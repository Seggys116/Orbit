// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/browser/orbit_devtools_bindings.h"

#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/notreached.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/uuid.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/cpp/simple_url_loader_stream_consumer.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace orbit {

namespace {

// IPC::mojom::kChannelMaximumMessageSize / 4 (ipc/constants.mojom), matching
// chrome/'s and content_shell's own chunk size.
constexpr size_t kMaxMessageChunkSize = 134217728 / 4;

// Panel layout, theme, "preserve log", breakpoints... Process-global and
// persisted; without it every inspector opens with factory defaults.
class DevToolsPreferences {
 public:
  static DevToolsPreferences& Get() {
    static base::NoDestructor<DevToolsPreferences> instance;
    return *instance;
  }

  DevToolsPreferences();
  ~DevToolsPreferences();

  // Reading the backing file blocks, which the UI thread forbids (FATAL
  // DCHECK in debug); the read happens on the thread pool instead.
  void GetAll(base::OnceCallback<void(base::DictValue)> callback) {
    if (loaded_) {
      std::move(callback).Run(values_.Clone());
      return;
    }
    pending_.push_back(std::move(callback));
    StartLoad();
  }

  void Set(const std::string& name, base::Value value) {
    values_.Set(name, std::move(value));
    SaveWhenLoaded();
  }

  void Remove(const std::string& name) {
    values_.Remove(name);
    SaveWhenLoaded();
  }

  // Every value is stored JSON-encoded (see ApplyEmbedderDefaults), so the
  // dock side is on disk as "\"right\"" rather than as right.
  std::string DockSide() {
    const std::string* raw = values_.FindString("currentDockState");
    if (!raw) {
      return "right";
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(*raw, base::JSON_PARSE_RFC);
    const std::string* side = parsed ? parsed->GetIfString() : nullptr;
    return side ? *side : "right";
  }

 private:
  static base::FilePath StoragePath() {
    content::BrowserContext* context = GetOrbitBrowserContext();
    return context ? context->GetPath().AppendASCII("DevTools Preferences")
                   : base::FilePath();
  }

  static base::DictValue ReadStoredValues(base::FilePath path) {
    std::string contents;
    if (path.empty() || !base::ReadFileToString(path, &contents)) {
      return base::DictValue();
    }
    std::optional<base::DictValue> parsed =
        base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
    return parsed ? std::move(*parsed) : base::DictValue();
  }

  void StartLoad() {
    if (loading_) {
      return;
    }
    loading_ = true;
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
        base::BindOnce(&DevToolsPreferences::ReadStoredValues, StoragePath()),
        base::BindOnce(&DevToolsPreferences::OnLoaded,
                       base::Unretained(this)));
  }

  // Anything the frontend wrote while the read was in flight is the newer
  // value and outranks what was on disk.
  void OnLoaded(base::DictValue stored) {
    for (auto entry : values_) {
      stored.Set(entry.first, std::move(entry.second));
    }
    values_ = std::move(stored);
    ApplyEmbedderDefaults();
    loaded_ = true;
    loading_ = false;

    std::vector<base::OnceCallback<void(base::DictValue)>> pending;
    pending.swap(pending_);
    for (auto& callback : pending) {
      std::move(callback).Run(values_.Clone());
    }

    if (save_when_loaded_) {
      save_when_loaded_ = false;
      Save();
    }
  }

  // Values are JSON-encoded per key. "chrome-theme-colors" defaults true in
  // the frontend, but Orbit serves no theme:// host so its stylesheet link
  // never loads and no onerror is registered -- force it off. Only fills
  // keys the user hasn't already set.
  void ApplyEmbedderDefaults() {
    if (!values_.Find("chrome-theme-colors")) {
      values_.Set("chrome-theme-colors", base::Value("false"));
    }
  }

  // Writing before the stored file has been read would truncate it to
  // whichever keys the frontend happened to set first.
  void SaveWhenLoaded() {
    if (!loaded_) {
      save_when_loaded_ = true;
      StartLoad();
      return;
    }
    Save();
  }

