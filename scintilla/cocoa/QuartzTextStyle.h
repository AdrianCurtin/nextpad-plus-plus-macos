/*
 *  QuartzTextStyle.h
 *
 *  Created by Evan Jones on Wed Oct 02 2002.
 *
 */

#ifndef QUARTZTEXTSTYLE_H
#define QUARTZTEXTSTYLE_H

#include "QuartzTextStyleAttribute.h"

// LOCAL CHANGE: glyph and advance table for printable ASCII (0x20 to 0x7E).
// PlatCocoa.mm builds one per distinct font, only when CoreText lays out such
// text as exactly one glyph per character at the glyph's nominal advance (no
// kerning, ligatures, contextual forms or font fallback), and then draws and
// measures ASCII runs from it without creating a CTLine for each run.
struct QuartzASCIIMetrics {
	static constexpr unsigned char first = 0x20;
	static constexpr unsigned char last = 0x7E;
	static constexpr size_t count = last - first + 1;
	CGGlyph glyphs[count] {};
	CGFloat advances[count] {};
};

class QuartzTextStyle {
public:
	QuartzTextStyle() {
		fontRef = NULL;
		styleDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
						      &kCFTypeDictionaryKeyCallBacks,
						      &kCFTypeDictionaryValueCallBacks);

		characterSet = Scintilla::CharacterSet::Ansi;
	}

	QuartzTextStyle(const QuartzTextStyle *other) {
		// Does not copy font colour attribute
		fontRef = static_cast<CTFontRef>(CFRetain(other->fontRef));
		styleDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
						      &kCFTypeDictionaryKeyCallBacks,
						      &kCFTypeDictionaryValueCallBacks);
		CFDictionaryAddValue(styleDict, kCTFontAttributeName, fontRef);
		characterSet = other->characterSet;
		asciiMetrics = other->asciiMetrics;	// LOCAL CHANGE: ASCII fast path.
	}

	~QuartzTextStyle() {
		if (styleDict != NULL) {
			CFRelease(styleDict);
			styleDict = NULL;
		}

		if (fontRef) {
			CFRelease(fontRef);
			fontRef = NULL;
		}
	}

	CFMutableDictionaryRef getCTStyle() const {
		return styleDict;
	}

	void setCTStyleColour(CGColor *inColour) {
		CFDictionarySetValue(styleDict, kCTForegroundColorAttributeName, inColour);
	}

	float getAscent() const {
		return static_cast<float>(::CTFontGetAscent(fontRef));
	}

	float getDescent() const {
		return static_cast<float>(::CTFontGetDescent(fontRef));
	}

	float getLeading() const {
		return static_cast<float>(::CTFontGetLeading(fontRef));
	}

	void setFontRef(CTFontRef inRef, Scintilla::CharacterSet characterSet_) {
		fontRef = inRef;
		characterSet = characterSet_;

		if (styleDict != NULL)
			CFRelease(styleDict);

		styleDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
						      &kCFTypeDictionaryKeyCallBacks,
						      &kCFTypeDictionaryValueCallBacks);

		CFDictionaryAddValue(styleDict, kCTFontAttributeName, fontRef);
	}

	CTFontRef getFontRef() const noexcept {
		return fontRef;
	}

	Scintilla::CharacterSet getCharacterSet() const noexcept {
		return characterSet;
	}

	// LOCAL CHANGE: ASCII fast path. The table is shared between styles with an
	// equal font and lives for the rest of the process; nullptr when the font
	// does not qualify.
	const QuartzASCIIMetrics *getASCIIMetrics() const noexcept {
		return asciiMetrics;
	}

	void setASCIIMetrics(const QuartzASCIIMetrics *metrics) noexcept {
		asciiMetrics = metrics;
	}

private:
	CFMutableDictionaryRef styleDict;
	CTFontRef fontRef;
	Scintilla::CharacterSet characterSet;
	const QuartzASCIIMetrics *asciiMetrics = nullptr;	// LOCAL CHANGE: ASCII fast path.
};

#endif

