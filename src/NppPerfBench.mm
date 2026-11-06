// Scripted scroll and render benchmark. See NppPerfBench.h.

#import "NppPerfBench.h"
#import "NppPerfDiagnostics.h"
#import "MainWindowController.h"
#import "EditorView.h"
#import "ScintillaView.h"
#import "Scintilla.h"
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>   // kVK_* key codes

#include "NppBuildInfo.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include <mach/mach.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <cmath>
#include <memory>
#include <vector>

BOOL NppPerfBenchActive(void) {
    const char *v = getenv("NPP_PERF_BENCH");
    return v && *v;
}

// ── Scenario definition ─────────────────────────────────────────────────────

@interface _NppBenchScenario : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic) NSInteger steps;
@property (nonatomic) NSInteger ticksPerStep;   // frame ticks between steps
@property (nonatomic) NSInteger tailTicks;      // ticks recorded after the last step
@property (nonatomic, copy, nullable) void (^setup)(void);
@property (nonatomic, copy) void (^step)(NSInteger i);
@property (nonatomic, copy) NSDictionary *params;
@end
@implementation _NppBenchScenario
@end

// One synthetic scroll event.
struct NppScrollInput {
    int32_t dx;
    int32_t dy;
    int phase;      // CGScrollPhase: 0 none, 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin
    int momentum;   // CGMomentumScrollPhase: 0 none, 1 begin, 2 continue, 3 end
    bool pixel;     // pixel units (trackpad) vs line units (wheel notch)
    bool noop;      // a frame with no input
};

typedef NS_ENUM(NSInteger, NppBenchPhase) {
    NppBenchWaitReady,
    NppBenchSettleOpen,
    NppBenchSetup,
    NppBenchSettle,
    NppBenchRun,
    NppBenchTail,
    NppBenchDone,
};

// How synthetic events reach the app. Events built from a CGEvent carry no
// window (the window server fills that in for real input, and posting through
// it needs Accessibility permission), so -[NSApplication postEvent:] drops
// them. The driver sends them to the window directly, with the location given
// in window coordinates so the hit test lands on the editor, and makes the
// event NSApp.currentEvent for the dispatch (private -_setCurrentEvent:, when
// present) because -[SCIContentView adjustScroll:] reads it to tell discrete
// wheels from trackpads.
static NSString *const kDeliveryCurrentEvent = @"NSWindow.sendEvent+currentEvent";
static NSString *const kDeliveryPlain = @"NSWindow.sendEvent";

// Dispatch `ev` as the current event: to `view` directly when given, else
// through -[NSWindow sendEvent:].
static void DispatchAsCurrentEvent(NSWindow *win, NSEvent *ev, NSView *view = nil) {
    static SEL setter = NSSelectorFromString(@"_setCurrentEvent:");
    const BOOL canSet = [NSApp respondsToSelector:setter];
    NSEvent *previous = NSApp.currentEvent;
    if (canSet) ((void (*)(id, SEL, id))objc_msgSend)(NSApp, setter, ev);
    if (view) [view scrollWheel:ev];
    else [win sendEvent:ev];
    if (canSet) ((void (*)(id, SEL, id))objc_msgSend)(NSApp, setter, previous);
}

static NSString *EventDelivery(void) {
    return [NSApp respondsToSelector:NSSelectorFromString(@"_setCurrentEvent:")] ? kDeliveryCurrentEvent : kDeliveryPlain;
}

@implementation NppPerfBench {
    __weak MainWindowController *_mwc;
    NppPerfFrameMonitor *_monitor;
    NSArray<_NppBenchScenario *> *_queue;
    NSInteger _queueIndex;
    NppBenchPhase _phase;
    NSInteger _phaseTicks;
    NSInteger _stepIndex;
    NSInteger _ticksUntilStep;
    double _phaseStart;
    uint64_t _paintsAtQuietCheck;
    double _lastPaintChange;
    double _scenarioStart;
    double _cpuStart;
    double _mainCpuStart;
    os_signpost_id_t _scenarioSpid;

    NSRect _baseFrame;
    NSString *_reportPath;
    NSMutableDictionary *_report;
    NSMutableArray *_scenarioResults;
    NSMutableArray *_errors;

    NSInteger _scrollPosted;
    NSInteger _scrollProbeBaseline;
    BOOL _scrollDeliveryVerified;

    // hv_scroll: view state after each gesture, and the clip view movement
    // of every scroll event in the current gesture.
    NSMutableArray<NSDictionary *> *_checkpoints;
    NSMutableArray<NSNumber *> *_gestureDx;
    NSMutableArray<NSNumber *> *_gestureDy;
    NSPoint _gestureStart;
    NSInteger _gestureOutside;
}

static NppPerfBench *gBench;

+ (NSArray<NSString *> *)scenarioNames {
    return @[@"smooth_scroll", @"smooth_scroll_mid", @"fling", @"wheel_notch", @"page_down",
             @"jump_end_home", @"hscroll", @"diagonal", @"hv_scroll", @"selection_scroll", @"caret_down",
             @"resize", @"zoom", @"idle"];
}

+ (void)startIfRequestedWithController:(MainWindowController *)controller {
    if (!NppPerfBenchActive() || gBench) return;
    gBench = [[NppPerfBench alloc] initWithController:controller];
    [gBench _start];
}

- (instancetype)initWithController:(MainWindowController *)controller {
    if ((self = [super init])) {
        _mwc = controller;
        _scenarioResults = [NSMutableArray array];
        _errors = [NSMutableArray array];
        const char *rp = getenv("NPP_PERF_REPORT");
        _reportPath = (rp && *rp) ? [NSString stringWithUTF8String:rp]
                                  : [NSString stringWithFormat:@"/tmp/nextpad-perf-%d.json", getpid()];
    }
    return self;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

- (EditorView *)_editor { return [_mwc currentEditor]; }
- (ScintillaView *)_sci { return [self _editor].scintillaView; }
- (NSView *)_content { return [self _sci].content; }

- (sptr_t)_msg:(unsigned)m { return [[self _sci] message:m wParam:0 lParam:0]; }
- (sptr_t)_msg:(unsigned)m w:(uptr_t)w { return [[self _sci] message:m wParam:w lParam:0]; }
- (sptr_t)_msg:(unsigned)m w:(uptr_t)w l:(sptr_t)l { return [[self _sci] message:m wParam:w lParam:l]; }

// CPU time (user + system) of the whole process and of the main thread, in
// ms. Independent of the probes, so it also measures runs with probes off.
static double ProcessCPUms(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000.0 +
           (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1000.0;
}

static double MainThreadCPUms(void) {
    static thread_act_t mainThread = mach_thread_self();   // first call is on the main thread
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(mainThread, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (info.user_time.seconds + info.system_time.seconds) * 1000.0 +
           (info.user_time.microseconds + info.system_time.microseconds) / 1000.0;
}

static NSInteger EnvInteger(const char *name, NSInteger dflt) {
    const char *v = getenv(name);
    return (v && *v) ? (NSInteger)atol(v) : dflt;
}

static NSString *Sysctl(const char *name) {
    char buf[256] = {0};
    size_t len = sizeof(buf) - 1;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0) return @"";
    return [NSString stringWithUTF8String:buf] ?: @"";
}

// Deliver one scroll-wheel event through the real event path.
- (void)_scroll:(const NppScrollInput &)in {
    if (in.noop) return;
    NSView *content = [self _content];
    NSWindow *win = content.window;
    if (!content || !win) return;
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, in.pixel ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine,
                                                  2, in.dy, in.dx);
    if (!cg) return;
    // Aim at the middle of the visible text. The event has no window, so its
    // locationInWindow is its screen location: give the window coordinates
    // (CG locations are top-left origin on the primary display).
    const NSRect vis = content.visibleRect;
    const NSPoint mid = NSMakePoint(NSMidX(vis), NSMidY(vis));
    const NSPoint inWin = [content convertPoint:mid toView:nil];
    const CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    CGEventSetLocation(cg, CGPointMake(inWin.x, primaryHeight - inWin.y));
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, in.pixel ? 1 : 0);
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, in.phase);
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, in.momentum);
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, win.windowNumber);
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, win.windowNumber);
    // NPP_PERF_SCROLL_POST=1: post the event through the window server
    // (CGEventPost at the HID tap, at the screen location of the text), so
    // NSWindow routes the gesture and its momentum events and NSScrollView
    // latches the momentum as it does for a trackpad. Needs the event-posting
    // (Accessibility) permission of the process that launched the app, and
    // the window frontmost at that point (run_perf.sh --activate). The
    // per-event movement in the hv_scroll checkpoints is then not recorded.
    static const BOOL postToHID = EnvInteger("NPP_PERF_SCROLL_POST", 0) > 0;
    if (postToHID) {
        const NSPoint onScreen = [win convertPointToScreen:inWin];
        CGEventSetLocation(cg, CGPointMake(onScreen.x, primaryHeight - onScreen.y));
        _scrollPosted++;
        CGEventPost(kCGHIDEventTap, cg);
        CFRelease(cg);
        return;
    }
    NSEvent *ev = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    if (!ev) return;
    _scrollPosted++;
    NSClipView *clip = content.enclosingScrollView.contentView;
    const NSPoint before = clip.bounds.origin;
    // NSWindow drops momentum-phase events that do not follow a gesture it
    // tracked itself (synthetic gestures are not tracked), so momentum goes
    // to the content view's -scrollWheel: directly; the scroll view path
    // from there on is the same.
    DispatchAsCurrentEvent(win, ev, in.momentum ? content : nil);
    if (_gestureDy) {
        const NSPoint after = clip.bounds.origin;
        [_gestureDx addObject:@(after.x - before.x)];
        [_gestureDy addObject:@(after.y - before.y)];
        // NSScrollView's "scroll occurred outside of gesture" flag: set by
        // every -reflectScrolledClipView:, cleared when a gesture begins.
        // While it is clear, NSScrollingBehaviorLegacy handles the gesture
        // and its momentum on its rubber-band path.
        static SEL outsideSel = NSSelectorFromString(@"_hasScrollOccurredOutsideOfGesture");
        NSScrollView *sv = content.enclosingScrollView;
        if ([sv respondsToSelector:outsideSel] && ((BOOL (*)(id, SEL))objc_msgSend)(sv, outsideSel))
            _gestureOutside++;
    }
}

