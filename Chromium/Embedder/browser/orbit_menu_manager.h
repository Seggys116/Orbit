// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.contextMenus' model, ported from chrome/browser/extensions/
// menu_manager.h. Two deliberate simplifications: no <webview> key (Orbit
// hosts no guest views, so an item is keyed by extension id alone) and no
// incognito flag (OrbitBrowserContext::IsOffTheRecord is always false).

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_MENU_MANAGER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_MENU_MANAGER_H_

#include <stdint.h>

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/common/url_pattern_set.h"

namespace content {
class BrowserContext;
class RenderFrameHost;
class WebContents;
struct ContextMenuParams;
}  // namespace content

namespace extensions {
class Extension;
class StateStore;
}  // namespace extensions

namespace orbit {

// Exactly one of `uid` and `string_uid` is set: a numeric id comes from the
// renderer's own GetNextContextMenuId(), a string one from createProperties.id.
struct OrbitMenuItemId {
  OrbitMenuItemId();
  explicit OrbitMenuItemId(const std::string& extension_id);
  OrbitMenuItemId(const OrbitMenuItemId&);
  OrbitMenuItemId& operator=(const OrbitMenuItemId&);
  ~OrbitMenuItemId();

  friend bool operator==(const OrbitMenuItemId&,
                         const OrbitMenuItemId&) = default;
  bool operator<(const OrbitMenuItemId& other) const;

  std::string extension_id;
  int uid = 0;
  std::string string_uid;
};

class OrbitMenuItem {
 public:
  using OwnedList = std::vector<std::unique_ptr<OrbitMenuItem>>;
  using List = std::vector<OrbitMenuItem*>;

  // A bitmask; values match MenuItem::Context so a stored contexts int written
  // by one build reads back the same in the next.
  enum Context {
    ALL = 1,
    PAGE = 2,
    SELECTION = 4,
    LINK = 8,
    EDITABLE = 16,
    IMAGE = 32,
    VIDEO = 64,
    AUDIO = 128,
    FRAME = 256,
    LAUNCHER = 512,
    BROWSER_ACTION = 1024,
    PAGE_ACTION = 2048,
    ACTION = 4096,
    TAB = 8192,
  };

  enum Type { NORMAL, CHECKBOX, RADIO, SEPARATOR };

  class ContextList {
   public:
    ContextList() = default;
    explicit ContextList(Context context) : value_(context) {}
    ContextList(const ContextList& other) = default;
    ContextList& operator=(const ContextList& other) = default;

    friend constexpr bool operator==(const ContextList&,
                                     const ContextList&) = default;

    bool Contains(Context context) const { return (value_ & context) > 0; }
    void Add(Context context) { value_ |= context; }
    base::Value ToValue() const { return base::Value(static_cast<int>(value_)); }
    bool Populate(const base::Value& value);

   private:
    uint32_t value_ = 0;
  };

  OrbitMenuItem(const OrbitMenuItemId& id,
                const std::string& title,
                bool checked,
                bool visible,
                bool enabled,
                Type type,
                const ContextList& contexts);

  OrbitMenuItem(const OrbitMenuItem&) = delete;
  OrbitMenuItem& operator=(const OrbitMenuItem&) = delete;

  ~OrbitMenuItem();

  const std::string& extension_id() const { return id_.extension_id; }
  const std::string& title() const { return title_; }
  const OwnedList& children() const { return children_; }
  const OrbitMenuItemId& id() const { return id_; }
  OrbitMenuItemId* parent_id() const { return parent_id_.get(); }
  const ContextList& contexts() const { return contexts_; }
  Type type() const { return type_; }
  bool checked() const { return checked_; }
  bool visible() const { return visible_; }
  bool enabled() const { return enabled_; }
  const extensions::URLPatternSet& document_url_patterns() const {
    return document_url_patterns_;
  }
  const extensions::URLPatternSet& target_url_patterns() const {
    return target_url_patterns_;
  }

  void set_title(const std::string& new_title) { title_ = new_title; }
  void set_contexts(ContextList contexts) { contexts_ = contexts; }
  void set_type(Type type) { type_ = type; }
  void set_visible(bool visible) { visible_ = visible; }
  void set_enabled(bool enabled) { enabled_ = enabled; }

  // Every %s replaced by `selection`, truncated to `max_length` characters.
  std::string TitleWithReplacement(const std::string& selection,
                                   size_t max_length) const;

  // False, leaving the state alone, for a NORMAL or SEPARATOR item.
  bool SetChecked(bool checked);

  base::DictValue ToValue() const;

  static std::unique_ptr<OrbitMenuItem> Populate(
      const std::string& extension_id,
      const base::DictValue& value,
      std::string* error);

  bool PopulateURLPatterns(const std::vector<std::string>* document_url_patterns,
                           const std::vector<std::string>* target_url_patterns,
                           std::string* error);

 private:
  friend class OrbitMenuManager;

  void AddChild(std::unique_ptr<OrbitMenuItem> item);
  std::unique_ptr<OrbitMenuItem> ReleaseChild(const OrbitMenuItemId& child_id,
                                              bool recursive);
  void GetFlattenedSubtree(List* list);
  std::set<OrbitMenuItemId> RemoveAllDescendants();

