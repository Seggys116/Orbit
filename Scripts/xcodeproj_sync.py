#!/usr/bin/env python3
"""Regenerate the file-membership sections of Orbit.xcodeproj/project.pbxproj from disk."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(REPO_ROOT, "Orbit.xcodeproj", "project.pbxproj")

# `@main` may appear once per module and ContentView binds `AppEnvironment.shared`, which the demo must never construct; anything else excluded here fails silently through EngineFactory.makeEngine()'s fallback.
DEMO_EXCLUDES = [
    "Orbit/ContentView.swift",
    "Orbit/OrbitApp.swift",
]

# OrbitTests has no TEST_HOST and cannot reach the app module, so it recompiles the app sources it exercises.
ORBIT_TESTS_REUSED_SOURCES = [
    "Orbit/Core/DesignTokens.swift",
    "Orbit/Core/OrbitDataRoot.swift",
    "Orbit/Core/OrbitDefaults.swift",
    "Orbit/Core/OrbitProcessLiveness.swift",
    "Orbit/Core/OrbitRuntimeScope.swift",
    "Orbit/Core/ShortcutRegistry.swift",
    "Orbit/Engine/BrowserEngine.swift",
    "Orbit/Engine/ContentBlocking/CompiledFilterListCache.swift",
    "Orbit/Engine/ContentBlocking/ContentBlocker.swift",
    "Orbit/Engine/ContentBlocking/ContentBlockerRuleSet.swift",
    "Orbit/Engine/ContentBlocking/ContentBlockingController.swift",
    "Orbit/Engine/ContentBlocking/ContentBlockingRuntime.swift",
    "Orbit/Engine/ContentBlocking/ContentBlockingTypes.swift",
    "Orbit/Engine/ContentBlocking/FilterListCatalog.swift",
    "Orbit/Engine/ContentBlocking/FilterListStore.swift",
    "Orbit/Engine/ContentBlocking/FilterRegexBounds.swift",
    "Orbit/Engine/ContentBlocking/FilterRule.swift",
    "Orbit/Engine/ContentBlocking/FilterTokenizer.swift",
    "Orbit/Engine/ContentBlocking/RedirectResource.swift",
    "Orbit/Engine/ContentBlocking/RedirectResourceData.swift",
    "Orbit/Engine/EngineTypes.swift",
    "Orbit/Engine/Extensions/ExtensionActionState.swift",
    "Orbit/Engine/Extensions/ExtensionContextMenuItem.swift",
    "Orbit/Features/Peek/PeekState.swift",
    "Orbit/Models/BrowserStore+Favorites.swift",
    "Orbit/Models/BrowserStore+Folders.swift",
    "Orbit/Models/BrowserStore+Profiles.swift",
    "Orbit/Models/BrowserStore+Spaces.swift",
    "Orbit/Models/BrowserStore+SplitView.swift",
    "Orbit/Models/BrowserStore+Tabs.swift",
    "Orbit/Models/BrowserStore.swift",
    "Orbit/Models/FolderPreview.swift",
    "Orbit/Models/ModelTypes.swift",
    "Orbit/Models/PinnedNodeTree.swift",
    "Orbit/Persistence/FaviconCache.swift",
    "Orbit/Persistence/HistoryStore.swift",
    "Orbit/Persistence/SchemaMigration.swift",
    "Orbit/Persistence/StateStore.swift",
    "Orbit/UI/Controls/OrbitContextMenuModel.swift",
    "Orbit/UI/Controls/OrbitContextMenuView.swift",
    "Orbit/UI/Controls/OrbitMenuPanel.swift",
    "Orbit/UI/Controls/OrbitMenuPanelAnchor.swift",
    "Orbit/UI/Controls/OrbitMenuPlacement.swift",
    "Orbit/UI/Controls/OrbitMenuSurface.swift",
    "Orbit/UI/Sidebar/FaviconView.swift",
    "Orbit/UI/Sidebar/FavoritesGridView.swift",
    "Orbit/UI/Sidebar/FolderHoverPreviewView.swift",
    "Orbit/UI/Sidebar/FolderToggleGlyph.swift",
    "Orbit/UI/Sidebar/OrbitNSActionButton.swift",
    "Orbit/UI/Sidebar/SidebarBottomBar.swift",
    "Orbit/UI/Sidebar/SidebarDragDrop.swift",
    "Orbit/UI/Sidebar/SidebarNewItemMenuView.swift",
    "Orbit/UI/Sidebar/SidebarTearOffDetector.swift",
    "Orbit/UI/Sidebar/SidebarToast.swift",
    "Orbit/UI/Sidebar/SidebarTopRow.swift",
    "Orbit/UI/Sidebar/TabHoverPreviewView.swift",
    "Orbit/UI/Sidebar/TabRowView.swift",
    "Orbit/UI/Spaces/MoveTabToSpaceMenu.swift",
    "Orbit/UI/Theme/GrainTexture.swift",
    "Orbit/UI/Theme/SpaceThemePalette.swift",
    "Orbit/UI/Theme/ThemeBackgroundView.swift",
    "Orbit/UI/Theme/ThemeSelfCheck.swift",
    "Orbit/UI/Window/ClickCatcherHitTesting.swift",
]

# Host-less helpers OrbitTests owns that the live suites also need, so the
# schema/liveness tables have exactly one parser rather than two that drift.
ORBIT_APP_TESTS_REUSED_SOURCES = [
    "OrbitTests/Support/ExtensionAPISchemaSurface.swift",
]

# Loose files are only copied into a bundle when they are named here: the scan below adds
# sources and resource directories, and nothing else.
APP_RESOURCES: list[str] = []

TARGETS = {
    "Orbit": {
        "roots": ["Orbit"],
        # Info.plist is INFOPLIST_FILE here, so it must not also be copied as a resource.
        "exclude": ["Orbit/Resources/Info.plist"],
        "extra_sources": [],
        "extra_resources": list(APP_RESOURCES),
    },
    "OrbitDemo": {
        "roots": ["Orbit", "OrbitDemo"],
        "exclude": list(DEMO_EXCLUDES) + [
            "OrbitDemo/Info.plist",
            "Orbit/Resources/Info.plist",
        ],
        "extra_sources": [],
        "extra_resources": list(APP_RESOURCES),
    },
    "OrbitTests": {
        "roots": ["OrbitTests"],
        "exclude": [],
        "extra_sources": list(ORBIT_TESTS_REUSED_SOURCES),
        "extra_resources": [],
    },
    "OrbitAppTests": {
        "roots": ["OrbitAppTests"],
        "exclude": [],
        "extra_sources": list(ORBIT_APP_TESTS_REUSED_SOURCES),
        "extra_resources": [],
    },
}

NAVIGATOR_ROOTS = ["Orbit", "OrbitDemo", "OrbitTests", "OrbitAppTests"]

SKIP_NAMES = {".DS_Store", ".git", ".gitignore", ".svn"}

BUNDLE_DIR_EXTS = {
    ".xcassets": "folder.assetcatalog",
    ".icon": "folder.iconcomposer.icon",
    ".xcdatamodeld": "wrapper.xcdatamodel",
    ".docc": "folder.documentationcatalog",
    ".bundle": "wrapper.plug-in",
    ".framework": "wrapper.framework",
    ".lproj": "folder",
}

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".m": "sourcecode.c.objc",
    ".mm": "sourcecode.cpp.objcpp",
    ".c": "sourcecode.c.c",
    ".cc": "sourcecode.cpp.cpp",
    ".cpp": "sourcecode.cpp.cpp",
    ".h": "sourcecode.c.h",
    ".hpp": "sourcecode.cpp.h",
    ".hh": "sourcecode.cpp.h",
    ".metal": "sourcecode.metal",
    ".entitlements": "text.plist.entitlements",
    ".plist": "text.plist.xml",
    ".template": "text.xml",
    ".xcconfig": "text.xcconfig",
    ".json": "text.json",
    # Vendored upstream API schemas: reference data for the conformance test, never compiled.
    ".webidl": "text",
    ".idl": "text",
    ".md": "net.daringfireball.markdown",
    ".txt": "text",
    ".sh": "text.script.sh",
    ".png": "image.png",
    ".jpg": "image.jpeg",
    ".jpeg": "image.jpeg",
    ".pdf": "image.pdf",
    ".xcstrings": "text.json.xcstrings",
    ".strings": "text.plist.strings",
    ".html": "text.html",
    ".css": "text.css",
    ".js": "sourcecode.javascript",
}

SOURCE_EXTS = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".metal"}

RESOURCE_DIR_EXTS = {".xcassets", ".icon", ".xcdatamodeld", ".docc", ".lproj"}

def file_type_for(name: str, is_dir: bool) -> str:
    """An unmapped extension is deliberately a hard error: any fallback type stops the file being compiled."""
    ext = os.path.splitext(name)[1].lower()
    if is_dir:
        return BUNDLE_DIR_EXTS.get(ext, "folder")
    file_type = FILE_TYPES.get(ext)
    if file_type is None:
        raise SystemExit(
            f"error: no lastKnownFileType mapped for '{ext or name}' (from {name!r}).\n"
            f"       Add it to FILE_TYPES in {os.path.basename(__file__)}. Do NOT add a\n"
            f"       default: a wrong or generic type silently stops a file being\n"
            f"       compiled, which is the defect this script exists to prevent."
        )
    return file_type

def oid(kind: str, key: str) -> str:
    """A stable 24-hex-digit Xcode object identifier, so re-runs produce an identical file."""
    return hashlib.sha256(f"orbit:{kind}:{key}".encode()).hexdigest()[:24].upper()

class Node:
    __slots__ = ("name", "rel", "is_dir", "children")

    def __init__(self, name: str, rel: str, is_dir: bool):
        self.name = name
        self.rel = rel
        self.is_dir = is_dir
        self.children: list[Node] = []

def scan(rel: str) -> Node:
    """Symlinks are followed to decide file vs directory but never resolved: the project must record the symlink path."""
    node = Node(os.path.basename(rel), rel, True)
    abspath = os.path.join(REPO_ROOT, rel)
    entries = sorted(os.listdir(abspath), key=lambda s: s.lower())
    for name in entries:
        if name in SKIP_NAMES or name.startswith("._"):
            continue
        child_rel = f"{rel}/{name}"
        child_abs = os.path.join(REPO_ROOT, child_rel)
        is_dir = os.path.isdir(child_abs)
        ext = os.path.splitext(name)[1].lower()
        if is_dir and ext not in BUNDLE_DIR_EXTS:
            # Dropped when it holds nothing: git cannot track an empty directory,
            # so a group for one exists in a working tree and not in a clone, and
            # --check then fails in CI on a project that is correct locally.
            child = scan(child_rel)
            if child.children:
                node.children.append(child)
        else:
            node.children.append(Node(name, child_rel, is_dir))
    return node

def iter_files(node: Node):
    for child in node.children:
        if child.is_dir and child.children:
            yield from iter_files(child)
        elif child.is_dir and not child.children and child.rel.endswith(tuple(BUNDLE_DIR_EXTS)):
            yield child
        elif not child.is_dir:
            yield child
        elif child.rel.endswith(tuple(BUNDLE_DIR_EXTS)):
            yield child

def all_items(node: Node):
    for child in node.children:
        ext = os.path.splitext(child.name)[1].lower()
        if child.is_dir and ext in BUNDLE_DIR_EXTS:
            yield child
        elif child.is_dir:
            yield from all_items(child)
        else:
            yield child

# The output must match Xcode's own OpenStep plist formatting, or Xcode reformats the file on save and every regeneration fights the diff.

UNQUOTED = re.compile(r"^[A-Za-z0-9_./]+$")

SINGLE_LINE_ISA = {"PBXBuildFile", "PBXFileReference"}

SECTION_ORDER = [
    "PBXAggregateTarget",
    "PBXBuildFile",
    "PBXContainerItemProxy",
    "PBXCopyFilesBuildPhase",
    "PBXFileReference",
    "PBXFrameworksBuildPhase",
    "PBXGroup",
    "PBXHeadersBuildPhase",
    "PBXNativeTarget",
    "PBXProject",
    "PBXResourcesBuildPhase",
    "PBXShellScriptBuildPhase",
    "PBXSourcesBuildPhase",
    "PBXTargetDependency",
    "PBXVariantGroup",
    "XCBuildConfiguration",
    "XCConfigurationList",
    "XCRemoteSwiftPackageReference",
    "XCSwiftPackageProductDependency",
]

PHASE_DEFAULT_NAME = {
    "PBXSourcesBuildPhase": "Sources",
    "PBXFrameworksBuildPhase": "Frameworks",
    "PBXResourcesBuildPhase": "Resources",
    "PBXHeadersBuildPhase": "Headers",
    "PBXCopyFilesBuildPhase": "CopyFiles",
}

def quote(value: str) -> str:
    if value == "":
        return '""'
    if UNQUOTED.match(value):
        return value
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'

class Writer:
    def __init__(self, objects: dict):
        self.objects = objects
        self.comments = self._compute_comments()

    def _display_name(self, oid_: str) -> str:
        obj = self.objects.get(oid_)
        if not isinstance(obj, dict):
            return ""
        isa = obj.get("isa", "")
        if isa == "PBXBuildFile":
            ref = obj.get("fileRef") or obj.get("productRef")
            return self._display_name(ref) if ref else ""
        if isa in PHASE_DEFAULT_NAME:
            return obj.get("name") or PHASE_DEFAULT_NAME[isa]
        if isa == "PBXProject":
            return "Project object"
        if isa == "PBXTargetDependency":
            return "PBXTargetDependency"
        if isa == "PBXContainerItemProxy":
            return "PBXContainerItemProxy"
        if isa == "XCSwiftPackageProductDependency":
            return obj.get("productName", "")
        if isa == "XCRemoteSwiftPackageReference":
            url = str(obj.get("repositoryURL", "")).rstrip("/")
            base = os.path.basename(url)
            if base.endswith(".git"):
                base = base[: -len(".git")]
            return f'XCRemoteSwiftPackageReference "{base}"' if base else isa
        name = obj.get("name")
        if name:
            return name
        path = obj.get("path")
        if path:
            return os.path.basename(path)
        return ""

    def _compute_comments(self) -> dict:
        comments: dict[str, str] = {}
        phase_of: dict[str, str] = {}
        for pid, obj in self.objects.items():
            if not isinstance(obj, dict):
                continue
            isa = obj.get("isa", "")
            if isa in PHASE_DEFAULT_NAME:
                phase_name = obj.get("name") or PHASE_DEFAULT_NAME[isa]
                for bf in obj.get("files", []):
                    phase_of[bf] = phase_name
        list_owner: dict[str, tuple[str, str]] = {}
        for pid, obj in self.objects.items():
            if not isinstance(obj, dict):
                continue
            cl = obj.get("buildConfigurationList")
            if cl:
                isa = obj.get("isa", "")
                owner = "PBXProject" if isa == "PBXProject" else isa
                nm = obj.get("name") or self._display_name(pid) or ""
                list_owner[cl] = (owner, nm)
        for pid, obj in self.objects.items():
            if not isinstance(obj, dict):
                continue
            isa = obj.get("isa", "")
            if isa == "PBXBuildFile":
                base = self._display_name(pid)
                phase = phase_of.get(pid)
                comments[pid] = f"{base} in {phase}" if phase and base else base
            elif isa == "XCConfigurationList":
                owner = list_owner.get(pid)
                if owner:
                    comments[pid] = f'Build configuration list for {owner[0]} "{owner[1]}"'
                else:
                    comments[pid] = "Build configuration list"
            else:
                comments[pid] = self._display_name(pid)
        return comments

    def ref(self, oid_: str) -> str:
        comment = self.comments.get(oid_)
        return f"{oid_} /* {comment} */" if comment else oid_

    def value(self, val, indent: int, single_line: bool) -> str:
        if isinstance(val, list):
            if single_line:
                inner = ", ".join(self.value(v, indent, True) for v in val)
                return f"({inner})"
            if not val:
                return "(\n" + "\t" * (indent + 1) + ")"
            pad = "\t" * (indent + 1)
            body = "".join(f"{pad}{self.value(v, indent + 1, False)},\n" for v in val)
            return "(\n" + body + "\t" * indent + ")"
        if isinstance(val, dict):
            pad = "\t" * (indent + 1)
            body = "".join(
                f"{pad}{quote(k)} = {self.value(v, indent + 1, False)};\n"
                for k, v in sorted(val.items())
            )
            return "{\n" + body + "\t" * indent + "}"
        text = str(val)
        if text in self.objects:
            return self.ref(text)
        return quote(text)

    def object_body(self, oid_: str, obj: dict) -> str:
        isa = obj.get("isa", "")
        keys = ["isa"] + sorted(k for k in obj if k != "isa")
        if isa in SINGLE_LINE_ISA:
            parts = []
            for k in keys:
                parts.append(f"{quote(k)} = {self.value(obj[k], 0, True)}; ")
            return "{" + "".join(parts) + "}"
        lines = ["{\n"]
        for k in keys:
            lines.append(f"\t\t\t{quote(k)} = {self.value(obj[k], 3, False)};\n")
        lines.append("\t\t}")
        return "".join(lines)

    def dump(self, root_object: str, object_version: str, archive_version: str) -> str:
        out = ["// !$*UTF8*$!\n{\n"]
        out.append(f"\tarchiveVersion = {archive_version};\n")
        out.append("\tclasses = {\n\t};\n")
        out.append(f"\tobjectVersion = {object_version};\n")
        out.append("\tobjects = {\n")
        by_isa: dict[str, list[str]] = {}
        for pid, obj in self.objects.items():
            by_isa.setdefault(obj.get("isa", "Unknown"), []).append(pid)
        ordered = [s for s in SECTION_ORDER if s in by_isa]
        ordered += sorted(s for s in by_isa if s not in SECTION_ORDER)
        for isa in ordered:
            out.append(f"\n/* Begin {isa} section */\n")
            for pid in sorted(by_isa[isa]):
                out.append(f"\t\t{self.ref(pid)} = {self.object_body(pid, self.objects[pid])};\n")
            out.append(f"/* End {isa} section */\n")
        out.append("\t};\n")
        out.append(f"\trootObject = {self.ref(root_object)};\n")
        out.append("}\n")
        return "".join(out)

def load_project() -> dict:
    raw = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", PBXPROJ],
        check=True, capture_output=True,
    ).stdout
    return json.loads(raw)

def rebuild(project: dict) -> dict:
    objects: dict = dict(project["objects"])
    root = project["rootObject"]
    proj_obj = objects[root]

    drop_isa = {
        "PBXGroup",
        "PBXFileSystemSynchronizedRootGroup",
        "PBXFileSystemSynchronizedBuildFileExceptionSet",
        "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet",
    }
    preserved_refs: dict[str, dict] = {}
    for pid, obj in objects.items():
        if obj.get("isa") != "PBXFileReference":
            continue
        path = obj.get("path", "")
        if obj.get("sourceTree") != "<group>":
            preserved_refs[pid] = obj
        elif "/" in path and path.split("/")[0] not in NAVIGATOR_ROOTS:
            preserved_refs[pid] = obj

    for pid, obj in list(objects.items()):
        isa = obj.get("isa")
        if isa in drop_isa:
            del objects[pid]
        elif isa == "PBXFileReference" and pid not in preserved_refs:
            del objects[pid]
        elif isa == "PBXBuildFile":
            # A `productRef` build file links a Swift package product and has no file on disk for the scan to rediscover, so deleting it would unlink the package.
            if obj.get("productRef"):
                continue
            ref = obj.get("fileRef")
            if ref not in preserved_refs:
                del objects[pid]

    ref_of: dict[str, str] = {}
    group_children: dict[str, list[str]] = {}

    def make_group(node: Node) -> str:
        gid = oid("group", node.rel)
        children: list[str] = []
        for child in node.children:
            ext = os.path.splitext(child.name)[1].lower()
            if child.is_dir and ext not in BUNDLE_DIR_EXTS:
                children.append(make_group(child))
            else:
                children.append(make_ref(child))
        objects[gid] = {
            "isa": "PBXGroup",
            "children": children,
            "path": node.name,
            "sourceTree": "<group>",
        }
        group_children[gid] = children
        return gid

    def make_ref(node: Node) -> str:
        rid = oid("file", node.rel)
        objects[rid] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": file_type_for(node.name, node.is_dir),
            "path": node.name,
            "sourceTree": "<group>",
        }
        ref_of[node.rel] = rid
        return rid

    root_group_ids: list[str] = []
    for rel in NAVIGATOR_ROOTS:
        tree = scan(rel)
        root_group_ids.append(make_group(tree))

    targets_by_name: dict[str, dict] = {}
    for pid, obj in objects.items():
        if obj.get("isa") == "PBXNativeTarget":
            targets_by_name[obj["name"]] = obj

    for tname, spec in TARGETS.items():
        target = targets_by_name.get(tname)
        if target is None:
            raise SystemExit(f"error: target {tname} not found in project")
        target.pop("fileSystemSynchronizedGroups", None)

        excluded = set(spec["exclude"])
        sources: list[str] = []
        resources: list[str] = []
        for rel in spec["roots"]:
            for item in sorted(all_items(scan(rel)), key=lambda n: n.rel.lower()):
                if item.rel in excluded:
                    continue
                ext = os.path.splitext(item.name)[1].lower()
                if item.is_dir:
                    if ext in RESOURCE_DIR_EXTS:
                        resources.append(item.rel)
                elif ext in SOURCE_EXTS:
                    sources.append(item.rel)
        sources.extend(spec["extra_sources"])
        resources.extend(spec["extra_resources"])

        phases = {objects[p]["isa"]: p for p in target.get("buildPhases", [])}
        _attach(objects, ref_of, phases.get("PBXSourcesBuildPhase"), sources, tname, "Sources")
        _attach(objects, ref_of, phases.get("PBXResourcesBuildPhase"), resources, tname, "Resources")

    main_group_id = proj_obj["mainGroup"]
    top_level_extra = [
        pid for pid, obj in preserved_refs.items()
        if obj.get("sourceTree") not in ("BUILT_PRODUCTS_DIR",)
    ]
    top_level_extra.sort(key=lambda pid: preserved_refs[pid].get("path", ""))

    products_id = proj_obj["productRefGroup"]
    product_children = [
        pid for pid, obj in preserved_refs.items()
        if obj.get("sourceTree") == "BUILT_PRODUCTS_DIR"
    ]
    old_products = project["objects"].get(products_id, {}).get("children", [])
    product_children.sort(key=lambda pid: old_products.index(pid) if pid in old_products else 999)
    objects[products_id] = {
        "isa": "PBXGroup",
        "children": product_children,
        "name": "Products",
        "sourceTree": "<group>",
    }
    objects[main_group_id] = {
        "isa": "PBXGroup",
        "children": top_level_extra + root_group_ids + [products_id],
        "sourceTree": "<group>",
    }

    project["objects"] = objects
    return project

def _attach(objects, ref_of, phase_id, rel_paths, target_name, phase_label):
    if phase_id is None:
        if rel_paths:
            raise SystemExit(
                f"error: target {target_name} has no {phase_label} phase but needs one"
            )
        return
    files = []
    seen = set()
    for rel in rel_paths:
        if rel in seen:
            continue
        seen.add(rel)
        rid = ref_of.get(rel)
        if rid is None:
            raise SystemExit(f"error: {rel} is listed for {target_name} but is not on disk")
        bid = oid("buildfile", f"{target_name}:{phase_label}:{rel}")
        objects[bid] = {"isa": "PBXBuildFile", "fileRef": rid}
        files.append(bid)
    existing = [f for f in objects[phase_id].get("files", []) if f in objects]
    objects[phase_id]["files"] = files + [f for f in existing if f not in files]

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if project.pbxproj is not up to date")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would change without writing")
    args = parser.parse_args()

    project = load_project()
    archive_version = str(project.get("archiveVersion", "1"))
    object_version = str(project.get("objectVersion", "77"))
    project = rebuild(project)
    text = Writer(project["objects"]).dump(project["rootObject"], object_version, archive_version)

    with open(PBXPROJ, "r", encoding="utf-8") as fh:
        current = fh.read()

    if text == current:
        print("project.pbxproj is up to date")
        return 0

    if args.check:
        print("project.pbxproj is out of date; run Scripts/xcodeproj-sync", file=sys.stderr)
        return 1

    if args.dry_run:
        print(f"project.pbxproj would change ({len(current)} -> {len(text)} bytes)")
        return 0

    with tempfile.NamedTemporaryFile("w", suffix=".pbxproj", delete=False, encoding="utf-8") as tmp:
        tmp.write(text)
        tmp_path = tmp.name
    lint = subprocess.run(["plutil", "-lint", tmp_path], capture_output=True, text=True)
    if lint.returncode != 0:
        print("error: generated project.pbxproj failed plutil -lint, refusing to write",
              file=sys.stderr)
        print(lint.stdout + lint.stderr, file=sys.stderr)
        print(f"the rejected file was left at {tmp_path}", file=sys.stderr)
        return 1
    os.replace(tmp_path, PBXPROJ)
    print(f"project.pbxproj updated ({len(current)} -> {len(text)} bytes)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
