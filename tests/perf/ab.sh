#!/bin/bash
# Interleaved A/B benchmark of two (or more) app builds.
#
# Usage:
#   tests/perf/ab.sh [options] NAME=<app> NAME=<app> [...] <file> <scenario> <outdir>
#
# Runs every build once per round, in order (A, B, A, B, ...), so slow drift
# on the machine (thermal state, other builds) lands on both sides. Each run
# is a fresh process through run_perf.sh; reports go to
# <outdir>/<NAME>/<round>/report.json, and the comparison table (medians, p95
# and range over the rounds) to <outdir>/compare.txt.
#
# Options:
#   --reps N        rounds (default 5)
#   --lock FILE     take this lock (lockf -k) around each run, so other
#                   benchmarks on the machine do not overlap
#   --              everything after this goes to run_perf.sh (for example
#                   --level 0 --window 1440x900)
#
# Example (both builds with probes off, five rounds, shared lock):
#   tests/perf/ab.sh --reps 5 --lock "$NPP_PERF_SCRATCH/bench.lock" \
#       base=../base/build/Nextpad++.app diag=build-release/Nextpad++.app \
#       big.txt smooth_scroll,page_down /tmp/ab -- --level 0

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPS=5
LOCK=""
BUILDS=()
POS=()
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --reps) REPS="$2"; shift ;;
        --lock) LOCK="$2"; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
        *=*) BUILDS+=("$1") ;;
        *) POS+=("$1") ;;
    esac
    shift
done
[ ${#BUILDS[@]} -ge 1 ] && [ ${#POS[@]} -eq 3 ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
FILE="${POS[0]}"; SCEN="${POS[1]}"; OUT="${POS[2]}"
mkdir -p "$OUT"

for round in $(seq 1 "$REPS"); do
    for b in "${BUILDS[@]}"; do
        name="${b%%=*}"; app="${b#*=}"
        dest="$OUT/$name/$round"
        mkdir -p "$dest"
        echo "== round $round/$REPS: $name"
        if [ -n "$LOCK" ]; then
            /usr/bin/lockf -k "$LOCK" "$HERE/run_perf.sh" ${EXTRA[@]+"${EXTRA[@]}"} --label "$name" "$app" "$FILE" "$SCEN" "$dest"
        else
            "$HERE/run_perf.sh" ${EXTRA[@]+"${EXTRA[@]}"} --label "$name" "$app" "$FILE" "$SCEN" "$dest"
        fi
    done
done

ARGS=()
for b in "${BUILDS[@]}"; do ARGS+=("${b%%=*}=$OUT/${b%%=*}"); done
python3 -I "$HERE/compare.py" --spread "${ARGS[@]}" | tee "$OUT/compare.txt"
