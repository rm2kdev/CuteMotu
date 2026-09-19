#pragma once
#include <array>
#include <atomic>
#include <algorithm>
#include <cstdint>

// Single producer (AUHAL), single consumer (worker). Never overwrite data that
// the consumer is copying. If stalled, drop the whole incoming block instead.
template<uint32_t Capacity = 65536> class AnalysisRing {
    struct Pair { float l, r; };
    std::array<Pair, Capacity> samples_{};
    alignas(64) std::atomic<uint64_t> written_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
    std::atomic<uint64_t> dropped_{0};
public:
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    void push(const float* data, uint32_t frames, uint32_t channels, uint32_t l, uint32_t r) {
        if (!data || channels == 0 || l >= channels || r >= channels) return;
        const auto w = written_.load(std::memory_order_relaxed);
        const auto available = Capacity - (w - read_.load(std::memory_order_acquire));
        if (frames > available) { dropped_.fetch_add(frames, std::memory_order_relaxed); return; }
        for (uint32_t i = 0; i < frames; ++i)
            samples_[(w + i) % Capacity] = {data[i * channels + l], data[i * channels + r]};
        written_.store(w + frames, std::memory_order_release);
    }
    uint32_t read(float* l, float* r, uint32_t capacity) {
        const auto begin = read_.load(std::memory_order_relaxed);
        const auto n = uint32_t(std::min<uint64_t>(capacity, written_.load(std::memory_order_acquire) - begin));
        for (uint32_t i = 0; i < n; ++i) { const auto p = samples_[(begin + i) % Capacity]; l[i] = p.l; r[i] = p.r; }
        read_.store(begin + n, std::memory_order_release);
        return n;
    }
    uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }
    void discard() { read_.store(written_.load(std::memory_order_acquire), std::memory_order_release); }
};