// hv_scroll: where the view is after a gesture. The clip view origin is
// where AppKit scrolled to; firstVisibleLine and xOffset are where Scintilla
// thinks it is; the text view's content sublayer is what AppKit composites
// (on macOS 26 and later it follows the visible rect).
- (NSDictionary *)_viewState {
    NSView *content = [self _content];
    NSClipView *clip = content.enclosingScrollView.contentView;
    const NSRect cb = clip.bounds;
    const NSRect vis = content.visibleRect;
    const sptr_t lineHeight = [self _msg:SCI_TEXTHEIGHT w:0];
    NSMutableDictionary *d = [@{
        @"firstVisibleLine": @([self _msg:SCI_GETFIRSTVISIBLELINE]),
        @"xOffset": @([self _msg:SCI_GETXOFFSET]),
        @"clipX": @(cb.origin.x),
        @"clipY": @(cb.origin.y),
        @"clipLine": @(lineHeight > 0 ? cb.origin.y / (double)lineHeight : 0),
        @"lineHeight": @(lineHeight),
        @"visibleRect": NSStringFromRect(vis),
    } mutableCopy];
    // NSScrollView's rubber-band stretch (elastic overscroll past the
    // document edge). On its rubber-band path NSScrollView drops the rest of
    // a momentum scroll that does not move along a stretched axis.
    NSScrollView *sv = content.enclosingScrollView;
    static SEL stretchSel = NSSelectorFromString(@"_stretchAmount");
    if ([sv respondsToSelector:stretchSel]) {
        const NSSize st = ((NSSize (*)(id, SEL))objc_msgSend)(sv, stretchSel);
        d[@"stretchX"] = @(st.width);
        d[@"stretchY"] = @(st.height);
    }
    d[@"documentRect"] = NSStringFromRect(clip.documentRect);
    NSMutableArray *subs = [NSMutableArray array];
    for (CALayer *sub in content.layer.sublayers)
        [subs addObject:[NSString stringWithFormat:@"%@ frame=%@ contentsFormat=%@",
                         NSStringFromClass([sub class]), NSStringFromRect(NSRectFromCGRect(sub.frame)),
                         sub.contentsFormat]];
    d[@"contentSublayers"] = subs;
    return d;
}

// Synthetic scroll events must reach -[SCIContentView scrollWheel:]. With
// probes on, check once per scenario after a few events.
- (void)_verifyScrollDelivery {
    if (_scrollDeliveryVerified || _scrollPosted < 3 || !NppPerf::On()) return;
    NppPerf::StatSnapshot s;
    const uint64_t seen = NppPerf::SnapshotOne("SCIContentView.scrollWheel", s) ? s.count : 0;
    _scrollDeliveryVerified = YES;
    if ((NSInteger)seen < _scrollProbeBaseline + 1)
        [_errors addObject:[NSString stringWithFormat:@"%@: scroll events did not reach the content view",
                            _queue[(NSUInteger)_queueIndex].name]];
}

- (void)_key:(unsigned short)keyCode chars:(unichar)ch modifiers:(NSEventModifierFlags)mods {
    NSWindow *win = [self _content].window;
    if (!win) return;
    NSString *s = [NSString stringWithCharacters:&ch length:1];
    const NSTimeInterval ts = [NSProcessInfo processInfo].systemUptime;
    NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods
                                    timestamp:ts windowNumber:win.windowNumber context:nil
                                   characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:keyCode];
    NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:mods
                                  timestamp:ts windowNumber:win.windowNumber context:nil
                                 characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:keyCode];
    // Straight to the window: the first responder gets keyDown: without
    // menu key equivalents, so the same Scintilla command runs every time.
    DispatchAsCurrentEvent(win, down);
    DispatchAsCurrentEvent(win, up);
}

- (void)_resetView {
    EditorView *ed = [self _editor];
    if (!ed) return;
    NSWindow *win = [self _content].window;
    if (win && !NSEqualRects(win.frame, _baseFrame)) [win setFrame:_baseFrame display:YES];
    if ([self _msg:SCI_GETZOOM] != 0) [self _msg:SCI_SETZOOM w:0];
    [self _msg:SCI_SETEMPTYSELECTION w:0];
    [self _msg:SCI_GOTOPOS w:0];
    [self _msg:SCI_SETFIRSTVISIBLELINE w:0];
    [self _msg:SCI_SETXOFFSET w:0];
    if (win && [self _content]) [win makeFirstResponder:[self _content]];
}

// ── Scenario construction ───────────────────────────────────────────────────

static std::vector<NppScrollInput> SmoothGesture(int frames, int dx, int dy) {
    std::vector<NppScrollInput> v;
    for (int i = 0; i < frames; i++) {
        const int phase = (i == 0) ? 1 : (i == frames - 1 ? 4 : 2);
        const bool last = (i == frames - 1);
        v.push_back({last ? 0 : dx, last ? 0 : dy, phase, 0, true, false});
    }
    return v;
}

static std::vector<NppScrollInput> Fling(int dy0) {
    std::vector<NppScrollInput> v;
    // Finger on the trackpad: a short, fast swipe.
    v.push_back({0, dy0 / 4, 1, 0, true, false});
    for (int i = 0; i < 5; i++) v.push_back({0, dy0 / 3, 2, 0, true, false});
    v.push_back({0, 0, 4, 0, true, false});
    // Momentum after lift-off, decaying like the system's inertial scroll.
    double d = dy0;
    v.push_back({0, (int32_t)d, 0, 1, true, false});
    while (std::fabs(d) >= 1.0) {
        d *= 0.95;
        v.push_back({0, (int32_t)std::lround(d), 0, 2, true, false});
    }
    v.push_back({0, 0, 0, 3, true, false});
    return v;
}

- (_NppBenchScenario *)_scrollScenario:(NSString *)name
                               summary:(NSString *)summary
                                inputs:(std::vector<NppScrollInput>)inputs
                          ticksPerStep:(NSInteger)tps
                                 setup:(void (^)(void))setup
                                params:(NSDictionary *)params {
    __weak NppPerfBench *weakSelf = self;
    auto shared = std::make_shared<std::vector<NppScrollInput>>(std::move(inputs));
    _NppBenchScenario *s = [_NppBenchScenario new];
    s.name = name;
    s.summary = summary;
    s.steps = (NSInteger)shared->size();
    s.ticksPerStep = tps;
    s.tailTicks = 45;
    s.setup = setup;
    s.params = params;
    s.step = ^(NSInteger i) {
        NppPerfBench *b = weakSelf;
        [b _scroll:(*shared)[(size_t)i]];
        [b _verifyScrollDelivery];
    };
    return s;
}

- (_NppBenchScenario *)_keyScenario:(NSString *)name summary:(NSString *)summary
                              steps:(NSInteger)steps ticksPerStep:(NSInteger)tps
                              setup:(void (^)(void))setup
                               keys:(void (^)(NSInteger i))keys
                             params:(NSDictionary *)params {
    _NppBenchScenario *s = [_NppBenchScenario new];
    s.name = name;
    s.summary = summary;
    s.steps = steps;
    s.ticksPerStep = tps;
    s.tailTicks = 45;
    s.setup = setup;
    s.step = keys;
    s.params = params;
    return s;
}

