// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_APP_ORBIT_MAIN_DELEGATE_H_
#define ORBIT_EMBEDDER_APP_ORBIT_MAIN_DELEGATE_H_

#include <memory>

#include "content/public/app/content_main_delegate.h"

namespace orbit {

class OrbitContentBrowserClient;
class OrbitContentClient;
class OrbitContentRendererClient;

// The embedder's content::ContentMainDelegate; every process type constructs one.
// See ContentMainRunnerImpl::Initialize() for the call order.
class OrbitMainDelegate : public content::ContentMainDelegate {
 public:
  OrbitMainDelegate();
  OrbitMainDelegate(const OrbitMainDelegate&) = delete;
  OrbitMainDelegate& operator=(const OrbitMainDelegate&) = delete;
  ~OrbitMainDelegate() override;

  // content::ContentMainDelegate:
  std::optional<int> BasicStartupComplete() override;
  void PreSandboxStartup() override;
  std::variant<int, content::MainFunctionParams> RunProcess(
      const std::string& process_type,
      content::MainFunctionParams main_function_params) override;

 protected:
  content::ContentClient* CreateContentClient() override;
  content::ContentBrowserClient* CreateContentBrowserClient() override;
  content::ContentRendererClient* CreateContentRendererClient() override;

 private:
  std::unique_ptr<OrbitContentClient> content_client_;
  std::unique_ptr<OrbitContentBrowserClient> browser_client_;
  std::unique_ptr<OrbitContentRendererClient> renderer_client_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_APP_ORBIT_MAIN_DELEGATE_H_
