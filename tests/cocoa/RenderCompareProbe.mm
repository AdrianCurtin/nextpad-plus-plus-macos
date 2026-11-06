/* Render a text file through ScintillaView offscreen under a matrix of view
   settings and write one raw RGBA dump per configuration, so that two
   Scintilla builds can be compared pixel for pixel. Run from the repository
   root in a macOS GUI session (no visible window):
     cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
     cmake --build build --target scintilla
     clang++ -std=c++17 -fobjc-arc -O2 -I scintilla/cocoa -I scintilla/include \
       tests/cocoa/RenderCompareProbe.mm build/libscintilla.a build/libscintilla_core.a \
       -framework Cocoa -framework QuartzCore -o build/RenderCompareProbe
     build/RenderCompareProbe <text file> <output dir>
   Build the probe once per Scintilla build (linking that build's libraries),
   run both on the same file into two directories and diff the printed lists:
     build/RenderCompareProbe-a file.txt /tmp/a > a.txt
     build/RenderCompareProbe-b file.txt /tmp/b > b.txt
     diff a.txt b.txt
   Each configuration is written to <name>.rgba (width, height and scale in
   index.txt; 8-bit RGBA rows, top row first) and a line with the name, an
   FNV-1a hash of the pixels and two pixel counts is printed. Configurations
   cover fonts (monospaced and proportional, bold), tab widths, styles that
   change mid-line, underline, selection with and without a selection text
   colour, a text-colour indicator, visible whitespace and indentation guides,
   one, two and multiple drawing phases, horizontal and vertical offsets,
   word wrap, zoom, the right-to-left mode and backing scales 1 and 2.
*/
#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#import "Scintilla.h"
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

