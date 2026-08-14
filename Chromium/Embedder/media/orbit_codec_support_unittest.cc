// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/media/orbit_codec_support.h"

#include "base/containers/flat_set.h"
#include "media/base/audio_codecs.h"
#include "media/base/supported_types.h"
#include "media/base/video_codecs.h"
#include "media/base/video_color_space.h"
#include "orbit/media/orbit_audio_toolbox_aac_decoder.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace orbit {
namespace {

using ::media::AudioCodec;
using ::media::AudioCodecProfile;
using ::media::VideoCodec;

// The whole answer a page sees from canPlayType / isTypeSupported:
// //media's own verdict, narrowed by Orbit's policy.
bool OrbitSupportsAudio(AudioCodec codec, AudioCodecProfile profile) {
  const media::AudioType type{codec, profile, false};
  return OrbitSupportsDecodingAudio(type,
                                    media::IsDecoderSupportedAudioType(type));
}

bool OrbitSupportsVideo(media::VideoCodecProfile profile) {
  media::VideoType type;
  type.codec = media::VideoCodecProfileToVideoCodec(profile);
  type.profile = profile;
  type.color_space = media::VideoColorSpace::REC709();
  return OrbitSupportsDecodingVideo(type,
                                    media::IsDecoderSupportedVideoType(type));
}

class OrbitCodecSupportTest : public testing::Test {
 protected:
  void SetUp() override {
    // Stands in for what the GPU process reports over mojo at run time.
    base::flat_set<media::AudioType> audio_types;
    for (const auto& config : OrbitSupportedMacAudioDecoderConfigs()) {
      audio_types.insert(media::AudioType{config.codec, config.profile, false});
    }
    media::UpdateDefaultDecoderSupportedAudioTypes(audio_types);
    media::UpdateDefaultDecoderSupportedVideoProfiles(
        {media::H264PROFILE_BASELINE, media::H264PROFILE_MAIN,
         media::H264PROFILE_HIGH, media::HEVCPROFILE_MAIN,
         media::VP9PROFILE_PROFILE0, media::AV1PROFILE_PROFILE_MAIN});
  }

