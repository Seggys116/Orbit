#!/usr/bin/env python3
"""Launches the real app bundles and decides whether they survived. See Scripts/app-launch-smoke.

Other suites drive an engine inside an XCTest host, which cannot catch a crash on the
AppKit/window-creation path. Stages/checks are read back from Orbit/Core/AppSmokeProbe.swift,
so a run cannot silently do less than the app claims.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
PROBE_SOURCE = os.path.join(REPO_ROOT, "Orbit", "Core", "AppSmokeProbe.swift")

STAGE_MARKER = "ORBIT-SMOKE: STAGES"
CHECK_MARKER = "ORBIT-SMOKE: CHECKS"

# The page the probe navigates to; its background is the marker colour the paint
# checks look for, so a "rendered" claim is specifically about this page.
MARKER_COLOUR = "4060A0"
MARKER_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Orbit launch smoke</title>
<style>
html, body { margin: 0; height: 100%; background: #4060A0; }
body { color: #ffffff; font: 700 42px -apple-system, sans-serif; }
h1 { margin: 0; padding: 24px; }
a { color: #ffffff; font-size: 20px; padding: 0 24px; }
</style>
</head>
<body>
<h1 id="marker">Orbit launch smoke</h1>
<p><a href="https://example.com/">a link</a></p>
</body>
</html>
"""

# A line matching any of these anywhere in a launch's output fails that launch.
# Several real defects announced themselves here while every test stayed green.
FATAL_PATTERNS = [
    ("FATAL:", "a Chromium FATAL log line"),
    ("Check failed", "a failed CHECK"),
    ("NOTREACHED", "a NOTREACHED"),
    ("Received signal", "Chromium's own crash handler"),
    ("DanglingPtr", "a dangling raw_ptr"),
]

DIAGNOSTIC_DIRECTORIES = [
    os.path.expanduser("~/Library/Logs/DiagnosticReports"),
    "/Library/Logs/DiagnosticReports",
]

PRODUCTION_PROFILE = os.path.expanduser("~/Library/Application Support/Orbit")


class SmokeError(Exception):
    pass


class Scheme:
    def __init__(self, name: str, xcode_scheme: str, app: str, executable: str, bundle_id: str):
        self.name = name
        self.xcode_scheme = xcode_scheme
        self.app = app
        self.executable = executable
        self.bundle_id = bundle_id

    # Every process name a crash report from one of these launches can carry.
    def crash_report_prefixes(self) -> list[str]:
        return [self.executable + "-", "Orbit Helper"]


SCHEMES = {
    "Orbit": Scheme("Orbit", "Orbit", "Orbit.app", "Orbit", "com.zak-noble-clarke.Orbit"),
    "Demo": Scheme("Demo", "Demo", "OrbitDemo.app", "OrbitDemo", "com.zak-noble-clarke.OrbitDemo"),
}


# MARK: - The inventory, read from the app's own source


def _enum_cases(text: str, marker: str) -> list[str]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if marker not in line:
            continue
        for start in range(index, min(index + 8, len(lines))):
            if re.search(r"\benum\s+\w+\s*:\s*String\s*,\s*CaseIterable\s*\{", lines[start]):
                cases = []
                for body in lines[start + 1:]:
                    if body.strip().startswith("}"):
                        return cases
                    match = re.match(r"\s*case\s+([A-Za-z0-9_]+)\s*$", body)
                    if match:
                        cases.append(match.group(1))
                raise SmokeError(
                    f"the enum after '{marker}' in {PROBE_SOURCE} is never closed; "
                    "this script reads the inventory out of that source and cannot guess it."
                )
    raise SmokeError(
        f"no '{marker}' enum in {PROBE_SOURCE}. The stages and checks a run must reach are "
        "read from the app's own source; if that enum moved or was renamed, this reader has to "
        "move with it rather than fall back to a list that can rot."
    )


