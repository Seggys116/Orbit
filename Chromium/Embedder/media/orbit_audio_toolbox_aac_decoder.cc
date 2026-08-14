// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/media/orbit_audio_toolbox_aac_decoder.h"

#include <algorithm>
#include <optional>
#include <utility>

#include "base/apple/osstatus_logging.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/memory/raw_span.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/notreached.h"
#include "base/task/bind_post_task.h"
#include "media/base/audio_buffer.h"
#include "media/base/audio_codecs.h"
#include "media/base/channel_layout.h"
#include "media/base/mac/channel_layout_util_mac.h"
#include "media/base/media_util.h"
#include "media/base/sample_format.h"
#include "media/base/status.h"
#include "media/formats/mp4/aac.h"
#include "media/formats/mp4/es_descriptor.h"

namespace orbit {

namespace {

constexpr size_t kAdtsHeaderSizeNoCrc = 7;
constexpr size_t kAdtsHeaderSizeWithCrc = 9;

// ISO 14496-3: one raw data block is 1024 samples; SBR doubles that.
constexpr UInt32 kFramesPerPacketLC = 1024;
constexpr UInt32 kFramesPerPacketSBR = 2048;

constexpr OSStatus kNoMoreDataError = -12345;

struct InputData {
  base::raw_span<const uint8_t> payload;
  bool consumed = false;
  AudioStreamPacketDescription packet = {};
};

OSStatus ProvideInputCallback(AudioConverterRef decoder,
                              UInt32* num_packets,
                              AudioBufferList* buffer_list,
                              AudioStreamPacketDescription** packets,
                              void* user_data) {
  auto* input_data = reinterpret_cast<InputData*>(user_data);
  if (input_data->consumed || input_data->payload.empty()) {
    *num_packets = 0;
    return kNoMoreDataError;
  }

  *num_packets = buffer_list->mNumberBuffers = 1;
  buffer_list->mBuffers[0].mNumberChannels = 0;
  buffer_list->mBuffers[0].mDataByteSize = input_data->payload.size();
  // No const version of this API, so const_cast() is unavoidable.
  buffer_list->mBuffers[0].mData =
      const_cast<uint8_t*>(input_data->payload.data());

  if (packets) {
    *packets = &input_data->packet;
  }

  input_data->consumed = true;
  return noErr;
}

}  // namespace

std::optional<size_t> AacAdtsHeaderSize(base::span<const uint8_t> frame) {
  if (frame.size() < kAdtsHeaderSizeNoCrc) {
    return 0u;
  }
  if (frame[0] != 0xFF || (frame[1] & 0xF6) != 0xF0) {
    return 0u;
  }
  const size_t frame_length = (static_cast<size_t>(frame[3] & 0x03) << 11) |
                              (static_cast<size_t>(frame[4]) << 3) |
                              (static_cast<size_t>(frame[5]) >> 5);
  // Every producer in this build (MSE MP4, MSE ADTS, MPEG2-TS) emits exactly
  // one ADTS frame per buffer, so anything else is a raw access unit.
  if (frame_length != frame.size()) {
    return 0u;
  }
  // AudioConverter takes exactly one raw data block per packet.
  if ((frame[6] & 0x03) != 0) {
    return std::nullopt;
  }
  const size_t header_size =
      (frame[1] & 0x01) ? kAdtsHeaderSizeNoCrc : kAdtsHeaderSizeWithCrc;
  if (header_size >= frame.size()) {
    return std::nullopt;
  }
  return header_size;
}

std::optional<AacStreamFormat> AacStreamFormatFor(
    base::span<const uint8_t> audio_specific_config,
    media::MediaLog* media_log) {
  media::NullMediaLog null_log;
  media::mp4::AAC parsed;
  if (!parsed.Parse(audio_specific_config,
                    media_log ? media_log : &null_log)) {
    return std::nullopt;
  }

  const std::vector<uint8_t> cookie = media::mp4::ESDescriptor::CreateEsds(
      std::vector<uint8_t>(audio_specific_config.begin(),
                           audio_specific_config.end()));

  AacStreamFormat format;
  if (parsed.GetProfile() == media::AudioCodecProfile::kXHE_AAC) {
    format.profile = AacProfile::kXHE;
    AudioStreamBasicDescription description = {};
    description.mFormatID = kAudioFormatMPEGD_USAC;
    UInt32 size = sizeof(description);
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, cookie.size(),
                               cookie.data(), &size, &description) != noErr) {
      return std::nullopt;
    }
    format.format_id = kAudioFormatMPEGD_USAC;
    format.sample_rate = description.mSampleRate;
    format.channels = description.mChannelsPerFrame;
    format.frames_per_packet = description.mFramesPerPacket;
    format.channel_layout =
        static_cast<int>(format.channels) > media::GetConcurrentMaxChannels()
            ? media::CHANNEL_LAYOUT_DISCRETE
            : media::GuessChannelLayout(static_cast<int>(format.channels));
  } else {
    // AudioToolbox's own AudioSpecificConfig parse, which always reports the
    // AAC-LC core: the SBR/PS extensions only show up in mp4::AAC's numbers.
    AudioStreamBasicDescription core = {};
    core.mFormatID = kAudioFormatMPEG4AAC;
    UInt32 size = sizeof(core);
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, cookie.size(),
                               cookie.data(), &size, &core) != noErr) {
      return std::nullopt;
    }

    const int extended_rate = parsed.GetOutputSamplesPerSecond(false);
    const media::ChannelLayoutConfig layout = parsed.GetChannelLayout(false);
    const bool sbr = extended_rate != static_cast<int>(core.mSampleRate);
    const bool ps =
        sbr && layout.channels() != static_cast<int>(core.mChannelsPerFrame);

    if (ps) {
      format.profile = AacProfile::kHEv2;
    } else if (sbr) {
      format.profile = AacProfile::kHE;
    } else {
      format.profile = AacProfile::kLC;
    }

    switch (format.profile) {
      case AacProfile::kLC:
        format.format_id = kAudioFormatMPEG4AAC;
        format.sample_rate = core.mSampleRate;
        format.channels = core.mChannelsPerFrame;
        format.frames_per_packet = kFramesPerPacketLC;
        break;
      case AacProfile::kHE:
        format.format_id = kAudioFormatMPEG4AAC_HE;
        format.sample_rate = extended_rate;
        format.channels = core.mChannelsPerFrame;
        format.frames_per_packet = kFramesPerPacketSBR;
        break;
      case AacProfile::kHEv2:
        format.format_id = kAudioFormatMPEG4AAC_HE_V2;
        format.sample_rate = extended_rate;
        format.channels = static_cast<UInt32>(layout.channels());
        format.frames_per_packet = kFramesPerPacketSBR;
        break;
      case AacProfile::kXHE:
        NOTREACHED();
    }
    format.channel_layout =
        layout.channels() == static_cast<int>(format.channels)
            ? layout.channel_layout()
            : media::GuessChannelLayout(static_cast<int>(format.channels));
  }

  if (format.channels == 0 || format.frames_per_packet == 0 ||
      format.sample_rate <= 0 ||
      format.channel_layout == media::CHANNEL_LAYOUT_UNSUPPORTED) {
    return std::nullopt;
  }
  return format;
}

