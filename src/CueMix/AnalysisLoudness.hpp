#pragma once
#include <cmath>
#include <vector>

namespace cutemix {
inline double loudness(double energy) { return energy > 1e-15 ? -0.691 + 10 * std::log10(energy) : -120; }
// Exact two-pass gating, bounded to 24 hours of 400-ms blocks at 100-ms hops.
// Store energies only, never audio. Capacity exhaustion preserves the completed
// measurement; momentary/short-term continue and the UI asks for a reset.
class LoudnessHistory {
public:
    static constexpr size_t capacity = 24 * 60 * 60 * 10 - 3;
    std::vector<double> blocks;
    size_t seen = 0;
    double absoluteSum = 0;
    LoudnessHistory() { blocks.reserve(capacity); }
    void reset() { blocks.clear(); seen = 0; absoluteSum = 0; }
    bool full() const { return seen >= capacity; }
    void add(double energy) {
        if (full()) return;
        ++seen;
        if (std::isfinite(energy) && loudness(energy) > -70) {
            blocks.push_back(energy); absoluteSum += energy;
        }
    }
    double integrated() const {
        if (blocks.empty()) return -120;
        const double threshold = absoluteSum / double(blocks.size()) * 0.1;
        double sum = 0; size_t count = 0;
        for (double energy : blocks) if (energy > threshold) { sum += energy; ++count; }
        return count ? loudness(sum / double(count)) : -120;
    }
};
}
