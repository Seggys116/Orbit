#!/usr/bin/env python3
"""Decides whether a test run really ran. See Scripts/test-verdict.

A green `xcodebuild test` proves nothing alone -- a dead host, a skipped TestableReference or
a dropped target all exit 0 with nothing executed -- so every check here is against the number
of tests declared in the sources. `check` is the plain `xcodebuild test` path; `live` is the
per-configuration verdict for Scripts/live-engine-tests; both share the readers below.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

GATE_MARKER = "ORBIT_LIVE_ENGINE"
MAY_SKIP_MARKER = "ORBIT-LIVE-ENGINE: MAY-SKIP"
SCHEMA_VERSION = "0.1.0"

TYPE_HEADER = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(class|struct|enum|actor|protocol|extension)\s+([A-Za-z0-9_]+)\s*(:[^{]*)?\{"
)
TEST_FUNC = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"func\s+(test[A-Za-z0-9_]*)\s*\(\s*\)"
)
MAY_SKIP_LINE = re.compile(r"^\s*//\s*" + re.escape(MAY_SKIP_MARKER) + r"\s+([A-Za-z0-9_]+)\s*$")
CONDITIONAL = re.compile(r"^\s*#(if|elseif|else|endif)\b\s*(.*)$")

LOG_SKIP = re.compile(r"^.*?:\s*-\[[A-Za-z0-9_.]+\.([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\]\s*:\s*Test skipped\s*-\s*(.*)$")
# Same wording as LOG_SKIP's suffix, but as an xcresult "Failure Message" child of a skipped Test Case.
BUNDLE_SKIP_PREFIX = "Test skipped - "
LOG_CASE = re.compile(r"^Test Case '-\[[A-Za-z0-9_.]+\.([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\]' (passed|failed|skipped)\b")
# Parallel-runner reporter (OrbitTests): lower-case "case", no module prefix, no skip reason at all.
LOG_CASE_PARALLEL = re.compile(r"^Test case '([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\(\)' (passed|failed|skipped)\b")


class VerdictError(Exception):
    pass


# A suite may subclass a shared base, so any `...TestCase` superclass counts.
def _inherits_test_case(inherits: str | None) -> bool:
    if not inherits:
        return False
    for token in inherits.lstrip(":").split(","):
        if re.sub(r"<.*", "", token).strip().endswith("TestCase"):
            return True
    return False


# The Debug configuration both callers build. An unknown condition is refused
# rather than guessed at: guessing wrong silently changes the expected count.
def _condition_holds(condition: str) -> bool:
    condition = condition.strip()
    if condition == "DEBUG":
        return True
    if condition.startswith("canImport(") and condition.endswith(")"):
        return True
    raise VerdictError(
        f"unknown compilation condition '#if {condition}' in a test source. "
        "Scripts/test_verdict.py decides the expected test count from the sources and "
        "cannot evaluate this one, so teach _condition_holds() what it means in the "
        "Debug configuration that CI builds."
    )


def declared_tests(target_dir: str) -> dict[tuple[str, str], str]:
    """Every test method the sources of `target_dir` declare, as (class, method) -> file."""
    root = os.path.join(REPO_ROOT, target_dir)
    if not os.path.isdir(root):
        raise VerdictError(f"{target_dir} is not a directory under {REPO_ROOT}")

    # Symlinks under OrbitTests/Reused*Sources/ are production sources compiled
    # into the test target. They declare no tests and are not this inventory's.
    files = []
    for directory, _, names in os.walk(root):
        for name in sorted(names):
            path = os.path.join(directory, name)
            if name.endswith(".swift") and not os.path.islink(path):
                files.append(path)
    files.sort()

    test_classes: set[str] = set()
    for path in files:
        for line in _lines(path):
            match = TYPE_HEADER.match(line)
            if match and match.group(1) == "class" and _inherits_test_case(match.group(3)):
                test_classes.add(match.group(2))

    declared: dict[tuple[str, str], str] = {}
    for path in files:
        text = "\n".join(_lines(path))
        if "TestCase" not in text and not any(f"extension {name}" in text for name in test_classes):
            continue
        current = None
        active = [True]
        for line in _lines(path):
            conditional = CONDITIONAL.match(line)
            if conditional:
                directive, condition = conditional.groups()
                if directive == "if":
                    active.append(active[-1] and _condition_holds(condition))
                elif directive == "elseif":
                    active[-1] = False
                elif directive == "else":
                    active[-1] = not active[-1]
                elif directive == "endif" and len(active) > 1:
                    active.pop()
                continue
            if not all(active):
                continue
            # Only a declaration in the first column opens a new context; an
            # indented one is a helper type nested inside the current class.
            match = TYPE_HEADER.match(line)
            if match and line[:1] and not line[0].isspace():
                kind, name, inherits = match.groups()
                if kind == "class" and _inherits_test_case(inherits):
                    current = name
                elif kind == "extension" and name in test_classes:
                    current = name
                else:
                    current = None
                continue
            match = TEST_FUNC.match(line)
            if match and current:
                declared[(current, match.group(1))] = os.path.relpath(path, REPO_ROOT)
    return declared


def _lines(path: str) -> list[str]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().splitlines()


def may_skip_declarations(target_dir: str) -> dict[tuple[str, str], str]:
    """Tests a live suite declares may legitimately skip, as (class, method) -> file."""
    root = os.path.join(REPO_ROOT, target_dir)
    declared = declared_tests(target_dir)
    by_file: dict[str, set[str]] = {}
    for (suite, method), path in declared.items():
        by_file.setdefault(path, set()).add(f"{suite}.{method}")

    allowed: dict[tuple[str, str], str] = {}
    for directory, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, REPO_ROOT)
            for line in _lines(path):
                match = MAY_SKIP_LINE.match(line)
                if not match:
                    continue
                method = match.group(1)
                matches = [
                    key for key in declared
                    if key[1] == method and declared[key] == relative
                ]
                if not matches:
                    raise VerdictError(
                        f"{relative} declares '{MAY_SKIP_MARKER} {method}' but has no test method "
                        f"of that name. A marker naming a test that does not exist would let a real "
                        f"skip through unnoticed."
                    )
                for key in matches:
                    allowed[key] = relative
    return allowed


def bundle_tests(path: str) -> dict[str, list[dict[str, str]]]:
    """Every test case in a result bundle, grouped by test bundle name."""
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests",
             "--schema-version", SCHEMA_VERSION, "--compact", "--path", path],
            capture_output=True, check=True,
        ).stdout
    except FileNotFoundError as error:
        raise VerdictError(f"xcrun is unavailable: {error}") from error
    except subprocess.CalledProcessError as error:
        raise VerdictError(
            f"could not read {path}: {error.stderr.decode('utf-8', 'replace').strip()}"
        ) from error

    document = json.loads(raw)
    grouped: dict[str, list[dict[str, str]]] = {}

    def walk(node, bundle, suite):
        node_type = node.get("nodeType")
        if node_type in ("Unit test bundle", "UI test bundle"):
            bundle = node.get("name")
        elif node_type == "Test Suite":
            suite = node.get("name")
        elif node_type == "Test Case":
            name = (node.get("name") or "").split("(")[0]
            reason = None
            for child in node.get("children") or []:
                text = child.get("name") or ""
                if child.get("nodeType") == "Failure Message" and text.startswith(BUNDLE_SKIP_PREFIX):
                    reason = text[len(BUNDLE_SKIP_PREFIX):]
                    break
            grouped.setdefault(bundle or "?", []).append({
                "suite": suite or "?",
                "name": name,
                "result": node.get("result") or "?",
                "reason": reason,
            })
            return
        for child in node.get("children") or []:
            walk(child, bundle, suite)

    for node in document.get("testNodes") or []:
        walk(node, None, None)
    return grouped


def log_events(path: str) -> tuple[dict[tuple[str, str], str], dict[str, int]]:
    """Skip reasons by (class, method), and the per-outcome case counts, from an xcodebuild log."""
    reasons: dict[tuple[str, str], str] = {}
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for line in _lines(path):
        match = LOG_SKIP.match(line)
        if match:
            suite, method, reason = match.groups()
            reasons[(suite, method)] = reason.strip()
            continue
        match = LOG_CASE.match(line)
        if match:
            counts[match.group(3)] += 1
            continue
        match = LOG_CASE_PARALLEL.match(line)
        if match:
            counts[match.group(3)] += 1
    return reasons, counts


def _sample(names, limit=20):
    names = sorted(names)
    shown = ", ".join(f"{suite}.{method}" for suite, method in names[:limit])
    if len(names) > limit:
        shown += f", and {len(names) - limit} more"
    return shown


def command_declared(arguments) -> int:
    total = 0
    for target in arguments.target:
        declared = declared_tests(target)
        total += len(declared)
        print(f"test-verdict: {target}: {len(declared)} test methods declared in the sources")
        if arguments.list:
            for suite, method in sorted(declared):
                print(f"test-verdict:   {suite}.{method}")
    print(f"test-verdict: {total} test methods declared in total")
    return 0


def command_check(arguments) -> int:
    problems: list[str] = []
    grouped = bundle_tests(arguments.result_bundle)

    reasons: dict[tuple[str, str], str] = {}
    log_counts = None
    if arguments.log:
        reasons, log_counts = log_events(arguments.log)

    live_suites = set()
    if arguments.allow_live_engine_gate_skips:
        live_suites = {suite for suite, _ in live_engine_tests().keys()}

    total_executed = 0
    total_passed = 0
    for target in arguments.target:
        declared = declared_tests(target)
        executed = grouped.get(target, [])
        seen = {(row["suite"], row["name"]): row["result"] for row in executed}
        bundle_reasons = {(row["suite"], row["name"]): row["reason"] for row in executed if row.get("reason")}
        total_executed += len(executed)
        total_passed += sum(1 for row in executed if row["result"] == "Passed")

        print(f"test-verdict: {target}: {len(executed)} executed, {len(declared)} declared in the sources")
        by_result: dict[str, int] = {}
        for row in executed:
            by_result[row["result"]] = by_result.get(row["result"], 0) + 1
        for result in sorted(by_result):
            print(f"test-verdict:   {result:<18} {by_result[result]}")

        if not executed:
            problems.append(
                f"{target}: no test from this target executed at all, while {len(declared)} are "
                "declared in its sources. Either the test host died before running anything, or the "
                "target's TestableReference in Orbit.xcodeproj/xcshareddata/xcschemes/Orbit.xcscheme "
                "has skipped = \"YES\", or the target is no longer in the scheme."
            )
            continue

        missing = set(declared) - set(seen)
        unexpected = set(seen) - set(declared)
        if missing:
            problems.append(
                f"{target}: {len(missing)} declared test(s) never executed: {_sample(missing)}. "
                "The sources declare them, so either they did not run or they are not in the target; "
                "Scripts/xcodeproj-sync --check proves the second."
            )
        if unexpected:
            problems.append(
                f"{target}: {len(unexpected)} test(s) executed that the source inventory does not "
                f"know about: {_sample(unexpected)}. Scripts/test_verdict.py derives the expected "
                "count by parsing the sources; a shape it cannot read has to be taught to it, not "
                "worked around, or the count stops being a guard."
            )

        failures = [key for key, result in seen.items() if result == "Failed"]
        if failures:
            problems.append(f"{target}: {len(failures)} test(s) failed: {_sample(failures)}.")

        for key, result in sorted(seen.items()):
            if result != "Skipped":
                continue
            suite, method = key
            # The log is cheap and already parsed; the result bundle always has it, so fall back to that.
            reason = reasons.get(key) or bundle_reasons.get(key)
            if reason is None:
                problems.append(
                    f"{target}: {suite}.{method} was skipped and no reason for it is in the log or the "
                    "result bundle. Pass --log so a skip can be told apart from a test that never ran."
                )
                continue
            print(f"test-verdict:   skipped {suite}.{method}: {reason}")
            if GATE_MARKER in reason:
                if not arguments.allow_live_engine_gate_skips:
                    problems.append(
                        f"{target}: {suite}.{method} skipped on the live-engine gate. This run was "
                        "not told to expect that; pass --allow-live-engine-gate-skips only from a "
                        "job that deliberately runs without a live engine."
                    )
                elif suite not in live_suites:
                    problems.append(
                        f"{target}: {suite}.{method} skipped on the live-engine gate, but "
                        f"{suite} is not a live-engine suite. --allow-live-engine-gate-skips covers "
                        "the live suites only."
                    )
            elif not _source_can_skip(declared.get(key), suite):
                problems.append(
                    f"{target}: {suite}.{method} was skipped, and {suite} calls no XCTSkip anywhere "
                    "in its source. A skip nothing in the test asked for came from the harness or "
                    f"the host, not from the test. Reason recorded: {reason}"
                )

    if log_counts is not None:
        print(
            f"test-verdict: log recorded {log_counts['passed']} passed, "
            f"{log_counts['failed']} failed, {log_counts['skipped']} skipped"
        )
        if log_counts["passed"] != total_passed:
            problems.append(
                f"the log recorded {log_counts['passed']} passes and the result bundle "
                f"{total_passed}. One of the two is not describing this run; do not trust either "
                "until that is explained."
            )

    print(f"test-verdict: {total_executed} test(s) executed over {len(arguments.target)} target(s)")

    if problems:
        print()
        for problem in problems:
            print(f"error: test-verdict: {problem}", file=sys.stderr)
        return 1

    print(f"test-verdict: verdict  every test declared in the sources executed, {total_passed} passed")
    return 0


_SKIP_CAPABILITY: dict[str, bool] = {}


def _source_can_skip(relative_path: str | None, suite: str) -> bool:
    """Whether the file declaring `suite` calls XCTSkip at all."""
    if not relative_path:
        return False
    key = f"{relative_path}:{suite}"
    if key not in _SKIP_CAPABILITY:
        text = "\n".join(_lines(os.path.join(REPO_ROOT, relative_path)))
        _SKIP_CAPABILITY[key] = "XCTSkip" in text
    return _SKIP_CAPABILITY[key]


def live_engine_tests(target_dir: str = "OrbitAppTests") -> dict[tuple[str, str], str]:
    """Every test in a suite gated on the live-engine switch, as (class, method) -> file."""
    declared = declared_tests(target_dir)
    gated_files = set()
    for path in {value for value in declared.values()}:
        text = "\n".join(
            line for line in _lines(os.path.join(REPO_ROOT, path))
            if not line.lstrip().startswith("//")
        )
        if "LiveChromiumEngineHost.isEnabled" in text or 'environment["ORBIT_LIVE_ENGINE"]' in text:
            gated_files.add(path)
    return {key: value for key, value in declared.items() if value in gated_files}


def command_live(arguments) -> int:
    rows = []
    with open(arguments.ledger, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            label, kind, expected, status, log_passed, log_skipped, summary_path, log_path = line.split("\t")
            rows.append({
                "label": label,
                "kind": kind,
                "expected": int(expected),
                "status": int(status),
                "log_passed": int(log_passed),
                "log_skipped": int(log_skipped),
                "summary_path": summary_path,
                "log_path": log_path,
            })

    may_skip = may_skip_declarations(arguments.source_dir)

    print()
    print(f"live-engine-tests: {arguments.configuration} results")

    problems: list[str] = []
    passed = failed = skipped = log_passed = log_skipped = accepted_skips = 0

    for row in rows:
        label = row["label"]
        print(f"live-engine-tests:   {label} ({row['kind']})")
        print(f"live-engine-tests:     xcodebuild exit status  {row['status']}")
        if row["summary_path"] == "-":
            print("live-engine-tests:     result bundle           UNREADABLE")
            problems.append(
                f"{label}: its result bundle could not be read, so nothing about that pass is "
                "established -- the error from xcresulttool is above."
            )
        else:
            with open(row["summary_path"], encoding="utf-8") as handle:
                summary = json.load(handle)
            row["passed"] = summary["passedTests"]
            row["failed"] = summary["failedTests"]
            row["skipped"] = summary["skippedTests"]
            row["result"] = summary["result"]
            passed += row["passed"]
            failed += row["failed"]
            skipped += row["skipped"]
            print(
                f"live-engine-tests:     result bundle           {row['result']}: "
                f"{row['passed']} passed, {row['failed']} failed, {row['skipped']} skipped"
            )
        print(f"live-engine-tests:     log                     {row['log_passed']} passed, {row['log_skipped']} skipped")
        print(f"live-engine-tests:     expected to execute     {row['expected']}")
        log_passed += row["log_passed"]
        log_skipped += row["log_skipped"]

        row["accepted_skips"] = 0
        reasons: dict[tuple[str, str], str] = {}
        if os.path.exists(row["log_path"]):
            reasons, _ = log_events(row["log_path"])
        elif row["log_skipped"]:
            problems.append(
                f"{label}: {row['log_skipped']} test(s) skipped and its log {row['log_path']} is "
                "gone, so why they skipped cannot be established."
            )
        for (suite, method), reason in sorted(reasons.items()):
            if GATE_MARKER in reason:
                problems.append(
                    f"{label}: {suite}.{method} skipped on the live-engine gate ({reason}). The "
                    "live engine was never switched on for that process -- the patched environment "
                    "did not reach the test host -- so this run proves nothing about a real browser. "
                    "That is the exact failure this check exists to catch, and no in-suite "
                    f"'{MAY_SKIP_MARKER}' declaration excuses it."
                )
            elif (suite, method) in may_skip:
                row["accepted_skips"] += 1
                accepted_skips += 1
                print(f"live-engine-tests:     declared skip           {suite}.{method}: {reason}")
            else:
                problems.append(
                    f"{label}: {suite}.{method} skipped without the engine being off and without "
                    f"declaring itself: {reason}. A live test that legitimately cannot run under a "
                    f"live engine says so with a whole-line '// {MAY_SKIP_MARKER} {method}' comment "
                    "in its own source, next to the reason; anything else is coverage going missing "
                    "quietly."
                )

    print(f"live-engine-tests:   totals over {len(rows)} test process(es)")
    print(f"live-engine-tests:     result bundles          {passed} passed, {failed} failed, {skipped} skipped")
    print(f"live-engine-tests:     logs                    {log_passed} passed, {log_skipped} skipped")
    print(f"live-engine-tests:     declared skips accepted {accepted_skips}")
    print(f"live-engine-tests:     expected to execute     {arguments.expected}")

    if len(rows) != arguments.expected_passes:
        problems.append(
            f"{len(rows)} of the {arguments.expected_passes} planned test process(es) recorded a "
            "result. One of them never ran or never reported, so the totals below are not the whole run."
        )
    for row in rows:
        if row["status"] != 0:
            problems.append(f"{row['label']}: xcodebuild exited {row['status']}.")
        if row.get("failed"):
            problems.append(
                f"{row['label']}: {row['failed']} live test(s) failed. The failures are in that pass's "
                "log and result bundle."
            )
        if row.get("result", "Passed") != "Passed":
            problems.append(f"{row['label']}: its result bundle says '{row['result']}'.")
        # Attributed to the pass, so a process that died part-way names the suites that were in it
        # rather than showing up only as a total that does not add up.
        if "passed" in row and row["passed"] + row["accepted_skips"] != row["expected"]:
            problems.append(
                f"{row['label']}: {row['passed']} live test(s) executed there and "
                f"{row['accepted_skips']} declared skip(s) were accepted, against {row['expected']} "
                "expected. That pass did not run everything it was given -- if its host died "
                "part-way, the log ends at the test that killed it."
            )
    if passed + accepted_skips != arguments.expected:
        problems.append(
            f"{passed} live test(s) executed and {accepted_skips} declared skip(s) were accepted, "
            f"against {arguments.expected} expected. Either a suite did not run, or tests were added "
            "or removed without this run seeing them; the expected number is counted from the "
            "sources, so re-run --list to see what it found."
        )
    if log_passed != passed:
        problems.append(
            f"the logs recorded {log_passed} passes and the result bundles {passed}. One of the two "
            "is not describing this run; do not trust either until that is explained."
        )
    if log_skipped != skipped:
        problems.append(
            f"the logs recorded {log_skipped} skips and the result bundles {skipped}. One of the two "
            "is not describing this run; do not trust either until that is explained."
        )

    if problems:
        print()
        for problem in problems:
            print(f"error: live-engine-tests: {arguments.configuration}: {problem}", file=sys.stderr)
        return 1

    verdict = (
        f"live-engine-tests:   verdict                 {passed}/{arguments.expected} live tests "
        f"executed and passed, over {len(rows)} test process(es)"
    )
    if accepted_skips:
        verdict += f", with {accepted_skips} declared skip(s)"
    print(verdict)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="test-verdict", description=__doc__)
    subparsers = parser.add_subparsers(dest="command")

    check = subparsers.add_parser("check", help="verdict for a plain `xcodebuild test` run")
    check.add_argument("--result-bundle", required=True)
    check.add_argument("--log")
    check.add_argument("--target", action="append", default=[], required=True)
    check.add_argument("--allow-live-engine-gate-skips", action="store_true")
    check.set_defaults(handler=command_check)

    live = subparsers.add_parser("live", help="verdict for one Scripts/live-engine-tests configuration")
    live.add_argument("--ledger", required=True)
    live.add_argument("--configuration", required=True)
    live.add_argument("--expected", type=int, required=True)
    live.add_argument("--expected-passes", type=int, required=True)
    live.add_argument("--source-dir", default="OrbitAppTests")
    live.set_defaults(handler=command_live)

    declared = subparsers.add_parser("declared", help="what the sources declare")
    declared.add_argument("--target", action="append", default=[], required=True)
    declared.add_argument("--list", action="store_true")
    declared.set_defaults(handler=command_declared)

    return parser


def main(argv: list[str]) -> int:
    if argv and argv[0].startswith("-") and argv[0] not in ("-h", "--help"):
        argv = ["check"] + argv
    arguments = build_parser().parse_args(argv)
    if not getattr(arguments, "handler", None):
        build_parser().print_help()
        return 2
    if arguments.handler is command_live and arguments.expected < 1:
        print(
            "error: test-verdict: an expected live-test count of "
            f"{arguments.expected} cannot be satisfied by any run. A verdict over zero tests is not "
            "a pass.", file=sys.stderr
        )
        return 2
    try:
        return arguments.handler(arguments)
    except VerdictError as error:
        print(f"error: test-verdict: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
