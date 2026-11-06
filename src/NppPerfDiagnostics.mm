// Performance diagnostics: enabling, timeline marks, aggregate snapshots,
// notification timing, frame clock, hitch detector and the live HUD.
// See NppPerfDiagnostics.h and tests/perf/README.md.

#import "NppPerfDiagnostics.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import "Scintilla.h"

#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <deque>
#include <vector>

// ── Enable / bootstrap ──────────────────────────────────────────────────────

static double gProcessStartToBootstrapMs = 0;   // process start -> bootstrap
static uint64_t gBootstrapNs = 0;               // NppPerf::NowNs() at bootstrap
static BOOL gHUDRequested = NO;
static BOOL gMarksEnabled = NO;                 // probes on, or a benchmark run

static int EnvInt(const char *name, int dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    if (!strcasecmp(v, "yes") || !strcasecmp(v, "true") || !strcasecmp(v, "on")) return 1;
    return atoi(v);
}

static double ProcessStartToNowMs(void) {
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return 0;
    struct timeval now;
    gettimeofday(&now, NULL);
    const struct timeval st = kp.kp_proc.p_starttime;
    return (now.tv_sec - st.tv_sec) * 1000.0 + (now.tv_usec - st.tv_usec) / 1000.0;
}

void NppPerfBootstrap(void) {
    NppPerf::Init();
    gBootstrapNs = NppPerf::NowNs();
    gProcessStartToBootstrapMs = ProcessStartToNowMs();

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    int level = EnvInt("NPP_PERF", 0);
    if ([ud boolForKey:@"NPPPerfDiagnostics"]) {
        NSInteger l = [ud integerForKey:@"NPPPerfLevel"];
        level = std::max(level, (int)(l > 0 ? l : 1));
    }
    gHUDRequested = EnvInt("NPP_PERF_HUD", 0) > 0 || [ud boolForKey:@"NPPPerfHUD"];
    if (gHUDRequested) level = std::max(level, 1);
    const char *bench = getenv("NPP_PERF_BENCH");
    const BOOL benchRun = bench && *bench;
    if (benchRun) level = std::max(level, 1);
    // NPP_PERF_LEVEL overrides everything, including 0: a benchmark run with
    // NPP_PERF_LEVEL=0 measures frame pacing and hitches with every probe off
    // (the overhead baseline).
    level = EnvInt("NPP_PERF_LEVEL", level);
    if (level > 2) level = 2;
    gMarksEnabled = level > 0 || benchRun;
    if (gMarksEnabled) NppPerfMark(@"main");
    if (level <= 0) return;

    NppPerf::SetLevel(level);
    NppPerfInstallPaintHook();
    os_signpost_event_emit(NppPerf::PoiLog(), OS_SIGNPOST_ID_EXCLUSIVE, "PerfDiagnosticsEnabled",
                           "level=%d processStartToMainMs=%.1f", level, gProcessStartToBootstrapMs);
}

BOOL NppPerfEnabled(void) { return NppPerf::On(); }
BOOL NppPerfHUDRequested(void) { return gHUDRequested; }

static double MsSinceStartForNs(uint64_t ns) {
    return gProcessStartToBootstrapMs + (double)((int64_t)(ns - gBootstrapNs)) / 1e6;
}

double NppPerfMsSinceProcessStart(void) {
    return MsSinceStartForNs(NppPerf::NowNs());
}

// ── Timeline marks ──────────────────────────────────────────────────────────

static NSMutableDictionary<NSString *, NSNumber *> *gMarks;
static uint64_t gLoadEndNs = 0;
static void *gLoadedContentView = nullptr;   // SCIContentView of the last loaded file

static void SetMark(NSString *name, double ms, BOOL overwrite) {
    @synchronized ([NSProcessInfo class]) {
        if (!gMarks) gMarks = [NSMutableDictionary dictionary];
        if (!overwrite && gMarks[name]) return;
        gMarks[name] = @(ms);
    }
}

