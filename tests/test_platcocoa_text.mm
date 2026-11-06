// Text measuring and drawing of the Cocoa platform layer (scintilla/cocoa/PlatCocoa.mm)
// checked against CoreText line layout, the way upstream Scintilla measures and draws
// every run. PlatCocoa draws and measures runs of printable ASCII from a per-font glyph
// table when the font qualifies; this test requires the results to be identical to the
// CTLine results: the same positions and widths to the last bit, and the same pixels in
// bitmap contexts at 1x and 2x, for fonts that qualify and fonts that do not.
//
// Draws only into memory: no window, no app launch, no defaults or files.

#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <string_view>
#include <vector>
#include <map>
#include <set>
#include <forward_list>
#include <optional>
#include <memory>
#include <numeric>

#import <Cocoa/Cocoa.h>

#import "ScintillaTypes.h"
#import "ScintillaMessages.h"
#import "ScintillaStructures.h"
#import "Debugging.h"
#import "Geometry.h"
#import "Platform.h"
#import "Scintilla.h"
#import "ScintillaView.h"
#import "ScintillaCocoa.h"
#import "PlatCocoa.h"

using namespace Scintilla;
using namespace Scintilla::Internal;

namespace {

int failures = 0;
int checks = 0;

void Fail(const std::string &what) {
	failures++;
	if (failures <= 40) {
		fprintf(stderr, "FAIL: %s\n", what.c_str());
	}
}

void Check(bool ok, const std::string &what) {
	checks++;
	if (!ok) {
		Fail(what);
	}
}

struct TestFont {
	const char *name;
	float size;
	FontWeight weight;
	bool italic;
};

// The reference CTLine for text, built as QuartzTextLayout builds it.
CTLineRef ReferenceLine(CTFontRef font, std::string_view text, CGColorRef colour) {
	CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(text.data()),
						  text.length(), kCFStringEncodingUTF8, false);
	if (!str) {
		return nullptr;
	}
	CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
								      &kCFTypeDictionaryKeyCallBacks,
								      &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(attributes, kCTFontAttributeName, font);
	if (colour) {
		CFDictionarySetValue(attributes, kCTForegroundColorAttributeName, colour);
	}
	CFAttributedStringRef as = CFAttributedStringCreate(kCFAllocatorDefault, str, attributes);
	CTLineRef line = CTLineCreateWithAttributedString(as);
	CFRelease(as);
	CFRelease(attributes);
	CFRelease(str);
	return line;
}

// Upstream SurfaceImpl::MeasureWidthsUTF8: summed advances per UTF-16 unit, mapped to bytes.
std::vector<XYPOSITION> ReferencePositions(CTFontRef font, std::string_view text) {
	std::vector<XYPOSITION> positions(text.length());
	CTLineRef line = ReferenceLine(font, text, nullptr);
	const CFIndex fit = CTLineGetStringRange(line).length;
	std::vector<CGFloat> lineAdvances(fit);
	CFArrayRef runs = CTLineGetGlyphRuns(line);
	for (CFIndex run = 0; run < CFArrayGetCount(runs); run++) {
		CTRunRef aRun = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, run));
		const CFIndex glyphCount = CTRunGetGlyphCount(aRun);
		std::vector<CFIndex> indices(glyphCount);
		CTRunGetStringIndices(aRun, CFRangeMake(0, glyphCount), indices.data());
		std::vector<CGSize> advances(glyphCount);
		CTRunGetAdvances(aRun, CFRangeMake(0, glyphCount), advances.data());
		for (CFIndex glyph = 0; glyph < glyphCount; glyph++) {
			if (indices[glyph] < fit) {
				lineAdvances[indices[glyph]] = advances[glyph].width;
			}
		}
	}
	std::vector<CGFloat> linePositions(fit);
	std::partial_sum(lineAdvances.begin(), lineAdvances.end(), linePositions.begin());
	size_t i = 0;
	CFIndex ui = 0;
	while (ui < fit && i < text.length()) {
		const unsigned char uch = text[i];
		const unsigned int byteCount = uch < 0x80 ? 1 : (uch < 0xE0 ? 2 : (uch < 0xF0 ? 3 : 4));
		const CGFloat xPosition = linePositions[ui];
		for (unsigned int b = 0; b < byteCount && i < text.length(); b++) {
			positions[i++] = xPosition;
		}
		ui += byteCount == 4 ? 2 : 1;
	}
	const XYPOSITION lastPos = i > 0 ? positions[i - 1] : 0.0;
	while (i < text.length()) {
		positions[i++] = lastPos;
	}
	CFRelease(line);
	return positions;
}

CGContextRef MakeContext(int width, int height, double scale) {
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGContextRef gc = CGBitmapContextCreate(nullptr, width * scale, height * scale, 8, 0, colorSpace,
						kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(colorSpace);
	// Flipped, like the NSView Scintilla draws into.
	CGContextTranslateCTM(gc, 0, height * scale);
	CGContextScaleCTM(gc, scale, -scale);
	CGContextSetRGBFillColor(gc, 1.0, 1.0, 1.0, 1.0);
	CGContextFillRect(gc, CGRectMake(0, 0, width, height));
	return gc;
}

bool SamePixels(CGContextRef a, CGContextRef b) {
	const size_t bytes = CGBitmapContextGetBytesPerRow(a) * CGBitmapContextGetHeight(a);
	return bytes == CGBitmapContextGetBytesPerRow(b) * CGBitmapContextGetHeight(b) &&
		memcmp(CGBitmapContextGetData(a), CGBitmapContextGetData(b), bytes) == 0;
}

}

