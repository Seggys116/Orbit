#!/usr/bin/env python3
"""Static security invariants for Orbit's process model and engine build. See Scripts/security-guards.

Runtime counterpart: OrbitTests/SandboxInvariantTests.swift, checking a real process tree.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

sys.path.insert(0, SCRIPT_DIR)
import chromium_manager as engine  # noqa: E402

CHROMIUM_XCCONFIG = os.path.join(REPO_ROOT, "Chromium", "Chromium.xcconfig")
GN_ARGS_PLATFORM = "macosarm64"
GN_DCHECK_ASSIGNMENT = re.compile(r"^\s*dcheck_always_on\s*=\s*(true|false)\s*$", re.MULTILINE)
XCCONFIG_DEFAULT_ENGINE = re.compile(r"^ORBIT_ENGINE_CONFIG\s*=\s*(\S+)\s*$", re.MULTILINE)

# Roots that may not all exist during the engine rewrite; MINIMUM_SCANNED_FILES
# stops this guard quietly scanning nothing and reporting success.
SOURCE_ROOTS = ("Orbit", "OrbitHelper", "OrbitDemo", "OrbitEngine", "Chromium/Embedder")
MINIMUM_SCANNED_FILES = 50
SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".h", ".hpp", ".cpp", ".c")
SCHEME_DIR = os.path.join("Orbit.xcodeproj", "xcshareddata", "xcschemes")

# Every switch here is silent -- the app behaves identically with or without it,
# which is why it needs a machine to notice. See design doc section 2.3.
DANGEROUS_SWITCHES = {
    "no-sandbox": (
        "Turns the Seatbelt sandbox off for every child process. The browser "
        "skips profile compilation entirely (ChildProcessLauncherHelper::"
        "BeforeLaunchOnLauncherThread), so a compromised renderer running "
        "attacker-controlled JavaScript gets the browser's own access to the "
        "disk, the keychain and the network."
    ),
    "disable-gpu-sandbox": (
        "Leaves the GPU process unconfined. The GPU process parses "
        "attacker-influenced shader and image data and talks to the kernel "
        "graphics drivers; it is the second most attacked process after the "
        "renderer."
    ),
    "single-process": (
        "Runs web content inside the browser process. There is then no renderer "
        "to sandbox, no site isolation, and no process boundary between a page "
        "and the user's profile. This is the total loss of the security model "
        "and it is invisible from the UI."
    ),
    "in-process-gpu": (
        "Runs GPU work in the browser process, so GPU driver bugs become "
        "browser-process bugs and the GPU sandbox stops existing."
    ),
    "disable-web-security": (
        "Switches off the same-origin policy. Any page can then read any other "
        "origin's data."
    ),
    "allow-running-insecure-content": (
        "Lets https pages load and execute http subresources, which hands any "
        "network attacker script execution in a secure origin."
    ),
    "ignore-certificate-errors": (
        "Accepts any TLS certificate, valid or not, which makes every https "
        "connection interceptable."
    ),
    "disable-site-isolation-trials": (
        "Disables site isolation, the mitigation that keeps a compromised or "
        "speculating renderer from reading another site's data."
    ),
    "disable-site-isolation-for-policy": ("Same effect as disable-site-isolation-trials."),
    "allow-file-access-from-files": (
        "Gives file: documents access to the whole filesystem through XHR and "
        "fetch, so one downloaded HTML file can read the user's home directory."
    ),
    "disable-features=IsolateOrigins": ("Removes origin isolation, half of site isolation."),
    "disable-features=SitePerProcess": ("Removes site isolation."),
    "remote-debugging-port": (
        "Opens an unauthenticated DevTools protocol socket. Anything on the "
        "machine that can reach the port drives the browser as the user."
    ),
    "remote-allow-origins": ("Only meaningful alongside remote debugging; see remote-debugging-port."),
}

# Feature names that are site isolation, whatever switch disables them.
SITE_ISOLATION_FEATURES = ("SitePerProcess", "IsolateOrigins")

COMMENT_PATTERNS = (
    re.compile(r"/\*.*?\*/", re.DOTALL),
    re.compile(r"^[ \t]*//.*$", re.MULTILINE),
)

STRING_LITERAL = re.compile(r'"([^"\\\n]|\\.)*"')


def strip_comments(text: str) -> str:
    """A switch named in prose is not a switch. Only whole-line // comments go, so trailing code before a comment is still scanned."""
    for pattern in COMMENT_PATTERNS:
        text = pattern.sub("", text)
    return text


