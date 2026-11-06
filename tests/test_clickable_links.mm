// SPDX-License-Identifier: MIT
//
// Headless tests for clickable-link detection (src/NppClickableLinks.mm).
// Foundation only; no app launch, no files, no defaults.
//
// The editor marks links on the visible lines either in one block (after an
// edit) or in strips (the lines a scroll step exposes), and caches what it has
// marked. Both must give the same result, so the main property checked here
// is that scanning a block of lines finds exactly the links found by scanning
// each line on its own, including after text that makes NSDataDetector stop
// reporting links for the rest of a string.
//
// Run with ctest (see CMakeLists.txt). Exits non-zero on any failure.

#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <utility>
#include <algorithm>
#import "NppClickableLinks.h"

static int g_fail = 0;

static void check(const char *label, bool cond, std::string detail = "") {
    printf("[%s] %s %s\n", cond ? "PASS" : "FAIL", label, detail.c_str());
    if (!cond) g_fail++;
}

typedef std::vector<std::pair<size_t, size_t>> Ranges;  // [start, end) bytes

static Ranges scan(const std::string &text, NSString *schemes, NppLinkScanStats *stats = nullptr) {
    __block Ranges out;
    NppFindClickableLinks(text.data(), text.size(), schemes, ^(size_t start, size_t length) {
        out.push_back({start, start + length});
    }, stats);
    std::sort(out.begin(), out.end());
    return out;
}

static std::vector<std::string> linkTexts(const std::string &text, const Ranges &r) {
    std::vector<std::string> v;
    for (const auto &x : r) v.push_back(text.substr(x.first, x.second - x.first));
    return v;
}

static std::string join(const std::vector<std::string> &v) {
    std::string s;
    for (const auto &x : v) { if (!s.empty()) s += " | "; s += x; }
    return s;
}

// Scans each line of `text` (split after LF, CR or CRLF) on its own and maps
// the results back to offsets in `text`.
static Ranges scanEachLine(const std::string &text, NSString *schemes) {
    Ranges all;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = pos;
        while (end < text.size() && text[end] != '\n' && text[end] != '\r') end++;
        size_t next = end;
        if (next < text.size() && text[next] == '\r') next++;
        if (next < text.size() && text[next] == '\n') next++;
        std::string line = text.substr(pos, next - pos);
        for (const auto &r : scan(line, schemes)) all.push_back({pos + r.first, pos + r.second});
        pos = next;
    }
    std::sort(all.begin(), all.end());
    return all;
}

// The text NSDataDetector stops after (reduced from a generated test file).
static const char *kPoison = "https://\xCE\xB5\xCE\xBB(http://x.y/z).\xCE\xBB\xCE\xB7\xCE\xBD\xCE\xB9\xCE\xBA\xCE\xAC.example/\xCE\xB4";

static void testPoisonDoesNotHideLaterLines() {
    NSString *schemes = @"svn:// git://";
    std::string text = std::string(kPoison) + "\nwww.github.com http://a.com/x\nmailto:x@y.org www.b.org\n";
    Ranges block = scan(text, schemes);
    std::vector<std::string> got = linkTexts(text, block);
    bool hasA = std::find(got.begin(), got.end(), "http://a.com/x") != got.end();
    bool hasB = std::find(got.begin(), got.end(), "www.b.org") != got.end();
    check("poison: links on later lines are found", hasA && hasB && got.size() >= 4, join(got));
    check("poison: block scan equals per-line scan", block == scanEachLine(text, schemes));

    // NSDataDetector itself, over the same text as one string, for the record.
    NSString *s = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    NSDataDetector *d = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    __block NSUInteger whole = 0;
    [d enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length)
                     usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) { whole++; }];
    printf("[INFO] NSDataDetector over the whole string: %lu links (per line: %zu)\n",
           (unsigned long)whole, block.size());
}