// ── Link-scan edits (verification only) ────────────────────────────────────

// Deterministic xorshift, so every run makes the same edits.
static uint64_t gLinkEditRng = 0x9E3779B97F4A7C15ull;
static uint64_t LinkEditRand(void) {
    gLinkEditRng ^= gLinkEditRng << 13; gLinkEditRng ^= gLinkEditRng >> 7; gLinkEditRng ^= gLinkEditRng << 17;
    return gLinkEditRng;
}
static sptr_t LinkEditRandIn(sptr_t lo, sptr_t hi) {
    return hi <= lo ? lo : lo + (sptr_t)(LinkEditRand() % (uint64_t)(hi - lo + 1));
}

// The last document line -[EditorView updateClickableLinks] scans.
- (sptr_t)_linkScanLastLine {
    const sptr_t vis = [self _msg:SCI_GETFIRSTVISIBLELINE] + [self _msg:SCI_LINESONSCREEN] + 1;
    return MIN([self _msg:SCI_DOCLINEFROMVISIBLE w:(uptr_t)vis], [self _msg:SCI_GETLINECOUNT] - 1);
}

// A character-boundary position on a random visible line.
- (sptr_t)_randomVisiblePos {
    const sptr_t first = [self _msg:SCI_DOCLINEFROMVISIBLE w:(uptr_t)[self _msg:SCI_GETFIRSTVISIBLELINE]];
    const sptr_t line = MIN(LinkEditRandIn(first, first + [self _msg:SCI_LINESONSCREEN] - 1),
                            [self _msg:SCI_GETLINECOUNT] - 1);
    const sptr_t p = LinkEditRandIn([self _msg:SCI_POSITIONFROMLINE w:(uptr_t)line],
                                    [self _msg:SCI_GETLINEENDPOSITION w:(uptr_t)line]);
    return [self _msg:SCI_POSITIONBEFORE w:(uptr_t)[self _msg:SCI_POSITIONAFTER w:(uptr_t)p]];
}

// One step of link_edits. Every tenth step types a newline inside a link on
// the last scanned line (the inserted newline takes the link's indicator, so
// that line's end is marked until a scan clears it) and the next steps scroll
// one line at a time, so the following scans cover only the lines below it.
// The other steps make random edits, undo and redo, and scroll.
- (void)_linkEditStep:(NSInteger)i {
    static const char *snippets[] = {
        "http://example.com/a?b=1 ", "www.example.org ", "mailto:x@y.co ", "svn://h/r ",
        "user@mail.example.net ", "https://", "example.com", "\n", " ", "ftp://f.example.com/x.txt",
        "(http://x.y/z).", "\xC3\xA9\xE2\x82\xAC ", "123.456\t789 ", "git://g.example/x ",
        "https://\xCE\xB5\xCE\xBB(http://x.y/z).\xCE\xBB\xCE\xB7\xCE\xBD\xCE\xB9\xCE\xBA\xCE\xAC.example/\xCE\xB4 "};
    const int nSnip = (int)(sizeof(snippets) / sizeof(snippets[0]));
    const unsigned linkInd = 8;   // kClickableLinkIndicator (NppScintillaIDs.h)
    const NSInteger k = i % 10;
    if (k == 0) {
        const sptr_t line = [self _linkScanLastLine];
        const sptr_t a = [self _msg:SCI_POSITIONFROMLINE w:(uptr_t)line];
        const sptr_t e = [self _msg:SCI_GETLINEENDPOSITION w:(uptr_t)line];
        for (sptr_t q = a; q < e; q++) {
            if ([self _msg:SCI_INDICATORVALUEAT w:linkInd l:q]) {
                const sptr_t end = [self _msg:SCI_INDICATOREND w:linkInd l:q];
                [self _msg:SCI_INSERTTEXT w:(uptr_t)(q + (end - q) / 2) l:(sptr_t)"\n"];
                NPP_PERF_COUNT("Bench.linkEdits.newlineInLink");
                return;
            }
        }
        // No link there yet: add one at the line end for the next round.
        [self _msg:SCI_INSERTTEXT w:(uptr_t)e l:(sptr_t)" http://boundary.example/abcdef"];
        return;
    }
    if (k <= 3) { [self _msg:SCI_LINESCROLL w:0 l:1]; return; }
    switch (LinkEditRand() % 10) {
        case 0: case 1: case 2:
            [self _msg:SCI_INSERTTEXT w:(uptr_t)[self _randomVisiblePos]
                     l:(sptr_t)snippets[LinkEditRand() % (uint64_t)nSnip]];
            break;
        case 3: {
            const sptr_t p = [self _randomVisiblePos];
            sptr_t e = MIN([self _msg:SCI_GETLENGTH], p + LinkEditRandIn(1, 60));
            e = [self _msg:SCI_POSITIONBEFORE w:(uptr_t)[self _msg:SCI_POSITIONAFTER w:(uptr_t)e]];
            if (e > p) [self _msg:SCI_DELETERANGE w:(uptr_t)p l:e - p];
            break;
        }
        case 4: [self _msg:SCI_UNDO]; break;
        case 5: [self _msg:SCI_REDO]; break;
        case 6: case 7: [self _msg:SCI_LINESCROLL w:0 l:LinkEditRandIn(-3, 3)]; break;
        case 8: [self _key:kVK_PageDown chars:NSPageDownFunctionKey modifiers:NSEventModifierFlagFunction]; break;
        default: {
            NppScrollInput in = {0, (int32_t)LinkEditRandIn(-40, 40), 0, 0, true, false};
            [self _scroll:in];
            break;
        }
    }
}