bool AudioToolboxCanDecode(AudioFormatID format_id) {
  UInt32 size = 0;
  if (AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0,
                                 nullptr, &size) != noErr ||
      size == 0) {
    return false;
  }
  std::vector<AudioFormatID> ids(size / sizeof(AudioFormatID));
  if (AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nullptr,
                             &size, ids.data()) != noErr) {
    return false;
  }
  return std::find(ids.begin(), ids.end(), format_id) != ids.end();
}

media::SupportedAudioDecoderConfigs OrbitSupportedMacAudioDecoderConfigs() {
  media::SupportedAudioDecoderConfigs configs;
  // Asked of macOS rather than hardcoded: advertising a codec with no decoder
  // behind it is what produces silence or a mid-playback error. HE-AAC and
  // HE-AACv2 share kUnknown with AAC-LC, so they cannot be advertised apart.
  if (AudioToolboxCanDecode(kAudioFormatMPEG4AAC)) {
    configs.emplace_back(media::AudioCodec::kAAC,
                         media::AudioCodecProfile::kUnknown);
  }
  if (AudioToolboxCanDecode(kAudioFormatMPEGD_USAC)) {
    configs.emplace_back(media::AudioCodec::kAAC,
                         media::AudioCodecProfile::kXHE_AAC);
  }
  return configs;
}