def inventory() -> tuple[list[str], list[str]]:
    if not os.path.isfile(PROBE_SOURCE):
        raise SmokeError(f"{PROBE_SOURCE} does not exist, so there is no inventory to check a run against.")
    with open(PROBE_SOURCE, "r", encoding="utf-8") as handle:
        text = handle.read()
    stages = _enum_cases(text, STAGE_MARKER)
    checks = _enum_cases(text, CHECK_MARKER)
    if not stages or not checks:
        raise SmokeError(
            f"read {len(stages)} stages and {len(checks)} checks from {PROBE_SOURCE}; "
            "a run cannot be judged against an empty inventory."
        )
    return stages, checks


# MARK: - Processes


def running_processes() -> list[tuple[int, str]]:
    completed = subprocess.run(["/bin/ps", "-Ao", "pid=,args="], capture_output=True, text=True)
    processes = []
    for line in completed.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, arguments = line.partition(" ")
        try:
            processes.append((int(pid), arguments.strip()))
        except ValueError:
            continue
    return processes


def pids_running(executable: str) -> set[int]:
    return {
        pid for pid, arguments in running_processes()
        if arguments == executable or arguments.startswith(executable + " ")
    }


def pids_under(bundle: str) -> set[int]:
    return {pid for pid, arguments in running_processes() if arguments.startswith(bundle + "/")}


def is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def kill_tree(pid: int | None, bundle: str, spare: set[int]) -> list[int]:
    killed = []
    for victim in sorted(pids_under(bundle) | ({pid} if pid else set())):
        if victim in spare or not is_alive(victim):
            continue
        try:
            os.kill(victim, signal.SIGKILL)
            killed.append(victim)
        except OSError:
            pass
    return killed


def foreign_orbits() -> list[tuple[int, str]]:
    """Orbit or OrbitDemo processes this script did not start."""
    found = []
    for pid, arguments in running_processes():
        for suffix in ("/Orbit.app/Contents/MacOS/Orbit", "/OrbitDemo.app/Contents/MacOS/OrbitDemo"):
            if arguments == suffix or arguments.endswith(suffix) or arguments.split(" ")[0].endswith(suffix):
                found.append((pid, arguments.split(" ")[0]))
                break
    return found


# MARK: - Crash reports


def crash_reports() -> set[str]:
    found = set()
    for directory in DIAGNOSTIC_DIRECTORIES:
        try:
            for name in os.listdir(directory):
                if name.endswith(".ips"):
                    found.add(os.path.join(directory, name))
        except OSError:
            continue
    return found


def crash_report_pid(path: str) -> int | None:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            body = handle.read()
    except OSError:
        return None
    parts = body.split("\n", 1)
    if len(parts) != 2:
        return None
    try:
        return int(json.loads(parts[1]).get("pid"))
    except (ValueError, TypeError, json.JSONDecodeError, AttributeError):
        return None


# MARK: - The production profile


def profile_snapshot() -> dict[str, tuple[int, int]]:
    snapshot: dict[str, tuple[int, int]] = {}
    if not os.path.isdir(PRODUCTION_PROFILE):
        return snapshot
    for directory, _, names in os.walk(PRODUCTION_PROFILE):
        for name in names:
            path = os.path.join(directory, name)
            try:
                info = os.lstat(path)
            except OSError:
                continue
            snapshot[os.path.relpath(path, PRODUCTION_PROFILE)] = (info.st_size, info.st_mtime_ns)
    return snapshot


def profile_difference(before: dict, after: dict) -> list[str]:
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(path for path in set(before) & set(after) if before[path] != after[path])
    parts = []
    for label, paths in (("added", added), ("removed", removed), ("modified", changed)):
        if paths:
            shown = ", ".join(paths[:10])
            if len(paths) > 10:
                shown += f", … ({len(paths)} total)"
            parts.append(f"{label} {shown}")
    return parts


# MARK: - One attempt


class AttemptResult:
    def __init__(self, index: int, directory: str):
        self.index = index
        self.directory = directory
        self.pid: int | None = None
        self.duration = 0.0
        self.stages: list[str] = []
        self.checks_passed = 0
        self.problems: list[str] = []

    @property
    def ok(self) -> bool:
        return not self.problems


