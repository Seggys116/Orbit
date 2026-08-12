#!/usr/bin/env python3
"""Orbit Chromium engine manager: the only reader and writer of Chromium/chromium-version.json.

Two ways to get a working build: `fetch` downloads Orbit's published build for the
pinned version (default, fast); `build --from-source` drives depot_tools/gclient/gn/ninja
against a real checkout under ThirdParty/chromium (hours, opt-in). Both redirect every
cache path under ThirdParty/ instead of the real home directory -- see build_env().

Every command takes --config: "shipping" (dcheck_always_on false, what users get) or
"dcheck" (true, what Debug builds and the live-engine suites run against). Each has its
own out directory, published asset and ThirdParty/prebuilt/<config> symlink.
"""

from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

MANIFEST_PATH = os.path.join(REPO_ROOT, "Chromium", "chromium-version.json")
GENERATED_DIR = os.path.join(REPO_ROOT, "Chromium", "Generated")
GENERATED_XCCONFIG = os.path.join(GENERATED_DIR, "Chromium.xcconfig")
OBSOLETE_ENGINE_CHOICE_FILE = os.path.join(GENERATED_DIR, "engine")
SWIFT_GENERATED_DIR = os.path.join(REPO_ROOT, "Orbit", "Generated")
SWIFT_VERSION_FILE = os.path.join(SWIFT_GENERATED_DIR, "ChromiumVersion.swift")

THIRDPARTY_DIR = os.path.join(REPO_ROOT, "ThirdParty")
DEPOT_TOOLS_DIR = os.path.join(THIRDPARTY_DIR, "depot_tools")
CHROMIUM_ROOT = os.path.join(THIRDPARTY_DIR, "chromium")  # gclient root: contains .gclient and src/
CHROMIUM_SRC = os.path.join(CHROMIUM_ROOT, "src")
GCLIENT_HOME = os.path.join(THIRDPARTY_DIR, ".gclient-home")
DOWNLOAD_CACHE = os.path.join(THIRDPARTY_DIR, "downloads")
DIST_DIR = os.path.join(THIRDPARTY_DIR, "dist")
ENGINE_LOCK_FILE = os.path.join(THIRDPARTY_DIR, ".engine-install.lock")

PREBUILT_ROOT = os.path.join(THIRDPARTY_DIR, "prebuilt")
OBSOLETE_CURRENT_LINK = os.path.join(PREBUILT_ROOT, "current")
MODE_MARKER = ".orbit-engine-mode"
CONFIG_MARKER = ".orbit-engine-config"

# Explicit, because dcheck_always_on defaults to true for a non-official build.
ENGINE_CONFIGS = {"shipping": False, "dcheck": True}
DEFAULT_ENGINE_CONFIG = "shipping"

# Written by Chromium/Embedder/bridge/orbit_bridge_api.cc from DCHECK_IS_ON().
ENGINE_MARKER_PREFIX = b"orbit-engine-build: dcheck="

# Chromium/Embedder reaches the checkout only through a symlink + BUILD.gn append
# (regenerated below every run) -- the gitignored checkout never keeps hand edits.
EMBEDDER_SOURCE_DIR = os.path.join(REPO_ROOT, "Chromium", "Embedder")
EMBEDDER_SYMLINK = os.path.join(CHROMIUM_SRC, "orbit")

ORBIT_ROOT_BUILD_GN_MARKER = "# --- Orbit embedder root, see Chromium/Embedder/BUILD.gn ---"
ORBIT_ROOT_BUILD_GN_APPEND = f"""
{ORBIT_ROOT_BUILD_GN_MARKER}
# Appended by Scripts/chromium (chromium_manager.py: patch_root_build_gn()).
# GN only defines targets reachable, through deps, from this file -- see the
# comment at the top of this file. //orbit/BUILD.gn (via the src/orbit
# symlink) is otherwise unreached, so nothing in it would ever be built.
# This is the one integration point; everything else Orbit's embedder needs
# lives in the Orbit repository, not here. Reapplied automatically after
# every checkout/sync, since this file is reset to upstream on a version
# bump like every other file in this checkout.
group("orbit_embedder") {{
  deps = [ "//orbit:orbit" ]
}}
"""

# "orbit" must be a static (non-component) build: a component build scatters
# Chromium's code as loose .dylibs outside the bundle, unreachable to a sandboxed child.
# out/Orbit is dcheck's because it predates the split and already holds that build.
BUILD_DIR_FOR_TARGET = {
    ("content_shell", "shipping"): "Release",
    ("content_shell", "dcheck"): "ReleaseDCheck",
    ("orbit", "shipping"): "OrbitShipping",
    ("orbit", "dcheck"): "Orbit",
}
DEFAULT_BUILD_DIR_NAME = "Release"

COMPONENT_BUILD_TARGETS = {"content_shell", "chrome"}

# What `ninja <build_target>` produces on macOS. Add an entry here before
# pinning `build_target` to anything not already listed.
BUILD_TARGET_ARTIFACTS = {
    "content_shell": "Content Shell.app",
    "chrome": "Chromium.app",
    "orbit": "Orbit Framework.framework",
}
# The Mach-O ninja actually links, inside the bundle above -- ninja creates the bundle
# shell early, so checking the bundle alone false-positives a build still hours from done.
BUILD_TARGET_EXECUTABLES = {
    "content_shell": os.path.join("Content Shell.app", "Contents", "MacOS", "Content Shell"),
    "chrome": os.path.join("Chromium.app", "Contents", "MacOS", "Chromium"),
    "orbit": os.path.join("Orbit Framework.framework", "Orbit Framework"),
}

CACHE_TTL_SECONDS = 6 * 60 * 60

_IS_TTY = sys.stdout.isatty()
_USE_COLOR = _IS_TTY and os.environ.get("NO_COLOR") is None

def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _USE_COLOR else text

def bold(t: str) -> str:
    return _c("1", t)

def dim(t: str) -> str:
    return _c("2", t)

def green(t: str) -> str:
    return _c("32", t)

def yellow(t: str) -> str:
    return _c("33", t)

def red(t: str) -> str:
    return _c("31", t)

def cyan(t: str) -> str:
    return _c("36", t)

def info(msg: str) -> None:
    print(f"{cyan('==>')} {msg}")

def step(msg: str) -> None:
    print(f"{dim('  ->')} {msg}")

def warn(msg: str) -> None:
    print(f"{yellow('warning:')} {msg}", file=sys.stderr)

def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    print(f"{red('error:')} {msg}", file=sys.stderr)
    sys.exit(code)

def human_bytes(n: int) -> str:
    if n <= 0:
        return "unknown"
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(n)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{value:.1f} TB"

