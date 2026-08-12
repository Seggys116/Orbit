#!/usr/bin/env python3
"""Orbit Developer ID release manager: archive, sign, verify, package, notarise."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import textwrap
import urllib.parse
import xml.etree.ElementTree as ElementTree

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

sys.path.insert(0, SCRIPT_DIR)
import chromium_manager  # noqa: E402

XCODEPROJ = os.path.join(REPO_ROOT, "Orbit.xcodeproj")
SCHEME = "Orbit"
APP_NAME = "Orbit.app"

RESOURCES_DIR = os.path.join(REPO_ROOT, "Orbit", "Resources")
MANIFEST_PATH = os.path.join(REPO_ROOT, "Chromium", "chromium-version.json")
GENERATED_XCCONFIG = os.path.join(REPO_ROOT, "Chromium", "Generated", "Chromium.xcconfig")

DEFAULT_WORK_DIR = os.path.join(REPO_ROOT, "build", "release")

SPARKLE_FRAMEWORK_NAME = "Sparkle.framework"

SPARKLE_XPC_SERVICES = ("Downloader.xpc", "Installer.xpc")
SPARKLE_XPC_PLIST_KEYS = (
    "SUEnableInstallerLauncherService",
    "SUEnableInstallerConnectionService",
    "SUEnableInstallerStatusService",
    "SUEnableDownloaderService",
)

SPARKLE_XPC_NOTE = (
    "Sparkle's XPC services exist for one reason: to let a SANDBOXED app reach "
    "past its own sandbox to install an update and to make a network request. "
    "Orbit has no App Sandbox (ENABLE_APP_SANDBOX = NO, for the reasons the "
    "role table records), so all four of the Info.plist keys that enable them "
    "are unset, which is their default, and Sparkle never launches either "
    "bundle. Sparkle's own sandboxing documentation says so and tells "
    "developers who do not sandbox to remove the services 'in a post install "
    "script when copying the framework to your application'. That is what the "
    "signing step does. Leaving them in would mean carrying two extra signed "
    "bundles, and their bugs, in every copy of Orbit for a code path that "
    "cannot execute. The strip is conditional, not unconditional: it reads "
    "the four keys out of the BUILT bundle's Info.plist, and if a future "
    "change ever turns one on, the services are kept and signed as bundles "
    "instead. Neither branch is a silent one."
)

SPARKLE_UPDATER_ENTITLEMENTS_NOTE = (
    "Sparkle.framework brings two more signed executables into Orbit.app that "
    "are not roles in the table above: 'Autoupdate', a plain Mach-O tool, and "
    "'Updater.app', a full nested application bundle that shows the progress "
    "window and relaunches Orbit once the new copy is in place. Both are "
    "signed here with the hardened runtime and with NO entitlements at all, "
    "and that is a decision rather than an omission. Their linkage was read "
    "with otool: between them they link Foundation, AppKit, Cocoa, "
    "CoreServices, ApplicationServices, Security, CoreFoundation, libobjc, "
    "libSystem and the compression libraries, and nothing else. They never "
    "load 'Orbit Framework.framework', so the one entitlement "
    "every Orbit process carries, disable-library-validation, is exactly the "
    "one they do not need; granting it would switch off library validation on "
    "the two processes that are allowed to replace Orbit on disk, which is "
    "the worst possible place to switch it off. They run no JavaScript and "
    "compile no shaders, so allow-jit does not apply. Relaunching the host "
    "application needs no entitlement. iCloud must never appear here: the "
    "browser role's CloudKit keys require a provisioning profile, and a "
    "nested bundle claiming a container it was not provisioned for fails to "
    "sign at all. No SignedRole was added for them, because a role's whole "
    "purpose is to render an .entitlements file, an empty one would embed an "
    "empty entitlement blob where none is wanted, and it would put a seventh "
    "generated file into Orbit/Resources for the check mode to police in "
    "exchange for nothing. Sparkle upstream ships Autoupdate with a "
    "com.apple.application-identifier entitlement naming "
    "org.sparkle-project.Sparkle.Autoupdate; re-signing without an "
    "entitlements file drops it, which is correct, because Orbit does not own "
    "that identifier and the key is only meaningful to a sandboxed keychain "
    "access group."
)

SPARKLE_FEED_HOSTING_NOTE = (
    "The appcast is a single cumulative feed served from GitHub Pages, off "
    "this repository's gh-pages branch, carrying the stable and the beta items "
    "together; Sparkle picks between them client-side by matching an item's "
    "sparkle:channel element against SPUUpdaterDelegate.allowedChannels(for:). "
    "It is deliberately NOT a release asset reached through "
    "/releases/latest/download/. GitHub defines the latest release as the most "
    "recent one that is neither a draft nor a pre-release, so an appcast "
    "attached to a pre-release cannot be reached that way at all, and the beta "
    "channel would have been dead on arrival rather than merely awkward. What "
    "this costs is a hosting dependency that nothing in this repository can "
    "create: GitHub Pages has to be enabled once, by hand, on the repository "
    "settings, pointed at gh-pages. Until that is done the feed URL returns "
    "404 and no copy of Orbit can update, with no other symptom. "
    "refs/RELEASING.md is where that maintainer step is written down."
)

# Deliberately not valid base64: Sparkle then rejects every update, where an absent key would fall back to Apple-code-signing-only validation.
SPARKLE_PUBLIC_KEY_PLACEHOLDER = "PLACEHOLDER.RUN.generate_keys.SEE.refs/RELEASING.md"

SPARKLE_PUBLIC_KEY_BYTES = 32

SOURCE_INFO_PLIST = os.path.join(RESOURCES_DIR, "Info.plist")
PBXPROJ_PATH = os.path.join(XCODEPROJ, "project.pbxproj")

NO_PUBLIC_KEY_HELP = """\
Orbit has no real Sparkle signing key yet, so it cannot ship an update anyone
could trust. The key is created once, by the maintainer, and then never again.

  1. Run Sparkle's generate_keys tool. It comes with the Sparkle distribution;
     with the Swift Package checked out it is at:

       find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f

     or download the same release used here from
     https://github.com/sparkle-project/Sparkle/releases and run bin/generate_keys.

  2. It puts the PRIVATE key in your login keychain, where it stays. It is
     never written to this repository and never goes into a build. Back it up
     with `generate_keys -x <file>`, keep that file somewhere safe and offline,
     and delete it from disk afterwards. Losing it means no existing install of
     Orbit can ever be updated again.

  3. It prints the PUBLIC key, 44 characters of base64. Put that string in
     Orbit/Resources/Info.plist as the value of SUPublicEDKey, replacing the
     placeholder that is there now.

  4. Re-run this command. It checks the key is present, is not the placeholder,
     and decodes to 32 bytes.

