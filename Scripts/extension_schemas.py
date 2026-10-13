#!/usr/bin/env python3
"""Vendors upstream Chromium extension API schemas and diffs Orbit's against them.

Schemas are vendored in OrbitTests/Fixtures/UpstreamAPISchemas. There is no Chromium
checkout and no version pin. This script diffs Orbit against that snapshot.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPSTREAM_SRC = os.path.join(REPO_ROOT, "ThirdParty", "chromium", "src")
CHROME_API_DIR = os.path.join(UPSTREAM_SRC, "chrome", "common", "extensions", "api")
CORE_API_DIR = os.path.join(UPSTREAM_SRC, "extensions", "common", "api")
CORE_PERMISSIONS_CC = os.path.join(
    UPSTREAM_SRC, "extensions", "common", "permissions", "extensions_api_permissions.cc"
)
DNR_CONSTANTS_CC = os.path.join(CORE_API_DIR, "declarative_net_request", "constants.cc")
VENDORED_PERMISSION_FEATURES = {
    "_chrome_permission_features.json": os.path.join(CHROME_API_DIR, "_permission_features.json"),
    "_core_permission_features.json": os.path.join(CORE_API_DIR, "_permission_features.json"),
}
WRAPPER_PATH = os.path.join(REPO_ROOT, "Orbit", "Engine", "WebKit", "ChromeAPIWrapperScript.swift")
VENDOR_DIR = os.path.join(REPO_ROOT, "OrbitTests", "Fixtures", "UpstreamAPISchemas")
EXPECTATIONS_PATH = os.path.join(REPO_ROOT, "OrbitTests", "Fixtures", "ExpectedAPIGaps.json")

MEMBER_KINDS = ("functions", "events", "types", "properties")
SINGULAR = {"functions": "function", "events": "event", "types": "type", "properties": "property"}

# Orbit writes every ported schema as .json; upstream writes some as .idl and,
# since 152, some as .webidl. The vendored counterpart keeps its real upstream
# name, so resolution is by basename across the three extensions.
SCHEMA_EXTENSIONS = (".json", ".idl", ".webidl")


def resolve_schema(directory, filename):
    """The real path in `directory` for Orbit's `filename`, or None."""
    stem = os.path.splitext(filename)[0]
    for extension in SCHEMA_EXTENSIONS:
        candidate = os.path.join(directory, stem + extension)
        if os.path.exists(candidate):
            return candidate
    return None

