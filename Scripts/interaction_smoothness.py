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
    ("openTab", "Open a tab"),
    ("openTabBackground", "Open a tab, not activated"),
    ("openBlankTab", "Open a blank new tab"),
    ("activateFreshTab", "Show a tab never shown"),
    ("activateRightAway", "Make a tab and show it at once"),
    ("activateAfterBriefWait", "Show a tab 120ms after making it"),
    ("rapidSwitch", "Switch eight tabs 25ms apart"),
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


def site_html(site, name):
    """A page of a small site: its own colour, links to its other pages and the other sites, enough text to scroll
    and lay out, and a script that talks to the server, so loading it exercises more than a static document."""
    colour = hexed(COLOURS[site % len(COLOURS)])
    links = "".join(f'<a href="/site/{site}/{other}">{other}</a> ' for other in ("a", "b", "c", "slow"))
    links += "".join(f'<a href="/site/{other}/a">site {other}</a> ' for other in range(len(COLOURS)))
    rows = "".join(f"<p>Row {n} of {name}: the quick brown fox jumps over the lazy dog.</p>" for n in range(600))
    script = (
        "fetch('/api/ping?site=%d&page=%s').then(r=>r.json()).then(j=>{document.title+=' ok'});"
        "setInterval(()=>{fetch('/api/ping').catch(()=>{})},1500);" % (site, name)
    )
    return (
        f"<!doctype html><html><head><title>site {site} {name}</title>"
        f'<meta name="theme-color" content="{colour}">'
        f"<style>html,body{{margin:0;background:{colour};color:#fff}}p,nav{{margin:0;padding:4px 14px}}a{{color:#fff;margin-right:8px}}</style>"
        f"</head><body><nav>{links}</nav>{rows}<script>{script}</script></body></html>"
    ).encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/ping":
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith("/site/"):
            parts = path.strip("/").split("/")
            site = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            name = parts[2] if len(parts) > 2 else "a"
            if name == "slow":
                time.sleep(1.5)
            body = site_html(site, name)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        index = int(self.path.strip("/").split("?")[0] or 0) if self.path.strip("/").split("?")[0].isdigit() else 0
        body = page_html(index % len(COLOURS))
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


DISPLAY_NAME = "Orbit Probe Display"


