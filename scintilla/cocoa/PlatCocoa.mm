/**
 * Scintilla source code edit control
 * @file PlatCocoa.mm - implementation of platform facilities on macOS/Cocoa
 *
 * Written by Mike Lischke
 * Based on PlatMacOSX.cxx
 * Based on work by Evan Jones (c) 2002 <ejones@uwaterloo.ca>
 * Based on PlatGTK.cxx Copyright 1998-2002 by Neil Hodgson <neilh@scintilla.org>
 * The License.txt file describes the conditions under which this software may be distributed.
 *
 * Copyright 2009 Sun Microsystems, Inc. All rights reserved.
 * This file is dual licensed under LGPL v2.1 and the Scintilla license (http://www.scintilla.org/License.txt).
 */

#include <cstddef>
#include <cstdlib>
#include <cassert>
#include <cstring>
#include <cstdio>
#include <cmath>

#include <stdexcept>
#include <string_view>
#include <vector>
#include <map>
#include <optional>
#include <functional>
#include <memory>
#include <numeric>
#include <mutex>	// LOCAL CHANGE: ASCII fast path font table cache.

#import <Foundation/NSGeometry.h>

#import "ScintillaTypes.h"
#import "ScintillaMessages.h"
#import "ScintillaStructures.h"

#import "Debugging.h"
#import "Geometry.h"
#import "Platform.h"

#include "XPM.h"
#include "UniConversion.h"

#import "ScintillaView.h"
#import "ScintillaCocoa.h"
#import "PlatCocoa.h"
// LOCAL CHANGE: performance probes (src/perf/NppPerfProbe.h); inert unless
// the app turns diagnostics on.
#include "NppPerfProbe.h"

using namespace Scintilla;
using namespace Scintilla::Internal;

extern sptr_t scintilla_send_message(void *sci, unsigned int iMessage, uptr_t wParam, sptr_t lParam);

//--------------------------------------------------------------------------------------------------

/**
 * Converts a Point as used by Scintilla to a Quartz-style CGPoint.
 */
inline CGPoint CGPointFromPoint(Scintilla::Internal::Point pt) {
	return CGPointMake(pt.x, pt.y);
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts a PRectangle as used by Scintilla to standard Obj-C NSRect structure .
 */
NSRect PRectangleToNSRect(const PRectangle &rc) {
	return NSMakeRect(rc.left, rc.top, rc.Width(), rc.Height());
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts an NSRect as used by the system to a native Scintilla rectangle.
 */
PRectangle NSRectToPRectangle(const NSRect &rc) {
	return PRectangle(rc.origin.x, rc.origin.y, NSMaxX(rc), NSMaxY(rc));
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts a PRectangle as used by Scintilla to a Quartz-style rectangle.
 */
inline CGRect PRectangleToCGRect(PRectangle &rc) {
	return CGRectMake(rc.left, rc.top, rc.Width(), rc.Height());
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts a PRectangle as used by Scintilla to a Quartz-style rectangle.
 * Result is inset by strokeWidth / 2 so stroking does not go outside the rectangle.
 */
inline CGRect CGRectFromPRectangleInset(PRectangle rc, XYPOSITION strokeWidth) {
	const XYPOSITION halfStroke = strokeWidth / 2.0f;
	const CGRect rect = PRectangleToCGRect(rc);
	return CGRectInset(rect, halfStroke, halfStroke);
}

//----------------- Text colour ------------------------------------------------------------------

// LOCAL CHANGE: cached text colours.
namespace {

// Text colours as generic RGB CGColors, the colour space CGColorCreateGenericRGB
// has always given text here, so colours look the same. Kept in a small
// direct-mapped cache per thread instead of creating and releasing one CGColor
// for every text run drawn; a paint uses only a few distinct text colours.
class GenericColourCache {
	struct Entry {
		int key = 0;
		CGColorRef colour = nullptr;
	};
	static constexpr size_t size = 64;
	Entry entries[size];
public:
	GenericColourCache() = default;
	GenericColourCache(const GenericColourCache &) = delete;
	GenericColourCache &operator=(const GenericColourCache &) = delete;
	~GenericColourCache() {
		for (Entry &entry : entries) {
			if (entry.colour) {
				CGColorRelease(entry.colour);
			}
		}
	}
	CGColorRef Get(ColourRGBA colour) {
		const int key = colour.AsInteger();
		// Multiplicative hash; the top 6 bits index the 64 entries.
		Entry &entry = entries[(static_cast<uint32_t>(key) * 2654435761u) >> 26];
		if (entry.colour && entry.key == key) {
			return entry.colour;
		}
		CGColorRef created = CGColorCreateGenericRGB(colour.GetRedComponent(),
							     colour.GetGreenComponent(),
							     colour.GetBlueComponent(),
							     colour.GetAlphaComponent());
		if (entry.colour) {
			CGColorRelease(entry.colour);
		}
		entry.key = key;
		entry.colour = created;
		return created;
	}
};

// The returned colour belongs to the cache: retain it to keep it past the next call.
CGColorRef GenericColour(ColourRGBA colour) {
	thread_local GenericColourCache cache;
	return cache.Get(colour);
}

}

//----------------- ASCII fast path ----------------------------------------------------------------

// LOCAL CHANGE: draw and measure runs of printable ASCII without CoreText line layout.
// Each text run used to cost a CFString, a CFAttributedString and a CTLine, for
// drawing and again for measuring. When CoreText lays out printable ASCII in a
// font as one glyph per character at the glyph's nominal advance, the glyphs and
// positions follow from a per-font table, so runs made only of such characters
// are drawn with CTFontDrawGlyphs and measured by summing advances. Whether a font
// qualifies is checked once, against CoreText's own layout, by
// BuildASCIIMetrics; fonts that do not qualify, and any run with another byte,
// keep the CTLine path.

namespace {

constexpr bool IsPrintableASCII(unsigned char ch) noexcept {
	return ch >= QuartzASCIIMetrics::first && ch <= QuartzASCIIMetrics::last;
}

// Lays out chars with CoreText and checks that the result is one run in the
// requested font holding one glyph per character, in order, with the table's
// glyph and advance and the running sum of advances as its position. Also checks
// the line width and, when checkOffsets is set, the caret offsets that the
// single-byte and DBCS paths of SurfaceImpl::MeasureWidths read.
bool LayoutMatchesTable(CTFontRef font, CFDictionaryRef attributes, const std::vector<UniChar> &chars,
			const QuartzASCIIMetrics &metrics, bool checkOffsets) {
	CFStringRef str = CFStringCreateWithCharacters(kCFAllocatorDefault, chars.data(), chars.size());
	if (!str) {
		return false;
	}
	CFAttributedStringRef as = CFAttributedStringCreate(kCFAllocatorDefault, str, attributes);
	CFRelease(str);
	if (!as) {
		return false;
	}
	CTLineRef line = CTLineCreateWithAttributedString(as);
	CFRelease(as);
	if (!line) {
		return false;
	}
	bool matches = false;
	CFArrayRef runs = CTLineGetGlyphRuns(line);
	if (CFArrayGetCount(runs) == 1) {
		CTRunRef run = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, 0));
		const CFIndex glyphCount = CTRunGetGlyphCount(run);
		const CTRunStatus unexpectedStatus = kCTRunStatusRightToLeft | kCTRunStatusNonMonotonic | kCTRunStatusHasNonIdentityMatrix;
		CTFontRef runFont = static_cast<CTFontRef>(CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName));
		if (glyphCount == static_cast<CFIndex>(chars.size()) && !(CTRunGetStatus(run) & unexpectedStatus) &&
			runFont && CFEqual(runFont, font)) {
			const CFRange rangeAll = CFRangeMake(0, glyphCount);
			std::vector<CGGlyph> glyphs(glyphCount);
			CTRunGetGlyphs(run, rangeAll, glyphs.data());
			std::vector<CGSize> advances(glyphCount);
			CTRunGetAdvances(run, rangeAll, advances.data());
			std::vector<CFIndex> indices(glyphCount);
			CTRunGetStringIndices(run, rangeAll, indices.data());
			std::vector<CGPoint> positions(glyphCount);
			CTRunGetPositions(run, rangeAll, positions.data());
			matches = true;
			CGFloat xPosition = 0.0;
			for (CFIndex i = 0; matches && i < glyphCount; i++) {
				const size_t index = chars[i] - QuartzASCIIMetrics::first;
				matches = indices[i] == i && glyphs[i] == metrics.glyphs[index] &&
					advances[i].width == metrics.advances[index] &&
					positions[i].x == xPosition && positions[i].y == 0.0;
				xPosition += metrics.advances[index];
				if (matches && checkOffsets) {
					matches = CTLineGetOffsetForStringIndex(line, i + 1, nullptr) == xPosition;
				}
			}
			if (matches) {
				matches = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr) == xPosition;
			}
		}
	}
	CFRelease(line);
	return matches;
}

// True when the font turns on contextual alternates or contextual ligatures by
// default. Those can depend on any amount of context, which the layout checks
// below do not cover, so such fonts (programming ligature fonts, typically)
// keep the CTLine path.
bool HasDefaultContextualFeatures(CTFontRef font) {
	CFArrayRef features = CTFontCopyFeatures(font);
	if (!features) {
		return false;
	}
	bool contextual = false;
	for (CFIndex f = 0; !contextual && f < CFArrayGetCount(features); f++) {
		CFDictionaryRef feature = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(features, f));
		CFNumberRef typeNumber = static_cast<CFNumberRef>(CFDictionaryGetValue(feature, kCTFontFeatureTypeIdentifierKey));
		CFArrayRef selectors = static_cast<CFArrayRef>(CFDictionaryGetValue(feature, kCTFontFeatureTypeSelectorsKey));
		int type = -1;
		if (!typeNumber || !selectors || !CFNumberGetValue(typeNumber, kCFNumberIntType, &type)) {
			continue;
		}
		if (type != kContextualAlternatesType && type != kLigaturesType) {
			continue;
		}
		for (CFIndex s = 0; !contextual && s < CFArrayGetCount(selectors); s++) {
			CFDictionaryRef selector = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(selectors, s));
			CFNumberRef selectorNumber = static_cast<CFNumberRef>(CFDictionaryGetValue(selector, kCTFontFeatureSelectorIdentifierKey));
			CFBooleanRef isDefault = static_cast<CFBooleanRef>(CFDictionaryGetValue(selector, kCTFontFeatureSelectorDefaultKey));
			int selectorId = -1;
			if (!selectorNumber || !isDefault || !CFBooleanGetValue(isDefault) ||
				!CFNumberGetValue(selectorNumber, kCFNumberIntType, &selectorId)) {
				continue;
			}
			contextual = (type == kContextualAlternatesType && selectorId == kContextualAlternatesOnSelector) ||
				(type == kLigaturesType && selectorId == kContextualLigaturesOnSelector);
		}
	}
	CFRelease(features);
	return contextual;
}

// Returns the table for font, or nullptr when CoreText's layout of printable ASCII
// in this font is not one nominal glyph per character. Checked with every ordered
// pair of printable ASCII characters (pair kerning, two-character ligatures) and
// with longer sequences that ligature fonts commonly substitute. Each test line
// stays short: CoreText skips shaping on lines of many thousands of characters.
std::unique_ptr<QuartzASCIIMetrics> BuildASCIIMetrics(CTFontRef font) {
	if (!font || HasDefaultContextualFeatures(font)) {
		return nullptr;
	}
	auto metrics = std::make_unique<QuartzASCIIMetrics>();
	UniChar characters[QuartzASCIIMetrics::count];
	for (size_t i = 0; i < QuartzASCIIMetrics::count; i++) {
		characters[i] = static_cast<UniChar>(QuartzASCIIMetrics::first + i);
	}
	if (!CTFontGetGlyphsForCharacters(font, characters, metrics->glyphs, QuartzASCIIMetrics::count)) {
		return nullptr;	// Some character is missing from the font and would come from a fallback font.
	}
	CGSize advances[QuartzASCIIMetrics::count];
	CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, metrics->glyphs, advances, QuartzASCIIMetrics::count);
	for (size_t i = 0; i < QuartzASCIIMetrics::count; i++) {
		metrics->advances[i] = advances[i].width;
	}

	CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
								      &kCFTypeDictionaryKeyCallBacks,
								      &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(attributes, kCTFontAttributeName, font);
	bool matches = true;
	std::vector<UniChar> chars;
	// One line per first character: "a a a ! a \" ... a ~" holds (a, x) and (x, a) for every x.
	for (size_t first = 0; matches && first < QuartzASCIIMetrics::count; first++) {
		chars.clear();
		for (size_t second = 0; second < QuartzASCIIMetrics::count; second++) {
			chars.push_back(characters[first]);
			chars.push_back(characters[second]);
		}
		matches = LayoutMatchesTable(font, attributes, chars, *metrics, first == 0);
	}
	if (matches) {
		const char sequences[] = "ffi ffl fff fj www ... ..= ..< ::: ;;; === !== =/= <=> <== ==> <-- --> <!-- ->> <<- "
					 "|||> <||| &&& ||| ### #{ #[ #( /** **/ /// //= +++ *** ~~> ~~~ <<< >>> <~> 0x0 1x1 "
					 "__ ?? ?. ?= !! :: <> </> </ /> ~@ |> <| .= .- -< >- >= <= != == => -> // /* */";
		chars.assign(sequences, sequences + strlen(sequences));
		matches = LayoutMatchesTable(font, attributes, chars, *metrics, true);
	}
	CFRelease(attributes);
	if (!matches) {
		return nullptr;
	}
	return metrics;
}