int main() {
	@autoreleasepool {
		const TestFont fonts[] = {
			{"Menlo", 12.0f, FontWeight::Normal, false},
			{"Menlo", 12.0f, FontWeight::Bold, false},
			{"Menlo", 12.0f, FontWeight::Normal, true},
			{"Menlo", 17.5f, FontWeight::Normal, false},
			{"Monaco", 11.0f, FontWeight::Normal, false},
			{"Courier New", 12.0f, FontWeight::Normal, false},
			{"Georgia", 13.0f, FontWeight::Normal, false},
			{"Helvetica", 12.0f, FontWeight::Normal, false},	// fi ligature: keeps the CTLine path
			{"Times New Roman", 14.0f, FontWeight::Normal, false},
		};
		const std::string texts[] = {
			"0.00123456",
			"-12.345678",
			"x",
			" ",
			"    ",
			"Hello, World! {}[]()<>=-+*/\\|~`'\"",
			"AVAVAV To Ta fi ffi ffl www === !== -> => <= :: ...",
			"!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~",
			std::string(300, 'x'),
			std::string(1500, '7'),
			"caf\xc3\xa9 na\xc3\xafve",
			"tab\there",
			"ctrl\x01x\x7f",
			"\xe4\xb8\xad\xe6\x96\x87 mixed",
			"emoji \xf0\x9f\x98\x80 end",
		};
		const ColourRGBA colours[] = {
			ColourRGBA(0x20, 0x20, 0x20),
			ColourRGBA(0x00, 0x00, 0xC0),
			ColourRGBA(0x80, 0x80, 0x80, 0xC0),
		};

		for (const TestFont &tf : fonts) {
			FontParameters fp(tf.name, tf.size, tf.weight, tf.italic);
			std::shared_ptr<Font> font = Font::Allocate(fp);
			// The CTFont PlatCocoa uses: rebuilt from the same parameters.
			QuartzFont reference(tf.name, strlen(tf.name), tf.size, tf.weight, FontStretch::Normal, tf.italic);
			CTFontRef ctFont = reference.getFontID();
			const std::string fontLabel = std::string(tf.name) + " " + std::to_string(tf.size) +
				(tf.weight == FontWeight::Bold ? " bold" : "") + (tf.italic ? " italic" : "");

			CGContextRef measureContext = MakeContext(10, 10, 1.0);
			SurfaceImpl surface;
			surface.Init(measureContext, nullptr);
			surface.SetMode(SurfaceMode(SC_CP_UTF8, false));

			for (const std::string &text : texts) {
				const std::string label = fontLabel + " '" + text.substr(0, 40) + "'";
				const std::vector<XYPOSITION> expected = ReferencePositions(ctFont, text);

				std::vector<XYPOSITION> positions(text.length(), -1.0);
				surface.MeasureWidthsUTF8(font.get(), text, positions.data());
				Check(positions == expected, "MeasureWidthsUTF8 " + label);

				std::fill(positions.begin(), positions.end(), -1.0);
				surface.MeasureWidths(font.get(), text, positions.data());
				Check(positions == expected, "MeasureWidths " + label);

				CTLineRef line = ReferenceLine(ctFont, text, nullptr);
				const XYPOSITION expectedWidth = static_cast<XYPOSITION>(
					static_cast<float>(CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr)));
				CFRelease(line);
				Check(surface.WidthTextUTF8(font.get(), text) == expectedWidth, "WidthTextUTF8 " + label);
				Check(surface.WidthText(font.get(), text) == expectedWidth, "WidthText " + label);

				for (const double scale : {1.0, 2.0}) {
					for (const XYPOSITION x : {0.0, 3.25, 7.224609375}) {
						for (const ColourRGBA &colour : colours) {
							const int width = static_cast<int>(std::ceil(expectedWidth + x)) + 8;
							CGContextRef actual = MakeContext(width, 24, scale);
							CGContextRef wanted = MakeContext(width, 24, scale);

							SurfaceImpl drawSurface;
							drawSurface.Init(actual, nullptr);
							drawSurface.SetMode(SurfaceMode(SC_CP_UTF8, false));
							drawSurface.DrawTextTransparent(PRectangle(x, 0, x + expectedWidth, 24), font.get(), 17.0,
											text, colour);
							// The fill colour drawing leaves set, used by a fill with no colour of its own.
							CGContextFillRect(actual, CGRectMake(0, 20, 4, 4));

							CGColorRef cgColour = CGColorCreateGenericRGB(colour.GetRedComponent(),
												  colour.GetGreenComponent(),
												  colour.GetBlueComponent(),
												  colour.GetAlphaComponent());
							CTLineRef drawLine = ReferenceLine(ctFont, text, cgColour);
							CGContextSetTextMatrix(wanted, CGAffineTransformMakeScale(1.0, -1.0));
							CGContextSetTextPosition(wanted, x, 17.0);
							CTLineDraw(drawLine, wanted);
							CGContextFillRect(wanted, CGRectMake(0, 20, 4, 4));
							CFRelease(drawLine);
							CGColorRelease(cgColour);

							Check(SamePixels(actual, wanted), "DrawTextTransparent " + label + " scale " +
							      std::to_string(scale) + " x " + std::to_string(x));
							CGContextRelease(actual);
							CGContextRelease(wanted);
						}
					}
				}
			}
			CGContextRelease(measureContext);
		}
	}
	printf("%d checks, %d failures\n", checks, failures);
	return failures == 0 ? 0 : 1;
}