def source_files() -> list:
    found = []
    for root_name in SOURCE_ROOTS:
        root = os.path.join(REPO_ROOT, root_name)
        for directory, _, names in os.walk(root):
            for name in sorted(names):
                if name.endswith(SOURCE_SUFFIXES):
                    found.append(os.path.join(directory, name))
    scheme_root = os.path.join(REPO_ROOT, SCHEME_DIR)
    if os.path.isdir(scheme_root):
        found += [os.path.join(scheme_root, n) for n in sorted(os.listdir(scheme_root))
                  if n.endswith(".xcscheme")]
    return found


class Finding:

    def __init__(self, path: str, line: int, text: str, invariant: str, why: str):
        self.path = os.path.relpath(path, REPO_ROOT)
        self.line = line
        self.text = text.strip()[:160]
        self.invariant = invariant
        self.why = why


def scan_switches() -> list:
    findings = []
    scanned = source_files()
    if len(scanned) < MINIMUM_SCANNED_FILES:
        findings.append(Finding(
            os.path.join(REPO_ROOT, "Scripts", "security_guards.py"), 0,
            f"scanned {len(scanned)} source files",
            "this guard must actually read Orbit's sources",
            "It found almost nothing to scan, so a clean result here means nothing at all. "
            "Either the source tree moved and SOURCE_ROOTS is out of date, or this is not a "
            "full checkout. A guard that silently inspects an empty file list is worse than "
            "no guard, because it reports success.",
        ))
        return findings
    for path in scanned:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
        is_scheme = path.endswith(".xcscheme")
        body = raw if is_scheme else strip_comments(raw)
        lines = body.splitlines()

        for index, line in enumerate(lines, start=1):
            literals = [line] if is_scheme else [m.group(0) for m in STRING_LITERAL.finditer(line)]
            haystack = " ".join(literals)
            if not haystack:
                continue
            for switch, why in DANGEROUS_SWITCHES.items():
                if switch in haystack:
                    findings.append(Finding(
                        path, index, line,
                        f"no shipped code path may pass --{switch} to the engine",
                        why,
                    ))
            for feature in SITE_ISOLATION_FEATURES:
                if feature in haystack and "disable" in haystack.lower():
                    findings.append(Finding(
                        path, index, line,
                        f"site isolation feature {feature} may not be disabled",
                        "Site isolation is what makes a renderer compromise, and a "
                        "Spectre-class cross-origin read, containable. It is on by "
                        "default; the only way to lose it is to ask.",
                    ))

        for match in re.finditer(r"no_sandbox\s*=\s*([A-Za-z0-9_]+)", body):
            if match.group(1) not in ("false", "NO", "0"):
                line = body[: match.start()].count("\n") + 1
                findings.append(Finding(
                    path, line, match.group(0),
                    "no_sandbox must be assigned false and nothing else",
                    "no_sandbox = true is the embedder-side spelling of --no-sandbox: "
                    "every helper launches unconfined and nothing in the UI changes.",
                ))
    return findings


DCHECK_WHY = (
    "dcheck_always_on is true by default in every non-official Chromium build "
    "(build/config/dcheck_always_on.gni: build_with_chromium && !is_official_build), so a "
    "shipping engine that does not set it false compiles every DCHECK in Blink, net and "
    "content into the binary and makes each one a fatal abort. One upstream QUIC assertion "
    "aborted Orbit's network service process mid-request and every request in flight was "
    "lost; the same check is a no-op in Chrome stable. It has to be written down explicitly, "
    "because the value that shipped the defect was the one nobody wrote."
)


