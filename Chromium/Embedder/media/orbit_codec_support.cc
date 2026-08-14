// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/media/orbit_codec_support.h"

#include "media/base/audio_codecs.h"
#include "media/base/video_codecs.h"
#include "orbit/orbit_media_buildflags.h"

namespace orbit {

bool OrbitSupportsDecodingAudio(const media::AudioType& type,
                                bool default_supported) {
  switch (type.codec) {
    // AAC-LC/HE/HEv2/xHE decode through OrbitAudioToolboxAacDecoder in the GPU
    // process, which advertises only what macOS reports it can decode.
    case media::AudioCodec::kAAC:
    case media::AudioCodec::kUnknown:
    case media::AudioCodec::kMP3:
    case media::AudioCodec::kPCM:
    case media::AudioCodec::kVorbis:
    case media::AudioCodec::kFLAC:
    case media::AudioCodec::kAMR_NB:
    case media::AudioCodec::kAMR_WB:
    case media::AudioCodec::kPCM_MULAW:
    case media::AudioCodec::kGSM_MS:
    case media::AudioCodec::kPCM_S16BE:
    case media::AudioCodec::kPCM_S24BE:
    case media::AudioCodec::kOpus:
    case media::AudioCodec::kEAC3:
    case media::AudioCodec::kPCM_ALAW:
    case media::AudioCodec::kALAC:
    case media::AudioCodec::kAC3:
    case media::AudioCodec::kMpegHAudio:
    case media::AudioCodec::kDTS:
    case media::AudioCodec::kDTSXP2:
    case media::AudioCodec::kDTSE:
    case media::AudioCodec::kAC4:
    case media::AudioCodec::kIAMF:
      break;
  }
  return default_supported;
}

bool OrbitSupportsDecodingVideo(const media::VideoType& type,
                                bool default_supported) {
  switch (type.codec) {
    case media::VideoCodec::kH264:
#if !BUILDFLAG(ORBIT_BUNDLED_PROPRIETARY_DECODERS)
      // VideoToolbox registers BASELINE..HIGH, with no software fallback.
      if (type.profile > media::H264PROFILE_HIGH) {
        return false;
      }
#endif
      break;
    case media::VideoCodec::kUnknown:
    case media::VideoCodec::kVC1:
    case media::VideoCodec::kMPEG2:
    case media::VideoCodec::kMPEG4:
    case media::VideoCodec::kTheora:
    case media::VideoCodec::kVP8:
    case media::VideoCodec::kVP9:
    case media::VideoCodec::kHEVC:
    case media::VideoCodec::kAV1:
    case media::VideoCodec::kDolbyVision:
      break;
  }
  return default_supported;
}

}  // namespace orbit
