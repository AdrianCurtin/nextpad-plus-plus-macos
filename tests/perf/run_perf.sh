#!/bin/bash
# Run the in-app scroll and render benchmark on an isolated copy of the app.
#
# Usage:
#   tests/perf/run_perf.sh [options] <Nextpad++.app> <file> [scenario] [outdir]
#
#   <Nextpad++.app>  a built app bundle (for example build-release/Nextpad++.app)
#   <file>           the file to open (opened read-only with -ro; never modified)
#   [scenario]       comma-separated scenario names, or "all" (default: all).
#                    See tests/perf/README.md for the list.
#   [outdir]         where to put the report and logs (default: a new
#                    directory under the scratch root)
#
# Options:
#   --sample         run /usr/bin/sample on the app while the scenarios run;
#                    the call tree goes to <outdir>/sample.txt
#   --xctrace        record an Instruments trace (Time Profiler plus
#                    os_signpost) to <outdir>/trace.trace and export the
#                    signpost and time-profile tables and a text summary.
#                    An app launched by xctrace is its own responsible
#                    process for privacy checks, so a file under ~/Desktop,
#                    ~/Documents or ~/Downloads would stall the load on a
#                    folder-access prompt; such a file is first cloned
#                    (APFS copy-on-write, cp -c) to <scratch>/files/
#   --level N        probe level: 0 off (frame pacing and hitches only),
#                    1 aggregates + coarse signposts (default), 2 adds the
#                    per-line and per-text-run signposts
#   --repeat N       run each scenario N times in the same process
#   --window WxH     window size in points (default 1440x900)
#   --screen S       screen for the window: "max" (default, the screen with
#                    the highest refresh rate, such as a 120 Hz ProMotion
#                    panel), "main", or an index into NSScreen.screens. The
#                    report records the screen and its refresh rate
#   --no-app-nap     write NSAppSleepDisabled into the test defaults domain,
#                    so App Nap does not throttle a window that is not frontmost
#   --activate       activate the app and make its window key
#   --timeout S      kill the app after S seconds (default 900)
#   --label NAME     prefix for the default output directory name
#   --scratch DIR    scratch root for the app copy, the home directory and
#                    default output (default: $NPP_PERF_SCRATCH, else
#                    ${TMPDIR:-/tmp}/nextpad-perf)
#   --keep-home      keep the scratch home directory after the run
#   --hud            show the live HUD during the run
#   --env K=V        set an environment variable for the app (repeatable;
#                    also reaches the app under --xctrace)
#   --app-arg ARG    pass ARG to the app before the file (repeatable), for
#                    example --app-arg -NSSomeDefault --app-arg NO to set an
#                    AppKit default in the argument domain for this run only
#                    (the app skips -NS... and -Apple... arguments)
#   --pref K=V       write the app preference K to the test defaults domain
#                    before the launch (repeatable): an integer as -int,
#                    YES or NO as -bool, anything else as -string; for
#                    example --pref NPPDarkMode=1 for the light appearance
#
# Isolation: the app is copied to <scratch>/apps/, its bundle id is changed
# to org.nextpadplusplus.mac.perf, its executable is renamed NextpadPerf (so
# xctrace can tell it from installed copies) and it is ad-hoc re-signed, so it never
# reads or writes the real org.nextpadplusplus.mac defaults. The config
# directory is redirected with CFFIXED_USER_HOME to <scratch>/home-<run>.
# The org.nextpadplusplus.mac.perf defaults domain is deleted before and
# after every run.
#
# Other benchmark runs may share the machine: wrap runs in the shared
# lock, for example
#   /usr/bin/lockf -k "$NPP_PERF_SCRATCH/bench.lock" tests/perf/run_perf.sh ...
#
# Exit status: 0 when the report was written, 1 otherwise.

set -u

PERF_BUNDLE_ID="org.nextpadplusplus.mac.perf"
SAMPLE=0
XCTRACE=0
LEVEL=1
REPEAT=1
WINDOW=""
SCREEN=""
ACTIVATE=0
TIMEOUT=900
LABEL="run"
SCRATCH="${NPP_PERF_SCRATCH:-${TMPDIR:-/tmp}/nextpad-perf}"
KEEP_HOME=0
HUD=0
NO_APP_NAP=0
EXTRA_APP_ARGS=()
EXTRA_ENV=()
PREFS=()

usage() { sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --sample) SAMPLE=1 ;;
        --xctrace) XCTRACE=1 ;;
        --level) LEVEL="$2"; shift ;;
        --repeat) REPEAT="$2"; shift ;;
        --window) WINDOW="$2"; shift ;;
        --screen) SCREEN="$2"; shift ;;
        --no-app-nap) NO_APP_NAP=1 ;;
        --activate) ACTIVATE=1 ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --label) LABEL="$2"; shift ;;
        --scratch) SCRATCH="$2"; shift ;;
        --keep-home) KEEP_HOME=1 ;;
        --hud) HUD=1 ;;
        --app-arg) EXTRA_APP_ARGS+=("$2"); shift ;;
        --env) EXTRA_ENV+=("$2"); shift ;;
        --pref) PREFS+=("$2"); shift ;;
        -h|--help) usage ;;
        --*) echo "unknown option: $1" >&2; usage ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done