void NppPerfMark(NSString *name) {
    if (!gMarksEnabled) return;
    const uint64_t now = NppPerf::NowNs();
    SetMark(name, MsSinceStartForNs(now), NO);
    if ([name isEqualToString:@"load.end"] && !gLoadEndNs) gLoadEndNs = now;
    os_signpost_event_emit(NppPerf::PoiLog(), OS_SIGNPOST_ID_EXCLUSIVE, "Mark", "%{public}s", name.UTF8String);
}

void NppPerfMarkAgain(NSString *name) {
    if (!gMarksEnabled) return;
    SetMark(name, NppPerfMsSinceProcessStart(), YES);
}

NSDictionary<NSString *, NSNumber *> *NppPerfMarks(void) {
    @synchronized ([NSProcessInfo class]) {
        return gMarks ? [gMarks copy] : @{};
    }
}

// ── Content paint hook ──────────────────────────────────────────────────────

static std::atomic<uint64_t> gLastPaintDurNs{0};
static std::atomic<uint64_t> gLastPaintEndNs{0};
static std::atomic<uint64_t> gPaintCount{0};
static BOOL gFirstPaintAfterLoadDone = NO;
static BOOL gFirstFullPaintAfterLoadDone = NO;

// firstPaint.*: the first content paint after the file load ended (often a
// small rectangle). firstFullPaint.*: the first one covering at least half of
// the visible area while the view is at least 100 pt tall (during the first
// layout pass the view can be a few points tall), which is the first frame
// with the file's text.
static void ContentPaintHook(void *view, double rectWidth, double rectHeight, double visibleWidth,
                             double visibleHeight, uint64_t t0, uint64_t t1) {
    (void)view;
    gLastPaintDurNs.store(t1 - t0, std::memory_order_relaxed);
    gLastPaintEndNs.store(t1, std::memory_order_relaxed);
    gPaintCount.fetch_add(1, std::memory_order_relaxed);
    // Only the editor that loaded the file: other editors (an empty first
    // tab, split panes) paint too and draw nothing of the file.
    if (!gLoadEndNs || t0 < gLoadEndNs || view != gLoadedContentView) return;
    if (!gFirstPaintAfterLoadDone) {
        gFirstPaintAfterLoadDone = YES;
        SetMark(@"firstPaint.begin", MsSinceStartForNs(t0), NO);
        SetMark(@"firstPaint.end", MsSinceStartForNs(t1), NO);
    }
    if (!gFirstFullPaintAfterLoadDone && visibleHeight >= 100 &&
        rectWidth * rectHeight >= 0.5 * visibleWidth * visibleHeight) {
        gFirstFullPaintAfterLoadDone = YES;
        SetMark(@"firstFullPaint.begin", MsSinceStartForNs(t0), NO);
        SetMark(@"firstFullPaint.end", MsSinceStartForNs(t1), NO);
        os_signpost_event_emit(NppPerf::PoiLog(), OS_SIGNPOST_ID_EXCLUSIVE, "FirstFullPaintAfterLoad",
                               "paintMs=%.2f height=%.0f", (t1 - t0) / 1e6, rectHeight);
    }
}

void NppPerfInstallPaintHook(void) {
    NppPerf::gContentPaintHook.store(&ContentPaintHook, std::memory_order_relaxed);
}

void NppPerfSetLoadedContentView(void *contentView) {
    gLoadedContentView = contentView;
}

uint64_t NppPerfLastPaintDurationNs(void) { return gLastPaintDurNs.load(std::memory_order_relaxed); }
uint64_t NppPerfLastPaintEndNs(void) { return gLastPaintEndNs.load(std::memory_order_relaxed); }
uint64_t NppPerfContentPaintCount(void) { return gPaintCount.load(std::memory_order_relaxed); }

// ── Aggregate snapshot ──────────────────────────────────────────────────────