// Fonts are recreated whenever Scintilla refreshes its styles (twice a frame while
// scrolling), so tables are cached for the process by font equality. Entries are
// never removed: one exists per distinct font and size used, and styles hold raw
// pointers to them.
const QuartzASCIIMetrics *ASCIIMetricsForFont(CTFontRef font) {
	if (!font) {
		return nullptr;
	}
	static std::mutex mutexCache;
	static CFMutableDictionaryRef cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
									&kCFTypeDictionaryKeyCallBacks, nullptr);
	static const char notEligible = 0;
	std::lock_guard<std::mutex> guard(mutexCache);
	const void *value = nullptr;
	if (CFDictionaryGetValueIfPresent(cache, font, &value)) {
		return (value == &notEligible) ? nullptr : static_cast<const QuartzASCIIMetrics *>(value);
	}
	NPP_PERF_SCOPE("PlatCocoa.ASCIIMetrics.build");	// LOCAL CHANGE: performance probe.
	const QuartzASCIIMetrics *metrics = BuildASCIIMetrics(font).release();
	if (!metrics) {
		NPP_PERF_COUNT("PlatCocoa.ASCIIMetrics.ineligible");	// LOCAL CHANGE: performance probe.
	}
	CFDictionarySetValue(cache, font, metrics ? static_cast<const void *>(metrics) : &notEligible);
	return metrics;
}

// Encodings that decode every printable ASCII byte to the same character
// (checked with CFStringCreateWithBytes). Shift-JIS maps '\\' and '~' to
// other characters and MacSymbol maps letters to Greek, so they are left out.
bool EncodingKeepsASCII(CFStringEncoding encoding) noexcept {
	switch (encoding) {
	case kCFStringEncodingUTF8:
	case kCFStringEncodingISOLatin1:
	case kCFStringEncodingMacRoman:
	case kCFStringEncodingWindowsBalticRim:
	case kCFStringEncodingBig5:
	case kCFStringEncodingWindowsLatin2:
	case kCFStringEncodingGB_18030_2000:
	case kCFStringEncodingWindowsGreek:
	case kCFStringEncodingEUC_KR:
	case kCFStringEncodingKOI8_R:
	case kCFStringEncodingWindowsCyrillic:
	case kCFStringEncodingWindowsLatin5:
	case kCFStringEncodingWindowsKoreanJohab:
	case kCFStringEncodingWindowsHebrew:
	case kCFStringEncodingWindowsArabic:
	case kCFStringEncodingWindowsVietnamese:
	case kCFStringEncodingISOLatinThai:
		return true;
	default:
		return false;
	}
}

// Draws text like QuartzTextLayout::draw would for a CTLine: same text matrix and
// text position, glyphs at the same positions, and the fill colour left set to the
// text colour as CTLineDraw leaves it. Returns false, having drawn nothing, when
// the font has no table or text holds a byte outside printable ASCII.
bool DrawASCII(CGContextRef gc, const QuartzTextStyle *style, std::string_view text, CGColorRef colour,
	       CGFloat x, CGFloat ybase) {
	const QuartzASCIIMetrics *metrics = style->getASCIIMetrics();
	if (!metrics || text.empty() || !gc) {
		return false;
	}
	constexpr size_t stackLength = 256;
	CGGlyph glyphsStack[stackLength];
	CGPoint positionsStack[stackLength];
	std::vector<CGGlyph> glyphsHeap;
	std::vector<CGPoint> positionsHeap;
	CGGlyph *glyphs = glyphsStack;
	CGPoint *positions = positionsStack;
	if (text.length() > stackLength) {
		glyphsHeap.resize(text.length());
		positionsHeap.resize(text.length());
		glyphs = glyphsHeap.data();
		positions = positionsHeap.data();
	}
	CGFloat xPosition = 0.0;
	for (size_t i = 0; i < text.length(); i++) {
		const unsigned char ch = text[i];
		if (!IsPrintableASCII(ch)) {
			return false;
		}
		const size_t index = ch - QuartzASCIIMetrics::first;
		glyphs[i] = metrics->glyphs[index];
		positions[i] = CGPointMake(xPosition, 0.0);
		xPosition += metrics->advances[index];
	}
	NPP_PERF_COUNT("PlatCocoa.DrawText.ascii");	// LOCAL CHANGE: performance probe.
	CGContextSetFillColorWithColor(gc, colour);
	CGContextSetTextMatrix(gc, CGAffineTransformMakeScale(1.0, -1.0));
	CGContextSetTextPosition(gc, x, ybase);
	CTFontDrawGlyphs(style->getFontRef(), glyphs, positions, text.length(), gc);
	return true;
}

// Fills positions as SurfaceImpl::MeasureWidths does from a CTLine: the running
// sum of advances, one entry per byte. Returns false when the font has no table
// or text holds a byte outside printable ASCII; positions is then partly written.
bool MeasureASCII(const QuartzTextStyle *style, std::string_view text, XYPOSITION *positions) noexcept {
	const QuartzASCIIMetrics *metrics = style->getASCIIMetrics();
	if (!metrics || text.empty()) {
		return false;
	}
	CGFloat xPosition = 0.0;
	for (size_t i = 0; i < text.length(); i++) {
		const unsigned char ch = text[i];
		if (!IsPrintableASCII(ch)) {
			return false;
		}
		xPosition += metrics->advances[ch - QuartzASCIIMetrics::first];
		positions[i] = xPosition;
	}
	NPP_PERF_COUNT("PlatCocoa.MeasureWidths.ascii");	// LOCAL CHANGE: performance probe.
	return true;
}

// Width as SurfaceImpl::WidthText returns it from a CTLine, including the
// rounding to float of QuartzTextLayout::MeasureStringWidth.
std::optional<XYPOSITION> WidthASCII(const QuartzTextStyle *style, std::string_view text) noexcept {
	const QuartzASCIIMetrics *metrics = style->getASCIIMetrics();
	if (!metrics || text.empty()) {
		return std::nullopt;
	}
	CGFloat width = 0.0;
	for (const unsigned char ch : text) {
		if (!IsPrintableASCII(ch)) {
			return std::nullopt;
		}
		width += metrics->advances[ch - QuartzASCIIMetrics::first];
	}
	return static_cast<XYPOSITION>(static_cast<float>(width));
}

}

//----------------- FontQuartz ---------------------------------------------------------------------

class FontQuartz : public Font {
public:
	std::unique_ptr<QuartzTextStyle> style;
	FontQuartz(const FontParameters &fp) {
		// LOCAL CHANGE: performance probe (CTFont creation for a style).
		NPP_PERF_SCOPE("PlatCocoa.FontCreate", "%{public}s size=%.1f weight=%d", fp.faceName, fp.size, static_cast<int>(fp.weight));
		style = std::make_unique<QuartzTextStyle>();
		// Create the font with attributes
		QuartzFont font(fp.faceName, strlen(fp.faceName), fp.size, fp.weight, fp.stretch, fp.italic);
		CTFontRef fontRef = font.getFontID();
		style->setFontRef(fontRef, fp.characterSet);
		style->setASCIIMetrics(ASCIIMetricsForFont(fontRef));	// LOCAL CHANGE: ASCII fast path.
	}
	FontQuartz(const QuartzTextStyle *style_) {
		style = std::make_unique<QuartzTextStyle>(style_);
	}
};

//--------------------------------------------------------------------------------------------------

static QuartzTextStyle *TextStyleFromFont(const Font *f) noexcept {
	if (f) {
		const FontQuartz *pfq = dynamic_cast<const FontQuartz *>(f);
		if (pfq) {
			return pfq->style.get();
		}
	}
	return nullptr;
}

//--------------------------------------------------------------------------------------------------

/**
 * Creates a CTFontRef with the given properties.
 */
std::shared_ptr<Font> Font::Allocate(const FontParameters &fp) {
	return std::make_shared<FontQuartz>(fp);
}

//--------------------------------------------------------------------------------------------------

// Bidirectional text support for Arabic and Hebrew.

