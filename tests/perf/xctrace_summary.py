#!/usr/bin/env python3
"""Text summary of an Instruments trace exported by run_perf.sh --xctrace.

Usage:
  xctrace_summary.py <outdir>
  xctrace_summary.py --intervals F --hangs F --profile F [--process NAME] [--top N]

<outdir> is a run_perf.sh output directory holding trace-intervals.xml
(OSSignpostIntervals), trace-hangs.xml (potential-hangs) and
trace-time-profile.xml (time-profile), all from `xcrun xctrace export`.

Prints:
  - signpost intervals by name (count, total, p50, p95, max), for the app's
    subsystem, over the whole trace and per benchmark scenario (the
    "Scenario" Points of Interest intervals)
  - potential hangs reported by Instruments
  - the main thread's heaviest functions by self time and by inclusive time,
    over the whole trace and inside the scenario windows
"""
import argparse
import collections
import math
import os
import sys
import xml.etree.ElementTree as ET


class RefTable:
    """Resolves the id/ref de-duplication used by xctrace exports."""

    def __init__(self):
        self.by_id = {}

    def resolve(self, el):
        ref = el.get("ref")
        if ref is not None:
            return self.by_id.get(ref, el)
        if el.get("id") is not None:
            self.by_id[el.get("id")] = el
        return el

    def register_tree(self, el):
        for sub in el.iter():
            if sub.get("id") is not None and sub.get("ref") is None:
                self.by_id[sub.get("id")] = sub


def rows(path):
    """Yields (columns, resolved child elements) for each row of a table export."""
    refs = RefTable()
    mnemonics = []
    for event, el in ET.iterparse(path, events=("end",)):
        if el.tag == "mnemonic":
            mnemonics.append(el.text)
        elif el.tag == "row":
            refs.register_tree(el)
            yield mnemonics, [refs.resolve(c) for c in el], refs


def text_of(el):
    if el is None:
        return ""
    if el.text and el.text.strip():
        return el.text.strip()
    return el.get("fmt", "")


def pct(values, q):
    if not values:
        return 0.0
    v = sorted(values)
    return v[max(0, min(len(v) - 1, math.ceil(q * len(v)) - 1))]


def load_intervals(path, process):
    out = []
    if not path or not os.path.exists(path):
        return out
    for cols, cells, _refs in rows(path):
        rec = dict(zip(cols, cells))
        proc = text_of(rec.get("process"))
        sub = text_of(rec.get("subsystem"))
        if sub and sub != "org.nextpadplusplus.mac":
            continue
        if process and process not in proc and process not in rec.get("process", ET.Element("x")).get("fmt", ""):
            continue
        try:
            start = int(text_of(rec.get("start")))
            dur = int(text_of(rec.get("duration")))
        except ValueError:
            continue
        name = text_of(rec.get("name"))
        msg = rec.get("start-message")
        out.append({
            "name": name,
            "category": text_of(rec.get("category")),
            "start": start,
            "dur": dur,
            "message": msg.get("fmt", "") if msg is not None else "",
        })
    return out


def load_hangs(path):
    out = []
    if not path or not os.path.exists(path):
        return out
    for cols, cells, _refs in rows(path):
        rec = dict(zip(cols, cells))
        try:
            out.append((int(text_of(rec.get("start"))), int(text_of(rec.get("duration"))),
                        text_of(rec.get("hang-type")), rec.get("thread").get("fmt", "") if rec.get("thread") is not None else ""))
        except ValueError:
            pass
    return out


def load_profile(path, process):
    """Returns a list of (time_ns, weight_ns, frames leaf-first) for main-thread samples."""
    samples = []
    if not path or not os.path.exists(path):
        return samples
    stacks = {}
    for cols, cells, refs in rows(path):
        rec = dict(zip(cols, cells))
        thread = rec.get("thread")
        tfmt = thread.get("fmt", "") if thread is not None else ""
        if "Main Thread" not in tfmt:
            continue
        if process and process not in tfmt:
            continue
        bt = rec.get("stack")
        if bt is None:
            continue
        key = bt.get("id") or bt.get("ref")
        frames = stacks.get(key)
        if frames is None:
            frames = []
            for fr in bt.iter("frame"):
                fr = refs.resolve(fr)
                name = fr.get("name") or fr.get("addr") or "?"
                binary = None
                for b in fr.iter("binary"):
                    binary = refs.resolve(b).get("name")
                    break
                frames.append((name, binary or ""))
            stacks[key] = frames
        try:
            t = int(text_of(rec.get("time")))
            w = int(text_of(rec.get("weight")) or 1000000)
        except ValueError:
            continue
        samples.append((t, w, frames))
    return samples