NSDictionary<NSString *, NSDictionary *> *NppPerfStatsSnapshot(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (const NppPerf::StatSnapshot &s : NppPerf::Snapshot()) {
        NSString *name = [NSString stringWithUTF8String:s.name.c_str()];
        if (!name) continue;
        switch (s.kind) {
            case NppPerf::Kind::Duration: {
                const double ms = 1e6;
                out[name] = @{
                    @"kind": @"duration",
                    @"count": @(s.count),
                    @"total_ms": @(s.sum / ms),
                    @"mean_ms": @(s.count ? s.sum / ms / s.count : 0),
                    @"min_ms": @(s.min / ms),
                    @"p50_ms": @(s.p50 / ms),
                    @"p90_ms": @(s.p90 / ms),
                    @"p95_ms": @(s.p95 / ms),
                    @"p99_ms": @(s.p99 / ms),
                    @"max_ms": @(s.max / ms),
                    @"last_ms": @(s.last / ms),
                };
                break;
            }
            case NppPerf::Kind::Value:
                out[name] = @{
                    @"kind": @"value",
                    @"count": @(s.count),
                    @"sum": @(s.sum),
                    @"mean": @(s.count ? (double)s.sum / s.count : 0),
                    @"min": @(s.min),
                    @"p50": @(s.p50),
                    @"p90": @(s.p90),
                    @"p95": @(s.p95),
                    @"p99": @(s.p99),
                    @"max": @(s.max),
                };
                break;
            case NppPerf::Kind::Counter:
                out[name] = @{
                    @"kind": @"counter",
                    @"calls": @(s.count),
                    @"total": @((int64_t)s.sum),
                };
                break;
        }
    }
    return out;
}

// ── Scintilla notification timing ───────────────────────────────────────────

NSString *NppPerfSCNName(unsigned code) {
    switch (code) {
        case SCN_STYLENEEDED: return @"StyleNeeded";
        case SCN_CHARADDED: return @"CharAdded";
        case SCN_SAVEPOINTREACHED: return @"SavePointReached";
        case SCN_SAVEPOINTLEFT: return @"SavePointLeft";
        case SCN_MODIFYATTEMPTRO: return @"ModifyAttemptRO";
        case SCN_KEY: return @"Key";
        case SCN_DOUBLECLICK: return @"DoubleClick";
        case SCN_UPDATEUI: return @"UpdateUI";
        case SCN_MODIFIED: return @"Modified";
        case SCN_MACRORECORD: return @"MacroRecord";
        case SCN_MARGINCLICK: return @"MarginClick";
        case SCN_NEEDSHOWN: return @"NeedShown";
        case SCN_PAINTED: return @"Painted";
        case SCN_USERLISTSELECTION: return @"UserListSelection";
        case SCN_URIDROPPED: return @"URIDropped";
        case SCN_DWELLSTART: return @"DwellStart";
        case SCN_DWELLEND: return @"DwellEnd";
        case SCN_ZOOM: return @"Zoom";
        case SCN_HOTSPOTCLICK: return @"HotSpotClick";
        case SCN_HOTSPOTDOUBLECLICK: return @"HotSpotDoubleClick";
        case SCN_CALLTIPCLICK: return @"CallTipClick";
        case SCN_AUTOCSELECTION: return @"AutoCSelection";
        case SCN_INDICATORCLICK: return @"IndicatorClick";
        case SCN_INDICATORRELEASE: return @"IndicatorRelease";
        case SCN_AUTOCCANCELLED: return @"AutoCCancelled";
        case SCN_AUTOCCHARDELETED: return @"AutoCCharDeleted";
        case SCN_HOTSPOTRELEASECLICK: return @"HotSpotReleaseClick";
        case SCN_FOCUSIN: return @"FocusIn";
        case SCN_FOCUSOUT: return @"FocusOut";
        case SCN_AUTOCCOMPLETED: return @"AutoCCompleted";
        case SCN_MARGINRIGHTCLICK: return @"MarginRightClick";
        case SCN_AUTOCSELECTIONCHANGE: return @"AutoCSelectionChange";
        default: return [NSString stringWithFormat:@"Code%u", code];
    }
}

static int SCNStatId(unsigned code) {
    static int ids[128];
    static bool inited = false;
    if (!inited) {
        for (int &i : ids) i = -2;
        inited = true;
    }
    const unsigned slot = (code >= 2000 && code < 2128) ? code - 2000 : 127;
    if (ids[slot] == -2) {
        NSString *name = [@"EditorView.SCN." stringByAppendingString:NppPerfSCNName(code)];
        ids[slot] = NppPerf::RegisterDynamic(name.UTF8String, NppPerf::Kind::Duration);
    }
    return ids[slot];
}