- (NSArray<_NppBenchScenario *> *)_buildScenarios {
    __weak NppPerfBench *weakSelf = self;
    void (^top)(void) = ^{ [weakSelf _resetView]; };
    NSMutableDictionary<NSString *, _NppBenchScenario *> *all = [NSMutableDictionary dictionary];

    const int smoothFrames = 360, smoothDy = -12;
    all[@"smooth_scroll"] = [self _scrollScenario:@"smooth_scroll"
        summary:@"Trackpad-like pixel scroll down from the top: one precise event per frame, 12 px each, 360 frames"
        inputs:SmoothGesture(smoothFrames, 0, smoothDy) ticksPerStep:1 setup:top
        params:@{@"events": @(smoothFrames), @"pxPerEvent": @(-smoothDy), @"unit": @"pixel"}];

    all[@"smooth_scroll_mid"] = [self _scrollScenario:@"smooth_scroll_mid"
        summary:@"Same pixel scroll, starting at the middle line of the document"
        inputs:SmoothGesture(smoothFrames, 0, smoothDy) ticksPerStep:1
        setup:^{
            NppPerfBench *b = weakSelf;
            [b _resetView];
            const sptr_t mid = [b _msg:SCI_GETLINECOUNT] / 2;
            [b _msg:SCI_GOTOLINE w:(uptr_t)mid];
            [b _msg:SCI_SETFIRSTVISIBLELINE w:(uptr_t)mid];
        }
        params:@{@"events": @(smoothFrames), @"pxPerEvent": @(-smoothDy), @"unit": @"pixel", @"start": @"middle"}];

    std::vector<NppScrollInput> flings;
    for (int k = 0; k < 3; k++) {
        auto f = Fling(-160);
        flings.insert(flings.end(), f.begin(), f.end());
        for (int g = 0; g < 20; g++) flings.push_back({0, 0, 0, 0, true, true});
    }
    const NSInteger flingEvents = (NSInteger)flings.size();
    all[@"fling"] = [self _scrollScenario:@"fling"
        summary:@"Three fast trackpad flings with decaying momentum events (x0.95 per frame from 160 px)"
        inputs:flings ticksPerStep:1 setup:top
        params:@{@"flings": @3, @"momentumStartPx": @160, @"decay": @0.95, @"frames": @(flingEvents)}];

    std::vector<NppScrollInput> notches;
    for (int i = 0; i < 240; i++) notches.push_back({0, -1, 0, 0, false, false});
    all[@"wheel_notch"] = [self _scrollScenario:@"wheel_notch"
        summary:@"Discrete mouse wheel: 240 one-line notches down, one every 3 frames"
        inputs:notches ticksPerStep:3 setup:top
        params:@{@"notches": @240, @"linesPerNotch": @1, @"ticksPerNotch": @3, @"unit": @"line"}];

    all[@"page_down"] = [self _keyScenario:@"page_down"
        summary:@"Page Down key 120 times, one every 4 frames"
        steps:120 ticksPerStep:4 setup:top
        keys:^(NSInteger i) {
            [weakSelf _key:kVK_PageDown chars:NSPageDownFunctionKey modifiers:NSEventModifierFlagFunction];
        }
        params:@{@"presses": @120, @"ticksPerPress": @4}];

    all[@"jump_end_home"] = [self _keyScenario:@"jump_end_home"
        summary:@"Cmd+End then Cmd+Home, six times, 60 frames apart"
        steps:12 ticksPerStep:60 setup:top
        keys:^(NSInteger i) {
            const NSEventModifierFlags mods = NSEventModifierFlagCommand | NSEventModifierFlagFunction;
            if (i % 2 == 0) [weakSelf _key:kVK_End chars:NSEndFunctionKey modifiers:mods];
            else [weakSelf _key:kVK_Home chars:NSHomeFunctionKey modifiers:mods];
        }
        params:@{@"cycles": @6, @"ticksBetween": @60}];

    std::vector<NppScrollInput> h = SmoothGesture(120, -12, 0);
    std::vector<NppScrollInput> back = SmoothGesture(120, 12, 0);
    h.insert(h.end(), back.begin(), back.end());
    all[@"hscroll"] = [self _scrollScenario:@"hscroll"
        summary:@"Horizontal pixel scroll right 120 frames then back left 120 frames, 12 px each"
        inputs:h ticksPerStep:1 setup:top
        params:@{@"framesEachWay": @120, @"pxPerEvent": @12, @"unit": @"pixel"}];

    // A trackpad swipe is rarely exactly vertical or horizontal. NSScrollView
    // locks each gesture to its predominant axis, so the first swipe scrolls
    // right only and the second down only; the minor axis deltas still reach
    // -scrollWheel: and -adjustScroll:.
    std::vector<NppScrollInput> d = SmoothGesture(120, -10, -6);
    std::vector<NppScrollInput> dDown = SmoothGesture(120, -6, -10);
    d.insert(d.end(), dDown.begin(), dDown.end());
    all[@"diagonal"] = [self _scrollScenario:@"diagonal"
        summary:@"Two diagonal pixel swipes: mostly right (10 px right, 6 px down per frame), then mostly down (6 px right, 10 px down), 120 frames each"
        inputs:d ticksPerStep:1 setup:top
        params:@{@"framesEachSwipe": @120, @"pxMajor": @10, @"pxMinor": @6, @"unit": @"pixel"}];

    // Trackpad: vertical gestures, then horizontal flings, each followed by
    // a vertical fling. The view state is recorded after each gesture (see
    // -_viewState) with the distance the clip view moved; every vertical
    // fling should move, momentum included, as far as the first one.
    {
        struct Gesture { NSString *name; std::vector<NppScrollInput> inputs; };
        // Fingers on the trackpad for `frames` events of (dx, dy), then (when
        // v0 is not zero) momentum after lift-off from (v0x, v0y), decaying
        // by 0.9 per frame like the system's inertial scroll.
        auto gesture = [](int frames, int dx, int dy, int v0x, int v0y) {
            std::vector<NppScrollInput> v;
            // Fingers down: a trackpad sends "may begin" before the first
            // movement (CGScrollPhase 128).
            v.push_back({0, 0, 128, 0, true, false});
            for (int i = 0; i < frames; i++)
                v.push_back({dx, dy, i == 0 ? 1 : 2, 0, true, false});
            v.push_back({0, 0, 4, 0, true, false});
            if (v0x == 0 && v0y == 0) return v;
            double fx = v0x, fy = v0y;
            v.push_back({v0x, v0y, 0, 1, true, false});
            while (std::fabs(fx) >= 1.0 || std::fabs(fy) >= 1.0) {
                fx *= 0.9; fy *= 0.9;
                v.push_back({(int32_t)std::lround(fx), (int32_t)std::lround(fy), 0, 2, true, false});
            }
            v.push_back({0, 0, 0, 3, true, false});
            return v;
        };
        auto gestures = std::make_shared<std::vector<Gesture>>(std::vector<Gesture>{
            {@"down", gesture(30, 0, -12, 0, 0)},
            {@"downSlow", gesture(30, 0, -3, 0, 0)},
            {@"downFling", gesture(8, 0, -14, 0, -30)},
            {@"rightFling", gesture(30, -12, 0, -20, 0)},
            {@"down", gesture(30, 0, -12, 0, 0)},
            {@"downSlow", gesture(30, 0, -3, 0, 0)},
            {@"downFling", gesture(8, 0, -14, 0, -30)},
            {@"upFling", gesture(8, 0, 14, 0, 30)},
            {@"left", gesture(30, 12, 0, 0, 0)},
            {@"downFling", gesture(8, 0, -14, 0, -30)},
            {@"rightToEdge", gesture(60, -40, 0, -60, 0)},
            {@"downFling", gesture(8, 0, -14, 0, -30)},
            {@"leftToEdge", gesture(60, 40, 0, 60, 0)},
            {@"downFling", gesture(8, 0, -14, 0, -30)},
        });
        // Idle frames after each gesture before its checkpoint. At the
        // default, a gesture that ran past the left edge is still springing
        // back when the next one starts.
        const int gap = (int)EnvInteger("NPP_PERF_HV_GAP", 20);
        auto plan = std::make_shared<std::vector<std::pair<int, int>>>();   // (gesture, input index or -1 idle)
        for (int g = 0; g < (int)gestures->size(); g++) {
            for (int k = 0; k < (int)(*gestures)[g].inputs.size(); k++) plan->push_back({g, k});
            for (int k = 0; k < gap; k++) plan->push_back({g, -1});
        }
        _NppBenchScenario *hv = [_NppBenchScenario new];
        hv.name = @"hv_scroll";
        hv.summary = @"Trackpad: vertical gestures (12 px, 3 px, a fling with momentum), horizontal flings (one past each edge), each followed by a vertical fling; view state after each";
        hv.steps = (NSInteger)plan->size();
        hv.ticksPerStep = 1;
        hv.tailTicks = 45;
        hv.setup = top;
        hv.params = @{@"gestures": @(gestures->size()), @"idleFramesAfterGesture": @(gap), @"unit": @"pixel"};
        hv.step = ^(NSInteger i) {
            NppPerfBench *b = weakSelf;
            if (!b) return;
            const auto [g, k] = (*plan)[(size_t)i];
            if (!b->_checkpoints) b->_checkpoints = [NSMutableArray array];
            if (k == 0) {
                b->_gestureDx = [NSMutableArray array];
                b->_gestureDy = [NSMutableArray array];
                b->_gestureStart = [b _content].enclosingScrollView.contentView.bounds.origin;
                b->_gestureOutside = 0;
            }
            if (k >= 0) {
                [b _scroll:(*gestures)[(size_t)g].inputs[(size_t)k]];
                [b _verifyScrollDelivery];
            }
            const bool lastOfGesture = (size_t)i + 1 == plan->size() || (*plan)[(size_t)i + 1].first != g;
            if (!lastOfGesture) return;
            const NSPoint end = [b _content].enclosingScrollView.contentView.bounds.origin;
            const double mx = end.x - b->_gestureStart.x, my = end.y - b->_gestureStart.y;
            NSInteger moving = 0;
            for (NSUInteger e = 0; e < b->_gestureDy.count; e++)
                if (b->_gestureDx[e].doubleValue != 0 || b->_gestureDy[e].doubleValue != 0) moving++;
            double reqX = 0, reqY = 0;
            for (const auto &in : (*gestures)[(size_t)g].inputs) { reqX -= in.dx; reqY -= in.dy; }
            NSMutableDictionary *c = [[b _viewState] mutableCopy];
            c[@"gesture"] = (*gestures)[(size_t)g].name;
            c[@"index"] = @(g);
            c[@"requestedX"] = @(reqX);
            c[@"requestedY"] = @(reqY);
            c[@"movedX"] = @(mx);
            c[@"movedY"] = @(my);
            c[@"events"] = @(b->_gestureDy.count);
            c[@"eventsThatMoved"] = @(moving);
            c[@"eventsScrolledOutsideGesture"] = @(b->_gestureOutside);
            c[@"eventDy"] = [b->_gestureDy copy];
            [b->_checkpoints addObject:c];
            b->_gestureDx = nil;
            b->_gestureDy = nil;
        };
        all[@"hv_scroll"] = hv;
    }

    all[@"selection_scroll"] = [self _scrollScenario:@"selection_scroll"
        summary:@"Pixel scroll down with a selection from line 4 to line 1200 active"
        inputs:SmoothGesture(smoothFrames, 0, smoothDy) ticksPerStep:1
        setup:^{
            NppPerfBench *b = weakSelf;
            [b _resetView];
            const sptr_t lines = [b _msg:SCI_GETLINECOUNT];
            const sptr_t a = [b _msg:SCI_POSITIONFROMLINE w:(uptr_t)MIN((sptr_t)3, lines - 1)];
            const sptr_t c = [b _msg:SCI_GETLINEENDPOSITION w:(uptr_t)MIN((sptr_t)1199, lines - 1)];
            [b _msg:SCI_SETSEL w:(uptr_t)a l:c];
            [b _msg:SCI_SETFIRSTVISIBLELINE w:0];
            [b _msg:SCI_SETXOFFSET w:0];
        }
        params:@{@"events": @(smoothFrames), @"pxPerEvent": @(-smoothDy), @"selection": @"lines 4-1200"}];

    all[@"caret_down"] = [self _keyScenario:@"caret_down"
        summary:@"Down arrow 240 times, one every 4 frames (30 Hz key repeat)"
        steps:240 ticksPerStep:4 setup:top
        keys:^(NSInteger i) {
            [weakSelf _key:kVK_DownArrow chars:NSDownArrowFunctionKey
                 modifiers:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad];
        }
        params:@{@"presses": @240, @"ticksPerPress": @4}];

    _NppBenchScenario *resize = [_NppBenchScenario new];
    resize.name = @"resize";
    resize.summary = @"Window resized every frame along a triangle wave (down to -400 x -250 pt), two cycles of 60 frames";
    resize.steps = 120;
    resize.ticksPerStep = 1;
    resize.tailTicks = 45;
    resize.setup = top;
    resize.params = @{@"frames": @120, @"dw": @400, @"dh": @250, @"cycles": @2};
    resize.step = ^(NSInteger i) {
        NppPerfBench *b = weakSelf;
        if (!b) return;
        const double phase = (double)(i % 60) / 60.0;
        const double tri = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
        NSRect f = b->_baseFrame;
        f.size.width -= std::round(400 * tri);
        const double dh = std::round(250 * tri);
        f.size.height -= dh;
        f.origin.y += dh;   // keep the top edge fixed
        [[b _content].window setFrame:f display:YES];
    };
    all[@"resize"] = resize;

    all[@"zoom"] = [self _keyScenario:@"zoom"
        summary:@"SCI_ZOOMIN three times then SCI_ZOOMOUT three times, 20 frames apart"
        steps:6 ticksPerStep:20 setup:top
        keys:^(NSInteger i) {
            [weakSelf _msg:(i < 3 ? SCI_ZOOMIN : SCI_ZOOMOUT)];
        }
        params:@{@"steps": @6, @"ticksBetween": @20}];

    _NppBenchScenario *idle = [_NppBenchScenario new];
    idle.name = @"idle";
    idle.summary = @"No input for 240 frames: background timers and idle work only";
    idle.steps = 240;
    idle.ticksPerStep = 1;
    idle.tailTicks = 0;
    idle.setup = top;
    idle.params = @{@"frames": @240};
    idle.step = ^(NSInteger i) {};
    all[@"idle"] = idle;

    // Not part of "all": edits the open document (in memory only; the file
    // is opened read-only and never saved) to check the clickable-link scan
    // cache with NPP_LINK_VERIFY=1. Its timings are not comparable.
    _NppBenchScenario *linkEdits = [_NppBenchScenario new];
    linkEdits.name = @"link_edits";
    linkEdits.summary = @"VERIFY: newlines typed inside links on the last scanned line, random edits, undo and scrolling";
    linkEdits.steps = 400;
    linkEdits.ticksPerStep = 2;
    linkEdits.tailTicks = 10;
    linkEdits.params = @{@"steps": @400, @"seed": @"xorshift 0x9E3779B97F4A7C15"};
    linkEdits.setup = ^{
        NppPerfBench *b = weakSelf;
        [b _resetView];
        gLinkEditRng = 0x9E3779B97F4A7C15ull;
        [b _msg:SCI_SETREADONLY w:0];
        [b _msg:SCI_EMPTYUNDOBUFFER];
    };
    linkEdits.step = ^(NSInteger i) {
        NppPerfBench *b = weakSelf;
        [b _linkEditStep:i];
        if (i == 399) {
            // Leave the document as it was opened.
            while ([b _msg:SCI_CANUNDO]) [b _msg:SCI_UNDO];
            [b _msg:SCI_SETSAVEPOINT];
            [b _msg:SCI_SETREADONLY w:1];
        }
    };
    all[@"link_edits"] = linkEdits;

    // Selection from NPP_PERF_BENCH.
    NSString *spec = [NSString stringWithUTF8String:getenv("NPP_PERF_BENCH") ?: ""];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *raw in [spec componentsSeparatedByString:@","]) {
        NSString *n = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!n.length || [n isEqualToString:@"open"]) continue;
        if ([n isEqualToString:@"all"]) { [names addObjectsFromArray:[NppPerfBench scenarioNames]]; continue; }
        if (all[n]) [names addObject:n];
        else [_errors addObject:[NSString stringWithFormat:@"unknown scenario '%@'", n]];
    }
    const NSInteger repeat = MAX((NSInteger)1, EnvInteger("NPP_PERF_BENCH_REPEAT", 1));
    NSMutableArray *queue = [NSMutableArray array];
    for (NSString *n in names)
        for (NSInteger r = 0; r < repeat; r++) [queue addObject:all[n]];
    return queue;
}

