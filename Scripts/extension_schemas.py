#!/usr/bin/env python3
"""Vendors upstream Chromium extension API schemas and diffs Orbit's against them.

`sync` copies schemas into OrbitTests/Fixtures/UpstreamAPISchemas/, stamped with
chromium_version, since ThirdParty/chromium is gitignored and absent on a fresh clone; the
conformance test fails when the stamp drifts, forcing a re-sync on every Chromium bump. This
script regenerates the expectations a human reviews; ExtensionSchemaConformanceTests.swift is
the separate implementation that enforces them.
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
ORBIT_API_DIR = os.path.join(REPO_ROOT, "Chromium", "Embedder", "common", "api")
VENDOR_DIR = os.path.join(REPO_ROOT, "OrbitTests", "Fixtures", "UpstreamAPISchemas")
EXPECTATIONS_PATH = os.path.join(REPO_ROOT, "OrbitTests", "Fixtures", "ExpectedAPIGaps.json")
VERSION_PATH = os.path.join(REPO_ROOT, "Chromium", "chromium-version.json")
PROVIDER_PATH = os.path.join(REPO_ROOT, "Chromium", "Embedder", "common", "orbit_extensions_api_provider.cc")

MEMBER_KINDS = ("functions", "events", "types", "properties")
SINGULAR = {"functions": "function", "events": "event", "types": "type", "properties": "property"}

# Why each absent chrome-layer namespace is absent; anything unnamed here regenerates
# "unclassified", which ExtensionSchemaConformanceTests rejects, forcing a human to triage it.
#   notPorted      in scope, Orbit simply has not ported it (section 1.4)
#   outOfScope     ChromeOS hardware/shell, enterprise, or the Chrome Apps
#                  platform-app model Orbit does not host (section 1.5)
#   chromeInternal allowlist-only; no third-party extension can reach it
DEFAULT_REASONS = {
    "notPorted": [
        "accessibilityFeatures", "bookmarks", "browserAction", "browsingData", "commands",
        "contentSettings", "contextMenus", "debugger", "declarativeContent", "desktopCapture",
        "devtools.inspectedWindow", "devtools.network", "devtools.panels", "devtools.performance",
        "devtools.recorder", "dom", "downloads", "extension", "fontSettings", "gcm", "history",
        "identity", "instanceID", "mdns", "notifications", "omnibox", "pageAction", "pageCapture",
        "processes", "proxy", "readingList", "search", "sessions", "sidePanel", "tabCapture",
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


def surface_of(path):
    """namespace -> {functions, events, types, properties} name sets."""
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


def orbit_ported_files():
    """Orbit's own chrome-layer schemas, as {namespace: filename}."""
    ported = {}
    for name in sorted(os.listdir(ORBIT_API_DIR)):
        if not name.endswith(".json") or name.startswith("_"):
            continue
        for namespace in surface_of(os.path.join(ORBIT_API_DIR, name)):
            ported[namespace] = name
    return ported


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


def registered_permission_names():
    with open(PROVIDER_PATH, encoding="utf-8") as handle:
        source = handle.read()
    start = source.find("kOrbitPermissionsToRegister[] = {")
    end = source.find("};", start)
    body = source[start:end]
    return set(re.findall(r'APIPermissionID::\w+,\s*"([^"]+)"', body))


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
    with open(VERSION_PATH, encoding="utf-8") as handle:
        return json.load(handle)["chromium_version"]


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_upstream():
    if not os.path.isdir(CHROME_API_DIR):
        sys.exit(
            "error: no Chromium checkout at %s.\n"
            "       Scripts/extension-schemas sync needs one: run\n"
            "         Scripts/chromium build --from-source\n"
            "       or sync on a machine that already has it. The vendored copy in\n"
            "       OrbitTests/Fixtures/UpstreamAPISchemas/ is what everyone else uses."
            % UPSTREAM_SRC
        )


