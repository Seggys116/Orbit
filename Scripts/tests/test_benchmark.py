"""Tests for the pure parts of Scripts/benchmark.py. Nothing here launches a browser.

    python3 -m unittest discover -s Scripts/tests -p 'test_benchmark.py' -v
"""

import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

import benchmark  # noqa: E402

MIB = 1048576
BUNDLE = "/Applications/Fake Browser.app"


def metric(unit, samples, conditions):
    return {
        "unit": unit,
        "conditions": conditions,
        "samples": samples,
        "summary": benchmark.summarize(samples),
    }


def document(label="A", metrics=None, **overrides):
    result = {
        "schema": benchmark.SCHEMA_VERSION,
        "kind": "run",
        "methodology_version": benchmark.METHODOLOGY_VERSION,
        "label": label,
        "created": "2026-01-01T00:00:00+00:00",
        "machine": {"chip": "Apple M2", "macos": "15.0", "ram_bytes": 16 * 1024 ** 3},
        "target": {"name": "Orbit", "version": "1.0", "git_commit": "abcdef0123456789"},
        "parameters": {},
        "methods": {"memory_source": "rusage", "cpu_source": "ps-cputime"},
        "metrics": metrics if metrics is not None else {
            "memory.light.tabs_10": metric("bytes", [100 * MIB], {"page": "light", "tabs": 10}),
        },
    }
    result.update(overrides)
    return result


def fake_table():
    webcontent = (
        "/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/XPCServices/"
        "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
    )
    networking = (
        "/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/XPCServices/"
        "com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
    )
    return [
        benchmark.ProcessEntry(100, 1, BUNDLE + "/Contents/MacOS/Fake Browser"),
        benchmark.ProcessEntry(101, 100, BUNDLE + "/Contents/Frameworks/Fake Helper.app/Contents/MacOS/Fake Helper"),
        benchmark.ProcessEntry(102, 101, "/usr/bin/tool"),
        benchmark.ProcessEntry(200, 1, webcontent),
        benchmark.ProcessEntry(201, 1, networking),
        benchmark.ProcessEntry(300, 1, "/usr/sbin/cfprefsd"),
        benchmark.ProcessEntry(301, 1, "/usr/bin/other"),
    ]


class StatisticsTests(unittest.TestCase):
    def test_median_odd_and_even(self):
        self.assertEqual(benchmark.median([3, 1, 2]), 2.0)
        self.assertAlmostEqual(benchmark.median([1, 2, 3, 4]), 2.5)

    def test_p90_interpolates_between_ranks(self):
        self.assertAlmostEqual(benchmark.p90([1, 2, 3, 4, 5]), 4.6)
        self.assertAlmostEqual(benchmark.p90([5, 4, 3, 2, 1]), 4.6)

    def test_single_sample_is_every_percentile(self):
        self.assertEqual(benchmark.median([7]), 7.0)
        self.assertEqual(benchmark.p90([7]), 7.0)

    def test_empty_samples_are_refused(self):
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.median([])

    def test_summarize(self):
        summary = benchmark.summarize([10, 20, 30, 40, 50])
        self.assertEqual(summary["n"], 5)
        self.assertEqual(summary["min"], 10.0)
        self.assertEqual(summary["max"], 50.0)
        self.assertEqual(summary["median"], 30.0)
        self.assertAlmostEqual(summary["p90"], 46.0)
        self.assertAlmostEqual(summary["mean"], 30.0)
        self.assertEqual(benchmark.summarize([])["n"], 0)

    def test_linear_slope(self):
        points = [(1, 10), (5, 50), (10, 100), (20, 200)]
        self.assertAlmostEqual(benchmark.linear_slope(points), 10.0)

    def test_linear_slope_needs_two_distinct_x(self):
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.linear_slope([(1, 1)])
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.linear_slope([(2, 1), (2, 5)])

    def test_cpu_percent_counts_new_processes_and_ignores_backwards_counters(self):
        before = {1: 1.0, 2: 2.0, 4: 9.0}
        after = {1: 2.0, 3: 0.5, 4: 3.0}
        result = benchmark.cpu_percent(before, after, 2.0)
        self.assertAlmostEqual(result["percent"], 75.0)
        self.assertEqual(result["vanished"], 1)
        self.assertEqual(result["appeared"], 1)

    def test_cpu_percent_needs_a_window(self):
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.cpu_percent({}, {}, 0)

    def test_crosscheck_ratio(self):
        self.assertAlmostEqual(benchmark.crosscheck_ratio({1: 90, 2: 10}, {1: 100}), 0.9)
        self.assertIsNone(benchmark.crosscheck_ratio({1: 90}, {2: 100}))


