//  NppClickableLinks.mm
//  Clickable-link detection for the editor. See NppClickableLinks.h.

#import "NppClickableLinks.h"

// Compiles a regex matching any of the user's custom URI schemes followed by a
// run of URL characters. Cached on the schemes string (a global pref) so it is
// not recompiled on every scroll.
static NSRegularExpression *nppClickableSchemeRegex(NSString *schemes) {
    static NSString *cachedSrc = nil;
    static NSRegularExpression *cachedRegex = nil;
    if (cachedSrc && [schemes isEqualToString:cachedSrc]) return cachedRegex;
    cachedSrc = [schemes copy];
    cachedRegex = nil;
    NSArray *tokens = [schemes componentsSeparatedByCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *escaped = [NSMutableArray array];
    for (NSString *t in tokens)
        if (t.length) [escaped addObject:[NSRegularExpression escapedPatternForString:t]];
    if (escaped.count) {
        // Scheme alternation followed by one+ non-space, non-markup chars.
        NSString *pattern = [NSString stringWithFormat:@"(?:%@)[^\\s<>\"'`]+",
                             [escaped componentsJoinedByString:@"|"]];
        cachedRegex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                               options:NSRegularExpressionCaseInsensitive
                                                                 error:nil];
    }
    return cachedRegex;
}

// UTF-8 length of the UTF-16 range [0, location) of `s`.
static size_t nppUTF8Offset(NSString *s, NSUInteger location) {
    if (location == 0) return 0;
    CFIndex used = 0;
    CFStringGetBytes((__bridge CFStringRef)s, CFRangeMake(0, (CFIndex)location),
                     kCFStringEncodingUTF8, 0, false, NULL, 0, &used);
    return (size_t)used;
}

void NppFindClickableLinks(const char *buf, size_t len, NSString *schemes,
                           void (^found)(size_t start, size_t length),
                           NppLinkScanStats *stats) {
    NppLinkScanStats local = {0, 0, 0};
    NppLinkScanStats *st = stats ? stats : &local;

    static NSDataDetector *detector = nil;
    static NSCharacterSet *trailTrim = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Standard web and mail links (http, https, ftp, mailto, bare www, ...).
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
        trailTrim = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?)]}>'\""];
    });
    // Custom URI schemes from prefs (svn://, git://, ...) the detector misses.
    NSRegularExpression *schemeRegex = nppClickableSchemeRegex(schemes);

    size_t pos = 0;
    while (pos < len) {
        size_t end = pos;
        bool ascii = true;
        while (end < len && buf[end] != '\n' && buf[end] != '\r') {
            if ((unsigned char)buf[end] & 0x80) ascii = false;
            end++;
        }
        const size_t lineStart = pos, lineLen = end - pos;
        // Next line: skip one LF, CR or CRLF.
        pos = end;
        if (pos < len && buf[pos] == '\r') pos++;
        if (pos < len && buf[pos] == '\n') pos++;
        if (lineLen == 0) continue;
        st->lines++;

        const char *line = buf + lineStart;
        @autoreleasepool {
            NSString *text = [[NSString alloc] initWithBytes:line length:lineLen
                                                    encoding:NSUTF8StringEncoding];
            if (!text.length) { st->invalidLines++; continue; }
            st->detectedLines++;
            const NSRange whole = NSMakeRange(0, text.length);
            void (^report)(NSRange) = ^(NSRange r) {
                if (r.length == 0) return;
                if (ascii) {
                    found(lineStart + r.location, r.length);
                } else {
                    const size_t b0 = nppUTF8Offset(text, r.location);
                    const size_t b1 = nppUTF8Offset(text, NSMaxRange(r));
                    if (b1 > b0) found(lineStart + b0, b1 - b0);
                }
            };
            [detector enumerateMatchesInString:text options:0 range:whole
                                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
                if (m.resultType == NSTextCheckingTypeLink && m.URL) report(m.range);
            }];
            if (schemeRegex) {
                [schemeRegex enumerateMatchesInString:text options:0 range:whole
                                           usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
                    NSRange r = m.range;
                    // Trim trailing sentence/markup punctuation that isn't part of the URL.
                    while (r.length > 0 &&
                           [trailTrim characterIsMember:[text characterAtIndex:NSMaxRange(r) - 1]])
                        r.length--;
                    report(r);
                }];
            }
        }
    }
}
