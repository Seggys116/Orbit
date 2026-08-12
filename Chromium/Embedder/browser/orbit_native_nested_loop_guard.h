// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Native nested run loops (menu tracking, modal panels) starve UI-thread tasks unless
// opted back in. Scoped to NSEventTrackingRunLoopMode/NSModalPanelRunLoopMode only, not
// kCFRunLoopCommonModes, so content::'s own UI pump is unaffected.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_NESTED_LOOP_GUARD_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_NESTED_LOOP_GUARD_H_

#include <CoreFoundation/CoreFoundation.h>

#include <memory>
#include <vector>

#include "base/apple/scoped_cftyperef.h"
#include "base/task/current_thread.h"

namespace orbit {

class OrbitNativeNestedLoopGuard {
 public:
  // Must be constructed on the UI thread, after the browser process's UI
  // thread SequenceManager exists (base::CurrentThread::IsSet()). Lives for
  // the remainder of the process; see OrbitBrowserMainParts.
  OrbitNativeNestedLoopGuard();
  OrbitNativeNestedLoopGuard(const OrbitNativeNestedLoopGuard&) = delete;
  OrbitNativeNestedLoopGuard& operator=(const OrbitNativeNestedLoopGuard&) =
      delete;
  ~OrbitNativeNestedLoopGuard();

  // Called only by the CFRunLoopObserver callback in the .mm; not part of
  // this class's public API otherwise.
  void HandleActivity(CFRunLoopActivity activity);

 private:
  using Scope = base::CurrentThread::ScopedAllowApplicationTasksInNativeNestedLoop;

  base::apple::ScopedCFTypeRef<CFRunLoopObserverRef> observer_;

  // One entry per nested loop level. Null entry means SequenceManager wasn't bound at
  // Entry (defensive); the matching Exit must not restore state that was never set.
  std::vector<std::unique_ptr<Scope>> allow_stack_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_NESTED_LOOP_GUARD_H_