def scan_dcheck() -> list:
    findings = []
    manifest = engine.load_manifest()
    build_target = manifest["build_target"]

    for config, wants_dcheck in sorted(engine.ENGINE_CONFIGS.items()):
        expected = f"dcheck_always_on = {'true' if wants_dcheck else 'false'}"
        generated = engine.gn_args_for(manifest, GN_ARGS_PLATFORM, config)
        if expected not in generated.splitlines():
            findings.append(Finding(
                engine.__file__, 0, generated.replace("\n", " | ").strip(" |"),
                f"the gn args Scripts/chromium writes for '{config}' must contain '{expected}'",
                DCHECK_WHY,
            ))

        out_dir = engine.out_dir_for(build_target, config)
        args_gn = os.path.join(out_dir, "args.gn")
        if os.path.isfile(args_gn):
            with open(args_gn, encoding="utf-8", errors="replace") as handle:
                on_disk = handle.read()
            match = GN_DCHECK_ASSIGNMENT.search(on_disk)
            if match is None:
                findings.append(Finding(
                    args_gn, 0, on_disk.replace("\n", " | ").strip(" |"),
                    f"out/{engine.build_dir_name_for(build_target, config)}/args.gn must assign dcheck_always_on",
                    DCHECK_WHY,
                ))
            elif match.group(1) != str(wants_dcheck).lower():
                line = on_disk[: match.start()].count("\n") + 1
                findings.append(Finding(
                    args_gn, line, match.group(0),
                    f"the '{config}' out directory must be generated with {expected}",
                    DCHECK_WHY,
                ))

        root = engine.matching_install_root(manifest, config)
        if root is None:
            continue
        compiled = engine.compiled_engine_config(root, build_target)
        if compiled != config:
            findings.append(Finding(
                root, 0, f"binary reports {compiled or 'no marker'}",
                f"the engine installed as '{config}' must have been compiled as '{config}'",
                DCHECK_WHY,
            ))

    try:
        with open(CHROMIUM_XCCONFIG, encoding="utf-8") as handle:
            xcconfig = handle.read()
    except OSError:
        xcconfig = ""
    default = XCCONFIG_DEFAULT_ENGINE.search(xcconfig)
    if default is None or default.group(1) != engine.DEFAULT_ENGINE_CONFIG:
        findings.append(Finding(
            CHROMIUM_XCCONFIG, 0, default.group(0) if default else "no ORBIT_ENGINE_CONFIG assignment",
            f"Chromium.xcconfig must default ORBIT_ENGINE_CONFIG to '{engine.DEFAULT_ENGINE_CONFIG}'",
            "Every configuration that is not named explicitly -- Release, and anything added "
            "later -- takes this value, so a default of anything but the shipping engine puts "
            "DCHECKs into a build the moment someone adds a configuration and forgets this file.",
        ))
    return findings


SWIFT_ROOTS = ("Orbit", "OrbitDemo", "OrbitHelper")
SWIFT_TEST_ROOTS = ("OrbitTests", "OrbitAppTests")
MINIMUM_SWIFT_FILES = 100

SCOPE_TYPE = os.path.join("Orbit", "Core", "OrbitRuntimeScope.swift")
DEFAULTS_TYPE = os.path.join("Orbit", "Core", "OrbitDefaults.swift")
DATA_ROOT_TYPE = os.path.join("Orbit", "Core", "OrbitDataRoot.swift")
ENGINE_STORAGE_TYPE = os.path.join("Orbit", "Engine", "EngineStorageDirectory.swift")