See refs/RELEASING.md for the full walkthrough, including how the appcast is
signed with the same key by sign_update / generate_appcast."""

_USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None

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

def run(cmd: list, capture: bool = False, check: bool = True, env: dict | None = None):
    try:
        if capture:
            return subprocess.run(
                cmd, check=check, capture_output=True, text=True, env=env
            )
        return subprocess.run(cmd, check=check, env=env)
    except FileNotFoundError:
        die(f"{cmd[0]} is not installed or not on PATH.")
    except subprocess.CalledProcessError as exc:
        detail = ""
        if capture:
            detail = ((exc.stdout or "") + (exc.stderr or "")).strip()
        die(
            f"{' '.join(cmd[:3])} … failed with exit code {exc.returncode}."
            + (f"\n{detail}" if detail else "")
        )

# chrome/installer/mac/signing/parts.py and chrome/app/helper-*-entitlements.plist.

ENTITLEMENT_RATIONALE = {
    "com.apple.security.cs.allow-jit": (
        "V8 compiles JavaScript to native code at runtime (Ignition/TurboFan), "
        "and ANGLE/Metal compiles shaders the same way. Under the hardened "
        "runtime that requires an explicitly MAP_JIT-mapped region, which is "
        "what this entitlement permits - and only that: it does not allow "
        "arbitrary writable-executable memory. Chromium grants it to exactly "
        "the renderer and the GPU process."
    ),
    "com.apple.security.cs.disable-library-validation": (
        "Turns off the hardened runtime's requirement that every loaded library "
        "be signed by the same Team ID as the executable loading it. Every role "
        "here carries it only under the ad hoc signing waiver recorded below "
        "(ENTITLEMENT_WAIVERS): two separately ad hoc signed Mach-O images are "
        "treated by AMFI as having different Team IDs, so a local or CI build "
        "(CODE_SIGN_IDENTITY = '-') cannot load its own code under the hardened "
        "runtime without it. A Developer ID build signs every part with one "
        "real Team ID and needs none of it."
    ),
    "com.apple.developer.icloud-container-identifiers": (
        "Names the private CloudKit container Orbit syncs its document "
        "through. CKContainer(identifier:) raises for a container the process "
        "is not signed for, so this key is what makes iCloud sync possible at "
        "all; without it Orbit detects the absence at launch and works "
        "locally. Browser process only: no helper touches CloudKit, and a "
        "renderer running untrusted web content must never be able to reach "
        "the user's iCloud container."
    ),
    "com.apple.developer.icloud-services": (
        "Selects CloudKit specifically. Orbit uses the private database and "
        "no other iCloud service; CloudDocuments is deliberately not "
        "requested."
    ),
    "com.apple.developer.ubiquity-kvstore-identifier": (
        "Companion key Xcode's iCloud capability adds unconditionally "
        "alongside CloudKit. Orbit does not use NSUbiquitousKeyValueStore; it "
        "is listed because removing it by hand makes the capability editor "
        "re-add it on the next save, which would then fail this table's own "
        "check mode."
    ),
}

# Deliberately granted to nothing: com.apple.security.cs.allow-dyld-environment-variables, a code-injection surface Chromium does not need.

SANDBOX_NOTE = (
    "App Sandbox is intentionally absent: Chromium's multi-process architecture "
    "(shared memory, Mach IPC between the browser and its renderer/GPU helpers, "
    "direct GPU access) is incompatible with it. The key is omitted rather than "
    "set to false, because ENABLE_APP_SANDBOX = NO already keeps it out of the "
    "signed entitlements. Chromium's own Seatbelt sandbox still confines every "
    "subprocess it launches; how Orbit's own engine bridge wires that in is "
    "undecided, since the bridge itself does not exist yet."
)

class SignedRole:

    def __init__(self, key, display, filename, purpose, entitlements, provisioned=()):
        self.key = key
        self.display = display
        self.filename = filename
        self.purpose = purpose
        self.entitlements = entitlements
        # Restricted keys: signing fails outright without a provisioning profile granting them, so these are emitted only under `--provisioned`.
        self.provisioned = provisioned

    def keys(self, provisioned: bool) -> tuple:
        return tuple(self.entitlements) + (tuple(self.provisioned) if provisioned else ())

    @property
    def path(self) -> str:
        return os.path.join(RESOURCES_DIR, self.filename)

BROWSER_ROLE = SignedRole(
    key="app",
    display="Orbit.app (browser process)",
    filename="Orbit.entitlements",
    purpose=(
        "The browser process: the only process with a user interface, the one "
        "that owns the window, the profile on disk and the network stack, and "
        "the one that launches all five helper roles below. It renders no web "
        "content itself. Chrome's browser process is signed with no hardened "
        "runtime exceptions at all; Orbit keeps allow-jit here because it is "
        "the configuration this app has actually been run under, and dropping "
        "it is a change no test in this repository can prove safe (nothing "
        "here ever starts the engine). See refs/RELEASING.md, 'Entitlements we "
        "could not narrow'."
    ),
    entitlements=(
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-library-validation",
    ),
    # No helper role may ever carry these: a renderer running untrusted web content must not reach the user's iCloud container.
    provisioned=(
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-services",
        "com.apple.developer.ubiquity-kvstore-identifier",
    ),
)

HELPER_ROLES = (
    SignedRole(
        key="utility",
        display="Orbit Helper.app",
        filename="OrbitHelper.entitlements",
        purpose=(
            "The general-purpose helper. Chromium launches processes of this "
            "kind for utility work - network service, storage service, audio "
            "service - none of which execute untrusted script or compile "
            "shaders. It therefore gets the smallest set of any process here. "
            "No target in this project builds or signs a bundle for it yet: "
            "this file exists for whoever writes the engine bridge to sign "
            "against once it does."
        ),
        entitlements=("com.apple.security.cs.disable-library-validation",),
    ),
    SignedRole(
        key="renderer",
        display="Orbit Helper (Renderer).app",
        filename="OrbitHelper-Renderer.entitlements",
        purpose=(
            "The renderer. This is the process that parses and executes "
            "untrusted web content, so it is the one whose entitlements matter "
            "most: it gets JIT because V8 cannot run without it, and nothing "
            "else. Chromium's helper-renderer-entitlements.plist is this exact "
            "single key."
        ),
        entitlements=(
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.disable-library-validation",
        ),
    ),
    SignedRole(
        key="gpu",
        display="Orbit Helper (GPU).app",
        filename="OrbitHelper-GPU.entitlements",
        purpose=(
            "The GPU process: rasterisation, compositing, and ANGLE/Metal "
            "shader compilation, which generates and runs code at runtime the "
            "same way V8 does. Chromium's helper-gpu-entitlements.plist is, "
            "likewise, allow-jit and nothing else."
        ),
        entitlements=(
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.disable-library-validation",
        ),
    ),
    # A direct Chromium embed has no plugin helper: the CDM runs as a kCdm
    # utility process in the plain helper with no entitlements.
    SignedRole(
        key="alerts",
        display="Orbit Helper (Alerts).app",
        filename="OrbitHelper-Alerts.entitlements",
        purpose=(
            "The alerts helper: a tiny process whose whole job is to post user "
            "notifications through UNUserNotificationCenter on the browser's "
            "behalf. It renders nothing and runs no script, so it gets no JIT "
            "and no executable memory. Chromium signs its equivalent with no "
            "entitlements at all."
        ),
        entitlements=("com.apple.security.cs.disable-library-validation",),
    ),
)

ALL_ROLES = (BROWSER_ROLE,) + HELPER_ROLES
ROLES_BY_KEY = {r.key: r for r in ALL_ROLES}

# --- Entitlement invariants ---
# Change a grant above without updating this section and `Scripts/release
# entitlements --check` fails on every pull request.

FORBIDDEN_ENTITLEMENTS = {
    "com.apple.security.cs.allow-unsigned-executable-memory": (
        "Permits writable-and-executable memory that is not MAP_JIT mapped, which "
        "is strictly weaker than allow-jit: it lets a process build and run code "
        "in ordinary anonymous memory, which is what almost every exploit chain "
        "wants. Chromium grants it to nothing on any platform. No role here needs "
        "it: there is no plugin helper, the CDM runs as a kCdm utility process "
        "with no entitlements at all, and Orbit cannot ship Widevine regardless."
    ),
    "com.apple.security.cs.disable-executable-page-protection": (
        "Turns off W^X for the whole process: any page may be made writable and "
        "executable at any time. It defeats the hardened runtime's central "
        "guarantee and makes every memory-corruption bug in a renderer directly "
        "exploitable as code execution. Chromium grants it to nothing, on any "
        "platform, and neither does Orbit. There is no process that needs it: a "
        "JIT needs MAP_JIT, which is allow-jit."
    ),
    "com.apple.security.cs.allow-dyld-environment-variables": (
        "Restores DYLD_INSERT_LIBRARIES and friends, i.e. lets any process that "
        "can set Orbit's environment load its own code into the browser. It is a "
        "code-injection surface with no legitimate use in a shipped build."
    ),
    "com.apple.security.get-task-allow": (
        "Lets any process the user owns attach a debugger and read or rewrite "
        "Orbit's memory, including the profile keys the browser process holds. "
        "Xcode adds it to debug builds; it must never be in the role table, "
        "because that is what puts it in a signed, distributed one."
    ),
    "com.apple.security.cs.debugger": (
        "The other half of the same hole: it lets Orbit be, or attach as, a "
        "debugger to other processes."
    ),
}

class EntitlementWaiver:
    """One named, dated exception to a forbidden entitlement: which roles, why it is tolerated, and the mechanically detectable condition that ends it. When that condition holds the check fails until the grant is gone. There is no waiver without an expiry."""

    def __init__(self, key, roles, why, expiry, has_expired):
        self.key = key
        self.roles = frozenset(roles)
        self.why = why
        self.expiry = expiry
        self.has_expired = has_expired

def _dev_signing_split_exists() -> bool:
    return "DEV_ADHOC_EXTRA_ENTITLEMENTS" in globals()

ENTITLEMENT_WAIVERS = (
    EntitlementWaiver(
        key="com.apple.security.cs.disable-library-validation",
        roles=("app", "utility", "renderer", "gpu", "alerts"),
        why=(
            "Measured, not assumed: dlopen versus linking is irrelevant here. Two "
            "separately ad hoc signed Mach-Os are treated by AMFI as having "
            "different Team IDs, so an ad hoc build (CODE_SIGN_IDENTITY = '-', "
            "which is every developer and CI build) cannot load its own framework "
            "under the hardened runtime without this. A Developer ID build signs "
            "every part with one Team ID and needs none of it, which is why "
            "Chrome ships without it anywhere."
        ),
        expiry=(
            "the dev/release signing split. When release_manager grows "
            "DEV_ADHOC_EXTRA_ENTITLEMENTS, this key moves there and out of every "
            "role: an ad hoc dev build gets it as an overlay at signing time, and "
            "no shipped role declares it. That is the whole of the work; this is "
            "not an open ended allowance."
        ),
        has_expired=_dev_signing_split_exists,
    ),
)

FORBIDDEN_ENTITLEMENTS["com.apple.security.cs.disable-library-validation"] = (
    "Turns off the hardened runtime's requirement that a loaded library carry the "
    "same Team ID as the executable loading it, i.e. it lets Orbit load code Orbit "
    "did not sign. No shipped Chromium browser carries it. It is forbidden here "
    "and survives only under the waiver below, which exists for ad hoc signing and "
    "expires with the dev/release signing split."
)

# Grants as they stand. A role gaining or losing one is a deliberate act and has to be recorded here in the same commit.
ENTITLEMENT_BASELINE = {
    "app": (
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-library-validation",
    ),
    "utility": ("com.apple.security.cs.disable-library-validation",),
    "renderer": (
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-library-validation",
    ),
    "gpu": (
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-library-validation",
    ),
    "alerts": ("com.apple.security.cs.disable-library-validation",),
}

def check_entitlement_policy(checks) -> None:
    """The invariants the role table itself cannot express. Every failure names the invariant and why it matters, because a guard nobody understands gets deleted the first time it goes red."""
    live_waivers = {}
    for waiver in ENTITLEMENT_WAIVERS:
        holders = {r.key for r in ALL_ROLES if waiver.key in r.entitlements}
        expired = waiver.has_expired()
        if not expired:
            live_waivers[waiver.key] = waiver
        checks.check(
            f"the waiver for {waiver.key} has not expired",
            not expired,
            "in force; ends on " + " ".join(waiver.expiry.split()) if not expired
            else (
                "EXPIRED, and the entitlement is still granted to "
                f"{sorted(holders) or ['nothing']}. The condition this waiver was written "
                "against now holds: " + " ".join(waiver.expiry.split())
                + " The entitlement is forbidden again from this moment; remove the grant "
                "rather than extending the waiver."
            ),
        )

    for role in ALL_ROLES:
        for key in role.entitlements:
            if key not in FORBIDDEN_ENTITLEMENTS:
                continue
            waiver = live_waivers.get(key)
            if waiver is not None and role.key in waiver.roles:
                checks.check(
                    f"{role.key} carries {key} only under its recorded waiver",
                    True,
                    " ".join(waiver.why.split()),
                )
                continue
            checks.check(
                f"{role.key} does not carry {key}",
                False,
                "FORBIDDEN. " + " ".join(FORBIDDEN_ENTITLEMENTS[key].split())
                + (
                    " There is a waiver for this key, and it does not cover this role: "
                    f"only {sorted(waiver.roles)} may hold it. A new holder is a new hole. "
                    "Widening the waiver is a deliberate act with its own justification."
                    if waiver is not None else
                    " No role may declare it and there is no waiver. Remove it from the role table."
                ),
            )

    known = set(FORBIDDEN_ENTITLEMENTS) | {w.key for w in ENTITLEMENT_WAIVERS}
    for role in ALL_ROLES:
        declared = tuple(ENTITLEMENT_BASELINE.get(role.key, ()))
        if tuple(role.entitlements) == declared:
            checks.check(f"{role.key} grants exactly its recorded baseline", True, ", ".join(declared) or "nothing")
            continue
        added = sorted(set(role.entitlements) - set(declared))
        removed = sorted(set(declared) - set(role.entitlements))
        checks.check(
            f"{role.key} grants exactly its recorded baseline",
            False,
            f"added {added}, removed {removed}. Every entitlement is a hole in the "
            "hardened runtime for the life of the product, so a grant changing is a "
            "security decision, not a build fix. Record it in ENTITLEMENT_BASELINE in "
            "the same commit, and if it is an exception rather than a permanent grant, "
            "give it an expiry in ENTITLEMENT_WAIVERS."
            + ("" if not added or set(added) <= known else
               " Nothing here has a rationale for the new key: add one to "
               "ENTITLEMENT_RATIONALE explaining what it turns off."),
        )

    for role in ALL_ROLES:
        if role.key == "app":
            continue
        developer = sorted(k for k in role.keys(provisioned=True) if k.startswith("com.apple.developer."))
        checks.check(
            f"{role.key} reaches no user data capability",
            not developer,
            "none" if not developer else (
                f"{developer}. A helper runs untrusted web content; the browser process "
                "is the only role that may reach iCloud, the keychain groups or any "
                "other capability tied to the user's data."
            ),
        )

    claimed = {r.filename for r in ALL_ROLES}
    on_disk = sorted(f for f in os.listdir(RESOURCES_DIR) if f.endswith(".entitlements")) \
        if os.path.isdir(RESOURCES_DIR) else []
    orphans = [f for f in on_disk if f not in claimed]
    checks.check(
        "every .entitlements file on disk belongs to a role",
        not orphans,
        f"{len(on_disk)} file(s), all claimed" if not orphans else (
            f"{orphans} is not claimed by any role. A role deleted from the table leaves "
            "its plist behind, and a build phase that still signs with it ships stale, "
            "over-permissive entitlements that nothing in this file describes. Delete the "
            "file, or restore the role."
        ),
    )

def _wrap_comment(text: str, indent: str) -> list:
    """codesign's entitlements parser rejects a double hyphen inside an XML comment even though `plutil -lint` accepts the file."""
    collapsed = " ".join(text.split())
    if "--" in collapsed:
        raise ValueError(
            "entitlement comment text contains a double hyphen, which is "
            "invalid inside an XML comment and makes codesign reject the "
            f"file at build time: {collapsed!r}"
        )
    return textwrap.wrap(collapsed, width=72 - len(indent.expandtabs()))