class ParsingTests(unittest.TestCase):
    def test_parse_cputime_formats(self):
        self.assertAlmostEqual(benchmark.parse_cputime("0:01.50"), 1.5)
        self.assertAlmostEqual(benchmark.parse_cputime("12:34.56"), 754.56)
        self.assertAlmostEqual(benchmark.parse_cputime("1:02:03.50"), 3723.5)
        self.assertAlmostEqual(benchmark.parse_cputime("2-01:00:00.00"), 2 * 86400 + 3600)

    def test_parse_cputime_refuses_garbage(self):
        for text in ("", "12", "a:b", "1:2:3:4"):
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.parse_cputime(text)

    def test_parse_cputime_listing_skips_missing_rows(self):
        listing = "  101   0:01.00\n  102  1:00.25\n\nbroken\n"
        self.assertEqual(benchmark.parse_cputime_listing(listing), {101: 1.0, 102: 60.25})

    def test_parse_process_table_keeps_paths_with_spaces(self):
        text = "  100     1 /Applications/Fake Browser.app/Contents/MacOS/Fake Browser\n  x y z\n  7 1 /sbin/launchd\n"
        table = benchmark.parse_process_table(text)
        self.assertEqual([(entry.pid, entry.ppid) for entry in table], [(100, 1), (7, 1)])
        self.assertEqual(table[0].path, BUNDLE + "/Contents/MacOS/Fake Browser")

    def test_power_state(self):
        self.assertEqual(benchmark.parse_power_source("Now drawing from 'AC Power'\n"), "ac")
        self.assertEqual(benchmark.parse_power_source("Now drawing from 'Battery Power'\n"), "battery")
        self.assertEqual(benchmark.parse_power_source(""), "unknown")
        self.assertTrue(benchmark.parse_low_power_mode(" lowpowermode         1\n"))
        self.assertFalse(benchmark.parse_low_power_mode(" lowpowermode         0\n"))
        self.assertIsNone(benchmark.parse_low_power_mode(""))

    def test_parse_footprint_output(self):
        self.assertEqual(
            benchmark.parse_footprint_output("Fake [1]: 64-bit    Footprint: 123 MB (16384 bytes per page)\n"),
            123 * MIB,
        )
        self.assertEqual(benchmark.parse_footprint_output("Footprint: 1.5 GB"), int(1.5 * 1073741824))
        self.assertIsNone(benchmark.parse_footprint_output("nothing useful"))

    def test_list_parsers(self):
        self.assertEqual(benchmark.parse_int_list("1,5,10,20", "x"), [1, 5, 10, 20])
        for text in ("", "5,1", "1,1", "0,2", "a"):
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.parse_int_list(text, "x")
        self.assertEqual(benchmark.parse_choice_list("light,heavy", benchmark.PAGE_KINDS, "x"), ["light", "heavy"])
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.parse_choice_list("light,bogus", benchmark.PAGE_KINDS, "x")