  void Save() {
    const base::FilePath path = StoragePath();
    std::optional<std::string> json = base::WriteJson(values_);
    if (path.empty() || !json) {
      return;
    }
    base::ThreadPool::PostTask(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
        base::BindOnce(
            [](base::FilePath target, std::string body) {
              base::WriteFile(target, body);
            },
            path, std::move(*json)));
  }

  base::DictValue values_;
  std::vector<base::OnceCallback<void(base::DictValue)>> pending_;
  bool loaded_ = false;
  bool loading_ = false;
  bool save_when_loaded_ = false;
};

DevToolsPreferences::DevToolsPreferences() = default;
DevToolsPreferences::~DevToolsPreferences() = default;

base::DictValue BuildObjectForResponse(const net::HttpResponseHeaders* rh,
                                       bool success,
                                       int net_error) {
  base::DictValue response;
  int response_code = 200;
  if (rh) {
    response_code = rh->response_code();
  } else if (!success) {
    response_code = 404;
  }
  response.Set("statusCode", response_code);
  response.Set("netError", net_error);
  response.Set("netErrorName", net::ErrorToString(net_error));

  base::DictValue headers;
  size_t iterator = 0;
  std::string name;
  std::string value;
  while (rh && rh->EnumerateHeaderLines(&iterator, &name, &value)) {
    headers.Set(name, value);
  }
  response.Set("headers", std::move(headers));
  return response;
}

}  // namespace

// Streams one loadNetworkResource fetch (source maps, mostly) back to the
// frontend in chunks.
class OrbitDevToolsBindings::NetworkResourceLoader
    : public network::SimpleURLLoaderStreamConsumer {
 public:
  NetworkResourceLoader(int stream_id,
                        int request_id,
                        OrbitDevToolsBindings* bindings,
                        std::unique_ptr<network::SimpleURLLoader> loader,
                        network::mojom::URLLoaderFactory* url_loader_factory)
      : stream_id_(stream_id),
        request_id_(request_id),
        bindings_(bindings),
        loader_(std::move(loader)) {
    loader_->SetOnResponseStartedCallback(base::BindOnce(
        &NetworkResourceLoader::OnResponseStarted, base::Unretained(this)));
    loader_->DownloadAsStream(url_loader_factory, this);
  }

  NetworkResourceLoader(const NetworkResourceLoader&) = delete;
  NetworkResourceLoader& operator=(const NetworkResourceLoader&) = delete;

 private:
  void OnResponseStarted(const GURL& final_url,
                         const network::mojom::URLResponseHead& response_head) {
    response_headers_ = response_head.headers;
  }

  void OnDataReceived(std::string_view chunk, base::OnceClosure resume) override {
    const bool encoded = !base::IsStringUTF8(chunk);
    base::Value chunk_value =
        encoded ? base::Value(base::Base64Encode(chunk)) : base::Value(chunk);
    bindings_->CallClientFunction("DevToolsAPI", "streamWrite",
                                  base::Value(stream_id_),
                                  std::move(chunk_value), base::Value(encoded));
    std::move(resume).Run();
  }

  void OnComplete(bool success) override {
    bindings_->SendMessageAck(
        request_id_, BuildObjectForResponse(response_headers_.get(), success,
                                            loader_->NetError()));
    bindings_->loaders_.erase(bindings_->loaders_.find(this));
  }

  void OnRetry(base::OnceClosure start_retry) override { NOTREACHED(); }

  const int stream_id_;
  const int request_id_;
  const raw_ptr<OrbitDevToolsBindings> bindings_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  scoped_refptr<net::HttpResponseHeaders> response_headers_;
};

OrbitDevToolsBindings::OrbitDevToolsBindings(
    content::WebContents* devtools_contents,
    content::WebContents* inspected_contents,
    Delegate* delegate)
    : content::WebContentsObserver(devtools_contents),
      inspected_contents_(inspected_contents),
      delegate_(delegate) {}

OrbitDevToolsBindings::~OrbitDevToolsBindings() {
  Detach();
}

