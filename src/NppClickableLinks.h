//  NppClickableLinks.h
//  Clickable-link detection for the editor (issue #133).
//
//  -[EditorView updateClickableLinks] marks links on the visible lines, and it
//  may scan a screen in pieces (the lines a scroll step exposes) or all at
//  once (after an edit). Both must mark the same links, so detection here runs
//  one line at a time: a line's links depend only on that line's text.
//
//  This matters for NSDataDetector, which can stop reporting links for the
//  rest of a string after some text. For example, after
//  "https://ελ(http://x.y/z).ληνικά.example/δ" it reported no link at all in a
//  string of several lines that held ordinary links further on. Scanned as one
//  block, such a line would hide every later link in the block, and whether a
//  link was found would depend on where the scanned block began.
//
//  Foundation only; main thread only (the custom-scheme regex is cached in a
//  static).

#import <Foundation/Foundation.h>
#include <stddef.h>

typedef struct {
    size_t lines;         // non-empty lines looked at
    size_t detectedLines; // lines passed to NSDataDetector and the scheme regex
    size_t invalidLines;  // lines that are not valid UTF-8 (skipped)
} NppLinkScanStats;

/// Calls `found` with the byte range, relative to `buf`, of every clickable
/// link in buf[0, len): NSDataDetector links, then matches of the custom
/// schemes in `schemes` (whitespace-separated, for example "svn:// git://").
/// `buf` holds UTF-8 text; lines end in LF, CR or CRLF, and a link never spans
/// a line end. Ranges of one line come in detection order and may overlap.
/// `stats` may be NULL.
void NppFindClickableLinks(const char *buf, size_t len, NSString *schemes,
                           void (^found)(size_t start, size_t length),
                           NppLinkScanStats *stats);