class ProcessFamilyTests(unittest.TestCase):
    def test_family_follows_bundle_children_and_responsible_process(self):
        owners = {200: 100, 201: 100, 300: 300, 301: 200}
        family = benchmark.discover_family(fake_table(), BUNDLE, lambda pid: owners.get(pid))
        self.assertEqual(set(family), {100, 101, 102, 200, 201, 301})
        self.assertEqual(family[100], "bundle")
        self.assertEqual(family[101], "bundle")
        self.assertEqual(family[102], "child")
        self.assertEqual(family[200], "responsible")
        self.assertNotIn(300, family)

    def test_without_the_responsible_lookup_system_helpers_are_missed(self):
        self.assertEqual(set(benchmark.discover_family(fake_table(), BUNDLE)), {100, 101, 102})

    def test_a_bundle_that_is_not_running_has_no_family(self):
        self.assertEqual(benchmark.discover_family(fake_table(), "/Applications/Other.app"), {})

    def test_roles(self):
        table = {entry.pid: entry.path for entry in fake_table()}
        self.assertEqual(benchmark.role_of(table[100], BUNDLE), "browser")
        self.assertEqual(benchmark.role_of(table[101], BUNDLE), "helper")
        self.assertEqual(benchmark.role_of(table[200], BUNDLE), "webcontent")
        self.assertEqual(benchmark.role_of(table[201], BUNDLE), "networking")
        self.assertEqual(benchmark.role_of(table[300], BUNDLE), "other")
        chromium = "/Applications/Chrome.app/Contents/Frameworks/X.framework/Helpers/Chrome Helper (Renderer).app/Contents/MacOS/Chrome Helper (Renderer)"
        self.assertEqual(benchmark.role_of(chromium, "/Applications/Chrome.app"), "renderer")

    def test_resolve_bundle_by_path_and_substring(self):
        table = fake_table()
        self.assertEqual(benchmark.resolve_bundle(BUNDLE, table), BUNDLE)
        self.assertEqual(benchmark.resolve_bundle(BUNDLE + "/", table), BUNDLE)
        self.assertEqual(benchmark.resolve_bundle("fake browser", table), BUNDLE)
        self.assertEqual(benchmark.resolve_bundle(BUNDLE + "/Contents/MacOS/Fake Browser", table), BUNDLE)

    def test_resolve_bundle_refuses_ambiguity_and_absence(self):
        table = fake_table() + [
            benchmark.ProcessEntry(400, 1, "/Applications/Fake Browser Beta.app/Contents/MacOS/Fake Browser Beta"),
        ]
        with self.assertRaises(benchmark.BenchmarkError) as raised:
            benchmark.resolve_bundle("Fake Browser", table)
        self.assertIn("several app bundles", str(raised.exception))
        self.assertEqual(benchmark.resolve_bundle("Beta", table), "/Applications/Fake Browser Beta.app")
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.resolve_bundle("nonexistent", table)
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.resolve_bundle("/Applications/Nope.app", table)

    def test_detect_engine(self):
        table = fake_table()
        self.assertEqual(benchmark.detect_engine(table), "webkit")
        chromium = [benchmark.ProcessEntry(1, 0, "/A/Chrome.app/Contents/Frameworks/Chrome Helper (Renderer).app/x")]
        self.assertEqual(benchmark.detect_engine(chromium), "chromium")
        self.assertEqual(benchmark.detect_engine([benchmark.ProcessEntry(1, 0, "/A/Mystery.app/Contents/MacOS/m")]), "unknown")

    def test_summarize_family_groups_by_role(self):
        summary = benchmark.summarize_family(
            {1: 100, 2: 50, 3: 25}, {1: "browser", 2: "webcontent", 3: "webcontent"}
        )
        self.assertEqual(summary["total_bytes"], 175)
        self.assertEqual(summary["by_role"], {"browser": 100, "webcontent": 75})
        self.assertEqual(summary["process_count"], 3)

    def test_read_family_memory_adds_probe_processes_and_cross_checks(self):
        entries = {entry.pid: entry for entry in fake_table()}

        class Sampler:
            bundle = BUNDLE

            def discover(self, probe_roles=None):
                family = {100: "bundle"}
                for pid in probe_roles or {}:
                    if pid in entries and pid not in family:
                        family[pid] = "probe"
                return family, entries

        class Reader:
            name = "stub"

            def read(self, pids):
                return {pid: {100: 1000, 200: 3000}[pid] for pid in pids if pid in (100, 200)}

        status = {
            "processes": [
                {"pid": 100, "role": "browser", "footprintBytes": 1000},
                {"pid": 200, "role": "webContent", "footprintBytes": 3000},
            ],
            "liveRenderers": 2,
        }
        summary = benchmark.read_family_memory(Sampler(), Reader(), status)
        self.assertEqual(summary["total_bytes"], 4000)
        self.assertEqual(summary["by_role"], {"browser": 1000, "webcontent": 3000})
        self.assertEqual(summary["probe_only"], [200])
        self.assertAlmostEqual(summary["crosscheck_ratio"], 1.0)
        self.assertEqual(summary["live_renderers"], 2)
        self.assertEqual(summary["unreadable"], [])