// ── Driver ──────────────────────────────────────────────────────────────────

- (void)_start {
    NppPerfMark(@"bench.start");
    MainThreadCPUms();   // capture the main thread's port while on it
    _report = [NSMutableDictionary dictionary];
    _queue = [self _buildScenarios];
    _phase = NppBenchWaitReady;
    _phaseStart = CACurrentMediaTime();
    NSView *view = [self _content] ?: _mwc.window.contentView;
    _monitor = [[NppPerfFrameMonitor alloc] initWithView:view];
    __weak NppPerfBench *weakSelf = self;
    _monitor.onFrame = ^(CFTimeInterval ts) { [weakSelf _tick:ts]; };
    [_monitor start];
    // Watchdog: a stuck scenario still produces a report.
    const NSInteger timeout = EnvInteger("NPP_PERF_BENCH_TIMEOUT", 900);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NppPerfBench *b = weakSelf;
        if (b && b->_phase != NppBenchDone) {
            [b->_errors addObject:[NSString stringWithFormat:@"watchdog: benchmark exceeded %ld s", (long)timeout]];
            [b _finish];
        }
    });
}

- (void)_enter:(NppBenchPhase)phase {
    _phase = phase;
    _phaseTicks = 0;
    _phaseStart = CACurrentMediaTime();
    _paintsAtQuietCheck = NppPerfContentPaintCount();
    _lastPaintChange = _phaseStart;
}

// YES once no content paint happened for quietS seconds (and minTicks passed).
- (BOOL)_quietFor:(double)quietS minTicks:(NSInteger)minTicks now:(double)now {
    const uint64_t paints = NppPerfContentPaintCount();
    if (paints != _paintsAtQuietCheck) {
        _paintsAtQuietCheck = paints;
        _lastPaintChange = now;
    }
    return _phaseTicks >= minTicks && (now - _lastPaintChange) >= quietS;
}

- (void)_tick:(CFTimeInterval)ts {
    const double now = CACurrentMediaTime();
    _phaseTicks++;
    switch (_phase) {
        case NppBenchWaitReady: {
            EditorView *ed = [self _editor];
            NSDictionary *marks = NppPerfMarks();
            // Ready at the first full paint of the loaded editor. With probes
            // off (NPP_PERF_LEVEL=0) there is no paint hook: wait 60 ticks
            // after the file is in place instead; with probes on, give up
            // waiting for a full paint after 5 s.
            const BOOL painted = marks[@"firstFullPaint.end"] != nil ||
                (_phaseTicks >= 60 && (!NppPerf::On() || now - _phaseStart > 5));
            if (ed && ed.filePath && painted) {
                NppPerfMark(@"bench.ready");
                if (!marks[@"firstFrame.tick"]) NppPerfMark(@"firstFrame.tick");
                [self _prepareWindow];
                [self _enter:NppBenchSettleOpen];
            } else if (now - _phaseStart > 120) {
                [_errors addObject:@"timed out waiting for the file to load and paint"];
                [self _finish];
            }
            break;
        }
        case NppBenchSettleOpen:
            if ([self _quietFor:0.5 minTicks:(NppPerf::On() ? 30 : 120) now:now] || now - _phaseStart > 10) {
                NppPerfMark(@"bench.settled");
                [self _recordOpen];
                [self _nextScenario];
            }
            break;
        case NppBenchSetup: {
            _NppBenchScenario *s = _queue[(NSUInteger)_queueIndex];
            if (s.setup) s.setup();
            [self _enter:NppBenchSettle];
            break;
        }
        case NppBenchSettle:
            if ([self _quietFor:0.25 minTicks:20 now:now] || now - _phaseStart > 5) [self _beginScenario];
            break;
        case NppBenchRun: {
            _NppBenchScenario *s = _queue[(NSUInteger)_queueIndex];
            if (--_ticksUntilStep > 0) break;
            {
                NPP_PERF_SCOPE("Bench.step", "%{public}s step=%ld", s.name.UTF8String, (long)_stepIndex);
                s.step(_stepIndex);
            }
            _stepIndex++;
            _ticksUntilStep = MAX((NSInteger)1, s.ticksPerStep);
            if (_stepIndex >= s.steps) [self _enter:NppBenchTail];
            break;
        }
        case NppBenchTail: {
            _NppBenchScenario *s = _queue[(NSUInteger)_queueIndex];
            if (_phaseTicks >= s.tailTicks) [self _endScenario];
            break;
        }
        case NppBenchDone:
            break;
    }
}