void NppPerfSCNScope::Begin(unsigned code_, int updated, int modificationType) {
    code = code_;
    t0 = NppPerf::NowNs();
    os_log_t log = NppPerf::Log();
    if (os_signpost_enabled(log)) {
        spid = os_signpost_id_generate(log);
        os_signpost_interval_begin(log, spid, "EditorView.notification", "%{public}s updated=0x%x mod=0x%x",
                                   NppPerfSCNName(code).UTF8String, updated, modificationType);
    }
}

void NppPerfSCNScope::End() {
    NppPerf::RecordDuration(SCNStatId(code), NppPerf::NowNs() - t0);
    if (spid != OS_SIGNPOST_ID_NULL)
        os_signpost_interval_end(NppPerf::Log(), spid, "EditorView.notification");
    t0 = 0;
}

void NppPerfLap::LapSlow(const char *name) {
    const uint64_t now = NppPerf::NowNs();
    const uint64_t dur = now - last;
    last = now;
    NppPerf::RecordDuration(NppPerf::Register(name, NppPerf::Kind::Duration), dur);
    os_signpost_event_emit(NppPerf::Log(), OS_SIGNPOST_ID_EXCLUSIVE, "Phase", "%{public}s %.3f ms", name, dur / 1e6);
}

// ── Small statistics helpers ────────────────────────────────────────────────

static double PercentileOf(std::vector<double> v, double q) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    size_t idx = (size_t)std::ceil(q * v.size());
    if (idx > 0) idx--;
    if (idx >= v.size()) idx = v.size() - 1;
    return v[idx];
}

static NSDictionary *Distribution(const std::vector<double> &v) {
    if (v.empty()) return @{@"count": @0};
    double sum = 0, mx = 0, mn = v[0];
    for (double d : v) { sum += d; mx = std::max(mx, d); mn = std::min(mn, d); }
    return @{
        @"count": @(v.size()),
        @"mean": @(sum / v.size()),
        @"min": @(mn),
        @"p50": @(PercentileOf(v, 0.50)),
        @"p90": @(PercentileOf(v, 0.90)),
        @"p95": @(PercentileOf(v, 0.95)),
        @"p99": @(PercentileOf(v, 0.99)),
        @"max": @(mx),
    };
}

static NSString *ActivityName(CFRunLoopActivity a) {
    switch (a) {
        case kCFRunLoopEntry: return @"Entry";
        case kCFRunLoopBeforeTimers: return @"BeforeTimers";
        case kCFRunLoopBeforeSources: return @"BeforeSources";
        case kCFRunLoopBeforeWaiting: return @"BeforeWaiting";
        case kCFRunLoopAfterWaiting: return @"AfterWaiting";
        case kCFRunLoopExit: return @"Exit";
        default: return @"Other";
    }
}

// ── Frame monitor ───────────────────────────────────────────────────────────

struct NppHitch {
    double atS;        // CACurrentMediaTime when it ended
    double durMs;
    CFRunLoopActivity before;
    CFRunLoopActivity after;
};

@implementation NppPerfFrameMonitor {
    __weak NSView *_view;
    id _caLink;                      // CADisplayLink (macOS 14+)
    CVDisplayLinkRef _cvLink;
    std::atomic<bool> _cvPending;
    NSTimer *_timer;
    NSTimer *_fallbackCheck;
    CFRunLoopObserverRef _obsFirst;
    CFRunLoopObserverRef _obsSleep;

    // Run loop state.
    double _lastActivityTs;
    CFRunLoopActivity _lastActivity;
    BOOL _asleep;
    double _iterStart;
    double _beforeWaitingTs;          // first BeforeWaiting callback of this iteration

    // Recording window.
    BOOL _recording;
    double _windowStart;
    std::vector<double> _ticks;
    std::vector<double> _latencyMs;
    std::vector<double> _periodsMs;
    std::vector<NppHitch> _hitches;
    std::vector<double> _busyIterMs;
    std::vector<double> _displayCycleMs;

    // Recent history for the HUD.
    std::deque<double> _recentTicks;
    std::deque<double> _recentHitchTs;

    double _lastPeriodS;
    NSString *_clockKind;
    uint64_t _tickCount;
}