# Why each absent chrome-layer namespace is absent; anything unnamed here regenerates
# "unclassified", which ExtensionSchemaConformanceTests rejects, forcing a human to triage it.
#   notPorted      in scope, Orbit simply has not ported it (section 1.4)
#   outOfScope     ChromeOS hardware/shell, enterprise, or the Chrome Apps
#                  platform-app model Orbit does not host (section 1.5)
#   chromeInternal allowlist-only; no third-party extension can reach it
DEFAULT_REASONS = {
    "notPorted": [
        "accessibilityFeatures", "bookmarks", "browserAction", "browsingData",
        "contentSettings", "contextMenus", "debugger", "declarativeContent", "desktopCapture",
        "devtools.inspectedWindow", "devtools.network", "devtools.panels", "devtools.performance",
        "devtools.recorder", "dom", "downloads", "extension", "fontSettings", "gcm",
        "identity", "instanceID", "mdns", "notifications", "omnibox", "pageAction", "pageCapture",
        "processes", "proxy", "readingList", "sidePanel", "tabCapture",
        "tabGroups", "topSites", "tts", "ttsEngine", "webAuthenticationProxy",
    ],
    "outOfScope": [
        "appviewTag", "certificateProvider", "certificateProviderInternal", "documentScan",
        "enterprise", "enterprise.deviceAttributes", "enterprise.hardwarePlatform",
        "enterprise.kioskInput", "enterprise.login", "enterprise.networkingAttributes",
        "enterprise.platformKeys", "fileBrowserHandler", "fileSystemProvider", "input.ime",
        "login", "loginState", "manifestTypes", "platformKeys", "printing", "vpnProvider",
        "wallpaper", "webviewTag",
    ],
    "chromeInternal": [
        "accessibilityPrivate", "accessibilityServicePrivate", "activityLogPrivate",
        "autofillPrivate", "autotestPrivate", "bookmarkManagerPrivate", "brailleDisplayPrivate",
        "chromeWebViewInternal", "chromeosInfoPrivate", "commandLinePrivate",
        "contextualTasksPrivate", "crashReportPrivate", "developerPrivate", "dictationPrivate",
        "downloadsInternal", "echoPrivate", "enterprise.platformKeysInternal",
        "enterprise.platformKeysPrivate", "enterprise.reportingPrivate", "experimentalActor",
        "experimentalAiData", "fileManagerPrivate", "fileManagerPrivateInternal",
        "fileSystemProviderInternal", "glicPrivate", "idltest", "imageLoaderPrivate",
        "imageWriterPrivate", "indigoPrivate", "inputMethodPrivate", "languageSettingsPrivate",
        "loginScreenStorage", "loginScreenUi", "mediaPlayerPrivate", "odfsConfigPrivate",
        "passwordsPrivate", "pdfViewerPrivate", "platformKeysInternal", "printingMetrics",
        "proxyOverrideRulesPrivate", "quickUnlockPrivate", "resourcesPrivate",
        "safeBrowsingPrivate", "settingsPrivate", "smartCardProviderPrivate",
        "speechRecognitionPrivate", "systemLog", "systemPrivate", "terminalPrivate",
        "usersPrivate", "webrtcDesktopCapturePrivate", "webrtcLoggingPrivate", "wmDesksPrivate",
    ],
}
REASON_OF = {name: reason for reason, names in DEFAULT_REASONS.items() for name in names}


# MARK: - JSON-with-comments


def strip_comments(text):
    out = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load_schema(path):
    with open(path, encoding="utf-8") as handle:
        parsed = json.loads(strip_comments(handle.read()))
    return parsed if isinstance(parsed, list) else [parsed]


# MARK: - Namespace discovery

PARTIAL_INTERFACE = re.compile(r"partial\s+interface\s+([A-Za-z0-9_]+)\s*\{(.*?)\n\};", re.S)
STATIC_ATTRIBUTE = re.compile(r"static\s+attribute\s+([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\s*;")
IDL_NAMESPACE = re.compile(r"^\s*namespace\s+([A-Za-z0-9_.]+)\s*\{", re.M)


def schema_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("_"):
                continue
            if name.endswith((".json", ".idl", ".webidl")):
                yield os.path.join(dirpath, name)


def namespaces_in(root):
    """Every API namespace a schema directory declares.

    .json states its own `namespace`; .webidl states it structurally -- a nested
    `partial interface System { attribute CPU cpu; }` names `system.cpu`.
    """
    names = set()
    edges = {}
    for path in schema_files(root):
        base = os.path.basename(path)
        if base.endswith(".json"):
            try:
                entries = load_schema(path)
            except ValueError:
                continue
            for entry in entries:
                if isinstance(entry, dict) and entry.get("namespace"):
                    names.add(entry["namespace"])
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = re.sub(r"^\s*//.*$", "", handle.read(), flags=re.M)
        for match in IDL_NAMESPACE.finditer(text):
            names.add(match.group(1))
        for match in PARTIAL_INTERFACE.finditer(text):
            parent = match.group(1)
            for attribute in STATIC_ATTRIBUTE.finditer(match.group(2)):
                edges.setdefault(parent, []).append((attribute.group(1), attribute.group(2)))

    def walk(interface, prefix, depth, seen):
        if depth > 4 or interface in seen:
            return
        for type_name, attribute_name in edges.get(interface, []):
            full = prefix + attribute_name
            names.add(full)
            walk(type_name, full + ".", depth + 1, seen | {interface})

    walk("Browser", "", 0, frozenset())
    return names


# MARK: - Member surface