// NPP_PERF_SCREEN: "max" (default) = the screen with the highest refresh rate
// (the ProMotion panel on a MacBook Pro), "main" = NSScreen.mainScreen, or an
// index into NSScreen.screens.
static NSScreen *BenchScreen(void) {
    const char *v = getenv("NPP_PERF_SCREEN");
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (v && !strcmp(v, "main")) return NSScreen.mainScreen;
    if (v && *v >= '0' && *v <= '9') {
        const NSUInteger i = (NSUInteger)atoi(v);
        if (i < screens.count) return screens[i];
    }
    NSScreen *best = NSScreen.mainScreen;
    NSInteger bestFps = 0;
    for (NSScreen *s in screens) {
        NSInteger fps = 60;
        if (@available(macOS 12.0, *)) fps = s.maximumFramesPerSecond;
        if (fps > bestFps) { bestFps = fps; best = s; }
    }
    return best;
}

- (void)_prepareWindow {
    NSWindow *win = [self _content].window ?: _mwc.window;
    NSScreen *screen = BenchScreen();
    NSRect vis = screen.visibleFrame;
    CGFloat w = 1440, h = 900;
    const char *ws = getenv("NPP_PERF_WINDOW");
    if (ws && *ws) {
        double pw = 0, ph = 0;
        if (sscanf(ws, "%lfx%lf", &pw, &ph) == 2 && pw > 200 && ph > 200) { w = pw; h = ph; }
    }
    w = MIN(w, vis.size.width - 40);
    h = MIN(h, vis.size.height - 40);
    _baseFrame = NSMakeRect(NSMinX(vis) + 20, NSMaxY(vis) - 20 - h, w, h);
    [win setFrame:_baseFrame display:YES];
    if (EnvInteger("NPP_PERF_ACTIVATE", 0) > 0) {
        [NSApp activateIgnoringOtherApps:YES];
        [win makeKeyAndOrderFront:nil];
    } else {
        [win orderFrontRegardless];
    }
    if ([self _content]) [win makeFirstResponder:[self _content]];
}

- (void)_nextScenario {
    if (_queueIndex >= (NSInteger)_queue.count) {
        [self _finish];
        return;
    }
    [self _enter:NppBenchSetup];
}

- (void)_beginScenario {
    _NppBenchScenario *s = _queue[(NSUInteger)_queueIndex];
    InstallContentLayerProbe([self _content]);
    NppPerf::ResetAll();
    NppPerf::StatSnapshot snap;
    _scrollProbeBaseline = NppPerf::SnapshotOne("SCIContentView.scrollWheel", snap) ? (NSInteger)snap.count : 0;
    _scrollPosted = 0;
    _scrollDeliveryVerified = NO;
    _checkpoints = nil;
    _gestureDx = nil;
    _gestureDy = nil;
    _stepIndex = 0;
    _ticksUntilStep = 1;
    _scenarioStart = CACurrentMediaTime();
    _cpuStart = ProcessCPUms();
    _mainCpuStart = MainThreadCPUms();
    _scenarioSpid = os_signpost_id_generate(NppPerf::PoiLog());
    os_signpost_interval_begin(NppPerf::PoiLog(), _scenarioSpid, "Scenario", "%{public}s", s.name.UTF8String);
    [_monitor beginWindow];
    [self _enter:NppBenchRun];
    _ticksUntilStep = 1;
}

- (NSDictionary *)_endState {
    NSWindow *win = [self _content].window;
    return @{
        @"firstVisibleLine": @([self _msg:SCI_GETFIRSTVISIBLELINE]),
        @"xOffset": @([self _msg:SCI_GETXOFFSET]),
        @"caret": @([self _msg:SCI_GETCURRENTPOS]),
        @"anchor": @([self _msg:SCI_GETANCHOR]),
        @"zoom": @([self _msg:SCI_GETZOOM]),
        @"linesOnScreen": @([self _msg:SCI_LINESONSCREEN]),
        @"windowSize": win ? NSStringFromSize(win.frame.size) : @"",
        @"windowVisible": @(win.occlusionState & NSWindowOcclusionStateVisible ? YES : NO),
        @"windowKey": @(win.isKeyWindow),
    };
}

static NSDictionary *StatOrEmpty(NSDictionary *stats, NSString *name) {
    return stats[name] ?: @{};
}

- (void)_endScenario {
    _NppBenchScenario *s = _queue[(NSUInteger)_queueIndex];
    NSDictionary *pacing = [_monitor endWindow];
    os_signpost_interval_end(NppPerf::PoiLog(), _scenarioSpid, "Scenario", "%{public}s", s.name.UTF8String);
    NSDictionary *stats = NppPerfStatsSnapshot();
    const double durMs = (CACurrentMediaTime() - _scenarioStart) * 1000.0;
    const double cpuMs = ProcessCPUms() - _cpuStart;
    const double mainCpuMs = MainThreadCPUms() - _mainCpuStart;

    NSDictionary *frames = pacing[@"frames"];
    NSDictionary *hitches = pacing[@"hitches"];
    NSDictionary *iv = frames[@"intervalMs"];
    NSDictionary *paint = StatOrEmpty(stats, @"SCIContentView.drawRect");
    NSDictionary *margin = StatOrEmpty(stats, @"SCIMarginView.drawRect");
    NSDictionary *wheel = StatOrEmpty(stats, @"SCIContentView.scrollWheel");
    NSDictionary *upd = StatOrEmpty(stats, @"EditorView.SCN.UpdateUI");
    NSMutableDictionary *summary = [@{
        @"durationMs": @(durMs),
        @"cpuMs": @(cpuMs),
        @"mainThreadCpuMs": @(mainCpuMs),
        @"mainThreadCpuPct": @(durMs > 0 ? 100.0 * mainCpuMs / durMs : 0),
        @"frameP50Ms": iv[@"p50"] ?: @0,
        @"frameP95Ms": iv[@"p95"] ?: @0,
        @"frameP99Ms": iv[@"p99"] ?: @0,
        @"frameMaxMs": iv[@"max"] ?: @0,
        @"droppedFrames": frames[@"dropped"] ?: @0,
        @"droppedPct": frames[@"droppedPct"] ?: @0,
        @"hitches": hitches[@"count"] ?: @0,
        @"hitchMaxMs": hitches[@"maxMs"] ?: @0,
        @"hitchTotalMs": hitches[@"totalMs"] ?: @0,
        @"displayCycleP95Ms": hitches[@"displayCycleMs"][@"p95"] ?: @0,
        @"busyIterationP95Ms": hitches[@"busyIterationMs"][@"p95"] ?: @0,
        @"contentDraws": paint[@"count"] ?: @0,
        @"contentDrawP50Ms": paint[@"p50_ms"] ?: @0,
        @"contentDrawP95Ms": paint[@"p95_ms"] ?: @0,
        @"contentDrawMaxMs": paint[@"max_ms"] ?: @0,
        @"contentDrawTotalMs": paint[@"total_ms"] ?: @0,
        @"marginDrawP95Ms": margin[@"p95_ms"] ?: @0,
        @"scrollEvents": wheel[@"count"] ?: @0,
        @"scrollEventP95Ms": wheel[@"p95_ms"] ?: @0,
        @"updateUIP95Ms": upd[@"p95_ms"] ?: @0,
        @"updateUITotalMs": upd[@"total_ms"] ?: @0,
    } mutableCopy];

    NSMutableDictionary *result = [@{
        @"name": s.name,
        @"description": s.summary ?: @"",
        @"params": s.params ?: @{},
        @"steps": @(s.steps),
        @"ticksPerStep": @(s.ticksPerStep),
        @"tailTicks": @(s.tailTicks),
        @"summary": summary,
        @"frames": frames ?: @{},
        @"hitches": hitches ?: @{},
        @"endState": [self _endState],
        @"stats": stats,
    } mutableCopy];
    if (_scrollPosted > 0) result[@"scrollEventsSent"] = @(_scrollPosted);
    if (_checkpoints.count) {
        result[@"checkpoints"] = [_checkpoints copy];
        // hv_scroll check: every vertical fling, before and after the
        // horizontal ones, moves (with its momentum) at least 90% as far as
        // the first one.
        double firstFling = 0;
        NSMutableArray<NSString *> *shortFlings = [NSMutableArray array];
        for (NSDictionary *c in _checkpoints) {
            if (![c[@"gesture"] isEqualToString:@"downFling"]) continue;
            const double moved = [c[@"movedY"] doubleValue];
            if (firstFling == 0) firstFling = moved;
            else if (moved < 0.9 * firstFling)
                [shortFlings addObject:[NSString stringWithFormat:@"%@ %.0f of %.0f pt", c[@"index"], moved, firstFling]];
        }
        result[@"flingCheck"] = @{@"pass": @(firstFling > 0 && shortFlings.count == 0), @"short": shortFlings};
        fprintf(stderr, "[perf] %s fling check: %s%s\n", s.name.UTF8String,
                firstFling > 0 && shortFlings.count == 0 ? "PASS" : "FAIL",
                shortFlings.count ? [NSString stringWithFormat:@" (gesture %@)", [shortFlings componentsJoinedByString:@", "]].UTF8String : "");
        fprintf(stderr, "[perf] %s checkpoints:\n", s.name.UTF8String);
        for (NSDictionary *c in _checkpoints)
            fprintf(stderr, "[perf]   %-12s moved %7.0f,%7.0f  events %3ld (moving %3ld, outside gesture %3ld)  clip %.1f,%.1f  stretch %.1f,%.1f  line %ld  xOffset %ld\n",
                    [c[@"gesture"] UTF8String], [c[@"movedX"] doubleValue], [c[@"movedY"] doubleValue],
                    (long)[c[@"events"] integerValue], (long)[c[@"eventsThatMoved"] integerValue],
                    (long)[c[@"eventsScrolledOutsideGesture"] integerValue],
                    [c[@"clipX"] doubleValue], [c[@"clipY"] doubleValue],
                    [c[@"stretchX"] doubleValue], [c[@"stretchY"] doubleValue],
                    (long)[c[@"firstVisibleLine"] integerValue], (long)[c[@"xOffset"] integerValue]);
    }
    _checkpoints = nil;
    _gestureDx = nil;
    _gestureDy = nil;
    result[@"eventDelivery"] = EventDelivery();
    [_scenarioResults addObject:result];
    fprintf(stderr, "[perf] %-18s %7.0f ms  main cpu %6.0f ms  frame p50 %5.2f p95 %6.2f max %7.2f ms  dropped %4.0f  hitches %3ld (max %.1f ms)  draws %ld p95 %.2f ms\n",
            s.name.UTF8String, durMs, mainCpuMs, [iv[@"p50"] doubleValue], [iv[@"p95"] doubleValue], [iv[@"max"] doubleValue],
            [frames[@"dropped"] doubleValue], (long)[hitches[@"count"] integerValue], [hitches[@"maxMs"] doubleValue],
            (long)[paint[@"count"] integerValue], [paint[@"p95_ms"] doubleValue]);
    _queueIndex++;
    [self _nextScenario];
}