class MetricTests(unittest.TestCase):
    def test_observation_metrics(self):
        series = [{"t": 0, "bytes": 100}, {"t": 30, "bytes": 110}, {"t": 60, "bytes": 130}]
        entries = benchmark.observation_metrics("mixed", 10, series, [1.0, 2.0], 30.0)
        by_id = {}
        for metric_id, value, unit, conditions in entries:
            by_id.setdefault(metric_id, []).append((value, unit, conditions))
        self.assertEqual([item[0] for item in by_id["memory.mixed.tabs_10"]], [100, 110, 130])
        self.assertEqual([item[0] for item in by_id["cpu_idle.mixed.tabs_10"]], [1.0, 2.0])
        self.assertEqual(by_id["cpu_idle.mixed.tabs_10"][0][2]["window_s"], 30.0)
        growth = by_id["memory_growth.mixed.tabs_10"][0]
        self.assertEqual(growth[0], 30)
        self.assertEqual(growth[2]["duration_s"], 60)
        rate = by_id["memory_growth_rate.mixed.tabs_10"][0]
        self.assertAlmostEqual(rate[0], 30.0)
        self.assertEqual(rate[1], "bytes_per_minute")

    def test_a_single_reading_has_no_growth(self):
        entries = benchmark.observation_metrics("light", 1, [{"t": 0, "bytes": 5}], [], 30.0)
        self.assertEqual([entry[0] for entry in entries], ["memory.light.tabs_1"])

    def test_aggregate_attempts_concatenates_samples(self):
        first = benchmark.Recorder()
        first.add("launch_cold_ms", 100, "ms", {"page": "light", "purged": False})
        second = benchmark.Recorder()
        second.add("launch_cold_ms", 300, "ms", {"page": "light", "purged": False})
        second.add("launch_cold_ms", 200, "ms", {"page": "light", "purged": False})
        metrics = benchmark.aggregate_attempts([
            {"samples": first.samples, "specs": first.specs},
            {"samples": second.samples, "specs": second.specs},
        ])
        entry = metrics["launch_cold_ms"]
        self.assertEqual(entry["samples"], [100.0, 300.0, 200.0])
        self.assertEqual(entry["summary"]["n"], 3)
        self.assertEqual(entry["summary"]["median"], 200.0)

    def test_a_metric_cannot_change_definition_between_attempts(self):
        first = benchmark.Recorder()
        first.add("x", 1, "ms", {"page": "light"})
        second = benchmark.Recorder()
        second.add("x", 1, "ms", {"page": "heavy"})
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.aggregate_attempts([
                {"samples": first.samples, "specs": first.specs},
                {"samples": second.samples, "specs": second.specs},
            ])

    def test_recorder_refuses_unknown_units(self):
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.Recorder().add("x", 1, "furlongs", {})


class SchemaTests(unittest.TestCase):
    def test_a_well_formed_document_is_valid(self):
        self.assertEqual(benchmark.validate_document(document()), [])

    def test_schema_mismatch_is_refused(self):
        problems = benchmark.validate_document(document(schema=2))
        self.assertTrue(any("schema" in problem for problem in problems))
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.require_valid(document(schema=2), "x.json")

    def test_missing_keys_and_bad_metrics_are_reported(self):
        broken = document()
        del broken["machine"]
        self.assertTrue(any("machine" in problem for problem in benchmark.validate_document(broken)))
        bad = document(metrics={"m": {"unit": "ms", "conditions": {}, "samples": [1, 2], "summary": {"n": 3}}})
        self.assertTrue(any("summary" in problem for problem in benchmark.validate_document(bad)))
        unitless = document(metrics={"m": metric("furlongs", [1], {})})
        self.assertTrue(any("unit" in problem for problem in benchmark.validate_document(unitless)))
        empty = document(metrics={"m": {"unit": "ms", "conditions": {}, "samples": [], "summary": {"n": 0}}})
        self.assertTrue(any("samples" in problem for problem in benchmark.validate_document(empty)))

    def test_write_then_load_round_trips_and_load_refuses_other_schemas(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "nested", "result.json")
            benchmark.write_document(document(), path)
            self.assertEqual(benchmark.load_document(path)["label"], "A")
            stale = os.path.join(directory, "stale.json")
            with open(stale, "w", encoding="utf-8") as handle:
                json.dump(document(schema=99), handle)
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.load_document(stale)
            garbage = os.path.join(directory, "garbage.json")
            with open(garbage, "w", encoding="utf-8") as handle:
                handle.write("{not json")
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.load_document(garbage)
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.load_document(os.path.join(directory, "missing.json"))

    def test_writing_an_invalid_document_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.write_document(document(schema=2), os.path.join(directory, "x.json"))
            self.assertEqual(os.listdir(directory), [])