  OrbitMenuItemId id_;
  std::string title_;
  Type type_;
  bool checked_;
  bool visible_;
  bool enabled_;
  ContextList contexts_;
  std::unique_ptr<OrbitMenuItemId> parent_id_;
  extensions::URLPatternSet document_url_patterns_;
  extensions::URLPatternSet target_url_patterns_;
  OwnedList children_;
};

class OrbitMenuManager : public extensions::ExtensionRegistryObserver {
 public:
  // The legacy per-item onclick event, still the one
  // extensions/renderer/resources/context_menus_handlers.js listens on.
  static const char kOnContextMenus[];
  static const char kOnClicked[];
  static constexpr OrbitMenuItem::OwnedList::size_type kMaxItemsPerExtension =
      1000;
  // ContextMenuMatcher::kMaxExtensionItemTitleLength.
  static constexpr size_t kMaxItemTitleLength = 75;

  static OrbitMenuManager& GetInstance();

  OrbitMenuManager(const OrbitMenuManager&) = delete;
  OrbitMenuManager& operator=(const OrbitMenuManager&) = delete;

  // Called once the single OrbitBrowserContext exists, and again as it goes
  // away -- see OrbitBrowserMainParts.
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();

  content::BrowserContext* browser_context() const { return browser_context_; }

  std::set<std::string> ExtensionIds() const;

  // Top-level items only; children hang off these.
  const OrbitMenuItem::OwnedList* MenuItems(
      const std::string& extension_id) const;
  OrbitMenuItem::OwnedList::size_type MenuItemsSize(
      const std::string& extension_id) const;

  bool AddContextItem(const extensions::Extension* extension,
                      std::unique_ptr<OrbitMenuItem> item);
  bool AddChildItem(const OrbitMenuItemId& parent_id,
                    std::unique_ptr<OrbitMenuItem> child);
  // Null `parent_id` moves `child_id` back to the top level.
  bool ChangeParent(const OrbitMenuItemId& child_id,
                    const OrbitMenuItemId* parent_id);
  bool RemoveContextMenuItem(const OrbitMenuItemId& id);
  void RemoveAllContextItems(const std::string& extension_id);
  OrbitMenuItem* GetItemById(const OrbitMenuItemId& id) const;
  bool ItemUpdated(const OrbitMenuItemId& id);

  // Fires the item's onClicked (and the legacy per-item onclick), toggling
  // checkbox/radio state first. `web_contents`/`render_frame_host` are the
  // frame the menu was opened in; both may be null in a headless selftest.
  void ExecuteCommand(content::WebContents* web_contents,
                      content::RenderFrameHost* render_frame_host,
                      const content::ContextMenuParams& params,
                      const OrbitMenuItemId& menu_item_id);

  // The items of every enabled extension that match `params`, in the shape
  // Swift's own menu builder consumes:
  // [{"extensionId":str,"extensionName":str,"items":[Item...]}], where Item is
  // {"id":{"extensionId":..,"uid":int|"stringUid":str},"title":str,
  //  "type":"normal"|"checkbox"|"radio"|"separator","checked":bool,
  //  "enabled":bool,"children":[Item...]}. Titles already have %s replaced and
  //  are truncated; invisible and non-matching items are already dropped.
  base::ListValue MatchingItemsValue(
      const content::ContextMenuParams& params) const;

  void WriteToStorage(const extensions::Extension* extension);
  void ReadFromStorage(const std::string& extension_id,
                       std::optional<base::Value> value);

  // extensions::ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext* browser_context,
                         const extensions::Extension* extension) override;
  void OnExtensionUnloaded(content::BrowserContext* browser_context,
                           const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason reason) override;

 private:
  friend class base::NoDestructor<OrbitMenuManager>;

  OrbitMenuManager();
  ~OrbitMenuManager() override;

  void RadioItemSelected(OrbitMenuItem* item);
  void SanitizeRadioListsInMenu(const OrbitMenuItem::OwnedList& item_list);
  bool DescendantOf(OrbitMenuItem* item, const OrbitMenuItemId& ancestor_id);
  void WriteToStorageInternal(const std::string& extension_id);
  extensions::StateStore* GetStateStore() const;

  // Recurses into children, dropping invisible and non-matching items exactly
  // as ContextMenuMatcher::GetRelevantExtensionItems does.
  base::ListValue MatchingItemsValue(const OrbitMenuItem::List& items,
                                     const content::ContextMenuParams& params,
                                     const std::string& selection) const;

  std::map<std::string, OrbitMenuItem::OwnedList> context_items_;
  std::map<OrbitMenuItemId, raw_ptr<OrbitMenuItem, CtnExperimental>>
      items_by_id_;
  std::map<std::string, base::OneShotTimer> write_tasks_;

  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_observation_{this};
  raw_ptr<content::BrowserContext> browser_context_ = nullptr;

  base::WeakPtrFactory<OrbitMenuManager> weak_ptr_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_MENU_MANAGER_H_