def cmd_sync(_args):
    require_upstream()
    version = chromium_version()
    ported = orbit_ported_files()
    os.makedirs(VENDOR_DIR, exist_ok=True)

    files = {}
    for namespace, filename in sorted(ported.items()):
        source = os.path.join(CHROME_API_DIR, filename)
        if not os.path.exists(source):
            sys.exit(
                "error: Orbit ports %s from %s but upstream has no such file at %s"
                % (namespace, filename, source)
            )
        shutil.copyfile(source, os.path.join(VENDOR_DIR, filename))
        files[filename] = sha256_of(source)

    for filename, source in sorted(VENDORED_PERMISSION_FEATURES.items()):
        shutil.copyfile(source, os.path.join(VENDOR_DIR, filename))
        files[filename] = sha256_of(source)

    core_registered, core_internal = core_registered_permissions()

    index = {
        "_readme": [
            "GENERATED by Scripts/extension-schemas sync. Do not hand-edit.",
            "",
            "A snapshot of the upstream Chromium extension API surface for the pinned",
            "chromium_version, vendored because ThirdParty/chromium is gitignored and",
            "absent on a clone. OrbitTests/ExtensionSchemaConformanceTests.swift diffs",
            "Orbit's own schemas against these and asserts the delta equals",
            "OrbitTests/Fixtures/ExpectedAPIGaps.json.",
            "",
            "chrome_namespaces: every namespace declared under",
            "  chrome/common/extensions/api (the chrome layer //extensions has none of).",
            "core_namespaces: every namespace declared under extensions/common/api,",
            "  which Orbit already gets for free and which therefore cancels out of",
            "  the diff.",
            "chrome_permissions / core_permissions: the keys of each layer's",
            "  _permission_features.json.",
            "core_registered_permissions: every name",
            "  extensions/common/permissions/extensions_api_permissions.cc registers an",
            "  APIPermissionInfo for, which CoreExtensionsAPIProvider gives Orbit",
            "  unconditionally. permissions_parser.cc DCHECKs on any registered name with",
            "  no permission feature, so this list minus core_internal_permissions is what",
            "  Orbit's own _permission_features.json has to finish covering.",
            "core_internal_permissions: the subset flagged kFlagInternal, which",
            "  APIPermissionSet::ParseFromJSON drops before the feature lookup.",
            "_chrome_permission_features.json / _core_permission_features.json: both",
            "  layers' whole feature files, vendored so the conformance test can check",
            "  Orbit copied the chrome-layer entries rather than inventing availability",
            "  for them, and can work out which permissions an ordinary extension can",
            "  really end up holding.",
        ],
        "chromium_version": version,
        "chrome_namespaces": sorted(namespaces_in(CHROME_API_DIR)),
        "core_namespaces": sorted(namespaces_in(CORE_API_DIR)),
        "chrome_permissions": sorted(
            permission_feature_names(os.path.join(CHROME_API_DIR, "_permission_features.json"))
        ),
        "core_permissions": sorted(
            permission_feature_names(os.path.join(CORE_API_DIR, "_permission_features.json"))
        ),
        "core_registered_permissions": sorted(core_registered),
        "core_internal_permissions": sorted(core_internal),
        "schema_sha256": files,
    }
    with open(os.path.join(VENDOR_DIR, "_index.json"), "w", encoding="utf-8") as handle:
        json.dump(index, handle, indent=2, sort_keys=False)
        handle.write("\n")

    print("synced %d upstream schemas for Chromium %s into %s" % (len(files), version, VENDOR_DIR))
    print("  chrome namespaces: %d   core namespaces: %d" % (
        len(index["chrome_namespaces"]), len(index["core_namespaces"])))
    print("run `Scripts/extension-schemas diff` next, then update ExpectedAPIGaps.json deliberately")


# MARK: - Diff


def load_index():
    path = os.path.join(VENDOR_DIR, "_index.json")
    if not os.path.exists(path):
        sys.exit("error: no vendored snapshot. Run `Scripts/extension-schemas sync` first.")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def compute_gaps():
    index = load_index()
    ported = orbit_ported_files()

    namespaces = {}
    absent = sorted(
        set(index["chrome_namespaces"]) - set(index["core_namespaces"]) - set(ported)
    )
    for name in absent:
        namespaces[name] = {"status": "absent", "reason": REASON_OF.get(name, "unclassified")}

    for namespace, filename in sorted(ported.items()):
        vendored = os.path.join(VENDOR_DIR, filename)
        if not os.path.exists(vendored):
            continue
        upstream = surface_of(vendored).get(namespace, {})
        orbit = surface_of(os.path.join(ORBIT_API_DIR, filename)).get(namespace, {})
        entry = {"status": "partial"}
        for kind in MEMBER_KINDS:
            missing = sorted(upstream.get(kind, set()) - orbit.get(kind, set()))
            extra = sorted(orbit.get(kind, set()) - upstream.get(kind, set()))
            if missing:
                entry["missing" + kind.capitalize()] = missing
            if extra:
                entry["extra" + kind.capitalize()] = extra
        if len(entry) == 1:
            entry["status"] = "complete"
        namespaces[namespace] = entry

    permissions = sorted(
        set(index["chrome_permissions"])
        - set(index["core_permissions"])
        - registered_permission_names()
    )
    return {
        "chromium_version": index["chromium_version"],
        "namespaces": namespaces,
        "unregisteredChromePermissions": permissions,
        "permissionsMissingFeatures": permissions_missing_features(index),
    }