def read_stages(directory: str) -> list[str]:
    path = os.path.join(directory, "stages.tsv")
    stages = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                fields = line.strip().split("\t")
                if len(fields) == 2:
                    stages.append(fields[1])
    except OSError:
        pass
    return stages


def scan_for_fatals(paths: list[str]) -> list[str]:
    problems = []
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                for number, line in enumerate(handle, start=1):
                    for needle, description in FATAL_PATTERNS:
                        if needle in line:
                            problems.append(
                                f"{description} in {path}:{number}: {line.strip()[:400]}"
                            )
                            break
        except OSError:
            continue
    return problems


def run_attempt(
    scheme: Scheme,
    app_path: str,
    index: int,
    total: int,
    options: argparse.Namespace,
    run_directory: str,
    stages_expected: list[str],
    checks_expected: list[str],
) -> AttemptResult:
    directory = os.path.join(run_directory, f"{scheme.name}-{index:02d}")
    os.makedirs(os.path.join(directory, "page"), exist_ok=True)
    result = AttemptResult(index, directory)

    if options.url:
        url = options.url
        marker = ""
    else:
        page = os.path.join(directory, "page", "index.html")
        with open(page, "w", encoding="utf-8") as handle:
            handle.write(MARKER_PAGE)
        url = "file://" + page
        marker = MARKER_COLOUR

    stdout_path = os.path.join(directory, "stdout.log")
    stderr_path = os.path.join(directory, "stderr.log")
    for path in (stdout_path, stderr_path):
        with open(path, "w", encoding="utf-8"):
            pass

    executable = os.path.join(app_path, "Contents", "MacOS", scheme.executable)
    existing_pids = pids_running(executable)
    reports_before = crash_reports()

    environment = {
        "ORBIT_SMOKE_PROBE": "1",
        "ORBIT_SMOKE_PROBE_OUT": directory,
        "ORBIT_SMOKE_PROBE_URL": url,
        "ORBIT_SMOKE_PROBE_LABEL": scheme.name,
        "ORBIT_SMOKE_PROBE_ATTEMPT": str(index),
    }
    if marker:
        environment["ORBIT_SMOKE_PROBE_MARKER"] = marker

    command = ["/usr/bin/open", "-n", "-a", app_path, "--stdout", stdout_path, "--stderr", stderr_path]
    for name, value in environment.items():
        command += ["--env", f"{name}={value}"]
    # Passed as launch arguments, not saved preferences, so an unattended run is never
    # stopped by the quit confirmation or starts fetching a Sparkle appcast mid-measurement.
    command += [
        "--args",
        "-OrbitConfirmBeforeQuit", "NO",
        "-SUEnableAutomaticChecks", "NO",
    ]

    print(f"app-launch-smoke: {scheme.name} attempt {index}/{total}: open -n {app_path}")
    started = time.monotonic()
    launch = subprocess.run(command, capture_output=True, text=True)
    if launch.returncode != 0:
        result.problems.append(
            f"`open -n -a {app_path}` failed with status {launch.returncode}: "
            f"{(launch.stderr or launch.stdout).strip()[:400]}"
        )
        return result

    while time.monotonic() - started < 20:
        appeared = pids_running(executable) - existing_pids
        if len(appeared) == 1:
            result.pid = appeared.pop()
            break
        if len(appeared) > 1:
            result.problems.append(
                f"{len(appeared)} new {scheme.executable} processes appeared for one launch "
                f"({sorted(appeared)}); this run cannot tell which one it started."
            )
            return result
        time.sleep(0.1)

    result_path = os.path.join(directory, "result.json")
    deadline = started + options.attempt_timeout
    death: float | None = None
    while time.monotonic() < deadline:
        if os.path.exists(result_path):
            break
        if result.pid is not None and not is_alive(result.pid):
            death = time.monotonic() - started
            break
        time.sleep(0.2)

    if result.pid is None and not os.path.exists(result_path):
        result.duration = time.monotonic() - started
        result.stages = read_stages(directory)
        result.problems.append(
            f"{scheme.app} never appeared as a running process, and wrote no result, within "
            f"{result.duration:.1f}s of launch on attempt {index} of {total}. Stages reached: "
            f"{', '.join(result.stages) or 'none'}. Log: {stderr_path}"
        )
    elif death is not None:
        result.duration = death
        result.stages = read_stages(directory)
        reached = result.stages[-1] if result.stages else "none"
        result.problems.append(
            f"{scheme.app} died {death:.1f}s after launch on attempt {index} of {total} "
            f"(pid {result.pid}), before writing a result. Last stage reached: {reached}; "
            f"expected to reach {stages_expected[-1]}. Log: {stderr_path}"
        )
    elif not os.path.exists(result_path):
        result.duration = time.monotonic() - started
        result.stages = read_stages(directory)
        reached = result.stages[-1] if result.stages else "none"
        result.problems.append(
            f"{scheme.app} was still running {result.duration:.1f}s after launch on attempt "
            f"{index} of {total} (pid {result.pid}) and had written no result: it is hung. Last "
            f"stage reached: {reached}. Log: {stderr_path}"
        )

    # The probe quits through the ordinary path once its result is on disk, so
    # a process still alive after this is a shutdown that hung.
    if os.path.exists(result_path) and result.pid is not None:
        shutdown_deadline = time.monotonic() + options.shutdown_timeout
        while time.monotonic() < shutdown_deadline and is_alive(result.pid):
            time.sleep(0.2)
        result.duration = time.monotonic() - started
        if is_alive(result.pid):
            result.problems.append(
                f"{scheme.app} wrote its result but was still running {options.shutdown_timeout}s "
                f"later on attempt {index} of {total} (pid {result.pid}): the quit path did not "
                f"finish. Log: {stderr_path}"
            )

    killed = kill_tree(result.pid, app_path, existing_pids)
    if killed:
        print(f"app-launch-smoke:   killed leftover process(es) {killed}")

    time.sleep(options.crash_report_grace)

    result.stages = read_stages(directory)
    if result.stages != stages_expected:
        missing = [stage for stage in stages_expected if stage not in result.stages]
        unexpected = [stage for stage in result.stages if stage not in stages_expected]
        detail = []
        if missing:
            detail.append(f"never reached {', '.join(missing)}")
        if unexpected:
            detail.append(f"recorded unknown stage(s) {', '.join(unexpected)}")
        if not detail:
            detail.append(f"recorded them as {', '.join(result.stages)}, not in the declared order")
        result.problems.append(
            f"attempt {index} of {total}: {'; '.join(detail)}. The app declares "
            f"{len(stages_expected)} stages ({', '.join(stages_expected)}) and every launch must "
            f"reach all of them. Stages file: {os.path.join(directory, 'stages.tsv')}"
        )

    result.problems += judge_result_file(result_path, scheme, app_path, result, index, total, checks_expected)
    result.problems += scan_for_fatals([stderr_path, stdout_path])

    new_reports = sorted(crash_reports() - reports_before)
    for report in new_reports:
        name = os.path.basename(report)
        if not any(name.startswith(prefix) for prefix in scheme.crash_report_prefixes()):
            continue
        pid = crash_report_pid(report)
        owner = f"pid {pid}" if pid else "an unrecorded pid"
        result.problems.append(
            f"attempt {index} of {total} produced a crash report for {owner}: {report}"
        )

    return result


