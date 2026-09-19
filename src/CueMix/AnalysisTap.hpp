#pragma once
#include "AnalysisRing.hpp"

// Generation handshake prevents samples from a previous pair entering a new
// analysis window, including a callback already in flight at selection time.
class AnalysisTap {
    AnalysisRing<> ring_;
    std::atomic<uint64_t> selected_{0}, applied_{0};
    uint64_t reading_ = 0; // consumer only
public:
    void select(uint32_t left, uint32_t right) {
        const auto old = selected_.load(std::memory_order_relaxed);
        const auto next = ((old >> 16) + 1) << 16 | (right << 8) | left;
        selected_.store(next, std::memory_order_release);
    }
    uint64_t selection() const { return selected_.load(std::memory_order_acquire); }
    void push(const float* data, uint32_t frames, uint32_t channels, uint64_t selection) {
        ring_.push(data, frames, channels, uint32_t(selection & 255), uint32_t((selection >> 8) & 255));
        applied_.store(selection, std::memory_order_release);
    }
    uint32_t read(float* left, float* right, uint32_t capacity) {
        const auto selected = selection();
        if (applied_.load(std::memory_order_acquire) != selected) { ring_.discard(); return 0; }
        if (reading_ != selected) { ring_.discard(); reading_ = selected; return 0; }
        return ring_.read(left, right, capacity);
    }
    uint64_t dropped() const { return ring_.dropped(); }
};