def property_paths(properties, prefix=""):
    paths = set()
    for key, value in (properties or {}).items():
        paths.add(prefix + key)
        if isinstance(value, dict) and isinstance(value.get("properties"), dict):
            paths |= property_paths(value["properties"], prefix + key + ".")
    return paths


IDL_BLOCK = re.compile(r"(dictionary|enum|interface)\s+([A-Za-z0-9_]+)\s*\{")
IDL_MEMBER = re.compile(r"static\s+[A-Za-z0-9_\[\]?]+(?:\s*\??)\s+([A-Za-z0-9_]+)\s*\(")


def idl_surface_of(path):
    """surface_of for a Chromium schema .idl.

    `callback` declarations are deliberately not types: json_schema_compiler
    folds them into the function's returns_async rather than emitting one.
    """
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = re.sub(r"^\s*//.*$", "", handle.read(), flags=re.M)
    match = IDL_NAMESPACE.search(text)
    if not match:
        return {}
    surface = {kind: set() for kind in MEMBER_KINDS}
    for block in IDL_BLOCK.finditer(text):
        kind, name = block.group(1), block.group(2)
        if kind in ("dictionary", "enum"):
            surface["types"].add(name)
            continue
        body = text[block.end():]
        depth = 1
        for index, character in enumerate(body):
            depth += (character == "{") - (character == "}")
            if depth == 0:
                body = body[:index]
                break
        target = {"Functions": "functions", "Events": "events", "Properties": "properties"}.get(name)
        if target:
            surface[target] |= {m.group(1) for m in IDL_MEMBER.finditer(body)}
    return {match.group(1): surface}


WEBIDL_DECLARATION = re.compile(r"\b(dictionary|enum|interface)\s+([A-Za-z0-9_]+)\s*(?::\s*[A-Za-z0-9_]+\s*)?\{")
WEBIDL_ATTRIBUTE = re.compile(r"static\s+attribute\s+[A-Za-z0-9_]+\s+([A-Za-z0-9_]+)\s*;")
WEBIDL_CONSTANT = re.compile(r"const\s+[A-Za-z0-9_]+\s+([A-Za-z0-9_]+)\s*=")
WEBIDL_OPERATION = re.compile(r"static\s+((?:(?!attribute)[^;{}])*?)\(")
WEBIDL_TRAILING_NAME = re.compile(r"([A-Za-z0-9_]+)\s*$")


def _braced_body(text, start):
    depth, index = 1, start
    while index < len(text) and depth:
        depth += (text[index] == "{") - (text[index] == "}")
        index += 1
    return text[start:index - 1]


def webidl_surface_of(path):
    """surface_of for a Chromium schema .webidl.

    The namespace is whatever `partial interface Browser` binds an attribute to,
    and that attribute's interface type carries the functions and events. Only
    dictionaries and enums are types: the per-event `interface FooEvent` and its
    `callback FooListener` are plumbing json_schema_compiler never emits.
    """
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = re.sub(r"^\s*//.*$", "", handle.read(), flags=re.M)

    bodies, surface = {}, {kind: set() for kind in MEMBER_KINDS}
    for match in WEBIDL_DECLARATION.finditer(text):
        kind, name = match.group(1), match.group(2)
        if kind == "interface":
            bodies[name] = _braced_body(text, match.end())
        else:
            surface["types"].add(name)

    namespace = None
    for parent, members in (("Browser", bodies.get("Browser", "")),):
        for attribute in re.finditer(r"static\s+attribute\s+([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\s*;", members):
            namespace, interface = attribute.group(2), attribute.group(1)
            del parent
            break
    if namespace is None:
        return {}

    body = bodies.get(interface, "")
    surface["events"] |= {m.group(1) for m in WEBIDL_ATTRIBUTE.finditer(body)}
    surface["properties"] |= {m.group(1) for m in WEBIDL_CONSTANT.finditer(body)}
    for operation in WEBIDL_OPERATION.finditer(body):
        name = WEBIDL_TRAILING_NAME.search(operation.group(1))
        if name:
            surface["functions"].add(name.group(1))
    return {namespace: surface}


