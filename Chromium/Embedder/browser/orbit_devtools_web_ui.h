// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Serves devtools://devtools/bundled/* out of orbit_resources.pak. Every
// other devtools:// path 404s; no /remote/ or /custom/ branch like chrome/'s.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_WEB_UI_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_WEB_UI_H_

#include <memory>
#include <string>

#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/web_ui_controller_factory.h"

class GURL;

namespace orbit {

// "devtools://devtools/bundled/devtools_app.html?targetType=tab".
std::string OrbitDevToolsFrontendURL();

// Registered once from OrbitBrowserMainParts::PreMainMessageLoopRun. Claims
// devtools://devtools/ and nothing else.
void RegisterOrbitDevToolsWebUI();

class OrbitDevToolsDataSource : public content::URLDataSource {
 public:
  OrbitDevToolsDataSource();
  OrbitDevToolsDataSource(const OrbitDevToolsDataSource&) = delete;
  OrbitDevToolsDataSource& operator=(const OrbitDevToolsDataSource&) = delete;
  ~OrbitDevToolsDataSource() override;

  // content::URLDataSource:
  std::string GetSource() override;
  void StartDataRequest(const GURL& url,
                        const content::WebContents::Getter& wc_getter,
                        GotDataCallback callback) override;
  std::string GetMimeType(const GURL& url) override;
  std::string GetContentSecurityPolicy(
      network::mojom::CSPDirectiveName directive) override;
  bool ShouldDenyXFrameOptions() override;
  bool ShouldServeMimeTypeAsContentTypeHeader() override;
};

class OrbitDevToolsUI : public content::WebUIController {
 public:
  explicit OrbitDevToolsUI(content::WebUI* web_ui);
  OrbitDevToolsUI(const OrbitDevToolsUI&) = delete;
  OrbitDevToolsUI& operator=(const OrbitDevToolsUI&) = delete;
  ~OrbitDevToolsUI() override;
};

class OrbitWebUIControllerFactory : public content::WebUIControllerFactory {
 public:
  static OrbitWebUIControllerFactory* GetInstance();

  std::unique_ptr<content::WebUIController> CreateWebUIControllerForURL(
      content::WebUI* web_ui,
      const GURL& url) override;
  content::WebUI::TypeID GetWebUIType(content::BrowserContext* browser_context,
                                      const GURL& url) override;
  bool UseWebUIForURL(content::BrowserContext* browser_context,
                      const GURL& url) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_WEB_UI_H_
