#pragma once

// Scripted scroll and render benchmark, driven from inside the app.
//
// Environment:
//   NPP_PERF_BENCH=<name[,name...]|all>  scenarios to run (implies NPP_PERF=1)
//   NPP_PERF_REPORT=<path>               JSON report path (default
//                                        /tmp/nextpad-perf-<pid>.json)
//   NPP_PERF_BENCH_REPEAT=<n>            run each scenario n times in-process
//   NPP_PERF_WINDOW=<W>x<H>              window size in points (default 1440x900)
//   NPP_PERF_ACTIVATE=1                  activate the app and make the window
//                                        key (default: order front only)
//   NPP_PERF_NO_QUIT=1                   stay open after the report is written
//
// After the file named on the command line has loaded and its first frame
// has painted, the driver sizes the window, waits for the editor to go
// quiet, then runs each scenario on the display link: one scripted input
// per frame tick (or every N ticks), the same inputs on every run. Scroll
// input is real NSEvent scroll-wheel events built with
// CGEventCreateScrollWheelEvent and posted to the application queue, so the
// whole AppKit and Scintilla scroll path runs. Key input is NSEvent key
// events sent to the window. For each scenario the report has frame pacing,
// main-thread hitches, every probe aggregate and the end state; it also has
// load timings and the environment. The app quits when done.
//
// Scenarios: see +[NppPerfBench scenarioNames] and tests/perf/README.md.

#import <Cocoa/Cocoa.h>

@class MainWindowController;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif
/// YES when NPP_PERF_BENCH is set. Startup uses it to skip interactive
/// prompts (large-file warning) and the network update check.
BOOL NppPerfBenchActive(void);
#ifdef __cplusplus
}
#endif

@interface NppPerfBench : NSObject

/// Every scenario name, in "all" order.
+ (NSArray<NSString *> *)scenarioNames;

/// Starts the driver if NPP_PERF_BENCH is set. Call at the end of
/// applicationDidFinishLaunching:.
+ (void)startIfRequestedWithController:(MainWindowController *)controller;

@end

NS_ASSUME_NONNULL_END