def surface_of(path):
    """namespace -> {functions, events, types, properties} name sets."""
    if path.endswith(".idl"):
        return idl_surface_of(path)
    if path.endswith(".webidl"):
        return webidl_surface_of(path)
    result = {}
    for entry in load_schema(path):
        name = entry.get("namespace")
        if not name:
            continue
        result[name] = {
            "functions": {f["name"] for f in entry.get("functions", []) if "name" in f},
            "events": {e["name"] for e in entry.get("events", []) if "name" in e},
            "types": {t["id"] for t in entry.get("types", []) if "id" in t},
            "properties": property_paths(entry.get("properties")),
        }
    return result


def wrapper_namespaces():
    """namespace -> method names from the WebKit chrome wrapper."""
    with open(WRAPPER_PATH, encoding="utf-8") as handle:
        source = handle.read()
    start = source.find("var NAMESPACES = {")
    end = source.find("};", start)
    if start < 0 or end < 0:
        sys.exit("error: %s has no NAMESPACES table" % WRAPPER_PATH)
    found = {}
    for line in source[start:end].splitlines():
        stripped = line.strip()
        if ":" not in stripped or stripped.startswith("/"):
            continue
        name, rest = stripped.split(":", 1)
        name = name.strip()
        methods = re.findall(r'"([A-Za-z_]+)"', rest)
        if name.isidentifier() and methods:
            found[name] = methods
    if not found:
        sys.exit("error: %s NAMESPACES table is empty" % WRAPPER_PATH)
    return found


def wrapped_permissions():
    with open(WRAPPER_PATH, encoding="utf-8") as handle:
        source = handle.read()
    match = re.search(r"let wrapped: Set<String> = \[([^\]]+)\]", source)
    if not match:
        sys.exit("error: %s has no wrapped permission set" % WRAPPER_PATH)
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def vendored_functions(namespace):
    for name in sorted(os.listdir(VENDOR_DIR)):
        if name.startswith("_") or not name.endswith((".json", ".idl", ".webidl")):
            continue
        surface = surface_of(os.path.join(VENDOR_DIR, name)).get(namespace)
        if surface and surface.get("functions"):
            return surface["functions"]
    return None


def permission_feature_names(path):
    names = set()
    depth = 0
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if line.startswith("//"):
                continue
            if depth == 1:
                match = re.match(r'"([^"]+)"\s*:', line)
                if match:
                    names.add(match.group(1))
            depth += line.count("{") - line.count("}")
    return names


def string_constants(path):
    """`const char kFoo[] = "bar";` -> {"kFoo": "bar"}."""
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    return dict(re.findall(r'const\s+char\s+(\w+)\[\]\s*=\s*"([^"]*)"\s*;', source))


def core_registered_permissions():
    """//extensions' own `permissions_to_register` table, as (all, internal).

    Every non-internal name reaches PermissionsInfo via CoreExtensionsAPIProvider;
    permissions_parser.cc DCHECKs on any that has no permission feature.
    """
    with open(CORE_PERMISSIONS_CC, encoding="utf-8") as handle:
        source = handle.read()
    start = source.find("permissions_to_register[] = {")
    end = source.find("\n};", start)
    if start < 0 or end < 0:
        sys.exit("error: no permissions_to_register array literal in %s" % CORE_PERMISSIONS_CC)
    body = strip_comments(source[start:end])
    constants = string_constants(DNR_CONSTANTS_CC)

    names, internal = set(), set()
    for entry in re.split(r"\{APIPermissionID::", body)[1:]:
        match = re.match(r"\w+,\s*([^,}]+)", entry, re.S)
        if not match:
            sys.exit("error: unparsable permission entry in %s: %r" % (CORE_PERMISSIONS_CC, entry[:80]))
        token = match.group(1).strip()
        if token.startswith('"'):
            name = token.strip('"')
        else:
            name = constants.get(token.rsplit("::", 1)[-1])
            if name is None:
                sys.exit(
                    "error: %s names a permission by the constant %s, which this script cannot "
                    "resolve. Add its defining file to string_constants() -- leaving it unresolved "
                    "would silently drop the permission from the feature-coverage guard."
                    % (CORE_PERMISSIONS_CC, token)
                )
        names.add(name)
        if "kFlagInternal" in entry:
            internal.add(name)
    return names, internal


