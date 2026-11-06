#pragma once

// Performance diagnostics for scrolling and rendering.
//
// Off by default and close to free when off: every probe is one relaxed
// atomic load and a predicted branch (see src/perf/NppPerfProbe.h).
//
// Turn on with any of:
//   NPP_PERF=1 (or 2)                 environment
//   defaults NPPPerfDiagnostics=YES   (NPPPerfLevel=2 for fine signposts)
//   NPP_PERF_HUD=1 / NPPPerfHUD=YES   live FPS overlay (implies level 1)
//   NPP_PERF_BENCH=<scenarios|all>    benchmark driver (implies level 1),
//                                     see NppPerfBench.h and tests/perf/README.md
//
// Level 1 aggregates every probe and emits os_signpost intervals for the
// coarse ones (subsystem org.nextpadplusplus.mac, category "Performance";
// scenario markers in PointsOfInterest). Level 2 adds signposts for the
// per-line and per-text-run probes.

#import <Cocoa/Cocoa.h>
#include "NppPerfProbe.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the environment and defaults and enables the probes. Call first
/// thing in main(), before NSApplication exists.
void NppPerfBootstrap(void);

/// YES when probes are on (level >= 1).
BOOL NppPerfEnabled(void);

/// YES when the live overlay was requested.
BOOL NppPerfHUDRequested(void);

/// Records a named timeline mark (milliseconds since process start) for the
/// report. First write wins, so a mark keeps its first occurrence.
void NppPerfMark(NSString *name);
/// Records a mark even if it exists (overwrites).
void NppPerfMarkAgain(NSString *name);
/// All marks, name -> milliseconds since process start.
NSDictionary<NSString *, NSNumber *> *NppPerfMarks(void);
/// Milliseconds since process start (process start from the kernel).
double NppPerfMsSinceProcessStart(void);

/// Snapshot of every aggregate as name -> {kind, count, sum, min, max, p50,
/// p90, p95, p99, last, mean}. Durations are reported in milliseconds with
/// the suffix "_ms" on each field; values and counters keep their units.
NSDictionary<NSString *, NSDictionary *> *NppPerfStatsSnapshot(void);

/// Display name for a Scintilla notification code ("UpdateUI", "Painted", ...).
NSString *NppPerfSCNName(unsigned code);

/// Installs the content-paint hook (first frame after load, HUD feed).
void NppPerfInstallPaintHook(void);

/// The SCIContentView that just loaded a file: the first-paint marks only
/// count paints of this view.
void NppPerfSetLoadedContentView(void *contentView);

/// Last content paint: duration and end time in ns (NppPerf::NowNs clock).
uint64_t NppPerfLastPaintDurationNs(void);
uint64_t NppPerfLastPaintEndNs(void);
uint64_t NppPerfContentPaintCount(void);

#ifdef __cplusplus
}

/// Times one Scintilla notification through EditorView: one aggregate per
/// code ("EditorView.SCN.UpdateUI", ...) plus a signpost interval
/// "EditorView.notification" with the code name and flags.
struct NppPerfSCNScope {
	uint64_t t0 = 0;
	unsigned code = 0;
	os_signpost_id_t spid = OS_SIGNPOST_ID_NULL;
	NppPerfSCNScope(unsigned code_, int updated, int modificationType) {
		if (NppPerf::On())
			Begin(code_, updated, modificationType);
	}
	~NppPerfSCNScope() {
		if (t0)
			End();
	}
	NppPerfSCNScope(const NppPerfSCNScope &) = delete;
	NppPerfSCNScope &operator=(const NppPerfSCNScope &) = delete;
	void Begin(unsigned code_, int updated, int modificationType);
	void End();
};

/// Sequential phase timer for straight-line code with early returns (file
/// load): Lap("Load.read") records the time since the previous lap (or since
/// construction) into the aggregate of that name and emits a "Phase" signpost
/// event. Names may be computed; each name is looked up under a lock, so use
/// it for a handful of phases, not in hot loops.
struct NppPerfLap {
	uint64_t last = 0;
	NppPerfLap() {
		if (NppPerf::On())
			last = NppPerf::NowNs();
	}
	void Lap(const char *name) {
		if (last)
			LapSlow(name);
	}
	void LapSlow(const char *name);
};
#endif

/// Frame clock plus main-thread hitch detector.
///
/// The clock is a display link on the editor's view (NSView displayLink on
/// macOS 14+, CVDisplayLink before that, an NSTimer if no display link fires).
/// Ticks run on the main thread, so a busy main thread shows up as late or
/// skipped ticks: frame intervals and dropped frames below are measured
/// against the display's refresh period.
///
/// Hitches are measured with run loop observers: a gap between two run loop
/// activities longer than the threshold means one callout (event handling,
/// timer, drawing, Core Animation commit) held the main thread that long.
@interface NppPerfFrameMonitor : NSObject

- (instancetype)initWithView:(NSView *)view;
- (instancetype)init NS_UNAVAILABLE;

/// Called on the main thread once per frame tick (timestamps in seconds,
/// CACurrentMediaTime clock).
@property (nonatomic, copy, nullable) void (^onFrame)(CFTimeInterval timestamp);

@property (nonatomic, readonly) NSString *clockKind;      // CADisplayLink / CVDisplayLink / NSTimer
@property (nonatomic, readonly) double nominalRefreshHz;   // NSScreen maximumFramesPerSecond
@property (nonatomic, readonly) double measuredRefreshHz;  // from the display link period
@property (nonatomic, readonly) uint64_t tickCount;

- (void)start;
- (void)stop;

/// Starts collecting frame intervals and hitches.
- (void)beginWindow;
/// Stops collecting and returns {frames:{...}, hitches:{...}}.
- (NSDictionary *)endWindow;

/// Frames per second over the last second, and the 95th percentile and max
/// frame interval (ms) over the last second (for the HUD).
- (void)recentFPS:(double *)fps p95Ms:(double *)p95 maxMs:(double *)maxMs hitches:(NSInteger *)hitches;

@end

/// Small live overlay: FPS, frame time, last paint time, hitches.
@interface NppPerfHUD : NSObject
+ (void)attachToWindowIfRequested:(NSWindow *)window view:(NSView *)view;
+ (void)detach;
@end

NS_ASSUME_NONNULL_END
