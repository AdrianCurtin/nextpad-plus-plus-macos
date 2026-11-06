#pragma once

// Performance probes shared by the app, the Scintilla Cocoa layer and the
// Scintilla core (C++ only, no Cocoa). Compiled into scintilla_core so every
// layer reports into one aggregator.
//
// Cost when diagnostics are off: one relaxed atomic load and a predicted
// branch per probe, plus a trivially constructed Scope object. Nothing is
// registered, timed or logged until NppPerf::SetLevel() turns probes on.
//
// Levels (NppPerf::gLevel):
//   0  off (default)
//   1  aggregate every probe (counts, durations, percentiles, counters) and
//      emit os_signpost intervals for the coarse probes (NPP_PERF_SCOPE)
//   2  also emit signposts for the fine-grained probes (NPP_PERF_SCOPE_FINE:
//      per line, per text segment, per CoreText call). Use with Instruments
//      on short traces only; it is a lot of signposts.
//
// Probe macros (each must be on its own source line; the macros declare
// locals named after __LINE__):
//
//   NPP_PERF_SCOPE("Name")                      interval, coarse
//   NPP_PERF_SCOPE("Name", "fmt %d", value)     interval with begin metadata
//   NPP_PERF_SCOPE_FINE("Name", ...)            interval, fine-grained
//   NPP_PERF_COUNT("Name")                      counter += 1
//   NPP_PERF_COUNT_N("Name", n)                 counter += n
//   NPP_PERF_VALUE("Name", v)                   distribution of a value (v >= 0)
//   NPP_PERF_EVENT("Name", "fmt", ...)          signpost event + counter
//   NPP_PERF_POI("Name", "fmt", ...)            Points of Interest event + counter
//
// Names must be string literals (os_signpost requires it). Durations are
// aggregated in nanoseconds; percentiles come from a log-linear histogram
// with 16 sub-buckets per power of two (about 6% resolution).

#include <os/log.h>
#include <os/signpost.h>

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

namespace NppPerf {

extern std::atomic<int> gLevel;

inline bool On() noexcept {
	return __builtin_expect(gLevel.load(std::memory_order_relaxed) != 0, 0);
}

// Must be called (once, early, on the main thread) before raising the level.
void Init() noexcept;
void SetLevel(int level) noexcept;
int Level() noexcept;

os_log_t Log() noexcept;      // subsystem org.nextpadplusplus.mac, category "Performance"
os_log_t PoiLog() noexcept;   // category PointsOfInterest

enum class Kind : int { Duration = 0, Value = 1, Counter = 2 };

// Registration is thread-safe and idempotent by name: two call sites with the
// same name share one aggregate. The returned id is stable for the process.
int Register(const char *name, Kind kind) noexcept;

uint64_t Now() noexcept;                 // mach_absolute_time ticks
uint64_t TicksToNs(uint64_t ticks) noexcept;
uint64_t NowNs() noexcept;               // TicksToNs(Now())

void RecordDuration(int id, uint64_t ns) noexcept;
void RecordValue(int id, uint64_t value) noexcept;
void AddCounter(int id, int64_t delta) noexcept;

// Dynamic-name helpers for call sites whose name is computed (for example
// one aggregate per Scintilla notification code). Slower than the macros
// (name lookup under a lock), so cache the id where possible.
int RegisterDynamic(const std::string &name, Kind kind) noexcept;

struct StatSnapshot {
	std::string name;
	Kind kind;
	uint64_t count;
	uint64_t sum;      // ns for durations, units for values, total for counters
	uint64_t min;
	uint64_t max;
	uint64_t last;
	uint64_t p50;
	uint64_t p90;
	uint64_t p95;
	uint64_t p99;
	uint64_t maxAtNs;  // NowNs() when the max was recorded
};

// Every registered aggregate with a non-zero count, sorted by name.
std::vector<StatSnapshot> Snapshot();
// Zero every aggregate (names and ids are kept).
void ResetAll() noexcept;
// Look up one aggregate by name; returns false when unknown or empty.
bool SnapshotOne(const char *name, StatSnapshot &out);
// The whole snapshot as a JSON object keyed by name.
std::string SnapshotJSON();

// Observer for each SCIContentView paint (time to first frame, HUD).
// Called on the main thread after the paint, only while probes are on, with
// the dirty rectangle and the view's visible rectangle (width and height in
// points).
using PaintHook = void (*)(void *contentView, double rectWidth, double rectHeight,
	double visibleWidth, double visibleHeight, uint64_t startNs, uint64_t endNs);
extern std::atomic<PaintHook> gContentPaintHook;

using EndFn = void (*)(os_signpost_id_t);

// RAII interval. Constructed inert; Begin() arms it.
struct Scope {
	uint64_t t0 = 0;
	EndFn endFn = nullptr;
	os_signpost_id_t spid = OS_SIGNPOST_ID_NULL;
	int id = -1;