# MARK: - Vendoring


def chromium_version():
    return load_index().get("chromium_version", "vendored")


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_upstream():
    if not os.path.isdir(CHROME_API_DIR):
        sys.exit(
            "error: schemas are vendored in OrbitTests/Fixtures/UpstreamAPISchemas. "
            "There is no Chromium checkout to sync from."
        )


def cmd_sync(_args):
    sys.exit(
        "error: schemas are vendored in OrbitTests/Fixtures/UpstreamAPISchemas. "
        "There is no Chromium checkout and no Embedder tree to copy."
    )


# MARK: - Diff


def load_index():
    path = os.path.join(VENDOR_DIR, "_index.json")
    if not os.path.exists(path):
        sys.exit("error: no vendored snapshot in %s." % VENDOR_DIR)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def compute_gaps():
    index = load_index()
    namespaces = {}
    for namespace, methods in sorted(wrapper_namespaces().items()):
        upstream = vendored_functions(namespace)
        entry = {"status": "partial", "functions": methods}
        if upstream is None:
            entry["extraFunctions"] = list(methods)
        else:
            extra = sorted(set(methods) - upstream)
            if extra:
                entry["extraFunctions"] = extra
            else:
                entry["status"] = "complete"
        namespaces[namespace] = entry
    invented = sorted(wrapped_permissions() - set(index["chrome_permissions"]) - set(index["core_permissions"]))
    return {
        "chromium_version": index["chromium_version"],
        "namespaces": namespaces,
        "unregisteredChromePermissions": invented,
        "permissionsMissingFeatures": invented,
    }


def cmd_diff(args):
    gaps = compute_gaps()
    if args.json:
        print(json.dumps(gaps, indent=2))
        return
    absent = [n for n, e in gaps["namespaces"].items() if e["status"] == "absent"]
    partial = {n: e for n, e in gaps["namespaces"].items() if e["status"] != "absent"}
    print("Chromium %s" % gaps["chromium_version"])
    print("\n%d chrome-layer namespaces absent from Orbit:" % len(absent))
    for name in absent:
        print("  %s" % name)
    print("\n%d ported namespaces:" % len(partial))
    for name, entry in partial.items():
        extra = entry.get("extraFunctions") or []
        print("  %-16s %s" % (name, "complete" if not extra else "%d orbit-only" % len(extra)))
        for member in extra:
            print("      + %s" % member)
    invented = gaps["permissionsMissingFeatures"]
    print("\n%d wrapped permissions absent from the vendored snapshot:" % len(invented))
    if invented:
        print("  " + ", ".join(invented))


def cmd_update_expectations(_args):
    sys.exit(
        "error: ExpectedAPIGaps.json stays the checked-in triage of the vendored snapshot. "
        "The WebKit wrapper is checked by OrbitTests/ExtensionSchemaConformanceTests."
    )


def cmd_status(_args):
    index = load_index()
    print("vendored snapshot: %s" % index["chromium_version"])
    print("schemas vendored:  %d" % len(index["schema_sha256"]))
    print("webkit wrapper namespaces: %d" % len(wrapper_namespaces()))


def main(argv):
    parser = argparse.ArgumentParser(prog="extension-schemas", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("sync", help="vendor upstream schemas for the pinned Chromium").set_defaults(func=cmd_sync)
    diff = subparsers.add_parser("diff", help="print Orbit's gaps against the vendored snapshot")
    diff.add_argument("--json", action="store_true")
    diff.set_defaults(func=cmd_diff)
    subparsers.add_parser(
        "update-expectations", help="rewrite OrbitTests/Fixtures/ExpectedAPIGaps.json from the current diff"
    ).set_defaults(func=cmd_update_expectations)
    subparsers.add_parser("status", help="show the vendored snapshot's Chromium stamp").set_defaults(func=cmd_status)
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