def host_platform(strict: bool = True):
    """macOS arch key for this machine; `strict=False` returns None instead of exiting, for CI."""
    if sys.platform != "darwin":
        if not strict:
            return None
        die(f"Orbit's Chromium engine is macOS-only; this host reports '{sys.platform}'.")
    machine = platform.machine()
    if machine == "arm64":
        return "macosarm64"
    if machine == "x86_64":
        try:
            translated = subprocess.run(
                ["sysctl", "-n", "sysctl.proc_translated"],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            if translated == "1":
                return "macosarm64"
        except OSError:
            pass
        return "macosx64"
    if not strict:
        return None
    die(f"Unsupported macOS architecture '{machine}'.")

def gn_target_cpu(platform_key: str) -> str:
    return "arm64" if platform_key == "macosarm64" else "x64"

def check_config(config: str) -> str:
    if config not in ENGINE_CONFIGS:
        die(f"Unknown engine configuration '{config}'. Known: {', '.join(sorted(ENGINE_CONFIGS))}.")
    return config

def dcheck_always_on(config: str) -> bool:
    return ENGINE_CONFIGS[check_config(config)]

def build_dir_name_for(build_target: str, config: str) -> str:
    key = (build_target, check_config(config))
    if key in BUILD_DIR_FOR_TARGET:
        return BUILD_DIR_FOR_TARGET[key]
    return DEFAULT_BUILD_DIR_NAME + ("" if config == "shipping" else "DCheck")

def out_dir_for(build_target: str, config: str) -> str:
    return os.path.join(CHROMIUM_SRC, "out", build_dir_name_for(build_target, config))

def build_log_for(config: str) -> str:
    return os.path.join(CHROMIUM_ROOT, f"build-{check_config(config)}.log")

def config_link(config: str) -> str:
    return os.path.join(PREBUILT_ROOT, check_config(config))

def artifact_name(build_target: str) -> str:
    return BUILD_TARGET_ARTIFACTS.get(build_target, build_target)

def load_manifest() -> dict:
    if not os.path.exists(MANIFEST_PATH):
        die(
            f"Manifest missing: {MANIFEST_PATH}\n"
            "  This does not look like a complete Orbit checkout. Re-clone the repository, "
            "then run: Scripts/chromium sync"
        )
    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        die(f"Manifest is not valid JSON ({exc}). Fix {MANIFEST_PATH} by hand, then re-run.")
    except OSError as exc:
        die(f"Could not read {MANIFEST_PATH}: {exc}")

def save_manifest(manifest: dict) -> None:
    order = [
        "_readme",
        "chromium_repo_url",
        "channel",
        "chromium_version",
        "chromium_checkout",
        "build_target",
        "pinned_at",
        "prebuilt",
    ]
    ordered = {key: manifest[key] for key in order if key in manifest}
    for key, value in manifest.items():
        if key not in ordered:
            ordered[key] = value
    with open(MANIFEST_PATH, "w", encoding="utf-8") as handle:
        json.dump(ordered, handle, indent=2)
        handle.write("\n")

def chromium_major(chromium_version: str) -> str:
    return chromium_version.split(".")[0]

##
# Networking helpers: small upstream resources only; the multi-gigabyte checkout is gclient's job.
##

def http_get(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "Orbit-chromium-manager/3.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()

def cached_json(cache_path: str, ttl: int, refresh: bool, fetch):
    if not refresh and os.path.exists(cache_path):
        age = time.time() - os.path.getmtime(cache_path)
        if age < ttl:
            try:
                with open(cache_path, encoding="utf-8") as handle:
                    return json.load(handle)
            except (json.JSONDecodeError, OSError):
                pass
    data = fetch()
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    with open(cache_path, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    return data

def fetch_chrome_releases(channel: str, platform_key: str, limit: int = 10) -> list[str]:
    """Recent served versions for a Chrome channel, from Google's public version history API."""
    api_platform = "mac_arm64" if platform_key == "macosarm64" else "mac"
    url = (
        f"https://versionhistory.googleapis.com/v1/chrome/platforms/{api_platform}"
        f"/channels/{channel}/versions/all/releases"
        f"?filter=endtime=none&order_by=version%20desc&page_size={limit}"
    )
    try:
        payload = json.loads(http_get(url))
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        die(f"Could not reach the Chrome version history API: {exc}\n  Check the network and retry.")
    seen = []
    for release in payload.get("releases", []):
        version = release.get("version")
        if version and version not in seen:
            seen.append(version)
    if not seen:
        die(f"No {channel} releases reported for {api_platform}.")
    return seen

def chromium_tag_exists(repo_url: str, version: str) -> bool:
    result = subprocess.run(
        ["git", "ls-remote", "--tags", repo_url, f"refs/tags/{version}"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip() != ""

def repo_slug(manifest: dict) -> str:
    """'owner/repo' for GitHub Release asset URLs: an explicit override, or Orbit's own origin remote."""
    override = manifest.get("prebuilt", {}).get("repo")
    if override:
        return override
    try:
        url = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError, subprocess.TimeoutExpired) as exc:
        die(f"Could not read the 'origin' remote to find where the prebuilt is published: {exc}")
    match = re.search(r"github\.com[:/]([^/]+)/([^/.]+?)(\.git)?/?$", url)
    if not match:
        die(f"'{url}' does not look like a GitHub remote; set prebuilt.repo in the manifest.")
    return f"{match.group(1)}/{match.group(2)}"

##
# Build environment: every source-build subprocess gets depot_tools first on PATH, with
# gclient/gn/cipd/vpython caches redirected under ThirdParty/ instead of the real $HOME.
##

def build_env() -> dict:
    env = dict(os.environ)
    env["PATH"] = DEPOT_TOOLS_DIR + os.pathsep + env.get("PATH", "")
    for sub in ("", ".cache", ".config", os.path.join(".local", "share"), ".cipd-cache", ".vpython-root"):
        os.makedirs(os.path.join(GCLIENT_HOME, sub), exist_ok=True)
    env["HOME"] = GCLIENT_HOME
    env["XDG_CACHE_HOME"] = os.path.join(GCLIENT_HOME, ".cache")
    env["XDG_CONFIG_HOME"] = os.path.join(GCLIENT_HOME, ".config")
    env["XDG_DATA_HOME"] = os.path.join(GCLIENT_HOME, ".local", "share")
    env["CIPD_CACHE_DIR"] = os.path.join(GCLIENT_HOME, ".cipd-cache")
    env["VPYTHON_VIRTUALENV_ROOT"] = os.path.join(GCLIENT_HOME, ".vpython-root")
    env["DEPOT_TOOLS_UPDATE"] = "0"
    env["DEPOT_TOOLS_METRICS"] = "0"
    env["DEPOT_TOOLS_COLLECT_METRICS"] = "0"
    return env

def ensure_depot_tools_submodule() -> None:
    if not os.path.isfile(os.path.join(DEPOT_TOOLS_DIR, "gclient.py")):
        info("Initialising the depot_tools submodule")
        result = subprocess.run(
            ["git", "submodule", "update", "--init", "--depth", "1", "--", "ThirdParty/depot_tools"],
            cwd=REPO_ROOT,
            check=False,
        )
        if result.returncode != 0 or not os.path.isfile(os.path.join(DEPOT_TOOLS_DIR, "gclient.py")):
            die(
                "Could not initialise ThirdParty/depot_tools.\n"
                "  Check that .gitmodules is present and that the submodule can reach its remote, "
                "then retry."
            )

    # Skips update_depot_tools' normal write here -- it would move the pinned HEAD via
    # git checkout -- and runs its non-git equivalent instead.
    marker = os.path.join(DEPOT_TOOLS_DIR, "python3_bin_reldir.txt")
    if not os.path.isfile(marker):
        info("Bootstrapping depot_tools' pinned Python (ensure_bootstrap)")
        result = subprocess.run(["./ensure_bootstrap"], cwd=DEPOT_TOOLS_DIR, env=build_env(), check=False)
        if result.returncode != 0 or not os.path.isfile(marker):
            die("ThirdParty/depot_tools/ensure_bootstrap failed. Check the network and retry.")

def run_streamed(command: list[str], cwd: str, env: dict, log_path: str | None = None) -> int:
    """Streams output live (a source build can run for hours) and, if given, tees it to a log file."""
    info(f"Running: {' '.join(command)}")
    log_handle = open(log_path, "w", encoding="utf-8") if log_path else None
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    try:
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if log_handle:
                log_handle.write(line)
    finally:
        if log_handle:
            log_handle.close()
    return process.wait()

##
# Generated build inputs.
##

GENERATED_BANNER = (
    "// GENERATED FILE - DO NOT EDIT.\n"
    "//\n"
    "// Written by Scripts/chromium from Chromium/chromium-version.json.\n"
    "// To change the Chromium version, edit that manifest (or run\n"
    "// `Scripts/chromium pin <version>`) and re-run `Scripts/chromium sync`.\n"
)

def install_dir_for(chromium_version: str, config: str) -> str:
    return os.path.join(PREBUILT_ROOT, f"{chromium_version}-{check_config(config)}")

def _artifact_present(root: str, build_target: str) -> bool:
    executable_rel = BUILD_TARGET_EXECUTABLES.get(build_target)
    if executable_rel is None:
        # Unknown target: the packaged artifact is whatever ninja names it directly (a binary,
        # not a bundle), so existence of that path is the only signal we have.
        return os.path.exists(os.path.join(root, artifact_name(build_target)))
    executable = os.path.join(root, executable_rel)
    return os.path.isfile(executable) and os.access(executable, os.X_OK) and os.path.getsize(executable) > 0

def candidate_install_roots(manifest: dict, config: str) -> list[str]:
    return [
        install_dir_for(manifest["chromium_version"], config),
        out_dir_for(manifest["build_target"], config),
    ]

def matching_install_root(manifest: dict, config: str) -> str | None:
    """The install directory for the *currently pinned* version and `config`, if complete."""
    for root in candidate_install_roots(manifest, config):
        if _artifact_present(root, manifest["build_target"]):
            return root
    return None

def engine_install_state(manifest: dict, config: str) -> tuple:
    """Returns (state, detail): "installed" and its path, or "absent".

    Checked against the version pinned now, not the config symlink -- a version
    bump must not read "installed" from an older build still sitting there.
    """
    root = matching_install_root(manifest, config)
    if root:
        return "installed", os.path.relpath(root, REPO_ROOT)
    return "absent", ""

def engine_is_installed(manifest: dict, config: str) -> bool:
    return engine_install_state(manifest, config)[0] == "installed"

def read_marker(root: str, marker: str) -> str | None:
    try:
        with open(os.path.join(root, marker), encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return None

def engine_mode(config: str) -> str | None:
    link = config_link(config)
    if not os.path.islink(link):
        return None
    return read_marker(os.path.realpath(link), MODE_MARKER)

def write_engine_markers(root: str, mode: str, config: str) -> None:
    for marker, value in ((MODE_MARKER, mode), (CONFIG_MARKER, check_config(config))):
        with open(os.path.join(root, marker), "w", encoding="utf-8") as handle:
            handle.write(value + "\n")

def compiled_engine_config(root: str, build_target: str) -> str | None:
    """The configuration the engine binary itself reports, or None if it carries no marker."""
    executable_rel = BUILD_TARGET_EXECUTABLES.get(build_target)
    if executable_rel is None:
        return None
    executable = os.path.join(root, executable_rel)
    if not os.path.isfile(executable):
        return None
    found = None
    tail = b""
    with open(executable, "rb") as handle:
        while True:
            chunk = handle.read(8 * 1024 * 1024)
            if not chunk:
                break
            window = tail + chunk
            start = window.find(ENGINE_MARKER_PREFIX)
            if start != -1:
                value = window[start + len(ENGINE_MARKER_PREFIX):start + len(ENGINE_MARKER_PREFIX) + 1]
                found = {b"1": "dcheck", b"0": "shipping"}.get(value)
                break
            tail = window[-(len(ENGINE_MARKER_PREFIX) + 1):]
    return found

def display_path(path: str) -> str:
    relative = os.path.relpath(path, REPO_ROOT)
    return path if relative.startswith("..") else relative

def assert_compiled_config(root: str, build_target: str, config: str) -> None:
    compiled = compiled_engine_config(root, build_target)
    where = display_path(root)
    if compiled == config:
        return
    if compiled is None:
        die(
            f"The engine at {where} carries no configuration marker, so whether its DCHECKs are "
            f"compiled in cannot be established.\n"
            "  It was built before the shipping/dcheck split; rebuild it: "
            f"Scripts/chromium build --from-source --config {config}"
        )
    die(
        f"The engine at {where} is a '{compiled}' build but is installed as '{config}'.\n"
        f"  dcheck_always_on is {str(dcheck_always_on(compiled)).lower()} in it, not "
        f"{str(dcheck_always_on(config)).lower()}. A shipping Orbit built against a dcheck engine "
        "turns every upstream development assertion into a fatal abort in a user's browser.\n"
        f"  Rebuild or re-fetch: Scripts/chromium fetch --config {config} --force"
    )

def relink_config(config: str, install_root: str) -> None:
    """Left alone when already correct: relinking would bump mtimes for no reason."""
    os.makedirs(PREBUILT_ROOT, exist_ok=True)
    link = config_link(config)
    if os.path.islink(link) and os.path.realpath(link) == os.path.realpath(install_root):
        return
    if os.path.islink(link):
        os.unlink(link)
    elif os.path.exists(link):
        die(f"{os.path.relpath(link, REPO_ROOT)} exists and is not a symlink; remove it by hand and re-run.")
    os.symlink(os.path.relpath(install_root, PREBUILT_ROOT), link)

def write_if_changed(path: str, text: str) -> bool:
    """Both generated files are build inputs, so an identical rewrite would bump mtimes and recompile the world."""
    try:
        with open(path, encoding="utf-8") as handle:
            if handle.read() == text:
                return False
    except OSError:
        pass
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True

def discard_obsolete_engine_choice() -> bool:
    try:
        os.remove(OBSOLETE_ENGINE_CHOICE_FILE)
        return True
    except OSError:
        return False

def discard_obsolete_current_link() -> bool:
    if not os.path.islink(OBSOLETE_CURRENT_LINK):
        return False
    os.unlink(OBSOLETE_CURRENT_LINK)
    return True

def write_generated_xcconfig(manifest: dict) -> None:
    os.makedirs(GENERATED_DIR, exist_ok=True)
    chromium_version = manifest["chromium_version"]

    lines = [
        GENERATED_BANNER,
        "",
        f"ORBIT_CHROMIUM_VERSION = {chromium_version}",
        f"ORBIT_CHROMIUM_CHANNEL = {manifest.get('channel', 'stable')}",
        f"ORBIT_CHROMIUM_MAJOR = {chromium_major(chromium_version)}",
        f"ORBIT_CHROMIUM_BUILD_TARGET = {manifest.get('build_target', 'content_shell')}",
        "",
        "// The path values (ORBIT_CHROMIUM_ROOT etc.) are already correct in the",
        "// committed Chromium.xcconfig -- see the comment there for why this",
        "// overlay only carries version values.",
    ]

    write_if_changed(GENERATED_XCCONFIG, "\n".join(lines) + "\n")

def write_generated_swift(manifest: dict) -> None:
    os.makedirs(SWIFT_GENERATED_DIR, exist_ok=True)
    chromium_version = manifest["chromium_version"]
    major = chromium_major(chromium_version)

    user_agent_product = f"Chrome/{major}.0.0.0"
    user_agent = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        f"(KHTML, like Gecko) {user_agent_product} Safari/537.36"
    )

    body = f'''{GENERATED_BANNER}
import Foundation

/// Facts about the Chromium build Orbit is compiled against.
///
/// Every value here comes from `Chromium/chromium-version.json`. Nothing in the
/// app hardcodes a Chromium version; read it from this type instead.
public enum ChromiumBuild {{

    /// Full Chromium version, e.g. `151.0.7922.109`.
    public static let version = "{chromium_version}"

    /// Chromium major version, e.g. `151`. This is what sites see.
    public static let majorVersion = {major}

    /// Upstream release channel the pin was taken from.
    public static let channel = "{manifest.get("channel", "stable")}"

    /// Date the version pin was last moved (ISO-8601).
    public static let pinnedAt = "{manifest.get("pinned_at", "")}"

    /// The user agent Orbit presents to websites, matching stock Chrome for this
    /// Chromium major so that sites serve Orbit their Chrome experience.
    public static let userAgent = "{user_agent}"

    /// The product token used to build the default Chrome-style User-Agent string.
    public static let userAgentProduct = "{user_agent_product}"

    /// Short human-readable engine description for the About window, the
    /// General settings pane and the "About Orbit" command.
    public static let engineDescription = "Chromium \\(version)"
}}
'''
    write_if_changed(SWIFT_VERSION_FILE, body)

def do_sync(manifest: dict, quiet: bool = False) -> None:
    discarded_choice = discard_obsolete_engine_choice()
    discarded_link = discard_obsolete_current_link()

    try:
        write_generated_xcconfig(manifest)
        write_generated_swift(manifest)
    except OSError as exc:
        die(
            f"Could not write the generated build inputs: {exc}\n"
            f"  Check that {os.path.relpath(GENERATED_DIR, REPO_ROOT)} and "
            f"{os.path.relpath(SWIFT_GENERATED_DIR, REPO_ROOT)} are writable, then re-run: "
            "Scripts/chromium sync"
        )

    if quiet:
        return

    info(f"Regenerated build inputs for Chromium {manifest['chromium_version']}")
    step(os.path.relpath(GENERATED_XCCONFIG, REPO_ROOT))
    step(os.path.relpath(SWIFT_VERSION_FILE, REPO_ROOT))
    if discarded_choice:
        step(os.path.relpath(OBSOLETE_ENGINE_CHOICE_FILE, REPO_ROOT) + dim("  removed (obsolete engine-choice marker)"))
    if discarded_link:
        step(os.path.relpath(OBSOLETE_CURRENT_LINK, REPO_ROOT) + dim("  removed (superseded by the per-configuration links)"))
    print()

    print(f"  Chromium version  {green(manifest['chromium_version'])}  ({manifest.get('channel', 'stable')})")
    for config in sorted(ENGINE_CONFIGS):
        state, detail = engine_install_state(manifest, config)
        label = f"  {config:<16}"
        if state == "installed":
            print(f"{label}{dim(detail)}  {dim('-- ' + (engine_mode(config) or 'unknown'))}")
        else:
            print(f"{label}{yellow('not installed yet')}  {dim('run: Scripts/chromium fetch --config ' + config)}")
    print(f"  Next              {bold('open Orbit.xcodeproj')} and build the Orbit scheme")

##
# Version resolution and pinning.
##

def cmd_pin(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    platform_key = host_platform(strict=False) or "macosarm64"
    normalized = args.version.strip().lower()

    if normalized in ("latest", "stable", "latest-stable"):
        channel = "stable"
        version = fetch_chrome_releases(channel, platform_key, limit=1)[0]
    elif normalized in ("beta", "latest-beta"):
        channel = "beta"
        version = fetch_chrome_releases(channel, platform_key, limit=1)[0]
    elif re.fullmatch(r"\d+\.\d+\.\d+\.\d+", args.version.strip()):
        channel = manifest.get("channel", "stable")
        version = args.version.strip()
    else:
        die(f"Could not resolve '{args.version}'. Use 'latest', 'latest-beta', or a full Chromium version.")

    if not chromium_tag_exists(manifest["chromium_repo_url"], version):
        die(f"Chromium has no tag '{version}' at {manifest['chromium_repo_url']}.")

    if version == manifest.get("chromium_version") and not args.force:
        info(f"Already pinned to Chromium {version}. Nothing to do.")
        do_sync(manifest, quiet=True)
        return 0

    previous = manifest.get("chromium_version", "none")

    manifest["channel"] = channel
    manifest["chromium_version"] = version
    manifest["chromium_checkout"] = f"refs/tags/{version}"
    manifest["pinned_at"] = datetime.date.today().isoformat()
    manifest.setdefault("prebuilt", {})["release_tag"] = f"chromium-{version}"
    manifest["prebuilt"].pop("platforms", None)
    # the old pin's published builds no longer match this version
    manifest["prebuilt"]["configs"] = {name: {"platforms": {}} for name in sorted(ENGINE_CONFIGS)}
    save_manifest(manifest)

    info(f"Pinned Chromium {previous} -> {green(version)}  ({channel})")
    step(f"manifest: {os.path.relpath(MANIFEST_PATH, REPO_ROOT)}")
    do_sync(manifest, quiet=True)

    print()
    print(f"Next: {bold('Scripts/chromium build --from-source')}  {dim('and again with --config dcheck, then publish both')}")
    return 0

def version_tuple(version: str) -> tuple:
    return tuple(int(part) for part in version.split("."))

def cmd_check_latest(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    channel = manifest.get("channel", "stable")
    pinned = manifest["chromium_version"]

    if args.require_stable and channel != "stable":
        die(
            f"The manifest is pinned to the {channel} channel, not stable.\n"
            "  A release must ship a stable Chromium. Run: Scripts/chromium pin latest"
        )
    latest = fetch_chrome_releases(channel, host_platform(strict=False) or "macosarm64", limit=1)[0]

    if version_tuple(pinned) >= version_tuple(latest):
        info(green(f"Chromium {pinned} is the newest {channel} release."))
        return 0

    die(
        f"Chromium {pinned} is behind the newest {channel} release, {latest}.\n"
        "  A Chrome patch release is a security release; shipping the older one ships the bugs it fixes.\n"
        "  Run the 'Chromium update' workflow (or wait for its daily run), merge the pin it opens\n"
        f"  once its build is green, then re-tag from that commit."
    )

def read_chrome_version(version_file: str) -> str:
    parts = {}
    with open(version_file, encoding="utf-8") as handle:
        for line in handle:
            if "=" in line:
                key, _, value = line.strip().partition("=")
                parts[key] = value
    return ".".join(parts.get(k, "0") for k in ("MAJOR", "MINOR", "BUILD", "PATCH"))

def du(path: str) -> str:
    try:
        result = subprocess.run(["du", "-sh", path], capture_output=True, text=True, timeout=120, check=False)
        if result.returncode == 0:
            return result.stdout.split("\t", 1)[0].strip()
    except (subprocess.TimeoutExpired, OSError):
        pass
    return "unknown"

def prebuilt_platforms(manifest: dict, config: str) -> dict:
    configs = manifest.get("prebuilt", {}).get("configs", {})
    return configs.get(check_config(config), {}).get("platforms", {})

def cmd_status(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    platform_key = args.platform or host_platform(strict=False) or "macosarm64"
    build_target = manifest.get("build_target", "content_shell")

    print(bold("Orbit Chromium build"))
    print(f"  Pinned version    {green(manifest['chromium_version'])}  ({manifest.get('channel', 'stable')})")
    print(f"  Build target      {build_target}")
    print(f"  Pinned on         {manifest.get('pinned_at', 'unknown')}")
    print(f"  Host platform     {platform_key}")
    if os.path.exists(OBSOLETE_ENGINE_CHOICE_FILE):
        print("  Stale marker      " + yellow(os.path.relpath(OBSOLETE_ENGINE_CHOICE_FILE, REPO_ROOT)) + dim("  run: Scripts/chromium sync"))

    for config in sorted(ENGINE_CONFIGS):
        state, detail = engine_install_state(manifest, config)
        print()
        print(bold(f"Engine configuration '{config}'") + dim(f"  dcheck_always_on = {str(dcheck_always_on(config)).lower()}"))
        print(f"  Out directory     {dim('out/' + build_dir_name_for(build_target, config))}")
        if state == "installed":
            root = matching_install_root(manifest, config)
            compiled = compiled_engine_config(root, build_target)
            print(f"  Installed         {green('yes')}  {dim(detail)}  {dim('-- ' + (engine_mode(config) or 'unknown'))}")
            if compiled is None:
                print(f"  Binary reports    {yellow('no marker')}  {dim('built before the configuration split')}")
            elif compiled == config:
                print(f"  Binary reports    {green(compiled)}")
            else:
                print(f"  Binary reports    {red(compiled)}  {dim('run: Scripts/chromium verify-engine --config ' + config)}")
        else:
            print(f"  Installed         {yellow('no')}")
        entry = prebuilt_platforms(manifest, config).get(platform_key)
        if entry:
            print(f"  Published         {green('yes')}  {dim(entry.get('asset', ''))}  {human_bytes(entry.get('size', 0))}")
        else:
            print(f"  Published         {yellow('no')}  {dim('run: Scripts/chromium build --from-source --config ' + config + ', then package/record-prebuilt')}")

    print()
    print(bold("Source checkout (build --from-source)"))
    depot_tools_ok = os.path.isfile(os.path.join(DEPOT_TOOLS_DIR, "gclient.py"))
    print(f"  depot_tools       " + (green("present") if depot_tools_ok else dim("not initialised")))
    chromium_present = os.path.isdir(CHROMIUM_SRC)
    if chromium_present:
        print(f"  Chromium src      {green(os.path.relpath(CHROMIUM_SRC, REPO_ROOT))}")
        version_file = os.path.join(CHROMIUM_SRC, "chrome", "VERSION")
        if os.path.isfile(version_file):
            checked_out = read_chrome_version(version_file)
            marker = "" if checked_out == manifest["chromium_version"] else yellow(f"  <- pin is {manifest['chromium_version']}")
            print(f"  Checked out       {checked_out}{marker}")
        print(f"  Disk used         {dim(du(CHROMIUM_ROOT))}")
    else:
        print(f"  Chromium src      {dim('not fetched (only needed for --from-source)')}")

    print()
    total, used, free = shutil.disk_usage(REPO_ROOT)
    print(f"{bold('Disk free on volume')}  {human_bytes(free)}")

    if args.offline:
        return 0

    print()
    print(bold("Upstream"))
    try:
        latest = fetch_chrome_releases("stable", platform_key, limit=1)[0]
        marker = "" if latest == manifest["chromium_version"] else yellow("  <- newer than the pin; run `Scripts/chromium pin latest`")
        print(f"  Latest stable     {latest}{marker}")
    except SystemExit:
        pass
    return 0

##
# Mode 1: consume a published build (default).
##

def download(url: str, destination: str, expected_size: int) -> None:
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    partial = destination + ".part"
    request = urllib.request.Request(url, headers={"User-Agent": "Orbit-chromium-manager/3.0"})

    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            total = int(response.headers.get("Content-Length") or expected_size or 0)
            written = 0
            last_report = 0.0
            next_milestone = 5
            with open(partial, "wb") as handle:
                while True:
                    chunk = response.read(1024 * 256)
                    if not chunk:
                        break
                    handle.write(chunk)
                    written += len(chunk)
                    pct = (written * 100.0 / total) if total else 0.0
                    if _IS_TTY:
                        now = time.time()
                        if now - last_report > 0.25:
                            last_report = now
                            if total:
                                bar_width = 32
                                filled = int(bar_width * written / total)
                                bar = "#" * filled + "." * (bar_width - filled)
                                sys.stdout.write(f"\r  [{bar}] {pct:5.1f}%  {human_bytes(written)} / {human_bytes(total)}")
                            else:
                                sys.stdout.write(f"\r  {human_bytes(written)}")
                            sys.stdout.flush()
                    elif total and pct >= next_milestone:
                        while next_milestone <= pct:
                            next_milestone += 5
                        print(f"  downloaded {pct:5.1f}%  {human_bytes(written)} / {human_bytes(total)}", flush=True)
            if _IS_TTY:
                sys.stdout.write("\r" + " " * 78 + "\r")
                sys.stdout.flush()
    except (urllib.error.URLError, OSError) as exc:
        if os.path.exists(partial):
            os.remove(partial)
        die(f"Download failed: {exc}\n  url: {url}\n  Reconnect and retry: Scripts/chromium fetch")

    os.replace(partial, destination)

def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def extract_tar(archive_path: str, install_root: str) -> None:
    staging = install_root + ".staging"
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    os.makedirs(staging, exist_ok=True)

    with tarfile.open(archive_path, "r:*") as tar:
        for member in tar.getmembers():
            if member.name.startswith("/") or ".." in member.name.split("/"):
                die(f"Archive contains an unsafe path: {member.name}")
        tar.extractall(staging)

    entries = [e for e in os.listdir(staging) if not e.startswith(".")]
    source = os.path.join(staging, entries[0]) if len(entries) == 1 and os.path.isdir(os.path.join(staging, entries[0])) else staging

    if os.path.isdir(install_root):
        shutil.rmtree(install_root)
    os.makedirs(os.path.dirname(install_root), exist_ok=True)
    shutil.move(source, install_root)
    if os.path.isdir(staging):
        shutil.rmtree(staging)

def install_prebuilt(manifest: dict, config: str) -> None:
    platform_key = host_platform()
    entry = prebuilt_platforms(manifest, config).get(platform_key)
    if not entry or not entry.get("asset"):
        die(
            f"No published '{config}' build for Chromium {manifest['chromium_version']} on {platform_key}.\n"
            f"  Either build it yourself: Scripts/chromium build --from-source --config {config}\n"
            f"  (then Scripts/chromium package --config {config} && Scripts/chromium record-prebuilt), or\n"
            "  wait for the release job to publish one and re-run `Scripts/chromium pin` to pick it up."
        )

    slug = repo_slug(manifest)
    tag = manifest["prebuilt"].get("release_tag", f"chromium-{manifest['chromium_version']}")
    url = f"https://github.com/{slug}/releases/download/{tag}/{entry['asset']}"
    archive_path = os.path.join(DOWNLOAD_CACHE, entry["asset"])
    install_root = install_dir_for(manifest["chromium_version"], config)

    info(f"Installing Chromium {manifest['chromium_version']} ({manifest['build_target']}, {config}) for {platform_key}")

    need_download = True
    if os.path.exists(archive_path):
        step("Verifying cached download")
        if entry.get("sha256") and sha256_of(archive_path) == entry["sha256"]:
            need_download = False
            step("Cached archive is valid, skipping download")
        else:
            warn("Cached archive failed verification; downloading again.")
            os.remove(archive_path)

    if need_download:
        step(f"Downloading {human_bytes(entry.get('size', 0))} from {url}")
        download(url, archive_path, entry.get("size", 0))
        if not entry.get("sha256"):
            # Fail closed: this binary runs in every Orbit process.
            os.remove(archive_path)
            die("No checksum recorded for this download; refusing to install unverified code.")
        step("Verifying SHA-256")
        actual = sha256_of(archive_path)
        if actual != entry["sha256"]:
            os.remove(archive_path)
            die(
                f"Checksum mismatch on {entry['asset']}.\n"
                f"  expected {entry['sha256']}\n  actual   {actual}\n"
                "  The corrupt archive has been deleted; the build was NOT installed. Re-run: Scripts/chromium fetch"
            )

    step(f"Extracting to {os.path.relpath(install_root, REPO_ROOT)}")
    extract_tar(archive_path, install_root)
    write_engine_markers(install_root, "prebuilt", config)
    relink_config(config, install_root)
    do_sync(manifest, quiet=True)

    state, detail = engine_install_state(manifest, config)
    if state != "installed":
        die(f"The build is still missing its artifact after installing (expected {artifact_name(manifest['build_target'])}). Re-run: Scripts/chromium fetch --force")
    assert_compiled_config(install_root, manifest["build_target"], config)

def cmd_fetch(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    config = check_config(args.config)

    if engine_is_installed(manifest, config) and not args.force:
        info(f"Chromium {manifest['chromium_version']} ({config}) is already installed.")
        relink_config(config, matching_install_root(manifest, config))
        do_sync(manifest)
        return 0

    with engine_lock():
        install_prebuilt(manifest, config)

    print()
    info(green(f"Chromium {manifest['chromium_version']} ({config}) is installed."))
    print(dim("  Reopen or rebuild the Xcode project to pick up the new engine."))
    return 0

##
# Mode 2: build from source (opt-in).
##

class engine_lock:
    """Advisory flock serialising engine installation: the second process blocks, then finds nothing to do."""

    def __init__(self, announce: bool = True):
        self.announce = announce
        self.handle = None

    def __enter__(self):
        os.makedirs(os.path.dirname(ENGINE_LOCK_FILE), exist_ok=True)
        self.handle = open(ENGINE_LOCK_FILE, "w", encoding="utf-8")
        try:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if self.announce:
                info("Another process is installing the Chromium engine; waiting for it to finish.")
                sys.stdout.flush()
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *_exc):
        if self.handle is not None:
            try:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            finally:
                self.handle.close()
                self.handle = None
        return False

def write_gclient_config(manifest: dict) -> None:
    os.makedirs(CHROMIUM_ROOT, exist_ok=True)
    gclient_file = os.path.join(CHROMIUM_ROOT, ".gclient")
    url = f"{manifest['chromium_repo_url']}@{manifest['chromium_version']}"
    spec = (
        "solutions = [{"
        "'name': 'src', "
        f"'url': '{url}', "
        "'deps_file': 'DEPS', "
        "'managed': True, "  # this checkout is entirely tool-managed; let gclient reset it cleanly
        "'custom_deps': {}, "
        "}]\n"
    )
    write_if_changed(gclient_file, spec)

def checkout_chromium(manifest: dict, env: dict, force: bool) -> None:
    write_gclient_config(manifest)
    version_file = os.path.join(CHROMIUM_SRC, "chrome", "VERSION")
    checked_out = read_chrome_version(version_file) if os.path.isfile(version_file) else None

    if checked_out == manifest["chromium_version"] and not force:
        info(f"Chromium src already at {manifest['chromium_version']}; skipping sync.")
        link_embedder_source()
        patch_root_build_gn()
        return

    info(f"Syncing Chromium {manifest['chromium_version']} (--no-history)")
    args = ["gclient", "sync", "--no-history", "--nohooks"]
    if checked_out is not None:
        args += ["--reset", "--force", "--delete_unversioned_trees"]
    status = run_streamed(args, cwd=CHROMIUM_ROOT, env=env, log_path=os.path.join(CHROMIUM_ROOT, "sync.log"))
    if status != 0:
        die(f"gclient sync failed (exit {status}). See {os.path.relpath(CHROMIUM_ROOT, REPO_ROOT)}/sync.log")

    info("Running gclient hooks (toolchain, sysroots)")
    status = run_streamed(["gclient", "runhooks"], cwd=CHROMIUM_ROOT, env=env)
    if status != 0:
        die(f"gclient runhooks failed (exit {status}).")

    link_embedder_source()
    patch_root_build_gn()

def link_embedder_source() -> None:
    """Makes //orbit resolve, inside the checkout, to Orbit's own repo-owned GN+C++ tree.

    A symlink, not a copy: `gclient sync --delete_unversioned_trees` skips symlinks
    (gclient_scm.py), so this is what survives a resync or fresh clone without writing
    into the checkout.
    """
    if not os.path.isdir(EMBEDDER_SOURCE_DIR):
        die(f"Missing {os.path.relpath(EMBEDDER_SOURCE_DIR, REPO_ROOT)}; this checkout is incomplete.")
    target = os.path.relpath(EMBEDDER_SOURCE_DIR, os.path.dirname(EMBEDDER_SYMLINK))
    if os.path.islink(EMBEDDER_SYMLINK):
        if os.readlink(EMBEDDER_SYMLINK) == target:
            return
        os.unlink(EMBEDDER_SYMLINK)
    elif os.path.exists(EMBEDDER_SYMLINK):
        die(f"{EMBEDDER_SYMLINK} exists and is not a symlink; remove it by hand and re-run.")
    os.symlink(target, EMBEDDER_SYMLINK)

def patch_root_build_gn() -> None:
    """Makes //orbit:orbit reachable from GN's discovery root.

    GN only defines targets reached, via deps, from the root build file, so a symlinked
    directory nothing depends on is never parsed. The root BUILD.gn is reset to upstream
    on every version bump, so this reapplies its group() append every checkout_chromium() run.
    """
    root_build_gn = os.path.join(CHROMIUM_SRC, "BUILD.gn")
    if not os.path.isfile(root_build_gn):
        die(f"Missing {os.path.relpath(root_build_gn, REPO_ROOT)}; this checkout is incomplete.")
    with open(root_build_gn, encoding="utf-8") as handle:
        contents = handle.read()
    if ORBIT_ROOT_BUILD_GN_MARKER in contents:
        return
    with open(root_build_gn, "a", encoding="utf-8") as handle:
        handle.write(ORBIT_ROOT_BUILD_GN_APPEND)

def gn_args_for(manifest: dict, platform_key: str, config: str) -> str:
    build_target = manifest.get("build_target", "content_shell")
    return "\n".join(
        [
            "is_debug = false",
            f"is_component_build = {'true' if build_target in COMPONENT_BUILD_TARGETS else 'false'}",
            "symbol_level = 0",
            f'target_cpu = "{gn_target_cpu(platform_key)}"',
            f"dcheck_always_on = {'true' if dcheck_always_on(config) else 'false'}",
            # EXPENSIVE_DCHECK()s DCHECK-crash the renderer on the first SVG page (CSSDefaultStyleSheets).
            "enable_expensive_dchecks = false",
        ]
    ) + "\n"

def gn_gen(manifest: dict, platform_key: str, env: dict, config: str) -> None:
    build_target = manifest.get("build_target", "content_shell")
    out_dir = out_dir_for(build_target, config)
    os.makedirs(out_dir, exist_ok=True)
    write_if_changed(os.path.join(out_dir, "args.gn"), gn_args_for(manifest, platform_key, config))

    info("Generating build files (gn gen)")
    status = run_streamed(["gn", "gen", f"out/{build_dir_name_for(build_target, config)}"], cwd=CHROMIUM_SRC, env=env)
    if status != 0:
        die(f"gn gen failed (exit {status}). Check the toolchain with: Scripts/chromium doctor --from-source")

def ninja_build(manifest: dict, env: dict, config: str) -> None:
    target = manifest.get("build_target", "content_shell")
    log_path = build_log_for(config)
    info(f"Building '{target}' ({config}, autoninja) -- this is the long step, hours on the first build")
    status = run_streamed(
        ["autoninja", "-C", f"out/{build_dir_name_for(target, config)}", target],
        cwd=CHROMIUM_SRC,
        env=env,
        log_path=log_path,
    )
    if status != 0:
        die(
            f"The Chromium build failed (exit {status}). See the output above or "
            f"{os.path.relpath(log_path, REPO_ROOT)}.\n"
            "  Check the toolchain with `Scripts/chromium doctor --from-source`, then re-run: "
            f"Scripts/chromium build --from-source --config {config}"
        )

def cmd_build(args: argparse.Namespace) -> int:
    if not args.from_source:
        die("Nothing to do: pass --from-source to build Chromium from source (this is the opt-in, hours-long path).")

    manifest = load_manifest()
    platform_key = host_platform()
    config = check_config(args.config)

    with engine_lock():
        ensure_depot_tools_submodule()
        env = build_env()
        checkout_chromium(manifest, env, force=args.force)
        gn_gen(manifest, platform_key, env, config)
        ninja_build(manifest, env, config)

        out_dir = out_dir_for(manifest["build_target"], config)
        write_engine_markers(out_dir, "source", config)
        relink_config(config, out_dir)
        do_sync(manifest, quiet=True)

    state, detail = engine_install_state(manifest, config)
    if state != "installed":
        die(f"The build finished but {artifact_name(manifest['build_target'])} is missing from {os.path.relpath(out_dir, REPO_ROOT)}.")
    assert_compiled_config(out_dir, manifest["build_target"], config)

    print()
    info(green(f"Chromium {manifest['chromium_version']} ({config}) built from source."))
    print(dim(f"  {os.path.relpath(out_dir, REPO_ROOT)}"))
    print(dim(f"  Next: Scripts/chromium package --config {config} && Scripts/chromium record-prebuilt   to publish this build."))
    return 0

def cmd_package(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    config = check_config(args.config)
    if engine_mode(config) != "source":
        die(f"ThirdParty/prebuilt/{config} is not a source build. Run: Scripts/chromium build --from-source --config {config}")

    platform_key = host_platform()
    root = os.path.realpath(config_link(config))
    artifact = os.path.join(root, artifact_name(manifest["build_target"]))
    if not _artifact_present(root, manifest["build_target"]):
        die(f"Build is incomplete: no linked executable inside {artifact}. Re-run: Scripts/chromium build --from-source --config {config}")
    assert_compiled_config(root, manifest["build_target"], config)

    os.makedirs(DIST_DIR, exist_ok=True)
    asset_name = f"orbit-chromium-{manifest['chromium_version']}-{platform_key}-{config}.tar.xz"
    dest = os.path.join(DIST_DIR, asset_name)

    info(f"Packaging {os.path.relpath(artifact, REPO_ROOT)} -> {os.path.relpath(dest, REPO_ROOT)}")
    with tarfile.open(dest, "w:xz", dereference=True) as tar:
        tar.add(artifact, arcname=os.path.basename(artifact))

    checksum = sha256_of(dest)
    size = os.path.getsize(dest)
    with open(dest + ".sha256", "w", encoding="utf-8") as handle:
        handle.write(f"{checksum}  {asset_name}\n")

    info(green("Packaged."))
    step(f"asset     {os.path.relpath(dest, REPO_ROOT)}  ({human_bytes(size)})")
    step(f"sha256    {checksum}")
    print()
    print(dim("Next: upload this asset to a GitHub Release, then:"))
    print(dim(f"  Scripts/chromium record-prebuilt --config {config} --platform {platform_key} --asset {dest}"))
    return 0

def cmd_record_prebuilt(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    config = check_config(args.config)
    if not os.path.isfile(args.asset):
        die(f"No such file: {args.asset}")

    checksum = sha256_of(args.asset)
    size = os.path.getsize(args.asset)
    tag = args.tag or manifest.get("prebuilt", {}).get("release_tag") or f"chromium-{manifest['chromium_version']}"

    prebuilt = manifest.setdefault("prebuilt", {})
    prebuilt["release_tag"] = tag
    prebuilt.pop("platforms", None)
    configs = prebuilt.setdefault("configs", {})
    for name in sorted(ENGINE_CONFIGS):
        configs.setdefault(name, {}).setdefault("platforms", {})
    configs[config]["platforms"][args.platform] = {
        "asset": os.path.basename(args.asset),
        "sha256": checksum,
        "size": size,
    }
    save_manifest(manifest)

    info(f"Recorded published '{config}' build for {args.platform}: {os.path.basename(args.asset)} ({human_bytes(size)})")
    step(f"tag       {tag}")
    step(f"sha256    {checksum}")
    return 0

def cmd_ensure(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    config = check_config(args.config)

    state, _detail = engine_install_state(manifest, config)
    if state == "installed":
        root = matching_install_root(manifest, config)
        assert_compiled_config(root, manifest["build_target"], config)
        relink_config(config, root)
        do_sync(manifest, quiet=True)
        if not args.quiet:
            info(f"Chromium {manifest['chromium_version']} ({config}) is installed.")
        return 0

    with engine_lock():
        state, _detail = engine_install_state(manifest, config)
        if state == "installed":
            root = matching_install_root(manifest, config)
            assert_compiled_config(root, manifest["build_target"], config)
            relink_config(config, root)
            do_sync(manifest, quiet=True)
            if not args.quiet:
                info(f"Chromium {manifest['chromium_version']} ({config}) was installed by another build.")
            return 0

        print()
        print("=" * 72)
        print(f"  Orbit embeds Chromium {manifest['chromium_version']}, built from source.")
        print("  It is not in this checkout yet, because it is far too large to commit.")
        print()
        print(f"  Installing the '{config}' configuration now: Orbit's own published build")
        print("  (a source build is opt-in, see `Scripts/chromium build --from-source`).")
        print("=" * 72)
        print()
        sys.stdout.flush()

        install_prebuilt(manifest, config)

    print()
    info(green(f"Chromium {manifest['chromium_version']} ({config}) installed. Continuing the build."))
    return 0

def cmd_verify_engine(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    config = check_config(args.config)
    build_target = manifest["build_target"]

    if args.bundle:
        root = os.path.join(os.path.abspath(args.bundle), "Contents", "Frameworks")
    else:
        root = matching_install_root(manifest, config)
        if root is None:
            die(f"No installed '{config}' engine to verify. Run: Scripts/chromium fetch --config {config}")

    if not _artifact_present(root, build_target):
        die(f"No {artifact_name(build_target)} under {display_path(root)}.")

    assert_compiled_config(root, build_target, config)
    info(green(f"{display_path(root)} is a '{config}' engine "
               f"(dcheck_always_on = {str(dcheck_always_on(config)).lower()})."))
    return 0

def cmd_bootstrap(args: argparse.Namespace) -> int:
    ensure_depot_tools_submodule()
    env = build_env()
    info("depot_tools ready: " + os.path.relpath(DEPOT_TOOLS_DIR, REPO_ROOT))
    step(f"HOME for build subprocesses redirected to {os.path.relpath(GCLIENT_HOME, REPO_ROOT)}")
    try:
        subprocess.run(
            ["git", "ls-remote", "--heads", "https://chromium.googlesource.com/chromium/src.git", "HEAD"],
            capture_output=True,
            timeout=20,
            check=True,
            env=env,
        )
        step("chromium.googlesource.com reachable")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        warn("chromium.googlesource.com was not reachable just now; `build --from-source` will fail without it.")
    info(green("Bootstrap complete. Next: Scripts/chromium build --from-source"))
    return 0

def cmd_sync(args: argparse.Namespace) -> int:
    do_sync(load_manifest())
    return 0

def cmd_doctor(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    ok = True

    def check(label: str, condition: bool, detail: str = "", required: bool = True) -> None:
        nonlocal ok
        mark = green("ok  ") if condition else (red("FAIL") if required else yellow("warn"))
        print(f"  [{mark}] {label}" + (f"  {dim(detail)}" if detail else ""))
        if not condition and required:
            ok = False

    print(bold("Manifest"))
    check("chromium-version.json readable", True, os.path.relpath(MANIFEST_PATH, REPO_ROOT))
    check("Chromium version pinned", bool(manifest.get("chromium_version")))
    check("build target known", manifest.get("build_target") in BUILD_TARGET_ARTIFACTS, f"artifact map has: {', '.join(BUILD_TARGET_ARTIFACTS)}")

    print()
    print(bold("Engine"))
    wanted = check_config(args.config)
    for config in sorted(ENGINE_CONFIGS):
        installed = engine_is_installed(manifest, config)
        check(
            f"Chromium {manifest['chromium_version']} ({config}) installed",
            installed,
            (engine_mode(config) or "") if installed else f"run: Scripts/chromium fetch --config {config}",
            required=(config == wanted),
        )
        if not installed:
            continue
        compiled = compiled_engine_config(matching_install_root(manifest, config), manifest["build_target"])
        check(
            f"the '{config}' engine binary reports dcheck_always_on = {str(dcheck_always_on(config)).lower()}",
            compiled == config,
            "as built" if compiled == config
            else (f"binary reports '{compiled}'" if compiled else "no marker: built before the configuration split"),
        )
    stale_overlay = os.path.exists(OBSOLETE_ENGINE_CHOICE_FILE)
    check("no stale engine-choice marker", not stale_overlay, "run: Scripts/chromium sync" if stale_overlay else "")
    swift_ok = os.path.exists(SWIFT_VERSION_FILE)
    check("generated Swift", swift_ok, "" if swift_ok else "run: Scripts/chromium sync")

    print()
    print(bold("Published-build toolchain (fetch)"))
    check("git", shutil.which("git") is not None)

    print()
    print(bold(f"Source-build toolchain (build --from-source){' -- required' if args.from_source else ' -- informational'}"))
    depot_tools_ok = os.path.isfile(os.path.join(DEPOT_TOOLS_DIR, "gclient.py"))
    check(
        "depot_tools submodule",
        depot_tools_ok,
        "" if depot_tools_ok else "run: git submodule update --init ThirdParty/depot_tools",
        required=args.from_source,
    )
    total, used, free = shutil.disk_usage(REPO_ROOT)
    disk_ok = free > 60 * 1024**3
    check(f"disk free ({human_bytes(free)})", disk_ok, "" if disk_ok else "want >60GB free", required=args.from_source)
    metal_ok = subprocess.run(
        ["xcrun", "--sdk", "macosx", "metal", "--version"], capture_output=True, check=False
    ).returncode == 0
    check(
        "Metal Toolchain (Skia/ANGLE shaders)",
        metal_ok,
        "" if metal_ok else "run: xcodebuild -downloadComponent MetalToolchain",
        required=args.from_source,
    )

    print()
    print(green("All required checks passed.") if ok else red("Some checks failed (see above)."))
    return 0 if ok else 1

def cmd_clean(args: argparse.Namespace) -> int:
    targets: list[str] = []

    if args.all:
        for path in (CHROMIUM_ROOT, PREBUILT_ROOT):
            if os.path.isdir(path):
                targets.append(path)
    else:
        manifest = load_manifest()
        for config in ([args.config] if args.config else sorted(ENGINE_CONFIGS)):
            link = config_link(check_config(config))
            if engine_is_installed(manifest, config) and os.path.islink(link):
                targets.append(os.path.realpath(link))

    if args.downloads:
        for path in (DOWNLOAD_CACHE, GCLIENT_HOME, DIST_DIR):
            if os.path.isdir(path):
                targets.append(path)

    if not targets:
        info("Nothing to clean.")
        return 0

    print(bold("The following will be deleted:"))
    for path in targets:
        print(f"  {os.path.relpath(path, REPO_ROOT)}  {dim(du(path))}")

    if not args.yes:
        print()
        answer = input("Delete these? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            info("Cancelled.")
            return 1

    for path in targets:
        shutil.rmtree(path, ignore_errors=True)
    for config in sorted(ENGINE_CONFIGS):
        link = config_link(config)
        if os.path.islink(link) and not os.path.exists(link):
            os.unlink(link)  # dangling: its target was just removed above

    do_sync(load_manifest(), quiet=True)
    info("Cleaned.")
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="Scripts/chromium",
        description="Build and manage the Chromium engine Orbit embeds, from source.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  Scripts/chromium status\n"
            "  Scripts/chromium fetch                            # default: the shipping engine\n"
            "  Scripts/chromium fetch --config dcheck            # the assertion-enabled engine\n"
            "  Scripts/chromium build --from-source              # opt-in: hours, ~8GB per out dir\n"
            "  Scripts/chromium build --from-source --config dcheck\n"
            "  Scripts/chromium verify-engine --config shipping\n"
            "  Scripts/chromium pin latest\n"
            "  Scripts/chromium sync\n"
            "\n"
            "there is no separate setup ritual: clone, open Orbit.xcodeproj and build.\n"
            "the ChromiumEngine target runs `ensure` before anything is compiled, which\n"
            "downloads the published build the first time -- a source build is never\n"
            "triggered by an ordinary Xcode build.\n"
            "\n"
            "two engine configurations exist. 'shipping' is what users get and what the\n"
            "Release configuration and every packaging path embed: dcheck_always_on is\n"
            "false, as in Chrome stable. 'dcheck' is what the Debug configuration and the\n"
            "live-engine suites embed: dcheck_always_on is true, so an invariant violation\n"
            "aborts loudly in a test rather than misbehaving quietly in a browser.\n"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_config(target, help_text: str) -> None:
        target.add_argument("--config", choices=sorted(ENGINE_CONFIGS), default=DEFAULT_ENGINE_CONFIG, help=help_text)

    p_bootstrap = sub.add_parser("bootstrap", help="initialise depot_tools and check upstream reachability")
    p_bootstrap.set_defaults(func=cmd_bootstrap)

    p_status = sub.add_parser("status", help="show the pinned, installed and published state")
    p_status.add_argument("--platform", help="inspect a platform other than this host")
    p_status.add_argument("--offline", action="store_true", help="do not contact upstream")
    p_status.set_defaults(func=cmd_status)

    p_check_latest = sub.add_parser("check-latest",
                                    help="fail unless the pinned version is the newest on its channel")
    p_check_latest.add_argument("--require-stable", action="store_true",
                                help="also fail unless that channel is stable")
    p_check_latest.set_defaults(func=cmd_check_latest)

    p_pin = sub.add_parser("pin", help="change which Chromium version Orbit targets")
    p_pin.add_argument("version", help="'latest', 'latest-beta', or a full Chromium version")
    p_pin.add_argument("--force", action="store_true", help="rewrite the manifest even if unchanged")
    p_pin.set_defaults(func=cmd_pin)

    p_fetch = sub.add_parser("fetch", help="download and verify the pinned Chromium build (default)")
    p_fetch.add_argument("--force", action="store_true", help="reinstall even if already present")
    p_fetch.add_argument("--jobs", type=int, help="unused, kept for CLI compatibility with older callers")
    add_config(p_fetch, "which engine configuration to install")
    p_fetch.set_defaults(func=cmd_fetch)

    p_build = sub.add_parser("build", help="build the pinned Chromium from source (opt-in)")
    p_build.add_argument("--from-source", action="store_true", help="required: this is the multi-hour source build")
    p_build.add_argument("--force", action="store_true", help="force a re-sync and rebuild")
    add_config(p_build, "which engine configuration to build; each has its own out directory")
    p_build.set_defaults(func=cmd_build)

    p_package = sub.add_parser("package", help="package a local source build into a publishable tarball")
    add_config(p_package, "which engine configuration to package")
    p_package.set_defaults(func=cmd_package)

    p_record = sub.add_parser("record-prebuilt", help="record a published tarball's checksum/size in the manifest")
    p_record.add_argument("--platform", required=True, choices=["macosarm64", "macosx64"])
    p_record.add_argument("--asset", required=True, help="path to the packaged tarball")
    p_record.add_argument("--tag", help="release tag (defaults to the manifest's)")
    add_config(p_record, "which engine configuration the tarball holds")
    p_record.set_defaults(func=cmd_record_prebuilt)

    p_ensure = sub.add_parser(
        "ensure",
        help="make the pinned engine present, downloading it if it is not (run by the Xcode build)",
    )
    p_ensure.add_argument("--jobs", type=int, help="unused, kept for CLI compatibility with older callers")
    p_ensure.add_argument("--quiet", action="store_true", help="say nothing when the engine is already installed")
    add_config(p_ensure, "which engine configuration this build embeds")
    p_ensure.set_defaults(func=cmd_ensure)

    p_verify = sub.add_parser(
        "verify-engine",
        help="prove an engine binary was compiled with the DCHECK setting its configuration declares",
    )
    add_config(p_verify, "the configuration the engine must be")
    p_verify.add_argument("--bundle", help="an .app to check instead of the installed engine")
    p_verify.set_defaults(func=cmd_verify_engine)

    p_sync = sub.add_parser("sync", help="regenerate build inputs from the manifest")
    p_sync.set_defaults(func=cmd_sync)

    p_doctor = sub.add_parser("doctor", help="check the local toolchain and engine state")
    p_doctor.add_argument("--from-source", action="store_true", help="also require the source-build toolchain")
    add_config(p_doctor, "which engine configuration this checkout must have installed")
    p_doctor.set_defaults(func=cmd_doctor)

    p_clean = sub.add_parser("clean", help="remove the installed engine, or the whole source checkout")
    p_clean.add_argument("--config", choices=sorted(ENGINE_CONFIGS), help="only this configuration (default: all of them)")
    p_clean.add_argument("--all", action="store_true", help="remove the whole Chromium source checkout, not just the installed engine")
    p_clean.add_argument("--downloads", action="store_true", help="also remove cached downloads, packages and the redirected build HOME")
    p_clean.add_argument("--yes", "-y", action="store_true", help="do not prompt")
    p_clean.set_defaults(func=cmd_clean)

    return parser

def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print()
        die("Interrupted.", code=130)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