# Entitlements whose value is not `<true/>`: a malformed CloudKit key reads to the app exactly like having no entitlement at all.
ENTITLEMENT_VALUES: dict[str, object] = {
    # Byte-for-byte identical to CloudSyncEngine.containerIdentifier; `doctor` cross-checks.
    "com.apple.developer.icloud-container-identifiers": [
        "iCloud.com.zak-noble-clarke.Orbit",
    ],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.ubiquity-kvstore-identifier": "iCloud.com.zak-noble-clarke.Orbit",
}

def _render_entitlement_value(key: str) -> list[str]:
    value = ENTITLEMENT_VALUES.get(key, True)
    if value is True:
        return ["\t<true/>"]
    if value is False:
        return ["\t<false/>"]
    if isinstance(value, str):
        return [f"\t<string>{value}</string>"]
    if isinstance(value, list):
        lines = ["\t<array>"]
        for element in value:
            lines.append(f"\t\t<string>{element}</string>")
        lines.append("\t</array>")
        return lines
    raise SystemExit(
        f"error: ENTITLEMENT_VALUES[{key!r}] has unsupported type {type(value).__name__}"
    )

def render_entitlements(role: SignedRole, provisioned: bool = False) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        "<!--",
        f"  {role.filename}",
        "",
        "  GENERATED FILE. DO NOT EDIT.",
        "",
        "  Written by the `entitlements` subcommand of Scripts/release, in write",
        "  mode, from the role table in Scripts/release_manager.py. That table is",
        "  the single place the reason for every entitlement in this app is",
        "  recorded. Editing this file by hand makes the same subcommand's check",
        "  mode fail; change the table instead. Run `Scripts/release entitlements`",
        "  with no arguments to see every role at once.",
        "",
        "  Nothing in this comment may contain two hyphens in a row: XML forbids",
        "  it inside a comment, and although `plutil -lint` accepts such a file,",
        "  codesign rejects it and the build fails.",
        "",
    ]
    for line in _wrap_comment(role.purpose, "  "):
        lines.append(f"  {line}")
    lines.append("")
    for line in _wrap_comment(SANDBOX_NOTE, "  "):
        lines.append(f"  {line}")
    lines.append("-->")
    lines.append('<plist version="1.0">')
    lines.append("<dict>")

    for index, key in enumerate(role.keys(provisioned)):
        if index:
            lines.append("")
        lines.append("\t<!--")
        for line in _wrap_comment(ENTITLEMENT_RATIONALE[key], "\t     "):
            lines.append(f"\t     {line}")
        lines.append("\t-->")
        lines.append(f"\t<key>{key}</key>")
        lines.extend(_render_entitlement_value(key))

    lines.append("</dict>")
    lines.append("</plist>")
    rendered = "\n".join(lines) + "\n"
    strict_xml_error(rendered)
    return rendered

def strict_xml_error(text: str) -> str:
    """'' when well-formed, else the parser's complaint. Not `plutil -lint`, which accepts entitlement plists codesign's stricter parser rejects."""
    try:
        ElementTree.fromstring(text)
    except ElementTree.ParseError as exc:
        return str(exc)
    return ""

def read_entitlement_keys(path: str) -> list:
    with open(path, "rb") as handle:
        parsed = plistlib.load(handle)
    return sorted(k for k, v in parsed.items() if v is True)

def read_plist(path: str) -> dict:
    try:
        with open(path, "rb") as handle:
            parsed = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}

def sparkle_public_key_status(value) -> tuple:
    """(ok, detail) for one SUPublicEDKey: absent, still the placeholder, or not 32 bytes."""
    if not value:
        return False, (
            "absent. Sparkle would ignore the appcast's EdDSA signatures "
            "entirely and accept updates on Apple code signing alone"
        )
    if not isinstance(value, str):
        return False, f"is a {type(value).__name__}, not a string"
    if value == SPARKLE_PUBLIC_KEY_PLACEHOLDER:
        return False, "is still the placeholder; nobody has run generate_keys yet"
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        return False, "is not valid base64, so Sparkle rejects every update"
    if len(decoded) != SPARKLE_PUBLIC_KEY_BYTES:
        return False, (
            f"decodes to {len(decoded)} bytes; an ed25519 public key is "
            f"{SPARKLE_PUBLIC_KEY_BYTES}"
        )
    return True, f"{SPARKLE_PUBLIC_KEY_BYTES} byte ed25519 key"

def sparkle_feed_url_status(value) -> tuple:
    if not value:
        return False, "absent; Sparkle has nowhere to look for updates"
    if not isinstance(value, str):
        return False, f"is a {type(value).__name__}, not a string"
    if value != value.strip():
        return False, "has leading or trailing whitespace"
    try:
        parsed = urllib.parse.urlparse(value)
    except ValueError as exc:
        return False, f"is not a parsable URL: {exc}"
    if parsed.scheme != "https":
        return False, (
            f"uses '{parsed.scheme or 'no'}' scheme, not https. Sparkle warns on "
            "anything else, and a feed fetched in the clear lets whoever is in "
            "the middle choose what browser the user installs next"
        )
    if not parsed.netloc:
        return False, f"has no host: {value}"
    if not parsed.path or parsed.path == "/":
        return False, f"has no path, so it names no appcast file: {value}"
    if not parsed.path.endswith(".xml"):
        return False, (
            f"does not end in .xml, so it is unlikely to be an appcast: {parsed.path}"
        )
    return True, value

def sparkle_enabled_xpc_keys(plist: dict) -> list:
    return [key for key in SPARKLE_XPC_PLIST_KEYS if plist.get(key) is True]

def sparkle_version_directory(framework: str) -> str:
    """The framework version Sparkle.framework points at; it is 'B', not 'A', so never hard-code it."""
    versions = os.path.join(framework, "Versions")
    current = os.path.join(versions, "Current")
    if os.path.islink(current):
        return os.path.join(versions, os.readlink(current))
    if os.path.isdir(current):
        return current
    if os.path.isdir(versions):
        entries = [e for e in sorted(os.listdir(versions)) if e != "Current"]
        if len(entries) == 1:
            return os.path.join(versions, entries[0])
    return ""

def project_sparkle_link_status() -> tuple:
    if not os.path.exists(PBXPROJ_PATH):
        return False, f"no project.pbxproj at {PBXPROJ_PATH}"
    result = run(
        ["plutil", "-convert", "json", "-o", "-", PBXPROJ_PATH],
        capture=True, check=False,
    )
    try:
        objects = json.loads(result.stdout or "{}")["objects"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return False, "project.pbxproj could not be parsed"

    products = {
        pid for pid, obj in objects.items()
        if obj.get("isa") == "XCSwiftPackageProductDependency"
        and obj.get("productName") == "Sparkle"
    }
    if not products:
        return False, "no XCSwiftPackageProductDependency named 'Sparkle'"

    build_files = {
        pid for pid, obj in objects.items()
        if obj.get("isa") == "PBXBuildFile" and obj.get("productRef") in products
    }
    if not build_files:
        return False, "the Sparkle product is declared but no target links it"

    linking = []
    for obj in objects.values():
        if obj.get("isa") != "PBXNativeTarget":
            continue
        phases = [objects.get(p, {}) for p in obj.get("buildPhases", [])]
        files = {f for phase in phases for f in phase.get("files", [])}
        if files & build_files or set(obj.get("packageProductDependencies", [])) & products:
            linking.append(obj.get("name", "?"))
    if linking != ["Orbit"]:
        return False, (
            "expected exactly the Orbit target to link Sparkle, found "
            + (", ".join(sorted(linking)) or "no target")
        )

    dangling = [f for f in build_files if not any(
        f in objects.get(p, {}).get("files", [])
        for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"
        for p in obj.get("buildPhases", [])
    )]
    if dangling:
        return False, "a Sparkle PBXBuildFile exists but is in no build phase"

    requirement = ""
    for obj in objects.values():
        if obj.get("isa") == "XCRemoteSwiftPackageReference" and "Sparkle" in str(
            obj.get("repositoryURL", "")
        ):
            req = obj.get("requirement", {})
            requirement = " ".join(f"{k}={v}" for k, v in sorted(req.items()))
    return True, f"Orbit target; {requirement or 'no requirement recorded'}"

def load_manifest() -> dict:
    if not os.path.exists(MANIFEST_PATH):
        die(
            f"{os.path.relpath(MANIFEST_PATH, REPO_ROOT)} is missing. "
            "This is not an Orbit checkout, or the checkout is incomplete."
        )
    with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)

_BUILD_SETTINGS_CACHE: dict = {}

def build_settings(target: str, configuration: str = "Release") -> dict:
    cache_key = (target, configuration)
    if cache_key in _BUILD_SETTINGS_CACHE:
        return _BUILD_SETTINGS_CACHE[cache_key]
    if not os.path.isdir(XCODEPROJ):
        die(f"no Orbit.xcodeproj at {XCODEPROJ}; run this from an Orbit checkout.")
    result = run(
        [
            "xcodebuild",
            "-project", XCODEPROJ,
            "-target", target,
            "-configuration", configuration,
            "-showBuildSettings",
            "-json",
        ],
        capture=True,
    )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        die(f"xcodebuild -showBuildSettings produced no JSON for target {target}.")
    settings = payload[0].get("buildSettings", {}) if payload else {}
    _BUILD_SETTINGS_CACHE[cache_key] = settings
    return settings