  void TearDown() override {
    media::UpdateDefaultDecoderSupportedAudioTypes({});
    media::UpdateDefaultDecoderSupportedVideoProfiles({});
  }
};

TEST_F(OrbitCodecSupportTest, AacIsSupportedBecauseAudioToolboxDecodesIt) {
  ASSERT_TRUE(AudioToolboxCanDecode(kAudioFormatMPEG4AAC));
  EXPECT_TRUE(OrbitSupportsAudio(AudioCodec::kAAC, AudioCodecProfile::kUnknown));
}

TEST_F(OrbitCodecSupportTest, XheAacFollowsWhatTheGpuProcessReported) {
  const bool advertised =
      AudioToolboxCanDecode(kAudioFormatMPEGD_USAC);
  EXPECT_EQ(OrbitSupportsAudio(AudioCodec::kAAC, AudioCodecProfile::kXHE_AAC),
            advertised);
}

TEST_F(OrbitCodecSupportTest, RoyaltyFreeAudioCodecsAreUntouched) {
  EXPECT_TRUE(OrbitSupportsAudio(AudioCodec::kOpus, AudioCodecProfile::kUnknown));
  EXPECT_TRUE(
      OrbitSupportsAudio(AudioCodec::kVorbis, AudioCodecProfile::kUnknown));
  EXPECT_TRUE(OrbitSupportsAudio(AudioCodec::kFLAC, AudioCodecProfile::kUnknown));
  EXPECT_TRUE(OrbitSupportsAudio(AudioCodec::kMP3, AudioCodecProfile::kUnknown));
  EXPECT_TRUE(OrbitSupportsAudio(AudioCodec::kPCM, AudioCodecProfile::kUnknown));
}

TEST_F(OrbitCodecSupportTest, CodecsWithNoDecoderAnywhereStayUnsupported) {
  EXPECT_FALSE(OrbitSupportsAudio(AudioCodec::kALAC, AudioCodecProfile::kUnknown));
  EXPECT_FALSE(
      OrbitSupportsAudio(AudioCodec::kAMR_NB, AudioCodecProfile::kUnknown));
  EXPECT_FALSE(
      OrbitSupportsAudio(AudioCodec::kMpegHAudio, AudioCodecProfile::kUnknown));
  EXPECT_FALSE(
      OrbitSupportsAudio(AudioCodec::kUnknown, AudioCodecProfile::kUnknown));
}

TEST_F(OrbitCodecSupportTest, H264StopsAtTheProfilesVideoToolboxRegisters) {
  EXPECT_TRUE(OrbitSupportsVideo(media::H264PROFILE_BASELINE));
  EXPECT_TRUE(OrbitSupportsVideo(media::H264PROFILE_MAIN));
  EXPECT_TRUE(OrbitSupportsVideo(media::H264PROFILE_HIGH));

  EXPECT_FALSE(OrbitSupportsVideo(media::H264PROFILE_HIGH10PROFILE));
  EXPECT_FALSE(OrbitSupportsVideo(media::H264PROFILE_HIGH422PROFILE));
  EXPECT_FALSE(OrbitSupportsVideo(media::H264PROFILE_HIGH444PREDICTIVEPROFILE));
}

TEST_F(OrbitCodecSupportTest, PlatformAndBuiltInVideoCodecsAreUntouched) {
  EXPECT_TRUE(OrbitSupportsVideo(media::VP8PROFILE_ANY));
  EXPECT_TRUE(OrbitSupportsVideo(media::VP9PROFILE_PROFILE0));
  EXPECT_TRUE(OrbitSupportsVideo(media::AV1PROFILE_PROFILE_MAIN));
  EXPECT_TRUE(OrbitSupportsVideo(media::HEVCPROFILE_MAIN));
}

TEST_F(OrbitCodecSupportTest, HevcFollowsWhatVideoToolboxReported) {
  media::UpdateDefaultDecoderSupportedVideoProfiles({media::H264PROFILE_HIGH});
  EXPECT_FALSE(OrbitSupportsVideo(media::HEVCPROFILE_MAIN));
}

TEST_F(OrbitCodecSupportTest, CodecsWithNoVideoDecoderStayUnsupported) {
  EXPECT_FALSE(OrbitSupportsVideo(media::VIDEO_CODEC_PROFILE_UNKNOWN));
  EXPECT_FALSE(OrbitSupportsVideo(media::DOLBYVISION_PROFILE5));
}

// Nothing may be advertised without a decoder behind it: every audio type
// //media reports as decodable has to be one Orbit can name a decoder for.
TEST_F(OrbitCodecSupportTest, NoAudioCodecIsAdvertisedWithoutADecoder) {
  for (int value = static_cast<int>(AudioCodec::kUnknown);
       value <= static_cast<int>(AudioCodec::kMaxValue); ++value) {
    const AudioCodec codec = static_cast<AudioCodec>(value);
    if (!OrbitSupportsAudio(codec, AudioCodecProfile::kUnknown)) {
      continue;
    }
    switch (codec) {
      // AudioToolbox, via OrbitAudioToolboxAacDecoder.
      case AudioCodec::kAAC:
        EXPECT_TRUE(AudioToolboxCanDecode(kAudioFormatMPEG4AAC));
        break;
      // Built into the engine and free of patent obligation.
      case AudioCodec::kOpus:
      case AudioCodec::kVorbis:
      case AudioCodec::kFLAC:
      case AudioCodec::kMP3:
      case AudioCodec::kPCM:
      case AudioCodec::kPCM_MULAW:
      case AudioCodec::kPCM_ALAW:
      case AudioCodec::kPCM_S16BE:
      case AudioCodec::kPCM_S24BE:
        break;
      case AudioCodec::kUnknown:
      case AudioCodec::kAMR_NB:
      case AudioCodec::kAMR_WB:
      case AudioCodec::kGSM_MS:
      case AudioCodec::kEAC3:
      case AudioCodec::kALAC:
      case AudioCodec::kAC3:
      case AudioCodec::kMpegHAudio:
      case AudioCodec::kDTS:
      case AudioCodec::kDTSXP2:
      case AudioCodec::kDTSE:
      case AudioCodec::kAC4:
      case AudioCodec::kIAMF:
        ADD_FAILURE() << "Orbit reports " << media::GetCodecName(codec)
                      << " decodable but ships no decoder for it.";
        break;
    }
  }
}

}  // namespace
}  // namespace orbit