void OrbitDevToolsBindings::NotifyCloseRequested() {
  if (delegate_) {
    delegate_->OnDevToolsCloseRequested();
  }
}

// static
std::string OrbitDevToolsBindings::StoredDockSide() {
  return DevToolsPreferences::Get().DockSide();
}

void OrbitDevToolsBindings::Attach() {
  if (!inspected_contents_) {
    return;
  }
  Detach();
  agent_host_ = content::DevToolsAgentHost::GetOrCreateForTab(
      inspected_contents_);
  agent_host_->AttachClient(this);
  if (inspect_element_at_x_ != -1) {
    InspectElementInFrame(inspect_element_at_x_, inspect_element_at_y_);
    inspect_element_at_x_ = -1;
    inspect_element_at_y_ = -1;
  }
}

void OrbitDevToolsBindings::Detach() {
  if (agent_host_) {
    agent_host_->DetachClient(this);
    agent_host_ = nullptr;
  }
}

// GetFocusedFrame() is null whenever nothing has focus (the ordinary state
// right after the main document loads); InspectElement dereferences it.
void OrbitDevToolsBindings::InspectElementInFrame(int x, int y) {
  if (!agent_host_ || !inspected_contents_) {
    return;
  }
  content::RenderFrameHost* frame = inspected_contents_->GetFocusedFrame();
  if (!frame) {
    frame = inspected_contents_->GetPrimaryMainFrame();
  }
  if (!frame) {
    return;
  }
  agent_host_->InspectElement(frame, x, y);
}

void OrbitDevToolsBindings::InspectElementAt(int x, int y) {
  if (agent_host_ && inspected_contents_) {
    InspectElementInFrame(x, y);
    return;
  }
  inspect_element_at_x_ = x;
  inspect_element_at_y_ = y;
}

void OrbitDevToolsBindings::OnInspectedContentsGone() {
  Detach();
  inspected_contents_ = nullptr;
}

void OrbitDevToolsBindings::ReadyToCommitNavigation(
    content::NavigationHandle* navigation_handle) {
  content::RenderFrameHost* frame = navigation_handle->GetRenderFrameHost();
  if (navigation_handle->IsInPrimaryMainFrame()) {
    frontend_host_ = content::DevToolsFrontendHost::Create(
        frame,
        base::BindRepeating(
            &OrbitDevToolsBindings::HandleMessageFromDevToolsFrontend,
            base::Unretained(this)));
    return;
  }
  const std::string origin =
      navigation_handle->GetURL().DeprecatedGetOriginAsURL().spec();
  auto it = extensions_api_.find(origin);
  if (it == extensions_api_.end()) {
    return;
  }
  content::DevToolsFrontendHost::SetupExtensionsAPI(
      frame, base::StringPrintf(
                 "%s(\"%s\")", it->second.c_str(),
                 base::Uuid::GenerateRandomV4().AsLowercaseString().c_str()));
}

void OrbitDevToolsBindings::WebContentsDestroyed() {
  Detach();
}

void OrbitDevToolsBindings::AgentHostClosed(
    content::DevToolsAgentHost* agent_host) {
  agent_host_ = nullptr;
  if (delegate_) {
    delegate_->OnDevToolsAgentHostClosed();
  }
}

bool OrbitDevToolsBindings::MayAccessAllCookies() {
  // The frontend is Orbit's own bundled resource, never a remote origin (see
  // orbit_devtools_web_ui.h), so it is as trusted as the browser process.
  return true;
}

void OrbitDevToolsBindings::DispatchProtocolMessage(
    content::DevToolsAgentHost* agent_host,
    base::span<const uint8_t> message) {
  std::string_view str_message(reinterpret_cast<const char*>(message.data()),
                               message.size());
  // CDP serialises command replies with "id" first and events with "method"
  // first, so this classifies without parsing the payload.
  if (base::StartsWith(str_message, "{\"id\":")) {
    ++responses_to_frontend_;
  } else {
    ++events_to_frontend_;
  }

  if (str_message.length() < kMaxMessageChunkSize) {
    CallClientFunction("DevToolsAPI", "dispatchMessage",
                       base::Value(std::string(str_message)));
    return;
  }
  const size_t total_size = str_message.length();
  for (size_t pos = 0; pos < str_message.length(); pos += kMaxMessageChunkSize) {
    CallClientFunction(
        "DevToolsAPI", "dispatchMessageChunk",
        base::Value(std::string(str_message.substr(pos, kMaxMessageChunkSize))),
        base::Value(base::NumberToString(pos ? 0 : total_size)));
  }
}