def judge_result_file(
    path: str,
    scheme: Scheme,
    app_path: str,
    result: AttemptResult,
    index: int,
    total: int,
    checks_expected: list[str],
) -> list[str]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        return [f"attempt {index} of {total}: {path} could not be read: {error}"]

    problems = []
    if payload.get("schema") != 1:
        problems.append(
            f"attempt {index} of {total}: {path} declares schema {payload.get('schema')!r}, not 1. "
            "AppSmokeProbe's result format changed; this reader has to change with it."
        )
    if payload.get("bundleIdentifier") != scheme.bundle_id:
        problems.append(
            f"attempt {index} of {total}: the result came from bundle "
            f"{payload.get('bundleIdentifier')!r}, not {scheme.bundle_id!r}."
        )
    reported_bundle = str(payload.get("bundlePath", ""))
    if os.path.realpath(reported_bundle) != os.path.realpath(app_path):
        problems.append(
            f"attempt {index} of {total}: the result came from {reported_bundle!r}, not the app "
            f"this run launched ({app_path})."
        )
    if result.pid is not None and payload.get("pid") != result.pid:
        problems.append(
            f"attempt {index} of {total}: the result was written by pid {payload.get('pid')}, but "
            f"this run launched pid {result.pid}."
        )

    checks = payload.get("checks") or []
    reported = [check.get("name") for check in checks]
    missing = [name for name in checks_expected if name not in reported]
    unknown = [name for name in reported if name not in checks_expected]
    duplicated = sorted({name for name in reported if reported.count(name) > 1})
    if missing:
        problems.append(
            f"attempt {index} of {total}: {len(missing)} declared check(s) are absent from "
            f"{path}: {', '.join(missing)}. The app declares {len(checks_expected)} checks and "
            "every one of them has to report an outcome."
        )
    if unknown:
        problems.append(
            f"attempt {index} of {total}: {path} reports check(s) the sources do not declare: "
            f"{', '.join(unknown)}."
        )
    if duplicated:
        problems.append(
            f"attempt {index} of {total}: {path} reports these checks more than once: "
            f"{', '.join(duplicated)}."
        )

    for check in checks:
        if check.get("passed") is True:
            result.checks_passed += 1
            continue
        problems.append(
            f"attempt {index} of {total}: check {check.get('name')} failed: {check.get('detail')}"
        )

    if payload.get("verdict") != "PASS" and not problems:
        problems.append(
            f"attempt {index} of {total}: the app's own verdict is {payload.get('verdict')!r} "
            f"though every check it reported passed. {path} is inconsistent with itself."
        )
    return problems