def resolve_version(explicit: str | None = None, manifest_only: bool = False) -> dict:
    """manifest_only answers without spawning xcodebuild, which is required inside an `xcodebuild test` (the build system's lock) and on Linux CI."""
    manifest = load_manifest()
    settings = {} if manifest_only else build_settings("Orbit")
    marketing = explicit or settings.get("MARKETING_VERSION", "")
    return {
        "marketing_version": marketing,
        "build_version": settings.get("CURRENT_PROJECT_VERSION", ""),
        "bundle_identifier": settings.get("PRODUCT_BUNDLE_IDENTIFIER", ""),
        "deployment_target": settings.get("MACOSX_DEPLOYMENT_TARGET", ""),
        "chromium_version": manifest.get("chromium_version", ""),
        "chromium_channel": manifest.get("channel", ""),
        "dmg_name": f"Orbit-{marketing}-{host_arch()}.dmg" if marketing else "",
    }

def host_arch() -> str:
    machine = os.uname().machine
    return "arm64" if machine in ("arm64", "aarch64") else machine

def available_identities(keychain: str | None = None) -> list:
    cmd = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain:
        cmd.append(keychain)
    result = run(cmd, capture=True, check=False)
    identities = []
    for line in (result.stdout or "").splitlines():
        match = re.search(r'\)\s+([0-9A-F]{40})\s+"(.+)"\s*$', line.strip())
        if match:
            identities.append({"sha1": match.group(1), "name": match.group(2)})
    return identities

def developer_id_identities(keychain: str | None = None) -> list:
    return [
        identity
        for identity in available_identities(keychain)
        if identity["name"].startswith("Developer ID Application:")
    ]

def team_id_of(identity_name: str) -> str:
    match = re.search(r"\(([A-Z0-9]{10})\)\s*$", identity_name)
    return match.group(1) if match else ""

NO_IDENTITY_HELP = """\
No 'Developer ID Application' certificate is available to codesign.

Orbit cannot be distributed through the Mac App Store, so a shipping build is
signed with a Developer ID Application certificate and notarised. To get one:

  1. Enrol in the Apple Developer Program (an individual account is enough).
  2. In Xcode: Settings > Accounts > (your account) > Manage Certificates,
     then '+' > 'Developer ID Application'. Xcode installs it into your login
     keychain along with its private key.
  3. Confirm it is visible here with:
       security find-identity -v -p codesigning

Then either pass it explicitly:
       Scripts/release sign --app <Orbit.app> --identity "Developer ID Application: Name (TEAMID)"
or set ORBIT_SIGN_IDENTITY in the environment and let this tool find it.

To exercise the signing pipeline WITHOUT a certificate - which verifies the
bundle layout, the signing order and every entitlement, but produces a build
that is not distributable and will not notarise - use:
       Scripts/release sign --app <Orbit.app> --adhoc"""

def resolve_identity(args) -> str:
    if getattr(args, "adhoc", False):
        return "-"
    explicit = getattr(args, "identity", None) or os.environ.get("ORBIT_SIGN_IDENTITY")
    if explicit:
        return explicit
    keychain = getattr(args, "keychain", None) or os.environ.get("ORBIT_SIGN_KEYCHAIN")
    found = developer_id_identities(keychain)
    if len(found) == 1:
        return found[0]["name"]
    if len(found) > 1:
        listing = "\n".join(f"  {i['name']}" for i in found)
        die(
            "more than one 'Developer ID Application' identity is available, so "
            "which one to sign with is ambiguous. Pass --identity with one of:\n"
            + listing
        )
    die(NO_IDENTITY_HELP)

NO_CREDENTIALS_HELP = """\
No notarisation credentials are available, so this build cannot be submitted to
Apple's notary service. Supply exactly one of the three forms notarytool
accepts. None of them may ever be committed to this repository.

  A. A stored keychain profile (best for a maintainer's own machine). Create it
     once, interactively, and it never appears in a command line again:

       xcrun notarytool store-credentials "Orbit" \\
         --apple-id <your-apple-id> --team-id <TEAMID> \\
         --password <app-specific-password>

     then export ORBIT_NOTARY_KEYCHAIN_PROFILE=Orbit

  B. An App Store Connect API key (best for CI - it is a file plus two ids,
     with no Apple ID and no 2FA involved):

       APPLE_NOTARY_KEY_PATH    path to the downloaded AuthKey_XXXX.p8
       APPLE_NOTARY_KEY_ID      the key id, e.g. 2X9R4HXF34
       APPLE_NOTARY_ISSUER_ID   the issuer UUID - Team keys only. An
                                Individual key carries its own issuer and
                                notarytool rejects the flag, so leave it unset
                                for one.

  C. An Apple ID and an app-specific password (simplest, but subject to 2FA
     policy and rate limits):

       APPLE_ID                       your Apple ID email
       APPLE_APP_SPECIFIC_PASSWORD    from appleid.apple.com > Sign-In and
                                      Security > App-Specific Passwords
       APPLE_TEAM_ID                  your 10-character Team ID

See refs/RELEASING.md for which to choose and why."""

def notary_auth_args() -> list:
    """notarytool auth flags; --issuer is Team-key-only, and notarytool rejects it for an Individual key."""
    profile = os.environ.get("ORBIT_NOTARY_KEYCHAIN_PROFILE")
    if profile:
        return ["--keychain-profile", profile]

    key_path = os.environ.get("APPLE_NOTARY_KEY_PATH")
    key_id = os.environ.get("APPLE_NOTARY_KEY_ID")
    if key_path or key_id:
        if not (key_path and key_id):
            die(
                "an App Store Connect API key is half-configured: "
                f"APPLE_NOTARY_KEY_PATH is {'set' if key_path else 'unset'} and "
                f"APPLE_NOTARY_KEY_ID is {'set' if key_id else 'unset'}. Both are "
                "required together."
            )
        if not os.path.exists(key_path):
            die(f"APPLE_NOTARY_KEY_PATH points at {key_path}, which does not exist.")
        auth = ["--key", key_path, "--key-id", key_id]
        issuer = os.environ.get("APPLE_NOTARY_ISSUER_ID")
        if issuer:
            auth += ["--issuer", issuer]
        return auth

    apple_id = os.environ.get("APPLE_ID")
    password = os.environ.get("APPLE_APP_SPECIFIC_PASSWORD")
    team_id = os.environ.get("APPLE_TEAM_ID")
    if apple_id or password:
        missing = [
            name
            for name, value in (
                ("APPLE_ID", apple_id),
                ("APPLE_APP_SPECIFIC_PASSWORD", password),
                ("APPLE_TEAM_ID", team_id),
            )
            if not value
        ]
        if missing:
            die(
                "an Apple ID credential is half-configured; still missing: "
                + ", ".join(missing)
            )
        return ["--apple-id", apple_id, "--password", password, "--team-id", team_id]

    die(NO_CREDENTIALS_HELP)

def notary_credential_summary() -> tuple:
    profile = os.environ.get("ORBIT_NOTARY_KEYCHAIN_PROFILE")
    if profile:
        return True, f"keychain profile '{profile}' (ORBIT_NOTARY_KEYCHAIN_PROFILE)"
    if os.environ.get("APPLE_NOTARY_KEY_PATH") and os.environ.get("APPLE_NOTARY_KEY_ID"):
        kind = "Team" if os.environ.get("APPLE_NOTARY_ISSUER_ID") else "Individual"
        return True, f"App Store Connect API key {os.environ['APPLE_NOTARY_KEY_ID']} ({kind})"
    if os.environ.get("APPLE_ID") and os.environ.get("APPLE_APP_SPECIFIC_PASSWORD"):
        return True, f"Apple ID {os.environ['APPLE_ID']} with an app-specific password"
    return False, "none configured"

def is_macho(path: str) -> bool:
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in (
        b"\xcf\xfa\xed\xfe",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xfe\xed\xfa\xce",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
    )

def nested_machos(app: str) -> list:
    found = []
    for root, dirs, files in os.walk(app):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        for name in files:
            path = os.path.join(root, name)
            if is_macho(path):
                found.append(path)
    found.sort(key=lambda p: (-p.count(os.sep), p))
    return found

def codesign_entitlements(path: str) -> dict:
    result = run(
        ["codesign", "--display", "--entitlements", "-", "--xml", path],
        capture=True,
        check=False,
    )
    payload = (result.stdout or "").strip()
    if not payload:
        return {}
    try:
        return plistlib.loads(payload.encode("utf-8"))
    except Exception:
        return {}

def codesign_info(path: str) -> dict:
    result = run(["codesign", "--display", "--verbose=4", path], capture=True, check=False)
    text = (result.stderr or "") + (result.stdout or "")
    flags_match = re.search(r"CodeDirectory .*?flags=0x[0-9a-f]+\(([^)]*)\)", text)
    flags = flags_match.group(1).split(",") if flags_match else []
    team_match = re.search(r"^TeamIdentifier=(.+)$", text, flags=re.MULTILINE)
    return {
        "signed": "code object is not signed" not in text,
        "flags": flags,
        "hardened_runtime": "runtime" in flags,
        "adhoc": "adhoc" in flags,
        # A signature without a secure timestamp reports "Signed Time=" instead, and notarisation rejects it.
        "secure_timestamp": bool(re.search(r"^Timestamp=", text, flags=re.MULTILINE)),
        "authorities": re.findall(r"^Authority=(.+)$", text, flags=re.MULTILINE),
        "team": team_match.group(1).strip() if team_match else "",
    }

def last_line(*candidates: str) -> str:
    for candidate in candidates:
        lines = [line for line in (candidate or "").strip().splitlines() if line.strip()]
        if lines:
            return lines[-1].strip()
    return ""

class Checklist:
    def __init__(self):
        self.ok = True
        self.failures = []

    def section(self, title: str) -> None:
        print()
        print(bold(title))

    def check(self, label: str, condition: bool, detail: str = "") -> bool:
        mark = green("ok  ") if condition else red("FAIL")
        print(f"  [{mark}] {label}" + (f"  {dim(detail)}" if detail else ""))
        if not condition:
            self.ok = False
            self.failures.append(f"{label}{(' - ' + detail) if detail else ''}")
        return condition

    def note(self, label: str, condition: bool, detail: str = "") -> bool:
        mark = green("ok  ") if condition else yellow("warn")
        print(f"  [{mark}] {label}" + (f"  {dim(detail)}" if detail else ""))
        return condition

    def finish(self, subject: str) -> int:
        print()
        if self.ok:
            print(green(f"{subject}: all required checks passed."))
            return 0
        print(red(f"{subject}: {len(self.failures)} check(s) failed:"))
        for failure in self.failures:
            print(red(f"  - {failure}"))
        return 1

