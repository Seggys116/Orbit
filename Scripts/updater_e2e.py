#!/usr/bin/env python3
"""Drives the shipped Sparkle end to end against scratch copies of real signed builds. See Scripts/updater-e2e."""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from xml.etree import ElementTree

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
PROBE_SOURCE = os.path.join(SCRIPT_DIR, "updater_e2e_probe.swift")
XCFRAMEWORK = os.path.join(REPO_ROOT, "DerivedData", "SourcePackages", "artifacts", "sparkle",
                           "Sparkle", "Sparkle.xcframework", "macos-arm64_x86_64")
PRODUCTION_BUNDLE_ID = "com.zak-noble-clarke.Orbit"
PRODUCTION_PROFILE = os.path.expanduser("~/Library/Application Support/Orbit")
PROBE_BUNDLE_ID = "com.zak-noble-clarke.OrbitUpdateProbe"

CASES = ["install", "no-downgrade", "forged-signature", "tampered-payload", "substituted-app",
         "verify-before-extraction"]


class Failure(Exception):
    pass


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def checked(command: list[str], **kwargs) -> str:
    result = run(command, **kwargs)
    if result.returncode != 0:
        raise Failure(f"{' '.join(command)} failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def info_value(app: str, key: str) -> str:
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as handle:
        return plistlib.load(handle).get(key, "")


def team_identifier(path: str) -> str:
    output = run(["codesign", "-dv", "--verbose=4", path]).stderr
    match = re.search(r"^TeamIdentifier=(\S+)$", output, re.M)
    return match.group(1) if match else ""


def running_orbit() -> list[str]:
    alive = []
    for line in run(["ps", "-Axo", "pid=,command="]).stdout.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2 and parts[1].split()[0].endswith("/Orbit.app/Contents/MacOS/Orbit"):
            alive.append(line.strip())
    return alive


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# MARK: - inputs


def materialise_app(source: str, destination_dir: str) -> str:
    os.makedirs(destination_dir, exist_ok=True)
    destination = os.path.join(destination_dir, "Orbit.app")
    if os.path.exists(destination):
        shutil.rmtree(destination)
    if source.endswith(".dmg"):
        mount = tempfile.mkdtemp(prefix="orbit-e2e-mount-")
        checked(["hdiutil", "attach", source, "-nobrowse", "-readonly", "-mountpoint", mount])
        try:
            app = os.path.join(mount, "Orbit.app")
            if not os.path.isdir(app):
                raise Failure(f"no Orbit.app inside {source}")
            checked(["ditto", app, destination])
        finally:
            run(["hdiutil", "detach", mount, "-force"])
            shutil.rmtree(mount, ignore_errors=True)
    else:
        checked(["cp", "-Rc", source, destination])
    return destination


def build_probe(work: str, host_app: str, identity: str) -> str:
    plist_path = os.path.join(work, "probe-Info.plist")
    with open(plist_path, "wb") as handle:
        plistlib.dump({
            "CFBundleIdentifier": PROBE_BUNDLE_ID,
            "CFBundleName": "OrbitUpdateProbe",
            "CFBundleExecutable": "probe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": True,
            # The tampered-payload and forged-signature feeds are served over local http.
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        }, handle)
    binary = os.path.join(work, "probe")
    frameworks = os.path.join(host_app, "Contents", "Frameworks")
    checked(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0",
             "-F", XCFRAMEWORK, "-framework", "Sparkle",
             "-Xlinker", "-rpath", "-Xlinker", frameworks,
             "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
             "-Xlinker", plist_path,
             "-o", binary, PROBE_SOURCE])
    checked(["codesign", "--force", "--sign", identity, "--timestamp=none", binary])
    return binary


# MARK: - local feed


def live_appcast() -> str:
    with urllib.request.urlopen("https://seggys116.github.io/Orbit/appcast.xml", timeout=60) as response:
        return response.read().decode("utf-8")


def newest_enclosure(appcast: str) -> dict[str, str]:
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    best: dict[str, str] | None = None
    for item in ElementTree.fromstring(appcast).iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        element = item.find(namespace + "version")
        build = enclosure.get(namespace + "version") or (element.text if element is not None else None)
        found = {"build": build or "0", "signature": enclosure.get(namespace + "edSignature", "")}
        if best is None or int(found["build"]) > int(best["build"]):
            best = found
    if best is None:
        raise Failure("no enclosure in the live appcast")
    return best