# MARK: - Building


def build(scheme: Scheme, options: argparse.Namespace, run_directory: str) -> None:
    log = os.path.join(run_directory, f"build-{scheme.name}.log")
    command = [
        "xcodebuild", "build",
        "-project", os.path.join(REPO_ROOT, "Orbit.xcodeproj"),
        "-scheme", scheme.xcode_scheme,
        "-configuration", "Debug",
        "-destination", options.destination,
        "-derivedDataPath", options.derived_data,
    ] + options.build_arguments
    print(f"app-launch-smoke: building the {scheme.xcode_scheme} scheme (log: {log})")
    with open(log, "w", encoding="utf-8") as handle:
        completed = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT, cwd=REPO_ROOT)
    if completed.returncode != 0:
        with open(log, "r", encoding="utf-8", errors="replace") as handle:
            tail = handle.read()[-4000:]
        raise SmokeError(
            f"building the {scheme.xcode_scheme} scheme failed with status {completed.returncode}. "
            f"Full log: {log}\n{tail}"
        )


# MARK: - Commands


def command_declared(arguments: argparse.Namespace) -> int:
    stages, checks = inventory()
    print(f"app-launch-smoke: {len(stages)} stages, {len(checks)} checks declared in {PROBE_SOURCE}")
    for stage in stages:
        print(f"app-launch-smoke:   stage {stage}")
    for check in checks:
        print(f"app-launch-smoke:   check {check}")
    return 0


