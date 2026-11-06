#!/usr/bin/env python3
"""Side-by-side comparison of Nextpad++ performance reports.

Usage:
  compare.py REPORT_OR_DIR [REPORT_OR_DIR ...]
  compare.py NAME=PATH[,PATH...] NAME=PATH[,PATH...] ...

Each argument is one column. A directory stands for every report.json below
it, so a column can hold several runs (repetitions); the column then shows
the median over its runs, and with --spread also the 95th percentile and the
range. A NAME=... prefix names the column; otherwise the column is named
after the report's directory.

Options:
  --scenario NAME[,NAME]   only these scenarios
  --stat NAME[:FIELD]      add a probe aggregate row (repeatable). FIELD is a
                           key of the aggregate: p50_ms, p95_ms, max_ms,
                           total_ms, count (durations); p50, p95, max, sum,
                           mean (values); total, calls (counters).
                           Default field: p95_ms, p95 or total by kind.
  --all-stats              add a row for every aggregate present
  --spread                 show p95 and min..max across runs in each column
  --markdown               Markdown table output

The first column is the baseline; every other column shows the change
relative to it. Each scenario's end state (first visible line, x offset,
caret) is compared across all runs, and a mismatch is reported, since the
scenarios are meant to be identical run to run.
"""
import argparse
import json
import math
import os
import statistics
import sys

SUMMARY_ROWS = [
    ("durationMs", "duration ms"),
    ("mainThreadCpuMs", "main thread CPU ms"),
    ("cpuMs", "process CPU ms"),
    ("frameP50Ms", "frame p50 ms"),
    ("frameP95Ms", "frame p95 ms"),
    ("frameP99Ms", "frame p99 ms"),
    ("frameMaxMs", "frame max ms"),
    ("droppedFrames", "dropped frames"),
    ("droppedPct", "dropped %"),
    ("hitches", "hitches >16.7ms"),
    ("hitchMaxMs", "hitch max ms"),
    ("hitchTotalMs", "hitch total ms"),
    ("displayCycleP95Ms", "display cycle p95 ms"),
    ("busyIterationP95Ms", "busy iteration p95 ms"),
    ("contentDraws", "content draws"),
    ("contentDrawP50Ms", "content draw p50 ms"),
    ("contentDrawP95Ms", "content draw p95 ms"),
    ("contentDrawMaxMs", "content draw max ms"),
    ("contentDrawTotalMs", "content draw total ms"),
    ("marginDrawP95Ms", "margin draw p95 ms"),
    ("scrollEvents", "scroll events"),
    ("scrollEventP95Ms", "scroll event p95 ms"),
    ("updateUIP95Ms", "SCN_UPDATEUI p95 ms"),
    ("updateUITotalMs", "SCN_UPDATEUI total ms"),
]

OPEN_ROWS = [
    ("loadFileMs", "load file ms"),
    ("processStartToMainMs", "process start to main ms"),
    ("didFinishLaunchingMs", "didFinishLaunching ms"),
    ("loadEndToFirstPaintMs", "load end to first paint ms"),
    ("firstPaintMs", "first paint ms"),
    ("processStartToFirstPaintMs", "process start to first paint ms"),
    ("loadEndToFirstFullPaintMs", "load end to first full paint ms"),
    ("firstFullPaintMs", "first full paint ms"),
    ("processStartToFirstFullPaintMs", "process start to first full paint ms"),
    ("processStartToFirstFrameTickMs", "process start to first frame ms"),
    ("processStartToSettledMs", "process start to settled ms"),
]

DEFAULT_STATS = [
    "SCIContentView.drawRect:p95_ms",
    "EditView.PaintText:p95_ms",
    "EditView.LayoutLine.full:count",
    "PositionCache.miss:total",
    "CoreText.CTLineCreate:count",
    "EditorView.SCN.UpdateUI:p95_ms",
    "MainWindowController.editorCursorMoved:total_ms",
    "RunLoop.displayCycle:p95_ms",
]


def find_reports(path):
    if os.path.isfile(path):
        return [path]
    out = []
    for root, _dirs, files in os.walk(path):
        if "report.json" in files:
            out.append(os.path.join(root, "report.json"))
    return sorted(out)


def load_columns(args):
    cols = []
    for arg in args:
        name = None
        if "=" in arg and not os.path.exists(arg):
            name, arg = arg.split("=", 1)
        paths = []
        for p in arg.split(","):
            paths.extend(find_reports(p))
        if not paths:
            sys.exit(f"no report.json found for {arg}")
        reports = []
        for p in paths:
            with open(p) as f:
                reports.append(json.load(f))
        if name is None:
            base = os.path.dirname(paths[0]) if len(paths) == 1 else arg.rstrip("/")
            name = os.path.basename(base) or base
        cols.append((name, reports))
    return cols


def scenario_runs(report, name):
    return [s for s in report.get("scenarios", []) if s.get("name") == name]


def stat_value(scn, spec):
    name, _, field = spec.partition(":")
    st = scn.get("stats", {}).get(name)
    if st is None:
        return None
    if not field:
        field = {"duration": "p95_ms", "value": "p95", "counter": "total"}.get(st.get("kind"), "count")
    v = st.get(field)
    return float(v) if isinstance(v, (int, float)) else None


def summary_value(scn, key):
    v = scn.get("summary", {}).get(key)
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, dict):
        # Load.* phases are reported as aggregates in the open summary.
        for k in ("total_ms", "total", "p50"):
            if isinstance(v.get(k), (int, float)):
                return float(v[k])
    return None