def write_feed(directory: str, port: int, payload_name: str, length: int, signature: str,
               build: str, version: str) -> str:
    feed = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Orbit updater end-to-end</title>
    <item>
      <title>{version}</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <enclosure url="http://127.0.0.1:{port}/{payload_name}" length="{length}"
                 type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
    path = os.path.join(directory, "appcast.xml")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(feed)
    return f"http://127.0.0.1:{port}/appcast.xml"


def serve(directory: str, port: int) -> subprocess.Popen:
    process = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                               cwd=directory, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return process
        except OSError:
            time.sleep(0.1)
    process.terminate()
    raise Failure("local feed server did not start")


def fake_orbit_app(directory: str, public_ed_key: str) -> str:
    app = os.path.join(directory, "Orbit.app")
    macos = os.path.join(app, "Contents", "MacOS")
    os.makedirs(macos, exist_ok=True)
    source = os.path.join(directory, "main.c")
    with open(source, "w", encoding="utf-8") as handle:
        handle.write("int main(void) { return 0; }\n")
    checked(["xcrun", "clang", "-o", os.path.join(macos, "Orbit"), source])
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({
            "CFBundleIdentifier": PRODUCTION_BUNDLE_ID,
            "CFBundleExecutable": "Orbit",
            "CFBundleName": "Orbit",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.4",
            "CFBundleVersion": "6",
            "SUPublicEDKey": public_ed_key,
            "SUFeedURL": "https://seggys116.github.io/Orbit/appcast.xml",
        }, handle)
    checked(["codesign", "--force", "--sign", "-", app])
    dmg = os.path.join(directory, "Substitute.dmg")
    checked(["hdiutil", "create", "-srcfolder", app, "-volname", "Orbit", "-format", "UDZO",
             "-ov", "-quiet", dmg])
    shutil.rmtree(app)
    return dmg


# MARK: - defaults


def sparkle_installation_caches() -> set[str]:
    root = os.path.expanduser(f"~/Library/Caches/{PRODUCTION_BUNDLE_ID}/org.sparkle-project.Sparkle/Installation")
    return {os.path.join(root, name) for name in os.listdir(root)} if os.path.isdir(root) else set()


def export_defaults() -> bytes | None:
    result = run(["defaults", "export", PRODUCTION_BUNDLE_ID, "-"])
    return result.stdout.encode("utf-8") if result.returncode == 0 else None


def restore_defaults(snapshot: bytes | None) -> None:
    if snapshot is None:
        run(["defaults", "delete", PRODUCTION_BUNDLE_ID])
        return
    subprocess.run(["defaults", "import", PRODUCTION_BUNDLE_ID, "-"], input=snapshot, check=False)


# MARK: - cases


def drive(probe: str, host_app: str, feed: str | None, mode: str, log_path: str, timeout: float) -> dict:
    command = [probe, "--host", host_app, "--mode", mode, "--out", log_path + ".json",
               "--timeout", str(int(timeout))]
    if feed:
        command += ["--feed", feed]
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 120)
    with open(log_path, "w", encoding="utf-8") as handle:
        handle.write(result.stdout + result.stderr)
    if not os.path.exists(log_path + ".json"):
        raise Failure(f"probe wrote no result; see {log_path}")
    with open(log_path + ".json", encoding="utf-8") as handle:
        return json.load(handle)


def event_names(result: dict) -> list[str]:
    return [event["event"] for event in result.get("events", [])]


def launch_updated_app(work: str, app: str, timeout: float) -> tuple[bool, str]:
    derived = os.path.join(work, "smoke-derived-data", "Build", "Products", "Release")
    os.makedirs(derived, exist_ok=True)
    link = os.path.join(derived, "Orbit.app")
    if os.path.islink(link) or os.path.exists(link):
        os.remove(link) if os.path.islink(link) else shutil.rmtree(link)
    os.symlink(app, link)
    command = [sys.executable, os.path.join(SCRIPT_DIR, "app_launch_smoke.py"), "run",
               "--scheme", "Orbit", "--attempts", "1", "--skip-build", "--configuration", "Release",
               "--derived-data", os.path.join(work, "smoke-derived-data"),
               "--results-dir", os.path.join(work, "smoke-results")]
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    with open(os.path.join(work, "smoke.log"), "w", encoding="utf-8") as handle:
        handle.write(result.stdout + result.stderr)
    tail = "\n".join((result.stdout + result.stderr).strip().splitlines()[-3:])
    return result.returncode == 0, tail