DEFAULTS_ALLOWED = {
    DEFAULTS_TYPE: (
        "the accessor itself. It is the one type that may name UserDefaults.standard and "
        "open a suite, because deciding which of the two a process gets is its whole job."
    ),
    os.path.join("Orbit", "UI", "Window", "OrbitTitleBarDoubleClick.swift"): (
        "AppleActionOnDoubleClick is a macOS global-domain setting the user chose in System "
        "Settings, not Orbit data. Every app reads it from the standard defaults; a scoped "
        "suite does not contain it, so routing it through OrbitDefaults would silently "
        "answer the wrong titlebar action in development and under test."
    ),
}

DATA_ROOT_ALLOWED = {
    DATA_ROOT_TYPE: (
        "the accessor itself. This is the one type allowed to name "
        "~/Library/Application Support/Orbit, because choosing that directory or a scoped "
        "one is its whole job."
    ),
    ENGINE_STORAGE_TYPE: (
        "productionProfile names the real profile only to assert that a private engine "
        "directory falls outside it. It is never used to configure the engine."
    ),
    os.path.join("OrbitDemo", "DemoEngineProbe.swift"): (
        "realProfileDirectory is the demo's negative control: it snapshots the real profile "
        "before and after a demo run to prove nothing was written to it. It resolves the "
        "home directory from the password database rather than through Foundation on "
        "purpose, so a redirected environment cannot make the check pass without ever "
        "looking at the directory it is about. Going through OrbitDataRoot would read the "
        "same redirection the probe exists to defeat."
    ),
}

BUNDLE_IDENTIFIER_ALLOWED = {
    SCOPE_TYPE: (
        "productionBundleIdentifier is declared here, and every other reader is expected to "
        "reach it through this type."
    ),
    os.path.join("OrbitTests", "ReleasePipelineTests.swift"): (
        "the literal is the CFBundleIdentifier value of a synthesised Info.plist fixture. "
        "Bundle identifiers in a plist are out of this guard's scope, and a test that proves "
        "the release pipeline stamps that exact identifier must not read the constant it is "
        "validating."
    ),
}

DEFAULTS_PATTERNS = (
    (re.compile(r"UserDefaults\s*\.\s*standard"), "UserDefaults.standard"),
    (re.compile(r"UserDefaults\s*\(\s*suiteName\s*:"), "UserDefaults(suiteName:)"),
)
APP_STORAGE_ATTRIBUTE = re.compile(r"@AppStorage\s*\(")
ORBIT_PROFILE_PATH = re.compile(r"Application Support/Orbit")
APPLICATION_SUPPORT_API = re.compile(r"\.applicationSupportDirectory\b")
HOME_DIRECTORY_API = re.compile(r"NSHomeDirectory\s*\(\s*\)|homeDirectoryForCurrentUser")
APPLICATION_SUPPORT_TEXT = "Application Support"
HOME_DIRECTORY_WINDOW = 6
BUNDLE_IDENTIFIER_LITERAL = re.compile(r'"com\.zak-noble-clarke\.Orbit"')

DEFAULTS_WHY = (
    "UserDefaults.standard is the real user's preferences. A run started from Xcode, and "
    "every test process, resolves to a scoped suite through OrbitDefaults precisely so it "
    "cannot read or overwrite them; a call site that names the standard defaults directly "
    "opts back out of that with no visible difference at all. Nothing fails, no window "
    "looks wrong, and the first evidence is a developer's own browser having lost a "
    "setting. Read and write through OrbitDefaults.standard instead, and pass it to "
    "@AppStorage as `store: OrbitDefaults.standard`."
)

DATA_ROOT_WHY = (
    "~/Library/Application Support/Orbit is the real user's browsing data -- history, "
    "notes, easels, downloads and the engine profile. OrbitDataRoot resolves a scoped "
    "directory for anything that is not the installed browser, so a store that builds its "
    "own path from the home directory writes a demo's or a test's data straight into it. "
    "That failure is silent and it is destructive: a prune or a reset run from a test then "
    "deletes real records. Take the URL from OrbitDataRoot.processDefault, or add a named "
    "subdirectory to OrbitDataRoot if the store needs one."
)