def cmd_doctor(args) -> int:
    checks = Checklist()

    checks.section("Toolchain")
    for tool, hint in (
        ("xcodebuild", "install Xcode from the App Store"),
        ("codesign", "install the Xcode Command Line Tools: xcode-select --install"),
        ("security", "part of macOS; a missing one means a broken system"),
        ("ditto", "part of macOS"),
        ("hdiutil", "part of macOS"),
        ("plutil", "part of macOS"),
        ("lipo", "install the Xcode Command Line Tools: xcode-select --install"),
    ):
        path = shutil.which(tool)
        checks.check(tool, path is not None, path or hint)

    for tool in ("notarytool", "stapler"):
        result = run(["xcrun", "--find", tool], capture=True, check=False)
        located = result.returncode == 0 and (result.stdout or "").strip()
        checks.check(
            f"xcrun {tool}",
            bool(located),
            (located or "").strip() or "requires Xcode 13 or newer (not just the CLT)",
        )

    version = run(["xcodebuild", "-version"], capture=True, check=False)
    first_line = (version.stdout or "").splitlines()[:1]
    checks.note("xcodebuild version", True, first_line[0] if first_line else "unknown")

    checks.section("Signing identity")
    keychain = args.keychain or os.environ.get("ORBIT_SIGN_KEYCHAIN")
    if keychain:
        checks.note("keychain override", os.path.exists(keychain), keychain)
    identities = developer_id_identities(keychain)
    if args.adhoc:
        checks.note(
            "Developer ID Application certificate",
            True,
            "--adhoc: skipped. An ad-hoc build verifies structure but cannot be distributed.",
        )
    elif os.environ.get("ORBIT_SIGN_IDENTITY"):
        name = os.environ["ORBIT_SIGN_IDENTITY"]
        checks.check(
            "ORBIT_SIGN_IDENTITY is a real identity",
            any(i["name"] == name for i in available_identities(keychain)),
            name,
        )
    else:
        found = checks.check(
            "Developer ID Application certificate",
            len(identities) >= 1,
            identities[0]["name"] if identities else "none found - see the message below",
        )
        if found and len(identities) > 1:
            checks.note(
                "exactly one Developer ID identity",
                False,
                f"{len(identities)} found; pass --identity to disambiguate",
            )
        if found:
            team = team_id_of(identities[0]["name"])
            checks.check("Team ID is readable from the certificate", bool(team), team or "-")

    checks.section("Notarisation credentials")
    configured, description = notary_credential_summary()
    if args.adhoc:
        checks.note(
            "notary credentials",
            configured,
            description + ("" if configured else " (not needed for an ad-hoc run, and not shippable either)"),
        )
    else:
        checks.check("notary credentials", configured, description)
    key_path = os.environ.get("APPLE_NOTARY_KEY_PATH")
    if key_path:
        absolute = os.path.abspath(key_path)
        inside_repo = absolute.startswith(REPO_ROOT + os.sep)
        checks.check(
            "the App Store Connect key lives outside the repository",
            not inside_repo,
            absolute if not inside_repo else "a .p8 inside the repo risks being committed",
        )

    checks.section("Chromium engine")
    checks.check(
        "engine bridge exists",
        False,
        "the browser-side bridge in Orbit/Engine/Chromium/ is not release-ready yet. "
        "Nothing in this pipeline can archive, sign or verify a working browser until it is. "
        "Chromium toolchain state (fetched, built, published) is Scripts/chromium "
        "doctor's job, not this one's.",
    )

    checks.section("Entitlements")
    for role in ALL_ROLES:
        exists = os.path.exists(role.path)
        checks.check(
            f"{role.filename} present",
            exists,
            os.path.relpath(role.path, REPO_ROOT) if exists else "run: Scripts/release entitlements --write",
        )
        if not exists:
            continue
        lint = run(["plutil", "-lint", role.path], capture=True, check=False)
        checks.check(
            f"{role.filename} is a valid plist",
            lint.returncode == 0,
            "" if lint.returncode == 0 else last_line(lint.stdout, lint.stderr) or "plutil rejected it",
        )
        with open(role.path, "r", encoding="utf-8") as handle:
            current = handle.read()
        # Separate from plutil, which accepts entitlement files codesign's own parser rejects.
        xml_error = strict_xml_error(current)
        checks.check(
            f"{role.filename} is well-formed XML",
            not xml_error,
            xml_error or "codesign will accept it",
        )
        checks.check(
            f"{role.filename} matches the role table",
            current == render_entitlements(role),
            "in sync" if current == render_entitlements(role) else "run: Scripts/release entitlements --write",
        )

    checks.section("Sparkle updater")
    link_ok, link_detail = project_sparkle_link_status()
    checks.check("the Orbit target links the Sparkle package", link_ok, link_detail)

    source_plist = read_plist(SOURCE_INFO_PLIST)
    checks.check(
        "Orbit/Resources/Info.plist is readable",
        bool(source_plist),
        os.path.relpath(SOURCE_INFO_PLIST, REPO_ROOT) if source_plist
        else "missing or not a plist",
    )
    feed_ok, feed_detail = sparkle_feed_url_status(source_plist.get("SUFeedURL"))
    checks.check("SUFeedURL", feed_ok, feed_detail)
    checks.note(
        "appcast hosting",
        True,
        "GitHub Pages, gh-pages branch. A valid URL is not proof the feed is "
        "served; Pages must be enabled once by hand. See refs/RELEASING.md",
    )
    key_ok, key_detail = sparkle_public_key_status(source_plist.get("SUPublicEDKey"))
    checks.check("SUPublicEDKey", key_ok, key_detail)

    enabled_xpc = sparkle_enabled_xpc_keys(source_plist)
    checks.note(
        "Sparkle XPC services",
        not enabled_xpc,
        "all four switches unset, so signing strips them" if not enabled_xpc
        else ", ".join(enabled_xpc) + " set, so signing keeps and signs them",
    )
    checks.note(
        "automatic update checks",
        source_plist.get("SUEnableAutomaticChecks") is True,
        f"every {source_plist.get('SUScheduledCheckInterval', 86400)} seconds"
        if source_plist.get("SUEnableAutomaticChecks") is True
        else "SUEnableAutomaticChecks is not YES; Sparkle will ask on second launch",
    )

    checks.section("Hardened runtime")
    for target in ("Orbit", "OrbitHelper"):
        settings = build_settings(target)
        checks.check(
            f"{target} enables the hardened runtime",
            settings.get("ENABLE_HARDENED_RUNTIME") == "YES",
            settings.get("ENABLE_HARDENED_RUNTIME", "unset")
            + ("" if settings.get("ENABLE_HARDENED_RUNTIME") == "YES" else " - notarisation requires YES"),
        )

    if args.app:
        checks.section("Bundle")
        verify_structure(args.app, checks)

    result = checks.finish("doctor")
    if not checks.ok and not identities and not args.adhoc and not os.environ.get("ORBIT_SIGN_IDENTITY"):
        print()
        print(NO_IDENTITY_HELP)
    if not checks.ok and not configured and not args.adhoc:
        print()
        print(NO_CREDENTIALS_HELP)
    if not feed_ok:
        print()
        print(textwrap.fill(SPARKLE_FEED_HOSTING_NOTE, width=78))
    if not key_ok:
        print()
        print(NO_PUBLIC_KEY_HELP)
    return result

def cmd_version(args) -> int:
    resolved = resolve_version(args.set, manifest_only=args.manifest_only)
    if args.json:
        print(json.dumps(resolved, indent=2, sort_keys=True))
        return 0
    print(bold("Orbit"))
    print(f"  marketing version   {resolved['marketing_version'] or dim('unset')}")
    print(f"  build version       {resolved['build_version'] or dim('unset')}")
    print(f"  bundle identifier   {resolved['bundle_identifier']}")
    print(f"  minimum macOS       {resolved['deployment_target']}")
    print()
    print(bold("Engine"))
    print(f"  Chromium            {resolved['chromium_version']} ({resolved['chromium_channel']})")
    print(f"  engine bridge       {dim('does not exist yet')}")
    print()
    print(bold("Would produce"))
    print(f"  {resolved['dmg_name'] or dim('no marketing version set')}")
    return 0

def cmd_entitlements(args) -> int:
    if args.print:
        role = ROLES_BY_KEY.get(args.print)
        if role is None:
            die(
                f"unknown role '{args.print}'. Known roles: "
                + ", ".join(sorted(ROLES_BY_KEY))
            )
        sys.stdout.write(render_entitlements(role))
        return 0

    if args.write:
        changed = []
        for role in ALL_ROLES:
            rendered = render_entitlements(role)
            existing = None
            if os.path.exists(role.path):
                with open(role.path, "r", encoding="utf-8") as handle:
                    existing = handle.read()
            if existing == rendered:
                continue
            os.makedirs(os.path.dirname(role.path), exist_ok=True)
            with open(role.path, "w", encoding="utf-8") as handle:
                handle.write(rendered)
            changed.append(role.filename)
        if changed:
            info("Rewrote " + ", ".join(changed))
        else:
            info("Every entitlements file already matches the role table.")
        return 0

    if args.check:
        checks = Checklist()
        checks.section("Entitlements")
        for role in ALL_ROLES:
            if not os.path.exists(role.path):
                checks.check(role.filename, False, "missing; run: Scripts/release entitlements --write")
                continue
            with open(role.path, "r", encoding="utf-8") as handle:
                current = handle.read()
            checks.check(
                role.filename,
                current == render_entitlements(role),
                "in sync" if current == render_entitlements(role)
                else "differs from the role table; run: Scripts/release entitlements --write",
            )
            xml_error = strict_xml_error(current)
            checks.check(
                f"{role.filename} is well-formed XML",
                not xml_error,
                xml_error or "codesign will accept it",
            )
        checks.section("Entitlement invariants")
        check_entitlement_policy(checks)
        return checks.finish("entitlements")

    print(bold("Signed executables in Orbit.app and the entitlements each carries"))
    print()
    for role in ALL_ROLES:
        print(f"  {bold(role.display)}")
        print(f"    {dim(os.path.relpath(role.path, REPO_ROOT))}")
        for key in role.entitlements:
            print(f"    - {key}")
        print()
    print(bold("Signed executables that deliberately carry no entitlements"))
    print()
    for note in (SPARKLE_UPDATER_ENTITLEMENTS_NOTE, SPARKLE_XPC_NOTE):
        print(textwrap.fill(note, width=76, initial_indent="  ", subsequent_indent="  "))
        print()
    print(dim("Run `Scripts/release entitlements --print <role>` for the file with its"))
    print(dim("rationale, or `--check` to prove the files on disk still match."))
    return 0

