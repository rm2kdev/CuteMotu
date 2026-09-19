#include "AnalysisBridge.h"
#include "AnalysisLoudness.hpp"
#include <algorithm>
#include <array>
#include <cmath>

namespace {
double dbPower(double x) { return x > 1e-12 ? 10 * std::log10(x) : -120; }
double clean(float x) { return std::isfinite(x) ? std::clamp(double(x), -4.0, 4.0) : 0; }
struct Biquad {
    double b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    double tick(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y;
        if (std::abs(z1) < 1e-30) z1 = 0;
        if (std::abs(z2) < 1e-30) z2 = 0;
        return y;
    }
};
// Transform the published BS.1770 48-kHz filters through their analogue
// bilinear equivalent. At 48 kHz this returns the exact published coefficients.
Biquad atRate(std::array<double, 3> b, std::array<double, 3> a, double rate) {
    const double p = 1 + rate / 48000, q = 1 - rate / 48000;
    auto transform = [p, q](std::array<double, 3> c) {
        return std::array<double, 3>{c[0]*p*p + c[1]*p*q + c[2]*q*q,
            2*p*q*(c[0]+c[2]) + c[1]*(p*p+q*q), c[0]*q*q + c[1]*p*q + c[2]*p*p};
    };
    const auto num = transform(b), den = transform(a);
    return {num[0]/den[0], num[1]/den[0], num[2]/den[0], den[1]/den[0], den[2]/den[0], 0, 0};
}
struct Block { double left = 0, right = 0, weighted = 0; };
struct Meter {
    double rate = 0;
    uint64_t frames = 0;
    uint32_t hop = 0, inBlock = 0;
    size_t next = 0, filled = 0;
    Block accumulating;
    std::array<Block, 30> recent{};
    std::array<Biquad, 2> shelf{}, highpass{};
    cutemix::LoudnessHistory history;
    AnalysisMeterResult result{};
    void reset(double sr) {
        rate = std::isfinite(sr) && sr >= 8000 && sr <= 192000 ? sr : 0;
        frames = 0; hop = uint32_t(std::llround(rate / 10)); inBlock = 0;
        next = filled = 0; accumulating = {}; recent = {}; history.reset(); result = {};
        result.peakLeft = result.peakRight = result.maxLeft = result.maxRight = -120;
        result.rmsLeft = result.rmsRight = result.momentary = result.shortTerm = result.integrated = -120;
        if (!rate) return;
        for (int ch = 0; ch < 2; ++ch) {
            shelf[ch] = atRate({1.53512485958697, -2.69169618940638, 1.19839281085285}, {1, -1.69065929318241, 0.73248077421585}, rate);
            highpass[ch] = atRate({1, -2, 1}, {1, -1.99004745483398, 0.99007225036621}, rate);
        }
    }
    void finishBlock() {
        recent[next] = {accumulating.left/hop, accumulating.right/hop, accumulating.weighted/hop};
        next = (next+1) % recent.size(); filled = std::min(recent.size(), filled+1);
        accumulating = {}; inBlock = 0;
        if (filled >= 4) {
            Block sum;
            for (size_t i = 0; i < 4; ++i) {
                const auto& b = recent[(next + recent.size() - 1 - i) % recent.size()];
                sum.left += b.left; sum.right += b.right; sum.weighted += b.weighted;
            }
            result.rmsLeft = dbPower(sum.left/4); result.rmsRight = dbPower(sum.right/4);
            result.momentary = cutemix::loudness(sum.weighted/4); result.momentaryReady = 1;
            history.add(sum.weighted/4);
        }
        if (filled == recent.size()) {
            double energy = 0; for (const auto& b : recent) energy += b.weighted;
            result.shortTerm = cutemix::loudness(energy/30); result.shortTermReady = 1;
        }
    }
    void push(const float* left, const float* right, uint32_t count) {
        if (!rate || !left || !right || !count) return;
        double peakL = 0, peakR = 0;
        bool finished = false;
        for (uint32_t i = 0; i < count; ++i) {
            const double l = clean(left[i]), r = clean(right[i]);
            peakL = std::max(peakL, std::abs(l)); peakR = std::max(peakR, std::abs(r));
            if (std::abs(l) >= 1) result.clippedLeft = 1;
            if (std::abs(r) >= 1) result.clippedRight = 1;
            const double kl = highpass[0].tick(shelf[0].tick(l)), kr = highpass[1].tick(shelf[1].tick(r));
            accumulating.left += l*l; accumulating.right += r*r; accumulating.weighted += kl*kl + kr*kr;
            ++frames;
            if (++inBlock == hop) { finishBlock(); finished = true; }
        }
        result.peakLeft = dbPower(peakL*peakL); result.peakRight = dbPower(peakR*peakR);
        result.maxLeft = std::max(result.maxLeft, result.peakLeft); result.maxRight = std::max(result.maxRight, result.peakRight);
        result.seconds = double(frames) / rate;
        if (finished) result.integrated = history.integrated();
        result.integratedFull = history.full() ? 1 : 0;
    }
};
}
void* analysisMeterCreate() { auto* m = new Meter; m->reset(0); return m; }
void analysisMeterDestroy(void* meter) { delete static_cast<Meter*>(meter); }
void analysisMeterReset(void* meter, double rate) { if (meter) static_cast<Meter*>(meter)->reset(rate); }
void analysisMeterPush(void* meter, const float* left, const float* right, uint32_t count) { if (meter) static_cast<Meter*>(meter)->push(left, right, count); }
void analysisMeterRead(void* meter, AnalysisMeterResult* result) { if (meter && result) *result = static_cast<Meter*>(meter)->result; }