class CompareTests(unittest.TestCase):
    def test_table_shows_both_medians_and_the_percentage_difference(self):
        a = document("Orbit", {"memory.light.tabs_10": metric("bytes", [100 * MIB], {"page": "light", "tabs": 10})})
        b = document("Other", {"memory.light.tabs_10": metric("bytes", [150 * MIB], {"page": "light", "tabs": 10})})
        text = benchmark.compare_documents([a, b], ["a.json", "b.json"])
        self.assertIn("| Metric | A | B | B vs A |", text)
        self.assertIn("100.0 MiB", text)
        self.assertIn("150.0 MiB", text)
        self.assertIn("+50.0%", text)
        self.assertNotIn("## Not comparable", text)
        self.assertIn("must cite the result files", text)

    def test_negative_difference(self):
        a = document("A", {"launch_cold_ms": metric("ms", [200.0], {"page": "light"})})
        b = document("B", {"launch_cold_ms": metric("ms", [150.0], {"page": "light"})})
        self.assertIn("-25.0%", benchmark.compare_documents([a, b], ["a.json", "b.json"]))

    def test_different_conditions_are_not_comparable(self):
        a = document("A", {"memory.light.tabs_10": metric("bytes", [100 * MIB], {"page": "light", "tabs": 10})})
        b = document("B", {"memory.light.tabs_10": metric("bytes", [90 * MIB], {"page": "light", "tabs": 11})})
        text = benchmark.compare_documents([a, b], ["a.json", "b.json"])
        self.assertIn("not comparable", text)
        self.assertIn("## Not comparable", text)
        self.assertIn("tabs 10 vs 11", text)
        self.assertNotIn("%", text.split("## Not comparable")[0].split("| Metric")[1])

    def test_different_memory_sources_are_not_comparable(self):
        a = document("A")
        b = document("B", methods={"memory_source": "rss", "cpu_source": "ps-cputime"})
        text = benchmark.compare_documents([a, b], ["a.json", "b.json"])
        self.assertIn("memory_source differs", text)

    def test_metrics_in_one_file_are_listed_separately(self):
        a = document("A", {
            "memory.light.tabs_10": metric("bytes", [100 * MIB], {"page": "light", "tabs": 10}),
            "launch_cold_ms": metric("ms", [100.0], {"page": "light"}),
        })
        b = document("B")
        text = benchmark.compare_documents([a, b], ["a.json", "b.json"])
        self.assertIn("## Present in only one file", text)
        self.assertIn("`launch_cold_ms` only in A", text)

    def test_mismatched_versions_are_refused(self):
        a = document("A")
        for override in ({"methodology_version": "999"}, {"schema": 2}):
            b = document("B", **override)
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.compare_documents([a, b], ["a.json", "b.json"])

    def test_machine_differences_are_called_out(self):
        a = document("A")
        b = document("B", machine={"chip": "Apple M4", "macos": "15.0", "ram_bytes": 16 * 1024 ** 3})
        text = benchmark.compare_documents([a, b], ["a.json", "b.json"])
        self.assertIn("different chip", text)

    def test_three_files_compare_against_the_first(self):
        docs = [
            document("A", {"launch_cold_ms": metric("ms", [100.0], {"page": "light"})}),
            document("B", {"launch_cold_ms": metric("ms", [200.0], {"page": "light"})}),
            document("C", {"launch_cold_ms": metric("ms", [50.0], {"page": "light"})}),
        ]
        text = benchmark.compare_documents(docs, ["a.json", "b.json", "c.json"])
        self.assertIn("| Metric | A | B | C | B vs A | C vs A |", text)
        self.assertIn("+100.0%", text)
        self.assertIn("-50.0%", text)

    def test_format_value(self):
        self.assertEqual(benchmark.format_value("ms", 12.34), "12.3 ms")
        self.assertEqual(benchmark.format_value("bytes", 3 * MIB), "3.0 MiB")
        self.assertEqual(benchmark.format_value("percent", 1.234), "1.23 %")
        self.assertEqual(benchmark.format_value("bytes", None), "-")