def print_intervals(title, intervals):
    by = collections.defaultdict(list)
    for iv in intervals:
        by[iv["name"]].append(iv["dur"] / 1e6)
    if not by:
        return
    print(f"\n{title}")
    print(f"  {'name':48} {'count':>7} {'total ms':>10} {'p50 ms':>8} {'p95 ms':>8} {'max ms':>8}")
    for name, d in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        print(f"  {name[:48]:48} {len(d):7d} {sum(d):10.1f} {pct(d, .5):8.3f} {pct(d, .95):8.3f} {max(d):8.3f}")


def print_profile(title, samples, top, app_binary):
    if not samples:
        return
    total = sum(w for _t, w, _f in samples)
    selfw = collections.Counter()
    incl = collections.Counter()
    app_incl = collections.Counter()
    lib_self = collections.Counter()
    for _t, w, frames in samples:
        if frames:
            selfw[frames[0][0]] += w
            lib_self[frames[0][1]] += w
        names = set(f[0] for f in frames)
        for n in names:
            incl[n] += w
        for n in set(f[0] for f in frames if f[1] == app_binary):
            app_incl[n] += w
    print(f"\n{title}: {len(samples)} main-thread samples, {total / 1e6:.0f} ms")
    print("  self time by function:")
    for f, w in selfw.most_common(top):
        print(f"    {w / 1e6:9.1f} ms {100 * w / total:5.1f}%  {f}")
    print("  self time by binary:")
    for f, w in lib_self.most_common(min(top, 12)):
        print(f"    {w / 1e6:9.1f} ms {100 * w / total:5.1f}%  {f or '?'}")
    print(f"  inclusive time, functions in {app_binary} (app, Scintilla, Lexilla):")
    for f, w in app_incl.most_common(top):
        print(f"    {w / 1e6:9.1f} ms {100 * w / total:5.1f}%  {f}")
    print("  inclusive time, all functions below 98% (skips run loop frames):")
    shown = 0
    for f, w in incl.most_common():
        if w >= 0.98 * total:
            continue
        print(f"    {w / 1e6:9.1f} ms {100 * w / total:5.1f}%  {f}")
        shown += 1
        if shown >= top:
            break


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", nargs="?")
    ap.add_argument("--intervals")
    ap.add_argument("--hangs")
    ap.add_argument("--profile")
    ap.add_argument("--process", default="NextpadPerf")
    ap.add_argument("--top", type=int, default=25)
    a = ap.parse_args()
    if a.outdir:
        a.intervals = a.intervals or os.path.join(a.outdir, "trace-intervals.xml")
        a.hangs = a.hangs or os.path.join(a.outdir, "trace-hangs.xml")
        a.profile = a.profile or os.path.join(a.outdir, "trace-time-profile.xml")

    intervals = load_intervals(a.intervals, a.process)
    scenarios = []
    seen = set()
    for iv in intervals:
        key = (iv["start"], iv["message"])
        if iv["name"] == "Scenario" and key not in seen:
            seen.add(key)
            scenarios.append(iv)
    print_intervals("Signpost intervals (whole trace)", [iv for iv in intervals if iv["name"] != "Scenario"])
    for sc in scenarios:
        lo, hi = sc["start"], sc["start"] + sc["dur"]
        inside = [iv for iv in intervals if iv["name"] != "Scenario" and lo <= iv["start"] < hi]
        print_intervals(f"Signpost intervals in scenario {sc['message']} ({sc['dur'] / 1e6:.0f} ms)", inside)

    hangs = load_hangs(a.hangs)
    if hangs:
        print("\nPotential hangs (Instruments):")
        for start, dur, kind, thread in hangs:
            where = ""
            for sc in scenarios:
                if sc["start"] <= start < sc["start"] + sc["dur"]:
                    where = f" during {sc['message']}"
            print(f"  {start / 1e9:8.3f} s  {dur / 1e6:8.1f} ms  {kind}{where}  {thread}")

    samples = load_profile(a.profile, a.process)
    print_profile("Time profile (whole trace)", samples, a.top, a.process)
    if scenarios:
        windows = [(sc["start"], sc["start"] + sc["dur"]) for sc in scenarios]
        inside = [s for s in samples if any(lo <= s[0] < hi for lo, hi in windows)]
        print_profile("Time profile (scenario windows only)", inside, a.top, a.process)


if __name__ == "__main__":
    sys.exit(main())