namespace {

struct Config {
	std::string name;
	const char *font = "Menlo";
	int size = 12;
	bool bold = false;
	int tabWidth = 4;
	int scale = 2;
	int xOffset = 0;
	int topLine = 0;
	bool styled = false;
	bool underline = false;
	bool selection = false;
	bool selectionFore = false;
	bool indicatorFore = false;
	bool whitespace = false;
	bool guides = false;
	int phases = SC_PHASES_TWO;
	bool wrap = false;
	int zoom = 0;
	bool caretLine = true;
	bool rtl = false;
};

uint64_t Fnv(const unsigned char *data, size_t length) {
	uint64_t h = 1469598103934665603ULL;
	for (size_t i = 0; i < length; i++) {
		h ^= data[i];
		h *= 1099511628211ULL;
	}
	return h;
}

void Apply(ScintillaView *sci, const Config &c) {
	((SCIScrollView *)sci.scrollView).rtlMode = c.rtl ? YES : NO;
	[sci message:SCI_SETBIDIRECTIONAL wParam:c.rtl ? SC_BIDIRECTIONAL_R2L : SC_BIDIRECTIONAL_DISABLED];
	[sci message:SCI_STYLERESETDEFAULT];
	[sci setFontName:[NSString stringWithUTF8String:c.font] size:c.size bold:c.bold italic:NO];
	[sci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:0x000000];
	[sci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:0xFFFFFF];
	[sci message:SCI_STYLECLEARALL];
	// Styles 1..3 differ in colour (and 2 in weight) so runs break mid-line.
	[sci message:SCI_STYLESETFORE wParam:1 lParam:0x0000C0];
	[sci message:SCI_STYLESETFORE wParam:2 lParam:0x008000];
	[sci message:SCI_STYLESETBOLD wParam:2 lParam:1];
	[sci message:SCI_STYLESETFORE wParam:3 lParam:0x800080];
	[sci message:SCI_STYLESETBACK wParam:3 lParam:0xE0F0FF];
	[sci message:SCI_STYLESETUNDERLINE wParam:1 lParam:c.underline ? 1 : 0];
	[sci message:SCI_SETTABWIDTH wParam:c.tabWidth];
	[sci message:SCI_SETPHASESDRAW wParam:c.phases];
	[sci message:SCI_SETVIEWWS wParam:c.whitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
	[sci message:SCI_SETINDENTATIONGUIDES wParam:c.guides ? SC_IV_REAL : SC_IV_NONE];
	[sci message:SCI_SETWRAPMODE wParam:c.wrap ? SC_WRAP_WORD : SC_WRAP_NONE];
	[sci message:SCI_SETZOOM wParam:c.zoom];
	[sci message:SCI_SETCARETPERIOD wParam:0];
	[sci message:SCI_SETCARETLINEVISIBLE wParam:c.caretLine ? 1 : 0];
	[sci message:SCI_SETCARETLINEBACK wParam:0xF0F0D0];
	[sci message:SCI_SETSCROLLWIDTH wParam:4000];
	[sci message:SCI_SETSCROLLWIDTHTRACKING wParam:0];
	[sci message:SCI_SETMARGINWIDTHN wParam:1 lParam:0];

	// Styling: none, or rotate styles 0..3 every 13 bytes.
	const sptr_t length = [sci message:SCI_GETLENGTH];
	[sci message:SCI_STARTSTYLING wParam:0];
	if (c.styled) {
		for (sptr_t pos = 0; pos < length; pos += 13) {
			const sptr_t run = std::min<sptr_t>(13, length - pos);
			[sci message:SCI_SETSTYLING wParam:run lParam:(pos / 13) % 4];
		}
	} else {
		[sci message:SCI_SETSTYLING wParam:length lParam:0];
	}

	const sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:c.topLine + 3];
	if (c.selection) {
		[sci message:SCI_SETSEL wParam:lineStart + 20 lParam:lineStart + 2000];
	} else {
		[sci message:SCI_SETSEL wParam:lineStart + 5 lParam:lineStart + 5];
	}
	// The window is never key, so the inactive selection colours apply too.
	for (int element : {SC_ELEMENT_SELECTION_TEXT, SC_ELEMENT_SELECTION_INACTIVE_TEXT}) {
		if (c.selectionFore)
			[sci message:SCI_SETELEMENTCOLOUR wParam:element lParam:0xFFFFFFFF];
		else
			[sci message:SCI_RESETELEMENTCOLOUR wParam:element];
	}
	for (int element : {SC_ELEMENT_SELECTION_BACK, SC_ELEMENT_SELECTION_INACTIVE_BACK})
		[sci message:SCI_SETELEMENTCOLOUR wParam:element lParam:0xFF804000];

	// Indicator 8: text colour over a range that crosses tabs, when enabled.
	[sci message:SCI_INDICSETSTYLE wParam:8 lParam:INDIC_TEXTFORE];
	[sci message:SCI_INDICSETFORE wParam:8 lParam:0x0080FF];
	[sci message:SCI_SETINDICATORCURRENT wParam:8];
	[sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:length];
	if (c.indicatorFore) {
		const sptr_t line5 = [sci message:SCI_POSITIONFROMLINE wParam:c.topLine + 5];
		[sci message:SCI_INDICATORFILLRANGE wParam:line5 + 30 lParam:90];
	}

	[sci message:SCI_SETFIRSTVISIBLELINE wParam:c.topLine];
	[sci message:SCI_SETXOFFSET wParam:c.xOffset];
}

}