std::unique_ptr<media::AudioDecoder> CreateOrbitMacAudioDecoder(
    std::unique_ptr<media::MediaLog> media_log) {
  return std::make_unique<OrbitAudioToolboxAacDecoder>(std::move(media_log));
}

// static
AudioConverterRef
OrbitAudioToolboxAacDecoder::ScopedAudioConverterRefTraits::Retain(
    AudioConverterRef converter) {
  NOTREACHED() << "Only compatible with ASSUME policy";
}

// static
void OrbitAudioToolboxAacDecoder::ScopedAudioConverterRefTraits::Release(
    AudioConverterRef converter) {
  const auto result = AudioConverterDispose(converter);
  OSSTATUS_DLOG_IF(WARNING, result != noErr, result)
      << "AudioConverterDispose() failed";
}

OrbitAudioToolboxAacDecoder::OrbitAudioToolboxAacDecoder(
    std::unique_ptr<media::MediaLog> log)
    : media_log_(std::move(log)) {}

OrbitAudioToolboxAacDecoder::~OrbitAudioToolboxAacDecoder() = default;

media::AudioDecoderType OrbitAudioToolboxAacDecoder::GetDecoderType() const {
  return media::AudioDecoderType::kAudioToolbox;
}

bool OrbitAudioToolboxAacDecoder::NeedsBitstreamConversion() const {
  return false;
}

void OrbitAudioToolboxAacDecoder::Initialize(
    const media::AudioDecoderConfig& config,
    media::CdmContext* cdm_context,
    InitCB init_cb,
    const OutputCB& output_cb,
    const media::WaitingCB& waiting_cb) {
  InitCB init_cb_bound = base::BindPostTaskToCurrentDefault(std::move(init_cb));

  if (config.codec() != media::AudioCodec::kAAC) {
    std::move(init_cb_bound).Run(media::DecoderStatus::Codes::kUnsupportedCodec);
    return;
  }

  if (config.is_encrypted()) {
    std::move(init_cb_bound)
        .Run(media::DecoderStatus::Codes::kUnsupportedEncryptionMode);
    return;
  }

  if (config.extra_data().empty()) {
    MEDIA_LOG(ERROR, media_log_)
        << "AAC stream carries no AudioSpecificConfig; AudioToolbox needs one.";
    std::move(init_cb_bound)
        .Run(media::DecoderStatus::Codes::kUnsupportedConfig);
    return;
  }

  // Supports re-initialization.
  decoder_.reset();

  output_cb_ = output_cb;
  if (!CreateDecoder(config)) {
    decoder_.reset();
    std::move(init_cb_bound)
        .Run(media::DecoderStatus::Codes::kFailedToCreateDecoder);
    return;
  }
  std::move(init_cb_bound).Run(media::DecoderStatus::Codes::kOk);
}

