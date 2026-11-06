/* Run from the repository root in a macOS GUI session (no visible window is
   needed, so it also runs while the screen is locked):
   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
   cmake --build build --target scintilla scintilla_core
   clang++ -std=c++17 -fobjc-arc -O2 -I scintilla/cocoa -I scintilla/include \
       tests/cocoa/ScrollInvalidationProbe.mm build/libscintilla.a build/libscintilla_core.a \
       -framework Cocoa -framework QuartzCore -o build/ScrollInvalidationProbe
   build/ScrollInvalidationProbe
   Paths assume the Unix Makefiles or Ninja CMake layout. Exits non-zero on a
   failed check.
*/
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "ScintillaView.h"
#import "Scintilla.h"
#include <cstdio>

// Checks which views a scroll invalidates:
// - a horizontal scroll leaves the line-number margin valid, a vertical one
//   invalidates it, and Scintilla's own margin invalidations (markers) still
//   reach it;
// - on macOS 26 and later a horizontal scroll invalidates the whole visible
//   text area, not only the exposed strip.

static int gContentInvalidations = 0;
static NSRect gContentUnion = NSZeroRect;

// Invalidations of the margin that reach NSView, counted by wrapping
// -[NSView setNeedsDisplayInRect:]. A layer-backed view's needsDisplay flag
// cannot be cleared from outside a display pass, so the probe counts requests.
static NSView *gMargin = nil;
static int gMarginInvalidations = 0;
static IMP gNSViewSetNeedsDisplayInRect = nullptr;

static void CountingSetNeedsDisplayInRect(NSView *self, SEL cmd, NSRect rect) {
	if (self == gMargin)
		gMarginInvalidations++;
	reinterpret_cast<void (*)(NSView *, SEL, NSRect)>(gNSViewSetNeedsDisplayInRect)(self, cmd, rect);
}

@interface ProbeContentView : SCIContentView
@end

@implementation ProbeContentView
- (void) setNeedsDisplayInRect: (NSRect) rect {
	gContentInvalidations++;
	gContentUnion = NSUnionRect(gContentUnion, rect);
	[super setNeedsDisplayInRect: rect];
}
@end

@interface ProbeScintillaView : ScintillaView
@end

@implementation ProbeScintillaView
+ (Class) contentViewClass {
	return [ProbeContentView class];
}
@end

static void Paint(NSView *view) {
	NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect: view.bounds];
	[view cacheDisplayInRect: view.bounds toBitmapImageRep: bitmap];
}

static int gFailures = 0;

static void Check(bool ok, const char *what) {
	printf("%s %s\n", ok ? "PASS" : "FAIL", what);
	gFailures += !ok;
}

int main() { @autoreleasepool {
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy: NSApplicationActivationPolicyProhibited];
	Method m = class_getInstanceMethod([NSView class], @selector(setNeedsDisplayInRect:));
	gNSViewSetNeedsDisplayInRect = method_setImplementation(m, reinterpret_cast<IMP>(CountingSetNeedsDisplayInRect));
	NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 700, 400)
		styleMask: NSWindowStyleMaskBorderless backing: NSBackingStoreBuffered defer: NO];
	window.releasedWhenClosed = NO;
	ScintillaView *sci = [[ProbeScintillaView alloc] initWithFrame: NSMakeRect(0, 0, 700, 400)];
	[window.contentView addSubview: sci];
	[sci setFontName: @"Menlo" size: 12 bold: NO italic: NO];
	[sci message: SCI_SETMARGINTYPEN wParam: 0 lParam: SC_MARGIN_NUMBER];
	[sci message: SCI_SETMARGINWIDTHN wParam: 0 lParam: 60];
	[sci message: SCI_SETMARGINTYPEN wParam: 1 lParam: SC_MARGIN_SYMBOL];
	[sci message: SCI_SETMARGINWIDTHN wParam: 1 lParam: 16];
	[sci message: SCI_MARKERDEFINE wParam: 1 lParam: SC_MARK_CIRCLE];
	NSMutableString *text = [NSMutableString string];
	for (int i = 0; i < 2000; ++i) {
		[text appendFormat: @"%d", i];
		for (int c = 0; c < 50; ++c) [text appendString: @"\t12345.678"];
		[text appendString: @"\n"];
	}
	[sci setString: text];
	[sci message: SCI_SETSCROLLWIDTH wParam: 4000];
	NSScrollView *scroll = sci.scrollView;
	[scroll tile];
	NSClipView *clip = scroll.contentView;
	NSView *margin = scroll.verticalRulerView;
	gMargin = margin;
	NSView *content = scroll.documentView;
	const int lineHeight = (int)[sci message: SCI_TEXTHEIGHT wParam: 0];

	[clip scrollToPoint: NSMakePoint(0, 100 * lineHeight)];
	[scroll reflectScrolledClipView: clip];
	Paint(margin);
	Paint(content);

	// Horizontal scroll: the margin stays valid.
	gMarginInvalidations = 0;
	gContentInvalidations = 0;
	gContentUnion = NSZeroRect;
	[clip scrollToPoint: NSMakePoint(240, 100 * lineHeight)];
	[scroll reflectScrolledClipView: clip];
	Check(gMarginInvalidations == 0, "horizontal scroll leaves the margin valid");
	Check([sci message: SCI_GETXOFFSET] == 240, "horizontal scroll reaches Scintilla's xOffset");
	if (@available(macOS 26.0, *)) {
		const NSRect visible = content.visibleRect;
		Check(gContentInvalidations > 0 && NSContainsRect(gContentUnion, visible),
			"horizontal scroll invalidates the whole visible text area");
	}
	Paint(content);

	// Vertical scroll: the margin is invalidated.
	gMarginInvalidations = 0;
	[clip scrollToPoint: NSMakePoint(240, 140 * lineHeight)];
	[scroll reflectScrolledClipView: clip];
	Check(gMarginInvalidations > 0, "vertical scroll invalidates the margin");
	Check([sci message: SCI_GETFIRSTVISIBLELINE] == 140, "vertical scroll reaches Scintilla's top line");
	Paint(margin);
	Paint(content);

	// Scintilla's margin invalidation (a marker on a visible line) still applies.
	gMarginInvalidations = 0;
	[sci message: SCI_MARKERADD wParam: 145 lParam: 1];
	Check(gMarginInvalidations > 0, "marker on a visible line invalidates the margin");
	Paint(margin);

	// Away and back without a paint: the first scroll invalidates the margin.
	gMarginInvalidations = 0;
	[clip scrollToPoint: NSMakePoint(240, 150 * lineHeight)];
	[scroll reflectScrolledClipView: clip];
	const int afterAway = gMarginInvalidations;
	[clip scrollToPoint: NSMakePoint(240, 140 * lineHeight)];
	[scroll reflectScrolledClipView: clip];
	Check(afterAway > 0, "scrolling away from the painted position invalidates the margin");

	// A resize that changes the clip height invalidates the margin.
	Paint(margin);
	gMarginInvalidations = 0;
	[sci setFrame: NSMakeRect(0, 0, 700, 300)];
	Check(gMarginInvalidations > 0, "a height change invalidates the margin");

	return gFailures ? 1 : 0;
}}
