// Aggregator behind NppPerfProbe.h. See that header for the contract.

#include "NppPerfProbe.h"

#include <mach/mach_time.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>

namespace NppPerf {

std::atomic<int> gLevel{0};
std::atomic<PaintHook> gContentPaintHook{nullptr};

namespace {

constexpr int kSubBits = 4;                       // 16 sub-buckets per power of two
constexpr int kSub = 1 << kSubBits;
constexpr int kBuckets = kSub + (64 - kSubBits) * kSub;
constexpr int kMaxStats = 2048;

struct Stat {
	std::string name;
	Kind kind = Kind::Duration;
	std::atomic<uint64_t> count{0};
	std::atomic<uint64_t> sum{0};
	std::atomic<uint64_t> min{UINT64_MAX};
	std::atomic<uint64_t> max{0};
	std::atomic<uint64_t> last{0};
	std::atomic<uint64_t> maxAt{0};
	std::atomic<uint32_t> buckets[kBuckets];
	Stat() {
		for (auto &b : buckets)
			b.store(0, std::memory_order_relaxed);
	}
};

std::mutex gRegistryMutex;
Stat *gStats[kMaxStats];
std::atomic<int> gStatCount{0};

mach_timebase_info_data_t gTimebase{1, 1};
os_log_t gLog = nullptr;
os_log_t gPoiLog = nullptr;
std::once_flag gInitOnce;

void InitOnce() {
	mach_timebase_info(&gTimebase);
	if (gTimebase.denom == 0)
		gTimebase = {1, 1};
	gLog = os_log_create("org.nextpadplusplus.mac", "Performance");
	gPoiLog = os_log_create("org.nextpadplusplus.mac", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
}

inline int BucketFor(uint64_t v) noexcept {
	if (v < static_cast<uint64_t>(kSub))
		return static_cast<int>(v);
	const int e = 63 - __builtin_clzll(v);            // >= kSubBits
	const int sub = static_cast<int>((v >> (e - kSubBits)) & (kSub - 1));
	return kSub + (e - kSubBits) * kSub + sub;
}

// Midpoint of a bucket's value range.
inline uint64_t BucketValue(int b) noexcept {
	if (b < kSub)
		return static_cast<uint64_t>(b);
	const int e = (b - kSub) / kSub + kSubBits;
	const int sub = (b - kSub) % kSub;
	const uint64_t lo = (static_cast<uint64_t>(kSub + sub)) << (e - kSubBits);
	const uint64_t width = 1ULL << (e - kSubBits);
	return lo + width / 2;
}

inline void AtomicMin(std::atomic<uint64_t> &a, uint64_t v) noexcept {
	uint64_t cur = a.load(std::memory_order_relaxed);
	while (v < cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
	}
}

inline bool AtomicMax(std::atomic<uint64_t> &a, uint64_t v) noexcept {
	uint64_t cur = a.load(std::memory_order_relaxed);
	while (v > cur) {
		if (a.compare_exchange_weak(cur, v, std::memory_order_relaxed))
			return true;
	}
	return false;
}

void Record(int id, uint64_t v) noexcept {
	if (id < 0 || id >= gStatCount.load(std::memory_order_acquire))
		return;
	Stat *s = gStats[id];
	s->count.fetch_add(1, std::memory_order_relaxed);
	s->sum.fetch_add(v, std::memory_order_relaxed);
	s->last.store(v, std::memory_order_relaxed);
	AtomicMin(s->min, v);
	if (AtomicMax(s->max, v))
		s->maxAt.store(TicksToNs(Now()), std::memory_order_relaxed);
	s->buckets[BucketFor(v)].fetch_add(1, std::memory_order_relaxed);
}

uint64_t Percentile(const Stat *s, uint64_t total, double q) noexcept {
	if (total == 0)
		return 0;
	uint64_t rank = static_cast<uint64_t>(q * static_cast<double>(total));
	if (rank >= total)
		rank = total - 1;
	uint64_t seen = 0;
	for (int b = 0; b < kBuckets; b++) {
		seen += s->buckets[b].load(std::memory_order_relaxed);
		if (seen > rank) {
			uint64_t v = BucketValue(b);
			const uint64_t mn = s->min.load(std::memory_order_relaxed);
			const uint64_t mx = s->max.load(std::memory_order_relaxed);
			if (v < mn)
				v = mn;
			if (v > mx)
				v = mx;
			return v;
		}
	}
	return s->max.load(std::memory_order_relaxed);
}

int RegisterLocked(const char *name, Kind kind) noexcept {
	const int n = gStatCount.load(std::memory_order_relaxed);
	for (int i = 0; i < n; i++) {
		if (gStats[i]->name == name)
			return i;
	}
	if (n >= kMaxStats)
		return -1;
	Stat *s = new (std::nothrow) Stat();
	if (!s)
		return -1;
	s->name = name;
	s->kind = kind;
	gStats[n] = s;
	gStatCount.store(n + 1, std::memory_order_release);
	return n;
}

void AppendJSONString(std::string &out, const std::string &s) {
	out += '"';
	for (const char c : s) {
		switch (c) {
		case '"': out += "\\\""; break;
		case '\\': out += "\\\\"; break;
		case '\n': out += "\\n"; break;
		default:
			if (static_cast<unsigned char>(c) < 0x20) {
				char buf[8];
				snprintf(buf, sizeof(buf), "\\u%04x", c);
				out += buf;
			} else {
				out += c;
			}
		}
	}
	out += '"';
}

const char *KindName(Kind k) noexcept {
	switch (k) {
	case Kind::Duration: return "duration_ns";
	case Kind::Value: return "value";
	case Kind::Counter: return "counter";
	}
	return "unknown";
}

}

void Init() noexcept {
	std::call_once(gInitOnce, InitOnce);
}

void SetLevel(int level) noexcept {
	Init();
	gLevel.store(level, std::memory_order_relaxed);
}

int Level() noexcept {
	return gLevel.load(std::memory_order_relaxed);
}

os_log_t Log() noexcept {
	Init();
	return gLog;
}

os_log_t PoiLog() noexcept {
	Init();
	return gPoiLog;
}

int Register(const char *name, Kind kind) noexcept {
	Init();
	std::lock_guard<std::mutex> guard(gRegistryMutex);
	return RegisterLocked(name, kind);
}

int RegisterDynamic(const std::string &name, Kind kind) noexcept {
	return Register(name.c_str(), kind);
}

uint64_t Now() noexcept {
	return mach_absolute_time();
}

uint64_t TicksToNs(uint64_t ticks) noexcept {
	return ticks * gTimebase.numer / gTimebase.denom;
}

uint64_t NowNs() noexcept {
	return TicksToNs(Now());
}

void RecordDuration(int id, uint64_t ns) noexcept {
	Record(id, ns);
}

void RecordValue(int id, uint64_t value) noexcept {
	Record(id, value);
}

void AddCounter(int id, int64_t delta) noexcept {
	if (id < 0 || id >= gStatCount.load(std::memory_order_acquire))
		return;
	Stat *s = gStats[id];
	s->count.fetch_add(1, std::memory_order_relaxed);
	s->sum.fetch_add(static_cast<uint64_t>(delta), std::memory_order_relaxed);
	s->last.store(static_cast<uint64_t>(delta), std::memory_order_relaxed);
}

bool Scope::Begin(int id_, int level) noexcept {
	id = id_;
	t0 = Now();
	if (gLevel.load(std::memory_order_relaxed) >= level && os_signpost_enabled(gLog)) {
		spid = os_signpost_id_generate(gLog);
		return true;
	}
	return false;
}

void Scope::End() noexcept {
	const uint64_t t1 = Now();
	Record(id, TicksToNs(t1 - t0));
	if (endFn)
		endFn(spid);
	id = -1;
}

std::vector<StatSnapshot> Snapshot() {
	std::vector<StatSnapshot> out;
	const int n = gStatCount.load(std::memory_order_acquire);
	out.reserve(n);
	for (int i = 0; i < n; i++) {
		const Stat *s = gStats[i];
		const uint64_t count = s->count.load(std::memory_order_relaxed);
		if (count == 0)
			continue;
		StatSnapshot ss;
		ss.name = s->name;
		ss.kind = s->kind;
		ss.count = count;
		ss.sum = s->sum.load(std::memory_order_relaxed);
		ss.last = s->last.load(std::memory_order_relaxed);
		ss.maxAtNs = s->maxAt.load(std::memory_order_relaxed);
		if (s->kind == Kind::Counter) {
			ss.min = ss.max = ss.p50 = ss.p90 = ss.p95 = ss.p99 = 0;
		} else {
			uint64_t total = 0;
			for (int b = 0; b < kBuckets; b++)
				total += s->buckets[b].load(std::memory_order_relaxed);
			ss.min = s->min.load(std::memory_order_relaxed);
			ss.max = s->max.load(std::memory_order_relaxed);
			ss.p50 = Percentile(s, total, 0.50);
			ss.p90 = Percentile(s, total, 0.90);
			ss.p95 = Percentile(s, total, 0.95);
			ss.p99 = Percentile(s, total, 0.99);
		}
		out.push_back(std::move(ss));
	}
	std::sort(out.begin(), out.end(), [](const StatSnapshot &a, const StatSnapshot &b) {
		return a.name < b.name;
	});
	return out;
}

bool SnapshotOne(const char *name, StatSnapshot &out) {
	const int n = gStatCount.load(std::memory_order_acquire);
	for (int i = 0; i < n; i++) {
		const Stat *s = gStats[i];
		if (s->name != name)
			continue;
		const uint64_t count = s->count.load(std::memory_order_relaxed);
		if (count == 0)
			return false;
		uint64_t total = 0;
		for (int b = 0; b < kBuckets; b++)
			total += s->buckets[b].load(std::memory_order_relaxed);
		out.name = s->name;
		out.kind = s->kind;
		out.count = count;
		out.sum = s->sum.load(std::memory_order_relaxed);
		out.last = s->last.load(std::memory_order_relaxed);
		out.min = s->min.load(std::memory_order_relaxed);
		out.max = s->max.load(std::memory_order_relaxed);
		out.maxAtNs = s->maxAt.load(std::memory_order_relaxed);
		out.p50 = Percentile(s, total, 0.50);
		out.p90 = Percentile(s, total, 0.90);
		out.p95 = Percentile(s, total, 0.95);
		out.p99 = Percentile(s, total, 0.99);
		return true;
	}
	return false;
}

void ResetAll() noexcept {
	const int n = gStatCount.load(std::memory_order_acquire);
	for (int i = 0; i < n; i++) {
		Stat *s = gStats[i];
		s->count.store(0, std::memory_order_relaxed);
		s->sum.store(0, std::memory_order_relaxed);
		s->min.store(UINT64_MAX, std::memory_order_relaxed);
		s->max.store(0, std::memory_order_relaxed);
		s->last.store(0, std::memory_order_relaxed);
		s->maxAt.store(0, std::memory_order_relaxed);
		for (auto &b : s->buckets)
			b.store(0, std::memory_order_relaxed);
	}
}

std::string SnapshotJSON() {
	std::string out = "{";
	bool first = true;
	char buf[512];
	for (const StatSnapshot &s : Snapshot()) {
		if (!first)
			out += ",";
		first = false;
		AppendJSONString(out, s.name);
		snprintf(buf, sizeof(buf),
			":{\"kind\":\"%s\",\"count\":%llu,\"sum\":%llu,\"min\":%llu,\"max\":%llu,"
			"\"p50\":%llu,\"p90\":%llu,\"p95\":%llu,\"p99\":%llu,\"last\":%llu}",
			KindName(s.kind),
			static_cast<unsigned long long>(s.count), static_cast<unsigned long long>(s.sum),
			static_cast<unsigned long long>(s.min), static_cast<unsigned long long>(s.max),
			static_cast<unsigned long long>(s.p50), static_cast<unsigned long long>(s.p90),
			static_cast<unsigned long long>(s.p95), static_cast<unsigned long long>(s.p99),
			static_cast<unsigned long long>(s.last));
		out += buf;
	}
	out += "}";
	return out;
}

}
