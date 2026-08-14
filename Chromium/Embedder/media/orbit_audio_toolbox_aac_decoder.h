// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_MEDIA_ORBIT_AUDIO_TOOLBOX_AAC_DECODER_H_
#define ORBIT_EMBEDDER_MEDIA_ORBIT_AUDIO_TOOLBOX_AAC_DECODER_H_

#include <AudioToolbox/AudioToolbox.h>

#include <memory>
#include <optional>
#include <vector>

#include "base/apple/scoped_typeref.h"
#include "base/containers/span.h"
#include "base/memory/free_deleter.h"
#include "media/base/audio_bus.h"
#include "media/base/audio_decoder.h"
#include "media/base/audio_decoder_config.h"
#include "media/base/audio_discard_helper.h"
#include "media/base/channel_layout.h"
#include "media/base/media_log.h"
#include "media/base/supported_audio_decoder_config.h"
#include "media/base/timestamp_constants.h"

namespace orbit {

// Which AAC flavour a stream is. AudioDecoderConfig::profile() cannot answer
// this: it collapses LC, HE-AAC and HE-AACv2 into kUnknown.
enum class AacProfile {
  kLC,
  kHE,
  kHEv2,
  kXHE,
};

// Everything the AudioToolbox converter needs, worked out from the stream's
// AudioSpecificConfig.
struct AacStreamFormat {
  AacProfile profile = AacProfile::kLC;
  AudioFormatID format_id = 0;
  double sample_rate = 0;
  UInt32 channels = 0;
  UInt32 frames_per_packet = 0;
  media::ChannelLayout channel_layout = media::CHANNEL_LAYOUT_UNSUPPORTED;
};

// Every AAC profile macOS itself decodes. Ships no decoder: this drives
// AudioToolbox's own codec components, which is also why it may only be
// constructed in the GPU process -- that is the one sandbox granting
// com.apple.audio.AudioComponentRegistrar and AudioCodecs.component.
class OrbitAudioToolboxAacDecoder : public media::AudioDecoder {
 public:
  explicit OrbitAudioToolboxAacDecoder(std::unique_ptr<media::MediaLog> log);

  OrbitAudioToolboxAacDecoder(const OrbitAudioToolboxAacDecoder&) = delete;
  OrbitAudioToolboxAacDecoder& operator=(const OrbitAudioToolboxAacDecoder&) =
      delete;

  ~OrbitAudioToolboxAacDecoder() override;

  media::AudioDecoderType GetDecoderType() const override;
  void Initialize(const media::AudioDecoderConfig& config,
                  media::CdmContext* cdm_context,
                  InitCB init_cb,
                  const OutputCB& output_cb,
                  const media::WaitingCB& waiting_cb) override;
  void Decode(scoped_refptr<media::DecoderBuffer> buffer,
              DecodeCB decode_cb) override;
  void Reset(base::OnceClosure reset_cb) override;
  bool NeedsBitstreamConversion() const override;

 private:
  struct ScopedAudioConverterRefTraits {
    static AudioConverterRef InvalidValue() { return nullptr; }
    static AudioConverterRef Retain(AudioConverterRef converter);
    static void Release(AudioConverterRef converter);
  };
  using ScopedAudioConverterRef =
      base::apple::ScopedTypeRef<AudioConverterRef,
                                 ScopedAudioConverterRefTraits>;

  bool CreateDecoder(const media::AudioDecoderConfig& config);
  bool ApplyChannelLayout(UInt32 channels);
  void EmitOutput(const media::AudioDiscardHelper::TimeInfo& time_info,
                  UInt32 frames);

  std::unique_ptr<media::MediaLog> media_log_;
  ScopedAudioConverterRef decoder_;
  OutputCB output_cb_;
  std::unique_ptr<media::AudioDiscardHelper> discard_helper_;
  std::unique_ptr<media::AudioBus> output_bus_;
  std::unique_ptr<AudioBufferList, base::FreeDeleter> output_buffer_list_;
  media::ChannelLayout channel_layout_ = media::CHANNEL_LAYOUT_UNSUPPORTED;
  int sample_rate_ = 0;
  size_t codec_delay_ = 0;
  base::TimeDelta last_input_timestamp_ = media::kNoTimestamp;
};

// Whether macOS itself reports a decoder for `format_id`.
bool AudioToolboxCanDecode(AudioFormatID format_id);

// Bytes of ADTS header at the front of `frame`, or 0 when the frame is already
// a raw access unit. std::nullopt means the frame is ADTS this decoder refuses.
std::optional<size_t> AacAdtsHeaderSize(base::span<const uint8_t> frame);

// AudioToolbox input format for an AudioSpecificConfig, or nullopt when macOS
// has no decoder for it. `media_log` may be null.
std::optional<AacStreamFormat> AacStreamFormatFor(
    base::span<const uint8_t> audio_specific_config,
    media::MediaLog* media_log);

// What Orbit's GPU-side media client advertises to the renderer for audio.
media::SupportedAudioDecoderConfigs OrbitSupportedMacAudioDecoderConfigs();

// The audio decoder Orbit's GPU-side media client hands to the media pipeline.
std::unique_ptr<media::AudioDecoder> CreateOrbitMacAudioDecoder(
    std::unique_ptr<media::MediaLog> media_log);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_MEDIA_ORBIT_AUDIO_TOOLBOX_AAC_DECODER_H_