def command_run(options: argparse.Namespace) -> int:
    stages_expected, checks_expected = inventory()
    schemes = [SCHEMES[name] for name in options.schemes]

    if options.attempts < 1:
        raise SmokeError(
            f"--attempts {options.attempts} cannot be satisfied by any run: a verdict over zero "
            "launches is not a pass."
        )

    manager = subprocess.run(["/bin/launchctl", "managername"], capture_output=True, text=True)
    session = manager.stdout.strip()
    if session != "Aqua":
        raise SmokeError(
            f"this login session is '{session or 'unknown'}', not 'Aqua'. These launches need a "
            "real window-server session: an app started without one cannot create a window, which "
            "is the exact code path this harness exists to exercise. Run it from a logged-in "
            "desktop session (CI: a runner with an interactive user), not over plain ssh."
        )

    intruders = foreign_orbits()
    if intruders and not options.allow_running_orbit:
        listing = ", ".join(f"pid {pid} ({path})" for pid, path in intruders)
        raise SmokeError(
            f"another Orbit is already running: {listing}. It writes to the real profile while "
            "this runs, which makes the production-profile check below unmeasurable, and it "
            "competes for the window server. Quit it, or pass --allow-running-orbit to run "
            "without that check."
        )

    run_directory = options.results_dir or os.path.join(
        options.derived_data, "AppLaunchSmoke", time.strftime("%Y%m%d-%H%M%S")
    )
    try:
        os.makedirs(run_directory, exist_ok=True)
    except OSError as error:
        raise SmokeError(f"could not create the results directory {run_directory}: {error}") from error

    print(
        f"app-launch-smoke: {len(schemes)} scheme(s) ({', '.join(scheme.name for scheme in schemes)}), "
        f"{options.attempts} launch(es) each, {len(checks_expected)} checks and "
        f"{len(stages_expected)} stages per launch"
    )
    print(f"app-launch-smoke: results in {run_directory}")

    profile_before = None if intruders else profile_snapshot()

    failures = 0
    executed_attempts = 0
    executed_checks = 0
    for scheme in schemes:
        if not options.skip_build:
            build(scheme, options, run_directory)
        app_path = os.path.join(options.derived_data, "Build", "Products", "Debug", scheme.app)
        if not os.path.isdir(app_path):
            raise SmokeError(
                f"{app_path} does not exist. Run without --skip-build, or point --derived-data at "
                "a tree that has it."
            )
        info = os.path.join(app_path, "Contents", "Info.plist")
        identifier = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", info],
            capture_output=True, text=True,
        ).stdout.strip()
        if identifier != scheme.bundle_id:
            raise SmokeError(
                f"{app_path} declares bundle identifier {identifier!r}, but the {scheme.name} "
                f"scheme is {scheme.bundle_id!r}. This run would be measuring the wrong app."
            )

        for index in range(1, options.attempts + 1):
            attempt = run_attempt(
                scheme, app_path, index, options.attempts, options, run_directory,
                stages_expected, checks_expected,
            )
            executed_attempts += 1
            executed_checks += attempt.checks_passed
            if attempt.ok:
                print(
                    f"app-launch-smoke:   attempt {index}/{options.attempts} PASS in "
                    f"{attempt.duration:.1f}s, {attempt.checks_passed} checks, "
                    f"{len(attempt.stages)} stages"
                )
                continue
            failures += 1
            print(f"app-launch-smoke:   attempt {index}/{options.attempts} FAIL", file=sys.stderr)
            for problem in attempt.problems:
                print(f"error: app-launch-smoke: {scheme.name}: {problem}", file=sys.stderr)
            if not options.keep_going:
                print(
                    "app-launch-smoke: stopping at the first failed launch "
                    "(pass --keep-going to run the rest anyway)",
                    file=sys.stderr,
                )
                return summarise(
                    run_directory, executed_attempts, executed_checks, failures,
                    executed_attempts, len(checks_expected), profile_before, intruders,
                )

    return summarise(
        run_directory, executed_attempts, executed_checks, failures,
        len(schemes) * options.attempts, len(checks_expected), profile_before, intruders,
    )