def case_install(options, work: str, identity: str, checks: list) -> None:
    host_dir = os.path.join(work, "host")
    app = materialise_app(options.base, host_dir)
    before = info_value(app, "CFBundleShortVersionString")
    probe = build_probe(work, app, identity)
    result = drive(probe, app, options.feed, "install", os.path.join(work, "probe.log"), options.timeout)
    events = event_names(result)
    after = info_value(app, "CFBundleShortVersionString")
    after_build = info_value(app, "CFBundleVersion")
    checks.append(("host started at an older version", before != after, f"{before} -> {after}"))
    checks.append(("Sparkle reported the update installed", result.get("outcome") == "installed",
                   json.dumps({"outcome": result.get("outcome"), "error": result.get("errorMessage", "")})))
    # No ready-to-install: Sparkle only asks that of a host that is running.
    for stage in ["download-started", "downloaded", "extracting", "extracted", "will-install", "installing", "installed"]:
        checks.append((f"reached {stage}", stage in events, ", ".join(events)))
    checks.append(("payload was downloaded whole",
                   result.get("receivedBytes", 0) == result.get("expectedBytes", -1),
                   f"{result.get('receivedBytes')} of {result.get('expectedBytes')} bytes"))
    checks.append((f"bundle on disk now reports {options.expect_version}",
                   after == options.expect_version, f"{app} is {after} ({after_build})"))
    verify = run(["codesign", "--verify", "--strict", "--verbose=2", app])
    checks.append(("replaced bundle passes codesign --verify", verify.returncode == 0,
                   verify.stderr.strip().splitlines()[-1] if verify.stderr.strip() else "ok"))
    assess = run(["spctl", "--assess", "--type", "exec", "-vv", app])
    checks.append(("replaced bundle passes Gatekeeper", assess.returncode == 0,
                   assess.stderr.strip().replace("\n", "; ")))
    checks.append(("Sparkle did not relaunch anything", result.get("relaunched") is False,
                   f"relaunched={result.get('relaunched')}"))
    if not options.skip_launch:
        launched, tail = launch_updated_app(work, app, options.launch_timeout)
        checks.append(("the replaced bundle launches and renders", launched, tail))


def case_no_downgrade(options, work: str, identity: str, checks: list) -> None:
    app = materialise_app(options.current, os.path.join(work, "host"))
    version = info_value(app, "CFBundleShortVersionString")
    probe = build_probe(work, app, identity)
    result = drive(probe, app, options.feed, "probe", os.path.join(work, "probe.log"), options.timeout)
    checks.append((f"a host already at {version} is offered nothing",
                   result.get("outcome") == "no-update",
                   json.dumps({"outcome": result.get("outcome"), "offered": result.get("offeredVersion", "")})))
    checks.append(("host bundle untouched", info_value(app, "CFBundleShortVersionString") == version, version))


def installer_crashes(since: float) -> list[str]:
    found = []
    for directory in [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]:
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            path = os.path.join(directory, name)
            if name.startswith("Autoupdate-") and os.path.getmtime(path) >= since:
                found.append(path)
    return found


def rejection_case(options, work: str, identity: str, checks: list, label: str,
                   prepare, host: str | None = None) -> None:
    app = host or materialise_app(options.base, os.path.join(work, "host"))
    before = info_value(app, "CFBundleShortVersionString")
    serve_dir = os.path.join(work, "serve")
    os.makedirs(serve_dir, exist_ok=True)
    payload_name, length, signature, build, version = prepare(serve_dir, app)
    port = free_port()
    feed = write_feed(serve_dir, port, payload_name, length, signature, build, version)
    server = serve(serve_dir, port)
    started = time.time()
    try:
        probe = build_probe(work, app, identity)
        result = drive(probe, app, feed, "install", os.path.join(work, "probe.log"), options.timeout)
    finally:
        server.terminate()
    time.sleep(options.crash_report_grace)
    after = info_value(app, "CFBundleShortVersionString")
    reason = " | ".join(result.get("errorChain", [])) or result.get("errorMessage", "")
    crashes = installer_crashes(started)
    checks.append((f"{label} is refused", result.get("outcome") == "rejected",
                   json.dumps({"outcome": result.get("outcome"), "reason": reason[:400]})))
    checks.append((f"{label} left the host at {before}", after == before, f"{app} is {after}"))
    checks.append((f"{label} was never installed", "installed" not in event_names(result),
                   ", ".join(event_names(result))))
    checks.append((f"{label} did not crash the installer", not crashes, ", ".join(crashes)))


