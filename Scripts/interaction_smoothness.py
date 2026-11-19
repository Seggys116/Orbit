#!/usr/bin/env python3
"""Frame timing and real window pixels for the interactions that have to feel instant.

Launches a built Orbit.app on a scratch profile through LaunchServices, so it is a real foreground app with a key
window, opens six pages of known solid colours from a local server, and drives each scenario through
Orbit/Core/AppInteractionProbe.swift. Every scenario runs twice: a timing pass (frame gaps only) and a pixel pass
(the pane's composited pixels on each frame, which slows the frames and so says nothing about timing).
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import app_launch_smoke as smoke  # noqa: E402

REPO_ROOT = smoke.REPO_ROOT

COLOURS = [(31, 157, 85), (43, 108, 176), (192, 86, 33), (128, 62, 160), (190, 160, 30), (20, 130, 140)]

SCENARIOS = [
    ("idle", "Idle (noise floor, no action)"),
    ("warmSwitch", "Switch tab (page kept warm)"),
    ("focusPane", "Move focus between panes"),
    ("enterSplitLoaded", "Enter split (two loaded pages)"),
    ("enterSplitBlank", "Enter split (blank pane)"),
    ("enterSplitKeyboard", "Enter split (keyboard)"),
    ("leaveSplitClose", "Leave split (close one pane)"),
    ("leaveSplitSeparate", "Leave split (separate tabs)"),
    ("closeTab", "Close the active tab"),
]


class Fail(Exception):
    pass


def hexed(colour):
    return "#%02x%02x%02x" % colour


def page_html(index):
    colour = hexed(COLOURS[index])
    rows = "".join(f"<p>Row {n}: the quick brown fox jumps over the lazy dog.</p>" for n in range(1500))
    return (
        f"<!doctype html><html><head><title>page {index}</title>"
        f'<meta name="theme-color" content="{colour}">'
        f"<style>html,body{{margin:0;background:{colour};color:{colour}}}p{{margin:0;padding:2px 12px}}</style>"
        f"</head><body>{rows}</body></html>"
    ).encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        index = int(self.path.strip("/").split("?")[0] or 0) if self.path.strip("/").split("?")[0].isdigit() else 0
        body = page_html(index % len(COLOURS))
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Launch:
    def __init__(self, app_path, directory, timeout):
        self.app_path = app_path
        self.directory = directory
        self.timeout = timeout
        self.pid = None
        self.sequence = 0
        self.executable = os.path.join(app_path, "Contents", "MacOS", "Orbit")

    def start(self):
        os.makedirs(self.directory, exist_ok=True)
        stdout_path = os.path.join(self.directory, "stdout.log")
        stderr_path = os.path.join(self.directory, "stderr.log")
        for path in (stdout_path, stderr_path):
            open(path, "w").close()
        spare = smoke.pids_running(self.executable)
        environment = {
            "ORBIT_SMOKE_PROBE": "1",
            "ORBIT_SMOKE_PROBE_BENCH": "1",
            "ORBIT_SMOKE_PROBE_OUT": self.directory,
            "ORBIT_SMOKE_PROBE_LABEL": "interaction-smoothness",
            "ORBIT_SMOKE_PROBE_ATTEMPT": "1",
        }
        command = ["/usr/bin/open", "-n", "-a", self.app_path, "--stdout", stdout_path, "--stderr", stderr_path]
        for key, value in environment.items():
            command += ["--env", f"{key}={value}"]
        command += ["--args", "-OrbitConfirmBeforeQuit", "NO", "-SUEnableAutomaticChecks", "NO"]
        subprocess.run(command, check=True, capture_output=True)
        deadline = time.monotonic() + self.timeout
        while self.pid is None:
            appeared = smoke.pids_running(self.executable) - spare
            if len(appeared) == 1:
                self.pid = appeared.pop()
            elif time.monotonic() > deadline:
                raise Fail("Orbit never appeared as a process")
            else:
                time.sleep(0.05)
        ready = os.path.join(self.directory, "bench-ready.json")
        while not os.path.exists(ready):
            if not smoke.is_alive(self.pid):
                raise Fail("Orbit exited before it was ready")
            if time.monotonic() > deadline:
                raise Fail("Orbit was not ready in time")
            time.sleep(0.05)
        with open(ready) as handle:
            info = json.load(handle)
        if "interact" not in info.get("commands", []):
            raise Fail("this build has no `interact` probe command; rebuild without --skip-build")
        data_root = os.path.realpath(str(info.get("dataRoot", "")))
        if not data_root or data_root.startswith(os.path.realpath(smoke.PRODUCTION_PROFILE)):
            raise Fail("the app's data root is the real profile; refusing to run against it")
        self.spare = spare

    def command(self, name, timeout=120.0, **fields):
        self.sequence += 1
        sequence = self.sequence
        payload = dict(fields, command=name)
        final = os.path.join(self.directory, f"bench-command-{sequence}.json")
        with open(final + ".tmp", "w") as handle:
            json.dump(payload, handle)
        os.replace(final + ".tmp", final)
        response_path = os.path.join(self.directory, f"bench-response-{sequence}.json")
        deadline = time.monotonic() + timeout
        while not os.path.exists(response_path):
            if not smoke.is_alive(self.pid):
                raise Fail(f"Orbit exited while handling {name}")
            if time.monotonic() > deadline:
                raise Fail(f"Orbit did not answer {name} within {timeout}s")
            time.sleep(0.01)
        with open(response_path) as handle:
            response = json.load(handle)
        if not response.get("ok"):
            raise Fail(f"Orbit refused {name}: {response.get('error')}")
        return response

    def stop(self):
        if self.pid is not None and smoke.is_alive(self.pid):
            try:
                self.command("quit", timeout=10.0)
            except Fail:
                pass
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and smoke.is_alive(self.pid):
                time.sleep(0.1)
        killed = smoke.kill_tree(self.pid, self.app_path, getattr(self, "spare", set()))
        if killed:
            print(f"interaction-smoothness: killed leftover process(es) {killed}")


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def build(options):
    log = os.path.join(options.output, "build.log")
    command = [
        "xcodebuild", "build", "-project", os.path.join(REPO_ROOT, "Orbit.xcodeproj"), "-scheme", "Orbit",
        "-configuration", options.configuration, "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", options.derived_data, "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
    ]
    print(f"interaction-smoothness: building {options.configuration} (log: {log})")
    with open(log, "w") as handle:
        completed = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT, cwd=REPO_ROOT)
    if completed.returncode != 0:
        raise Fail(f"build failed with status {completed.returncode}; see {log}")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--derived-data", default=os.path.join(REPO_ROOT, "DerivedData-agent"))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--scenarios", default=",".join(name for name, _ in SCENARIOS))
    parser.add_argument("--iterations", type=int, default=12)
    parser.add_argument("--pixel-iterations", type=int, default=4)
    parser.add_argument("--settle", type=float, default=25.0, help="seconds to let launch-time work (content blocker compile) finish")
    parser.add_argument("--output", default=os.path.join(REPO_ROOT, "DerivedData-agent", "interaction-smoothness"))
    parser.add_argument("--launch-timeout", type=float, default=90.0)
    parser.add_argument("--sample", default="", help="scenario to sample the app's main thread during, with /usr/bin/sample")
    options = parser.parse_args(argv)

    if subprocess.run(["/bin/launchctl", "managername"], capture_output=True, text=True).stdout.strip() != "Aqua":
        raise Fail("not in a logged-in desktop (Aqua) session; Orbit needs a real window-server session")
    os.makedirs(options.output, exist_ok=True)
    if not options.skip_build:
        build(options)
    app_path = os.path.join(options.derived_data, "Build", "Products", options.configuration, "Orbit.app")
    if not os.path.isdir(app_path):
        raise Fail(f"{app_path} does not exist; build first")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"

    wanted = [name for name in options.scenarios.split(",") if name]
    labels = dict(SCENARIOS)
    launch = Launch(app_path, os.path.join(options.output, f"run-{int(time.time())}"), options.launch_timeout)
    results = {}
    try:
        launch.start()
        launch.command("openTabs", urls=[f"{base}/{index}" for index in range(len(COLOURS))])
        print(f"interaction-smoothness: pages open, letting launch-time work finish ({options.settle:.0f}s)")
        time.sleep(options.settle)
        colours = [list(colour) for colour in COLOURS]
        for name in wanted:
            sampler = None
            if name == options.sample:
                sample_path = os.path.join(options.output, f"sample-{name}.txt")
                sampler = subprocess.Popen(["/usr/bin/sample", str(launch.pid), str(int(options.iterations * 2.2) + 2), "1", "-file", sample_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(1.0)
            timing = launch.command("interact", scenario=name, iterations=options.iterations, pixels=False, colours=colours)
            if sampler is not None:
                sampler.wait()
            pixels = launch.command("interact", scenario=name, iterations=options.pixel_iterations, pixels=True, colours=colours)
            results[name] = {"timing": timing, "pixels": pixels}
    finally:
        launch.stop()
        server.shutdown()

    first = next(iter(results.values()))["timing"]
    print()
    print(
        f"{options.configuration} build, {first['refreshHz']}Hz display, key window: {first['keyWindow']}, "
        f"app active: {first['appActive']}"
    )
    header = f"{'interaction':36} {'action':>7} {'gap median':>10} {'p90':>7} {'worst':>7} {'hitches/run':>11} {'cpu burst':>10} {'bad frames*':>12}"
    print(header)
    print("-" * len(header))
    for name in wanted:
        timing = results[name]["timing"]["iterations"]
        pixel = results[name]["pixels"]["iterations"]
        gaps = [run["longestGapMs"] for run in timing]
        hitches = statistics.mean(run["hitches"] for run in timing)
        action = statistics.median(run["actionMs"] for run in timing)
        bursts = [run.get("longestCpuBurstMs", 0.0) for run in timing]
        state_bad = sum(len([t for t in run["defectTimesMs"] if t > 50]) for run in timing)
        pixel_bad = sum(len([t for t in run["defectTimesMs"] if t > 50]) for run in pixel)
        pixel_frames = sum(run["frames"] for run in pixel)
        print(
            f"{labels.get(name, name):36} {action:6.1f}ms {statistics.median(gaps):9.1f}ms "
            f"{percentile(gaps, 0.9):6.1f}ms {max(gaps):6.1f}ms {hitches:11.1f} {statistics.median(bursts):8.1f}ms "
            f"{state_bad + pixel_bad:>5} of {pixel_frames:<4}"
        )
    print("cpu burst = the most main-thread CPU time spent between two frames, median over runs. Above one frame it drops frames on any machine; a busy machine only stretches the gap, not this.")
    print("* frames more than 50ms after the action where the pane was not the page's colour (the first frame is the previous picture still on screen).")
    path = os.path.join(options.output, f"results-{options.configuration}-{int(time.time())}.json")
    with open(path, "w") as handle:
        json.dump({"configuration": options.configuration, "results": results}, handle, indent=1)
    print(f"\nraw results: {path}")
    for name in wanted:
        for run in results[name]["pixels"]["iterations"] + results[name]["timing"]["iterations"]:
            if run["firstDefect"] and any(t > 50 for t in run["defectTimesMs"]):
                print(f"first defect in {name}: {run['firstDefect']}")
                break
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as error:
        print(f"interaction-smoothness: {error}", file=sys.stderr)
        sys.exit(1)
