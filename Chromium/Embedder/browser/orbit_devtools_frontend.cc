// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/browser/orbit_devtools_frontend.h"

#include <map>
#include <memory>
#include <utility>

#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/values.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "orbit/browser/orbit_devtools_bindings.h"
#include "orbit/browser/orbit_devtools_web_ui.h"
#include "orbit/browser/orbit_web_contents_host.h"

namespace orbit {

namespace {

class OrbitDevToolsSession;

std::map<OrbitWebContentsHost*, OrbitDevToolsSession*>& SessionsByInspected() {
  static base::NoDestructor<std::map<OrbitWebContentsHost*, OrbitDevToolsSession*>>
      map;
  return *map;
}

std::map<OrbitWebContentsHost*, OrbitDevToolsSession*>& SessionsByFrontend() {
  static base::NoDestructor<std::map<OrbitWebContentsHost*, OrbitDevToolsSession*>>
      map;
  return *map;
}

class OrbitDevToolsSession : public content::WebContentsObserver,
                             public OrbitDevToolsBindings::Delegate {
 public:
  OrbitDevToolsSession(OrbitWebContentsHost* inspected,
                       OrbitWebContentsHost* frontend)
      : content::WebContentsObserver(frontend->web_contents()),
        inspected_(inspected),
        frontend_(frontend),
        bindings_(std::make_unique<OrbitDevToolsBindings>(
            frontend->web_contents(),
            inspected->web_contents(),
            this)) {
    SessionsByInspected()[inspected] = this;
    SessionsByFrontend()[frontend] = this;
  }

  OrbitDevToolsSession(const OrbitDevToolsSession&) = delete;
  OrbitDevToolsSession& operator=(const OrbitDevToolsSession&) = delete;

  ~OrbitDevToolsSession() override {
    if (inspected_) {
      SessionsByInspected().erase(inspected_);
    }
    SessionsByFrontend().erase(frontend_);
  }

  OrbitDevToolsBindings* bindings() { return bindings_.get(); }
  OrbitWebContentsHost* frontend() { return frontend_; }

  void ForgetInspected() {
    bindings_->OnInspectedContentsGone();
    SessionsByInspected().erase(inspected_);
    inspected_ = nullptr;
  }

  // content::WebContentsObserver (the frontend's WebContents):
  void PrimaryMainDocumentElementAvailable() override { bindings_->Attach(); }
  void WebContentsDestroyed() override { delete this; }

  // OrbitDevToolsBindings::Delegate:
  void OnDevToolsAgentHostClosed() override {
    if (inspected_) {
      inspected_->NotifyDevToolsClosed();
    }
  }

  void OnDevToolsDockedChanged(bool is_docked) override {
    if (inspected_) {
      inspected_->NotifyDevToolsDockedChanged(is_docked);
    }
  }

  void OnDevToolsInspectedPageBounds(int x,
                                     int y,
                                     int width,
                                     int height,
                                     bool hide_inspected_page) override {
    if (inspected_) {
      inspected_->NotifyDevToolsInspectedPageBounds(x, y, width, height,
                                                    hide_inspected_page);
    }
  }

  void OnDevToolsCloseRequested() override {
    if (inspected_) {
      inspected_->NotifyDevToolsCloseRequested();
    }
  }

  void OnDevToolsBringToFront() override {
    if (inspected_) {
      inspected_->NotifyDevToolsBringToFront();
    }
  }

 private:
  raw_ptr<OrbitWebContentsHost> inspected_;
  raw_ptr<OrbitWebContentsHost> frontend_;
  std::unique_ptr<OrbitDevToolsBindings> bindings_;
};

OrbitDevToolsSession* SessionFor(OrbitWebContentsHost* inspected) {
  auto it = SessionsByInspected().find(inspected);
  return it == SessionsByInspected().end() ? nullptr : it->second;
}

}  // namespace

OrbitWebContentsHost* OpenDevToolsFor(OrbitWebContentsHost* inspected,
                                      bool has_inspect_point,
                                      int inspect_x,
                                      int inspect_y) {
  if (!inspected || SessionFor(inspected)) {
    return nullptr;
  }
  content::BrowserContext* browser_context =
      inspected->web_contents()->GetBrowserContext();
  if (!browser_context) {
    return nullptr;
  }

  auto* frontend = new OrbitWebContentsHost(browser_context);
  auto* session = new OrbitDevToolsSession(inspected, frontend);
  if (has_inspect_point) {
    session->bindings()->InspectElementAt(inspect_x, inspect_y);
  }
  frontend->LoadURL(OrbitDevToolsFrontendURL());
  return frontend;
}

OrbitWebContentsHost* DevToolsFrontendFor(OrbitWebContentsHost* inspected) {
  OrbitDevToolsSession* session = SessionFor(inspected);
  return session ? session->frontend() : nullptr;
}

void CloseDevToolsFor(OrbitWebContentsHost* inspected) {
  if (OrbitDevToolsSession* session = SessionFor(inspected)) {
    session->bindings()->Detach();
  }
}

void InspectElementInDevTools(OrbitWebContentsHost* inspected, int x, int y) {
  if (OrbitDevToolsSession* session = SessionFor(inspected)) {
    session->bindings()->InspectElementAt(x, y);
  }
}

std::string DevToolsStateJSONFor(OrbitWebContentsHost* inspected) {
  base::DictValue state;
  OrbitDevToolsSession* session = SessionFor(inspected);
  state.Set("open", session != nullptr);
  if (session) {
    OrbitDevToolsBindings* bindings = session->bindings();
    state.Set("attached", bindings->is_attached());
    state.Set("frontendURL", session->frontend()
                                 ->web_contents()
                                 ->GetLastCommittedURL()
                                 .spec());
    state.Set("commandsFromFrontend", bindings->commands_from_frontend());
    state.Set("responsesToFrontend", bindings->responses_to_frontend());
    state.Set("eventsToFrontend", bindings->events_to_frontend());
    state.Set("dockDecided", bindings->dock_decided());
    state.Set("docked", bindings->is_docked());
    state.Set("dockSide", OrbitDevToolsBindings::StoredDockSide());
    state.Set("hidesInspectedPage", bindings->hides_inspected_page());
    base::DictValue page_bounds;
    page_bounds.Set("x", bindings->inspected_page_x());
    page_bounds.Set("y", bindings->inspected_page_y());
    page_bounds.Set("width", bindings->inspected_page_width());
    page_bounds.Set("height", bindings->inspected_page_height());
    state.Set("inspectedPageBounds", std::move(page_bounds));
  }
  return base::WriteJson(state).value_or("{}");
}

void NotifyWebContentsHostDestroyed(OrbitWebContentsHost* host) {
  auto frontend_it = SessionsByFrontend().find(host);
  if (frontend_it != SessionsByFrontend().end()) {
    delete frontend_it->second;
    return;
  }
  if (OrbitDevToolsSession* session = SessionFor(host)) {
    session->ForgetInspected();
  }
}

}  // namespace orbit