def orbit_permission_feature_names():
    return permission_feature_names(os.path.join(ORBIT_API_DIR, "_permission_features.json"))


def permissions_missing_features(index):
    """Registered permissions with no permission feature -- every one a DCHECK."""
    registered = set(index["core_registered_permissions"]) | registered_permission_names()
    described = set(index["core_permissions"]) | orbit_permission_feature_names()
    return sorted(registered - set(index["core_internal_permissions"]) - described)


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
        details = []
        for kind in MEMBER_KINDS:
            missing = entry.get("missing" + kind.capitalize())
            if missing:
                details.append("%d %s" % (len(missing), kind))
        print("  %-16s %s" % (name, "missing " + ", ".join(details) if details else "complete"))
        for kind in MEMBER_KINDS:
            for member in entry.get("missing" + kind.capitalize(), []):
                print("      - %s (%s)" % (member, SINGULAR[kind]))
            for member in entry.get("extra" + kind.capitalize(), []):
                print("      + %s (%s, Orbit-only)" % (member, SINGULAR[kind]))
    print("\n%d chrome-layer permissions unregistered by OrbitExtensionsAPIProvider:"
          % len(gaps["unregisteredChromePermissions"]))
    print("  " + ", ".join(gaps["unregisteredChromePermissions"]))
    missing = gaps["permissionsMissingFeatures"]
    print("\n%d registered permissions with no permission feature:" % len(missing))
    if missing:
        print("  " + ", ".join(missing))
        print("  Each one aborts the browser process from permissions_parser.cc the moment an")
        print("  extension names it in a manifest. Copy the pinned Chromium's chrome-layer")
        print("  entry for each into Chromium/Embedder/common/api/_permission_features.json.")


def cmd_update_expectations(_args):
    gaps = compute_gaps()
    existing = {}
    if os.path.exists(EXPECTATIONS_PATH):
        with open(EXPECTATIONS_PATH, encoding="utf-8") as handle:
            existing = json.load(handle)

    old_namespaces = existing.get("namespaces", {})
    for name, entry in gaps["namespaces"].items():
        for carried in ("reason", "note"):
            if carried in old_namespaces.get(name, {}):
                entry[carried] = old_namespaces[name][carried]

    merged = {
        "_readme": existing.get("_readme", []),
        "chromium_version": gaps["chromium_version"],
        "neverDispatchedEvents": existing.get("neverDispatchedEvents", []),
        "namespaces": gaps["namespaces"],
        "unregisteredChromePermissions": gaps["unregisteredChromePermissions"],
    }
    with open(EXPECTATIONS_PATH, "w", encoding="utf-8") as handle:
        json.dump(merged, handle, indent=2)
        handle.write("\n")
    print("wrote %s" % EXPECTATIONS_PATH)
    print("READ THE DIFF BEFORE COMMITTING: a member disappearing from this file means "
          "Orbit implemented it, and a member appearing means Orbit lost it.")


def cmd_status(_args):
    index = load_index()
    pinned = chromium_version()
    print("pinned Chromium:   %s" % pinned)
    print("vendored snapshot: %s" % index["chromium_version"])
    if index["chromium_version"] != pinned:
        print("STALE -- run `Scripts/extension-schemas sync`")
    print("schemas vendored:  %d" % len(index["schema_sha256"]))
    print("upstream checkout: %s" % ("present" if os.path.isdir(CHROME_API_DIR) else "absent"))


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