def pct(vals, q):
    vals = sorted(vals)
    idx = max(0, min(len(vals) - 1, math.ceil(q * len(vals)) - 1))
    return vals[idx]


def fmt(v):
    if v is None:
        return "-"
    if abs(v) >= 1000:
        return f"{v:,.0f}"
    if abs(v) >= 100:
        return f"{v:.1f}"
    return f"{v:.2f}"


def cell(vals, spread):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None, "-"
    med = statistics.median(vals)
    text = fmt(med)
    if spread and len(vals) > 1:
        text += f" (p95 {fmt(pct(vals, 0.95))}, {fmt(min(vals))}..{fmt(max(vals))})"
    return med, text


def delta(base, v):
    if base is None or v is None:
        return ""
    if base == 0:
        return "" if v == 0 else " (new)"
    return f" ({(v - base) / abs(base) * 100:+.1f}%)"


def render(title, header, rows, markdown):
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    if markdown:
        print(f"\n### {title}\n")
        print("| " + " | ".join(header) + " |")
        print("|" + "|".join("---" for _ in header) + "|")
        for r in rows:
            print("| " + " | ".join(str(c) for c in r) + " |")
    else:
        print(f"\n== {title} ==")
        print("  ".join(str(h).ljust(widths[i]) for i, h in enumerate(header)))
        for r in rows:
            print("  ".join(str(c).ljust(widths[i]) if i == 0 else str(c).rjust(widths[i])
                            for i, c in enumerate(r)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--scenario")
    ap.add_argument("--stat", action="append", default=[])
    ap.add_argument("--all-stats", action="store_true")
    ap.add_argument("--spread", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    a = ap.parse_args()

    cols = load_columns(a.inputs)
    order = []
    for _, reports in cols:
        for r in reports:
            for s in r.get("scenarios", []):
                if s.get("name") not in order:
                    order.append(s.get("name"))
    if a.scenario:
        wanted = a.scenario.split(",")
        order = [n for n in order if n in wanted]

    header = ["metric"] + [f"{name} (n={len(reports)})" for name, reports in cols]
    print("columns:")
    for name, reports in cols:
        envs = [r.get("environment", {}) for r in reports]
        e = envs[0] if envs else {}
        print(f"  {name}: {len(reports)} run(s), commit {e.get('buildCommit')}{'+dirty' if e.get('buildDirty') else ''}"
              f" {e.get('buildType')}, file {os.path.basename(e.get('file', ''))}"
              f" ({e.get('lines')} lines, largeFileMode={e.get('largeFileMode')}),"
              f" {e.get('measuredRefreshHz', 0):.0f} Hz {e.get('frameClock')}, perf level {e.get('perfLevel')}")
        errs = [err for r in reports for err in r.get("errors", [])]
        for err in sorted(set(errs)):
            print(f"    error: {err}")

    for scn_name in order:
        is_open = scn_name == "open"
        specs = []
        for key, label in (OPEN_ROWS if is_open else SUMMARY_ROWS):
            specs.append((label, lambda s, k=key: summary_value(s, k)))
        if is_open:
            keys = set()
            for _, reports in cols:
                for r in reports:
                    for s in scenario_runs(r, "open"):
                        keys.update(k for k in s.get("summary", {}) if k.startswith("Load."))
            for k in sorted(keys):
                specs.append((k + " ms", lambda s, k=k: summary_value(s, k)))
        stat_specs = list(a.stat) or ([] if is_open else DEFAULT_STATS)
        if a.all_stats:
            names = set()
            for _, reports in cols:
                for r in reports:
                    for s in scenario_runs(r, scn_name):
                        names.update(s.get("stats", {}).keys())
            stat_specs = sorted(names)
        for spec in stat_specs:
            specs.append((spec, lambda s, sp=spec: stat_value(s, sp)))

        rows = []
        for label, getter in specs:
            row = [label]
            base = None
            any_value = False
            for ci, (_, reports) in enumerate(cols):
                vals = [getter(s) for r in reports for s in scenario_runs(r, scn_name)]
                med, text = cell(vals, a.spread)
                any_value = any_value or med is not None
                if ci == 0:
                    base = med
                    row.append(text)
                else:
                    row.append(text + delta(base, med))
            if any_value:
                rows.append(row)
        render(scn_name, header, rows, a.markdown)

        # Determinism check over every run of this scenario.
        states = set()
        for _, reports in cols:
            for r in reports:
                for s in scenario_runs(r, scn_name):
                    es = s.get("endState", {})
                    states.add((es.get("firstVisibleLine"), es.get("xOffset"), es.get("caret")))
        if len(states) > 1 and not is_open:
            print(f"  warning: end state differs across runs (firstVisibleLine, xOffset, caret): {sorted(states, key=str)}")
        # A window that was not visible (screen locked, display asleep,
        # covered) is not paced by the display: its frame numbers do not
        # describe scrolling.
        hidden = []
        for name, reports in cols:
            n = sum(1 for r in reports for s in scenario_runs(r, scn_name)
                    if s.get("endState", {}).get("windowVisible") is False)
            if n:
                hidden.append(f"{name} {n}")
        if hidden:
            print(f"  warning: window not visible at the end of the scenario (runs per column: {', '.join(hidden)});"
                  " frame and paint numbers from those runs are not valid")


if __name__ == "__main__":
    main()