int main(int argc, char **argv) { @autoreleasepool {
	if (argc < 3) {
		fprintf(stderr, "usage: %s <text file> <output dir>\n", argv[0]);
		return 2;
	}
	NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
		encoding:NSUTF8StringEncoding error:nil];
	if (!text) {
		fprintf(stderr, "cannot read %s as UTF-8\n", argv[1]);
		return 2;
	}
	const std::string outDir = argv[2];
	[[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:outDir.c_str()]
		withIntermediateDirectories:YES attributes:nil error:nil];

	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
	NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	const int viewWidth = 900, viewHeight = 400;
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, viewWidth, viewHeight)
		styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	ScintillaView *sci = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, viewWidth, viewHeight)];
	[window.contentView addSubview:sci];
	[sci message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
	[sci setString:text];

	std::vector<Config> configs;
	auto add = [&](const std::string &name, auto edit) {
		Config c;
		c.name = name;
		edit(c);
		configs.push_back(c);
	};
	for (int scale : {1, 2}) {
		const std::string s = "s" + std::to_string(scale) + "-";
		add(s + "plain", [&](Config &c) { c.scale = scale; });
		add(s + "tab8", [&](Config &c) { c.scale = scale; c.tabWidth = 8; });
		add(s + "styled", [&](Config &c) { c.scale = scale; c.styled = true; });
		add(s + "underline", [&](Config &c) { c.scale = scale; c.styled = true; c.underline = true; });
		add(s + "selection", [&](Config &c) { c.scale = scale; c.selection = true; });
		add(s + "selection-fore", [&](Config &c) { c.scale = scale; c.selection = true; c.selectionFore = true; });
		add(s + "indicator-fore", [&](Config &c) { c.scale = scale; c.indicatorFore = true; });
		add(s + "whitespace", [&](Config &c) { c.scale = scale; c.whitespace = true; });
		add(s + "guides", [&](Config &c) { c.scale = scale; c.guides = true; });
		add(s + "phases-one", [&](Config &c) { c.scale = scale; c.phases = SC_PHASES_ONE; c.styled = true; });
		add(s + "phases-multiple", [&](Config &c) { c.scale = scale; c.phases = SC_PHASES_MULTIPLE; c.styled = true; });
		add(s + "xoffset", [&](Config &c) { c.scale = scale; c.xOffset = 333; });
		add(s + "top", [&](Config &c) { c.scale = scale; c.topLine = 37; c.selection = true; });
		add(s + "wrap", [&](Config &c) { c.scale = scale; c.wrap = true; });
		add(s + "zoom", [&](Config &c) { c.scale = scale; c.zoom = 3; });
		add(s + "zoom-out", [&](Config &c) { c.scale = scale; c.zoom = -2; });
		add(s + "menlo-bold-15", [&](Config &c) { c.scale = scale; c.size = 15; c.bold = true; });
		add(s + "courier-13", [&](Config &c) { c.scale = scale; c.font = "Courier"; c.size = 13; c.styled = true; });
		add(s + "helvetica-12", [&](Config &c) { c.scale = scale; c.font = "Helvetica"; c.styled = true; });
		add(s + "helvetica-selection", [&](Config &c) { c.scale = scale; c.font = "Helvetica"; c.selection = true; });
		add(s + "rtl", [&](Config &c) { c.scale = scale; c.rtl = true; c.styled = true; });
	}

	FILE *index = fopen((outDir + "/index.txt").c_str(), "w");
	for (const Config &c : configs) {
		Apply(sci, c);
		const int width = viewWidth * c.scale, height = viewHeight * c.scale;
		NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
			pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4
			hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
			bytesPerRow:width * 4 bitsPerPixel:32];
		NSGraphicsContext *bitmapContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
		CGContextRef gc = bitmapContext.CGContext;
		NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithCGContext:gc flipped:YES];
		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext:context];
		CGContextSetRGBFillColor(gc, 1, 0, 1, 1);
		CGContextFillRect(gc, CGRectMake(0, 0, width, height));
		CGContextTranslateCTM(gc, 0, height);
		CGContextScaleCTM(gc, c.scale, -c.scale);
		[sci.scrollView tile];
		NSView *content = [sci content];
		const NSRect visible = content.visibleRect;
		CGContextTranslateCTM(gc, -visible.origin.x, -visible.origin.y);
		[content displayRectIgnoringOpacity:visible inContext:context];
		[NSGraphicsContext restoreGraphicsState];
		const size_t bytes = static_cast<size_t>(bitmap.bytesPerRow) * height;
		const std::string path = outDir + "/" + c.name + ".rgba";
		FILE *f = fopen(path.c_str(), "wb");
		fwrite(bitmap.bitmapData, 1, bytes, f);
		fclose(f);
		fprintf(index, "%s %d %d %d\n", c.name.c_str(), width, height, c.scale);
		// Ink: pixels that are neither the white background nor the magenta
		// fill outside the drawing, to catch a blank or misplaced render.
		size_t ink = 0, outside = 0;
		for (size_t p = 0; p + 3 < bytes; p += 4) {
			const unsigned char *px = bitmap.bitmapData + p;
			if (px[0] == 255 && px[1] == 0 && px[2] == 255)
				outside++;
			else if (!(px[0] == 255 && px[1] == 255 && px[2] == 255))
				ink++;
		}
		printf("%-28s %016llx ink=%zu outside=%zu\n", c.name.c_str(),
			static_cast<unsigned long long>(Fnv(bitmap.bitmapData, bytes)), ink, outside);
	}
	fclose(index);
	return 0;
}}
