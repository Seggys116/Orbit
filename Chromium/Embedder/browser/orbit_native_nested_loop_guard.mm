// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_native_nested_loop_guard.h"

#import <AppKit/AppKit.h>

namespace orbit {

namespace {

void ObserverCallback(CFRunLoopObserverRef observer,
                       CFRunLoopActivity activity,
                       void* info) {
  static_cast<OrbitNativeNestedLoopGuard*>(info)->HandleActivity(activity);
}

}  // namespace

OrbitNativeNestedLoopGuard::OrbitNativeNestedLoopGuard() {
  CFRunLoopObserverContext context = {0};
  context.info = this;
  observer_.reset(CFRunLoopObserverCreate(
      /*allocator=*/nullptr,
      /*activities=*/kCFRunLoopEntry | kCFRunLoopExit,
      /*repeats=*/true,
      /*order=*/0,
      /*callout=*/&ObserverCallback,
      /*context=*/&context));

  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopAddObserver(loop, observer_.get(),
                       (__bridge CFRunLoopMode)NSEventTrackingRunLoopMode);
  CFRunLoopAddObserver(loop, observer_.get(),
                       (__bridge CFRunLoopMode)NSModalPanelRunLoopMode);
}

OrbitNativeNestedLoopGuard::~OrbitNativeNestedLoopGuard() {
  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopRemoveObserver(loop, observer_.get(),
                          (__bridge CFRunLoopMode)NSEventTrackingRunLoopMode);
  CFRunLoopRemoveObserver(loop, observer_.get(),
                          (__bridge CFRunLoopMode)NSModalPanelRunLoopMode);
  CFRunLoopObserverInvalidate(observer_.get());

  // Any levels still open at shutdown restore themselves in LIFO order.
  allow_stack_.clear();
}

void OrbitNativeNestedLoopGuard::HandleActivity(CFRunLoopActivity activity) {
  if (activity == kCFRunLoopEntry) {
    std::unique_ptr<Scope> scope;
    if (base::CurrentThread::IsSet()) {
      scope = std::make_unique<Scope>();
    }
    allow_stack_.push_back(std::move(scope));
    return;
  }

  if (activity == kCFRunLoopExit) {
    if (!allow_stack_.empty()) {
      allow_stack_.pop_back();
    }
  }
}

}  // namespace orbit