	Scope() noexcept = default;
	Scope(const Scope &) = delete;
	Scope &operator=(const Scope &) = delete;
	~Scope() {
		if (__builtin_expect(id >= 0, 0))
			End();
	}
	// Returns true when a signpost should be emitted for this interval.
	bool Begin(int id_, int level) noexcept;
	void End() noexcept;
};

}

#define NPP_PERF_CAT2(a, b) a##b
#define NPP_PERF_CAT(a, b) NPP_PERF_CAT2(a, b)

#define NPP_PERF_SCOPE_AT(level, name, ...) \
	::NppPerf::Scope NPP_PERF_CAT(_nppPerfScope_, __LINE__); \
	if (::NppPerf::On()) { \
		static const int _nppPerfId = ::NppPerf::Register(name, ::NppPerf::Kind::Duration); \
		struct _NppPerfEnd { \
			static void End(os_signpost_id_t s) { os_signpost_interval_end(::NppPerf::Log(), s, name); } \
		}; \
		if (NPP_PERF_CAT(_nppPerfScope_, __LINE__).Begin(_nppPerfId, level)) { \
			NPP_PERF_CAT(_nppPerfScope_, __LINE__).endFn = &_NppPerfEnd::End; \
			os_signpost_interval_begin(::NppPerf::Log(), NPP_PERF_CAT(_nppPerfScope_, __LINE__).spid, name, ##__VA_ARGS__); \
		} \
	}

#define NPP_PERF_SCOPE(name, ...) NPP_PERF_SCOPE_AT(1, name, ##__VA_ARGS__)
#define NPP_PERF_SCOPE_FINE(name, ...) NPP_PERF_SCOPE_AT(2, name, ##__VA_ARGS__)

#define NPP_PERF_COUNT_N(name, n) \
	do { \
		if (::NppPerf::On()) { \
			static const int _nppPerfId = ::NppPerf::Register(name, ::NppPerf::Kind::Counter); \
			::NppPerf::AddCounter(_nppPerfId, static_cast<int64_t>(n)); \
		} \
	} while (0)

#define NPP_PERF_COUNT(name) NPP_PERF_COUNT_N(name, 1)

#define NPP_PERF_VALUE(name, v) \
	do { \
		if (::NppPerf::On()) { \
			static const int _nppPerfId = ::NppPerf::Register(name, ::NppPerf::Kind::Value); \
			const long long _nppPerfV = static_cast<long long>(v); \
			::NppPerf::RecordValue(_nppPerfId, _nppPerfV > 0 ? static_cast<uint64_t>(_nppPerfV) : 0); \
		} \
	} while (0)

#define NPP_PERF_EVENT(name, ...) \
	do { \
		if (::NppPerf::On()) { \
			static const int _nppPerfId = ::NppPerf::Register(name, ::NppPerf::Kind::Counter); \
			::NppPerf::AddCounter(_nppPerfId, 1); \
			os_signpost_event_emit(::NppPerf::Log(), OS_SIGNPOST_ID_EXCLUSIVE, name, ##__VA_ARGS__); \
		} \
	} while (0)

#define NPP_PERF_POI(name, ...) \
	do { \
		if (::NppPerf::On()) { \
			static const int _nppPerfId = ::NppPerf::Register(name, ::NppPerf::Kind::Counter); \
			::NppPerf::AddCounter(_nppPerfId, 1); \
			os_signpost_event_emit(::NppPerf::PoiLog(), OS_SIGNPOST_ID_EXCLUSIVE, name, ##__VA_ARGS__); \
		} \
	} while (0)