void OrbitDevToolsBindings::HandleMessageFromDevToolsFrontend(
    base::DictValue message) {
  const std::string* method = message.FindString("method");
  if (!method) {
    return;
  }

  const int request_id = message.FindInt("id").value_or(0);
  base::ListValue params;
  if (base::ListValue* params_value = message.FindList("params")) {
    params = std::move(*params_value);
  }

  if (*method == "dispatchProtocolMessage" && params.size() == 1) {
    const std::string* protocol_message = params[0].GetIfString();
    if (!agent_host_ || !protocol_message) {
      return;
    }
    ++commands_from_frontend_;
    agent_host_->DispatchProtocolMessage(this,
                                         base::as_byte_span(*protocol_message));
  } else if (*method == "loadCompleted") {
    CallClientFunction("DevToolsAPI", "setUseSoftMenu", base::Value(true));
  } else if (*method == "setIsDocked") {
    // Must fall through to the ack below on every path, malformed params
    // included: the frontend drops setInspectedPageBounds until it's acked,
    // so a swallowed ack freezes the docked layout after one dock change.
    const bool docked =
        params.size() == 1 && params[0].is_bool() && params[0].GetBool();
    const bool changed = !dock_decided_ || is_docked_ != docked;
    dock_decided_ = true;
    is_docked_ = docked;
    if (changed && delegate_) {
      delegate_->OnDevToolsDockedChanged(docked);
    }
  } else if (*method == "setInspectedPageBounds" && params.size() == 1) {
    if (const base::DictValue* bounds = params[0].GetIfDict()) {
      inspected_page_x_ = bounds->FindInt("x").value_or(0);
      inspected_page_y_ = bounds->FindInt("y").value_or(0);
      inspected_page_width_ = bounds->FindInt("width").value_or(0);
      inspected_page_height_ = bounds->FindInt("height").value_or(0);
      hide_inspected_page_ =
          (inspected_page_width_ <= 0 || inspected_page_height_ <= 0) &&
          inspected_page_x_ == 0 && inspected_page_y_ == 0;
      if (delegate_) {
        delegate_->OnDevToolsInspectedPageBounds(
            inspected_page_x_, inspected_page_y_, inspected_page_width_,
            inspected_page_height_, hide_inspected_page_);
      }
    }
  } else if (*method == "closeWindow") {
    // Never synchronously: the embedder destroys the frontend WebContents
    // (and this object) in response, so the ack below would run on freed memory.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OrbitDevToolsBindings::NotifyCloseRequested,
                                  weak_factory_.GetWeakPtr()));
  } else if (*method == "bringToFront") {
    if (delegate_) {
      delegate_->OnDevToolsBringToFront();
    }
  } else if (*method == "inspectedURLChanged" || *method == "inspectElementCompleted") {
    // Handled so they reach the ack below rather than the unknown-method
    // return; Orbit has nothing of its own to do for either.
  } else if (*method == "loadNetworkResource" && params.size() == 3) {
    const std::string* url = params[0].GetIfString();
    const std::string* headers = params[1].GetIfString();
    const std::optional<int> stream_id = params[2].GetIfInt();
    if (!url || !headers || !stream_id.has_value() || !inspected_contents_) {
      return;
    }
    GURL gurl(*url);
    if (!gurl.is_valid()) {
      base::DictValue response;
      response.Set("statusCode", 404);
      response.Set("urlValid", false);
      SendMessageAck(request_id, std::move(response));
      return;
    }

    net::NetworkTrafficAnnotationTag traffic_annotation =
        net::DefineNetworkTrafficAnnotation("orbit_devtools_frontend_resource",
                                            R"(
            semantics {
              sender: "Developer Tools"
              description:
                "When the user opens Developer Tools, the browser may fetch "
                "additional resources from the network to enrich the "
                "debugging experience (e.g. source map resources)."
              trigger: "User opens Developer Tools to debug a web page."
              data: "Any resources requested by Developer Tools."
              destination: OTHER
            }
            policy {
              cookies_allowed: YES
              cookies_store: "user"
              setting: "It's not possible to disable this feature from settings."
              policy_exception_justification: "Not implemented."
            })");

    auto resource_request = std::make_unique<network::ResourceRequest>();
    resource_request->url = gurl;
    resource_request->site_for_cookies = net::SiteForCookies::FromUrl(gurl);
    resource_request->headers.AddHeadersFromString(*headers);

    auto factory = inspected_contents_->GetPrimaryMainFrame()
                       ->GetStoragePartition()
                       ->GetURLLoaderFactoryForBrowserProcess();
    loaders_.insert(std::make_unique<NetworkResourceLoader>(
        *stream_id, request_id, this,
        network::SimpleURLLoader::Create(std::move(resource_request),
                                        traffic_annotation),
        factory.get()));
    return;
  } else if (*method == "getPreferences") {
    DevToolsPreferences::Get().GetAll(
        base::BindOnce(&OrbitDevToolsBindings::SendMessageAck,
                       weak_factory_.GetWeakPtr(), request_id));
    return;
  } else if (*method == "getHostConfig") {
    SendMessageAck(request_id, {});
    return;
  } else if (*method == "setPreference") {
    if (params.size() < 2) {
      return;
    }
    const std::string* name = params[0].GetIfString();
    if (!name || !params[1].is_string()) {
      return;
    }
    DevToolsPreferences::Get().Set(*name, std::move(params[1]));
  } else if (*method == "removePreference") {
    if (params.empty()) {
      return;
    }
    const std::string* name = params[0].GetIfString();
    if (!name) {
      return;
    }
    DevToolsPreferences::Get().Remove(*name);
  } else if (*method == "requestFileSystems") {
    CallClientFunction("DevToolsAPI", "fileSystemsLoaded",
                       base::Value(base::Value::Type::LIST));
  } else if (*method == "reattach") {
    if (!agent_host_) {
      return;
    }
    agent_host_->DetachClient(this);
    agent_host_->AttachClient(this);
  } else if (*method == "registerExtensionsAPI") {
    if (params.size() < 2) {
      return;
    }
    const std::string* origin = params[0].GetIfString();
    const std::string* script = params[1].GetIfString();
    if (!origin || !script) {
      return;
    }
    extensions_api_[*origin + "/"] = *script;
  } else {
    return;
  }

  if (request_id) {
    SendMessageAck(request_id, {});
  }
}

void OrbitDevToolsBindings::CallClientFunction(const std::string& object_name,
                                               const std::string& method_name,
                                               base::Value arg1,
                                               base::Value arg2,
                                               base::Value arg3) {
  content::RenderFrameHost* frame = web_contents()->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive()) {
    return;
  }
  frame->AllowInjectingJavaScript();

  base::ListValue arguments;
  if (!arg1.is_none()) {
    arguments.Append(std::move(arg1));
    if (!arg2.is_none()) {
      arguments.Append(std::move(arg2));
      if (!arg3.is_none()) {
        arguments.Append(std::move(arg3));
      }
    }
  }
  frame->ExecuteJavaScriptMethod(base::ASCIIToUTF16(object_name),
                                 base::ASCIIToUTF16(method_name),
                                 std::move(arguments), base::NullCallback());
}

void OrbitDevToolsBindings::SendMessageAck(int request_id, base::DictValue arg) {
  CallClientFunction("DevToolsAPI", "embedderMessageAck",
                     base::Value(request_id), base::Value(std::move(arg)));
}

}  // namespace orbit
