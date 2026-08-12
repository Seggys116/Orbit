// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// The CDP pipe between a bundled DevTools frontend WebContents and the
// content::DevToolsAgentHost of the inspected page. Adapted from
// shell_devtools_bindings.{h,cc}, minus content_shell's HTTP-served frontend.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_BINDINGS_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_BINDINGS_H_

#include <map>
#include <memory>
#include <set>
#include <string>

#include "base/containers/span.h"
#include "base/containers/unique_ptr_adapters.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/devtools_frontend_host.h"
#include "content/public/browser/web_contents_observer.h"

namespace content {
class NavigationHandle;
class WebContents;
}  // namespace content

namespace orbit {

class OrbitDevToolsBindings : public content::WebContentsObserver,
                              public content::DevToolsAgentHostClient {
 public:
  class Delegate {
   public:
    // The agent host went away on its own (renderer gone, target closed).
    virtual void OnDevToolsAgentHostClosed() = 0;

    // The frontend picked docked or undocked, from its own Dock side menu or
    // from the stored currentDockState as it loads. Nothing is presented
    // before the first of these, matching chrome/'s own lifecycle.
    virtual void OnDevToolsDockedChanged(bool is_docked) = 0;

    // Where the inspected page is drawn on the frontend's view, in DIPs,
    // top-left origin. Empty bounds at origin means hidden entirely.
    virtual void OnDevToolsInspectedPageBounds(int x,
                                               int y,
                                               int width,
                                               int height,
                                               bool hide_inspected_page) = 0;

    // The inspector's own close button.
    virtual void OnDevToolsCloseRequested() = 0;

    virtual void OnDevToolsBringToFront() = 0;

   protected:
    virtual ~Delegate() = default;
  };

  // `devtools_contents` hosts the bundled frontend; `inspected_contents` is
  // the page being debugged. Neither is owned.
  OrbitDevToolsBindings(content::WebContents* devtools_contents,
                        content::WebContents* inspected_contents,
                        Delegate* delegate);
  OrbitDevToolsBindings(const OrbitDevToolsBindings&) = delete;
  OrbitDevToolsBindings& operator=(const OrbitDevToolsBindings&) = delete;
  ~OrbitDevToolsBindings() override;

  void Attach();
  void Detach();
  void InspectElementAt(int x, int y);

  // Resolves the frame to inspect, falling back to the primary main frame when
  // nothing holds focus. InspectElement dereferences the frame it is given.
  void InspectElementInFrame(int x, int y);

  // Stops referencing the inspected page. Called when it is about to be
  // destroyed, so nothing here can outlive it.
  void OnInspectedContentsGone();

  bool is_attached() const { return agent_host_ != nullptr; }

  // The frontend's persisted currentDockState; "right" until it says
  // otherwise. Process-global, like the preference store itself.
  static std::string StoredDockSide();

  // False until the frontend's first setIsDocked, the point chrome/ also waits
  // for before presenting anything.
  bool dock_decided() const { return dock_decided_; }
  bool is_docked() const { return is_docked_; }
  bool hides_inspected_page() const { return hide_inspected_page_; }
  int inspected_page_x() const { return inspected_page_x_; }
  int inspected_page_y() const { return inspected_page_y_; }
  int inspected_page_width() const { return inspected_page_width_; }
  int inspected_page_height() const { return inspected_page_height_; }

  // Counters over the CDP pipe itself, for OrbitWebContentsDevToolsStateJSON:
  // CDP commands the frontend sent, and the responses/events it got back.
  int commands_from_frontend() const { return commands_from_frontend_; }
  int responses_to_frontend() const { return responses_to_frontend_; }
  int events_to_frontend() const { return events_to_frontend_; }

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost* agent_host,
                               base::span<const uint8_t> message) override;
  void AgentHostClosed(content::DevToolsAgentHost* agent_host) override;
  bool MayAccessAllCookies() override;

 private:
  class NetworkResourceLoader;

  // content::WebContentsObserver (on the frontend WebContents):
  void ReadyToCommitNavigation(
      content::NavigationHandle* navigation_handle) override;
  void WebContentsDestroyed() override;

  void HandleMessageFromDevToolsFrontend(base::DictValue message);
  void NotifyCloseRequested();
  void CallClientFunction(const std::string& object_name,
                          const std::string& method_name,
                          base::Value arg1 = {},
                          base::Value arg2 = {},
                          base::Value arg3 = {});
  void SendMessageAck(int request_id, base::DictValue arg);

  raw_ptr<content::WebContents> inspected_contents_;
  raw_ptr<Delegate> delegate_;
  scoped_refptr<content::DevToolsAgentHost> agent_host_;
  std::unique_ptr<content::DevToolsFrontendHost> frontend_host_;

  int inspect_element_at_x_ = -1;
  int inspect_element_at_y_ = -1;

  bool dock_decided_ = false;
  bool is_docked_ = false;
  bool hide_inspected_page_ = false;
  int inspected_page_x_ = 0;
  int inspected_page_y_ = 0;
  int inspected_page_width_ = 0;
  int inspected_page_height_ = 0;

  int commands_from_frontend_ = 0;
  int responses_to_frontend_ = 0;
  int events_to_frontend_ = 0;

  std::set<std::unique_ptr<NetworkResourceLoader>, base::UniquePtrComparator>
      loaders_;

  // origin -> extension API bootstrap script, per registerExtensionsAPI.
  std::map<std::string, std::string> extensions_api_;

  // getPreferences is answered after an off-thread read of the stored
  // preferences file, which can outlive this frontend.
  base::WeakPtrFactory<OrbitDevToolsBindings> weak_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_BINDINGS_H_