- (void)_recordOpen {
    NSDictionary *marks = NppPerfMarks();
    NSDictionary *stats = NppPerfStatsSnapshot();
    double (^m)(NSString *) = ^double(NSString *k) { return [marks[k] doubleValue]; };
    NSMutableDictionary *load = [NSMutableDictionary dictionary];
    if (marks[@"load.begin"] && marks[@"load.end"])
        load[@"loadFileMs"] = @(m(@"load.end") - m(@"load.begin"));
    if (marks[@"firstPaint.end"]) {
        load[@"processStartToFirstPaintMs"] = @(m(@"firstPaint.end"));
        if (marks[@"load.end"]) load[@"loadEndToFirstPaintMs"] = @(m(@"firstPaint.end") - m(@"load.end"));
        load[@"firstPaintMs"] = @(m(@"firstPaint.end") - m(@"firstPaint.begin"));
    }
    if (marks[@"firstFullPaint.end"]) {
        load[@"processStartToFirstFullPaintMs"] = @(m(@"firstFullPaint.end"));
        if (marks[@"load.end"]) load[@"loadEndToFirstFullPaintMs"] = @(m(@"firstFullPaint.end") - m(@"load.end"));
        load[@"firstFullPaintMs"] = @(m(@"firstFullPaint.end") - m(@"firstFullPaint.begin"));
    }
    if (marks[@"main"]) load[@"processStartToMainMs"] = @(m(@"main"));
    if (marks[@"launch.end"] && marks[@"launch.begin"])
        load[@"didFinishLaunchingMs"] = @(m(@"launch.end") - m(@"launch.begin"));
    if (marks[@"firstFrame.tick"]) load[@"processStartToFirstFrameTickMs"] = @(m(@"firstFrame.tick"));
    if (marks[@"bench.settled"]) load[@"processStartToSettledMs"] = @(m(@"bench.settled"));
    // Per-phase load timings from the probes in -[EditorView loadFileAtPath:].
    for (NSString *k in stats) {
        if ([k hasPrefix:@"Load."] && [stats[k][@"kind"] isEqual:@"duration"]) load[k] = stats[k][@"total_ms"];
    }
    [_scenarioResults addObject:@{
        @"name": @"open",
        @"description": @"Process start to file loaded and first frame painted, then settled",
        @"summary": load,
        @"marks": marks,
        @"stats": stats,
        @"endState": [self _endState],
    }];
    fprintf(stderr, "[perf] open: load %.1f ms, process start to first full paint %.1f ms, first full paint %.1f ms\n",
            [load[@"loadFileMs"] doubleValue], [load[@"processStartToFirstFullPaintMs"] doubleValue],
            [load[@"firstFullPaintMs"] doubleValue]);
}

// Core Animation display timing. On macOS 26 and later AppKit keeps the
// drawing of a drawRect: view in a visible-rect-sized content sublayer as a
// display list; Core Animation rasterizes that list into the sublayer's
// backing store during the transaction commit, on the main thread, outside
// any drawRect:. The benchmark wraps -display of that sublayer class to time
// the rasterization per view: CA.ContentLayer.display.text (the editor text),
// .margin (line numbers), .tabs (tab bar) and .other.
static IMP gContentLayerDisplay = nullptr;

static void TimedContentLayerDisplay(CALayer *self_, SEL cmd) {
    auto orig = reinterpret_cast<void (*)(CALayer *, SEL)>(gContentLayerDisplay);
    if (!NppPerf::On()) { orig(self_, cmd); return; }
    id owner = self_.superlayer.delegate;
    if ([owner isKindOfClass:[SCIContentView class]]) {
        NPP_PERF_SCOPE("CA.ContentLayer.display.text");
        orig(self_, cmd);
    } else if ([owner isKindOfClass:[SCIMarginView class]]) {
        NPP_PERF_SCOPE("CA.ContentLayer.display.margin");
        orig(self_, cmd);
    } else if ([NSStringFromClass([owner class]) hasPrefix:@"_NppTab"] ||
               [NSStringFromClass([owner class]) hasPrefix:@"NppTab"]) {
        NPP_PERF_SCOPE("CA.ContentLayer.display.tabs");
        orig(self_, cmd);
    } else {
        NPP_PERF_SCOPE("CA.ContentLayer.display.other");
        orig(self_, cmd);
    }
}

static void InstallContentLayerProbe(NSView *content) {
    if (gContentLayerDisplay) return;
    for (CALayer *sub in content.layer.sublayers) {
        Class cls = [sub class];
        if (![NSStringFromClass(cls) containsString:@"ContentLayer"]) continue;
        Method m = class_getInstanceMethod(cls, @selector(display));
        if (!m) return;
        gContentLayerDisplay = method_getImplementation(m);
        class_replaceMethod(cls, @selector(display), (IMP)TimedContentLayerDisplay, method_getTypeEncoding(m));
        return;
    }
}

// One line per layer in the window's layer tree: depth, layer class, the view
// it backs (when its delegate is an NSView), size in points, opacity,
// contentsFormat, drawsAsynchronously, the view's redraw policy and whether
// it draws its subviews into its own layer. Shows which layers AppKit keeps
// for the editor and in what pixel format Core Animation rasterizes them.
static void AppendLayerTree(CALayer *layer, NSInteger depth, NSMutableArray<NSString *> *out) {
    if (!layer || out.count >= 400 || depth > 24) return;
    NSMutableString *line = [NSMutableString stringWithFormat:@"%*s%@", (int)(depth * 2), "",
                             NSStringFromClass([layer class])];
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:[NSView class]]) {
        NSView *v = delegate;
        [line appendFormat:@" view=%@ wantsLayer=%d updateLayer=%d policy=%ld drawsSubviews=%d",
         NSStringFromClass([v class]), v.wantsLayer, v.wantsUpdateLayer,
         (long)v.layerContentsRedrawPolicy, v.canDrawSubviewsIntoLayer];
    }
    [line appendFormat:@" frame=%.0f,%.0f,%.0fx%.0f opaque=%d format=%@ async=%d hidden=%d",
     layer.frame.origin.x, layer.frame.origin.y, layer.bounds.size.width, layer.bounds.size.height,
     layer.opaque, layer.contentsFormat, layer.drawsAsynchronously, layer.hidden];
    if (layer.contents) [line appendFormat:@" contents=%@", NSStringFromClass([layer.contents class])];
    if (@available(macOS 14.0, *)) {
        if (layer.wantsExtendedDynamicRangeContent) [line appendString:@" edr=1"];
    }
    if (layer.filters.count || layer.backgroundFilters.count || layer.compositingFilter)
        [line appendFormat:@" filters=%lu/%lu", (unsigned long)layer.filters.count,
         (unsigned long)layer.backgroundFilters.count];
    [out addObject:line];
    for (CALayer *sub in layer.sublayers) AppendLayerTree(sub, depth + 1, out);
}