class PageTests(unittest.TestCase):
    def test_every_page_reports_its_own_painted_frame(self):
        for kind in benchmark.PAGE_KINDS:
            html = benchmark.build_page(kind, "tab-7").decode("utf-8")
            self.assertIn("/beacon?id=tab-7", html)
            self.assertIn("requestAnimationFrame", html)
            self.assertIn(f"Orbit benchmark {kind} tab-7", html)

    def test_weights_differ_as_documented(self):
        light = benchmark.build_page("light", "x")
        medium = benchmark.build_page("medium", "x").decode("utf-8")
        heavy = benchmark.build_page("heavy", "x").decode("utf-8")
        self.assertEqual(medium.count('class="row"'), benchmark.MEDIUM_ROWS)
        self.assertGreater(len(medium), 50 * len(light))
        self.assertIn(f"i<{benchmark.HEAVY_RECORDS}", heavy)
        self.assertIn(f"Float64Array({benchmark.HEAVY_BUFFER_LENGTH})", heavy)
        self.assertNotIn("setInterval", heavy)
        self.assertNotIn("setTimeout", heavy)

    def test_heavy_script_braces_balance(self):
        heavy = benchmark.build_page("heavy", "x").decode("utf-8")
        script = heavy.split("<script>")[1].split("</script>")[0]
        self.assertEqual(script.count("{"), script.count("}"))
        self.assertEqual(script.count("("), script.count(")"))

    def test_hostile_identifiers_and_unknown_kinds_are_refused(self):
        for identifier in ("", "a b", "<script>", "x" * 65, "a/b"):
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.build_page("light", identifier)
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.build_page("enormous", "x")

    def test_mixed_cycles_the_three_weights(self):
        kinds = [benchmark.page_kind_for(index, "mixed") for index in range(6)]
        self.assertEqual(kinds, list(benchmark.PAGE_KINDS) * 2)
        self.assertEqual(benchmark.page_kind_for(4, "heavy"), "heavy")


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.server = benchmark.BenchServer()
        self.server.start()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def tearDown(self):
        self.server.stop()

    def test_serves_pages_and_records_beacons(self):
        self.assertTrue(self.server.base_url.startswith("http://127.0.0.1:"))
        with self.opener.open(self.server.page_url("light", "t1"), timeout=5) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertIn(b"Orbit benchmark light t1", response.read())
        self.assertIsNone(self.server.wait_painted("t1", 0.05))
        with self.opener.open(self.server.base_url + "/beacon?id=t1", timeout=5) as response:
            self.assertEqual(response.status, 204)
        self.assertIsNotNone(self.server.wait_painted("t1", 1.0))

    def test_first_beacon_wins(self):
        self.server.record_painted("t2", 10.0)
        self.server.record_painted("t2", 20.0)
        self.assertEqual(self.server.wait_painted("t2", 0.1), 10.0)

    def test_bad_requests_are_refused(self):
        for path in ("/page/light?id=a%20b", "/page/enormous?id=x", "/beacon?id=%3Cb%3E"):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.opener.open(self.server.base_url + path, timeout=5)
            self.assertEqual(raised.exception.code, 400)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.opener.open(self.server.base_url + "/elsewhere", timeout=5)
        self.assertEqual(raised.exception.code, 404)


class ProbeInventoryTests(unittest.TestCase):
    def test_the_app_declares_every_command_the_script_sends(self):
        declared = benchmark.declared_bench_commands()
        for name in benchmark.USED_COMMANDS:
            self.assertIn(name, declared)

    def test_the_smoke_inventory_is_untouched_by_the_benchmark_commands(self):
        stages, checks = benchmark.smoke.inventory()
        for name in benchmark.USED_COMMANDS:
            self.assertNotIn(name, stages)
            self.assertNotIn(name, checks)


if __name__ == "__main__":
    unittest.main()
