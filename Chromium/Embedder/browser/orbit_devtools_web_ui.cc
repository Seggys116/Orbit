// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/browser/orbit_devtools_web_ui.h"

#include <utility>

#include "base/containers/span.h"
#include "base/memory/ref_counted_memory.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/devtools_frontend_host.h"
#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "content/public/common/bindings_policy.h"
#include "content/public/common/url_constants.h"
#include "url/gurl.h"
#include "url/url_constants.h"

namespace orbit {

namespace {

constexpr char kDevToolsHost[] = "devtools";
constexpr char kBundledPathPrefix[] = "bundled/";

std::string DevToolsOrigin() {
  return base::StrCat(
      {content::kChromeDevToolsScheme, url::kStandardSchemeSeparator,
       kDevToolsHost});
}

// URLDataSource::URLToRequestPath keeps the query string; the pak lookup key
// must not have it.
std::string PathWithoutParams(const std::string& path) {
  return GURL(DevToolsOrigin()).Resolve(path).GetPath().substr(1);
}

scoped_refptr<base::RefCountedMemory> NotFound() {
  static constexpr char kBody[] = "HTTP/1.1 404 Not Found\n\n";
  return base::MakeRefCounted<base::RefCountedStaticMemory>(
      base::byte_span_from_cstring(kBody));
}

std::string MimeTypeForURL(const GURL& url) {
  const std::string filename = url.ExtractFileName();
  const auto ends_with = [&filename](const char* suffix) {
    return base::EndsWith(filename, suffix, base::CompareCase::INSENSITIVE_ASCII);
  };
  if (ends_with(".css")) {
    return "text/css";
  }
  if (ends_with(".js") || ends_with(".mjs")) {
    return "application/javascript";
  }
  if (ends_with(".json") || ends_with(".map")) {
    return "application/json";
  }
  if (ends_with(".png")) {
    return "image/png";
  }
  if (ends_with(".gif")) {
    return "image/gif";
  }
  if (ends_with(".svg")) {
    return "image/svg+xml";
  }
  if (ends_with(".woff2")) {
    return "font/woff2";
  }
  return "text/html";
}

bool IsOrbitDevToolsURL(const GURL& url) {
  return url.SchemeIs(content::kChromeDevToolsScheme) &&
         url.GetHost() == kDevToolsHost;
}

}  // namespace

// can_dock=true registers AdvancedAppProvider and lets DockController run;
// without it the frontend hard-codes itself undocked.
std::string OrbitDevToolsFrontendURL() {
  return base::StrCat(
      {DevToolsOrigin(), "/", kBundledPathPrefix,
       "devtools_app.html?targetType=tab&can_dock=true"});
}

void RegisterOrbitDevToolsWebUI() {
  static bool registered = false;
  if (registered) {
    return;
  }
  registered = true;
  content::WebUIControllerFactory::RegisterFactory(
      OrbitWebUIControllerFactory::GetInstance());
}

OrbitDevToolsDataSource::OrbitDevToolsDataSource() = default;

OrbitDevToolsDataSource::~OrbitDevToolsDataSource() = default;

std::string OrbitDevToolsDataSource::GetSource() {
  return kDevToolsHost;
}

void OrbitDevToolsDataSource::StartDataRequest(
    const GURL& url,
    const content::WebContents::Getter& wc_getter,
    GotDataCallback callback) {
  const std::string path = content::URLDataSource::URLToRequestPath(url);
  if (!base::StartsWith(path, kBundledPathPrefix,
                        base::CompareCase::INSENSITIVE_ASCII)) {
    std::move(callback).Run(NotFound());
    return;
  }

  const std::string bundled_path =
      PathWithoutParams(path).substr(sizeof(kBundledPathPrefix) - 1);
  scoped_refptr<base::RefCountedMemory> bytes =
      content::DevToolsFrontendHost::GetFrontendResourceBytes(bundled_path);
  std::move(callback).Run(bytes ? bytes : NotFound());
}

std::string OrbitDevToolsDataSource::GetMimeType(const GURL& url) {
  return MimeTypeForURL(url);
}

std::string OrbitDevToolsDataSource::GetContentSecurityPolicy(
    network::mojom::CSPDirectiveName directive) {
  switch (directive) {
    case network::mojom::CSPDirectiveName::ObjectSrc:
      return "object-src 'none';";
    case network::mojom::CSPDirectiveName::ScriptSrc:
      // No remote origin, unlike chrome/'s equivalent: Orbit only ever serves
      // the bundled frontend.
      return "script-src 'self';";
    default:
      return std::string();
  }
}

bool OrbitDevToolsDataSource::ShouldDenyXFrameOptions() {
  return false;
}

bool OrbitDevToolsDataSource::ShouldServeMimeTypeAsContentTypeHeader() {
  return true;
}

OrbitDevToolsUI::OrbitDevToolsUI(content::WebUI* web_ui)
    : WebUIController(web_ui) {
  // No Mojo/WebUI bindings: the frontend talks to the browser only through
  // DevToolsFrontendHost, which OrbitDevToolsBindings installs.
  web_ui->SetBindings(content::BindingsPolicySet());
  content::URLDataSource::Add(
      web_ui->GetWebContents()->GetBrowserContext(),
      std::make_unique<OrbitDevToolsDataSource>());
}

OrbitDevToolsUI::~OrbitDevToolsUI() = default;

// static
OrbitWebUIControllerFactory* OrbitWebUIControllerFactory::GetInstance() {
  static base::NoDestructor<OrbitWebUIControllerFactory> instance;
  return instance.get();
}

std::unique_ptr<content::WebUIController>
OrbitWebUIControllerFactory::CreateWebUIControllerForURL(content::WebUI* web_ui,
                                                         const GURL& url) {
  if (!IsOrbitDevToolsURL(url)) {
    return nullptr;
  }
  return std::make_unique<OrbitDevToolsUI>(web_ui);
}

content::WebUI::TypeID OrbitWebUIControllerFactory::GetWebUIType(
    content::BrowserContext* browser_context,
    const GURL& url) {
  if (!IsOrbitDevToolsURL(url)) {
    return content::WebUI::kNoWebUI;
  }
  static int devtools_type = 0;
  return reinterpret_cast<content::WebUI::TypeID>(&devtools_type);
}

bool OrbitWebUIControllerFactory::UseWebUIForURL(
    content::BrowserContext* browser_context,
    const GURL& url) {
  return IsOrbitDevToolsURL(url);
}

}  // namespace orbit