- (instancetype)initWithView:(NSView *)view {
    if ((self = [super init])) {
        _view = view;
        _cvPending = false;
        _clockKind = @"none";
        _lastPeriodS = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSString *)clockKind { return _clockKind; }
- (uint64_t)tickCount { return _tickCount; }

- (double)nominalRefreshHz {
    NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
    if (@available(macOS 12.0, *)) {
        NSInteger fps = screen.maximumFramesPerSecond;
        if (fps > 0) return (double)fps;
    }
    return 60.0;
}

- (double)measuredRefreshHz {
    return _lastPeriodS > 0 ? 1.0 / _lastPeriodS : 0;
}

- (double)_periodS {
    if (_lastPeriodS > 0.0005) return _lastPeriodS;
    return 1.0 / self.nominalRefreshHz;
}

static void CVTick(NppPerfFrameMonitor *self, double ts, double periodS);

static CVReturn CVCallback(CVDisplayLinkRef, const CVTimeStamp *inNow, const CVTimeStamp *inOutput,
                           CVOptionFlags, CVOptionFlags *, void *ctx) {
    NppPerfFrameMonitor *mon = (__bridge NppPerfFrameMonitor *)ctx;
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    const double ts = (double)inNow->hostTime * tb.numer / tb.denom / 1e9;
    double period = 0;
    if (inOutput->videoTimeScale > 0)
        period = (double)inOutput->videoRefreshPeriod / inOutput->videoTimeScale;
    CVTick(mon, ts, period);
    return kCVReturnSuccess;
}

static void CVTick(NppPerfFrameMonitor *self, double ts, double periodS) {
    // Coalesce: one pending main-thread tick at most, like a real frame clock
    // that skips frames while the main thread is busy.
    if (self->_cvPending.exchange(true)) return;
    __weak NppPerfFrameMonitor *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NppPerfFrameMonitor *s = weakSelf;
        if (!s) return;
        s->_cvPending = false;
        [s _tickAt:ts period:periodS];
    });
}

- (void)start {
    if (_caLink || _cvLink || _timer) return;
    NSView *view = _view;
    if (@available(macOS 14.0, *)) {
        if (view) {
            CADisplayLink *link = [view displayLinkWithTarget:self selector:@selector(_caTick:)];
            // Ask for the fastest rate any screen offers: the link follows the
            // view to whichever screen it ends up on.
            float fps = 60;
            for (NSScreen *s in NSScreen.screens) fps = MAX(fps, (float)s.maximumFramesPerSecond);
            link.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps);
            [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            _caLink = link;
            _clockKind = @"CADisplayLink";
        }
    }
    if (!_caLink) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (CVDisplayLinkCreateWithActiveCGDisplays(&_cvLink) == kCVReturnSuccess) {
            CVDisplayLinkSetOutputCallback(_cvLink, CVCallback, (__bridge void *)self);
            CVDisplayLinkStart(_cvLink);
            _clockKind = @"CVDisplayLink";
        }
#pragma clang diagnostic pop
    }
    // No ticks after half a second (display asleep, view off screen): fall
    // back to a timer at the nominal refresh rate so scenarios still run.
    __weak NppPerfFrameMonitor *weakSelf = self;
    _fallbackCheck = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *t) {
        NppPerfFrameMonitor *s = weakSelf;
        if (!s || s->_tickCount > 0) return;
        [s _startTimerClock];
    }];
    [self _installObservers];
}

- (void)_startTimerClock {
    [self _stopClocks];
    _clockKind = @"NSTimer";
    __weak NppPerfFrameMonitor *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:1.0 / self.nominalRefreshHz repeats:YES block:^(NSTimer *t) {
        NppPerfFrameMonitor *s = weakSelf;
        [s _tickAt:CACurrentMediaTime() period:1.0 / s.nominalRefreshHz];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)_stopClocks {
    if (_caLink) {
        [_caLink invalidate];
        _caLink = nil;
    }
    if (_cvLink) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkStop(_cvLink);
        CVDisplayLinkRelease(_cvLink);
#pragma clang diagnostic pop
        _cvLink = NULL;
    }
    [_timer invalidate];
    _timer = nil;
}