BUNDLE_IDENTIFIER_WHY = (
    "This literal is how a process recognises itself as the installed browser, and "
    "OrbitRuntimeScope.resolve is the one place that comparison is allowed to happen. A "
    "second copy is a second source of truth: it drifts the day the identifier changes, and "
    "whatever the copy guarded -- a scope decision, a running-instance check, a Keychain "
    "service -- then fails silently and in the unsafe direction. Use "
    "OrbitRuntimeScope.productionBundleIdentifier. Longer identifiers built on top of it, "
    "such as the Keychain service and the CloudKit container, already do."
)


def swift_files(roots) -> list:
    found = []
    for root_name in roots:
        root = os.path.join(REPO_ROOT, root_name)
        for directory, _, names in os.walk(root):
            for name in sorted(names):
                if name.endswith(".swift"):
                    found.append(os.path.join(directory, name))
    return found


def too_few_scanned(scanned: list, roots) -> list:
    if len(scanned) >= MINIMUM_SWIFT_FILES:
        return []
    return [Finding(
        os.path.join(REPO_ROOT, "Scripts", "security_guards.py"), 0,
        f"scanned {len(scanned)} Swift files under {', '.join(roots)}",
        "this guard must actually read Orbit's Swift sources",
        "It found almost nothing to scan, so a clean result here means nothing at all. "
        "Either the source tree moved and the root list is out of date, or this is not a "
        "full checkout. A guard that silently inspects an empty file list is worse than no "
        "guard, because it reports success.",
    )]


def relative(path: str) -> str:
    return os.path.relpath(path, REPO_ROOT)