def archs_for_release(args) -> list:
    explicit = getattr(args, "archs", None)
    if explicit:
        return explicit.split()
    return [host_arch()]

def cmd_archive(args) -> int:
    resolved = resolve_version(args.version)
    archive_path = args.archive or os.path.join(DEFAULT_WORK_DIR, "Orbit.xcarchive")
    os.makedirs(os.path.dirname(archive_path), exist_ok=True)

    archs = archs_for_release(args)

    identity = "-" if args.adhoc else (args.identity or os.environ.get("ORBIT_SIGN_IDENTITY") or "-")

    command = [
        "xcodebuild", "archive",
        "-project", XCODEPROJ,
        "-scheme", SCHEME,
        "-configuration", "Release",
        "-destination", "generic/platform=macOS",
        "-archivePath", archive_path,
        f"ARCHS={' '.join(archs)}",
        "ONLY_ACTIVE_ARCH=NO",
        "CODE_SIGN_STYLE=Manual",
        f"CODE_SIGN_IDENTITY={identity}",
        "PROVISIONING_PROFILE_SPECIFIER=",
    ]
    if args.version:
        command.append(f"MARKETING_VERSION={args.version}")
    if args.build:
        command.append(f"CURRENT_PROJECT_VERSION={args.build}")
    team = args.team or os.environ.get("APPLE_TEAM_ID") or ""
    command.append(f"DEVELOPMENT_TEAM={team}")
    if args.derived_data:
        command += ["-derivedDataPath", args.derived_data]

    info(
        f"Archiving Orbit {resolved['marketing_version'] or '(version unset)'} "
        f"for {' '.join(archs)} with Chromium {resolved['chromium_version']}"
    )
    step(f"archive path: {archive_path}")
    run(command)

    app = os.path.join(archive_path, "Products", "Applications", APP_NAME)
    if not os.path.isdir(app):
        die(f"the archive succeeded but there is no {APP_NAME} at {app}.")
    info(f"Archived {app}")
    print(app)
    return 0

def app_from_archive(archive_path: str) -> str:
    return os.path.join(archive_path, "Products", "Applications", APP_NAME)

def cmd_sign(args) -> int:
    app = os.path.abspath(args.app)
    if not os.path.isdir(app):
        die(f"no app bundle at {app}")

    identity = resolve_identity(args)
    keychain = args.keychain or os.environ.get("ORBIT_SIGN_KEYCHAIN")
    adhoc = identity == "-"

    if adhoc:
        warn(
            "signing ad-hoc. This proves the bundle layout, the signing order and "
            "every entitlement, but the result is NOT distributable and will not "
            "notarise."
        )

    for role in ALL_ROLES:
        if not os.path.exists(role.path):
            die(
                f"{os.path.relpath(role.path, REPO_ROOT)} is missing. "
                "Run: Scripts/release entitlements --write"
            )

    def sign(path: str, entitlements: str | None = None, label: str = "") -> None:
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
        # Notarisation requires a secure timestamp; an ad-hoc signature cannot have one.
        command.append("--timestamp" if not adhoc else "--timestamp=none")
        if keychain:
            command += ["--keychain", keychain]
        if entitlements:
            command += ["--entitlements", entitlements]
        command.append(path)
        step(label or os.path.relpath(path, app))
        run(command, capture=True)

    info(f"Signing {os.path.basename(app)} with {identity}")

    # Quarantine flags and resource forks make codesign fail with "resource fork, Finder information, or similar detritus not allowed"; strip them first.
    run(["xattr", "-cr", app], capture=True, check=False)

    # No engine bridge exists yet (Chromium/README.md); nothing to sign here.
    signed_paths = set()
    frameworks_dir = os.path.join(app, "Contents", "Frameworks")

    # 1. Sparkle, inside out: Updater.app and the .xpc services must be sealed as bundles here, deepest first, because step 2 walks files rather than bundles.
    sparkle = os.path.join(frameworks_dir, SPARKLE_FRAMEWORK_NAME)
    if not os.path.isdir(sparkle):
        die(
            f"{SPARKLE_FRAMEWORK_NAME} is not embedded in "
            f"{os.path.relpath(frameworks_dir, app)}. The Orbit target links the "
            "Sparkle Swift package, and Xcode embeds an XCFramework binary target "
            "automatically, so an app bundle without it was not built from this "
            "project as it stands. Refusing to sign a build whose updater is "
            "missing: it would install, run, and never update."
        )

    sparkle_version = sparkle_version_directory(sparkle)
    if not sparkle_version or not os.path.isdir(sparkle_version):
        die(
            f"{SPARKLE_FRAMEWORK_NAME} has no resolvable version directory. "
            "Versions/Current should be a symlink to the current version "
            "(Sparkle 2 uses 'B'). Without it there is nothing to sign and "
            "macOS cannot load the framework either."
        )

    # The BUILT bundle's Info.plist, not the repository's: it is what the shipped Sparkle reads at runtime.
    bundle_plist = read_plist(os.path.join(app, "Contents", "Info.plist"))
    enabled_xpc = sparkle_enabled_xpc_keys(bundle_plist)
    xpc_services = os.path.join(sparkle_version, "XPCServices")
    if enabled_xpc:
        step(
            "keeping Sparkle's XPC services: "
            + ", ".join(enabled_xpc)
            + " set in Info.plist"
        )
        if not os.path.isdir(xpc_services):
            die(
                f"{', '.join(enabled_xpc)} is set in the app's Info.plist, but "
                f"{SPARKLE_FRAMEWORK_NAME} has no XPCServices directory. Sparkle "
                "would fail at the point it tries to launch the service, which is "
                "in the middle of installing an update."
            )
        for entry in sorted(os.listdir(xpc_services)):
            service = os.path.join(xpc_services, entry)
            if entry.endswith(".xpc") and os.path.isdir(service):
                sign(service, label=f"Sparkle {entry}")
    elif os.path.isdir(xpc_services):
        present = sorted(
            e for e in os.listdir(xpc_services) if e.endswith(".xpc")
        )
        step(
            "removing Sparkle's unused XPC services ("
            + ", ".join(present or ["none"])
            + "): no sandbox, so nothing can launch them"
        )
        # Removing anything from an already-signed framework invalidates its signature, so this must happen immediately before the re-sign below.
        shutil.rmtree(xpc_services)
        # The top level is symlinks into Versions/Current, so remove there too or the dangling XPCServices link makes codesign fail.
        xpc_link = os.path.join(sparkle, "XPCServices")
        if os.path.islink(xpc_link):
            os.unlink(xpc_link)

    updater_app = os.path.join(sparkle_version, "Updater.app")
    if not os.path.isdir(updater_app):
        die(
            f"{SPARKLE_FRAMEWORK_NAME} contains no Updater.app. That bundle is "
            "the process Sparkle hands off to in order to replace Orbit on disk "
            "and relaunch it; without it an update downloads and then fails at "
            "the last step."
        )
    sign(updater_app, label="Sparkle Updater.app  (no entitlements)")

    autoupdate = os.path.join(sparkle_version, "Autoupdate")
    if not os.path.isfile(autoupdate):
        die(
            f"{SPARKLE_FRAMEWORK_NAME} contains no Autoupdate tool. It is what "
            "Updater.app runs to perform the installation."
        )
    sign(autoupdate, label="Sparkle Autoupdate  (no entitlements)")

    sparkle_binary = os.path.join(sparkle_version, "Sparkle")
    if os.path.isfile(sparkle_binary):
        sign(sparkle_binary, label="Sparkle  (framework binary)")

    sign(sparkle, label=SPARKLE_FRAMEWORK_NAME)

    # 2. Anything else Mach-O not signed above; the outer bundle would otherwise seal it unsigned.
    for path in nested_machos(app):
        if path in signed_paths:
            continue
        if path == os.path.join(app, "Contents", "MacOS", "Orbit"):
            continue
        # Sparkle was sealed as bundles in step 1; re-signing its executables here would undo that ordering.
        if path.startswith(sparkle + os.sep):
            continue
        sign(path, label=f"{os.path.relpath(path, app)}  (additional nested code)")

    # 3. Last, the outer bundle, which seals everything above it.
    sign(app, BROWSER_ROLE.path, label=f"{os.path.basename(app)}  (browser process)")

    info("Signed. Verifying.")
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app], capture=True)
    info(f"{os.path.basename(app)} is signed and verifies with --deep --strict.")
    if adhoc:
        warn("this is an ad-hoc signature; it cannot be notarised or distributed.")
    return 0

def verify_sparkle_structure(app: str, checks: Checklist) -> None:
    contents = os.path.join(app, "Contents")
    plist = read_plist(os.path.join(contents, "Info.plist"))

    feed_ok, feed_detail = sparkle_feed_url_status(plist.get("SUFeedURL"))
    checks.check("SUFeedURL", feed_ok, feed_detail)
    key_ok, key_detail = sparkle_public_key_status(plist.get("SUPublicEDKey"))
    checks.check("SUPublicEDKey", key_ok, key_detail)

    frameworks_dir = os.path.join(contents, "Frameworks")
    sparkle = os.path.join(frameworks_dir, SPARKLE_FRAMEWORK_NAME)
    if not checks.check(
        f"{SPARKLE_FRAMEWORK_NAME} embedded",
        os.path.isdir(sparkle),
        "Contents/Frameworks" if os.path.isdir(sparkle)
        else "absent - this build has no updater at all",
    ):
        return

    version_dir = sparkle_version_directory(sparkle)
    if not checks.check(
        "Sparkle Versions/Current resolves",
        bool(version_dir) and os.path.isdir(version_dir),
        os.path.basename(version_dir) if version_dir else "no version directory",
    ):
        return
    version_name = os.path.basename(version_dir)

    # Both the symlink and its target: a copy made with anything but ditto flattens the symlinks and leaves a framework that can no longer install an update.
    for name in ("Autoupdate", "Updater.app", "Sparkle", "Resources"):
        link = os.path.join(sparkle, name)
        expected = f"Versions/Current/{name}"
        checks.check(
            f"Sparkle top-level '{name}' symlink",
            os.path.islink(link) and os.readlink(link) == expected,
            os.readlink(link) if os.path.islink(link) else "missing or not a symlink",
        )
        checks.check(
            f"Sparkle Versions/{version_name}/{name} exists",
            os.path.exists(os.path.join(version_dir, name)),
            f"Versions/{version_name}/{name}",
        )

    updater_binary = os.path.join(version_dir, "Updater.app", "Contents", "MacOS", "Updater")
    checks.check(
        "Sparkle Updater.app executable",
        os.path.isfile(updater_binary) and os.access(updater_binary, os.X_OK),
        "Updater.app/Contents/MacOS/Updater",
    )
    autoupdate = os.path.join(version_dir, "Autoupdate")
    checks.check(
        "Sparkle Autoupdate is executable",
        os.path.isfile(autoupdate) and os.access(autoupdate, os.X_OK),
        f"Versions/{version_name}/Autoupdate",
    )

    # Enabled but absent is fatal; present but unused is only a warning, which is what a freshly archived, not-yet-signed bundle looks like.
    xpc_services = os.path.join(version_dir, "XPCServices")
    enabled = sparkle_enabled_xpc_keys(plist)
    present = (
        sorted(e for e in os.listdir(xpc_services) if e.endswith(".xpc"))
        if os.path.isdir(xpc_services) else []
    )
    if enabled:
        checks.check(
            "Sparkle XPC services present for the keys that enable them",
            bool(present),
            ", ".join(present) if present
            else f"{', '.join(enabled)} is set but XPCServices is missing",
        )
    else:
        checks.note(
            "Sparkle XPC services stripped",
            not present,
            "removed; the app is not sandboxed" if not present
            else ", ".join(present) + " still present - has this bundle been signed yet?",
        )
    # A symlink to a removed directory is the specific way the strip above goes half-done.
    xpc_link = os.path.join(sparkle, "XPCServices")
    checks.check(
        "no dangling Sparkle XPCServices symlink",
        not (os.path.islink(xpc_link) and not os.path.exists(xpc_link)),
        "clean" if not os.path.islink(xpc_link)
        else ("resolves" if os.path.exists(xpc_link) else "points at a removed directory"),
    )