// A file of mixed lines, scanned in every split into a block of up to 8 lines
// and in one piece: each line's links must not depend on its neighbours.
static void testBlocksEqualPerLine() {
    NSString *schemes = @"svn:// git://";
    const char *parts[] = {
        "svn://svn.example.org/repo", "example.com", "www.github.com", "mailto:someone@example.org",
        "user@mail.example.net", "file://localhost/tmp/x", "ftp://files.example.com/a.txt",
        "see (http://x.y/z).", "trailing http://t.co/abc,", "1.2345\t6.789\t-0.5", "\t\t\t",
        "plain words here", "\xCE\xB1\xCE\xB2\xCE\xB3 https://\xCE\xB5\xCE\xBB\xCE\xBB\xCE\xB7\xCE\xBD\xCE\xB9\xCE\xBA\xCE\xAC.example/\xCE\xB4",
        "git://host/x.git", kPoison, "http://\xE4\xBE\x8B\xE5\xAD\x90(a).\xE6\xB5\x8B\xE8\xAF\x95",
        "(https://a(http://x.y/z).b.example/c)", "x https://\xCE\xB5\xCE\xBB( y",
    };
    const size_t nParts = sizeof(parts) / sizeof(parts[0]);
    const char *eols[] = {"\n", "\r\n", "\r"};
    std::string text;
    unsigned seed = 12345;
    auto rnd = [&seed](unsigned n) { seed = seed * 1103515245u + 12345u; return (seed >> 16) % n; };
    for (int line = 0; line < 400; line++) {
        unsigned k = 1 + rnd(4);
        for (unsigned i = 0; i < k; i++) {
            if (i) text += ' ';
            text += parts[rnd((unsigned)nParts)];
        }
        text += eols[rnd(3)];
    }
    Ranges ref = scanEachLine(text, schemes);
    check("corpus: whole text equals per-line scan", scan(text, schemes) == ref,
          std::to_string(ref.size()) + " links");

    // Line starts.
    std::vector<size_t> starts{0};
    for (size_t i = 0; i < text.size(); i++) {
        if (text[i] == '\r' && i + 1 < text.size() && text[i + 1] == '\n') continue;
        if (text[i] == '\n' || text[i] == '\r') starts.push_back(i + 1);
    }
    if (starts.back() != text.size()) starts.push_back(text.size());
    bool ok = true;
    std::string where;
    for (size_t a = 0; a + 1 < starts.size() && ok; a++) {
        for (size_t n = 1; n <= 8 && a + n < starts.size() && ok; n++) {
            size_t b0 = starts[a], b1 = starts[a + n];
            Ranges got;
            for (const auto &r : scan(text.substr(b0, b1 - b0), schemes))
                got.push_back({b0 + r.first, b0 + r.second});
            Ranges want;
            for (const auto &r : ref) if (r.first >= b0 && r.second <= b1) want.push_back(r);
            if (got != want) { ok = false; where = "lines " + std::to_string(a) + "+" + std::to_string(n); }
        }
    }
    check("corpus: every block of 1 to 8 lines equals per-line scan", ok, where);

    bool noEol = true;
    for (const auto &r : ref)
        for (size_t i = r.first; i < r.second; i++)
            if (text[i] == '\n' || text[i] == '\r') noEol = false;
    check("corpus: no link covers a line end", noEol);
}

static void testOffsets() {
    NSString *schemes = @"svn://";
    std::string text = "\xCE\xB1\xCE\xB2\xCE\xB3 https://\xCE\xB5\xCE\xBB.example/\xCE\xB4 x\r\n"
                       "svn://host/repo). tail\r"
                       "end http://a.b/c";
    Ranges r = scan(text, schemes);
    std::vector<std::string> got = linkTexts(text, r);
    std::vector<std::string> want = {
        "https://\xCE\xB5\xCE\xBB.example/\xCE\xB4", "svn://host/repo", "http://a.b/c"};
    std::sort(want.begin(), want.end());
    std::sort(got.begin(), got.end());
    got.erase(std::unique(got.begin(), got.end()), got.end());  // detector and scheme regex may both match
    check("offsets: UTF-8 byte ranges, CRLF and CR line ends, scheme trim", got == want, join(got));
}

static void testInvalidUTF8() {
    std::string text = "bad \xFF\xFE http://a.b/c\nhttp://d.e/f\n";
    NppLinkScanStats st = {0, 0, 0};
    Ranges r = scan(text, @"", &st);
    check("invalid UTF-8: only that line is skipped",
          st.invalidLines == 1 && linkTexts(text, r) == std::vector<std::string>{"http://d.e/f"},
          join(linkTexts(text, r)));
}

int main() {
    @autoreleasepool {
        testPoisonDoesNotHideLaterLines();
        testBlocksEqualPerLine();
        testOffsets();
        testInvalidUTF8();
    }
    printf("%s\n", g_fail ? "FAILED" : "ALL PASSED");
    return g_fail ? 1 : 0;
}