namespace {

CFIndex IndexFromPosition(std::string_view text, size_t position) {
	const std::string_view textUptoPosition = text.substr(0, position);
	return UTF16Length(textUptoPosition);
}

// Handling representations and tabs

struct Blob {
	XYPOSITION width;
	Blob(XYPOSITION width_) : width(width_) {
	}
};

static void BlobDealloc(void *refCon) {
	Blob *blob = static_cast<Blob *>(refCon);
	delete blob;
}

static CGFloat BlobGetWidth(void *refCon) {
	Blob *blob = static_cast<Blob *>(refCon);
	return blob->width;
}

class ScreenLineLayout : public IScreenLineLayout {
	CTLineRef line = NULL;
	const std::string text;
public:
	ScreenLineLayout(const IScreenLine *screenLine);
	~ScreenLineLayout();
	// IScreenLineLayout implementation
	size_t PositionFromX(XYPOSITION xDistance, bool charPosition) override;
	XYPOSITION XFromPosition(size_t caretPosition) override;
	std::vector<Interval> FindRangeIntervals(size_t start, size_t end) override;
};

ScreenLineLayout::ScreenLineLayout(const IScreenLine *screenLine) : text(screenLine->Text()) {
	// LOCAL CHANGE: performance probe (bidirectional line layout).
	NPP_PERF_SCOPE_FINE("PlatCocoa.ScreenLineLayout", "bytes=%lu", static_cast<unsigned long>(text.length()));
	const UInt8 *puiBuffer = reinterpret_cast<const UInt8 *>(text.data());
	std::string_view sv = text;

	// Start with an empty mutable attributed string and add each character to it.
	CFMutableAttributedStringRef mas = CFAttributedStringCreateMutable(NULL, 0);

	for (size_t bp=0; bp<text.length();) {
		const unsigned char uch = text[bp];
		const int utf8Status = UTF8Classify(sv);
		const unsigned int byteCount = utf8Status & UTF8MaskWidth;
		XYPOSITION repWidth = screenLine->RepresentationWidth(bp);
		if (uch == '\t') {
			// Find the size up to the tab
			NSMutableAttributedString *nas = (__bridge NSMutableAttributedString *)mas;
			const NSSize sizeUpTo = [nas size];
			const XYPOSITION nextTab = screenLine->TabPositionAfter(sizeUpTo.width);
			repWidth = nextTab - sizeUpTo.width;
		}
		CFAttributedStringRef as = NULL;
		if (repWidth > 0.0f) {
			CTRunDelegateCallbacks callbacks = {
				.version = kCTRunDelegateVersion1,
				.dealloc = BlobDealloc,
				.getWidth = BlobGetWidth
			};
			CTRunDelegateRef runDelegate = CTRunDelegateCreate(&callbacks, new Blob(repWidth));
			NSMutableAttributedString *masBlob = [[NSMutableAttributedString alloc] initWithString:@"X"];
			NSRange rangeX = NSMakeRange(0, 1);
			[masBlob addAttribute: (NSString *)kCTRunDelegateAttributeName value: (__bridge id)runDelegate range:rangeX];
			CFRelease(runDelegate);
			as = (CFAttributedStringRef)CFBridgingRetain(masBlob);
		} else {
			CFStringRef piece = CFStringCreateWithBytes(NULL,
								    &puiBuffer[bp],
								    byteCount,
								    kCFStringEncodingUTF8,
								    false);
			const QuartzTextStyle *qts = TextStyleFromFont(screenLine->FontOfPosition(bp));
			CFMutableDictionaryRef pieceAttributes = qts->getCTStyle();
			as = CFAttributedStringCreate(NULL, piece, pieceAttributes);
			CFRelease(piece);
		}
		CFAttributedStringReplaceAttributedString(mas,
							  CFRangeMake(CFAttributedStringGetLength(mas), 0),
							  as);
		bp += byteCount;
		sv.remove_prefix(byteCount);
		CFRelease(as);
	}

	line = CTLineCreateWithAttributedString(mas);
	CFRelease(mas);
}

ScreenLineLayout::~ScreenLineLayout() {
	CFRelease(line);
}

size_t ScreenLineLayout::PositionFromX(XYPOSITION xDistance, bool charPosition) {
	if (!line) {
		return 0;
	}
	const CGPoint ptDistance = CGPointMake(xDistance, 0);
	const CFIndex offset = CTLineGetStringIndexForPosition(line, ptDistance);
	if (offset == kCFNotFound) {
		return 0;
	}
	// Convert back to UTF-8 positions
	return UTF8PositionFromUTF16Position(text, offset);
}

XYPOSITION ScreenLineLayout::XFromPosition(size_t caretPosition) {
	if (!line) {
		return 0.0;
	}
	// Convert from UTF-8 position
	const CFIndex caretIndex = IndexFromPosition(text, caretPosition);

	const CGFloat distance = CTLineGetOffsetForStringIndex(line, caretIndex, nullptr);
	return distance;
}

void AddToIntervalVector(std::vector<Interval> &vi, XYPOSITION left, XYPOSITION right) {
	const Interval interval = {left, right};
	if (vi.empty()) {
		vi.push_back(interval);
	} else {
		Interval &last = vi.back();
		if (std::abs(last.right-interval.left) < 0.01) {
			// If new left is very close to previous right then extend last item
			last.right = interval.right;
		} else {
			vi.push_back(interval);
		}
	}
}

std::vector<Interval> ScreenLineLayout::FindRangeIntervals(size_t start, size_t end) {
	if (!line) {
		return {};
	}

	std::vector<Interval> ret;

	// Convert from UTF-8 position
	const CFIndex startIndex = IndexFromPosition(text, start);
	const CFIndex endIndex = IndexFromPosition(text, end);

	CFArrayRef runs = CTLineGetGlyphRuns(line);
	const CFIndex runCount = CFArrayGetCount(runs);
	for (CFIndex run=0; run<runCount; run++) {
		CTRunRef aRun = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, run));
		const CFIndex glyphCount = CTRunGetGlyphCount(aRun);
		const CFRange rangeAll = CFRangeMake(0, glyphCount);
		std::vector<CFIndex> indices(glyphCount);
		CTRunGetStringIndices(aRun, rangeAll, indices.data());
		std::vector<CGPoint> positions(glyphCount);
		CTRunGetPositions(aRun, rangeAll, positions.data());
		std::vector<CGSize> advances(glyphCount);
		CTRunGetAdvances(aRun, rangeAll, advances.data());
		for (CFIndex glyph=0; glyph<glyphCount; glyph++) {
			const CFIndex glyphIndex = indices[glyph];
			const XYPOSITION xPosition = positions[glyph].x;
			const XYPOSITION width = advances[glyph].width;
			if ((glyphIndex >= startIndex) && (glyphIndex < endIndex)) {
				AddToIntervalVector(ret, xPosition, xPosition + width);
			}
		}
	}
	return ret;
}

// Helper for SurfaceImpl::MeasureWidths that examines the glyph runs in a layout

void GetPositions(CTLineRef line, std::vector<CGFloat> &positions) {

	// Find the advances of the text
	std::vector<CGFloat> lineAdvances(positions.size());
	CFArrayRef runs = CTLineGetGlyphRuns(line);
	const CFIndex runCount = CFArrayGetCount(runs);
	for (CFIndex run=0; run<runCount; run++) {
		CTRunRef aRun = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, run));
		const CFIndex glyphCount = CTRunGetGlyphCount(aRun);
		const CFRange rangeAll = CFRangeMake(0, glyphCount);
		std::vector<CFIndex> indices(glyphCount);
		CTRunGetStringIndices(aRun, rangeAll, indices.data());
		std::vector<CGSize> advances(glyphCount);
		CTRunGetAdvances(aRun, rangeAll, advances.data());
		for (CFIndex glyph=0; glyph<glyphCount; glyph++) {
			const CFIndex glyphIndex = indices[glyph];
			if (glyphIndex >= positions.size()) {
				return;
			}
			lineAdvances[glyphIndex] = advances[glyph].width;
		}
	}

	// Accumulate advances into positions
	std::partial_sum(lineAdvances.begin(), lineAdvances.end(),
			 positions.begin(), std::plus<CGFloat>());
}

const Supports SupportsCocoa[] = {
	Supports::LineDrawsFinal,
	Supports::PixelDivisions,
	Supports::FractionalStrokeWidth,
	Supports::TranslucentStroke,
	Supports::PixelModification,
	Supports::ThreadSafeMeasureWidths,
};

}

//----------------- SurfaceImpl --------------------------------------------------------------------

SurfaceImpl::SurfaceImpl() {
	gc = NULL;

	bitmapData.reset(); // Release will try and delete bitmapData if != nullptr
	bitmapWidth = 0;
	bitmapHeight = 0;

	Release();
}

SurfaceImpl::SurfaceImpl(const SurfaceImpl *surface, int width, int height) {

	// Create a new bitmap context, along with the RAM for the bitmap itself
	bitmapWidth = width;
	bitmapHeight = height;

	const int bitmapBytesPerRow = (width * BYTES_PER_PIXEL);
	const int bitmapByteCount = (bitmapBytesPerRow * height);

	// Create an RGB color space.
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	if (colorSpace == NULL)
		return;

	// Create the bitmap.
	bitmapData.reset(new uint8_t[bitmapByteCount]);
	// create the context
	gc = CGBitmapContextCreate(bitmapData.get(),
				   width,
				   height,
				   BITS_PER_COMPONENT,
				   bitmapBytesPerRow,
				   colorSpace,
				   kCGImageAlphaPremultipliedLast);

	if (gc == NULL) {
		// the context couldn't be created for some reason,
		// and we have no use for the bitmap without the context
		bitmapData.reset();
	}

	// the context retains the color space, so we can release it
	CGColorSpaceRelease(colorSpace);

	if (gc && bitmapData) {
		// "Erase" to white.
		CGContextClearRect(gc, CGRectMake(0, 0, width, height));
		CGContextSetRGBFillColor(gc, 1.0, 1.0, 1.0, 1.0);
		CGContextFillRect(gc, CGRectMake(0, 0, width, height));
	}

	mode = surface->mode;
}

//--------------------------------------------------------------------------------------------------

SurfaceImpl::~SurfaceImpl() {
	Clear();
}

//--------------------------------------------------------------------------------------------------