bool OrbitAudioToolboxAacDecoder::CreateDecoder(
    const media::AudioDecoderConfig& config) {
  std::optional<AacStreamFormat> format =
      AacStreamFormatFor(config.extra_data(), media_log_.get());
  if (!format) {
    MEDIA_LOG(ERROR, media_log_)
        << "AAC object type has no AudioToolbox decoder.";
    return false;
  }

  const std::vector<uint8_t> magic_cookie =
      media::mp4::ESDescriptor::CreateEsds(config.extra_data());

  AudioStreamBasicDescription input_format = {};
  input_format.mFormatID = format->format_id;
  input_format.mSampleRate = format->sample_rate;
  input_format.mChannelsPerFrame = format->channels;
  input_format.mFramesPerPacket = format->frames_per_packet;

  {
    AudioStreamBasicDescription output_format = {};
    output_format.mFormatID = kAudioFormatLinearPCM;
    output_format.mFormatFlags =
        kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsNonInterleaved;
    output_format.mFramesPerPacket = 1;
    output_format.mBitsPerChannel = 32;
    output_format.mSampleRate = input_format.mSampleRate;
    output_format.mChannelsPerFrame = input_format.mChannelsPerFrame;
    output_format.mBytesPerPacket = output_format.mBytesPerFrame =
        output_format.mBitsPerChannel / 8;

    auto result = AudioConverterNew(&input_format, &output_format,
                                    decoder_.InitializeInto());
    if (result != noErr) {
      OSSTATUS_MEDIA_LOG(ERROR, result, media_log_)
          << "AudioConverterNew() failed";
      return false;
    }
  }

  channel_layout_ = format->channel_layout;
  if (!ApplyChannelLayout(format->channels)) {
    return false;
  }

  auto result = AudioConverterSetProperty(
      decoder_.get(), kAudioConverterDecompressionMagicCookie,
      magic_cookie.size(), magic_cookie.data());
  if (result != noErr) {
    OSSTATUS_MEDIA_LOG(ERROR, result, media_log_)
        << "AudioConverterSetProperty() failed to set the magic cookie";
    return false;
  }

  switch (format->profile) {
    case AacProfile::kXHE: {
      // macOS provides no default target loudness for USAC; these are the
      // values Fraunhofer recommends, and only USAC accepts them.
      const Float32 kDefaultLoudness = -16.0;
      result = AudioConverterSetProperty(
          decoder_.get(), kAudioCodecPropertyProgramTargetLevel,
          sizeof(kDefaultLoudness), &kDefaultLoudness);
      if (result != noErr) {
        OSSTATUS_MEDIA_LOG(ERROR, result, media_log_)
            << "AudioConverterSetProperty() failed to set loudness";
        return false;
      }
      // 0=none, night=1, noisy=2, limited=3. No key name exists yet.
      const UInt32 kDefaultEffectType = 3;
      result = AudioConverterSetProperty(decoder_.get(), 0x64726370 /* "drcp" */,
                                         sizeof(kDefaultEffectType),
                                         &kDefaultEffectType);
      if (result != noErr) {
        OSSTATUS_MEDIA_LOG(ERROR, result, media_log_)
            << "AudioConverterSetProperty() failed to set DRC effect type";
        return false;
      }
      break;
    }
    case AacProfile::kLC:
    case AacProfile::kHE:
    case AacProfile::kHEv2:
      break;
  }

  sample_rate_ = static_cast<int>(format->sample_rate);
  codec_delay_ = config.codec_delay();
  discard_helper_ = std::make_unique<media::AudioDiscardHelper>(
      sample_rate_, codec_delay_, false);
  discard_helper_->Reset(codec_delay_);
  last_input_timestamp_ = media::kNoTimestamp;

  output_bus_ = media::AudioBus::Create(
      static_cast<int>(format->channels),
      static_cast<int>(format->frames_per_packet));

  // AudioBufferList is variable length with one inline slot, so the multi
  // channel form has to be built by hand.
  output_buffer_list_.reset(reinterpret_cast<AudioBufferList*>(
      calloc(1, sizeof(AudioBufferList) +
                    output_bus_->channels() * sizeof(AudioBuffer))));
  return output_buffer_list_ != nullptr;
}

bool OrbitAudioToolboxAacDecoder::ApplyChannelLayout(UInt32 channels) {
  auto ordered_layout = media::ChannelLayoutToAudioChannelLayout(
      media::ChannelLayoutConfig(channel_layout_, static_cast<int>(channels)));
  if (!ordered_layout) {
    MEDIA_LOG(ERROR, media_log_) << "Failed to create audio channel layout.";
    return false;
  }

  auto result = AudioConverterSetProperty(
      decoder_.get(), kAudioConverterOutputChannelLayout,
      ordered_layout->layout_size(), ordered_layout->layout());
  if (result != noErr) {
    OSSTATUS_MEDIA_LOG(ERROR, result, media_log_)
        << "AudioConverterSetProperty() failed to set the channel layout";
    return false;
  }
  return true;
}