class VirtualDisplay:
    """A display that exists only for the run, so the app's window never opens on a real screen."""

    def __init__(self, output):
        self.output = output
        self.process = None

    def start(self):
        binary = os.path.join(self.output, "virtual-display")
        source = os.path.join(SCRIPT_DIR, "virtual_display.m")
        compiled = subprocess.run(
            ["/usr/bin/clang", "-fobjc-arc", "-framework", "Cocoa", source, "-o", binary], capture_output=True, text=True
        )
        if compiled.returncode != 0:
            raise Fail(f"could not build the virtual display helper: {compiled.stderr.strip()}")
        self.process = subprocess.Popen([binary, DISPLAY_NAME], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            line = self.process.stdout.readline()
            if line.startswith("ready"):
                time.sleep(1.0)
                return
            if self.process.poll() is not None:
                raise Fail(f"the virtual display helper exited: {self.process.stderr.read().strip()}")
        raise Fail("the virtual display never became ready")

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()


class Launch:
    def __init__(self, app_path, directory, timeout, screen=None):
        self.screen = screen
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
        if self.screen:
            environment["ORBIT_SMOKE_PROBE_SCREEN"] = self.screen
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
    parser.add_argument("--fullscreen", action="store_true", help="enter real element fullscreen and report what the page and its window show")
    parser.add_argument("--fullscreen-url", default="", help="page to load before entering fullscreen; its player element is made fullscreen")
    parser.add_argument("--fullscreen-variants", default="plain", help="comma list of: plain, split, splitSecond, pinned, inspector")
    parser.add_argument("--journey", action="store_true", help="run seeded random journeys through tabs, pins and splits and report what broke")
    parser.add_argument("--seeds", default="1,2,3", help="comma list of journey seeds")
    parser.add_argument("--steps", type=int, default=60, help="steps per journey")
    parser.add_argument("--virtual-display", action="store_true", help="open the window on a virtual display instead of a real screen (moves the display arrangement while it exists)")
    parser.add_argument("--drop-target", action="store_true", help="check that a sidebar drag over the page lands on the split drop target when the app reports mouseMoved (events are posted inside the app; no cursor is used)")
    parser.add_argument("--file-drop", action="store_true", help="check that a file dragged in from another app is offered to the page itself and not to a view that would turn it away (events are posted inside the app; no cursor is used)")
    parser.add_argument("--sites", default="", help="comma list of real page addresses (at least three) opened instead of the local colour pages; timing only, since their pixels are not known colours")
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
    display = VirtualDisplay(options.output) if options.virtual_display else None
    launch = Launch(
        app_path, os.path.join(options.output, f"run-{int(time.time())}"), options.launch_timeout,
        screen=None if display is None else DISPLAY_NAME,
    )
    results = {}
    try:
        if display is not None:
            display.start()
        launch.start()
        sites = [value for value in options.sites.split(",") if value]
        if sites and len(sites) < 3:
            raise Fail("--sites needs at least three addresses")
        launch.command("openTabs", urls=sites or [f"{base}/{index}" for index in range(len(COLOURS))])
        print(f"interaction-smoothness: pages open, letting launch-time work finish ({options.settle:.0f}s)")
        time.sleep(options.settle)
        colours = [list(colour) for colour in (COLOURS if not sites else [(0, 0, 0)] * len(sites))]
        if options.journey:
            failed = 0
            for seed in [int(value) for value in options.seeds.split(",") if value]:
                report = launch.command("interact", scenario="journey", base=base, seed=seed, steps=options.steps, dumpDir=os.path.join(options.output, "frames-journey"), timeout=1800.0)
                path = os.path.join(options.output, f"journey-{seed}.json")
                with open(path, "w") as handle:
                    json.dump(report, handle, indent=1)
                found = report["violations"]
                delays = [d["ms"] for d in report["paintDelays"]]
                print(f"seed {seed}: {len(found)} violation(s), {len(report['stalls'])} stall(s) over 250 ms, paint delays {sorted(delays)[-5:]} ms, key window {report['keyWindow']}  ({path})")
                seen = {}
                for item in found:
                    key = item["problem"]
                    if key not in seen:
                        seen[key] = [item, 0]
                    seen[key][1] += 1
                for item, count in list(seen.values())[:15]:
                    print(f"   first at step {item['step']} [{item['action']}] x{count}: {item['problem']}")
                for item in report["stalls"][:6]:
                    print(f"   stall {item['ms']} ms at step {item['step']} [{item['action']}] (the call itself took {item.get('actionMs', '?')} ms)")
                failed += len(found)
            return 1 if failed else 0
        if options.drop_target:
            # the app's tear-off timer ends a drag record it sees no button held for, so an attempt only counts while the drag was still in flight
            counted = failed = 0
            for _ in range(12):
                seen = launch.command("interact", scenario="dropTargetEvent")["seen"]
                print(f"drop target: hit {seen.get('hit')}, current event {seen.get('currentEvent')}, drag in flight {seen.get('inFlight')}")
                if not seen.get("inFlight"):
                    continue
                counted += 1
                if seen.get("hit") != "SplitPaneDropCatcherView":
                    failed += 1
                if counted == 3:
                    break
            if counted == 0:
                raise Fail("no attempt saw the drag still in flight")
            return 1 if failed else 0
        if options.file_drop:
            seen = launch.command("interact", scenario="dropTargetEvent", drag="file")["seen"]
            print(f"file drop: hit {seen.get('hit')}, offered to {seen.get('destination')}, current event {seen.get('currentEvent')}")
            print(f"   chain {' > '.join(seen.get('chain', []))}")
            print(f"   pasteboard types {seen.get('types')}")
            return 0 if seen.get("destination") == "OrbitWebView" else 1
        if options.fullscreen:
            extra = {}
            if options.fullscreen_url:
                extra = {"fullscreenURL": options.fullscreen_url, "fullscreenScript": "(function(){var p=document.getElementById('movie_player')||document.querySelector('video');var v=document.querySelector('video');if(v){v.muted=true;v.play();}p.requestFullscreen().catch(function(){});return 1})()"}
            for variant in options.fullscreen_variants.split(","):
                report = launch.command("interact", scenario="elementFullscreen", iterations=2, colours=colours, variant=variant, dumpDir=os.path.join(options.output, f"frames-{variant}"), timeout=600.0, **extra)
                print(f"--- variant {variant}")
                for run in report["runs"]:
                    painted = [s.get("fullscreenWindowOrange", -1) for s in run["samples"]]
                    sizes = sorted({s["viewFrame"] for s in run["samples"]})
                    strays = sorted({w for s in run["samples"] for w in s.get("strayWindows", [])})
                    for w in strays:
                        print(f"   other window: {w}")
                    print(f"entered={run['entered']} orange(last)={painted[-1]:.2f} frames={sizes} returned={run['after']['returnedToPane']} paneAfter={run['after']['viewFrame']}")
            return 0
        for name in wanted:
            sampler = None
            if name == options.sample:
                sample_path = os.path.join(options.output, f"sample-{name}.txt")
                sampler = subprocess.Popen(["/usr/bin/sample", str(launch.pid), str(int(options.iterations * 2.2) + 2), "1", "-file", sample_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(1.0)
            timing = launch.command("interact", scenario=name, iterations=options.iterations, pixels=False, colours=colours)
            if sampler is not None:
                sampler.wait()
            pixels = {"iterations": []} if sites else launch.command("interact", scenario=name, iterations=options.pixel_iterations, pixels=True, colours=colours, dumpDir=os.path.join(options.output, "frames"))
            results[name] = {"timing": timing, "pixels": pixels}
    finally:
        launch.stop()
        if display is not None:
            display.stop()
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