- (void)stop {
    [_fallbackCheck invalidate];
    _fallbackCheck = nil;
    [self _stopClocks];
    [self _removeObservers];
}

- (void)_caTick:(id)link {
    if (@available(macOS 14.0, *)) {
        CADisplayLink *dl = link;
        const double period = dl.targetTimestamp - dl.timestamp;
        [self _tickAt:dl.timestamp period:(period > 0 ? period : dl.duration)];
    }
}

- (void)_tickAt:(double)ts period:(double)periodS {
    _tickCount++;
    if (periodS > 0.0005) _lastPeriodS = periodS;
    const double now = CACurrentMediaTime();
    if (_recording) {
        _ticks.push_back(ts);
        _latencyMs.push_back((now - ts) * 1000.0);
        if (periodS > 0.0005) _periodsMs.push_back(periodS * 1000.0);
    }
    _recentTicks.push_back(ts);
    while (!_recentTicks.empty() && ts - _recentTicks.front() > 1.0) _recentTicks.pop_front();
    if (self.onFrame) self.onFrame(ts);
}

// ── Run loop observers (hitches) ──

- (void)_installObservers {
    if (_obsFirst) return;
    __weak NppPerfFrameMonitor *weakSelf = self;
    _obsFirst = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopAllActivities, true, LONG_MIN,
        ^(CFRunLoopObserverRef, CFRunLoopActivity activity) {
            [weakSelf _activity:activity late:NO];
        });
    _obsSleep = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, LONG_MAX,
        ^(CFRunLoopObserverRef, CFRunLoopActivity activity) {
            [weakSelf _activity:activity late:YES];
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), _obsFirst, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetMain(), _obsSleep, kCFRunLoopCommonModes);
}

- (void)_removeObservers {
    if (_obsFirst) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), _obsFirst, kCFRunLoopCommonModes);
        CFRelease(_obsFirst);
        _obsFirst = NULL;
    }
    if (_obsSleep) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), _obsSleep, kCFRunLoopCommonModes);
        CFRelease(_obsSleep);
        _obsSleep = NULL;
    }
}

- (void)_activity:(CFRunLoopActivity)activity late:(BOOL)late {
    const double now = CACurrentMediaTime();
    if (activity == kCFRunLoopAfterWaiting && !late) {
        // Woke up: the time since the sleep mark was idle, not work.
        _asleep = NO;
        _iterStart = now;
        _lastActivityTs = now;
        _lastActivity = activity;
        return;
    }
    if (!_asleep && _lastActivityTs > 0) {
        const double gapMs = (now - _lastActivityTs) * 1000.0;
        if (gapMs >= 16.7) {
            if (_recording) _hitches.push_back({now, gapMs, _lastActivity, activity});
            _recentHitchTs.push_back(now);
        }
    }
    _lastActivityTs = now;
    _lastActivity = activity;
    if (activity == kCFRunLoopBeforeWaiting && !late) _beforeWaitingTs = now;
    if (late) {
        // Last BeforeWaiting observer: the iteration is done. Early to late
        // BeforeWaiting spans the other BeforeWaiting observers: AppKit's
        // display pass and the Core Animation commit where those run as
        // observers. On macOS 27 the commit runs from a run loop source
        // instead, so this span is near zero there and the commit is part
        // of the busy iteration and the hitch gaps.
        if (_beforeWaitingTs > 0) {
            const double cycleMs = (now - _beforeWaitingTs) * 1000.0;
            if (_recording) _displayCycleMs.push_back(cycleMs);
            if (NppPerf::On()) {
                static const int idCycle = NppPerf::Register("RunLoop.displayCycle", NppPerf::Kind::Duration);
                NppPerf::RecordDuration(idCycle, (uint64_t)(cycleMs * 1e6));
            }
            _beforeWaitingTs = 0;
        }
        if (_iterStart > 0) {
            const double busyMs = (now - _iterStart) * 1000.0;
            if (_recording) _busyIterMs.push_back(busyMs);
            if (NppPerf::On()) {
                static const int idBusy = NppPerf::Register("RunLoop.iterationBusy", NppPerf::Kind::Duration);
                NppPerf::RecordDuration(idBusy, (uint64_t)(busyMs * 1e6));
            }
        }
        _asleep = YES;
        _iterStart = 0;
    } else if (_iterStart == 0) {
        _iterStart = now;
    }
    while (!_recentHitchTs.empty() && now - _recentHitchTs.front() > 1.0) _recentHitchTs.pop_front();
}