def verify_structure(app: str, checks: Checklist) -> None:
    app = os.path.abspath(app)
    checks.check("app bundle exists", os.path.isdir(app), app)
    if not os.path.isdir(app):
        return

    contents = os.path.join(app, "Contents")
    main_binary = os.path.join(contents, "MacOS", "Orbit")
    checks.check(
        "main executable",
        os.path.isfile(main_binary) and os.access(main_binary, os.X_OK),
        "Contents/MacOS/Orbit",
    )
    checks.check("Info.plist", os.path.isfile(os.path.join(contents, "Info.plist")), "Contents/Info.plist")

    verify_sparkle_structure(app, checks)
    verify_engine_configuration(app, checks)

def verify_engine_configuration(app: str, checks: Checklist) -> None:
    frameworks = os.path.join(app, "Contents", "Frameworks")
    if not os.path.isdir(os.path.join(frameworks, "Orbit Framework.framework")):
        checks.note("embedded Chromium engine", False, "no Orbit Framework.framework in this bundle")
        return
    compiled = chromium_manager.compiled_engine_config(frameworks, "orbit")
    checks.check(
        "embedded engine has DCHECKs compiled out",
        compiled == "shipping",
        "shipping" if compiled == "shipping"
        else f"binary reports '{compiled or 'no marker'}'; a distributable build must embed "
             "the shipping engine, in which a development assertion is not there to abort on",
    )

def verify_signature(app: str, checks: Checklist, require_timestamp: bool, require_notarised: bool) -> None:
    app = os.path.abspath(app)

    deep = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
               capture=True, check=False)
    checks.check(
        "codesign --verify --deep --strict",
        deep.returncode == 0,
        "valid on disk" if deep.returncode == 0
        else last_line(deep.stderr, deep.stdout) or "failed",
    )

    outer = codesign_info(app)
    checks.check("outer bundle is signed", outer["signed"], ", ".join(outer["flags"]) or "-")
    checks.check("outer bundle uses the hardened runtime", outer["hardened_runtime"],
                 "runtime" if outer["hardened_runtime"] else "notarisation requires it")
    if require_timestamp:
        checks.check("outer bundle has a secure timestamp", outer["secure_timestamp"],
                     "present" if outer["secure_timestamp"] else
                     "absent - notarisation rejects signatures without one")
    else:
        checks.note("outer bundle has a secure timestamp", outer["secure_timestamp"],
                    "present" if outer["secure_timestamp"] else
                    "absent (expected for an ad-hoc build)")
    if outer["adhoc"]:
        checks.note("signing identity", False,
                    "ad-hoc: this bundle is verifiable but not distributable")
    elif outer["authorities"]:
        checks.note("signing identity", True, outer["authorities"][0])

    # Every nested Mach-O must be signed in its own right, or the outer signature seals unsigned code and notarisation rejects the whole bundle.
    unsigned = []
    for path in nested_machos(app):
        result = run(["codesign", "--verify", "--strict", path], capture=True, check=False)
        if result.returncode != 0:
            unsigned.append(os.path.relpath(path, app))
    checks.check(
        "every nested Mach-O is individually signed",
        not unsigned,
        f"{len(nested_machos(app))} images checked" if not unsigned
        else "unsigned: " + ", ".join(unsigned[:5]) + (" …" if len(unsigned) > 5 else ""),
    )

    frameworks_dir = os.path.join(app, "Contents", "Frameworks")

    # No engine bridge exists yet (Chromium/README.md); the browser process is
    # the only signed role to check.
    embedded = codesign_entitlements(app)
    granted = sorted(k for k, v in embedded.items() if v is True)
    expected = sorted(BROWSER_ROLE.entitlements)
    checks.check(
        f"{BROWSER_ROLE.display} entitlements",
        granted == expected,
        "as declared" if granted == expected else
        f"expected [{', '.join(expected)}], signature carries [{', '.join(granted) or 'none'}]",
    )
    checks.check(
        f"{BROWSER_ROLE.display} uses the hardened runtime",
        outer["hardened_runtime"],
        "runtime" if outer["hardened_runtime"] else "missing --options runtime",
    )

    # These processes replace Orbit on disk and must carry no entitlements; each is also checked as a sealed bundle.
    sparkle = os.path.join(frameworks_dir, SPARKLE_FRAMEWORK_NAME)
    if os.path.isdir(sparkle):
        version_dir = sparkle_version_directory(sparkle)
        subjects = [(SPARKLE_FRAMEWORK_NAME, sparkle)]
        if version_dir and os.path.isdir(version_dir):
            updater_app = os.path.join(version_dir, "Updater.app")
            autoupdate = os.path.join(version_dir, "Autoupdate")
            if os.path.isdir(updater_app):
                subjects.append(("Sparkle Updater.app", updater_app))
            if os.path.isfile(autoupdate):
                subjects.append(("Sparkle Autoupdate", autoupdate))
            xpc_services = os.path.join(version_dir, "XPCServices")
            if os.path.isdir(xpc_services):
                for entry in sorted(os.listdir(xpc_services)):
                    if entry.endswith(".xpc"):
                        subjects.append((f"Sparkle {entry}", os.path.join(xpc_services, entry)))
        for label, path in subjects:
            granted = sorted(k for k, v in codesign_entitlements(path).items() if v is True)
            checks.check(
                f"{label} carries no entitlements",
                not granted,
                "none" if not granted else "unexpected: " + ", ".join(granted),
            )
            sealed = run(["codesign", "--verify", "--strict", path], capture=True, check=False)
            checks.check(
                f"{label} is sealed in its own right",
                sealed.returncode == 0,
                "valid" if sealed.returncode == 0
                else last_line(sealed.stderr, sealed.stdout) or "failed",
            )
            nested_info = codesign_info(path)
            checks.check(
                f"{label} uses the hardened runtime",
                nested_info["hardened_runtime"],
                "runtime" if nested_info["hardened_runtime"] else "missing --options runtime",
            )

    if require_notarised:
        stapled = run(["xcrun", "stapler", "validate", app], capture=True, check=False)
        checks.check(
            "notarisation ticket is stapled",
            stapled.returncode == 0,
            "stapled" if stapled.returncode == 0
            else "no ticket - run: Scripts/release notarize",
        )

    assessment = run(["spctl", "--assess", "--type", "exec", "--verbose=2", app],
                     capture=True, check=False)
    verdict_text = last_line((assessment.stderr or "") + (assessment.stdout or "")) or "no verdict"
    if require_notarised:
        checks.check("Gatekeeper accepts the app", assessment.returncode == 0, verdict_text)
    else:
        checks.note("Gatekeeper assessment", assessment.returncode == 0, verdict_text)

def cmd_verify(args) -> int:
    checks = Checklist()
    checks.section("Bundle structure")
    verify_structure(args.app, checks)
    if not args.structure_only:
        checks.section("Code signature")
        verify_signature(args.app, checks, require_timestamp=args.require_timestamp,
                         require_notarised=args.require_notarised)
    return checks.finish("verify")

def cmd_package(args) -> int:
    app = os.path.abspath(args.app)
    if not os.path.isdir(app):
        die(f"no app bundle at {app}")

    resolved = resolve_version(args.version)
    dmg = args.output or os.path.join(DEFAULT_WORK_DIR, resolved["dmg_name"] or "Orbit.dmg")
    dmg = os.path.abspath(dmg)
    volume = args.volume_name or (
        f"Orbit {resolved['marketing_version']}" if resolved["marketing_version"] else "Orbit"
    )

    staging = os.path.join(
        os.path.dirname(dmg) or DEFAULT_WORK_DIR,
        f".{os.path.basename(dmg)}.staging",
    )
    os.makedirs(os.path.dirname(dmg), exist_ok=True)
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    os.makedirs(staging)

    info(f"Building {os.path.basename(dmg)}")
    # ditto, not cp: it preserves the xattrs and symlinks a signed bundle's seal depends on.
    step("staging the app")
    run(["ditto", app, os.path.join(staging, os.path.basename(app))], capture=True)
    os.symlink("/Applications", os.path.join(staging, "Applications"))

    if os.path.exists(dmg):
        os.remove(dmg)

    step("hdiutil create")
    run([
        "hdiutil", "create",
        "-volname", volume,
        "-srcfolder", staging,
        "-fs", "HFS+",
        "-format", "UDZO",
        "-imagekey", "zlib-level=9",
        "-ov",
        dmg,
    ], capture=True)
    shutil.rmtree(staging, ignore_errors=True)

    if not args.no_sign:
        identity = resolve_identity(args)
        command = ["codesign", "--force", "--sign", identity]
        if identity != "-":
            command.append("--timestamp")
        keychain = args.keychain or os.environ.get("ORBIT_SIGN_KEYCHAIN")
        if keychain:
            command += ["--keychain", keychain]
        command.append(dmg)
        step(f"signing the disk image with {identity}")
        run(command, capture=True)

    info(f"Wrote {dmg}")
    print(dmg)
    return 0