void OrbitAudioToolboxAacDecoder::Decode(
    scoped_refptr<media::DecoderBuffer> buffer,
    DecodeCB decode_cb) {
  CHECK(decoder_);
  DecodeCB decode_cb_bound =
      base::BindPostTaskToCurrentDefault(std::move(decode_cb));

  const bool end_of_stream = buffer->end_of_stream();

  if (!end_of_stream && buffer->timestamp() == media::kNoTimestamp) {
    std::move(decode_cb_bound)
        .Run(media::DecoderStatus::Codes::kMissingTimestamp);
    return;
  }

  if (!end_of_stream && buffer->is_encrypted()) {
    std::move(decode_cb_bound)
        .Run(media::DecoderStatus::Codes::kUnsupportedEncryptionMode);
    return;
  }

  InputData input_data;
  if (!end_of_stream) {
    if (buffer->size() == 0) {
      std::move(decode_cb_bound).Run(media::OkStatus());
      return;
    }

    base::span<const uint8_t> frame = base::span(*buffer);
    std::optional<size_t> header_size = AacAdtsHeaderSize(frame);
    if (!header_size) {
      MEDIA_LOG(ERROR, media_log_)
          << "ADTS frame AudioToolbox cannot take as one packet.";
      std::move(decode_cb_bound)
          .Run(media::DecoderStatus::Codes::kPlatformDecodeFailure);
      return;
    }

    input_data.payload = frame.subspan(*header_size);
    input_data.packet.mDataByteSize = input_data.payload.size();
    last_input_timestamp_ = buffer->timestamp();
  }

  output_buffer_list_->mNumberBuffers = output_bus_->channels();

  // SAFETY: CreateDecoder() allocated sizeof(AudioBufferList) plus
  // output_bus_->channels() AudioBuffer slots, which is exactly this span.
  auto buffer_span = UNSAFE_BUFFERS(base::span(
      output_buffer_list_->mBuffers, output_buffer_list_->mNumberBuffers));
  for (int i = 0; i < output_bus_->channels(); ++i) {
    buffer_span[i].mNumberChannels = 1;
    buffer_span[i].mDataByteSize = output_bus_->frames() * sizeof(float);
    buffer_span[i].mData = output_bus_->channel(i).data();
  }

  UInt32 num_frames = output_bus_->frames();
  auto result = AudioConverterFillComplexBuffer(
      decoder_.get(), ProvideInputCallback, &input_data, &num_frames,
      output_buffer_list_.get(), nullptr);

  if (result != noErr && result != kNoMoreDataError) {
    OSSTATUS_MEDIA_LOG(ERROR, result, media_log_)
        << "AudioConverterFillComplexBuffer() failed";
    std::move(decode_cb_bound)
        .Run(media::DecoderStatus::Codes::kPlatformDecodeFailure);
    return;
  }

  if (num_frames == 0) {
    std::move(decode_cb_bound).Run(media::OkStatus());
    return;
  }

  media::AudioDiscardHelper::TimeInfo time_info;
  if (end_of_stream) {
    time_info = media::AudioDiscardHelper::TimeInfo{
        last_input_timestamp_ == media::kNoTimestamp ? base::TimeDelta()
                                                     : last_input_timestamp_,
        base::TimeDelta(), std::nullopt};
  } else {
    time_info = media::AudioDiscardHelper::TimeInfo::FromBuffer(*buffer);
  }

  EmitOutput(time_info, num_frames);
  std::move(decode_cb_bound).Run(media::OkStatus());
}

void OrbitAudioToolboxAacDecoder::EmitOutput(
    const media::AudioDiscardHelper::TimeInfo& time_info,
    UInt32 frames) {
  const size_t bytes = static_cast<size_t>(frames) * sizeof(float);
  std::vector<base::span<const uint8_t>> channels;
  channels.reserve(output_bus_->channels());
  for (int i = 0; i < output_bus_->channels(); ++i) {
    // as_byte_span refuses float; this is the pattern dav1d_video_decoder.cc uses.
    channels.push_back(UNSAFE_BUFFERS(base::span(
        reinterpret_cast<const uint8_t*>(output_bus_->channel(i).data()), bytes)));
  }

  scoped_refptr<media::AudioBuffer> output = media::AudioBuffer::CopyFrom(
      media::kSampleFormatPlanarF32, channel_layout_, output_bus_->channels(),
      sample_rate_, static_cast<int>(frames), channels, time_info.timestamp);

  if (discard_helper_->ProcessBuffers(time_info, output.get())) {
    // The AudioDecoder contract forbids running output_cb_ inside Decode().
    base::BindPostTaskToCurrentDefault(output_cb_).Run(std::move(output));
  }
}

void OrbitAudioToolboxAacDecoder::Reset(base::OnceClosure reset_cb) {
  CHECK(decoder_);
  // AudioConverterReset() can fail with no way to report it; a later Decode()
  // will surface it instead.
  const auto result = AudioConverterReset(decoder_.get());
  OSSTATUS_DLOG_IF(WARNING, result != noErr, result)
      << "AudioConverterReset() failed";
  discard_helper_->Reset(codec_delay_);
  last_input_timestamp_ = media::kNoTimestamp;
  base::BindPostTaskToCurrentDefault(std::move(reset_cb)).Run();
}

}  // namespace orbit