// ── Recording windows ──

- (void)beginWindow {
    _ticks.clear();
    _latencyMs.clear();
    _periodsMs.clear();
    _hitches.clear();
    _busyIterMs.clear();
    _displayCycleMs.clear();
    _windowStart = CACurrentMediaTime();
    _recording = YES;
}

- (NSDictionary *)endWindow {
    _recording = NO;
    const double windowEnd = CACurrentMediaTime();
    const double periodMs = _periodsMs.empty() ? 1000.0 / self.nominalRefreshHz : PercentileOf(_periodsMs, 0.5);

    std::vector<double> intervals;
    double dropped = 0, longest = 0;
    NSInteger over15 = 0, over2 = 0, over4 = 0;
    for (size_t i = 1; i < _ticks.size(); i++) {
        const double iv = (_ticks[i] - _ticks[i - 1]) * 1000.0;
        intervals.push_back(iv);
        const double frames = std::round(iv / periodMs);
        if (frames > 1) dropped += frames - 1;
        longest = std::max(longest, iv);
        if (iv > 1.5 * periodMs) over15++;
        if (iv > 2.0 * periodMs) over2++;
        if (iv > 4.0 * periodMs) over4++;
    }
    const double durMs = (windowEnd - _windowStart) * 1000.0;
    const double expectedFrames = durMs / periodMs;
    NSDictionary *frames = @{
        @"clock": _clockKind,
        @"ticks": @(_ticks.size()),
        @"windowMs": @(durMs),
        @"refreshHzNominal": @(self.nominalRefreshHz),
        @"refreshHzMeasured": @(periodMs > 0 ? 1000.0 / periodMs : 0),
        @"periodMs": @(periodMs),
        @"intervalMs": Distribution(intervals),
        @"dropped": @(dropped),
        @"droppedPct": @(expectedFrames > 0 ? 100.0 * dropped / expectedFrames : 0),
        @"longestStallMs": @(longest),
        @"intervalsOver1_5x": @(over15),
        @"intervalsOver2x": @(over2),
        @"intervalsOver4x": @(over4),
        @"effectiveFps": @(durMs > 0 ? _ticks.size() * 1000.0 / durMs : 0),
        @"tickLatencyMs": Distribution(_latencyMs),
    };

    std::vector<double> hitchMs;
    double total = 0, mx = 0;
    NSInteger o33 = 0, o50 = 0, o100 = 0, o250 = 0;
    for (const NppHitch &h : _hitches) {
        hitchMs.push_back(h.durMs);
        total += h.durMs;
        mx = std::max(mx, h.durMs);
        if (h.durMs >= 33.3) o33++;
        if (h.durMs >= 50) o50++;
        if (h.durMs >= 100) o100++;
        if (h.durMs >= 250) o250++;
    }
    std::vector<NppHitch> top = _hitches;
    std::sort(top.begin(), top.end(), [](const NppHitch &a, const NppHitch &b) { return a.durMs > b.durMs; });
    if (top.size() > 10) top.resize(10);
    NSMutableArray *topArr = [NSMutableArray array];
    for (const NppHitch &h : top) {
        [topArr addObject:@{
            @"atMs": @((h.atS - _windowStart) * 1000.0 - h.durMs),
            @"durMs": @(h.durMs),
            @"afterActivity": ActivityName(h.before),
            @"beforeActivity": ActivityName(h.after),
        }];
    }
    NSInteger busyOver = 0;
    for (double b : _busyIterMs) if (b >= 16.7) busyOver++;
    NSDictionary *hitches = @{
        @"thresholdMs": @16.7,
        @"count": @(_hitches.size()),
        @"over33ms": @(o33),
        @"over50ms": @(o50),
        @"over100ms": @(o100),
        @"over250ms": @(o250),
        @"totalMs": @(total),
        @"maxMs": @(mx),
        @"durationMs": Distribution(hitchMs),
        @"top": topArr,
        @"busyIterationMs": Distribution(_busyIterMs),
        @"displayCycleMs": Distribution(_displayCycleMs),
        @"busyIterationsOver16ms": @(busyOver),
    };
    return @{@"frames": frames, @"hitches": hitches};
}