def read_stripped(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return strip_comments(handle.read())


def argument_list(text: str, opening: int) -> str:
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    return text[opening:]


def line_of(text: str, offset: int) -> int:
    return text[:offset].count("\n") + 1


def scan_defaults() -> list:
    scanned = swift_files(SWIFT_ROOTS)
    findings = too_few_scanned(scanned, SWIFT_ROOTS)
    if findings:
        return findings
    for path in scanned:
        if relative(path) in DEFAULTS_ALLOWED:
            continue
        body = read_stripped(path)
        lines = body.splitlines()
        for pattern, name in DEFAULTS_PATTERNS:
            for match in pattern.finditer(body):
                line = line_of(body, match.start())
                findings.append(Finding(
                    path, line, lines[line - 1],
                    f"{name} may only be reached through OrbitDefaults",
                    DEFAULTS_WHY,
                ))
        for match in APP_STORAGE_ATTRIBUTE.finditer(body):
            arguments = argument_list(body, match.end() - 1)
            if "OrbitDefaults" in arguments:
                continue
            line = line_of(body, match.start())
            findings.append(Finding(
                path, line, lines[line - 1],
                "@AppStorage must name its store: `store: OrbitDefaults.standard`",
                DEFAULTS_WHY,
            ))
    return findings


def scan_data_root() -> list:
    scanned = swift_files(SWIFT_ROOTS)
    findings = too_few_scanned(scanned, SWIFT_ROOTS)
    if findings:
        return findings
    for path in scanned:
        if relative(path) in DATA_ROOT_ALLOWED:
            continue
        body = read_stripped(path)
        lines = body.splitlines()

        for index, line in enumerate(lines, start=1):
            for literal in STRING_LITERAL.finditer(line):
                if ORBIT_PROFILE_PATH.search(literal.group(0)):
                    findings.append(Finding(
                        path, index, line,
                        "only OrbitDataRoot may spell out the real profile's path",
                        DATA_ROOT_WHY,
                    ))
                    break

        for match in APPLICATION_SUPPORT_API.finditer(body):
            line = line_of(body, match.start())
            findings.append(Finding(
                path, line, lines[line - 1],
                "only OrbitDataRoot may ask Foundation for the Application Support directory",
                DATA_ROOT_WHY,
            ))

        for match in HOME_DIRECTORY_API.finditer(body):
            line = line_of(body, match.start())
            window = []
            for candidate in lines[line - 1:line - 1 + HOME_DIRECTORY_WINDOW]:
                if not candidate.strip():
                    break
                window.append(candidate)
            if APPLICATION_SUPPORT_TEXT not in "\n".join(window):
                continue
            findings.append(Finding(
                path, line, lines[line - 1],
                "only OrbitDataRoot may build an Application Support path from the home directory",
                DATA_ROOT_WHY,
            ))
    return findings


def scan_bundle_identifier() -> list:
    roots = SWIFT_ROOTS + SWIFT_TEST_ROOTS
    scanned = swift_files(roots)
    findings = too_few_scanned(scanned, roots)
    if findings:
        return findings
    for path in scanned:
        if relative(path) in BUNDLE_IDENTIFIER_ALLOWED:
            continue
        body = read_stripped(path)
        lines = body.splitlines()
        for match in BUNDLE_IDENTIFIER_LITERAL.finditer(body):
            line = line_of(body, match.start())
            findings.append(Finding(
                path, line, lines[line - 1],
                "the production bundle identifier is declared once, in OrbitRuntimeScope",
                BUNDLE_IDENTIFIER_WHY,
            ))
    return findings


PERSISTENT_GATE_WHY = (
    "EngineStorageDirectory.directory(for:) is the last thing between a launch and the real "
    "user's Chromium profile: `.persistent` answers nil -- meaning 'leave the engine on its "
    "own default', which is that profile -- and it may only do so in the production scope. "
    "Returning nil unconditionally, or dropping the scope argument, hands a development run "
    "and every test the real cookies, history and logged-in sessions. Nothing about that "
    "looks wrong from the UI; it looks like the browser working. Restore the gate: the "
    "`.persistent` case must call persistentDirectory(for: OrbitRuntimeScope.current), and "
    "persistentDirectory must answer nil only for a production scope."
)

PERSISTENT_GATE_CHECKS = (
    (re.compile(r"case\s+\.persistent\s*:(.*?)(?=\n\s*case\s|\n\s*\}\s*\n)", re.DOTALL),
     "persistentDirectory(for:",
     "the .persistent branch of directory(for:) must call persistentDirectory(for:"),
)


def scan_persistent_gate() -> list:
    path = os.path.join(REPO_ROOT, ENGINE_STORAGE_TYPE)
    if not os.path.isfile(path):
        return [Finding(
            path, 0, "file not found",
            f"{ENGINE_STORAGE_TYPE} must exist",
            PERSISTENT_GATE_WHY,
        )]
    body = read_stripped(path)
    findings = []

    if "OrbitRuntimeScope" not in body:
        findings.append(Finding(
            path, 0, "no mention of OrbitRuntimeScope",
            f"{ENGINE_STORAGE_TYPE} must resolve the profile through OrbitRuntimeScope",
            PERSISTENT_GATE_WHY,
        ))

    entry = re.search(r"func\s+directory\s*\(\s*for\s+storage\s*:(.*?)\n\s{4}\}", body, re.DOTALL)
    if entry is None:
        findings.append(Finding(
            path, 0, "no directory(for storage:) declaration",
            "EngineStorageDirectory must still resolve every EngineStorage in one function",
            PERSISTENT_GATE_WHY,
        ))
    else:
        for pattern, required, invariant in PERSISTENT_GATE_CHECKS:
            branch = pattern.search(entry.group(1))
            if branch is None or required not in branch.group(1):
                findings.append(Finding(
                    path, line_of(body, entry.start()),
                    branch.group(0).strip() if branch else "no .persistent case",
                    invariant, PERSISTENT_GATE_WHY,
                ))

    gate = re.search(
        r"func\s+persistentDirectory\s*\((.*?)\n\s{4}\}", body, re.DOTALL)
    if gate is None:
        findings.append(Finding(
            path, 0, "no persistentDirectory(for:) declaration",
            "persistentDirectory(for:) must exist and take an OrbitRuntimeScope",
            PERSISTENT_GATE_WHY,
        ))
    else:
        if "OrbitRuntimeScope" not in gate.group(1):
            findings.append(Finding(
                path, line_of(body, gate.start()), gate.group(0).splitlines()[0],
                "persistentDirectory must take the scope, not decide without it",
                PERSISTENT_GATE_WHY,
            ))
        if "isProduction" not in gate.group(1) and ".production" not in gate.group(1):
            findings.append(Finding(
                path, line_of(body, gate.start()), gate.group(0).splitlines()[0],
                "persistentDirectory must answer nil only for a production scope",
                PERSISTENT_GATE_WHY,
            ))
    return findings


def allowlist_epilogue(allowed: dict) -> list:
    lines = ["The only sanctioned exceptions, and why each one is one:"]
    for path in sorted(allowed):
        lines.append(f"  {path}")
        lines += [f"      {line}" for line in _wrap(allowed[path], width=66)]
    lines.append("Adding to that list is a change to the guarantee, not to the guard.")
    return lines


def report(title: str, findings: list, where: str, epilogue: list) -> int:
    if not findings:
        print(f"[ok] {title}: clean ({where})")
        return 0
    print()
    print(f"SECURITY GUARD FAILED: {title}", file=sys.stderr)
    for finding in findings:
        print(file=sys.stderr)
        print(f"  invariant broken: {finding.invariant}", file=sys.stderr)
        print(f"  at:               {finding.path}:{finding.line}", file=sys.stderr)
        print(f"  found:            {finding.text}", file=sys.stderr)
        print("  why it matters:   " + "\n                    ".join(
            _wrap(finding.why)), file=sys.stderr)
    print(file=sys.stderr)
    for line in epilogue:
        print(f"  {line}", file=sys.stderr)
    print(file=sys.stderr)
    print(f"  Runtime counterpart: {where}", file=sys.stderr)
    return 1


def _wrap(text: str, width: int = 58) -> list:
    words, lines, current = text.split(), [], ""
    for word in words:
        if len(current) + len(word) + 1 > width:
            lines.append(current)
            current = word
        else:
            current = f"{current} {word}".strip()
    if current:
        lines.append(current)
    return lines


def guard_switches(_args) -> int:
    return report(
        "sandbox-disabling switches",
        scan_switches(),
        "OrbitTests/SandboxInvariantTests.swift reads the real argv of every process in a "
        "running Orbit's tree, which catches a switch this static scan cannot see",
        [
            "This guard exists because every switch it looks for is SILENT: the app",
            "looks and behaves exactly the same with it and without it, so a build",
            "that has lost its sandbox is indistinguishable from one that has not",
            "until someone attacks it. If you believe a hit is legitimate, it is not:",
            "take it out. If the code genuinely never reaches the engine, move the",
            "string out of a string literal or out of the shipped targets.",
        ],
    )


def guard_dcheck(_args) -> int:
    return report(
        "engine DCHECK configuration",
        scan_dcheck(),
        "Scripts/chromium verify-engine --config shipping --bundle <Orbit.app>, which reads the "
        "marker out of the framework a built bundle actually embeds",
        [
            "A DCHECK is a development assertion. Compiled in, it aborts the process",
            "that trips it; compiled out, it is not there at all. Which one a build",
            "got is invisible from the outside until an assertion fires in front of a",
            "user, so it is written down in the gn args, in the binary's own marker,",
            "and checked here rather than remembered.",
        ],
    )


def guard_entitlements(_args) -> int:
    result = subprocess.run([os.path.join(SCRIPT_DIR, "release"), "entitlements", "--check"])
    if result.returncode == 0:
        print("[ok] entitlement invariants: clean (Scripts/release entitlements --check)")
        return 0
    print()
    print("SECURITY GUARD FAILED: entitlement invariants", file=sys.stderr)
    print("  The failing checks are listed above, each with the reason the", file=sys.stderr)
    print("  entitlement matters. An entitlement is a hole in the hardened runtime", file=sys.stderr)
    print("  for the life of the product and is granted per process role, so the", file=sys.stderr)
    print("  renderer -- the one process that executes attacker-controlled code --", file=sys.stderr)
    print("  is the one whose set has to stay smallest.", file=sys.stderr)
    print("  Fix by changing the role table in Scripts/release_manager.py and", file=sys.stderr)
    print("  running `Scripts/release entitlements --write`, never by editing a", file=sys.stderr)
    print("  .entitlements plist: those files are generated.", file=sys.stderr)
    return 1


def guard_defaults(_args) -> int:
    return report(
        "scoped preferences",
        scan_defaults(),
        "OrbitAppTests/OrbitDefaultsTests.swift and OrbitAppTests/DataRootIsolationTests.swift, "
        "which write through OrbitDefaults from a test process and then read the real "
        "preferences domain back to prove nothing landed in it",
        [
            "Which UserDefaults a process gets is decided once, by OrbitRuntimeScope,",
            "and handed out by OrbitDefaults. Every call site that names the standard",
            "defaults itself is a hole in that: the installed browser and a test",
            "process then behave identically, and the test writes the user's real",
            "settings. There is no UI for this and no test fails; it is only ever",
            "noticed afterwards, by the person whose browser changed.",
        ] + allowlist_epilogue(DEFAULTS_ALLOWED),
    )


def guard_data_root(_args) -> int:
    return report(
        "scoped data root",
        scan_data_root(),
        "OrbitAppTests/DataRootIsolationTests.swift, which snapshots every file under the "
        "real profile and asserts a demo run and a test run leave all of them untouched",
        [
            "Where a store writes is decided once, by OrbitRuntimeScope, and handed",
            "out by OrbitDataRoot. A path built from the home directory bypasses that",
            "decision and points a development or test run at the real browsing data.",
            "The write is silent; the delete is not recoverable. A new store must name",
            "its subdirectory on OrbitDataRoot rather than assemble a path of its own.",
        ] + allowlist_epilogue(DATA_ROOT_ALLOWED),
    )


def guard_bundle_identifier(_args) -> int:
    return report(
        "single production identity",
        scan_bundle_identifier(),
        "OrbitAppTests/OrbitRuntimeScopeTests.swift, which resolves the scope for real bundle "
        "identifiers, bundle paths and environments",
        [
            "Recognising the installed browser is what separates the real user's data",
            "from a scoped copy of it, and it happens in exactly one comparison, in",
            "OrbitRuntimeScope.resolve. A second copy of the literal is a second",
            "answer to that question, and the two stop agreeing the day the identifier",
            "changes -- silently, and in the direction that reaches real data.",
        ] + allowlist_epilogue(BUNDLE_IDENTIFIER_ALLOWED),
    )


def guard_engine_profile(_args) -> int:
    return report(
        "engine persistent-profile scope gate",
        scan_persistent_gate(),
        "OrbitAppTests/EngineStorageDirectoryTests.swift, which asserts .persistent resolves "
        "outside the real profile in every scope but production",
        [
            "This is a textual check on one function on purpose. The gate is three",
            "lines long, deleting it compiles, every test that does not run the real",
            "engine still passes, and the browser that results looks exactly right --",
            "because it is showing the user's own tabs, cookies and sessions to a",
            "development build or a test. The point is that removing it cannot pass",
            "unnoticed.",
        ],
    )


GUARDS = {
    "switches": guard_switches,
    "entitlements": guard_entitlements,
    "dcheck": guard_dcheck,
    "defaults": guard_defaults,
    "data-root": guard_data_root,
    "bundle-identifier": guard_bundle_identifier,
    "engine-profile": guard_engine_profile,
}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("guard", nargs="?", choices=sorted(GUARDS) + ["all"], default="all")
    args = parser.parse_args(argv)
    names = sorted(GUARDS) if args.guard == "all" else [args.guard]
    status = 0
    for name in names:
        status |= GUARDS[name](args)
    return status


if __name__ == "__main__":
    sys.exit(main())