bool SurfaceImpl::UnicodeMode() const noexcept {
	return mode.codePage == SC_CP_UTF8;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Clear() {
	if (bitmapData) {
		bitmapData.reset();
		// We only "own" the graphics context if we are a bitmap context
		if (gc)
			CGContextRelease(gc);
	}
	gc = NULL;

	bitmapWidth = 0;
	bitmapHeight = 0;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Release() noexcept {
	Clear();
}

//--------------------------------------------------------------------------------------------------

bool SurfaceImpl::Initialised() {
	// We are initalised if the graphics context is not null
	return gc != NULL;// || port != NULL;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Init(WindowID) {
	// To be able to draw, the surface must get a CGContext handle.  We save the graphics port,
	// then acquire/release the context on an as-need basis (see above).
	// XXX Docs on QDBeginCGContext are light, a better way to do this would be good.
	// AFAIK we should not hold onto a context retrieved this way, thus the need for
	// acquire/release of the context.

	Release();
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Init(SurfaceID sid, WindowID) {
	Release();
	gc = static_cast<CGContextRef>(sid);
	CGContextSetLineWidth(gc, 1.0);
}

std::unique_ptr<Surface> SurfaceImpl::AllocatePixMap(int width, int height) {
	return std::make_unique<SurfaceImpl>(this, width, height);
}

std::unique_ptr<SurfaceImpl> SurfaceImpl::AllocatePixMapImplementation(int width, int height) {
	return std::make_unique<SurfaceImpl>(this, width, height);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::SetMode(SurfaceMode mode_) {
	mode = mode_;
}

//--------------------------------------------------------------------------------------------------

int SurfaceImpl::SupportsFeature(Supports feature) noexcept {
	for (const Supports f : SupportsCocoa) {
		if (f == feature)
			return 1;
	}
	return 0;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillColour(ColourRGBA fill) {
	// Set the Fill color to match
	CGContextSetRGBFillColor(gc,
				 fill.GetRedComponent(),
				 fill.GetGreenComponent(),
				 fill.GetBlueComponent(),
				 fill.GetAlphaComponent());
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::PenColourAlpha(ColourRGBA fore) {
	// Set the Stroke color to match
	CGContextSetRGBStrokeColor(gc,
				   fore.GetRedComponent(),
				   fore.GetGreenComponent(),
				   fore.GetBlueComponent(),
				   fore.GetAlphaComponent());
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::SetFillStroke(FillStroke fillStroke) {
	FillColour(fillStroke.fill.colour);
	PenColourAlpha(fillStroke.stroke.colour);
	CGContextSetLineWidth(gc, fillStroke.stroke.width);
}

//--------------------------------------------------------------------------------------------------

CGImageRef SurfaceImpl::CreateImage() {
	// For now, assume that CreateImage can only be called on PixMap surfaces.
	if (!bitmapData)
		return NULL;

	CGContextFlush(gc);

	// Create an RGB color space.
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	if (colorSpace == NULL)
		return NULL;

	const int bitmapBytesPerRow = bitmapWidth * BYTES_PER_PIXEL;
	const int bitmapByteCount = bitmapBytesPerRow * bitmapHeight;

	// Make a copy of the bitmap data for the image creation and divorce it
	// From the SurfaceImpl lifetime
	CFDataRef dataRef = CFDataCreate(kCFAllocatorDefault, bitmapData.get(), bitmapByteCount);

	// Create a data provider.
	CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData(dataRef);

	CGImageRef image = NULL;
	if (dataProvider != NULL) {
		// Create the CGImage.
		image = CGImageCreate(bitmapWidth,
				      bitmapHeight,
				      BITS_PER_COMPONENT,
				      BITS_PER_PIXEL,
				      bitmapBytesPerRow,
				      colorSpace,
				      kCGImageAlphaPremultipliedLast,
				      dataProvider,
				      NULL,
				      0,
				      kCGRenderingIntentDefault);
	}

	// The image retains the color space, so we can release it.
	CGColorSpaceRelease(colorSpace);
	colorSpace = NULL;

	// Done with the data provider.
	CGDataProviderRelease(dataProvider);
	dataProvider = NULL;

	// Done with the data provider.
	CFRelease(dataRef);

	return image;
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the vertical logical device resolution of the main monitor.
 * This is no longer called.
 * For Cocoa, all screens are treated as 72 DPI, even retina displays.
 */
int SurfaceImpl::LogPixelsY() {
	return 72;
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the number of device pixels per logical pixel.
 * 1 for older displays and 2 for retina displays. Potentially 3 for some phones.
 */
int SurfaceImpl::PixelDivisions() {
	if (gc) {
		const CGSize szDevice = CGContextConvertSizeToDeviceSpace(gc, CGSizeMake(1.0, 1.0));
		const int devicePixels = std::round(szDevice.width);
		assert(devicePixels == 1 || devicePixels == 2);
		return devicePixels;
	}
	return 1;
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts the logical font height in points into a device height.
 * For Cocoa, points are always used for the result even on retina displays.
 */
int SurfaceImpl::DeviceHeightFont(int points) {
	return points;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::LineDraw(Point start, Point end, Stroke stroke) {
	PenColourAlpha(stroke.colour);
	CGContextSetLineWidth(gc, stroke.width);

	CGContextBeginPath(gc);
	CGContextMoveToPoint(gc, start.x, start.y);
	CGContextAddLineToPoint(gc, end.x, end.y);
	CGContextStrokePath(gc);

	CGContextSetLineWidth(gc, 1.0f);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::PolyLine(const Point *pts, size_t npts, Stroke stroke) {
	PLATFORM_ASSERT(gc && (npts > 1));
	if (!gc || (npts <= 1)) {
		return;
	}
	PenColourAlpha(stroke.colour);
	CGContextSetLineWidth(gc, stroke.width);
	CGContextBeginPath(gc);
	CGContextMoveToPoint(gc, pts[0].x, pts[0].y);
	for (size_t i = 1; i < npts; i++) {
		CGContextAddLineToPoint(gc, pts[i].x, pts[i].y);
	}
	CGContextStrokePath(gc);

	CGContextSetLineWidth(gc, 1.0f);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Polygon(const Scintilla::Internal::Point *pts, size_t npts, FillStroke fillStroke) {
	std::vector<CGPoint> points;
	std::transform(pts, pts + npts, std::back_inserter(points), CGPointFromPoint);

	CGContextBeginPath(gc);

	SetFillStroke(fillStroke);

	// Draw the polygon
	CGContextAddLines(gc, points.data(), npts);

	// Explicitly close the path, so it is closed for stroking AND filling (implicit close = filling only)
	CGContextClosePath(gc);
	CGContextDrawPath(gc, kCGPathFillStroke);

	// Restore as not all paths set
	CGContextSetLineWidth(gc, 1.0f);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::RectangleDraw(PRectangle rc, FillStroke fillStroke) {
	if (!gc)
		return;
	CGContextBeginPath(gc);
	SetFillStroke(fillStroke);

	CGContextAddRect(gc, CGRectFromPRectangleInset(rc, fillStroke.stroke.width));

	CGContextDrawPath(gc, kCGPathFillStroke);

	// Restore as not all paths set
	CGContextSetLineWidth(gc, 1.0f);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::RectangleFrame(PRectangle rc, Stroke stroke) {
	if (!gc)
		return;

	CGContextBeginPath(gc);
	PenColourAlpha(stroke.colour);
	CGContextSetLineWidth(gc, stroke.width);

	CGContextAddRect(gc, CGRectFromPRectangleInset(rc, stroke.width));

	CGContextDrawPath(gc, kCGPathStroke);

	// Restore as not all paths set
	CGContextSetLineWidth(gc, 1.0f);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillRectangle(PRectangle rc, Fill fill) {
	NPP_PERF_COUNT("PlatCocoa.FillRectangle");	// LOCAL CHANGE: performance probe.
	if (gc) {
		FillColour(fill.colour);
		CGRect rect = PRectangleToCGRect(rc);
		CGContextFillRect(gc, rect);
	}
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillRectangleAligned(PRectangle rc, Fill fill) {
	FillRectangle(PixelAlign(rc, PixelDivisions()), fill);
}

//--------------------------------------------------------------------------------------------------

static void drawImageRefCallback(void *info, CGContextRef gc) {
	CGImageRef pattern = static_cast<CGImageRef>(info);
	CGContextDrawImage(gc, CGRectMake(0, 0, CGImageGetWidth(pattern), CGImageGetHeight(pattern)), pattern);
}

//--------------------------------------------------------------------------------------------------

static void releaseImageRefCallback(void *info) {
	CGImageRelease(static_cast<CGImageRef>(info));
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillRectangle(PRectangle rc, Surface &surfacePattern) {
	SurfaceImpl &patternSurface = static_cast<SurfaceImpl &>(surfacePattern);

	// For now, assume that copy can only be called on PixMap surfaces. Shows up black.
	CGImageRef image = patternSurface.CreateImage();
	if (image == NULL) {
		FillRectangle(rc, ColourRGBA::FromRGB(0));
		return;
	}

	const CGPatternCallbacks drawImageCallbacks = { 0, drawImageRefCallback, releaseImageRefCallback };

	CGPatternRef pattern = CGPatternCreate(image,
					       CGRectMake(0, 0, patternSurface.bitmapWidth, patternSurface.bitmapHeight),
					       CGAffineTransformIdentity,
					       patternSurface.bitmapWidth,
					       patternSurface.bitmapHeight,
					       kCGPatternTilingNoDistortion,
					       true,
					       &drawImageCallbacks
					      );
	if (pattern != NULL) {
		// Create a pattern color space
		CGColorSpaceRef colorSpace = CGColorSpaceCreatePattern(NULL);
		if (colorSpace != NULL) {

			CGContextSaveGState(gc);
			CGContextSetFillColorSpace(gc, colorSpace);

			// Unlike the documentation, you MUST pass in a "components" parameter:
			// For coloured patterns it is the alpha value.
			const CGFloat alpha = 1.0;
			CGContextSetFillPattern(gc, pattern, &alpha);
			CGContextFillRect(gc, PRectangleToCGRect(rc));
			CGContextRestoreGState(gc);
			// Free the color space, the pattern and image
			CGColorSpaceRelease(colorSpace);
		} /* colorSpace != NULL */
		colorSpace = NULL;
		CGPatternRelease(pattern);
		pattern = NULL;
	} /* pattern != NULL */
}

void SurfaceImpl::RoundedRectangle(PRectangle rc, FillStroke fillStroke) {
	// This is only called from the margin marker drawing code for MarkerSymbol::RoundRect
	// The Win32 version does
	//  ::RoundRect(hdc, rc.left + 1, rc.top, rc.right - 1, rc.bottom, 8, 8 );
	// which is a rectangle with rounded corners each having a radius of 4 pixels.
	// It would be almost as good just cutting off the corners with lines at
	// 45 degrees as is done on GTK+.

	// Create a rectangle with semicircles at the corners
	const int MAX_RADIUS = 4;
	const int radius = std::min(MAX_RADIUS, static_cast<int>(std::min(rc.Height()/2, rc.Width()/2)));

	// Points go clockwise, starting from just below the top left
	// Corners are kept together, so we can easily create arcs to connect them
	CGPoint corners[4][3] = {
		{
			{ rc.left, rc.top + radius },
			{ rc.left, rc.top },
			{ rc.left + radius, rc.top },
		},
		{
			{ rc.right - radius - 1, rc.top },
			{ rc.right - 1, rc.top },
			{ rc.right - 1, rc.top + radius },
		},
		{
			{ rc.right - 1, rc.bottom - radius - 1 },
			{ rc.right - 1, rc.bottom - 1 },
			{ rc.right - radius - 1, rc.bottom - 1 },
		},
		{
			{ rc.left + radius, rc.bottom - 1 },
			{ rc.left, rc.bottom - 1 },
			{ rc.left, rc.bottom - radius - 1 },
		},
	};

	// Align the points in the middle of the pixels
	for (int i = 0; i < 4; ++ i) {
		for (int j = 0; j < 3; ++ j) {
			corners[i][j].x += 0.5;
			corners[i][j].y += 0.5;
		}
	}

	SetFillStroke(fillStroke);

	// Move to the last point to begin the path
	CGContextBeginPath(gc);
	CGContextMoveToPoint(gc, corners[3][2].x, corners[3][2].y);

	for (int i = 0; i < 4; ++ i) {
		CGContextAddLineToPoint(gc, corners[i][0].x, corners[i][0].y);
		CGContextAddArcToPoint(gc, corners[i][1].x, corners[i][1].y, corners[i][2].x, corners[i][2].y, radius);
	}

	// Close the path to enclose it for stroking and for filling, then draw it
	CGContextClosePath(gc);
	CGContextDrawPath(gc, kCGPathFillStroke);

	// Restore as not all paths set
	CGContextSetLineWidth(gc, 1.0f);
}

// DrawChamferedRectangle is a helper function for AlphaRectangle that either fills or strokes a
// rectangle with its corners chamfered at 45 degrees.
static void DrawChamferedRectangle(CGContextRef gc, PRectangle rc, int cornerSize, CGPathDrawingMode mode) {
	// Points go clockwise, starting from just below the top left
	CGPoint corners[4][2] = {
		{
			{ rc.left, rc.top + cornerSize },
			{ rc.left + cornerSize, rc.top },
		},
		{
			{ rc.right - cornerSize - 1, rc.top },
			{ rc.right - 1, rc.top + cornerSize },
		},
		{
			{ rc.right - 1, rc.bottom - cornerSize - 1 },
			{ rc.right - cornerSize - 1, rc.bottom - 1 },
		},
		{
			{ rc.left + cornerSize, rc.bottom - 1 },
			{ rc.left, rc.bottom - cornerSize - 1 },
		},
	};

	// Align the points in the middle of the pixels
	for (int i = 0; i < 4; ++ i) {
		for (int j = 0; j < 2; ++ j) {
			corners[i][j].x += 0.5;
			corners[i][j].y += 0.5;
		}
	}

	// Move to the last point to begin the path
	CGContextBeginPath(gc);
	CGContextMoveToPoint(gc, corners[3][1].x, corners[3][1].y);

	for (int i = 0; i < 4; ++ i) {
		CGContextAddLineToPoint(gc, corners[i][0].x, corners[i][0].y);
		CGContextAddLineToPoint(gc, corners[i][1].x, corners[i][1].y);
	}

	// Close the path to enclose it for stroking and for filling, then draw it
	CGContextClosePath(gc);
	CGContextDrawPath(gc, mode);
}

void Scintilla::Internal::SurfaceImpl::AlphaRectangle(PRectangle rc, XYPOSITION cornerSize, FillStroke fillStroke) {
	if (gc) {
		const XYPOSITION halfStroke = fillStroke.stroke.width / 2.0f;
		// Set the Fill color to match
		FillColour(fillStroke.fill.colour);
		PenColourAlpha(fillStroke.stroke.colour);
		PRectangle rcFill = rc;
		if (cornerSize == 0) {
			// A simple rectangle, no rounded corners
			if (fillStroke.fill.colour == fillStroke.stroke.colour) {
				// Optimization for simple case
				CGRect rect = PRectangleToCGRect(rcFill);
				CGContextFillRect(gc, rect);
			} else {
				rcFill.left += fillStroke.stroke.width;
				rcFill.top += fillStroke.stroke.width;
				rcFill.right -= fillStroke.stroke.width;
				rcFill.bottom -= fillStroke.stroke.width;
				CGRect rect = PRectangleToCGRect(rcFill);
				CGContextFillRect(gc, rect);
				CGContextAddRect(gc, CGRectMake(rc.left + halfStroke, rc.top + halfStroke,
								rc.Width() - fillStroke.stroke.width, rc.Height() - fillStroke.stroke.width));
				CGContextStrokeRectWithWidth(gc,
							     CGRectMake(rc.left + halfStroke, rc.top + halfStroke,
									rc.Width() - fillStroke.stroke.width, rc.Height() - fillStroke.stroke.width),
							     fillStroke.stroke.width);
			}
		} else {
			// Approximate rounded corners with 45 degree chamfers.
			// Drawing real circular arcs often leaves some over- or under-drawn pixels.
			if (fillStroke.fill.colour == fillStroke.stroke.colour) {
				// Specializing this case avoids a few stray light/dark pixels in corners.
				rcFill.left -= halfStroke;
				rcFill.top -= halfStroke;
				rcFill.right += halfStroke;
				rcFill.bottom += halfStroke;
				DrawChamferedRectangle(gc, rcFill, cornerSize, kCGPathFill);
			} else {
				rcFill.left += halfStroke;
				rcFill.top += halfStroke;
				rcFill.right -= halfStroke;
				rcFill.bottom -= halfStroke;
				DrawChamferedRectangle(gc, rcFill, cornerSize-fillStroke.stroke.width, kCGPathFill);
				DrawChamferedRectangle(gc, rc, cornerSize, kCGPathStroke);
			}
		}
	}
}

void Scintilla::Internal::SurfaceImpl::GradientRectangle(PRectangle rc, const std::vector<ColourStop> &stops, GradientOptions options) {
	if (!gc) {
		return;
	}

	CGPoint ptStart = CGPointMake(rc.left, rc.top);
	CGPoint ptEnd = CGPointMake(rc.left, rc.bottom);
	if (options == GradientOptions::leftToRight) {
		ptEnd = CGPointMake(rc.right, rc.top);
	}

	std::vector<CGFloat> components;
	std::vector<CGFloat> locations;
	for (const ColourStop &stop : stops) {
		locations.push_back(stop.position);
		components.push_back(stop.colour.GetRedComponent());
		components.push_back(stop.colour.GetGreenComponent());
		components.push_back(stop.colour.GetBlueComponent());
		components.push_back(stop.colour.GetAlphaComponent());
	}

	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	if (!colorSpace) {
		return;
	}

	CGGradientRef gradiantRef = CGGradientCreateWithColorComponents(colorSpace,
									components.data(),
									locations.data(),
									locations.size());
	if (gradiantRef) {
		CGContextSaveGState(gc);
		CGRect rect = PRectangleToCGRect(rc);
		CGContextClipToRect(gc, rect);
		CGContextBeginPath(gc);
		CGContextAddRect(gc, rect);
		CGContextClosePath(gc);
		CGContextDrawLinearGradient(gc, gradiantRef, ptStart, ptEnd, 0);
		CGGradientRelease(gradiantRef);
		CGContextRestoreGState(gc);
	}
	CGColorSpaceRelease(colorSpace);
}

static void ProviderReleaseData(void *, const void *data, size_t) {
	const unsigned char *pixels = static_cast<const unsigned char *>(data);
	delete []pixels;
}

static CGImageRef ImageCreateFromRGBA(int width, int height, const unsigned char *pixelsImage, bool invert) {
	CGImageRef image = 0;

	// Create an RGB color space.
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	if (colorSpace) {
		const int bitmapBytesPerRow = width * 4;
		const int bitmapByteCount = bitmapBytesPerRow * height;

		// Create a data provider.
		CGDataProviderRef dataProvider = 0;
		if (invert) {
			unsigned char *pixelsUpsideDown = new unsigned char[bitmapByteCount];

			for (int y=0; y<height; y++) {
				int yInverse = height - y - 1;
				memcpy(pixelsUpsideDown + y * bitmapBytesPerRow,
				       pixelsImage + yInverse * bitmapBytesPerRow,
				       bitmapBytesPerRow);
			}

			dataProvider = CGDataProviderCreateWithData(
					       NULL, pixelsUpsideDown, bitmapByteCount, ProviderReleaseData);
		} else {
			dataProvider = CGDataProviderCreateWithData(
					       NULL, pixelsImage, bitmapByteCount, NULL);

		}
		if (dataProvider) {
			// Create the CGImage.
			image = CGImageCreate(width,
					      height,
					      8,
					      8 * 4,
					      bitmapBytesPerRow,
					      colorSpace,
					      kCGImageAlphaLast,
					      dataProvider,
					      NULL,
					      0,
					      kCGRenderingIntentDefault);

			CGDataProviderRelease(dataProvider);
		}

		// The image retains the color space, so we can release it.
		CGColorSpaceRelease(colorSpace);
	}
	return image;
}

void SurfaceImpl::DrawRGBAImage(PRectangle rc, int width, int height, const unsigned char *pixelsImage) {
	CGImageRef image = ImageCreateFromRGBA(width, height, pixelsImage, true);
	if (image) {
		CGRect drawRect = CGRectMake(rc.left, rc.top, rc.Width(), rc.Height());
		CGContextDrawImage(gc, drawRect, image);
		CGImageRelease(image);
	}
}

void SurfaceImpl::Ellipse(PRectangle rc, FillStroke fillStroke) {
	const CGRect ellipseRect = CGRectFromPRectangleInset(rc, fillStroke.stroke.width / 2.0f);
	SetFillStroke(fillStroke);
	CGContextBeginPath(gc);
	CGContextAddEllipseInRect(gc, ellipseRect);
	CGContextDrawPath(gc, kCGPathFillStroke);
	// Restore as not all paths set
	CGContextSetLineWidth(gc, 1.0f);
}

void SurfaceImpl::Stadium(PRectangle rc, FillStroke fillStroke, Ends ends) {
	const CGFloat midLine = rc.Centre().y;
	const CGFloat piOn2 = acos(0.0);
	const XYPOSITION halfStroke = fillStroke.stroke.width / 2.0f;
	const float radius = rc.Height() / 2.0f - halfStroke;
	PRectangle rcInner = rc;
	rcInner.left += radius;
	rcInner.right -= radius;

	SetFillStroke(fillStroke);
	CGContextBeginPath(gc);

	const Ends leftSide = static_cast<Ends>(static_cast<int>(ends) & 0xf);
	const Ends rightSide = static_cast<Ends>(static_cast<int>(ends) & 0xf0);
	switch (leftSide) {
		case Ends::leftFlat:
			CGContextMoveToPoint(gc, rc.left + halfStroke, rc.top + halfStroke);
			CGContextAddLineToPoint(gc, rc.left + halfStroke, rc.bottom - halfStroke);
			break;
		case Ends::leftAngle:
			CGContextMoveToPoint(gc, rcInner.left + halfStroke, rc.top + halfStroke);
			CGContextAddLineToPoint(gc, rc.left + halfStroke, rc.Centre().y);
			CGContextAddLineToPoint(gc, rcInner.left + halfStroke, rc.bottom - halfStroke);
			break;
		case Ends::semiCircles:
		default:
			CGContextMoveToPoint(gc, rcInner.left + halfStroke, rc.top + halfStroke);
			CGContextAddArc(gc, rcInner.left + halfStroke, midLine, radius, -piOn2, piOn2, 1);
			break;
	}

	switch (rightSide) {
		case Ends::rightFlat:
			CGContextAddLineToPoint(gc, rc.right - halfStroke, rc.bottom - halfStroke);
			CGContextAddLineToPoint(gc, rc.right - halfStroke, rc.top + halfStroke);
			break;
		case Ends::rightAngle:
			CGContextAddLineToPoint(gc, rcInner.right - halfStroke, rc.bottom - halfStroke);
			CGContextAddLineToPoint(gc, rc.right - halfStroke, rc.Centre().y);
			CGContextAddLineToPoint(gc, rcInner.right - halfStroke, rc.top + halfStroke);
			break;
		case Ends::semiCircles:
		default:
			CGContextAddLineToPoint(gc, rcInner.right - halfStroke, rc.bottom - halfStroke);
			CGContextAddArc(gc, rcInner.right - halfStroke, midLine, radius, piOn2, -piOn2, 1);
			break;
	}

	// Close the path to enclose it for stroking and for filling, then draw it
	CGContextClosePath(gc);
	CGContextDrawPath(gc, kCGPathFillStroke);

	CGContextSetLineWidth(gc, 1.0f);
}

void SurfaceImpl::CopyImageRectangle(SurfaceImpl *source, PRectangle srcRect, PRectangle dstRect) {
	CGImageRef image = source->CreateImage();

	CGRect src = PRectangleToCGRect(srcRect);
	CGRect dst = PRectangleToCGRect(dstRect);

	/* source from QuickDrawToQuartz2D.pdf on developer.apple.com */
	const float w = static_cast<float>(CGImageGetWidth(image));
	const float h = static_cast<float>(CGImageGetHeight(image));
	CGRect drawRect = CGRectMake(0, 0, w, h);
	if (!CGRectEqualToRect(src, dst)) {
		CGFloat sx = CGRectGetWidth(dst) / CGRectGetWidth(src);
		CGFloat sy = CGRectGetHeight(dst) / CGRectGetHeight(src);
		CGFloat dx = CGRectGetMinX(dst) - (CGRectGetMinX(src) * sx);
		CGFloat dy = CGRectGetMinY(dst) - (CGRectGetMinY(src) * sy);
		drawRect = CGRectMake(dx, dy, w*sx, h*sy);
	}
	CGContextSaveGState(gc);
	CGContextClipToRect(gc, dst);
	CGContextDrawImage(gc, drawRect, image);
	CGContextRestoreGState(gc);
	CGImageRelease(image);
}

void SurfaceImpl::Copy(PRectangle rc, Scintilla::Internal::Point from, Surface &surfaceSource) {
	// Maybe we have to make the Surface two contexts:
	// a bitmap context which we do all the drawing on, and then a "real" context
	// which we copy the output to when we call "Synchronize". Ugh! Gross and slow!

	// For now, assume that copy can only be called on PixMap surfaces
	SurfaceImpl &source = static_cast<SurfaceImpl &>(surfaceSource);
	// LOCAL CHANGE: performance probe (pixmap to window copy, buffered drawing).
	NPP_PERF_SCOPE_FINE("PlatCocoa.Copy", "w=%.0f h=%.0f", rc.Width(), rc.Height());

	// Get the CGImageRef
	CGImageRef image = source.CreateImage();
	// If we could not get an image reference, fill the rectangle black
	if (image == NULL) {
		FillRectangle(rc, ColourRGBA::FromRGB(0));
		return;
	}

	// Now draw the image on the surface

	// Some fancy clipping work is required here: draw only inside of rc
	CGContextSaveGState(gc);
	CGContextClipToRect(gc, PRectangleToCGRect(rc));

	//Platform::DebugPrintf(stderr, "Copy: CGContextDrawImage: (%d, %d) - (%d X %d)\n", rc.left - from.x, rc.top - from.y, source.bitmapWidth, source.bitmapHeight );
	CGContextDrawImage(gc, CGRectMake(rc.left - from.x, rc.top - from.y, source.bitmapWidth, source.bitmapHeight), image);

	// Undo the clipping fun
	CGContextRestoreGState(gc);

	// Done with the image
	CGImageRelease(image);
	image = NULL;
}

//--------------------------------------------------------------------------------------------------

// Bidirectional text support for Arabic and Hebrew.

std::unique_ptr<IScreenLineLayout> SurfaceImpl::Layout(const IScreenLine *screenLine) {
	return std::make_unique<ScreenLineLayout>(screenLine);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextNoClip(PRectangle rc, const Font *font_, XYPOSITION ybase, std::string_view text,
				 ColourRGBA fore, ColourRGBA back) {
	FillRectangleAligned(rc, back);
	DrawTextTransparent(rc, font_, ybase, text, fore);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextClipped(PRectangle rc, const Font *font_, XYPOSITION ybase, std::string_view text,
				  ColourRGBA fore, ColourRGBA back) {
	CGContextSaveGState(gc);
	CGContextClipToRect(gc, PRectangleToCGRect(rc));
	DrawTextNoClip(rc, font_, ybase, text, fore, back);
	CGContextRestoreGState(gc);
}

//--------------------------------------------------------------------------------------------------

CFStringEncoding EncodingFromCharacterSet(bool unicode, CharacterSet characterSet) {
	if (unicode)
		return kCFStringEncodingUTF8;

	// Unsupported -> Latin1 as reasonably safe
	enum { notSupported = kCFStringEncodingISOLatin1};

	switch (characterSet) {
	case CharacterSet::Ansi:
		return kCFStringEncodingISOLatin1;
	case CharacterSet::Default:
		return kCFStringEncodingISOLatin1;
	case CharacterSet::Baltic:
		return kCFStringEncodingWindowsBalticRim;
	case CharacterSet::ChineseBig5:
		return kCFStringEncodingBig5;
	case CharacterSet::EastEurope:
		return kCFStringEncodingWindowsLatin2;
	case CharacterSet::GB2312:
		return kCFStringEncodingGB_18030_2000;
	case CharacterSet::Greek:
		return kCFStringEncodingWindowsGreek;
	case CharacterSet::Hangul:
		return kCFStringEncodingEUC_KR;
	case CharacterSet::Mac:
		return kCFStringEncodingMacRoman;
	case CharacterSet::Oem:
		return kCFStringEncodingISOLatin1;
	case CharacterSet::Russian:
		return kCFStringEncodingKOI8_R;
	case CharacterSet::Cyrillic:
		return kCFStringEncodingWindowsCyrillic;
	case CharacterSet::ShiftJis:
		return kCFStringEncodingShiftJIS;
	case CharacterSet::Symbol:
		return kCFStringEncodingMacSymbol;
	case CharacterSet::Turkish:
		return kCFStringEncodingWindowsLatin5;
	case CharacterSet::Johab:
		return kCFStringEncodingWindowsKoreanJohab;
	case CharacterSet::Hebrew:
		return kCFStringEncodingWindowsHebrew;
	case CharacterSet::Arabic:
		return kCFStringEncodingWindowsArabic;
	case CharacterSet::Vietnamese:
		return kCFStringEncodingWindowsVietnamese;
	case CharacterSet::Thai:
		return kCFStringEncodingISOLatinThai;
	case CharacterSet::Iso8859_15:
		return kCFStringEncodingISOLatin1;
	default:
		return notSupported;
	}
}

void SurfaceImpl::DrawTextTransparent(PRectangle rc, const Font *font_, XYPOSITION ybase, std::string_view text,
				      ColourRGBA fore) {
	// LOCAL CHANGE: performance probes (one text run drawn with CoreText).
	NPP_PERF_SCOPE_FINE("PlatCocoa.DrawText", "bytes=%lu", static_cast<unsigned long>(text.length()));
	NPP_PERF_VALUE("PlatCocoa.DrawText.bytes", text.length());
	QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return;
	}
	CFStringEncoding encoding = EncodingFromCharacterSet(UnicodeMode(), style->getCharacterSet());

	CGColorRef color = GenericColour(fore);	// LOCAL CHANGE: cached text colour.
	// LOCAL CHANGE: ASCII fast path (see DrawASCII).
	if (EncodingKeepsASCII(encoding) && DrawASCII(gc, style, text, color, rc.left, ybase)) {
		return;
	}

	style->setCTStyleColour(color);

	QuartzTextLayout layoutDraw(text, encoding, style);
	layoutDraw.draw(gc, rc.left, ybase);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::MeasureWidths(const Font *font_, std::string_view text, XYPOSITION *positions) {
	// LOCAL CHANGE: performance probes (one segment measured with CoreText).
	NPP_PERF_SCOPE_FINE("PlatCocoa.MeasureWidths", "bytes=%lu", static_cast<unsigned long>(text.length()));
	NPP_PERF_VALUE("PlatCocoa.MeasureWidths.bytes", text.length());
	const QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return;
	}
	CFStringEncoding encoding = EncodingFromCharacterSet(UnicodeMode(), style->getCharacterSet());
	// LOCAL CHANGE: ASCII fast path (see MeasureASCII).
	if (EncodingKeepsASCII(encoding) && MeasureASCII(style, text, positions)) {
		return;
	}
	QuartzTextLayout layoutMeasure(text, encoding, style);
	const CFStringEncoding encodingUsed = layoutMeasure.getEncoding();

	CTLineRef mLine = layoutMeasure.getCTLine();
	assert(mLine);

	if (encodingUsed != encoding) {
		// Switched to MacRoman to make work so treat as single byte encoding.
		for (int i=0; i<text.length(); i++) {
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, i+1, nullptr);
			positions[i] = xPosition;
		}
		return;
	}

	if (UnicodeMode()) {
		// Map the widths given for UTF-16 characters back onto the UTF-8 input string
		CFIndex fit = layoutMeasure.getStringLength();
		int ui=0;
		int i=0;
		std::vector<CGFloat> linePositions(fit);
		GetPositions(mLine, linePositions);
		while (ui<fit) {
			const unsigned char uch = text[i];
			const unsigned int byteCount = UTF8BytesOfLead[uch];
			const int codeUnits = UTF16LengthFromUTF8ByteCount(byteCount);
			const CGFloat xPosition = linePositions[ui];
			for (unsigned int bytePos=0; (bytePos<byteCount) && (i<text.length()); bytePos++) {
				positions[i++] = xPosition;
			}
			ui += codeUnits;
		}
		XYPOSITION lastPos = 0.0f;
		if (i > 0)
			lastPos = positions[i-1];
		while (i<text.length()) {
			positions[i++] = lastPos;
		}
	} else if (mode.codePage) {
		int ui = 0;
		for (int i=0; i<text.length();) {
			size_t lenChar = DBCSIsLeadByte(mode.codePage, text[i]) ? 2 : 1;
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, ui+1, NULL);
			for (unsigned int bytePos=0; (bytePos<lenChar) && (i<text.length()); bytePos++) {
				positions[i++] = xPosition;
			}
			ui++;
		}
	} else {	// Single byte encoding
		for (int i=0; i<text.length(); i++) {
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, i+1, NULL);
			positions[i] = xPosition;
		}
	}

}

XYPOSITION SurfaceImpl::WidthText(const Font *font_, std::string_view text) {
	NPP_PERF_SCOPE_FINE("PlatCocoa.WidthText", "bytes=%lu", static_cast<unsigned long>(text.length()));	// LOCAL CHANGE: performance probe.
	const QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return 1;
	}
	CFStringEncoding encoding = EncodingFromCharacterSet(UnicodeMode(), style->getCharacterSet());
	// LOCAL CHANGE: ASCII fast path (see WidthASCII).
	if (EncodingKeepsASCII(encoding)) {
		if (const std::optional<XYPOSITION> width = WidthASCII(style, text)) {
			return *width;
		}
	}
	QuartzTextLayout layoutMeasure(text, encoding, style);

	return static_cast<XYPOSITION>(layoutMeasure.MeasureStringWidth());
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextNoClipUTF8(PRectangle rc, const Font *font_, XYPOSITION ybase, std::string_view text,
				 ColourRGBA fore, ColourRGBA back) {
	FillRectangleAligned(rc, back);
	DrawTextTransparentUTF8(rc, font_, ybase, text, fore);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextClippedUTF8(PRectangle rc, const Font *font_, XYPOSITION ybase, std::string_view text,
				  ColourRGBA fore, ColourRGBA back) {
	CGContextSaveGState(gc);
	CGContextClipToRect(gc, PRectangleToCGRect(rc));
	DrawTextNoClipUTF8(rc, font_, ybase, text, fore, back);
	CGContextRestoreGState(gc);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextTransparentUTF8(PRectangle rc, const Font *font_, XYPOSITION ybase, std::string_view text,
				      ColourRGBA fore) {
	// LOCAL CHANGE: performance probes (one text run drawn with CoreText).
	NPP_PERF_SCOPE_FINE("PlatCocoa.DrawText", "bytes=%lu utf8=1", static_cast<unsigned long>(text.length()));
	NPP_PERF_VALUE("PlatCocoa.DrawText.bytes", text.length());
	QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return;
	}
	const CFStringEncoding encoding = kCFStringEncodingUTF8;

	CGColorRef color = GenericColour(fore);	// LOCAL CHANGE: cached text colour.
	// LOCAL CHANGE: ASCII fast path (see DrawASCII).
	if (DrawASCII(gc, style, text, color, rc.left, ybase)) {
		return;
	}

	style->setCTStyleColour(color);

	QuartzTextLayout layoutDraw(text, encoding, style);
	layoutDraw.draw(gc, rc.left, ybase);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::MeasureWidthsUTF8(const Font *font_, std::string_view text, XYPOSITION *positions) {
	// LOCAL CHANGE: performance probes (one segment measured with CoreText).
	NPP_PERF_SCOPE_FINE("PlatCocoa.MeasureWidths", "bytes=%lu utf8=1", static_cast<unsigned long>(text.length()));
	NPP_PERF_VALUE("PlatCocoa.MeasureWidths.bytes", text.length());
	const QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return;
	}
	constexpr CFStringEncoding encoding = kCFStringEncodingUTF8;
	// LOCAL CHANGE: ASCII fast path (see MeasureASCII).
	if (MeasureASCII(style, text, positions)) {
		return;
	}
	QuartzTextLayout layoutMeasure(text, encoding, style);
	const CFStringEncoding encodingUsed = layoutMeasure.getEncoding();

	CTLineRef mLine = layoutMeasure.getCTLine();
	assert(mLine);

	if (encodingUsed != encoding) {
		// Switched to MacRoman to make work so treat as single byte encoding.
		for (int i=0; i<text.length(); i++) {
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, i+1, nullptr);
			positions[i] = xPosition;
		}
		return;
	}

	// Map the widths given for UTF-16 characters back onto the UTF-8 input string
	CFIndex fit = layoutMeasure.getStringLength();
	int ui=0;
	int i=0;
	std::vector<CGFloat> linePositions(fit);
	GetPositions(mLine, linePositions);
	while (ui<fit) {
		const unsigned char uch = text[i];
		const unsigned int byteCount = UTF8BytesOfLead[uch];
		const int codeUnits = UTF16LengthFromUTF8ByteCount(byteCount);
		const CGFloat xPosition = linePositions[ui];
		for (unsigned int bytePos=0; (bytePos<byteCount) && (i<text.length()); bytePos++) {
			positions[i++] = xPosition;
		}
		ui += codeUnits;
	}
	XYPOSITION lastPos = 0.0f;
	if (i > 0)
		lastPos = positions[i-1];
	while (i<text.length()) {
		positions[i++] = lastPos;
	}
}

XYPOSITION SurfaceImpl::WidthTextUTF8(const Font *font_, std::string_view text) {
	NPP_PERF_SCOPE_FINE("PlatCocoa.WidthText", "bytes=%lu utf8=1", static_cast<unsigned long>(text.length()));	// LOCAL CHANGE: performance probe.
	const QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return 1;
	}
	// LOCAL CHANGE: ASCII fast path (see WidthASCII).
	if (const std::optional<XYPOSITION> width = WidthASCII(style, text)) {
		return *width;
	}
	QuartzTextLayout layoutMeasure(text, kCFStringEncodingUTF8, style);
	return static_cast<XYPOSITION>(layoutMeasure.MeasureStringWidth());
}

//--------------------------------------------------------------------------------------------------


// This string contains a good range of characters to test for size.
const char sizeString[] = "`~!@#$%^&*()-_=+\\|[]{};:\"\'<,>.?/1234567890"
			  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

XYPOSITION SurfaceImpl::Ascent(const Font *font_) {
	const QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return 1;
	}

	float ascent = style->getAscent();
	return ascent + 0.5f;

}

XYPOSITION SurfaceImpl::Descent(const Font *font_) {
	const QuartzTextStyle *style = TextStyleFromFont(font_);
	if (!style) {
		return 1;
	}

	float descent = style->getDescent();
	return descent + 0.5f;

}

XYPOSITION SurfaceImpl::InternalLeading(const Font *) {
	return 0;
}

XYPOSITION SurfaceImpl::Height(const Font *font_) {

	return Ascent(font_) + Descent(font_);
}

XYPOSITION SurfaceImpl::AverageCharWidth(const Font *font_) {

	XYPOSITION width = WidthText(font_, sizeString);

	return std::round(width / strlen(sizeString));
}

void SurfaceImpl::SetClip(PRectangle rc) {
	CGContextSaveGState(gc);
	CGContextClipToRect(gc, PRectangleToCGRect(rc));
}

void SurfaceImpl::PopClip() {
	CGContextRestoreGState(gc);
}

void SurfaceImpl::FlushCachedState() {
	CGContextSynchronize(gc);
}

void SurfaceImpl::FlushDrawing() {
}

std::unique_ptr<Surface> Surface::Allocate(Technology) {
	return std::make_unique<SurfaceImpl>();
}

//----------------- Window -------------------------------------------------------------------------

// Cocoa uses different types for windows and views, so a Window may
// be either an NSWindow or NSView and the code will check the type
// before performing an action.

Window::~Window() noexcept {
}

// Window::Destroy needs to see definition of ListBoxImpl so is located after ListBoxImpl

//--------------------------------------------------------------------------------------------------

static CGFloat ScreenMax() {
	return NSMaxY([NSScreen mainScreen].frame);
}

//--------------------------------------------------------------------------------------------------

PRectangle Window::GetPosition() const {
	if (wid) {
		NSRect rect;
		id idWin = (__bridge id)(wid);
		NSWindow *win;
		if ([idWin isKindOfClass: [NSView class]]) {
			// NSView
			NSView *view = idWin;
			win = view.window;
			rect = [view convertRect: view.bounds toView: nil];
			rect = [win convertRectToScreen: rect];
		} else {
			// NSWindow
			win = idWin;
			rect = win.frame;
		}
		CGFloat screenHeight = ScreenMax();
		// Invert screen positions to match Scintilla
		return PRectangle(
			       NSMinX(rect), screenHeight - NSMaxY(rect),
			       NSMaxX(rect), screenHeight - NSMinY(rect));
	} else {
		return PRectangle(0, 0, 1, 1);
	}
}

//--------------------------------------------------------------------------------------------------

void Window::SetPosition(PRectangle rc) {
	if (wid) {
		id idWin = (__bridge id)(wid);
		if ([idWin isKindOfClass: [NSView class]]) {
			// NSView
			// Moves this view inside the parent view
			NSRect nsrc = NSMakeRect(rc.left, rc.bottom, rc.Width(), rc.Height());
			NSView *view = idWin;
			nsrc = [view.window convertRectFromScreen: nsrc];
			view.frame = nsrc;
		} else {
			// NSWindow
			PLATFORM_ASSERT([idWin isKindOfClass: [NSWindow class]]);
			NSWindow *win = idWin;
			CGFloat screenHeight = ScreenMax();
			NSRect nsrc = NSMakeRect(rc.left, screenHeight - rc.bottom,
						 rc.Width(), rc.Height());
			[win setFrame: nsrc display: YES];
		}
	}
}

//--------------------------------------------------------------------------------------------------

void Window::SetPositionRelative(PRectangle rc, const Window *window) {
	PRectangle rcOther = window->GetPosition();
	rc.left += rcOther.left;
	rc.right += rcOther.left;
	rc.top += rcOther.top;
	rc.bottom += rcOther.top;
	SetPosition(rc);
}

//--------------------------------------------------------------------------------------------------

PRectangle Window::GetClientPosition() const {
	// This means, in macOS terms, get the "frame bounds". Call GetPosition, just like on Win32.
	return GetPosition();
}

//--------------------------------------------------------------------------------------------------

void Window::Show(bool show) {
	if (wid) {
		id idWin = (__bridge id)(wid);
		if ([idWin isKindOfClass: [NSWindow class]]) {
			NSWindow *win = idWin;
			if (show) {
				[win orderFront: nil];
			} else {
				[win orderOut: nil];
			}
		}
	}
}

//--------------------------------------------------------------------------------------------------

/**
 * Invalidates the entire window or view so it is completely redrawn.
 */
void Window::InvalidateAll() {
	NPP_PERF_COUNT("PlatCocoa.InvalidateAll");	// LOCAL CHANGE: performance probe.
	if (wid) {
		id idWin = (__bridge id)(wid);
		NSView *container;
		if ([idWin isKindOfClass: [NSView class]]) {
			container = idWin;
		} else {
			// NSWindow
			NSWindow *win = idWin;
			container = win.contentView;
			container.needsDisplay = YES;
		}
		container.needsDisplay = YES;
	}
}

//--------------------------------------------------------------------------------------------------

/**
 * Invalidates part of the window or view so only this part redrawn.
 */
void Window::InvalidateRectangle(PRectangle rc) {
	// LOCAL CHANGE: performance probes (invalidated height in points).
	NPP_PERF_COUNT("PlatCocoa.InvalidateRectangle");
	NPP_PERF_VALUE("PlatCocoa.InvalidateRectangle.heightPt", rc.Height());
	if (wid) {
		id idWin = (__bridge id)(wid);
		NSView *container;
		if ([idWin isKindOfClass: [NSView class]]) {
			container = idWin;
		} else {
			// NSWindow
			NSWindow *win = idWin;
			container = win.contentView;
		}
		[container setNeedsDisplayInRect: PRectangleToNSRect(rc)];
	}
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts the Scintilla cursor enum into an NSCursor and stores it in the associated NSView,
 * which then will take care to set up a new mouse tracking rectangle.
 */
void Window::SetCursor(Cursor curs) {
	if (wid) {
		id idWin = (__bridge id)(wid);
		if ([idWin isKindOfClass: [SCIContentView class]]) {
			SCIContentView *container = idWin;
			[container setCursor: static_cast<int>(curs)];
		}
	}
}

//--------------------------------------------------------------------------------------------------

PRectangle Window::GetMonitorRect(Point) {
	if (wid) {
		id idWin = (__bridge id)(wid);
		if ([idWin isKindOfClass: [NSView class]]) {
			NSView *view = idWin;
			idWin = view.window;
		}
		if ([idWin isKindOfClass: [NSWindow class]]) {
			PRectangle rcPosition = GetPosition();

			NSWindow *win = idWin;
			NSScreen *screen = win.screen;
			NSRect rect = screen.visibleFrame;
			CGFloat screenHeight = rect.origin.y + rect.size.height;
			// Invert screen positions to match Scintilla
			PRectangle rcWork(
				NSMinX(rect), screenHeight - NSMaxY(rect),
				NSMaxX(rect), screenHeight - NSMinY(rect));
			PRectangle rcMonitor(rcWork.left - rcPosition.left,
					     rcWork.top - rcPosition.top,
					     rcWork.right - rcPosition.left,
					     rcWork.bottom - rcPosition.top);
			return rcMonitor;
		}
	}
	return PRectangle();
}

//----------------- ImageFromXPM -------------------------------------------------------------------

// Convert an XPM image into an NSImage for use with Cocoa

static NSImage *ImageFromXPM(XPM *pxpm) {
	NSImage *img = nil;
	if (pxpm) {
		const int width = pxpm->GetWidth();
		const int height = pxpm->GetHeight();
		PRectangle rcxpm(0, 0, width, height);
		std::unique_ptr<Surface> surfaceBase(Surface::Allocate(Technology::Default));
		std::unique_ptr<Surface> surfaceXPM = surfaceBase->AllocatePixMap(width, height);
		SurfaceImpl *surfaceIXPM = static_cast<SurfaceImpl *>(surfaceXPM.get());
		CGContextClearRect(surfaceIXPM->GetContext(), CGRectMake(0, 0, width, height));
		pxpm->Draw(surfaceXPM.get(), rcxpm);
		CGImageRef imageRef = surfaceIXPM->CreateImage();
		img = [[NSImage alloc] initWithCGImage: imageRef size: NSZeroSize];
		CGImageRelease(imageRef);
	}
	return img;
}

//----------------- ListBox and related classes ----------------------------------------------------

//----------------- IListBox -----------------------------------------------------------------------

namespace {

// Unnamed namespace hides local IListBox interface.
// IListBox is used to cross languages to send events from Objective C++
// AutoCompletionDelegate and AutoCompletionDataSource to C++ ListBoxImpl.

class IListBox {
public:
	virtual int Rows() = 0;
	virtual NSImage *ImageForRow(NSInteger row) = 0;
	virtual NSString *TextForRow(NSInteger row) = 0;
	virtual void DoubleClick() = 0;
	virtual void SelectionChange() = 0;
};

}

//----------------- AutoCompletionDelegate ---------------------------------------------------------

// AutoCompletionDelegate is an Objective C++ class so it can implement
// NSTableViewDelegate and receive tableViewSelectionDidChange events.

@interface AutoCompletionDelegate : NSObject <NSTableViewDelegate> {
	IListBox *box;
}

@property IListBox *box;

@end

@implementation AutoCompletionDelegate

@synthesize box;

- (void) tableViewSelectionDidChange: (NSNotification *) notification {
#pragma unused(notification)
	if (box) {
		box->SelectionChange();
	}
}

@end

//----------------- AutoCompletionDataSource -------------------------------------------------------

// AutoCompletionDataSource provides data to display in the list box.
// It is also the target of the NSTableView so it receives double clicks.

@interface AutoCompletionDataSource : NSObject <NSTableViewDataSource> {
	IListBox *box;
}

@property IListBox *box;

@end

@implementation AutoCompletionDataSource

@synthesize box;

- (void) doubleClick: (id) sender {
#pragma unused(sender)
	if (box) {
		box->DoubleClick();
	}
}

- (id) tableView: (NSTableView *) aTableView objectValueForTableColumn: (NSTableColumn *) aTableColumn row: (NSInteger) rowIndex {
#pragma unused(aTableView)
	if (!box)
		return nil;
	if ([(NSString *)aTableColumn.identifier isEqualToString: @"icon"]) {
		return box->ImageForRow(rowIndex);
	} else {
		return box->TextForRow(rowIndex);
	}
}

- (void) tableView: (NSTableView *) aTableView setObjectValue: anObject forTableColumn: (NSTableColumn *) aTableColumn row: (NSInteger) rowIndex {
#pragma unused(aTableView)
#pragma unused(anObject)
#pragma unused(aTableColumn)
#pragma unused(rowIndex)
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *) aTableView {
#pragma unused(aTableView)
	if (!box)
		return 0;
	return box->Rows();
}

@end

//----------------- ListBoxImpl --------------------------------------------------------------------

namespace {	// unnamed namespace hides ListBoxImpl and associated classes

struct RowData {
	int type;
	std::string text;
	RowData(int type_, const char *text_) :
		type(type_), text(text_) {
	}
};

class LinesData {
	std::vector<RowData> lines;
public:
	LinesData() {
	}
	~LinesData() {
	}
	int Length() const {
		return static_cast<int>(lines.size());
	}
	void Clear() {
		lines.clear();
	}
	void Add(int /* index */, int type, char *str) {
		lines.push_back(RowData(type, str));
	}
	int GetType(size_t index) const {
		if (index < lines.size()) {
			return lines[index].type;
		} else {
			return 0;
		}
	}
	const char *GetString(size_t index) const {
		if (index < lines.size()) {
			return lines[index].text.c_str();
		} else {
			return 0;
		}
	}
};

class ListBoxImpl : public ListBox, IListBox {
private:
	NSMutableDictionary *images;
	int lineHeight;
	bool unicodeMode;
	int desiredVisibleRows;
	XYPOSITION maxItemWidth;
	unsigned int aveCharWidth;
	XYPOSITION maxIconWidth;
	std::unique_ptr<Font> font;
	int maxWidth;

	NSTableView *table;
	NSScrollView *scroller;
	NSTableColumn *colIcon;
	NSTableColumn *colText;
	AutoCompletionDataSource *ds;
	AutoCompletionDelegate *acd;

	LinesData ld;
	IListBoxDelegate *delegate;

public:
	ListBoxImpl() :
		images(nil),
		lineHeight(10),
		unicodeMode(false),
		desiredVisibleRows(5),
		maxItemWidth(0),
		aveCharWidth(8),
		maxIconWidth(0),
		maxWidth(2000),
		table(nil),
		scroller(nil),
		colIcon(nil),
		colText(nil),
		ds(nil),
		acd(nil),
		delegate(nullptr) {
		images = [[NSMutableDictionary alloc] init];
	}
	~ListBoxImpl() override {
	}

	// ListBox methods
	void SetFont(const Font *font_) override;
	void Create(Window &parent, int ctrlID, Scintilla::Internal::Point pt, int lineHeight_, bool unicodeMode_, Technology technology_) override;
	void SetAverageCharWidth(int width) override;
	void SetVisibleRows(int rows) override;
	int GetVisibleRows() const override;
	PRectangle GetDesiredRect() override;
	int CaretFromEdge() override;
	void Clear() noexcept override;
	void Append(char *s, int type = -1) override;
	int Length() override;
	void Select(int n) override;
	int GetSelection() override;
	int Find(const char *prefix) override;
	std::string GetValue(int n) override;
	void RegisterImage(int type, const char *xpm_data) override;
	void RegisterRGBAImage(int type, int width, int height, const unsigned char *pixelsImage) override;
	void ClearRegisteredImages() override;
	void SetDelegate(IListBoxDelegate *lbDelegate) override {
		delegate = lbDelegate;
	}
	void SetList(const char *list, char separator, char typesep) override;
	void SetOptions(ListOptions options_) override;

	// To clean up when closed
	void ReleaseViews();

	// For access from AutoCompletionDataSource implement IListBox
	int Rows() override;
	NSImage *ImageForRow(NSInteger row) override;
	NSString *TextForRow(NSInteger row) override;
	void DoubleClick() override;
	void SelectionChange() override;
};

void ListBoxImpl::Create(Window & /*parent*/, int /*ctrlID*/, Scintilla::Internal::Point pt,
			 int lineHeight_, bool unicodeMode_, Technology) {
	lineHeight = lineHeight_;
	unicodeMode = unicodeMode_;
	maxWidth = 2000;

	NSRect lbRect = NSMakeRect(pt.x, pt.y, 120, lineHeight * desiredVisibleRows);
	NSWindow *winLB = [[NSWindow alloc] initWithContentRect: lbRect
						      styleMask: NSWindowStyleMaskBorderless
							backing: NSBackingStoreBuffered
							  defer: NO];
	[winLB setLevel: NSModalPanelWindowLevel+1];
	[winLB setHasShadow: YES];
	NSRect scRect = NSMakeRect(0, 0, lbRect.size.width, lbRect.size.height);
	scroller = [[NSScrollView alloc] initWithFrame: scRect];
	[scroller setHasVerticalScroller: YES];
	table = [[NSTableView alloc] initWithFrame: scRect];
	[table setHeaderView: nil];
	scroller.documentView = table;
	colIcon = [[NSTableColumn alloc] initWithIdentifier: @"icon"];
	colIcon.width = 20;
	[colIcon setEditable: NO];
	[colIcon setHidden: YES];
	NSImageCell *imCell = [[NSImageCell alloc] init];
	colIcon.dataCell = imCell;
	[table addTableColumn: colIcon];
	colText = [[NSTableColumn alloc] initWithIdentifier: @"name"];
	colText.resizingMask = NSTableColumnAutoresizingMask;
	[colText setEditable: NO];
	[table addTableColumn: colText];
	ds = [[AutoCompletionDataSource alloc] init];
	ds.box = this;
	table.dataSource = ds;	// Weak reference
	acd = [[AutoCompletionDelegate alloc] init];
	[acd setBox: this];
	table.delegate = acd;
	scroller.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[winLB.contentView addSubview: scroller];

	table.target = ds;
	table.doubleAction = @selector(doubleClick:);
	table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;

	if (@available(macOS 11.0, *)) {
		[table setStyle: NSTableViewStylePlain];
	}

	wid = (__bridge_retained WindowID)winLB;
}

void ListBoxImpl::SetFont(const Font *font_) {
	// NSCell setFont takes an NSFont* rather than a CTFontRef but they
	// are the same thing toll-free bridged.
	QuartzTextStyle *style = TextStyleFromFont(font_);
	font = std::make_unique<FontQuartz>(style);
	NSFont *pfont = (__bridge NSFont *)style->getFontRef();
	[colText.dataCell setFont: pfont];
	CGFloat itemHeight = std::ceil(pfont.boundingRectForFont.size.height);
	table.rowHeight = itemHeight;
}

void ListBoxImpl::SetAverageCharWidth(int width) {
	aveCharWidth = width;
}

void ListBoxImpl::SetVisibleRows(int rows) {
	desiredVisibleRows = rows;
}

int ListBoxImpl::GetVisibleRows() const {
	return desiredVisibleRows;
}

PRectangle ListBoxImpl::GetDesiredRect() {
	PRectangle rcDesired;
	rcDesired = GetPosition();

	CGFloat itemHeight;
	if (@available(macOS 11.0, *)) {
		itemHeight = table.rowHeight;
	} else {
		// There appears to be an extra pixel above and below the row contents
		itemHeight = table.rowHeight + 2;
	}

	int rows = Length();
	if ((rows == 0) || (rows > desiredVisibleRows))
		rows = desiredVisibleRows;

	rcDesired.bottom = rcDesired.top + static_cast<XYPOSITION>(itemHeight * rows);
	rcDesired.right = rcDesired.left + maxItemWidth + aveCharWidth;
	rcDesired.right += 4; // Ensures no truncation of text

	if (Length() > rows) {
		[scroller setHasVerticalScroller: YES];
		rcDesired.right += [NSScroller scrollerWidthForControlSize: NSControlSizeRegular
							     scrollerStyle: NSScrollerStyleLegacy];
	} else {
		[scroller setHasVerticalScroller: NO];
	}
	rcDesired.right += maxIconWidth;
	rcDesired.right += 6; // For icon space

	return rcDesired;
}

int ListBoxImpl::CaretFromEdge() {
	if (colIcon.hidden)
		return 3;
	else
		return 6 + static_cast<int>(colIcon.width);
}

void ListBoxImpl::ReleaseViews() {
	[table setDataSource: nil];
	table = nil;
	scroller = nil;
	colIcon = nil;
	colText = nil;
	acd = nil;
	ds = nil;
}

void ListBoxImpl::Clear() noexcept {
	maxItemWidth = 0;
	maxIconWidth = 0;
	ld.Clear();
}

void ListBoxImpl::Append(char *s, int type) {
	int count = Length();
	ld.Add(count, type, s);

	Scintilla::Internal::SurfaceImpl surface;
	XYPOSITION width = surface.WidthText(font.get(), s);
	if (width > maxItemWidth) {
		maxItemWidth = width;
		colText.width = maxItemWidth;
	}
	NSImage *img = images[@(type)];
	if (img) {
		XYPOSITION widthIcon = img.size.width;
		if (widthIcon > maxIconWidth) {
			[colIcon setHidden: NO];
			maxIconWidth = widthIcon;
			colIcon.width = maxIconWidth;
		}
	}
}

void ListBoxImpl::SetList(const char *list, char separator, char typesep) {
	Clear();
	size_t count = strlen(list) + 1;
	std::vector<char> words(list, list+count);
	char *startword = words.data();
	char *numword = nullptr;
	int i = 0;
	for (; words[i]; i++) {
		if (words[i] == separator) {
			words[i] = '\0';
			if (numword)
				*numword = '\0';
			Append(startword, numword?atoi(numword + 1):-1);
			startword = words.data() + i + 1;
			numword = nullptr;
		} else if (words[i] == typesep) {
			numword = words.data() + i;
		}
	}
	if (startword) {
		if (numword)
			*numword = '\0';
		Append(startword, numword?atoi(numword + 1):-1);
	}
	[table reloadData];
}

void ListBoxImpl::SetOptions(ListOptions) {
}

int ListBoxImpl::Length() {
	return ld.Length();
}

void ListBoxImpl::Select(int n) {
	[table selectRowIndexes: [NSIndexSet indexSetWithIndex: n] byExtendingSelection: NO];
	[table scrollRowToVisible: n];
}

int ListBoxImpl::GetSelection() {
	return static_cast<int>(table.selectedRow);
}

int ListBoxImpl::Find(const char *prefix) {
	int count = Length();
	for (int i = 0; i < count; i++) {
		const char *s = ld.GetString(i);
		if (s && (s[0] != '\0') && (0 == strncmp(prefix, s, strlen(prefix)))) {
			return i;
		}
	}
	return - 1;
}

std::string ListBoxImpl::GetValue(int n) {
	const char *textString = ld.GetString(n);
	if (textString) {
		return textString;
	}
	return std::string();
}

void ListBoxImpl::RegisterImage(int type, const char *xpm_data) {
	XPM xpm(xpm_data);
	NSImage *img = ImageFromXPM(&xpm);
	images[@(type)] = img;
}

void ListBoxImpl::RegisterRGBAImage(int type, int width, int height, const unsigned char *pixelsImage) {
	CGImageRef imageRef = ImageCreateFromRGBA(width, height, pixelsImage, false);
	NSImage *img = [[NSImage alloc] initWithCGImage: imageRef size: NSZeroSize];
	CGImageRelease(imageRef);
	images[@(type)] = img;
}

void ListBoxImpl::ClearRegisteredImages() {
	[images removeAllObjects];
}

int ListBoxImpl::Rows() {
	return ld.Length();
}

NSImage *ListBoxImpl::ImageForRow(NSInteger row) {
	return images[@(ld.GetType(row))];
}

NSString *ListBoxImpl::TextForRow(NSInteger row) {
	const char *textString = ld.GetString(row);
	NSString *sTitle;
	if (unicodeMode)
		sTitle = @(textString);
	else
		sTitle = [NSString stringWithCString: textString encoding: NSWindowsCP1252StringEncoding];
	return sTitle;
}

void ListBoxImpl::DoubleClick() {
	if (delegate) {
		ListBoxEvent event(ListBoxEvent::EventType::doubleClick);
		delegate->ListNotify(&event);
	}
}

void ListBoxImpl::SelectionChange() {
	if (delegate) {
		ListBoxEvent event(ListBoxEvent::EventType::selectionChange);
		delegate->ListNotify(&event);
	}
}

} // unnamed namespace

//----------------- ListBox ------------------------------------------------------------------------

// ListBox is implemented by the ListBoxImpl class.

ListBox::ListBox() noexcept {
}

ListBox::~ListBox() noexcept {
}

std::unique_ptr<ListBox> ListBox::Allocate() {
	return std::make_unique<ListBoxImpl>();
}

//--------------------------------------------------------------------------------------------------

void Window::Destroy() noexcept {
	ListBoxImpl *listbox = dynamic_cast<ListBoxImpl *>(this);
	if (listbox) {
		listbox->ReleaseViews();
	}
	if (wid) {
		id idWin = (__bridge id)(wid);
		if ([idWin isKindOfClass: [NSWindow class]]) {
			[idWin close];
		}
	}
	wid = nullptr;
}


//----------------- ScintillaContextMenu -----------------------------------------------------------

@implementation ScintillaContextMenu :
NSMenu

// This NSMenu subclass serves also as target for menu commands and forwards them as
// notification messages to the front end.

- (void) handleCommand: (NSMenuItem *) sender {
	owner->HandleCommand(sender.tag);
}

//--------------------------------------------------------------------------------------------------

- (void) setOwner: (Scintilla::Internal::ScintillaCocoa *) newOwner {
	owner = newOwner;
}

@end

//----------------- Menu ---------------------------------------------------------------------------

Menu::Menu() noexcept
	: mid(0) {
}

//--------------------------------------------------------------------------------------------------

void Menu::CreatePopUp() {
	Destroy();
	mid = (__bridge_retained MenuID)[[ScintillaContextMenu alloc] initWithTitle: @""];
}

//--------------------------------------------------------------------------------------------------

void Menu::Destroy() noexcept {
	CFBridgingRelease(mid);
	mid = nullptr;
}

//--------------------------------------------------------------------------------------------------

void Menu::Show(Point, const Window &) {
	// Cocoa menus are handled a bit differently. We only create the menu. The framework
	// takes care to show it properly.
}

//----------------- Platform -----------------------------------------------------------------------

ColourRGBA Platform::Chrome() {
	return ColourRGBA(0xE0, 0xE0, 0xE0);
}

//--------------------------------------------------------------------------------------------------

ColourRGBA Platform::ChromeHighlight() {
	return ColourRGBA(0xFF, 0xFF, 0xFF);
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the currently set system font for the user.
 */
const char *Platform::DefaultFont() {
	return "Menlo-Regular";
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the currently set system font size for the user.
 */
int Platform::DefaultFontSize() {
	return 11;
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the time span in which two consecutive mouse clicks must occur to be considered as
 * double click.
 *
 * @return time span in milliseconds
 */
unsigned int Platform::DoubleClickTime() {
	NSTimeInterval threshold = NSEvent.doubleClickInterval;
	if (threshold == 0)
		threshold = 0.5;
	return static_cast<unsigned int>(threshold * 1000.0);
}

//--------------------------------------------------------------------------------------------------

//#define TRACE
#ifdef TRACE

void Platform::DebugDisplay(const char *s) noexcept {
	fprintf(stderr, "%s", s);
}

//--------------------------------------------------------------------------------------------------

void Platform::DebugPrintf(const char *format, ...) noexcept {
	const int BUF_SIZE = 2000;
	char buffer[BUF_SIZE];

	va_list pArguments;
	va_start(pArguments, format);
	vsnprintf(buffer, BUF_SIZE, format, pArguments);
	va_end(pArguments);
	Platform::DebugDisplay(buffer);
}

#else

void Platform::DebugDisplay(const char *) noexcept {}

void Platform::DebugPrintf(const char *, ...) noexcept {}

#endif

//--------------------------------------------------------------------------------------------------

static bool assertionPopUps = true;

bool Platform::ShowAssertionPopUps(bool assertionPopUps_) noexcept {
	bool ret = assertionPopUps;
	assertionPopUps = assertionPopUps_;
	return ret;
}

//--------------------------------------------------------------------------------------------------

void Platform::Assert(const char *c, const char *file, int line) noexcept {
	char buffer[2000];
	snprintf(buffer, sizeof(buffer), "Assertion [%s] failed at %s %d\r\n", c, file, line);
	Platform::DebugDisplay(buffer);
#ifdef DEBUG
	// Jump into debugger in assert on Mac
	pthread_kill(pthread_self(), SIGTRAP);
#endif
}

//--------------------------------------------------------------------------------------------------
