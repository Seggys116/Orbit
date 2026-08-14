#!/bin/bash
# Regenerates orbit_aac_test_streams.h from freshly encoded AAC. Needs ffmpeg
# for AAC-LC and macOS's own afconvert for HE-AAC/HE-AACv2, which ffmpeg cannot
# produce without a bundled encoder Orbit will not ship.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
OUT="orbit_aac_test_streams.h"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "sine=frequency=440:sample_rate=44100:duration=0.25" -ar 44100 -ac 2 "${WORK}/s.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "sine=frequency=440:sample_rate=48000:duration=0.25" -ar 48000 -ac 2 "${WORK}/s48.wav"

ffmpeg -hide_banner -loglevel error -y -i "${WORK}/s.wav" \
  -c:a aac -profile:a aac_low -b:a 64k -movflags +faststart "${WORK}/t_lc.m4a"
ffmpeg -hide_banner -loglevel error -y -i "${WORK}/s48.wav" \
  -c:a aac -profile:a aac_low -b:a 64k -movflags +faststart "${WORK}/t_lc48.m4a"
afconvert -f m4af -d aach -b 32000 "${WORK}/s.wav" "${WORK}/t_he.m4a"
afconvert -f m4af -d aacp -b 24000 "${WORK}/s.wav" "${WORK}/t_hev2.m4a"

for name in t_lc t_lc48 t_he t_hev2; do
  ffmpeg -hide_banner -loglevel error -y -i "${WORK}/${name}.m4a" -c:a copy -f adts "${WORK}/${name}.aac"
done

WORK="${WORK}" python3 - > "${OUT}" <<'PY'
import os
work = os.environ["WORK"]
names = [("LC44100", "t_lc"), ("LC48000", "t_lc48"), ("HE32000", "t_he"), ("HEv2_44100", "t_hev2")]

def asc(path):
    d = open(path, "rb").read()
    p = d.find(b"esds") + 8
    def rl(p):
        n = 0
        while True:
            b = d[p]; p += 1; n = (n << 7) | (b & 0x7F)
            if not b & 0x80:
                return n, p
    assert d[p] == 3; p += 1; _, p = rl(p); p += 3
    assert d[p] == 4; p += 1; _, p = rl(p); p += 1 + 1 + 3 + 4 + 4
    assert d[p] == 5; p += 1; n, p = rl(p)
    return d[p:p + n]

def arr(b):
    return "\n".join("    " + ", ".join("0x%02x" % x for x in b[i:i + 12]) + "," for i in range(0, len(b), 12))

print('''// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Generated fixtures: real AAC bitstreams, ~0.25s of a 440Hz tone. Each entry
// pairs the AudioSpecificConfig from the stream's own esds with the matching
// ADTS elementary stream, so the decoder can be driven exactly as the MSE MP4
// path drives it. Regenerate with Chromium/Embedder/media/make_aac_fixtures.sh.

#ifndef ORBIT_EMBEDDER_MEDIA_ORBIT_AAC_TEST_STREAMS_H_
#define ORBIT_EMBEDDER_MEDIA_ORBIT_AAC_TEST_STREAMS_H_

#include <stdint.h>

#include <array>

namespace orbit::test {
''')
for label, base in names:
    a = asc(os.path.join(work, base + ".m4a"))
    d = open(os.path.join(work, base + ".aac"), "rb").read()
    print("inline constexpr std::array<uint8_t, %d> k%sAsc = {\n%s\n};\n" % (len(a), label, arr(a)))
    print("inline constexpr std::array<uint8_t, %d> k%sAdts = {\n%s\n};\n" % (len(d), label, arr(d)))
print('''}  // namespace orbit::test

#endif  // ORBIT_EMBEDDER_MEDIA_ORBIT_AAC_TEST_STREAMS_H_''')
PY

echo "wrote ${OUT}"