def case_forged_signature(options, work: str, identity: str, checks: list) -> None:
    enclosure = newest_enclosure(live_appcast())

    def prepare(serve_dir: str, app: str):
        payload = os.path.join(serve_dir, "Orbit.dmg")
        checked(["cp", "-c", options.target_dmg, payload])
        real = enclosure["signature"]
        forged = ("B" if real[0] != "B" else "C") + real[1:]
        return "Orbit.dmg", os.path.getsize(payload), forged, enclosure["build"], "9.9.9"

    rejection_case(options, work, identity, checks, "a genuine payload with a forged signature", prepare)


def case_tampered_payload(options, work: str, identity: str, checks: list) -> None:
    enclosure = newest_enclosure(live_appcast())

    def prepare(serve_dir: str, app: str):
        payload = os.path.join(serve_dir, "Orbit.dmg")
        checked(["cp", "-c", options.target_dmg, payload])
        size = os.path.getsize(payload)
        with open(payload, "r+b") as handle:
            handle.seek(size // 2)
            original = handle.read(1)
            handle.seek(size // 2)
            handle.write(bytes([original[0] ^ 0xFF]))
        return "Orbit.dmg", size, enclosure["signature"], enclosure["build"], "9.9.9"

    rejection_case(options, work, identity, checks, "a tampered payload under its real signature", prepare)


def case_substituted_app(options, work: str, identity: str, checks: list) -> None:
    def prepare(serve_dir: str, app: str):
        dmg = fake_orbit_app(serve_dir, info_value(app, "SUPublicEDKey"))
        name = os.path.basename(dmg)
        return name, os.path.getsize(dmg), base64.b64encode(secrets.token_bytes(64)).decode(), "6", "1.0.4"

    rejection_case(options, work, identity, checks, "a substituted, self-signed app", prepare)


def prevalidating_host(options, work: str) -> str:
    app = materialise_app(options.base, os.path.join(work, "host"))
    path = os.path.join(app, "Contents", "Info.plist")
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    info["SUVerifyUpdateBeforeExtraction"] = True
    with open(path, "wb") as handle:
        plistlib.dump(info, handle)
    checked(["codesign", "--force", "--deep", "--sign", "-", app])
    return app


def case_verify_before_extraction(options, work: str, identity: str, checks: list) -> None:
    enclosure = newest_enclosure(live_appcast())
    app = prevalidating_host(options, work)

    def prepare(serve_dir: str, _app: str):
        payload = os.path.join(serve_dir, "Orbit.dmg")
        checked(["cp", "-c", options.target_dmg, payload])
        size = os.path.getsize(payload)
        with open(payload, "r+b") as handle:
            handle.seek(size // 2)
            original = handle.read(1)
            handle.seek(size // 2)
            handle.write(bytes([original[0] ^ 0xFF]))
        return "Orbit.dmg", size, enclosure["signature"], enclosure["build"], "9.9.9"

    rejection_case(options, work, identity, checks,
                   "with SUVerifyUpdateBeforeExtraction, a tampered payload", prepare, host=app)
    result = drive(build_probe(work, app, identity), app, options.feed, "install",
                   os.path.join(work, "genuine.log"), options.timeout)
    checks.append(("the same host still installs the genuine update",
                   result.get("outcome") == "installed" and
                   info_value(app, "CFBundleShortVersionString") == options.expect_version,
                   json.dumps({"outcome": result.get("outcome"),
                               "version": info_value(app, "CFBundleShortVersionString")})))


HANDLERS = {
    "install": case_install,
    "no-downgrade": case_no_downgrade,
    "forged-signature": case_forged_signature,
    "tampered-payload": case_tampered_payload,
    "substituted-app": case_substituted_app,
    "verify-before-extraction": case_verify_before_extraction,
}


# MARK: - driver


def preflight(options) -> str:
    if not os.path.isdir(XCFRAMEWORK):
        raise Failure(f"no Sparkle xcframework at {XCFRAMEWORK}; resolve the Swift packages first")
    alive = running_orbit()
    if alive and not options.allow_running_orbit:
        raise Failure("Orbit is running; quit it first so no installer can ever match its bundle path:\n  "
                      + "\n  ".join(alive))
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout
    match = re.search(r'([0-9A-F]{40}) "(Developer ID Application: [^"]+)"', identities)
    if not match:
        raise Failure("no Developer ID Application identity; the installer rejects XPC clients from another team")
    needed = {case: getattr(options, attribute) for case, attribute in
              [("install", "base"), ("no-downgrade", "current"), ("forged-signature", "target_dmg"),
               ("tampered-payload", "target_dmg"), ("substituted-app", "base"),
               ("verify-before-extraction", "target_dmg")]
              if case in options.cases}
    for case, path in needed.items():
        if not path or not os.path.exists(path):
            raise Failure(f"case {case} needs an input that does not exist: {path!r}")
    return match.group(1), match.group(2)


def command_run(options) -> int:
    identity_hash, identity_name = preflight(options)
    print(f"updater-e2e: signing the probe as {identity_name}")
    os.makedirs(options.work, exist_ok=True)
    snapshot = export_defaults()
    before_processes = running_orbit()
    before_installations = sparkle_installation_caches()
    failures = 0
    try:
        for case in options.cases:
            work = os.path.join(options.work, case)
            if os.path.isdir(work):
                shutil.rmtree(work)
            os.makedirs(work)
            checks: list = []
            print(f"\nupdater-e2e: {case}")
            started = time.time()
            try:
                HANDLERS[case](options, work, identity_hash, checks)
            except Exception as error:  # noqa: BLE001 - reported as a failed check
                checks.append((f"{case} ran to completion", False, str(error)))
            for name, passed, detail in checks:
                print(f"  {'PASS' if passed else 'FAIL'}  {name}" + (f" — {detail}" if detail else ""))
                failures += 0 if passed else 1
            print(f"  ({time.time() - started:.0f}s, artefacts in {work})")
    finally:
        restore_defaults(snapshot)
        for path in sparkle_installation_caches() - before_installations:
            shutil.rmtree(path, ignore_errors=True)
    leaked = [line for line in running_orbit() if line not in before_processes]
    print("\nupdater-e2e: no Orbit process was launched by an update" if not leaked
          else f"\nupdater-e2e: FAIL an update launched {leaked}")
    failures += len(leaked)
    if os.path.isdir(PRODUCTION_PROFILE):
        print(f"updater-e2e: {PRODUCTION_PROFILE} left in place, never opened by this run")
    print(f"\nupdater-e2e: {'PASSED' if failures == 0 else str(failures) + ' FAILED CHECK(S)'}")
    return 0 if failures == 0 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="updater-e2e", description=__doc__)
    parser.add_argument("--case", dest="cases", action="append", choices=CASES,
                        help="repeatable; every case by default")
    parser.add_argument("--base", help="a signed Orbit.app or .dmg at the OLD version, updated during the run")
    parser.add_argument("--current", help="a signed Orbit.app or .dmg at the version the feed offers")
    parser.add_argument("--target-dmg", help="the .dmg the live feed's newest item points at")
    parser.add_argument("--feed", help="feed override for the install and no-downgrade cases")
    parser.add_argument("--expect-version", default="1.0.3")
    parser.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "orbit-updater-e2e"))
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--launch-timeout", type=float, default=600.0)
    parser.add_argument("--skip-launch", action="store_true")
    # A report lands well after the crash; 6s is not enough to see one.
    parser.add_argument("--crash-report-grace", type=float, default=25.0)
    parser.add_argument("--allow-running-orbit", action="store_true")
    parser.set_defaults(handler=command_run)
    return parser


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(line_buffering=True)
    options = build_parser().parse_args(argv)
    options.cases = options.cases or CASES
    try:
        return options.handler(options)
    except Failure as error:
        print(f"updater-e2e: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
