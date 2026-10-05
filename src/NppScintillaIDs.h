#pragma once

// Scintilla marker and indicator numbers used by the host, plus the ranges
// handed out to plugins via NPPM_ALLOCATEMARKER / NPPM_ALLOCATEINDICATOR.
// Keep every host-owned number here so the plugin ranges can be checked
// against them at compile time (see the static_asserts at the bottom).
//
// Marker map (0-31, Scintilla MARKER_MAX = 31):
//    0         unused
//    1-14      plugins (NPPM_ALLOCATEMARKER), same range as Windows NPP
//   15-17      git gutter: added / modified / deleted
//   18-19      hide-lines end / begin arrows
//   20         bookmark (NPPM_GETBOOKMARKID)
//   21-24      Scintilla change history (SC_MARKNUM_HISTORY_*)
//   25-31      Scintilla fold markers (SC_MARKNUM_FOLDER*)
//
// Indicator map (0-43, Scintilla INDICATOR_MAX = 43):
//    0-7       reserved for lexers (INDICATOR_CONTAINER = 8)
//    8         smart highlight
//    9-13      mark styles 1-5
//   14-16      unused
//   17         spell check
//   18         git diff line highlight
//   19         clickable links
//   20-27      plugins (NPPM_ALLOCATEINDICATOR)
//   28         incremental search
//   29-30      unused
//   31         Find "Mark" results
//   32-43      Scintilla IME and change history (INDICATOR_IME..INDICATOR_MAX)
//
// Windows NPP gives plugins indicators 9-19 because its own indicators sit
// at 8 and 21-31. The macOS host already uses 9-13 and 17-19, so plugins get
// the free contiguous block 20-27 instead. Plugins must not assume fixed
// numbers; they get theirs from the allocator.

// ── Host markers ──────────────────────────────────────────────────────────
static const int kGitMarkerAdded        = 15;
static const int kGitMarkerModified     = 16;
static const int kGitMarkerDeleted      = 17;
static const int kHideLinesEndMarker    = 18; // green ◀ arrow on line AFTER hidden range
static const int kHideLinesBeginMarker  = 19; // green ▶ arrow on line BEFORE hidden range
static const int kBookmarkMarker        = 20;

// ── Host indicators ───────────────────────────────────────────────────────
static const int kHighlightIndicator     =  8; // INDICATOR_CONTAINER, avoids lexer indicators 0-7
static const int kMarkIndicatorFirst     =  9; // mark styles 1-5 use 9-13
static const int kMarkIndicatorCount     =  5;
static const int kSpellIndicator         = 17;
static const int kGitDiffIndicator       = 18;
static const int kClickableLinkIndicator = 19;
static const int kIndicatorIncSearch     = 28;
static const int kFindMarkIndicator      = 31;

// ── Plugin ranges: [first, limit) ─────────────────────────────────────────
static const int kPluginMarkerFirst     =  1;
static const int kPluginMarkerLimit     = 15;
static const int kPluginIndicatorFirst  = 20;
static const int kPluginIndicatorLimit  = 28;

// Plugin command IDs. FuncItem _cmdIDs are assigned from the first range at
// load time; NPPM_ALLOCATECMDID hands out the second. Same values as Windows
// NPP (ID_PLUGINS_CMD, ID_PLUGINS_CMD_DYNAMIC). The first range is capped
// below the second so they can never overlap.
static const int kPluginCmdIDFirst        = 22000;
static const int kPluginCmdIDLimit        = 23000;
static const int kPluginDynamicCmdIDFirst = 23000;
static const int kPluginDynamicCmdIDLimit = 25000;

#ifdef __cplusplus
namespace NppScintillaIDsDetail {
constexpr bool outside(int id, int first, int limit) { return id < first || id >= limit; }
}
static_assert(NppScintillaIDsDetail::outside(kGitMarkerAdded,       kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kGitMarkerModified,    kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kGitMarkerDeleted,     kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kHideLinesEndMarker,   kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kHideLinesBeginMarker, kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kBookmarkMarker,       kPluginMarkerFirst, kPluginMarkerLimit),
              "host marker inside the plugin marker range");
static_assert(kPluginMarkerLimit <= 21, "plugin markers overlap Scintilla change-history markers (21-24)");
static_assert(NppScintillaIDsDetail::outside(kHighlightIndicator,     kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              kMarkIndicatorFirst + kMarkIndicatorCount <= kPluginIndicatorFirst &&
              NppScintillaIDsDetail::outside(kSpellIndicator,         kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kGitDiffIndicator,       kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kClickableLinkIndicator, kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kIndicatorIncSearch,     kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kFindMarkIndicator,      kPluginIndicatorFirst, kPluginIndicatorLimit),
              "host indicator inside the plugin indicator range");
static_assert(kPluginIndicatorFirst >= 8 && kPluginIndicatorLimit <= 32,
              "plugin indicators overlap lexer (0-7) or IME/history (32+) indicators");
static_assert(kPluginCmdIDLimit <= kPluginDynamicCmdIDFirst, "plugin cmdID ranges overlap");
#endif
