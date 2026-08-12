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


GUARDS = {
    "switches": guard_switches,
    "entitlements": guard_entitlements,
    "dcheck": guard_dcheck,
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
