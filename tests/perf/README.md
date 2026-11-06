# Scroll and render performance diagnostics

Nextpad++ carries a diagnostics layer for scrolling and rendering: probes in
the Scintilla core, the Scintilla Cocoa layer and the app, a frame-pacing and
main-thread hitch monitor, an optional live overlay and a scripted benchmark
that writes a JSON report. Everything is off by default; with it off, each
probe costs one relaxed atomic load and a predicted branch.

## Turning it on

| Setting | Effect |
|---|---|
| `NPP_PERF=1` (environment) or `defaults write <bundle id> NPPPerfDiagnostics -bool YES` | Probes on: every probe is aggregated, coarse probes emit os_signpost intervals |
| `NPP_PERF=2` or `NPPPerfLevel=2` | Also emits signposts for the per-line and per-text-run probes (heavy; short Instruments traces only) |
| `NPP_PERF_HUD=1` or `NPPPerfHUD=YES` | Live overlay in the main window: FPS, frame time p95 and max, last paint time, hitches per second (implies level 1) |
| `NPP_PERF_BENCH=<scenarios>` | Runs the benchmark and quits (implies level 1 unless `NPP_PERF_LEVEL` says otherwise) |
| `NPP_PERF_LEVEL=<0..2>` | Overrides the level; `0` with `NPP_PERF_BENCH` runs the benchmark with every probe off (frame pacing and hitches only) |

Signposts use subsystem `org.nextpadplusplus.mac`, category `Performance`;
benchmark scenarios, timeline marks and the first full paint after a load
are Points of Interest.

Never run a development build against the real `org.nextpadplusplus.mac`
defaults domain or `~/Library/Application Support/Nextpad++`; use
`run_perf.sh`, which isolates the run.

## Running the benchmark

```sh
cmake -S . -B build-release -DCMAKE_BUILD_TYPE=Release
cmake --build build-release --target NotepadPlusPlusMac
export NPP_PERF_SCRATCH=/path/to/scratch        # app copy, homes, outputs
/usr/bin/lockf -k "$NPP_PERF_SCRATCH/bench.lock" \
    tests/perf/run_perf.sh build-release/Nextpad++.app big.txt all
```

`run_perf.sh` copies the app to `$NPP_PERF_SCRATCH/apps/`, sets its bundle id
to `org.nextpadplusplus.mac.perf`, renames the executable `NextpadPerf` and
re-signs it ad hoc, points `CFFIXED_USER_HOME` at a fresh
`$NPP_PERF_SCRATCH/home-<run>`, opens the file with `-ro -nosession`, waits
for the app to quit (with a timeout), keeps the report and logs, and deletes
the `org.nextpadplusplus.mac.perf` defaults domain before and after. Run it
with `--help` for every option. The useful ones:

| Option | |
|---|---|
| `--sample` | `/usr/bin/sample` call tree of the scenarios (`sample.txt`). Sampling slows the app; do not read timings from these runs |
| `--xctrace` | Instruments trace (Time Profiler + os_signpost) in `trace.trace`, exported tables and `trace-summary.txt` (signpost intervals per name and per scenario, Instruments hang reports, main-thread self and inclusive time with the app's own functions listed separately). A file under `~/Desktop`, `~/Documents` or `~/Downloads` is cloned to the scratch root first (`cp -c`): an app launched by `xctrace` answers privacy checks for itself, and the folder-access prompt would stall the load |
| `--level 0/1/2` | Probe level (default 1) |
| `--repeat N` | Run each scenario N times in one process |
| `--window WxH` | Window size in points (default 1440x900) |
| `--screen S` | Screen for the window: `max` (default, the highest refresh rate), `main` or an index into `NSScreen.screens` (sets `NPP_PERF_SCREEN`) |
| `--no-app-nap` | Writes `NSAppSleepDisabled` into the test defaults domain so App Nap does not throttle the window while another app is frontmost |
| `--activate` | Make the app active and its window key (default: ordered front without taking focus) |
| `--hud` | Show the overlay during the run |
| `--env K=V` | Environment variable for the app (repeatable; also reaches the app under `--xctrace`) |
| `--pref K=V` | Write app preference `K` to the test defaults domain before the launch (repeatable), for example `--pref NPPDarkMode=1` for the light appearance |
| `--app-arg ARG` | Argument before the file (repeatable), for AppKit defaults in the argument domain (`--app-arg -NSFoo --app-arg NO`) |

A locked screen or a sleeping display leaves the window occluded, and AppKit
then neither paces nor draws it: `run_perf.sh` warns and writes
`screenLocked=1` to `run.txt`, and `compare.py` warns about runs whose window
was not visible at the end of a scenario.

Other benchmark runs may use the machine at the same time: take the shared lock
around every benchmark, and compare builds interleaved in one lock session:

```sh
/usr/bin/lockf -k "$NPP_PERF_SCRATCH/bench.lock" tests/perf/ab.sh --reps 5 \
    base=/path/to/base/Nextpad++.app new=build-release/Nextpad++.app \
    big.txt smooth_scroll,page_down "$NPP_PERF_SCRATCH/out/ab-1"
```

`ab.sh` runs A, B, A, B, ... and prints `compare.py --spread` over the rounds.

### Display

The window goes to the screen with the highest refresh rate
(`NPP_PERF_SCREEN=max`, or `main`, or an index into `NSScreen.screens`). On a
MacBook Pro with the lid open that is the 120 Hz ProMotion panel; with only
external 60 Hz displays the frame budget is 16.7 ms. The report records the
screen, its maximum rate and the rate the display link actually ran at.
`environment.screenInfo` (and `screens`, one entry per screen) adds the colour
space, the current and potential extended dynamic range headroom and the
frame; `windowNumber` is the window's window server id, for
`screencapture -l` comparisons of what a build puts on screen.
`environment.layerTree` lists the window's layer tree, one line per layer:
the layer class, the view it backs, its size, opacity, `contentsFormat` and
whether it draws asynchronously.

## Scenarios

Each scenario starts from the top of the document (caret at 0, no selection,
zoom 0, base window frame), waits for the editor to stop painting, then
replays the same inputs on the display link: one input per frame tick or one
every N ticks. Durations therefore stretch when the app is slow; the inputs
and the end state stay the same.

| Name | Input |
|---|---|
| `open` | Always recorded: process start to file loaded and first full paint, load phases, everything up to the editor going quiet |
| `smooth_scroll` | 360 precise pixel scroll events, 12 px each, one per frame (trackpad gesture with began, changed and ended phases) |
| `smooth_scroll_mid` | The same, starting at the middle line of the document |
| `fling` | Three fast swipes, each followed by momentum events decaying by 0.95 per frame from 160 px |
| `wheel_notch` | 240 discrete one-line wheel notches, one every 3 frames |
| `page_down` | Page Down 120 times, one every 4 frames |
| `jump_end_home` | Cmd+End and Cmd+Home six times each, 60 frames apart |
| `hscroll` | Horizontal pixel scroll right for 120 frames and back for 120 frames, 12 px each |
| `diagonal` | Two diagonal pixel swipes of 120 frames: mostly right (10 px right, 6 px down per event), then mostly down (6 px right, 10 px down). `NSScrollView` locks each gesture to its predominant axis, so the first scrolls right only and the second down only |
| `hv_scroll` | Trackpad gestures with momentum: down 12 px and 3 px per event, a vertical fling, a horizontal fling, then vertical flings after horizontal flings in the middle, past the right edge and past the left edge. Records the view after each gesture (`checkpoints`: distance moved, clip view origin, `NSScrollView` rubber-band stretch, how many events found the clip view scrolled outside the gesture, Scintilla's first line and x offset) and checks that every vertical fling moves at least 90% as far as the first (`flingCheck`, also printed). `NPP_PERF_HV_GAP` sets the idle frames after each gesture (default 20, short enough that the next fling starts while a gesture past the left edge is still springing back) |
| `selection_scroll` | `smooth_scroll` with lines 4 to 1200 selected |
| `caret_down` | Down arrow 240 times, one every 4 frames |
| `resize` | Window resized every frame along a triangle wave, down to 400 x 250 pt smaller, two cycles |
| `zoom` | `SCI_ZOOMIN` three times then `SCI_ZOOMOUT` three times, 20 frames apart |
| `idle` | No input for 240 frames: timers and idle work only |
| `link_edits` | Verification only, not part of `all`: 400 steps that type a newline inside a link on the last line the link scan covers, scroll one line at a time, make random edits and undo them, scroll and page down. It edits the document in memory (the file stays read-only and unsaved) and undoes everything at the end. Run it with `NPP_LINK_VERIFY=1` and read `EditorView.linkVerify.mismatch`; its timings are not comparable |

Scroll input is built with `CGEventCreateScrollWheelEvent`, turned into an
`NSEvent` and sent to the window, so AppKit's hit test, `NSScrollView` and
`-[SCIContentView scrollWheel:]` / `adjustScroll:` all run. Such events carry
no window, so `-[NSApplication postEvent:]` would drop them; the driver sends
them to the window with the location in window coordinates and makes them
`NSApp.currentEvent` for the dispatch (private `-_setCurrentEvent:`, used only
by the benchmark), because `adjustScroll:` reads the current event. Momentum
events go to the content view's `scrollWheel:` directly, since `NSWindow`
drops momentum that does not follow a gesture it tracked. Keys are `NSEvent`
key events sent to the window, which reach the editor's `keyDown:` without
menu key equivalents.

`NPP_PERF_SCROLL_POST=1` (with `--activate`) posts scroll events through the
window server instead (`CGEventPost` at the HID tap, at the screen location
of the text), so `NSWindow` routes gestures and momentum and `NSScrollView`
latches momentum as it does for a trackpad. It needs the Accessibility
(event posting) permission of the process that launches the app, for
example the terminal running `run_perf.sh`. Such events still lack the
gesture events and fractional deltas of a real trackpad.

Every pixel-scroll scenario records one main-thread stall of about 33.4 ms
(`hitchMaxMs`, the `max` of `SCIContentView.scrollWheel` and `Bench.step`)
at the end of the gesture, on every display and refresh rate. It is the
event with the ended phase: `SCIContentView` overrides `scrollWheel:`, so
`NSScrollView` uses its legacy scrolling behaviour, which on a gesture end
waits inside `-[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:]`
for momentum events. The driver sends no momentum through the event queue,
so the wait runs to its timeout. With a real trackpad, momentum events
follow the gesture at once when there is any, and otherwise the content has
stopped moving, so the stall is a property of the synthetic input and is
not expected to show on screen.

The large-file warning is accepted automatically and the update check is
skipped while `NPP_PERF_BENCH` is set.

## The report

`report.json` (schema `nextpad-perf/1`):

- `environment`: machine, macOS, build commit, branch, dirty flag and type,
  file size and lines, large-file mode, lexer, encoding, EOL, wrap mode,
  Scintilla technology, buffered drawing, phases, layout cache mode, position
  cache size, idle styling, layout threads, font, line height, margins,
  window frame, backing scale, screen, refresh rate, frame clock.
- `scenarios[]`, each with
  - `summary`: the headline numbers (duration, CPU time of the process and
    of the main thread, frame interval p50, p95, p99 and max, dropped
    frames, hitches, display cycle, content and margin draw times, scroll
    event handling, `SCN_UPDATEUI` cost). CPU time comes from the kernel
    (`getrusage`, `thread_info`), so it is also there with probes off and is
    the measure to compare builds by when frames are not dropped
  - `frames`: frame-clock statistics. The clock is the display link of the
    editor view (`NSView` display link on macOS 14+, `CVDisplayLink` before,
    an `NSTimer` if no display link fires). Its callbacks run on the main
    thread, so an interval of n periods means n - 1 frames the main thread
    could not serve: `dropped` is the sum of those over the scenario
  - `hitches`: main-thread stalls from run loop observers. Each gap of at
    least 16.7 ms between two run loop activities is one callout (an event,
    a timer, the AppKit display pass, the Core Animation commit) that held
    the main thread that long; `top` lists the ten longest with the
    activities on either side. `busyIterationMs` is the busy time of each
    run loop iteration; `displayCycleMs` is the span of the BeforeWaiting
    observers. Where AppKit's display pass and the Core Animation commit run
    from BeforeWaiting observers, that span covers them; on macOS 27 the
    commit (and every `drawRect:` inside it) runs from a run loop source
    instead, so the span reads near zero there and the commit shows up in
    `busyIterationMs` and in the hitch gaps
  - `stats`: every probe aggregate for the scenario window (durations in ms:
    count, total, mean, min, p50, p90, p95, p99, max; values: count, sum,
    percentiles; counters: calls and total)
  - `endState`: first visible line, x offset, caret, anchor, zoom, window
    size and visibility, for checking that runs did the same thing
- `open` also has `marks`: timeline marks in ms since process start (`main`,
  `launch.begin`, `load.begin`, `load.end`, `firstPaint.*`,
  `firstFullPaint.*`, `bench.ready`, `bench.settled`).

Percentiles of probe aggregates come from a log-linear histogram with about
6% resolution; frame and hitch percentiles are exact.

`compare.py` prints scenarios side by side:

```sh
tests/perf/compare.py before=out/a after=out/b            # medians
tests/perf/compare.py --spread A=out/ab/A B=out/ab/B      # plus p95 and range
tests/perf/compare.py --stat EditView.LayoutLine.full:count out/a out/b
tests/perf/compare.py --all-stats --scenario smooth_scroll out/a
```

## Probes

Probe names are `Area.What`; sub-steps add a suffix. Durations unless noted.

**Scintilla core** (`scintilla/src`, `LOCAL CHANGE` comments)

- `Editor.Paint` and its steps `.StyleAreaBounded`, `.NotifyUpdateUI`,
  `.RefreshPixMaps`, `.NotifyPainted`; events `Editor.Paint.abandoned`
- `Editor.PaintSelMargin`, `Editor.RefreshStyleData`, `Editor.ChangeScrollBars`,
  `Editor.ChangeSize`, `Editor.ScrollTo`, `Editor.HorizontalScrollTo`,
  `Editor.WrapLines` (fine), `Editor.WrapLines.unwrapAll`, `Editor.WrapBlock`
  (+ value `.lines`), `Editor.NotifyUpdateUI`, `Editor.Idle`, `Editor.IdleStyle`,
  `Editor.IdleWork`, `Editor.StyleToPositionInView` (fine), `Editor.NotifyModified` (fine)
- counters `Editor.Redraw`, `Editor.RedrawRect`, `Editor.SetTopLine.changed`,
  `Editor.StyleAreaBounded.truncated`; value `Editor.SetTopLine.deltaLines`
- counters `Editor.InvalidateStyleRedraw` (each one re-wraps, clears the
  layout and position caches and repaints everything) and
  `Editor.IndicSet.unchanged` (an indicator setter that changed nothing and
  so skipped that invalidation)
- `EditView.PaintText` (+ values `.areaHeightPx`, `.areaWidthPx`,
  `.lineDraws`, `.passes`), `EditView.PaintText.layout` (fine),
  `EditView.PaintText.copyLine` (fine, buffered drawing only)
- `EditView.DrawLine` (fine) and phases `.back`, `.indicatorsBack`, `.text`,
  `.indicatorsFore`; counters `EditView.DrawBackground.fillsMerged` (segment
  backgrounds folded into the previous fill) and
  `EditView.DrawForeground.segmentsMerged` (tab and text segments folded into
  one monospaced text run)
- `EditView.LayoutLine` (fine), `.full`, `.measure`, `.wrap`; values `.chars`,
  `.segments`, `.threads`; counters `LayoutCache.hit` (layout reused),
  `.positionsOnly` (rewrap only), `.check` (style clock moved: compare text
  and styles), `.checkFailed`, `.miss` (full layout),
  `EditView.LayoutLine.fromWrapThread`
- counters `LineLayoutCache.retrieve`, `.allocate`, `.styleClockInvalidate`,
  `.uncached`
- counters `PositionCache.monospaceFastPath`, `.hit`, `.miss`, `.uncacheable`,
  `.clear`; value `.segmentBytes`; `PositionCache.measure` (fine)
- `Document.EnsureStyledTo` (+ value `.bytes`), `Lexer.Lex`, `Lexer.Fold`
  (+ value `Lexer.bytes`)
- `MarginView.PaintMargin`, `MarginView.PaintOneMargin` (fine),
  `MarginView.GetHighlightDelimiters` (fine); counter `MarginView.lineNumberDrawn`

**Scintilla Cocoa layer** (`scintilla/cocoa`, `LOCAL CHANGE` comments)

- `SCIContentView.drawRect` (+ values `.heightPt`, `.areaPt2`; event `.retry`;
  counter `.occluded`: paints while the window was not visible),
  `.viewWillDraw` (+ value `.rects`), `.prepareContentInRect` (+ value
  `.heightPt`), `.setFrame`, `.keyDown`, `.scrollWheel` (+ counters `.precise`,
  `.momentum`, value `.eventAgeUs`), counter `.adjustScroll`
- `SCIMarginView.drawRect` (+ value `.heightPt`), `.drawHashMarksAndLabels`;
  counters `SCIMarginView.invalidate.scroll` (from `NSScrollView` reflecting a
  scroll), `.invalidate.other`, `SCIMarginView.scrollInvalidate.skipped`
  (scroll invalidations dropped because the margin's vertical position did not
  change)
- event `ScintillaView.layerConfig` (once per editor window attach): the text
  view's layer class, its content sublayer and whether it draws
  asynchronously, redraw policy and responsive scrolling
- `ScintillaView.boundsDidChange` (clip view `NSViewBoundsDidChangeNotification`),
  `ScintillaView.setFrame`, event `ScintillaView.setMarginWidth.changed`
- `ScintillaCocoa.SyncPaint` (+ event `.abandoned`), `.PaintMargin`,
  `.WillDraw` (+ `.style`, value `.heightPt`, event `.wrapRedraw`),
  `.SetVerticalScrollPos`, `.SetHorizontalScrollPos`, `.SetScrollingSize`
  (+ `.setFrame`), `.Resize`, `.UpdateForScroll`, `.NotifyParent`
  (+ `.accessibility`), `.IdleWork`, `.IdleTimerFired`, `.TickFor`,
  `.KeyboardInput`; counters `.Redraw`, `.Redraw.duringPaint` (full redraw
  requested while the text was being painted), `.RedrawRect`,
  `.DiscardOverdraw`, `.ModifyScrollBars`, `.UpdateForScroll.hscrollRepaint`
  (full text repaint after a horizontal scroll, macOS 26 and later); value
  `.UpdateForScroll.dxPt` (horizontal distance of each horizontal scroll step)
- `PlatCocoa.FontCreate`, `PlatCocoa.MeasureWidths` and `PlatCocoa.WidthText`
  (fine, + value `.bytes`), `PlatCocoa.DrawText` (fine, + value `.bytes`),
  `PlatCocoa.Copy` (fine), `PlatCocoa.ScreenLineLayout` (fine); counters
  `PlatCocoa.FillRectangle`, `.InvalidateAll`, `.InvalidateRectangle` (+ value
  `.heightPt`)
- ASCII fast path: counters `PlatCocoa.DrawText.ascii` and
  `PlatCocoa.MeasureWidths.ascii` (runs drawn or measured from the font's
  glyph table instead of a CTLine), `PlatCocoa.ASCIIMetrics.build` (checking a
  new font against CoreText layout, once per distinct font) and counter
  `PlatCocoa.ASCIIMetrics.ineligible` (fonts that keep the CTLine path)
- `CoreText.CTLineCreate`, `CoreText.CTLineDraw` (fine)

**App**

- `EditorView.SCN.<Code>` for every Scintilla notification through
  `-[EditorView notification:]` (signpost `EditorView.notification` with the
  code name), counters `EditorView.SCN.UpdateUI.vscroll`, `.hscroll`,
  `.selection`, `.content`
- `EditorView.forwardToPlugins`, `Plugins.beNotified` (per plugin),
  `EditorView.updateBraceHighlight`, `.updateSmartHighlight` (+ `.clearAll`),
  `.updateClickableLinks`, `.postCursorDidMove` (status bar, tab and Document
  Map observers), `.recomputeLineNumberMargin`, `.runSpellCheck`,
  `.updateGitDiffMarkers`, `.applyGitDiffHighlights`, `.pollExternalChange`,
  `.setLanguage`, `.applyThemeColors`
- Clickable links: `EditorView.markClickableLinks` (+ value `.bytes`;
  counters `.detectLines`, lines passed to NSDataDetector, and `.numericSkip`,
  lines of numeric text skipped), value `EditorView.updateClickableLinks.lines`
  (lines scanned per update) and counter `.cached` (updates whose lines were
  all scanned before). With `NPP_LINK_VERIFY=1` in the environment every
  update also rescans the whole visible range, line ends included, and
  compares it with the indicators in the document: counters
  `EditorView.linkVerify.checked`, `.mismatch`, `.skipped` (ranges over the
  128 KB budget), value `.runs`; the first mismatches go to the log
- `MainWindowController.editorCursorMoved`, `.updateStatusBar` (counters
  `.leftUnchanged`, `.rightUnchanged`), `.refreshTabsForEditor`,
  `.updateTitle`, `.docListRefresh`, `.pollScrollSync` (fine),
  `.autoSaveTick`; `NppTabBar.drawRect`, `.setTitle` (counter `.unchanged`)
- `DocumentMap.cursorMoved`, `.syncScroll`, `.updateContent`, `.applyTheme`;
  `FunctionList.loadEditor`, `.scan` (background queue), `.applyResults`
- `Load.loadFileAtPath`, `Load.addText` and the phases `Load.stat`,
  `Load.prompt`, `Load.read` or `Load.read.mapped`, `Load.decode`,
  `Load.createDocument`, `Load.addTextPhase`, `Load.eolDetect`,
  `Load.setLanguage`, `Load.finish`; values `Load.fileSizeBytes`,
  `Load.lines`; counter `Load.largeFileMode`
- `AppDelegate.didFinishLaunching`, `AppDelegate.openFilesFromCLI`
- `CA.ContentLayer.display.text`, `.margin`, `.tabs`, `.other`: Core
  Animation rasterizing a view's drawing into its layer. On macOS 26 and
  later AppKit keeps the drawing of a `drawRect:` view as a display list in a
  visible-rect-sized content sublayer and rasterizes it during the
  transaction commit on the main thread, outside any `drawRect:`; the
  benchmark wraps `-display` of that sublayer class and attributes each call
  to the view that owns it (the editor text, the line-number margin, the tab
  bar, anything else)
- `RunLoop.displayCycle`, `RunLoop.iterationBusy` (from the frame monitor
  while it runs), `Bench.step`, counter `HUD.update`

The Document Map is a second `ScintillaView`; while it is open its paints
add to the same `SCIContentView`, `Editor` and `EditView` aggregates.

### Adding a probe

```cpp
#include "NppPerfProbe.h"            // or NppPerfDiagnostics.h in app code
NPP_PERF_SCOPE("Area.what", "line=%ld", (long)line);   // coarse interval
NPP_PERF_SCOPE_FINE("Area.hot");                       // per line / per run
NPP_PERF_COUNT("Area.event");
NPP_PERF_VALUE("Area.bytes", n);
```

Names must be string literals. One probe per source line (the macros declare
locals named after `__LINE__`). In vendored Scintilla files, mark the change
with a `LOCAL CHANGE:` comment and keep the file's line endings.

## Checking that drawing is unchanged

Benchmarks show what a change costs; `tests/cocoa/RenderCompareProbe.mm`
shows whether it changes what is drawn. It renders a text file through a real
`ScintillaView` offscreen under a matrix of settings (backing scales, fonts,
tab widths, styles, selection, indicators, whitespace, guides, drawing
phases, offsets, wrap, zoom, right-to-left) and prints a pixel hash per
configuration. Build it once against each Scintilla build's `libscintilla.a`
and `libscintilla_core.a` (instructions at the top of the file), run both on
the same file and `diff` the output. Any differing line is a visible change.