def summarise(
    run_directory: str,
    executed_attempts: int,
    executed_checks: int,
    failures: int,
    expected_attempts: int,
    checks_per_attempt: int,
    profile_before: dict | None,
    intruders: list,
) -> int:
    problems = []
    if executed_attempts != expected_attempts:
        problems.append(
            f"{executed_attempts} of {expected_attempts} launches were attempted; the rest never "
            "ran, so this run has no verdict on them."
        )
    expected_checks = expected_attempts * checks_per_attempt
    if failures == 0 and executed_checks != expected_checks:
        problems.append(
            f"{executed_checks} checks passed but {expected_checks} were expected "
            f"({expected_attempts} launches x {checks_per_attempt} checks). A launch reported "
            "fewer checks than the app declares."
        )

    if profile_before is not None:
        changes = profile_difference(profile_before, profile_snapshot())
        if changes:
            problems.append(
                f"the real profile at {PRODUCTION_PROFILE} changed during this run: "
                f"{'; '.join(changes)}. No other Orbit was running, so these launches wrote them — "
                "a smoke run must never touch the profile the user browses with."
            )

    print()
    if failures or problems:
        for problem in problems:
            print(f"error: app-launch-smoke: {problem}", file=sys.stderr)
        print(
            f"app-launch-smoke: FAILED — {failures} of {executed_attempts} launch(es) failed. "
            f"Logs, captures and results: {run_directory}",
            file=sys.stderr,
        )
        return 1

    verdict = (
        f"app-launch-smoke: every launch green — {executed_attempts} real app launches, "
        f"{executed_checks} checks executed and passed"
    )
    if intruders:
        verdict += ", with the production-profile check skipped (another Orbit was running)"
    else:
        verdict += f", and {PRODUCTION_PROFILE} untouched"
    print(verdict)
    print(f"app-launch-smoke: results in {run_directory}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="app-launch-smoke", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command")

    declared = subparsers.add_parser("declared", help="the stages and checks the sources declare")
    declared.set_defaults(handler=command_declared)

    run = subparsers.add_parser("run", help="build the app bundles and launch them for real")
    run.add_argument("--scheme", dest="schemes", action="append", choices=sorted(SCHEMES),
                     help="repeatable; both schemes by default")
    run.add_argument("--attempts", type=int, default=5,
                     help="launches per scheme (default 5: the launch crash this exists for is "
                          "intermittent, so one launch proves nothing)")
    run.add_argument("--derived-data", default=os.path.join(REPO_ROOT, "DerivedData"))
    run.add_argument("--destination", default="platform=macOS,arch=arm64")
    run.add_argument("--results-dir")
    run.add_argument("--skip-build", action="store_true")
    run.add_argument("--url", help="load this instead of the local marker page; the paint checks "
                                   "then only rule out a blank frame, they cannot assert which page")
    run.add_argument("--attempt-timeout", type=float, default=240.0)
    run.add_argument("--shutdown-timeout", type=float, default=60.0)
    run.add_argument("--crash-report-grace", type=float, default=6.0)
    run.add_argument("--allow-running-orbit", action="store_true")
    run.add_argument("--keep-going", action="store_true",
                     help="run every remaining launch after a failure instead of stopping")
    run.add_argument("build_arguments", nargs="*", default=[],
                     help="extra arguments for xcodebuild, after --")
    run.set_defaults(handler=command_run)
    return parser


def main(argv: list[str]) -> int:
    # Otherwise a failure printed to stderr lands before the progress lines that
    # explain it whenever this is piped, which is every CI log.
    sys.stdout.reconfigure(line_buffering=True)
    if not argv or argv[0].startswith("-"):
        argv = ["run"] + argv
    options = build_parser().parse_args(argv)
    if not getattr(options, "handler", None):
        build_parser().print_help()
        return 2
    if options.handler is command_run:
        options.schemes = options.schemes or list(SCHEMES)
        options.derived_data = os.path.abspath(options.derived_data)
        if shutil.which("xcodebuild") is None and not options.skip_build:
            print("error: app-launch-smoke: xcodebuild is not on PATH.", file=sys.stderr)
            return 2
    try:
        return options.handler(options)
    except SmokeError as error:
        print(f"error: app-launch-smoke: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