def cmd_notarize(args) -> int:
    target = os.path.abspath(args.file)
    if not os.path.exists(target):
        die(f"nothing to notarise at {target}")

    auth = notary_auth_args()
    configured, description = notary_credential_summary()
    info(f"Submitting {os.path.basename(target)} using {description}")

    submission = target
    temporary_zip = None
    if os.path.isdir(target):
        # notarytool takes a zip, a disk image or an installer package, never a bare .app.
        temporary_zip = target.rstrip(os.sep) + ".notarize.zip"
        if os.path.exists(temporary_zip):
            os.remove(temporary_zip)
        step("zipping the bundle for submission")
        run(["ditto", "-c", "-k", "--keepParent", target, temporary_zip], capture=True)
        submission = temporary_zip

    result = run(
        ["xcrun", "notarytool", "submit", submission, *auth,
         "--wait", "--timeout", args.timeout, "--output-format", "json"],
        capture=True,
        check=False,
    )
    if temporary_zip and os.path.exists(temporary_zip):
        os.remove(temporary_zip)

    payload = {}
    try:
        payload = json.loads((result.stdout or "").strip() or "{}")
    except json.JSONDecodeError:
        pass

    submission_id = payload.get("id", "")
    status = payload.get("status", "")
    if not submission_id:
        detail = ((result.stdout or "") + (result.stderr or "")).strip()
        die(f"notarytool did not return a submission id.\n{detail}")

    info(f"Submission {submission_id} -> {status or 'unknown'}")

    if status != "Accepted":
        print(red("The notary service did not accept this build. Its log follows."), file=sys.stderr)
        run(["xcrun", "notarytool", "log", submission_id, *auth], check=False)
        return 1

    staple_target = args.staple or (target if os.path.isdir(target) or target.endswith(".dmg") else None)
    if staple_target:
        step(f"stapling {os.path.basename(staple_target)}")
        run(["xcrun", "stapler", "staple", staple_target])
        run(["xcrun", "stapler", "validate", staple_target])
        info(f"Stapled {staple_target}")
    else:
        warn(
            f"nothing was stapled. A .zip cannot carry a ticket; pass --staple with the "
            f"path to the .app or .dmg it contains."
        )
    return 0

def cmd_all(args) -> int:
    info("Preflight")
    doctor_args = argparse.Namespace(
        app=None, adhoc=args.adhoc, keychain=args.keychain, identity=args.identity
    )
    if cmd_doctor(doctor_args) != 0 and not args.force:
        die(
            "preflight failed; fix the checks above, or pass --force to proceed anyway "
            "(which will simply fail later, further in)."
        )

    if not args.adhoc:
        resolve_identity(args)
        notary_auth_args()

    archive_path = args.archive or os.path.join(DEFAULT_WORK_DIR, "Orbit.xcarchive")
    archive_args = argparse.Namespace(
        version=args.version, build=args.build, archive=archive_path, archs=args.archs,
        adhoc=args.adhoc, identity=args.identity, team=args.team, derived_data=args.derived_data,
    )
    if cmd_archive(archive_args) != 0:
        return 1

    app = os.path.join(DEFAULT_WORK_DIR, "export", APP_NAME)
    os.makedirs(os.path.dirname(app), exist_ok=True)
    if os.path.isdir(app):
        shutil.rmtree(app)
    info("Exporting the archived app")
    run(["ditto", app_from_archive(archive_path), app], capture=True)

    sign_args = argparse.Namespace(app=app, identity=args.identity, adhoc=args.adhoc,
                                   keychain=args.keychain)
    if cmd_sign(sign_args) != 0:
        return 1

    verify_args = argparse.Namespace(app=app, structure_only=False,
                                     require_timestamp=not args.adhoc, require_notarised=False)
    if cmd_verify(verify_args) != 0:
        die("the signed bundle did not verify; refusing to notarise or package it.")

    if not args.adhoc:
        info("Notarising the app")
        notarize_args = argparse.Namespace(file=app, staple=app, timeout=args.timeout)
        if cmd_notarize(notarize_args) != 0:
            return 1

    resolved = resolve_version(args.version)
    dmg = args.output or os.path.join(DEFAULT_WORK_DIR, resolved["dmg_name"] or "Orbit.dmg")
    package_args = argparse.Namespace(app=app, output=dmg, version=args.version,
                                      volume_name=None, no_sign=args.adhoc,
                                      identity=args.identity, adhoc=args.adhoc,
                                      keychain=args.keychain)
    if cmd_package(package_args) != 0:
        return 1

    if not args.adhoc:
        info("Notarising the disk image")
        notarize_args = argparse.Namespace(file=dmg, staple=dmg, timeout=args.timeout)
        if cmd_notarize(notarize_args) != 0:
            return 1

        final = argparse.Namespace(app=app, structure_only=False,
                                   require_timestamp=True, require_notarised=True)
        if cmd_verify(final) != 0:
            return 1

    print()
    info("Release complete.")
    print(f"  app  {app}")
    print(f"  dmg  {dmg}")
    if args.adhoc:
        warn("this was an --adhoc run: nothing here is distributable.")
    return 0

def add_signing_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--identity", help="codesign identity (default: the only Developer ID Application one)")
    parser.add_argument("--adhoc", action="store_true",
                        help="sign ad-hoc: verifiable, but not distributable and not notarisable")
    parser.add_argument("--keychain", help="keychain to search for the identity")

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="Scripts/release",
        description="Build, sign, notarise and package Orbit for Developer ID distribution.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  Scripts/release doctor\n"
            "  Scripts/release entitlements --check\n"
            "  Scripts/release archive --version 1.0.0\n"
            "  Scripts/release sign --app build/release/export/Orbit.app --adhoc\n"
            "  Scripts/release verify --app build/release/export/Orbit.app\n"
            "  Scripts/release all --version 1.0.0\n"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_doctor = sub.add_parser("doctor", help="check the toolchain, identity, engine and layout")
    p_doctor.add_argument("--app", help="also verify the structure of a built app bundle")
    p_doctor.add_argument("--adhoc", action="store_true",
                          help="do not require a Developer ID certificate")
    p_doctor.add_argument("--identity", help=argparse.SUPPRESS)
    p_doctor.add_argument("--keychain", help="keychain to search for the identity")
    p_doctor.set_defaults(func=cmd_doctor)

    p_version = sub.add_parser("version", help="resolve the version this build would carry")
    p_version.add_argument("--json", action="store_true", help="machine-readable output")
    p_version.add_argument("--set", help="resolve as if MARKETING_VERSION were this")
    p_version.add_argument("--manifest-only", action="store_true",
                           help="answer from Chromium/chromium-version.json alone; do not run xcodebuild")
    p_version.set_defaults(func=cmd_version)

    p_ent = sub.add_parser("entitlements", help="show, regenerate or drift-check the per-role plists")
    group = p_ent.add_mutually_exclusive_group()
    group.add_argument("--print", metavar="ROLE",
                       help="print one role's generated plist (" + ", ".join(r.key for r in ALL_ROLES) + ")")
    group.add_argument("--write", action="store_true", help="rewrite every plist from the role table")
    group.add_argument("--check", action="store_true", help="fail if any plist has drifted from the table")
    p_ent.set_defaults(func=cmd_entitlements)

    p_archive = sub.add_parser("archive", help="xcodebuild archive a Release Orbit.app")
    p_archive.add_argument("--version", help="MARKETING_VERSION for this build")
    p_archive.add_argument("--build", help="CURRENT_PROJECT_VERSION for this build")
    p_archive.add_argument("--archive", help="where to write the .xcarchive")
    p_archive.add_argument("--archs", help="architectures to build (default: host architecture)")
    p_archive.add_argument("--team", help="DEVELOPMENT_TEAM (default: $APPLE_TEAM_ID)")
    p_archive.add_argument("--derived-data", help="-derivedDataPath for the build")
    add_signing_arguments(p_archive)
    p_archive.set_defaults(func=cmd_archive)

    p_sign = sub.add_parser("sign", help="sign an Orbit.app inside out, for distribution")
    p_sign.add_argument("--app", required=True, help="the Orbit.app to sign")
    add_signing_arguments(p_sign)
    p_sign.set_defaults(func=cmd_sign)

    p_verify = sub.add_parser("verify", help="prove a bundle is structurally and cryptographically sound")
    p_verify.add_argument("--app", required=True, help="the Orbit.app to inspect")
    p_verify.add_argument("--structure-only", action="store_true",
                          help="check the layout only; do not look at signatures")
    p_verify.add_argument("--require-timestamp", action="store_true",
                          help="fail unless the signature carries a secure timestamp")
    p_verify.add_argument("--require-notarised", action="store_true",
                          help="fail unless a notarisation ticket is stapled and Gatekeeper accepts it")
    p_verify.set_defaults(func=cmd_verify)

    p_package = sub.add_parser("package", help="build the drag-to-Applications disk image")
    p_package.add_argument("--app", required=True, help="the signed Orbit.app to package")
    p_package.add_argument("--output", help="path of the .dmg to write")
    p_package.add_argument("--version", help="version used to name the image")
    p_package.add_argument("--volume-name", help="mounted volume name")
    p_package.add_argument("--no-sign", action="store_true", help="do not sign the disk image")
    add_signing_arguments(p_package)
    p_package.set_defaults(func=cmd_package)

    p_notarize = sub.add_parser("notarize", help="submit to Apple's notary service, wait, staple")
    p_notarize.add_argument("--file", required=True, help="the .app, .dmg or .zip to submit")
    p_notarize.add_argument("--staple", help="what to staple the ticket to (default: the submission)")
    p_notarize.add_argument("--timeout", default="45m", help="how long to wait for a verdict")
    p_notarize.set_defaults(func=cmd_notarize)

    p_all = sub.add_parser("all", help="preflight, archive, sign, verify, notarise, package, staple")
    p_all.add_argument("--version", help="MARKETING_VERSION for this release")
    p_all.add_argument("--build", help="CURRENT_PROJECT_VERSION for this release")
    p_all.add_argument("--archive", help="where to write the .xcarchive")
    p_all.add_argument("--output", help="path of the .dmg to write")
    p_all.add_argument("--archs", help="architectures to build (default: host architecture)")
    p_all.add_argument("--team", help="DEVELOPMENT_TEAM (default: $APPLE_TEAM_ID)")
    p_all.add_argument("--derived-data", help="-derivedDataPath for the build")
    p_all.add_argument("--timeout", default="45m", help="how long to wait for each notary verdict")
    p_all.add_argument("--force", action="store_true", help="continue even if preflight fails")
    add_signing_arguments(p_all)
    p_all.set_defaults(func=cmd_all)

    return parser

def main(argv: list) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print()
        die("Interrupted.", code=130)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
