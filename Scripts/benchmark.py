#!/usr/bin/env python3
"""Performance and memory benchmarks for Orbit, plus passive sampling of other browsers.

  run              Launch a built Orbit.app (never any other browser) with a scratch profile and
                   measure cold/warm launch to first paint, new-tab-to-paint, idle CPU, memory
                   footprint at 1/5/10/20 tabs, per-tab marginal memory, memory after closing every
                   tab, and memory growth over a few idle minutes.
  measure-running  Sample memory footprint and CPU of a browser the user already started. It only
                   reads the process table and per-process counters; it never starts, signals or
                   changes the browser.
  compare          Markdown table of two or more result files, refusing files from different
                   schema or methodology versions and flagging metrics that are not comparable.
  serve            Serve the benchmark pages on 127.0.0.1 so another browser can be pointed at
                   exactly the pages Orbit was measured on.

Orbit is driven through Orbit/Core/AppSmokeProbe.swift (ORBIT_SMOKE_PROBE=1 plus
ORBIT_SMOKE_PROBE_BENCH=1), which redirects every data path off the real profile. The pages report
their own first painted frame to this script over loopback, so the same pages and the same timing
source work for any browser. Methodology and limits: refs/PERFORMANCE.md.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import datetime
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import app_launch_smoke as smoke  # noqa: E402

REPO_ROOT = smoke.REPO_ROOT

SCHEMA_VERSION = 1
METHODOLOGY_VERSION = "1"
RESULT_KINDS = ("run", "measure-running")
KNOWN_UNITS = ("ms", "bytes", "percent", "bytes_per_minute")
ALL_METRIC_GROUPS = ("launch", "tabs", "cpu", "memory", "growth")
PAGE_KINDS = ("light", "medium", "heavy")

BENCH_MARKER = "ORBIT-BENCH: COMMANDS"
USED_COMMANDS = ("openTabs", "closeOpenedTabs", "status", "quit")

MEDIUM_ROWS = 4000
HEAVY_RECORDS = 60000
HEAVY_BUFFER_LENGTH = 524288

IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9_.-]{1,64}")

PROBE_ROLES = {
    "browser": "browser",
    "webContent": "webcontent",
    "extensionProcess": "extension",
    "networking": "networking",
    "gpu": "gpu",
    "helper": "helper",
    "other": "other",
}


class BenchmarkError(Exception):
    pass


# MARK: - Statistics


def percentile(values, fraction):
    """Linear interpolation between the two closest ranks (NumPy's default method)."""
    if not values:
        raise BenchmarkError("a percentile of zero samples is undefined")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    weight = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * weight


def median(values):
    return percentile(values, 0.5)


def p90(values):
    return percentile(values, 0.9)


def summarize(values):
    if not values:
        return {"n": 0, "min": None, "median": None, "p90": None, "max": None, "mean": None}
    floats = [float(value) for value in values]
    return {
        "n": len(floats),
        "min": min(floats),
        "median": median(floats),
        "p90": p90(floats),
        "max": max(floats),
        "mean": sum(floats) / len(floats),
    }


def linear_slope(points):
    """Least-squares slope of y against x."""
    if len(points) < 2:
        raise BenchmarkError("a slope needs at least two points")
    xs = [float(x) for x, _ in points]
    ys = [float(y) for _, y in points]
    mean_x = sum(xs) / len(xs)
    mean_y = sum(ys) / len(ys)
    denominator = sum((x - mean_x) ** 2 for x in xs)
    if denominator == 0:
        raise BenchmarkError("a slope needs at least two distinct x values")
    return sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / denominator


def cpu_percent(before, after, wall_seconds):
    """CPU use over a window; 100 means one core fully busy. Inputs map pid to cumulative CPU seconds."""
    if wall_seconds <= 0:
        raise BenchmarkError("a CPU window needs a positive duration")
    total = 0.0
    for pid, finished in after.items():
        started = before.get(pid, 0.0)
        if finished < started:
            continue
        total += finished - started
    return {
        "percent": total / wall_seconds * 100.0,
        "cpu_seconds": total,
        "wall_seconds": wall_seconds,
        "processes_at_start": len(before),
        "processes_at_end": len(after),
        "vanished": len(set(before) - set(after)),
        "appeared": len(set(after) - set(before)),
    }


def crosscheck_ratio(external, in_app):
    shared = set(external) & set(in_app)
    denominator = sum(in_app[pid] for pid in shared)
    if not shared or denominator == 0:
        return None
    return sum(external[pid] for pid in shared) / denominator


# MARK: - Metric naming


def memory_metric_id(page, tabs):
    return f"memory.{page}.tabs_{tabs}"


def cpu_metric_id(page, tabs):
    return f"cpu_idle.{page}.tabs_{tabs}"


def observation_metrics(page, tabs, series, cpu_percents, interval):
    """Metrics for a window of repeated readings; shared by `run` (growth launch) and `measure-running`.

    series: [{"t": seconds since the first reading, "bytes": total footprint}]
    """
    out = []
    memory_conditions = {"page": page, "tabs": tabs}
    for point in series:
        out.append((memory_metric_id(page, tabs), point["bytes"], "bytes", dict(memory_conditions)))
    for value in cpu_percents:
        out.append((
            cpu_metric_id(page, tabs), value, "percent",
            {"page": page, "tabs": tabs, "window_s": interval},
        ))
    if len(series) >= 2:
        conditions = {
            "page": page,
            "tabs": tabs,
            "duration_s": int(round((len(series) - 1) * interval)),
            "interval_s": interval,
        }
        out.append((
            f"memory_growth.{page}.tabs_{tabs}",
            series[-1]["bytes"] - series[0]["bytes"], "bytes", dict(conditions),
        ))
        out.append((
            f"memory_growth_rate.{page}.tabs_{tabs}",
            linear_slope([(point["t"] / 60.0, point["bytes"]) for point in series]),
            "bytes_per_minute", dict(conditions),
        ))
    return out


class Recorder:
    def __init__(self):
        self.samples = {}
        self.specs = {}

    def add(self, metric_id, value, unit, conditions):
        if unit not in KNOWN_UNITS:
            raise BenchmarkError(f"metric {metric_id} uses unknown unit {unit!r}")
        spec = {"unit": unit, "conditions": conditions}
        existing = self.specs.setdefault(metric_id, spec)
        if existing != spec:
            raise BenchmarkError(
                f"metric {metric_id} was recorded under two different definitions within one "
                f"attempt: {existing} and {spec}"
            )
        self.samples.setdefault(metric_id, []).append(float(value))

    def add_all(self, entries):
        for metric_id, value, unit, conditions in entries:
            self.add(metric_id, value, unit, conditions)


def aggregate_attempts(attempts):
    specs = {}
    samples = {}
    for attempt in attempts:
        for metric_id, spec in attempt["specs"].items():
            existing = specs.setdefault(metric_id, spec)
            if existing != spec:
                raise BenchmarkError(
                    f"metric {metric_id} changed definition between attempts: {existing} vs {spec}"
                )
        for metric_id, values in attempt["samples"].items():
            samples.setdefault(metric_id, []).extend(values)
    metrics = {}
    for metric_id in sorted(samples):
        values = samples[metric_id]
        metrics[metric_id] = {
            "unit": specs[metric_id]["unit"],
            "conditions": specs[metric_id]["conditions"],
            "samples": values,
            "summary": summarize(values),
        }
    return metrics


# MARK: - Result documents


def validate_document(document):
    problems = []
    if not isinstance(document, dict):
        return ["the top level is not a JSON object"]
    required = (
        "schema", "kind", "methodology_version", "label", "created",
        "machine", "target", "parameters", "methods", "metrics",
    )
    for key in required:
        if key not in document:
            problems.append(f"missing '{key}'")
    if problems:
        return problems
    if document["schema"] != SCHEMA_VERSION:
        problems.append(
            f"schema is {document['schema']!r}; this tool reads schema {SCHEMA_VERSION} only"
        )
    if document["kind"] not in RESULT_KINDS:
        problems.append(f"kind is {document['kind']!r}, not one of {', '.join(RESULT_KINDS)}")
    if not isinstance(document["methodology_version"], str):
        problems.append("methodology_version is not a string")
    machine = document["machine"]
    if not isinstance(machine, dict):
        problems.append("machine is not an object")
    else:
        for key in ("chip", "macos", "ram_bytes"):
            if key not in machine:
                problems.append(f"machine lacks '{key}'")
    for key in ("target", "parameters", "methods"):
        if not isinstance(document[key], dict):
            problems.append(f"{key} is not an object")
    metrics = document["metrics"]
    if not isinstance(metrics, dict) or not metrics:
        problems.append("metrics is empty or not an object")
        return problems
    for metric_id, metric in metrics.items():
        if not isinstance(metric, dict):
            problems.append(f"metric {metric_id} is not an object")
            continue
        if metric.get("unit") not in KNOWN_UNITS:
            problems.append(f"metric {metric_id} has unknown unit {metric.get('unit')!r}")
        if not isinstance(metric.get("conditions"), dict):
            problems.append(f"metric {metric_id} lacks a conditions object")
        samples = metric.get("samples")
        valid_samples = (
            isinstance(samples, list) and samples
            and all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in samples)
        )
        if not valid_samples:
            problems.append(f"metric {metric_id} has no numeric samples")
            continue
        summary = metric.get("summary")
        if not isinstance(summary, dict) or summary.get("n") != len(samples):
            problems.append(f"metric {metric_id} summary does not describe its {len(samples)} samples")
    return problems