- (void)recentFPS:(double *)fps p95Ms:(double *)p95 maxMs:(double *)maxMs hitches:(NSInteger *)hitches {
    std::vector<double> iv;
    for (size_t i = 1; i < _recentTicks.size(); i++)
        iv.push_back((_recentTicks[i] - _recentTicks[i - 1]) * 1000.0);
    if (fps) *fps = (double)_recentTicks.size();
    if (p95) *p95 = PercentileOf(iv, 0.95);
    if (maxMs) *maxMs = iv.empty() ? 0 : *std::max_element(iv.begin(), iv.end());
    if (hitches) *hitches = (NSInteger)_recentHitchTs.size();
}

@end

// ── HUD ─────────────────────────────────────────────────────────────────────

static NSTextField *gHUDLabel;
static NppPerfFrameMonitor *gHUDMonitor;

@implementation NppPerfHUD

+ (void)attachToWindowIfRequested:(NSWindow *)window view:(NSView *)view {
    if (!gHUDRequested || gHUDLabel || !window.contentView) return;
    NSView *host = window.contentView;
    NSTextField *label = [NSTextField labelWithString:@"perf"];
    label.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    label.textColor = NSColor.whiteColor;
    label.drawsBackground = YES;
    label.backgroundColor = [NSColor colorWithWhite:0 alpha:0.65];
    label.bezeled = NO;
    label.editable = NO;
    label.selectable = NO;
    label.alignment = NSTextAlignmentRight;
    const NSSize sz = NSMakeSize(520, 18);
    const NSRect b = host.bounds;
    const CGFloat top = host.isFlipped ? 64 : NSMaxY(b) - 64 - sz.height;
    label.frame = NSMakeRect(NSMaxX(b) - sz.width - 24, top, sz.width, sz.height);
    label.autoresizingMask = NSViewMinXMargin | (host.isFlipped ? NSViewMaxYMargin : NSViewMinYMargin);
    [host addSubview:label positioned:NSWindowAbove relativeTo:nil];
    gHUDLabel = label;

    gHUDMonitor = [[NppPerfFrameMonitor alloc] initWithView:view ?: host];
    __block double lastUpdate = 0;
    gHUDMonitor.onFrame = ^(CFTimeInterval ts) {
        if (ts - lastUpdate < 0.25) return;
        lastUpdate = ts;
        NPP_PERF_COUNT("HUD.update");
        double fps = 0, p95 = 0, mx = 0;
        NSInteger hitches = 0;
        [gHUDMonitor recentFPS:&fps p95Ms:&p95 maxMs:&mx hitches:&hitches];
        NppPerf::StatSnapshot ps;
        double paintP95 = 0;
        if (NppPerf::SnapshotOne("SCIContentView.drawRect", ps)) paintP95 = ps.p95 / 1e6;
        gHUDLabel.stringValue = [NSString stringWithFormat:
            @"%3.0f fps  frame p95 %5.1f max %5.1f ms  paint %4.1f (p95 %4.1f) ms  hitch/s %ld",
            fps, p95, mx, NppPerfLastPaintDurationNs() / 1e6, paintP95, (long)hitches];
    };
    [gHUDMonitor start];
}

+ (void)detach {
    [gHUDMonitor stop];
    gHUDMonitor = nil;
    [gHUDLabel removeFromSuperview];
    gHUDLabel = nil;
}

@end