[ ${#ARGS[@]} -ge 2 ] || usage

SRC_APP="${ARGS[0]%/}"
FILE="${ARGS[1]}"
SCENARIO="${ARGS[2]:-all}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
OUT="${ARGS[3]:-$SCRATCH/out/$LABEL-$STAMP}"

[ -x "$SRC_APP/Contents/MacOS/Nextpad++" ] || { echo "not an app bundle: $SRC_APP" >&2; exit 1; }
[ -r "$FILE" ] || { echo "cannot read file: $FILE" >&2; exit 1; }
case "$FILE" in /*) ;; *) FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")" ;; esac
mkdir -p "$OUT" "$SCRATCH/apps"
OUT="$(cd "$OUT" && pwd)"

# ── Isolated copy: new bundle id, ad-hoc signature ──────────────────────────
# One copy per source bundle path, refreshed when the binary changes.
KEY="$(printf '%s' "$(cd "$SRC_APP" && pwd)" | shasum | cut -c1-12)"
APP="$SCRATCH/apps/$KEY/NextpadPerf.app"
EXE="NextpadPerf"
ORIG="$SCRATCH/apps/$KEY/source-binary"   # unsigned-copy check, kept outside the bundle
if [ ! -x "$APP/Contents/MacOS/$EXE" ] || \
   ! cmp -s "$SRC_APP/Contents/MacOS/Nextpad++" "$ORIG" 2>/dev/null; then
    rm -rf "$SCRATCH/apps/$KEY"
    mkdir -p "$SCRATCH/apps/$KEY"
    /usr/bin/ditto "$SRC_APP" "$APP" || exit 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PERF_BUNDLE_ID" "$APP/Contents/Info.plist" || exit 1
    mv "$APP/Contents/MacOS/Nextpad++" "$APP/Contents/MacOS/$EXE"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXE" "$APP/Contents/Info.plist" || exit 1
    xattr -cr "$APP"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || { echo "codesign failed" >&2; exit 1; }
    cp "$SRC_APP/Contents/MacOS/Nextpad++" "$ORIG"
fi
ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$ACTUAL_ID" != "$PERF_BUNDLE_ID" ]; then
    echo "refusing to run: bundle id is $ACTUAL_ID" >&2
    exit 1
fi
BIN="$APP/Contents/MacOS/$EXE"

HOME_DIR="$SCRATCH/home-$STAMP"
mkdir -p "$HOME_DIR"
REPORT="$OUT/report.json"
rm -f "$REPORT"

cleanup_defaults() { defaults delete "$PERF_BUNDLE_ID" >/dev/null 2>&1 || true; }
cleanup_defaults
[ "$NO_APP_NAP" = 1 ] && defaults write "$PERF_BUNDLE_ID" NSAppSleepDisabled -bool YES
for kv in ${PREFS[@]+"${PREFS[@]}"}; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$v" in
        YES|NO) defaults write "$PERF_BUNDLE_ID" "$k" -bool "$v" ;;
        ''|*[!0-9-]*) defaults write "$PERF_BUNDLE_ID" "$k" -string "$v" ;;
        *) defaults write "$PERF_BUNDLE_ID" "$k" -int "$v" ;;
    esac
done

ENVV=(
    "CFFIXED_USER_HOME=$HOME_DIR"
    "NPP_PERF_BENCH=$SCENARIO"
    "NPP_PERF_REPORT=$REPORT"
    "NPP_PERF_LEVEL=$LEVEL"
    "NPP_PERF_BENCH_REPEAT=$REPEAT"
    "NPP_PERF_BENCH_TIMEOUT=$TIMEOUT"
)
[ -n "$WINDOW" ] && ENVV+=("NPP_PERF_WINDOW=$WINDOW")
[ -n "$SCREEN" ] && ENVV+=("NPP_PERF_SCREEN=$SCREEN")
[ "$ACTIVATE" = 1 ] && ENVV+=("NPP_PERF_ACTIVATE=1")
[ "$HUD" = 1 ] && ENVV+=("NPP_PERF_HUD=1")
ENVV+=(${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"})
APP_ARGS=(${EXTRA_APP_ARGS[@]+"${EXTRA_APP_ARGS[@]}"} -ro -nosession "$FILE")

{
    echo "app=$SRC_APP"
    echo "copy=$APP"
    echo "file=$FILE"
    echo "scenario=$SCENARIO level=$LEVEL repeat=$REPEAT window=${WINDOW:-default} screen=${SCREEN:-max} noAppNap=$NO_APP_NAP"
    echo "appArgs=${EXTRA_APP_ARGS[*]-}"
    echo "extraEnv=${EXTRA_ENV[*]-}"
    echo "prefs=${PREFS[*]-}"
    echo "home=$HOME_DIR"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/run.txt"

# Waits for a pid with a timeout; kills it on expiry. Returns 124 on timeout.
wait_with_timeout() {
    local pid=$1 limit=$2 waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$limit" ]; then
            echo "timeout after ${limit}s; killing $pid" >&2
            kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
            return 124
        fi
        sleep 1; waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null
    return $?
}

# A locked screen (or a sleeping display) leaves the window occluded: AppKit
# stops pacing and drawing it, so frame numbers from such a run are not valid.
SCREEN_LOCKED=0
if /usr/sbin/ioreg -n Root -d1 -a 2>/dev/null | /usr/bin/plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null | \
        /usr/bin/grep -A1 CGSSessionScreenIsLocked | /usr/bin/grep -q '<true/>'; then
    SCREEN_LOCKED=1
    echo "warning: the screen is locked; frame and paint numbers from this run are not valid" >&2
fi
echo "screenLocked=$SCREEN_LOCKED" >> "$OUT/run.txt"

STATUS=0
if [ "$XCTRACE" = 1 ]; then
    case "$FILE" in
        "$HOME"/Desktop/*|"$HOME"/Documents/*|"$HOME"/Downloads/*)
            mkdir -p "$SCRATCH/files"
            CLONE="$SCRATCH/files/$(basename "$FILE")"
            if [ ! -f "$CLONE" ] || [ "$(stat -f %z "$CLONE")" != "$(stat -f %z "$FILE")" ] || \
               [ "$FILE" -nt "$CLONE" ]; then
                cp -c "$FILE" "$CLONE" 2>/dev/null || cp "$FILE" "$CLONE" || exit 1
            fi
            echo "file clone for xctrace: $CLONE" >> "$OUT/run.txt"
            APP_ARGS=(${EXTRA_APP_ARGS[@]+"${EXTRA_APP_ARGS[@]}"} -ro -nosession "$CLONE")
            ;;
    esac
    XENV=()
    for kv in "${ENVV[@]}"; do XENV+=(--env "$kv"); done
    TRACE="$OUT/trace.trace"
    rm -rf "$TRACE"
    xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
        --time-limit "${TIMEOUT}s" --output "$TRACE" "${XENV[@]}" \
        --launch -- "$BIN" "${APP_ARGS[@]}" > "$OUT/xctrace.log" 2>&1 &
    XPID=$!
    wait_with_timeout "$XPID" $((TIMEOUT + 60)) || STATUS=$?
    # Leftover app (xctrace normally ends it with the recording).
    pkill -f "$BIN" 2>/dev/null || true
    if [ -d "$TRACE" ]; then
        xcrun xctrace export --input "$TRACE" --toc > "$OUT/trace-toc.xml" 2>>"$OUT/xctrace.log"
        for pair in OSSignpostIntervals:intervals potential-hangs:hangs time-profile:time-profile; do
            xcrun xctrace export --input "$TRACE" \
                --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"${pair%%:*}\"]" \
                > "$OUT/trace-${pair#*:}.xml" 2>>"$OUT/xctrace.log"
        done
        python3 -I "$(cd "$(dirname "$0")" && pwd)/xctrace_summary.py" "$OUT" \
            > "$OUT/trace-summary.txt" 2>>"$OUT/xctrace.log" || true
    fi
    cp "$OUT/xctrace.log" "$OUT/stderr.log" 2>/dev/null || true
else
    env "${ENVV[@]}" "$BIN" "${APP_ARGS[@]}" > "$OUT/stdout.log" 2> "$OUT/stderr.log" &
    PID=$!
    echo "pid=$PID" >> "$OUT/run.txt"
    if [ "$SAMPLE" = 1 ]; then
        # Sample the scenarios only: start once the open phase is recorded.
        (
            for _ in $(seq 1 600); do
                grep -q '^\[perf\] open:' "$OUT/stderr.log" 2>/dev/null && break
                kill -0 "$PID" 2>/dev/null || exit 0
                sleep 0.2
            done
            /usr/bin/sample "$PID" "$TIMEOUT" 1 -mayDie -file "$OUT/sample.txt" > "$OUT/sample.log" 2>&1
        ) &
        SPID=$!
    fi
    wait_with_timeout "$PID" "$TIMEOUT" || STATUS=$?
    if [ "$SAMPLE" = 1 ]; then
        # sample stops when the app exits; give it time to write the report.
        for _ in $(seq 1 60); do kill -0 "$SPID" 2>/dev/null || break; sleep 1; done
        kill "$SPID" 2>/dev/null || true
    fi
fi

cleanup_defaults
[ "$KEEP_HOME" = 1 ] || rm -rf "$HOME_DIR"
echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ) status=$STATUS" >> "$OUT/run.txt"

grep '^\[perf\]' "$OUT/stderr.log" 2>/dev/null
if [ -s "$REPORT" ]; then
    echo "report: $REPORT"
    exit 0
fi
echo "no report written (status $STATUS); see $OUT/stderr.log" >&2
exit 1