def require_valid(document, source):
    problems = validate_document(document)
    if problems:
        raise BenchmarkError(
            f"{source} is not a usable result file: " + "; ".join(problems)
        )


def load_document(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except OSError as error:
        raise BenchmarkError(f"cannot read {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise BenchmarkError(f"{path} is not valid JSON: {error}") from error
    require_valid(document, path)
    return document


def write_document(document, path):
    require_valid(document, "the result about to be written")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def check_versions(documents, names):
    reference = documents[0]
    for document, name in zip(documents[1:], names[1:]):
        for key in ("schema", "methodology_version"):
            if document[key] != reference[key]:
                raise BenchmarkError(
                    f"{name} has {key} {document[key]!r} but {names[0]} has {reference[key]!r}. "
                    f"Results from different {key}s measure different things, so they are not compared."
                )


def format_value(unit, value):
    if value is None:
        return "-"
    if unit == "ms":
        return f"{value:,.1f} ms"
    if unit == "bytes":
        return f"{value / 1048576:,.1f} MiB"
    if unit == "bytes_per_minute":
        return f"{value / 1048576:,.2f} MiB/min"
    if unit == "percent":
        return f"{value:,.2f} %"
    return f"{value:g} {unit}"


def describe_condition_difference(first, second):
    parts = []
    for key in sorted(set(first) | set(second)):
        if first.get(key) != second.get(key):
            parts.append(f"{key} {first.get(key)!r} vs {second.get(key)!r}")
    return ", ".join(parts)


def incomparable_reason(metric_id, entries, documents):
    """entries: [(document index, metric)]. None when every entry measured the same thing the same way."""
    first = entries[0][1]
    for _, metric in entries[1:]:
        if metric["unit"] != first["unit"]:
            return f"units differ ({first['unit']} vs {metric['unit']})"
        if metric["conditions"] != first["conditions"]:
            return "conditions differ: " + describe_condition_difference(first["conditions"], metric["conditions"])
    if metric_id.startswith(("memory", "cpu")):
        key = "memory_source" if metric_id.startswith("memory") else "cpu_source"
        sources = {documents[index]["methods"].get(key) for index, _ in entries}
        if len(sources) > 1:
            return f"{key} differs ({', '.join(sorted(str(source) for source in sources))})"
    return None


def compare_documents(documents, names):
    check_versions(documents, names)
    letters = [chr(ord("A") + index) for index in range(len(documents))]
    lines = ["# Benchmark comparison", ""]
    for letter, document, name in zip(letters, documents, names):
        machine = document["machine"]
        target = document["target"]
        ram = machine.get("ram_bytes") or 0
        lines.append(
            f"- {letter}: {document['label']} ({document['kind']}, `{os.path.basename(name)}`) - "
            f"{machine.get('chip')}, macOS {machine.get('macos')}, {ram / 1073741824:.0f} GiB; "
            f"target {target.get('name', '')} {target.get('version', '')} {str(target.get('git_commit', ''))[:10]}".rstrip()
        )
    lines.append("")

    metric_ids = sorted({metric_id for document in documents for metric_id in document["metrics"]})
    rows = []
    incomparable = []
    partial = []
    for metric_id in metric_ids:
        present = {
            index: document["metrics"][metric_id]
            for index, document in enumerate(documents) if metric_id in document["metrics"]
        }
        if len(present) < 2:
            partial.append((metric_id, [letters[index] for index in present]))
            continue
        cells = []
        for index in range(len(documents)):
            metric = present.get(index)
            if metric is None:
                cells.append("-")
                continue
            summary = metric["summary"]
            cells.append(
                f"{format_value(metric['unit'], summary['median'])} "
                f"(p90 {format_value(metric['unit'], summary['p90'])}, n={summary['n']})"
            )
        deltas = []
        for index in range(1, len(documents)):
            if 0 not in present or index not in present:
                deltas.append("-")
                continue
            reason = incomparable_reason(metric_id, [(0, present[0]), (index, present[index])], documents)
            if reason is not None:
                deltas.append("not comparable")
                incomparable.append((metric_id, f"{letters[0]} vs {letters[index]}: {reason}"))
                continue
            base = present[0]["summary"]["median"]
            deltas.append(
                "n/a" if not base else f"{(present[index]['summary']['median'] - base) / abs(base) * 100:+.1f}%"
            )
        rows.append((metric_id, cells, deltas))

    header = ["Metric"] + letters + [f"{letter} vs {letters[0]}" for letter in letters[1:]]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for metric_id, cells, deltas in rows:
        lines.append("| " + " | ".join([f"`{metric_id}`"] + cells + deltas) + " |")
    if not rows:
        lines.append("| (no metric appears in two or more files) |" + " |" * (len(header) - 1))
    lines.append("")
    lines.append("Cells are median (p90, sample count). Differences are relative to the median of "
                 f"{letters[0]}; negative means lower than {letters[0]}.")

    if incomparable:
        lines += ["", "## Not comparable", ""]
        for metric_id, reason in incomparable:
            lines.append(f"- `{metric_id}`: {reason}")
    if partial:
        lines += ["", "## Present in only one file", ""]
        for metric_id, where in partial:
            lines.append(f"- `{metric_id}` only in {', '.join(where)}")

    notes = []
    reference_machine = documents[0]["machine"]
    for letter, document in zip(letters[1:], documents[1:]):
        differences = [
            key for key in ("chip", "macos", "ram_bytes")
            if document["machine"].get(key) != reference_machine.get(key)
        ]
        if differences:
            notes.append(f"{letter} was measured on a different {', '.join(differences)} than {letters[0]}.")
    for letter, document in zip(letters, documents):
        for warning in document.get("warnings", []):
            notes.append(f"{letter}: {warning}")
    if notes:
        lines += ["", "## Notes", ""] + [f"- {note}" for note in notes]
    lines += ["", "Any claim built on this table must cite the result files listed above."]
    return "\n".join(lines) + "\n"


# MARK: - Parsing process output


def parse_cputime(text):
    """ps cputime: [days-][hours:]minutes:seconds.centiseconds."""
    original = text
    text = text.strip()
    days = 0
    try:
        if "-" in text:
            day_text, text = text.split("-", 1)
            days = int(day_text)
        parts = text.split(":")
        if len(parts) not in (2, 3):
            raise ValueError("unexpected field count")
        seconds = float(parts[-1])
        minutes = int(parts[-2])
        hours = int(parts[-3]) if len(parts) == 3 else 0
    except ValueError as error:
        raise BenchmarkError(f"cannot read CPU time {original!r} from ps") from error
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def parse_cputime_listing(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            result[int(fields[0])] = parse_cputime(fields[1])
        except ValueError:
            continue
    return result


class ProcessEntry:
    def __init__(self, pid, ppid, path):
        self.pid = pid
        self.ppid = ppid
        self.path = path

    def __repr__(self):
        return f"ProcessEntry({self.pid}, {self.ppid}, {self.path!r})"


def parse_process_table(text):
    entries = []
    for line in text.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        try:
            entries.append(ProcessEntry(int(fields[0]), int(fields[1]), fields[2].strip()))
        except ValueError:
            continue
    return entries


def parse_power_source(text):
    match = re.search(r"Now drawing from '([^']+)'", text)
    if not match:
        return "unknown"
    return "battery" if "battery" in match.group(1).lower() else "ac"


def parse_low_power_mode(text):
    match = re.search(r"lowpowermode\s+(\d)", text)
    if not match:
        return None
    return match.group(1) == "1"


FOOTPRINT_PATTERN = re.compile(r"Footprint:\s*([0-9][0-9.,]*)\s*(KB|MB|GB|B)\b")
FOOTPRINT_UNITS = {"B": 1, "KB": 1024, "MB": 1048576, "GB": 1073741824}


def parse_footprint_output(text):
    match = FOOTPRINT_PATTERN.search(text)
    if not match:
        return None
    return int(float(match.group(1).replace(",", "")) * FOOTPRINT_UNITS[match.group(2)])


# MARK: - Process families


def outermost_bundle(path):
    parts = path.split("/")
    for index, part in enumerate(parts):
        if index > 0 and part.endswith(".app"):
            return "/".join(parts[: index + 1])
    return None


def resolve_bundle(match, table):
    if not match:
        raise BenchmarkError("--process-match is empty")
    if match.startswith("/"):
        trimmed = match.rstrip("/")
        bundle = trimmed if trimmed.endswith(".app") else outermost_bundle(trimmed)
        if bundle is None:
            raise BenchmarkError(f"{match} is not inside an .app bundle; give the browser's .app path")
        if not any(entry.path.startswith(bundle + "/") for entry in table):
            raise BenchmarkError(
                f"no process is running from {bundle}. Start the browser yourself first; this tool never starts one."
            )
        return bundle
    needle = match.lower()
    bundles = sorted({
        bundle for entry in table if needle in entry.path.lower()
        for bundle in [outermost_bundle(entry.path)] if bundle
    })
    if not bundles:
        raise BenchmarkError(
            f"no running process inside an .app bundle has {match!r} in its executable path. "
            "Start the browser yourself first, or pass its .app path."
        )
    if len(bundles) > 1:
        raise BenchmarkError(
            f"{match!r} matches several app bundles: {', '.join(bundles)}. Pass the full .app path of the one to measure."
        )
    return bundles[0]


def discover_family(table, bundle, responsible=None):
    """pid -> how it was attributed: bundle path prefix, child of a member, or responsible process."""
    prefix = bundle + "/"
    family = {entry.pid: "bundle" for entry in table if entry.path.startswith(prefix)}
    if not family:
        return {}
    children = {}
    for entry in table:
        children.setdefault(entry.ppid, []).append(entry.pid)
    stack = list(family)
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            if child not in family:
                family[child] = "child"
                stack.append(child)
    if responsible is not None:
        owners = {}
        for entry in table:
            if entry.pid not in family:
                owners[entry.pid] = responsible(entry.pid)
        changed = True
        while changed:
            changed = False
            for pid, owner in owners.items():
                if pid not in family and owner is not None and owner != pid and owner in family:
                    family[pid] = "responsible"
                    changed = True
    return family


def role_of(path, bundle):
    lowered = path.lower()
    if "webkit.webcontent" in lowered:
        return "webcontent"
    if "webkit.networking" in lowered:
        return "networking"
    if "webkit.gpu" in lowered:
        return "gpu"
    if not path.startswith(bundle + "/"):
        return "other"
    parts = path[len(bundle) + 1:].split("/")
    if len(parts) == 3 and parts[0] == "Contents" and parts[1] == "MacOS":
        return "browser"
    if "(renderer)" in lowered:
        return "renderer"
    if "(gpu)" in lowered:
        return "gpu"
    if "helper" in lowered or "plugin-container" in lowered:
        return "helper"
    return "other"


def detect_engine(entries):
    joined = "\n".join(entry.path.lower() for entry in entries)
    if "helper (renderer)" in joined or "chromium embedded" in joined or "chrome framework" in joined \
            or "electron framework" in joined:
        return "chromium"
    if "plugin-container" in joined or "/firefox" in joined:
        return "gecko"
    if "webkit.webcontent" in joined:
        return "webkit"
    return "unknown"


ATTRIBUTION_TEXT = {
    "webkit": {
        "method": (
            "The main process and anything inside the .app bundle are matched by executable path. "
            "WebKit's WebContent, Networking and GPU services are system XPC services outside the bundle, "
            "so they are attributed through the macOS responsible-process relation "
            "(responsibility_get_pid_responsible_for_pid), the relation Activity Monitor uses to label them."
        ),
        "limits": [
            "A spare WebContent process WebKit keeps prewarmed counts toward the browser if its responsible pid is the browser.",
            "The Networking and GPU services are shared by all of that browser's windows, so their footprint is counted once, not per tab.",
            "If the responsible-process lookup fails the helpers are missing and memory is badly understated; the tool refuses to continue without them.",
        ],
    },
    "chromium": {
        "method": (
            "Every helper (renderer, GPU, utility) lives inside the .app bundle and is matched by executable path."
        ),
        "limits": [
            "Site isolation and the renderer process limit make the number of renderer processes depend on which sites are open, so per-tab figures are not a property of the browser alone.",
            "All benchmark pages share one origin (127.0.0.1), so Chromium may host several in one renderer where WebKit uses another split.",
        ],
    },
    "gecko": {
        "method": "Content and utility processes live inside the .app bundle and are matched by executable path.",
        "limits": [
            "Process count and sharing follow the browser's own content-process policy, not the tab count.",
        ],
    },
    "unknown": {
        "method": "Matched by executable path inside the .app bundle and by responsible process; the engine could not be identified.",
        "limits": ["The engine was not recognised, so helper attribution could not be sanity-checked."],
    },
}


def describe_attribution(engine, source_counts, responsible_available):
    entry = ATTRIBUTION_TEXT[engine]
    return {
        "engine": engine,
        "method": entry["method"],
        "limits": list(entry["limits"]),
        "responsible_process_lookup": "available" if responsible_available else "unavailable",
        "sources_at_first_sample": dict(source_counts),
    }


def summarize_family(readings, roles):
    by_role = {}
    for pid, value in readings.items():
        role = roles.get(pid, "other")
        by_role[role] = by_role.get(role, 0) + value
    return {
        "total_bytes": sum(readings.values()),
        "by_role": by_role,
        "process_count": len(readings),
    }


# MARK: - System readers


def read_process_table():
    completed = subprocess.run(["/bin/ps", "-ww", "-Ao", "pid=,ppid=,comm="], capture_output=True, text=True)
    if completed.returncode != 0:
        raise BenchmarkError(f"ps failed with status {completed.returncode}: {completed.stderr.strip()}")
    table = parse_process_table(completed.stdout)
    if not table:
        raise BenchmarkError("ps returned no processes")
    return table


def ps_cpu_seconds(pids):
    if not pids:
        return {}
    completed = subprocess.run(
        ["/bin/ps", "-o", "pid=,cputime=", "-p", ",".join(str(pid) for pid in sorted(pids))],
        capture_output=True, text=True,
    )
    return parse_cputime_listing(completed.stdout)


def _load_library(names):
    for name in names:
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    return None


class ResponsibleLookup:
    def __init__(self):
        self.function = None
        library = _load_library([None, "/usr/lib/system/libquarantine.dylib"])
        if library is not None:
            try:
                function = library.responsibility_get_pid_responsible_for_pid
                function.argtypes = [ctypes.c_int]
                function.restype = ctypes.c_int
                self.function = function
            except AttributeError:
                self.function = None
        self.available = self.function is not None and self(os.getpid()) is not None

    def __call__(self, pid):
        if self.function is None:
            return None
        owner = self.function(pid)
        return owner if owner > 0 else None


class RusageInfoV0(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
    ]


class RusageMemoryReader:
    """ri_phys_footprint from proc_pid_rusage: what Activity Monitor calls Memory, and what Orbit's Task Manager shows."""

    name = "rusage"

    def __init__(self):
        library = _load_library(["/usr/lib/libproc.dylib", "libproc.dylib", None])
        if library is None:
            raise BenchmarkError("libproc could not be loaded")
        try:
            function = library.proc_pid_rusage
        except AttributeError as error:
            raise BenchmarkError("libproc has no proc_pid_rusage") from error
        function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RusageInfoV0)]
        function.restype = ctypes.c_int
        self.function = function

    def read(self, pids):
        result = {}
        for pid in pids:
            info = RusageInfoV0()
            if self.function(pid, 0, ctypes.byref(info)) == 0:
                result[pid] = int(info.ri_phys_footprint)
        return result


class FootprintCliReader:
    """The `footprint` command line tool; slower and rounded to the precision it prints."""

    name = "footprint"
    executable = "/usr/bin/footprint"

    def __init__(self):
        if not os.path.exists(self.executable):
            raise BenchmarkError(f"{self.executable} does not exist")

    def read(self, pids):
        result = {}
        for pid in pids:
            completed = subprocess.run([self.executable, str(pid)], capture_output=True, text=True)
            value = parse_footprint_output(completed.stdout)
            if value is not None:
                result[pid] = value
        return result


class RssMemoryReader:
    """Resident set size from ps. Not the footprint: it ignores compressed memory and counts shared pages."""

    name = "rss"

    def read(self, pids):
        if not pids:
            return {}
        completed = subprocess.run(
            ["/bin/ps", "-o", "pid=,rss=", "-p", ",".join(str(pid) for pid in sorted(pids))],
            capture_output=True, text=True,
        )
        result = {}
        for line in completed.stdout.splitlines():
            fields = line.split()
            if len(fields) == 2:
                try:
                    result[int(fields[0])] = int(fields[1]) * 1024
                except ValueError:
                    continue
        return result


def choose_memory_reader(preference):
    classes = {"rusage": RusageMemoryReader, "footprint": FootprintCliReader, "rss": RssMemoryReader}
    order = ["rusage", "footprint", "rss"] if preference == "auto" else [preference]
    problems = []
    for name in order:
        try:
            reader = classes[name]()
            value = reader.read([os.getpid()]).get(os.getpid())
        except BenchmarkError as error:
            problems.append(f"{name}: {error}")
            continue
        if value is not None and 1 << 20 <= value <= 1 << 42:
            return reader
        problems.append(f"{name}: reading this process returned {value!r}, which is not a plausible footprint")
    raise BenchmarkError("no memory source works. " + "; ".join(problems))


def capture(command):
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return completed.stdout.strip() if completed.returncode == 0 else ""


def machine_info():
    chip = capture(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]) \
        or capture(["/usr/sbin/sysctl", "-n", "hw.model"]) or platform.machine()
    macos = capture(["/usr/bin/sw_vers", "-productVersion"])
    memory = capture(["/usr/sbin/sysctl", "-n", "hw.memsize"])
    if not macos or not memory.isdigit():
        raise BenchmarkError("could not read the macOS version or installed memory with sw_vers and sysctl")
    return {
        "chip": chip,
        "model": capture(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "macos": macos,
        "macos_build": capture(["/usr/bin/sw_vers", "-buildVersion"]),
        "ram_bytes": int(memory),
        "logical_cpus": os.cpu_count(),
        "power_source": parse_power_source(capture(["/usr/bin/pmset", "-g", "batt"])),
        "low_power_mode": parse_low_power_mode(capture(["/usr/bin/pmset", "-g"])),
        "load_average_1m_at_start": os.getloadavg()[0],
        "python": platform.python_version(),
    }


def git_info():
    commit = capture(["/usr/bin/git", "-C", REPO_ROOT, "rev-parse", "HEAD"])
    status = capture(["/usr/bin/git", "-C", REPO_ROOT, "status", "--porcelain"])
    return {"git_commit": commit, "git_dirty": bool(status)}


def plist_value(bundle, key):
    return capture(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", os.path.join(bundle, "Contents", "Info.plist")])


def require_gui_session():
    manager = subprocess.run(["/bin/launchctl", "managername"], capture_output=True, text=True)
    session = manager.stdout.strip()
    if session != "Aqua":
        raise BenchmarkError(
            f"this login session is '{session or 'unknown'}', not 'Aqua'. Orbit must paint into a real "
            "window-server session; run this from a logged-in desktop session, not over plain ssh."
        )


def require_fair_power_state(machine, allow):
    problems = []
    if machine["power_source"] == "battery":
        problems.append("the Mac is running on battery power")
    if machine["low_power_mode"]:
        problems.append("Low Power Mode is on")
    if problems and not allow:
        raise BenchmarkError(
            " and ".join(problems) + ". Both throttle the CPU, so the numbers would not be comparable. "
            "Plug in and turn Low Power Mode off, or pass --allow-battery to record them anyway."
        )
    return [f"measured while {problem}" for problem in problems]


def wait_for_quiet_machine(max_load, timeout=300.0):
    deadline = time.monotonic() + timeout
    announced = False
    while True:
        load = os.getloadavg()[0]
        if load <= max_load:
            return load
        if time.monotonic() >= deadline:
            raise BenchmarkError(
                f"the 1-minute load average is {load:.2f} (limit {max_load}) after waiting {timeout:.0f}s. "
                "Something else is using the machine, so timings would be noise. Quit it, or raise --max-load."
            )
        if not announced:
            print(f"benchmark: load average {load:.2f} is above {max_load}; waiting for the machine to settle")
            announced = True
        time.sleep(5)


def purge_file_cache():
    completed = subprocess.run(["/usr/bin/sudo", "-n", "/usr/sbin/purge"], capture_output=True, text=True)
    if completed.returncode != 0:
        raise BenchmarkError(
            "--purge-cold needs passwordless sudo for /usr/sbin/purge "
            f"(status {completed.returncode}: {completed.stderr.strip()}). "
            "Run `sudo -v` first or add a sudoers rule; otherwise leave the flag off and the "
            "cold launch is only 'first launch of the attempt'."
        )


# MARK: - The benchmark pages


LOREM = (
    "Browsers spend most of their lives waiting for the next input, so a measurement of an idle "
    "browser is mostly a measurement of what it keeps alive. This paragraph is fixed text so every "
    "load of the page does exactly the same work."
)


def beacon_script(identifier):
    return (
        "<script>requestAnimationFrame(function(){requestAnimationFrame(function(){"
        "fetch('/beacon?id=" + identifier + "',{cache:'no-store',keepalive:true}).catch(function(){});"
        "});});</script>"
    )


def page_shell(title, style, body):
    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>" + title + "</title>"
        "<style>" + style + "</style></head><body>" + body + "</body></html>"
    )


def build_page(kind, identifier):
    if not IDENTIFIER_PATTERN.fullmatch(identifier or ""):
        raise BenchmarkError(f"page identifier {identifier!r} must match {IDENTIFIER_PATTERN.pattern}")
    title = f"Orbit benchmark {kind} {identifier}"
    base_style = "body{margin:0;padding:32px;font:16px/1.5 -apple-system,sans-serif;background:#f4f1ea;color:#222}"
    if kind == "light":
        paragraphs = "".join(f"<p>{LOREM} ({number})</p>" for number in range(1, 7))
        body = f"<h1>{title}</h1>{paragraphs}" + beacon_script(identifier)
        return page_shell(title, base_style + "h1{margin:0 0 16px}p{max-width:60ch}", body).encode("utf-8")
    if kind == "medium":
        style = (
            base_style
            + ".row{display:flex;gap:12px;align-items:center;padding:4px 8px;border-bottom:1px solid #d8d2c4}"
            + ".row:nth-child(odd){background:#ece7da}.n{width:56px;text-align:right;color:#777}"
            + ".t{flex:1}.cell b{margin-right:6px}.cell i{color:#a33}"
        )
        rows = "".join(
            f"<div class=\"row\" id=\"r{number}\"><span class=\"n\">{number}</span>"
            f"<span class=\"t\">Row {number} of the benchmark table</span>"
            f"<a href=\"#r{number}\">link {number}</a>"
            f"<div class=\"cell\"><b>{number % 97}</b><i>{number % 13}</i></div></div>"
            for number in range(MEDIUM_ROWS)
        )
        body = f"<h1>{title}</h1>{rows}" + beacon_script(identifier)
        return page_shell(title, style, body).encode("utf-8")
    if kind == "heavy":
        script = (
            "<script>"
            "var records=[];"
            f"for(var i=0;i<{HEAVY_RECORDS};i++){{records.push({{id:i,name:'record-'+i,"
            "tags:['a'+(i%17),'b'+(i%31)],score:Math.sqrt(i)});}"
            f"var buffer=new Float64Array({HEAVY_BUFFER_LENGTH});"
            "for(var j=0;j<buffer.length;j++){buffer[j]=Math.sin(j)*Math.cos(j/3);}"
            "var digest=0;for(var k=0;k<records.length;k++){digest=(digest+records[k].score*(k%7))%1000003;}"
            "window.__benchmark={records:records,buffer:buffer,digest:digest};"
            "document.getElementById('digest').textContent=String(digest);"
            "</script>"
        )
        body = f"<h1>{title}</h1><p>Digest <span id=\"digest\"></span></p>" + script + beacon_script(identifier)
        return page_shell(title, base_style, body).encode("utf-8")
    raise BenchmarkError(f"unknown page kind {kind!r}; the kinds are {', '.join(PAGE_KINDS)}")


def page_kind_for(index, page):
    if page == "mixed":
        return PAGE_KINDS[index % len(PAGE_KINDS)]
    return page


class BenchServer:
    """A loopback-only HTTP server for the pages and for their painted-frame beacons."""

    def __init__(self, port=0):
        self._painted = {}
        self._condition = threading.Condition()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                return

            def _reply(self, status, content_type, body):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                arrived = time.time()
                parsed = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                identifier = (query.get("id") or [""])[0]
                if parsed.path.startswith("/page/"):
                    try:
                        body = build_page(parsed.path[len("/page/"):], identifier)
                    except BenchmarkError as error:
                        self._reply(400, "text/plain; charset=utf-8", str(error).encode("utf-8"))
                        return
                    self._reply(200, "text/html; charset=utf-8", body)
                elif parsed.path == "/beacon":
                    if not IDENTIFIER_PATTERN.fullmatch(identifier):
                        self._reply(400, "text/plain; charset=utf-8", b"bad id")
                        return
                    owner.record_painted(identifier, arrived)
                    self.send_response(204)
                    self.send_header("Content-Length", "0")
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                else:
                    self._reply(404, "text/plain; charset=utf-8", b"not found")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.httpd.daemon_threads = True
        self.thread = None

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def page_url(self, kind, identifier):
        return f"{self.base_url}/page/{kind}?id={urllib.parse.quote(identifier)}"

    def start(self):
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        if self.thread is not None:
            self.thread.join(timeout=5)

    def record_painted(self, identifier, epoch):
        with self._condition:
            self._painted.setdefault(identifier, epoch)
            self._condition.notify_all()

    def wait_painted(self, identifier, timeout):
        deadline = time.monotonic() + timeout
        with self._condition:
            while identifier not in self._painted:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self._condition.wait(remaining)
            return self._painted[identifier]


# MARK: - Driving Orbit


def declared_bench_commands():
    with open(smoke.PROBE_SOURCE, "r", encoding="utf-8") as handle:
        text = handle.read()
    return smoke._enum_cases(text, BENCH_MARKER)


def log_tail(path, limit=1500):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()[-limit:]
    except OSError:
        return ""


class RunContext:
    def __init__(self, options, scheme, app_path, run_directory, server, reader, responsible):
        self.options = options
        self.scheme = scheme
        self.app_path = app_path
        self.run_directory = run_directory
        self.server = server
        self.reader = reader
        self.responsible = responsible
        self.warnings = []
        self.engine_version = ""
        self.bundle_sampler = FamilySampler(app_path, responsible if responsible.available else None)

    def warn(self, message):
        if message not in self.warnings:
            self.warnings.append(message)
            print(f"benchmark: warning: {message}", file=sys.stderr)


class OrbitLaunch:
    """One launched Orbit process and the file channel into its benchmark probe."""

    def __init__(self, context, name):
        self.context = context
        self.name = name
        self.directory = os.path.join(context.run_directory, name)
        self.pid = None
        self.started_epoch = 0.0
        self.ready = {}
        self.sequence = 0
        self.spare = set()

    def start(self, url=None):
        options = self.context.options
        scheme = self.context.scheme
        app_path = self.context.app_path
        os.makedirs(self.directory, exist_ok=True)
        stdout_path = os.path.join(self.directory, "stdout.log")
        stderr_path = os.path.join(self.directory, "stderr.log")
        for path in (stdout_path, stderr_path):
            with open(path, "w", encoding="utf-8"):
                pass

        executable = os.path.join(app_path, "Contents", "MacOS", scheme.executable)
        self.spare = smoke.pids_running(executable)
        environment = {
            "ORBIT_SMOKE_PROBE": "1",
            "ORBIT_SMOKE_PROBE_BENCH": "1",
            "ORBIT_SMOKE_PROBE_OUT": self.directory,
            "ORBIT_SMOKE_PROBE_LABEL": scheme.name,
            "ORBIT_SMOKE_PROBE_ATTEMPT": self.name,
        }
        if url:
            environment["ORBIT_SMOKE_PROBE_URL"] = url
        command = ["/usr/bin/open", "-n", "-a", app_path, "--stdout", stdout_path, "--stderr", stderr_path]
        for key, value in environment.items():
            command += ["--env", f"{key}={value}"]
        command += ["--args", "-OrbitConfirmBeforeQuit", "NO", "-SUEnableAutomaticChecks", "NO"]

        self.started_epoch = time.time()
        started = time.monotonic()
        launch = subprocess.run(command, capture_output=True, text=True)
        if launch.returncode != 0:
            raise BenchmarkError(
                f"`open -n -a {app_path}` failed with status {launch.returncode}: "
                f"{(launch.stderr or launch.stdout).strip()[:400]}"
            )

        deadline = started + options.launch_timeout
        while self.pid is None:
            appeared = smoke.pids_running(executable) - self.spare
            if len(appeared) == 1:
                self.pid = appeared.pop()
            elif len(appeared) > 1:
                raise BenchmarkError(
                    f"{len(appeared)} new {scheme.executable} processes appeared for one launch "
                    f"({sorted(appeared)}); this run cannot tell which one it started."
                )
            elif time.monotonic() >= deadline:
                raise BenchmarkError(
                    f"{scheme.app} never appeared as a process within {options.launch_timeout}s. "
                    f"Log: {stderr_path}\n{log_tail(stderr_path)}"
                )
            else:
                time.sleep(0.02)

        ready_path = os.path.join(self.directory, "bench-ready.json")
        while not os.path.exists(ready_path):
            if not smoke.is_alive(self.pid):
                raise BenchmarkError(
                    f"{scheme.app} (pid {self.pid}) exited before it was ready. Log: {stderr_path}\n{log_tail(stderr_path)}"
                )
            if time.monotonic() >= deadline:
                raise BenchmarkError(
                    f"{scheme.app} (pid {self.pid}) was not ready within {options.launch_timeout}s. "
                    f"Log: {stderr_path}\n{log_tail(stderr_path)}"
                )
            time.sleep(0.01)
        with open(ready_path, "r", encoding="utf-8") as handle:
            self.ready = json.load(handle)
        self.verify_ready(stderr_path)

    def verify_ready(self, stderr_path):
        app_path = self.context.app_path
        if self.ready.get("schema") != 1:
            raise BenchmarkError(f"bench-ready.json declares schema {self.ready.get('schema')!r}, not 1")
        if self.ready.get("pid") != self.pid:
            raise BenchmarkError(
                f"the probe reports pid {self.ready.get('pid')} but this run launched pid {self.pid}"
            )
        if os.path.realpath(str(self.ready.get("bundlePath", ""))) != os.path.realpath(app_path):
            raise BenchmarkError(
                f"the probe ran from {self.ready.get('bundlePath')!r}, not the app this run launched ({app_path})"
            )
        missing = [name for name in USED_COMMANDS if name not in self.ready.get("commands", [])]
        if missing:
            raise BenchmarkError(
                f"this build of the app does not handle the probe command(s) {', '.join(missing)}. "
                f"Rebuild without --skip-build. Log: {stderr_path}"
            )
        data_root = str(self.ready.get("dataRoot", ""))
        production = os.path.realpath(smoke.PRODUCTION_PROFILE)
        resolved = os.path.realpath(data_root)
        if not data_root or resolved == production or resolved.startswith(production + os.sep):
            raise BenchmarkError(f"the app's data root {data_root!r} is the real profile; refusing to benchmark into it")

    def command(self, name, timeout=30.0, **fields):
        self.sequence += 1
        sequence = self.sequence
        payload = dict(fields)
        payload["command"] = name
        final = os.path.join(self.directory, f"bench-command-{sequence}.json")
        temporary = final + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(temporary, final)

        response_path = os.path.join(self.directory, f"bench-response-{sequence}.json")
        deadline = time.monotonic() + timeout
        while not os.path.exists(response_path):
            if not smoke.is_alive(self.pid):
                raise BenchmarkError(
                    f"Orbit (pid {self.pid}) exited while handling the {name} command. "
                    f"Log: {os.path.join(self.directory, 'stderr.log')}"
                )
            if time.monotonic() >= deadline:
                raise BenchmarkError(
                    f"Orbit did not answer the {name} command within {timeout}s. "
                    f"Log: {os.path.join(self.directory, 'stderr.log')}"
                )
            time.sleep(0.005)
        with open(response_path, "r", encoding="utf-8") as handle:
            response = json.load(handle)
        if not response.get("ok"):
            raise BenchmarkError(f"Orbit refused the {name} command: {response.get('error')}")
        return response

    def stop(self):
        options = self.context.options
        if self.pid is not None and smoke.is_alive(self.pid):
            try:
                self.command("quit", timeout=10.0)
            except BenchmarkError:
                pass
            deadline = time.monotonic() + options.shutdown_timeout
            while time.monotonic() < deadline and smoke.is_alive(self.pid):
                time.sleep(0.1)
        killed = smoke.kill_tree(self.pid, self.context.app_path, self.spare)
        if killed:
            print(f"benchmark:   killed leftover process(es) {killed}")


@contextlib.contextmanager
def orbit_launch(context, name, url=None):
    launch = OrbitLaunch(context, name)
    try:
        launch.start(url)
        yield launch
    finally:
        launch.stop()


def settle_between_launches(context):
    deadline = time.monotonic() + 30
    while smoke.pids_under(context.app_path) and time.monotonic() < deadline:
        time.sleep(0.2)
    time.sleep(context.options.between_launches)


# MARK: - Sampling a process family


class FamilySampler:
    def __init__(self, bundle, responsible):
        self.bundle = bundle
        self.responsible = responsible

    def discover(self, probe_roles=None):
        table = read_process_table()
        family = discover_family(table, self.bundle, self.responsible)
        entries = {entry.pid: entry for entry in table}
        for pid in probe_roles or {}:
            if pid in entries and pid not in family:
                family[pid] = "probe"
        return family, entries


def read_family_memory(sampler, reader, status=None):
    probe_roles = {}
    in_app = {}
    if status is not None:
        for item in status.get("processes", []):
            pid = int(item["pid"])
            probe_roles[pid] = PROBE_ROLES.get(item.get("role"), "other")
            in_app[pid] = int(item["footprintBytes"])
    family, entries = sampler.discover(probe_roles)
    pids = sorted(family)
    readings = reader.read(pids)
    roles = {pid: probe_roles.get(pid) or role_of(entries[pid].path, sampler.bundle) for pid in pids}
    summary = summarize_family(readings, roles)
    summary["processes"] = sorted(
        (
            {
                "pid": pid,
                "role": roles[pid],
                "source": family[pid],
                "name": os.path.basename(entries[pid].path),
                "bytes": readings[pid],
            }
            for pid in pids if pid in readings
        ),
        key=lambda item: -item["bytes"],
    )
    sources = {}
    for source in family.values():
        sources[source] = sources.get(source, 0) + 1
    summary["sources"] = sources
    summary["unreadable"] = [pid for pid in pids if pid not in readings]
    summary["probe_only"] = [pid for pid, source in family.items() if source == "probe"]
    summary["crosscheck_ratio"] = crosscheck_ratio(readings, in_app) if in_app else None
    summary["live_renderers"] = status.get("liveRenderers") if status else None
    return summary


def measure_memory(context, launch, require_pages):
    options = context.options
    taken = []
    for number in range(options.memory_readings):
        status = launch.command("status")
        summary = read_family_memory(context.bundle_sampler, context.reader, status)
        if require_pages and summary["by_role"].get("webcontent", 0) == 0:
            raise BenchmarkError(
                "no WebContent process was attributed to Orbit although tabs are open, so the memory "
                f"reading would exclude every page. Attribution sources: {summary['sources']}. Log: {launch.directory}"
            )
        ratio = summary["crosscheck_ratio"]
        if ratio is not None and context.reader.name == "rusage" and not 0.8 <= ratio <= 1.25:
            context.warn(
                f"the footprint this script read for Orbit's processes was {ratio:.2f}x what Orbit's own "
                "Task Manager API reported at the same moment; check the memory source"
            )
        if summary["probe_only"]:
            context.warn(
                "Orbit named process(es) the external attribution did not find (counted anyway); "
                "measure-running on Orbit may read lower than this run"
            )
        if summary["unreadable"]:
            context.warn(f"footprint could not be read for pid(s) {summary['unreadable']} of Orbit's family")
        taken.append(summary)
        if number < options.memory_readings - 1:
            time.sleep(options.memory_reading_gap)
    return {"bytes": median([item["total_bytes"] for item in taken]), "readings": taken}


def measure_idle_cpu(context, launch, window):
    status = launch.command("status")
    probe_roles = {int(item["pid"]): PROBE_ROLES.get(item.get("role"), "other") for item in status.get("processes", [])}
    sampler = context.bundle_sampler
    family_start, _ = sampler.discover(probe_roles)
    before = ps_cpu_seconds(sorted(family_start))
    started = time.monotonic()
    time.sleep(window)
    family_end, _ = sampler.discover(probe_roles)
    after = ps_cpu_seconds(sorted(family_end))
    return cpu_percent(before, after, time.monotonic() - started)


def wait_painted_or_explain(context, launch, identifier):
    timeout = context.options.paint_timeout
    painted = context.server.wait_painted(identifier, timeout)
    if painted is not None:
        return painted
    try:
        detail = json.dumps(launch.command("status", timeout=10.0).get("tabs"))
    except BenchmarkError as error:
        detail = f"status unavailable: {error}"
    raise BenchmarkError(
        f"page {identifier} never reported a painted frame within {timeout}s. Orbit's view of the tabs "
        f"it opened: {detail}. The window must be on screen, not covered, and the display awake. "
        f"Logs: {launch.directory}"
    )


def open_tab_timed(context, launch, kind, identifier):
    url = context.server.page_url(kind, identifier)
    response = launch.command("openTabs", urls=[url])
    started = float(response["opened"][0]["startEpoch"])
    painted = wait_painted_or_explain(context, launch, identifier)
    elapsed = (painted - started) * 1000.0
    if elapsed < 0:
        raise BenchmarkError(f"page {identifier} reported painting {-elapsed:.1f} ms before Orbit opened it; the clocks disagree")
    return elapsed


# MARK: - The attempt


def stage_cold(context, index, recorder, raw):
    options = context.options
    if options.purge_cold:
        purge_file_cache()
    identifier = f"a{index}-cold"
    url = context.server.page_url("light", identifier)
    stage = {}
    with orbit_launch(context, f"attempt{index:02d}-cold", url=url) as launch:
        context.engine_version = launch.ready.get("engine", context.engine_version)
        painted = wait_painted_or_explain(context, launch, identifier)
        elapsed = (painted - launch.started_epoch) * 1000.0
        if elapsed < 0:
            raise BenchmarkError("the first page reported painting before the launch began; the clocks disagree")
        stage["launch_ms"] = elapsed
        print(f"benchmark:   cold launch to first paint {elapsed:.1f} ms")
        if "launch" in options.metrics:
            recorder.add("launch_cold_ms", elapsed, "ms", {"page": "light", "purged": bool(options.purge_cold)})
        if "cpu" in options.metrics:
            time.sleep(options.settle_seconds)
            cpu = measure_idle_cpu(context, launch, options.cpu_window)
            stage["cpu"] = cpu
            print(f"benchmark:   idle CPU {cpu['percent']:.2f} % over {cpu['wall_seconds']:.1f}s")
            recorder.add(
                cpu_metric_id("light", 1), cpu["percent"], "percent",
                {"page": "light", "tabs": 1, "window_s": options.cpu_window},
            )
    raw["cold"] = stage
    settle_between_launches(context)


def stage_warm(context, index, recorder, raw):
    options = context.options
    identifier = f"a{index}-warm"
    url = context.server.page_url("light", identifier)
    stage = {}
    with orbit_launch(context, f"attempt{index:02d}-warm", url=url) as launch:
        painted = wait_painted_or_explain(context, launch, identifier)
        elapsed = (painted - launch.started_epoch) * 1000.0
        if elapsed < 0:
            raise BenchmarkError("the first page reported painting before the launch began; the clocks disagree")
        stage["launch_ms"] = elapsed
        print(f"benchmark:   warm relaunch to first paint {elapsed:.1f} ms")
        if "launch" in options.metrics:
            recorder.add("launch_warm_ms", elapsed, "ms", {"page": "light"})
        if "tabs" in options.metrics:
            time.sleep(options.settle_seconds)
            opens = []
            for number in range(1, options.tab_open_count + 1):
                opens.append(open_tab_timed(context, launch, "light", f"a{index}-tab-{number}"))
            stage["tab_open_ms"] = opens
            print(f"benchmark:   {len(opens)} sequential tab opens, median {median(opens):.1f} ms")
            for value in opens:
                recorder.add(
                    "tab_open_ms", value, "ms",
                    {"page": "light", "tabs_opened": options.tab_open_count},
                )
    raw["warm"] = stage
    settle_between_launches(context)


def stage_ladder(context, index, page, recorder, raw):
    options = context.options
    stage = {"rungs": []}
    with orbit_launch(context, f"attempt{index:02d}-ladder-{page}") as launch:
        time.sleep(options.settle_seconds)
        baseline = measure_memory(context, launch, require_pages=False)
        recorder.add("memory.baseline.tabs_0", baseline["bytes"], "bytes", {"page": "none", "tabs": 0})
        stage["baseline"] = baseline
        opened = 0
        points = []
        for count in options.tab_counts:
            while opened < count:
                opened += 1
                open_tab_timed(context, launch, page_kind_for(opened - 1, page), f"a{index}-{page}-{opened}")
            time.sleep(options.settle_seconds)
            measured = measure_memory(context, launch, require_pages=True)
            recorder.add(memory_metric_id(page, count), measured["bytes"], "bytes", {"page": page, "tabs": count})
            points.append((count, measured["bytes"]))
            stage["rungs"].append({"tabs": count, **measured})
            print(f"benchmark:   {page} x{count} tabs: {measured['bytes'] / 1048576:,.1f} MiB")
        if len(points) >= 2:
            slope = linear_slope(points)
            recorder.add(
                f"memory.{page}.per_tab_bytes", slope, "bytes",
                {"page": page, "tab_counts": list(options.tab_counts)},
            )
            print(f"benchmark:   {page} marginal {slope / 1048576:,.2f} MiB per tab")
        closed = launch.command("closeOpenedTabs", timeout=60.0)
        stage["closed"] = closed
        time.sleep(options.close_settle_seconds)
        after = measure_memory(context, launch, require_pages=False)
        stage["after_close"] = after
        recorder.add(
            f"memory_after_close.{page}", after["bytes"], "bytes",
            {"page": page, "tabs_before_close": options.tab_counts[-1]},
        )
        recorder.add(
            f"memory_after_close_over_baseline.{page}", after["bytes"] - baseline["bytes"], "bytes",
            {"page": page, "tabs_before_close": options.tab_counts[-1]},
        )
        print(
            f"benchmark:   {page} after closing all: {after['bytes'] / 1048576:,.1f} MiB "
            f"({(after['bytes'] - baseline['bytes']) / 1048576:+,.1f} MiB vs baseline)"
        )
    raw[f"ladder_{page}"] = stage
    settle_between_launches(context)


def stage_growth(context, index, recorder, raw):
    options = context.options
    tabs = options.growth_tabs
    intervals = int(options.growth_seconds // options.growth_interval)
    stage = {"series": [], "cpu": []}
    with orbit_launch(context, f"attempt{index:02d}-growth") as launch:
        time.sleep(options.settle_seconds)
        for number in range(1, tabs + 1):
            open_tab_timed(context, launch, page_kind_for(number - 1, "mixed"), f"a{index}-mixed-{number}")
        time.sleep(options.settle_seconds)
        origin = time.monotonic()
        series = []
        cpu_percents = []

        def take():
            measured = measure_memory(context, launch, require_pages=True)
            series.append({"t": time.monotonic() - origin, "bytes": measured["bytes"]})
            stage["series"].append({"t": series[-1]["t"], **measured})

        take()
        for _ in range(intervals):
            cpu = measure_idle_cpu(context, launch, options.growth_interval)
            cpu_percents.append(cpu["percent"])
            stage["cpu"].append(cpu)
            take()
        recorder.add_all(observation_metrics("mixed", tabs, series, cpu_percents, options.growth_interval))
        growth = series[-1]["bytes"] - series[0]["bytes"]
        print(
            f"benchmark:   mixed x{tabs} tabs over {series[-1]['t']:.0f}s: "
            f"{series[0]['bytes'] / 1048576:,.1f} -> {series[-1]['bytes'] / 1048576:,.1f} MiB "
            f"({growth / 1048576:+,.1f} MiB), idle CPU median {median(cpu_percents):.2f} %"
        )
    raw["growth"] = stage
    settle_between_launches(context)


def run_attempt(context, index):
    options = context.options
    recorder = Recorder()
    raw = {"index": index, "load_average_1m": os.getloadavg()[0]}
    wants = options.metrics
    if wants & {"launch", "cpu"}:
        stage_cold(context, index, recorder, raw)
    if wants & {"launch", "tabs"}:
        stage_warm(context, index, recorder, raw)
    if "memory" in wants:
        for page in options.pages:
            stage_ladder(context, index, page, recorder, raw)
    if "growth" in wants:
        stage_growth(context, index, recorder, raw)
    return {"index": index, "samples": recorder.samples, "specs": recorder.specs, "raw": raw}


# MARK: - Commands


def parse_choice_list(text, allowed, name):
    chosen = [item.strip() for item in text.split(",") if item.strip()]
    unknown = [item for item in chosen if item not in allowed]
    if not chosen or unknown:
        raise BenchmarkError(f"{name} must be a comma list drawn from {', '.join(allowed)}; got {text!r}")
    return chosen


def parse_int_list(text, name):
    try:
        values = [int(item) for item in text.split(",") if item.strip()]
    except ValueError as error:
        raise BenchmarkError(f"{name} must be comma-separated integers; got {text!r}") from error
    if not values or any(value < 1 for value in values) or values != sorted(set(values)):
        raise BenchmarkError(f"{name} must be strictly increasing positive integers; got {text!r}")
    return values


def default_results_directory():
    return os.path.join(REPO_ROOT, "build", "benchmark", time.strftime("%Y%m%d-%H%M%S"))


def sanitize_label(label):
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
    return cleaned or "browser"


def print_metric_summary(metrics):
    print("benchmark: summary (median, p90, samples)")
    for metric_id in sorted(metrics):
        metric = metrics[metric_id]
        summary = metric["summary"]
        print(
            f"benchmark:   {metric_id:48s} {format_value(metric['unit'], summary['median']):>14s}  "
            f"{format_value(metric['unit'], summary['p90']):>14s}  n={summary['n']}"
        )


def command_run(options):
    if options.attempts < 1:
        raise BenchmarkError(f"--attempts {options.attempts} cannot produce a measurement")
    options.metrics = set(parse_choice_list(options.metrics, ALL_METRIC_GROUPS, "--metrics"))
    options.pages = parse_choice_list(options.pages, PAGE_KINDS, "--pages")
    options.tab_counts = parse_int_list(options.tab_counts, "--tab-counts")
    if options.tab_open_count < 1 or options.growth_tabs < 1:
        raise BenchmarkError("--tab-open-count and --growth-tabs must be at least 1")
    if options.growth_interval <= 0 or options.growth_seconds < options.growth_interval:
        raise BenchmarkError("--growth-seconds must be at least one --growth-interval")
    if options.cpu_window <= 0 or options.memory_readings < 1:
        raise BenchmarkError("--cpu-window must be positive and --memory-readings at least 1")
    if shutil.which("xcodebuild") is None and not options.skip_build:
        raise BenchmarkError("xcodebuild is not on PATH")
    declared = declared_bench_commands()
    missing = [name for name in USED_COMMANDS if name not in declared]
    if missing:
        raise BenchmarkError(
            f"{smoke.PROBE_SOURCE} no longer declares the probe command(s) {', '.join(missing)} under "
            f"'{BENCH_MARKER}'; this script and the app have drifted apart."
        )

    require_gui_session()
    machine = machine_info()
    warnings = require_fair_power_state(machine, options.allow_battery)
    intruders = smoke.foreign_orbits()
    if intruders and not options.allow_running_orbit:
        listing = ", ".join(f"pid {pid} ({path})" for pid, path in intruders)
        raise BenchmarkError(
            f"another Orbit is already running: {listing}. It competes for CPU, memory and the window "
            "server, which makes every number unreliable. Quit it, or pass --allow-running-orbit."
        )
    if options.purge_cold:
        purge_file_cache()

    reader = choose_memory_reader(options.memory_source)
    responsible = ResponsibleLookup()
    print(f"benchmark: memory source {reader.name}; responsible-process lookup "
          f"{'available' if responsible.available else 'UNAVAILABLE (relying on the app to name its helpers)'}")

    run_directory = os.path.abspath(options.results_dir or default_results_directory())
    os.makedirs(run_directory, exist_ok=True)
    print(f"benchmark: results in {run_directory}")

    scheme = smoke.SCHEMES["Orbit"]
    options.derived_data = os.path.abspath(options.derived_data)
    if not options.skip_build:
        smoke.build(scheme, options, run_directory)
    app_path = os.path.join(options.derived_data, "Build", "Products", options.configuration, scheme.app)
    if not os.path.isdir(app_path):
        raise BenchmarkError(
            f"{app_path} does not exist. Run without --skip-build, or point --derived-data at a tree that has it."
        )
    identifier = plist_value(app_path, "CFBundleIdentifier")
    if identifier != scheme.bundle_id:
        raise BenchmarkError(
            f"{app_path} declares bundle identifier {identifier!r}, not {scheme.bundle_id!r}; this run would measure the wrong app."
        )

    own_executable = os.path.join(app_path, "Contents", "MacOS", scheme.executable)
    if any(path == own_executable for _, path in intruders):
        raise BenchmarkError(
            f"{own_executable} is already running; quit it. This run launches and kills processes from "
            "that bundle and must not touch one it did not start."
        )
    preexisting = smoke.pids_under(app_path)
    load = wait_for_quiet_machine(options.max_load)
    machine["load_average_1m_at_start"] = load
    server = BenchServer()
    server.start()
    context = RunContext(options, scheme, app_path, run_directory, server, reader, responsible)
    context.warnings.extend(warnings)
    profile_before = None if intruders else smoke.profile_snapshot()
    attempts = []
    try:
        for index in range(1, options.attempts + 1):
            print(f"benchmark: attempt {index}/{options.attempts}")
            attempt = run_attempt(context, index)
            attempts.append(attempt)
            write_json_file(os.path.join(run_directory, f"attempt-{index:02d}.json"), attempt)
    finally:
        server.stop()
        smoke.kill_tree(None, app_path, preexisting)

    if profile_before is not None:
        changes = smoke.profile_difference(profile_before, smoke.profile_snapshot())
        if changes:
            raise BenchmarkError(
                f"the real profile at {smoke.PRODUCTION_PROFILE} changed during this run: {'; '.join(changes)}. "
                "A benchmark must never touch the profile the user browses with."
            )

    target = {
        "name": "Orbit",
        "bundle_path": app_path,
        "bundle_identifier": identifier,
        "version": plist_value(app_path, "CFBundleShortVersionString"),
        "build": plist_value(app_path, "CFBundleVersion"),
        "configuration": options.configuration,
        "engine": context.engine_version,
    }
    target.update(git_info())
    metrics = aggregate_attempts(attempts)
    document = {
        "schema": SCHEMA_VERSION,
        "kind": "run",
        "methodology_version": METHODOLOGY_VERSION,
        "label": options.label,
        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "machine": machine,
        "target": target,
        "parameters": {
            "attempts": options.attempts,
            "metrics": sorted(options.metrics),
            "pages": options.pages,
            "tab_counts": options.tab_counts,
            "tab_open_count": options.tab_open_count,
            "growth_tabs": options.growth_tabs,
            "growth_seconds": options.growth_seconds,
            "growth_interval": options.growth_interval,
            "cpu_window": options.cpu_window,
            "settle_seconds": options.settle_seconds,
            "close_settle_seconds": options.close_settle_seconds,
            "memory_readings": options.memory_readings,
            "memory_reading_gap": options.memory_reading_gap,
            "purge_cold": bool(options.purge_cold),
            "medium_rows": MEDIUM_ROWS,
            "heavy_records": HEAVY_RECORDS,
            "heavy_buffer_length": HEAVY_BUFFER_LENGTH,
        },
        "methods": {
            "memory_source": reader.name,
            "cpu_source": "ps-cputime",
            "timing_source": "page beacon over loopback, wall clock",
            "attribution": describe_attribution(
                "webkit", {}, responsible.available
            ),
        },
        "metrics": metrics,
        "warnings": context.warnings,
        "raw": {"attempts": [attempt["raw"] for attempt in attempts]},
    }
    path = os.path.join(run_directory, "results.json")
    write_document(document, path)
    print_metric_summary(metrics)
    print(f"benchmark: wrote {path}")
    return 0


def write_json_file(path, payload):
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def command_measure_running(options):
    if options.duration < options.interval or options.interval <= 0:
        raise BenchmarkError("--duration must be at least one --interval, and --interval positive")
    if options.tabs_open is not None and options.tabs_open < 0:
        raise BenchmarkError("--tabs-open cannot be negative")
    if not re.fullmatch(r"[a-z0-9_-]+", options.page):
        raise BenchmarkError("--page may contain only lowercase letters, digits, '_' and '-'")

    reader = choose_memory_reader(options.memory_source)
    responsible = ResponsibleLookup()
    table = read_process_table()
    bundle = resolve_bundle(options.process_match, table)
    sampler = FamilySampler(bundle, responsible if responsible.available else None)
    family, entries = sampler.discover()
    engine = detect_engine([entries[pid] for pid in family])
    roles = {pid: role_of(entries[pid].path, bundle) for pid in family}
    if "webcontent" not in roles.values() and engine in ("webkit", "unknown") and not options.allow_missing_helpers:
        raise BenchmarkError(
            f"{bundle} is running but no WebContent helper was attributed to it. For a WebKit browser "
            f"that means the responsible-process lookup failed (lookup {'available' if responsible.available else 'unavailable'}) "
            "or no page is open, and the footprint would exclude every page. Open a page, or pass "
            "--allow-missing-helpers if this really is a browser without separate helper processes."
        )

    label = options.label or os.path.basename(bundle)[: -len(".app")]
    machine = machine_info()
    warnings = []
    if machine["power_source"] == "battery":
        warnings.append("measured while the Mac was on battery power")
    if machine["low_power_mode"]:
        warnings.append("measured while Low Power Mode was on")
    if os.getloadavg()[0] > 2.0:
        warnings.append(f"the 1-minute load average was {os.getloadavg()[0]:.2f} when sampling began")

    print(f"benchmark: measuring {label} at {bundle} (engine: {engine}); this never starts or signals the browser")
    counts = {}
    for role in roles.values():
        counts[role] = counts.get(role, 0) + 1
    print(f"benchmark: {len(family)} processes in the family: " + ", ".join(f"{role} x{count}" for role, count in sorted(counts.items())))
    print(f"benchmark: memory source {reader.name}; sampling every {options.interval:g}s for {options.duration:g}s")

    if options.settle > 0:
        time.sleep(options.settle)

    ticks = int(options.duration // options.interval)
    series = []
    cpu_percents = []
    cpu_windows = []
    raw_ticks = []
    previous = None
    origin = time.monotonic()
    source_counts = {}
    for tick in range(ticks + 1):
        due = origin + tick * options.interval
        remaining = due - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        family, entries = sampler.discover()
        pids = sorted(family)
        readings = reader.read(pids)
        cpu_times = ps_cpu_seconds(pids)
        now = time.monotonic()
        tick_roles = {pid: role_of(entries[pid].path, bundle) for pid in pids}
        summary = summarize_family(readings, tick_roles)
        summary["t"] = now - origin
        summary["unreadable"] = [pid for pid in pids if pid not in readings]
        raw_ticks.append(summary)
        series.append({"t": now - origin, "bytes": summary["total_bytes"]})
        if tick == 0:
            for source in family.values():
                source_counts[source] = source_counts.get(source, 0) + 1
        if previous is not None:
            window = cpu_percent(previous[0], cpu_times, now - previous[1])
            cpu_windows.append(window)
            cpu_percents.append(window["percent"])
        previous = (cpu_times, now)
        print(
            f"benchmark:   t={now - origin:6.1f}s  {summary['total_bytes'] / 1048576:,.1f} MiB "
            f"in {summary['process_count']} processes"
            + (f"  cpu {cpu_percents[-1]:.2f} %" if cpu_percents and tick > 0 else "")
        )

    tabs_label = options.tabs_open if options.tabs_open is not None else "unspecified"
    recorder = Recorder()
    recorder.add_all(observation_metrics(options.page, tabs_label, series, cpu_percents, options.interval))
    metrics = {}
    for metric_id in sorted(recorder.samples):
        values = recorder.samples[metric_id]
        metrics[metric_id] = {
            "unit": recorder.specs[metric_id]["unit"],
            "conditions": recorder.specs[metric_id]["conditions"],
            "samples": values,
            "summary": summarize(values),
        }

    target = {
        "name": label,
        "bundle_path": bundle,
        "version": plist_value(bundle, "CFBundleShortVersionString"),
        "build": plist_value(bundle, "CFBundleVersion"),
        "engine": engine,
        "process_roles_at_first_sample": counts,
    }
    document = {
        "schema": SCHEMA_VERSION,
        "kind": "measure-running",
        "methodology_version": METHODOLOGY_VERSION,
        "label": label,
        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "machine": machine,
        "target": target,
        "parameters": {
            "process_match": options.process_match,
            "tabs_open": options.tabs_open,
            "page": options.page,
            "duration_s": options.duration,
            "interval_s": options.interval,
            "settle_s": options.settle,
        },
        "methods": {
            "memory_source": reader.name,
            "cpu_source": "ps-cputime",
            "timing_source": "none (no launch or paint timing is taken from a browser this tool did not start)",
            "attribution": describe_attribution(engine, source_counts, responsible.available),
        },
        "metrics": metrics,
        "warnings": warnings,
        "raw": {"ticks": raw_ticks, "cpu_windows": cpu_windows},
    }
    directory = os.path.abspath(options.results_dir or default_results_directory())
    path = os.path.join(directory, f"measure-{sanitize_label(label)}.json")
    write_document(document, path)
    print_metric_summary(metrics)
    for warning in warnings:
        print(f"benchmark: warning: {warning}", file=sys.stderr)
    print(f"benchmark: wrote {path}")
    return 0


def command_compare(options):
    documents = [load_document(path) for path in options.files]
    text = compare_documents(documents, options.files)
    if options.output:
        with open(options.output, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"benchmark: wrote {options.output}")
    sys.stdout.write(text)
    return 0


def command_serve(options):
    if options.tabs < 1:
        raise BenchmarkError("--tabs must be at least 1")
    server = BenchServer(options.port)
    server.start()
    try:
        print(f"benchmark: serving the {options.page} page set on {server.base_url} (loopback only)")
        print("benchmark: open exactly these URLs, one per tab, in the browser you started yourself:")
        for number in range(1, options.tabs + 1):
            print(server.page_url(page_kind_for(number - 1, options.page), f"serve-{number}"))
        print("benchmark: press Ctrl-C to stop serving")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("benchmark: stopped")
    finally:
        server.stop()
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="benchmark", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command")

    run = subparsers.add_parser("run", help="build and benchmark Orbit (Orbit only)")
    run.add_argument("--attempts", type=int, default=5)
    run.add_argument("--label", default="Orbit")
    run.add_argument("--configuration", default="Release", choices=["Debug", "Release"])
    run.add_argument("--derived-data", default=os.path.join(REPO_ROOT, "DerivedData"))
    run.add_argument("--destination", default="platform=macOS,arch=arm64")
    run.add_argument("--skip-build", action="store_true")
    run.add_argument("--results-dir", help="default: build/benchmark/<timestamp>")
    run.add_argument("--metrics", default=",".join(ALL_METRIC_GROUPS),
                     help="comma list of launch,tabs,cpu,memory,growth (default: all)")
    run.add_argument("--pages", default=",".join(PAGE_KINDS), help="page weights for the memory ladder")
    run.add_argument("--tab-counts", default="1,5,10,20")
    run.add_argument("--tab-open-count", type=int, default=10,
                     help="sequential tab opens timed per attempt")
    run.add_argument("--growth-tabs", type=int, default=10)
    run.add_argument("--growth-seconds", type=float, default=180.0)
    run.add_argument("--growth-interval", type=float, default=30.0)
    run.add_argument("--cpu-window", type=float, default=30.0)
    run.add_argument("--settle-seconds", type=float, default=5.0)
    run.add_argument("--close-settle-seconds", type=float, default=10.0)
    run.add_argument("--memory-readings", type=int, default=3,
                     help="footprint readings per data point; the median is kept")
    run.add_argument("--memory-reading-gap", type=float, default=1.0)
    run.add_argument("--memory-source", default="auto", choices=["auto", "rusage", "footprint", "rss"])
    run.add_argument("--between-launches", type=float, default=3.0)
    run.add_argument("--paint-timeout", type=float, default=30.0)
    run.add_argument("--launch-timeout", type=float, default=60.0)
    run.add_argument("--shutdown-timeout", type=float, default=30.0)
    run.add_argument("--max-load", type=float, default=2.0,
                     help="refuse to start while the 1-minute load average is above this")
    run.add_argument("--purge-cold", action="store_true",
                     help="run `sudo -n purge` before each cold launch (needs passwordless sudo)")
    run.add_argument("--allow-battery", action="store_true")
    run.add_argument("--allow-running-orbit", action="store_true")
    run.add_argument("build_arguments", nargs="*", default=[],
                     help="extra arguments for xcodebuild, after --")
    run.set_defaults(handler=command_run)

    measure = subparsers.add_parser(
        "measure-running",
        help="sample a browser you already started; never starts or signals it",
    )
    measure.add_argument("--process-match", required=True,
                         help="the browser's .app path, or a substring of its executable path")
    measure.add_argument("--label")
    measure.add_argument("--tabs-open", type=int,
                         help="how many benchmark pages are open, recorded and used to match metrics")
    measure.add_argument("--page", default="unspecified",
                         help="page set open in the browser: light, medium, heavy or mixed (see `serve`)")
    measure.add_argument("--duration", type=float, default=180.0)
    measure.add_argument("--interval", type=float, default=30.0)
    measure.add_argument("--settle", type=float, default=0.0, help="seconds to wait before the first sample")
    measure.add_argument("--memory-source", default="auto", choices=["auto", "rusage", "footprint", "rss"])
    measure.add_argument("--results-dir")
    measure.add_argument("--allow-missing-helpers", action="store_true")
    measure.set_defaults(handler=command_measure_running)

    compare = subparsers.add_parser("compare", help="markdown table of two or more result files")
    compare.add_argument("files", nargs="+")
    compare.add_argument("--output", help="also write the table to this file")
    compare.set_defaults(handler=command_compare)

    serve = subparsers.add_parser("serve", help="serve the benchmark pages for another browser")
    serve.add_argument("--page", default="light", choices=list(PAGE_KINDS) + ["mixed"])
    serve.add_argument("--tabs", type=int, default=10)
    serve.add_argument("--port", type=int, default=0)
    serve.set_defaults(handler=command_serve)
    return parser


def main(argv):
    sys.stdout.reconfigure(line_buffering=True)
    parser = build_parser()
    options = parser.parse_args(argv)
    if not getattr(options, "handler", None):
        parser.print_help()
        return 2
    if options.handler is command_compare and len(options.files) < 2:
        print("error: benchmark: compare needs at least two result files", file=sys.stderr)
        return 2
    try:
        return options.handler(options)
    except (BenchmarkError, smoke.SmokeError) as error:
        print(f"error: benchmark: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("benchmark: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
