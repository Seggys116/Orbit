// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/media/orbit_audio_toolbox_aac_decoder.h"

#include <array>
#include <cmath>
#include <memory>
#include <utility>
#include <vector>

#include <algorithm>
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "media/base/audio_buffer.h"
#include "media/base/audio_bus.h"
#include "media/base/audio_codecs.h"
#include "media/base/decoder_buffer.h"
#include "media/base/decoder_status.h"
#include "media/base/media_util.h"
#include "media/base/sample_format.h"
#include "media/base/timestamp_constants.h"
#include "orbit/media/orbit_aac_test_streams.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace orbit {
namespace {

using ::media::AudioCodec;
using ::media::AudioCodecProfile;

struct DecodedAudio {
  int sample_rate = 0;
  int channels = 0;
  int64_t frames = 0;
  float peak = 0;
  media::DecoderStatus::Codes init_status = media::DecoderStatus::Codes::kFailed;
  bool all_decodes_ok = true;
};

// Splits an ADTS elementary stream the way MSE hands AAC to the decoder: one
// buffer per ADTS frame, header included.
std::vector<base::span<const uint8_t>> SplitAdts(
    base::span<const uint8_t> stream) {
  std::vector<base::span<const uint8_t>> frames;
  size_t offset = 0;
  while (offset + 7 <= stream.size()) {
    base::span<const uint8_t> rest = stream.subspan(offset);
    if (rest[0] != 0xFF || (rest[1] & 0xF6) != 0xF0) {
      break;
    }
    const size_t length = (static_cast<size_t>(rest[3] & 0x03) << 11) |
                          (static_cast<size_t>(rest[4]) << 3) |
                          (static_cast<size_t>(rest[5]) >> 5);
    if (length < 7 || length > rest.size()) {
      break;
    }
    frames.push_back(rest.first(length));
    offset += length;
  }
  return frames;
}

DecodedAudio DecodeStream(base::span<const uint8_t> asc,
                          base::span<const uint8_t> adts,
                          int config_sample_rate,
                          media::ChannelLayoutConfig config_layout) {
  DecodedAudio result;

  media::AudioDecoderConfig config;
  config.Initialize(AudioCodec::kAAC, media::kSampleFormatPlanarF32,
                    config_layout, config_sample_rate,
                    std::vector<uint8_t>(asc.begin(), asc.end()),
                    media::EncryptionScheme::kUnencrypted, base::TimeDelta(), 0);

  OrbitAudioToolboxAacDecoder decoder(std::make_unique<media::NullMediaLog>());

  decoder.Initialize(
      config, nullptr,
      base::BindOnce([](media::DecoderStatus::Codes* out,
                        media::DecoderStatus status) { *out = status.code(); },
                     &result.init_status),
      base::BindRepeating(
          [](DecodedAudio* out, scoped_refptr<media::AudioBuffer> buffer) {
            out->sample_rate = buffer->sample_rate();
            out->channels = buffer->channel_count();
            out->frames += buffer->frame_count();
            std::unique_ptr<media::AudioBus> bus = media::AudioBus::Create(
                buffer->channel_count(), buffer->frame_count());
            buffer->ReadFrames(buffer->frame_count(), 0, 0, bus.get());
            for (int channel = 0; channel < bus->channels(); ++channel) {
              for (float sample : bus->channel(channel)) {
                out->peak = std::max(out->peak, std::fabs(sample));
              }
            }
          },
          &result),
      base::DoNothing());
  base::RunLoop().RunUntilIdle();

  if (result.init_status != media::DecoderStatus::Codes::kOk) {
    return result;
  }

  base::TimeDelta timestamp;
  for (base::span<const uint8_t> frame : SplitAdts(adts)) {
    scoped_refptr<media::DecoderBuffer> buffer =
        media::DecoderBuffer::CopyFrom(frame);
    buffer->set_timestamp(timestamp);
    timestamp += base::Milliseconds(20);
    decoder.Decode(buffer, base::BindOnce(
                               [](bool* ok, media::DecoderStatus status) {
                                 *ok = *ok && status.is_ok();
                               },
                               &result.all_decodes_ok));
    base::RunLoop().RunUntilIdle();
  }

  decoder.Decode(media::DecoderBuffer::CreateEOSBuffer(),
                 base::BindOnce(
                     [](bool* ok, media::DecoderStatus status) {
                       *ok = *ok && status.is_ok();
                     },
                     &result.all_decodes_ok));
  base::RunLoop().RunUntilIdle();
  return result;
}

class OrbitAacDecoderTest : public testing::Test {
 protected:
  base::test::SingleThreadTaskEnvironment task_environment_;
};

TEST_F(OrbitAacDecoderTest, AdtsHeaderIsRecognisedAndStripped) {
  std::vector<base::span<const uint8_t>> frames =
      SplitAdts(test::kLC44100Adts);
  ASSERT_FALSE(frames.empty());
  EXPECT_EQ(AacAdtsHeaderSize(frames.front()), 7u);
}

TEST_F(OrbitAacDecoderTest, RawAccessUnitIsLeftAlone) {
  std::vector<base::span<const uint8_t>> frames =
      SplitAdts(test::kLC44100Adts);
  ASSERT_FALSE(frames.empty());
  EXPECT_EQ(AacAdtsHeaderSize(frames.front().subspan(7u)), 0u);
}

TEST_F(OrbitAacDecoderTest, AdtsFrameWithSeveralRawBlocksIsRefused) {
  std::vector<uint8_t> frame(64, 0);
  frame[0] = 0xFF;
  frame[1] = 0xF1;
  frame[3] = static_cast<uint8_t>(frame.size() >> 11);
  frame[4] = static_cast<uint8_t>((frame.size() & 0x7FF) >> 3);
  frame[5] = static_cast<uint8_t>((frame.size() & 0x07) << 5);
  frame[6] = 0x01;
  EXPECT_FALSE(AacAdtsHeaderSize(frame).has_value());
}

TEST_F(OrbitAacDecoderTest, StreamFormatSeparatesLcFromSbrAndParametricStereo) {
  std::optional<AacStreamFormat> lc =
      AacStreamFormatFor(test::kLC44100Asc, nullptr);
  ASSERT_TRUE(lc);
  EXPECT_EQ(lc->profile, AacProfile::kLC);
  EXPECT_EQ(lc->format_id, kAudioFormatMPEG4AAC);
  EXPECT_EQ(lc->sample_rate, 44100);
  EXPECT_EQ(lc->channels, 2u);
  EXPECT_EQ(lc->frames_per_packet, 1024u);

  // 48 kHz LC is the regression case: its core rate equals the SBR-doubled
  // rate the spec caps at 48000, so a naive comparison calls it HE-AAC.
  std::optional<AacStreamFormat> lc48 =
      AacStreamFormatFor(test::kLC48000Asc, nullptr);
  ASSERT_TRUE(lc48);
  EXPECT_EQ(lc48->profile, AacProfile::kLC);
  EXPECT_EQ(lc48->sample_rate, 48000);
  EXPECT_EQ(lc48->frames_per_packet, 1024u);

  std::optional<AacStreamFormat> he =
      AacStreamFormatFor(test::kHE32000Asc, nullptr);
  ASSERT_TRUE(he);
  EXPECT_EQ(he->profile, AacProfile::kHE);
  EXPECT_EQ(he->format_id, kAudioFormatMPEG4AAC_HE);
  EXPECT_EQ(he->sample_rate, 32000);
  EXPECT_EQ(he->channels, 2u);
  EXPECT_EQ(he->frames_per_packet, 2048u);

  std::optional<AacStreamFormat> hev2 =
      AacStreamFormatFor(test::kHEv2_44100Asc, nullptr);
  ASSERT_TRUE(hev2);
  EXPECT_EQ(hev2->profile, AacProfile::kHEv2);
  EXPECT_EQ(hev2->format_id, kAudioFormatMPEG4AAC_HE_V2);
  EXPECT_EQ(hev2->sample_rate, 44100);
  EXPECT_EQ(hev2->channels, 2u);
  EXPECT_EQ(hev2->frames_per_packet, 2048u);
}

TEST_F(OrbitAacDecoderTest, StreamFormatRejectsNonsense) {
  const std::array<uint8_t, 2> not_aac = {0x00, 0x00};
  EXPECT_FALSE(AacStreamFormatFor(not_aac, nullptr).has_value());
  EXPECT_FALSE(AacStreamFormatFor(base::span<const uint8_t>(), nullptr)
                   .has_value());
}

TEST_F(OrbitAacDecoderTest, DecodesAacLcToNonSilentPcm) {
  DecodedAudio audio =
      DecodeStream(test::kLC44100Asc, test::kLC44100Adts, 44100,
                   media::ChannelLayoutConfig::Stereo());
  EXPECT_EQ(audio.init_status, media::DecoderStatus::Codes::kOk);
  EXPECT_TRUE(audio.all_decodes_ok);
  EXPECT_EQ(audio.sample_rate, 44100);
  EXPECT_EQ(audio.channels, 2);
  EXPECT_GT(audio.frames, 44100 * 0.2);
  EXPECT_LT(audio.frames, 44100 * 0.5);
  EXPECT_GT(audio.peak, 0.01f);
}

TEST_F(OrbitAacDecoderTest, DecodesAacLc48kToNonSilentPcm) {
  DecodedAudio audio =
      DecodeStream(test::kLC48000Asc, test::kLC48000Adts, 48000,
                   media::ChannelLayoutConfig::Stereo());
  EXPECT_EQ(audio.init_status, media::DecoderStatus::Codes::kOk);
  EXPECT_TRUE(audio.all_decodes_ok);
  EXPECT_EQ(audio.sample_rate, 48000);
  EXPECT_EQ(audio.channels, 2);
  EXPECT_GT(audio.peak, 0.01f);
}

TEST_F(OrbitAacDecoderTest, DecodesHeAacAtItsSbrRate) {
  DecodedAudio audio = DecodeStream(test::kHE32000Asc, test::kHE32000Adts,
                                    32000, media::ChannelLayoutConfig::Stereo());
  EXPECT_EQ(audio.init_status, media::DecoderStatus::Codes::kOk);
  EXPECT_TRUE(audio.all_decodes_ok);
  // 32000, not the 16000 core: SBR really ran.
  EXPECT_EQ(audio.sample_rate, 32000);
  EXPECT_EQ(audio.channels, 2);
  EXPECT_GT(audio.peak, 0.01f);
}

TEST_F(OrbitAacDecoderTest, DecodesHeAacV2ToStereo) {
  DecodedAudio audio =
      DecodeStream(test::kHEv2_44100Asc, test::kHEv2_44100Adts, 44100,
                   media::ChannelLayoutConfig::Stereo());
  EXPECT_EQ(audio.init_status, media::DecoderStatus::Codes::kOk);
  EXPECT_TRUE(audio.all_decodes_ok);
  EXPECT_EQ(audio.sample_rate, 44100);
  // The core is mono; parametric stereo is what makes this 2.
  EXPECT_EQ(audio.channels, 2);
  EXPECT_GT(audio.peak, 0.01f);
}

TEST_F(OrbitAacDecoderTest, EncryptedConfigIsRefusedRatherThanFaked) {
  media::AudioDecoderConfig config;
  config.Initialize(AudioCodec::kAAC, media::kSampleFormatPlanarF32,
                    media::ChannelLayoutConfig::Stereo(), 44100,
                    std::vector<uint8_t>(test::kLC44100Asc.begin(),
                                         test::kLC44100Asc.end()),
                    media::EncryptionScheme::kCenc, base::TimeDelta(), 0);

  OrbitAudioToolboxAacDecoder decoder(std::make_unique<media::NullMediaLog>());
  media::DecoderStatus::Codes status = media::DecoderStatus::Codes::kOk;
  decoder.Initialize(
      config, nullptr,
      base::BindOnce([](media::DecoderStatus::Codes* out,
                        media::DecoderStatus s) { *out = s.code(); },
                     &status),
      base::DoNothing(), base::DoNothing());
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(status, media::DecoderStatus::Codes::kUnsupportedEncryptionMode);
}

TEST_F(OrbitAacDecoderTest, NonAacConfigIsRefused) {
  media::AudioDecoderConfig config;
  config.Initialize(AudioCodec::kOpus, media::kSampleFormatPlanarF32,
                    media::ChannelLayoutConfig::Stereo(), 48000,
                    std::vector<uint8_t>(), media::EncryptionScheme::kUnencrypted,
                    base::TimeDelta(), 0);

  OrbitAudioToolboxAacDecoder decoder(std::make_unique<media::NullMediaLog>());
  media::DecoderStatus::Codes status = media::DecoderStatus::Codes::kOk;
  decoder.Initialize(
      config, nullptr,
      base::BindOnce([](media::DecoderStatus::Codes* out,
                        media::DecoderStatus s) { *out = s.code(); },
                     &status),
      base::DoNothing(), base::DoNothing());
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(status, media::DecoderStatus::Codes::kUnsupportedCodec);
}

// The bug this whole change exists to prevent: an advertised codec with no
// decoder behind it, which shows up as silence or a mid-playback error.
TEST_F(OrbitAacDecoderTest, EveryAdvertisedAudioConfigHasARealDecoder) {
  const media::SupportedAudioDecoderConfigs configs =
      OrbitSupportedMacAudioDecoderConfigs();
  ASSERT_FALSE(configs.empty());

  for (const media::SupportedAudioDecoderConfig& config : configs) {
    EXPECT_EQ(config.codec, AudioCodec::kAAC);
    switch (config.profile) {
      case AudioCodecProfile::kUnknown: {
        // kUnknown covers AAC-LC, HE-AAC and HE-AACv2; all three must decode.
        const std::array<std::pair<base::span<const uint8_t>,
                                   base::span<const uint8_t>>,
                         3>
            streams = {{{test::kLC44100Asc, test::kLC44100Adts},
                        {test::kHE32000Asc, test::kHE32000Adts},
                        {test::kHEv2_44100Asc, test::kHEv2_44100Adts}}};
        for (const auto& [asc, adts] : streams) {
          DecodedAudio audio = DecodeStream(
              asc, adts, 44100, media::ChannelLayoutConfig::Stereo());
          EXPECT_EQ(audio.init_status, media::DecoderStatus::Codes::kOk);
          EXPECT_GT(audio.frames, 0);
          EXPECT_GT(audio.peak, 0.01f);
        }
        break;
      }
      case AudioCodecProfile::kXHE_AAC:
        EXPECT_TRUE(AudioToolboxCanDecode(kAudioFormatMPEGD_USAC));
        break;
      case AudioCodecProfile::kIAMF_SIMPLE:
      case AudioCodecProfile::kIAMF_BASE:
        ADD_FAILURE() << "Orbit's macOS audio client advertised an IAMF "
                         "profile it has no decoder for.";
        break;
    }
  }
}

TEST_F(OrbitAacDecoderTest, AacIsAdvertisedOnlyBecauseMacOsHasTheDecoder) {
  const media::SupportedAudioDecoderConfigs configs =
      OrbitSupportedMacAudioDecoderConfigs();
  EXPECT_EQ(AudioToolboxCanDecode(kAudioFormatMPEG4AAC),
            std::find(configs.begin(), configs.end(),
                      media::SupportedAudioDecoderConfig(
                          AudioCodec::kAAC, AudioCodecProfile::kUnknown)) !=
                configs.end());
  EXPECT_EQ(AudioToolboxCanDecode(kAudioFormatMPEGD_USAC),
            std::find(configs.begin(), configs.end(),
                      media::SupportedAudioDecoderConfig(
                          AudioCodec::kAAC, AudioCodecProfile::kXHE_AAC)) !=
                configs.end());
}

TEST_F(OrbitAacDecoderTest, DoesNotAskForAdtsBitstreamConversion) {
  OrbitAudioToolboxAacDecoder decoder(std::make_unique<media::NullMediaLog>());
  EXPECT_FALSE(decoder.NeedsBitstreamConversion());
  EXPECT_EQ(decoder.GetDecoderType(), media::AudioDecoderType::kAudioToolbox);
}

}  // namespace
}  // namespace orbit
