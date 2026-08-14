// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_MEDIA_ORBIT_CODEC_SUPPORT_H_
#define ORBIT_EMBEDDER_MEDIA_ORBIT_CODEC_SUPPORT_H_

#include "media/base/media_types.h"

namespace orbit {

// Orbit's answer for canPlayType / MediaSource.isTypeSupported /
// MediaCapabilities / WebCodecs. `default_supported` is //media's own answer,
// which these narrow to what Orbit -- shipping no bundled decoder -- can
// actually decode. Both switch exhaustively so a new codec enum value is a
// compile error rather than a silent claim of support.
bool OrbitSupportsDecodingAudio(const media::AudioType& type,
                                bool default_supported);
bool OrbitSupportsDecodingVideo(const media::VideoType& type,
                                bool default_supported);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_MEDIA_ORBIT_CODEC_SUPPORT_H_
