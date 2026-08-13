// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/public/browser/native_event_processor_mac.h"

#import <objc/runtime.h>

namespace orbit {
namespace {

// Nothing in the framework implements this protocol -- Swift grafts it onto
// NSApplication at startup via objc_getProtocol -- so the shipping link
// strips its metadata and that lookup returns nil. Chromium then aborts in
// content::responsiveness::Watcher::SetUp(). dcheck keeps it either way,
// which is why only a release build ever failed.
__attribute__((used)) Protocol* const kRetainedProtocols[] = {
    @protocol(NativeEventProcessor),
};

}  // namespace
}  // namespace orbit