static NSArray<NSString *> *LayerTree(NSWindow *win) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSView *frameView = win.contentView.superview ?: win.contentView;
    AppendLayerTree(frameView.layer, 0, out);
    return out;
}

static NSDictionary *ScreenInfo(NSScreen *screen) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!screen) return d;
    d[@"name"] = screen.localizedName ?: @"";
    if (@available(macOS 12.0, *)) d[@"maximumFramesPerSecond"] = @(screen.maximumFramesPerSecond);
    d[@"backingScale"] = @(screen.backingScaleFactor);
    d[@"colorSpace"] = screen.colorSpace.localizedName ?: @"";
    d[@"depth"] = @(NSBitsPerPixelFromDepth(screen.depth));
    d[@"maxEDR"] = @(screen.maximumExtendedDynamicRangeColorComponentValue);
    d[@"maxPotentialEDR"] = @(screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
    d[@"maxReferenceEDR"] = @(screen.maximumReferenceExtendedDynamicRangeColorComponentValue);
    d[@"frame"] = NSStringFromRect(screen.frame);
    return d;
}

- (NSDictionary *)_environment {
    EditorView *ed = [self _editor];
    ScintillaView *sci = ed.scintillaView;
    NSWindow *win = sci.window;
    NSScreen *screen = win.screen ?: NSScreen.mainScreen;
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    env[@"date"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    env[@"hwModel"] = Sysctl("hw.model");
    env[@"cpu"] = Sysctl("machdep.cpu.brand_string");
    env[@"cpuCount"] = @([NSProcessInfo processInfo].activeProcessorCount);
    env[@"memoryGB"] = @([NSProcessInfo processInfo].physicalMemory / (1024.0 * 1024 * 1024));
    env[@"os"] = [NSProcessInfo processInfo].operatingSystemVersionString;
    if (@available(macOS 12.0, *)) env[@"lowPowerMode"] = @([NSProcessInfo processInfo].isLowPowerModeEnabled);
    env[@"thermalState"] = @([NSProcessInfo processInfo].thermalState);
#if defined(__arm64__)
    env[@"arch"] = @"arm64";
#else
    env[@"arch"] = @"x86_64";
#endif
    env[@"buildCommit"] = @NPP_BUILD_COMMIT;
    env[@"buildBranch"] = @NPP_BUILD_BRANCH;
    env[@"buildDirty"] = @(NPP_BUILD_DIRTY);
    env[@"buildType"] = @NPP_BUILD_TYPE;
    env[@"bundleId"] = [NSBundle mainBundle].bundleIdentifier ?: @"";
    env[@"appVersion"] = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    env[@"perfLevel"] = @(NppPerf::Level());
    env[@"pid"] = @(getpid());

    NSString *path = ed.filePath ?: @"";
    env[@"file"] = path;
    env[@"fileSizeBytes"] = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize] ?: @0;
    env[@"docLengthBytes"] = @([self _msg:SCI_GETLENGTH]);
    env[@"lines"] = @([self _msg:SCI_GETLINECOUNT]);
    env[@"largeFileMode"] = @(ed.largeFileMode);
    env[@"language"] = ed.currentLanguage ?: @"";
    char lexer[128] = {0};
    if ([self _msg:SCI_GETLEXERLANGUAGE] < (sptr_t)sizeof(lexer))
        [sci message:SCI_GETLEXERLANGUAGE wParam:0 lParam:(sptr_t)lexer];
    env[@"lexer"] = [NSString stringWithUTF8String:lexer] ?: @"";
    env[@"encoding"] = ed.encodingName ?: @"";
    env[@"eol"] = ed.eolName ?: @"";
    env[@"readOnly"] = @([self _msg:SCI_GETREADONLY] != 0);
    env[@"wrapMode"] = @([self _msg:SCI_GETWRAPMODE]);
    env[@"technology"] = @([self _msg:SCI_GETTECHNOLOGY]);
    env[@"bufferedDraw"] = @([self _msg:SCI_GETBUFFEREDDRAW] != 0);
    env[@"phasesDraw"] = @([self _msg:SCI_GETPHASESDRAW]);
    env[@"layoutCache"] = @([self _msg:SCI_GETLAYOUTCACHE]);
    env[@"positionCacheSize"] = @([self _msg:SCI_GETPOSITIONCACHE]);
    env[@"idleStyling"] = @([self _msg:SCI_GETIDLESTYLING]);
    env[@"layoutThreads"] = @([self _msg:SCI_GETLAYOUTTHREADS]);
    env[@"viewWhitespace"] = @([self _msg:SCI_GETVIEWWS]);
    env[@"changeHistory"] = @([self _msg:SCI_GETCHANGEHISTORY]);
    env[@"caretLineVisible"] = @([self _msg:SCI_GETCARETLINEVISIBLE] != 0);
    env[@"lineHeight"] = @([self _msg:SCI_TEXTHEIGHT w:0]);
    env[@"zoom"] = @([self _msg:SCI_GETZOOM]);
    char font[128] = {0};
    [sci message:SCI_STYLEGETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)font];
    env[@"font"] = [NSString stringWithUTF8String:font] ?: @"";
    env[@"fontSize"] = @([self _msg:SCI_STYLEGETSIZEFRACTIONAL w:STYLE_DEFAULT] / 100.0);
    NSMutableArray *margins = [NSMutableArray array];
    for (int i = 0; i < 5; i++) [margins addObject:@([self _msg:SCI_GETMARGINWIDTHN w:(uptr_t)i])];
    env[@"marginWidths"] = margins;
    env[@"windowFrame"] = NSStringFromRect(win.frame);
    env[@"windowNumber"] = @(win.windowNumber);
    env[@"contentViewSize"] = NSStringFromSize(sci.content.visibleRect.size);
    env[@"backingScale"] = @(win.backingScaleFactor);
    env[@"screen"] = screen.localizedName ?: @"";
    env[@"screenMaxFps"] = @(_monitor.nominalRefreshHz);
    env[@"measuredRefreshHz"] = @(_monitor.measuredRefreshHz);
    env[@"frameClock"] = _monitor.clockKind;
    env[@"layerBacked"] = @(sci.content.wantsLayer || sci.content.layer != nil);
    env[@"responsiveScrolling"] = @([sci.content.class isCompatibleWithResponsiveScrolling]);
    env[@"screenInfo"] = ScreenInfo(screen);
    env[@"screens"] = ^{
        NSMutableArray *a = [NSMutableArray array];
        for (NSScreen *s in NSScreen.screens) [a addObject:ScreenInfo(s)];
        return a;
    }();
    env[@"windowDepthLimit"] = @(NSBitsPerPixelFromDepth(win.depthLimit));
    env[@"windowColorSpace"] = win.colorSpace.localizedName ?: @"";
    if (win) env[@"layerTree"] = LayerTree(win);
    return env;
}

- (void)_finish {
    if (_phase == NppBenchDone) return;
    _phase = NppBenchDone;
    [_monitor stop];
    _report[@"schema"] = @"nextpad-perf/1";
    _report[@"environment"] = [self _environment];
    _report[@"scenarios"] = _scenarioResults;
    _report[@"requested"] = [NSString stringWithUTF8String:getenv("NPP_PERF_BENCH") ?: ""];
    _report[@"errors"] = _errors;
    _report[@"scenarioCatalog"] = [NppPerfBench scenarioNames];
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:_report
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&err];
    if (json && [json writeToFile:_reportPath atomically:YES])
        fprintf(stderr, "[perf] report written: %s\n", _reportPath.UTF8String);
    else
        fprintf(stderr, "[perf] failed to write report %s: %s\n", _reportPath.UTF8String,
                err.localizedDescription.UTF8String ?: "write failed");
    if (EnvInteger("NPP_PERF_NO_QUIT", 0) > 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    // Last resort if something blocks termination (a modal prompt).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        fprintf(stderr, "[perf] terminate did not finish in 15 s; exiting\n");
        _exit(0);
    });
}

@end
