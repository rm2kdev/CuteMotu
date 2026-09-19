#include "AnalysisBridge.h"
#include "AnalysisRing.hpp"
#include "AnalysisTap.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <random>
#include <thread>

namespace {
constexpr double pi = 3.14159265358979323846;
unsigned checks = 0;
void expect(bool value, const char* why) { ++checks; if (!value) { std::fprintf(stderr, "FAIL: %s\n", why); std::exit(1); } }
void near(double actual, double expected, double tolerance, const char* why) {
    if (std::abs(actual - expected) > tolerance || !std::isfinite(actual)) {
        std::fprintf(stderr, "actual %.9f expected %.9f tolerance %.9f\n", actual, expected, tolerance);
        expect(false, why);
    }
    ++checks;
}
struct Fixture {
    void* engine = analysisEngineCreate();
    std::array<float, AnalysisWindow> l{}, r{};
    std::array<float, AnalysisBins> lm{}, rm{}, phase{};
    AnalysisResult result{};
    ~Fixture() { analysisEngineDestroy(engine); }
    void sine(double hz, double rate, double angle = 0, double amplitude = 0.5) {
        for (unsigned i = 0; i < l.size(); ++i) {
            l[i] = float(amplitude * std::sin(2 * pi * hz * i / rate));
            r[i] = float(amplitude * std::sin(2 * pi * hz * i / rate + angle));
        }
    }
    void run(double rate = 48000, bool right = false) {
        analysisProcess(engine, l.data(), r.data(), AnalysisWindow, rate, right, &result, lm.data(), rm.data(), phase.data());
    }
};
}
int main() {
    Fixture f;
    expect(f.engine != nullptr, "FFT setup");
    for (double rate : {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0}) {
        for (double hz : {40.0, 41.2034, 55.0, 82.4069, 130.8128, 220.0, 440.0, 443.0, 880.0, 1318.51, 1500.0}) {
            f.sine(hz, rate); f.run(rate);
            const double cents = 1200 * std::log2(f.result.frequency / hz);
            if (!std::isfinite(cents) || std::abs(cents) > 1) std::fprintf(stderr, "rate %.0f Hz, tone %.4f Hz, found %.4f Hz\n", rate, hz, f.result.frequency);
            near(cents, 0, 1.0, "Pitch error under one cent across supported rates");
            expect(f.result.confidence > 0.85, "Confident periodic pitch");
        }
    }
    // Strong second harmonic must not be mistaken for an octave-up fundamental.
    f.sine(82.4069, 48000);
    for (unsigned i = 0; i < f.l.size(); ++i) f.l[i] = float(0.2 * std::sin(2*pi*82.4069*i/48000) + 0.6 * std::sin(4*pi*82.4069*i/48000));
    f.run(); near(f.result.frequency, 82.4069, 0.1, "Harmonic-rich low E fundamental");
    f.sine(440, 48000);
    for (unsigned i = 0; i < f.r.size(); ++i) f.r[i] = float(0.5 * std::sin(2*pi*220*i/48000));
    f.run(48000, true); near(f.result.frequency, 220, 0.2, "Tuner uses selected right channel");

    constexpr unsigned bin = 160;
    const double frequency = bin * 48000.0 / AnalysisFFT;
    f.sine(frequency, 48000); f.run();
    near(f.lm[bin], -6.0205999, 0.001, "Hann window amplitude normalized");
    near(f.result.rmsLeft, -9.0308999, 0.001, "Sine RMS in dBFS");
    near(f.result.peakLeft, -6.0205999, 0.001, "Sine peak in dBFS");
    near(f.phase[bin], 0, 0.0001, "Identical phase");
    near(f.result.correlation, 1, 0.00001, "Identical correlation");
    f.sine(frequency, 48000, pi); f.run();
    near(std::abs(f.phase[bin]), pi, 0.0001, "Opposite polarity phase");
    near(f.result.correlation, -1, 0.00001, "Opposite polarity correlation");
    f.sine(frequency, 48000, pi / 2); f.run();
    near(f.phase[bin], -pi / 2, 0.0001, "Phase convention left minus right");
    near(f.result.correlation, 0, 0.00001, "Quadrature correlation");
    // Correlation removes a DC offset from both inputs.
    for (auto& x : f.l) x += 0.2f;
    for (auto& x : f.r) x -= 0.3f;
    f.run(); near(f.result.correlation, 0, 0.00001, "DC-independent correlation");
    std::mt19937 rng(830);
    std::uniform_real_distribution<float> noise(-0.4f, 0.4f);
    for (unsigned i = 0; i < f.l.size(); ++i) { f.l[i] = noise(rng); f.r[i] = noise(rng); }
    f.run(); expect(f.result.frequency == 0, "Noise rejects pitch");
    near(f.result.correlation, 0, 0.05, "Uncorrelated noise");
    f.l.fill(0); f.r.fill(0); f.run();
    expect(f.result.frequency == 0 && f.result.correlationValid == 0, "Silence has no pitch or correlation");
    for (float db : f.lm) near(db, -120, 0, "Silent FFT floor");
    f.l.fill(0.4); f.r.fill(-0.2); f.run();
    expect(f.result.frequency == 0 && !f.result.correlationValid, "DC has no pitch or correlation");
    f.l.fill(std::numeric_limits<float>::quiet_NaN()); f.r.fill(std::numeric_limits<float>::infinity()); f.run();
    expect(!f.result.correlationValid && f.result.frequency == 0, "Nonfinite audio sanitized");
    for (float db : f.lm) expect(std::isfinite(db), "Finite display on malformed input");
    analysisProcess(f.engine, f.l.data(), f.r.data(), 0, 48000, 0, &f.result, f.lm.data(), f.rm.data(), f.phase.data());
    expect(f.result.peakLeft == -120 && f.result.frequency == 0, "Incomplete window cleared");

    AnalysisRing<32> ring;
    float interleaved[64], left[32], right[32];
    for (int i = 0; i < 64; ++i) interleaved[i] = float(i);
    ring.push(interleaved, 16, 4, 2, 3);
    expect(ring.read(left, right, 9) == 9, "Partial read");
    for (int i = 0; i < 9; ++i) { near(left[i], i*4+2, 0, "Selected L channel"); near(right[i], i*4+3, 0, "Selected R channel"); }
    ring.push(interleaved, 16, 4, 0, 1); ring.push(interleaved, 16, 4, 0, 1);
    expect(ring.dropped() == 16, "Full ring drops whole block");
    expect(ring.read(left, right, 32) == 23, "No unread data overwritten");
    for (int i = 0; i < 7; ++i) near(left[i], (i+9)*4+2, 0, "Old data preserved");
    ring.push(interleaved, 16, 4, 0, 3);
    expect(ring.read(left, right, 32) == 16, "Ring wraps");
    for (int i = 0; i < 16; ++i) near(right[i], i*4+3, 0, "Wrapped data intact");
    ring.push(interleaved, 1, 4, 4, 0); expect(ring.read(left, right, 32) == 0, "Out of range channel rejected");

    AnalysisTap tap;
    tap.select(0, 1);
    const auto oldSelection = tap.selection();
    tap.push(interleaved, 16, 4, oldSelection);
    expect(tap.read(left, right, 32) == 0, "Initial callback handshake flushes startup");
    tap.push(interleaved, 16, 4, oldSelection);
    expect(tap.read(left, right, 32) == 16, "Initial selected samples delivered");
    tap.select(2, 3);
    tap.push(interleaved, 16, 4, oldSelection); // prior source was already rendering
    expect(tap.read(left, right, 32) == 0, "In-flight old source cannot enter new window");
    tap.push(interleaved, 16, 4, tap.selection());
    expect(tap.read(left, right, 32) == 0, "New-source acknowledgement flushes all queued history");
    tap.push(interleaved, 16, 4, tap.selection());
    expect(tap.read(left, right, 32) == 16, "New source delivers after handoff");
    for (int i = 0; i < 16; ++i) { near(left[i], i*4+2, 0, "New left only"); near(right[i], i*4+3, 0, "New right only"); }

    // Concurrent reader verifies ordering and stereo pairing under overflow.
    AnalysisRing<256> threaded;
    std::atomic<bool> done{false};
    std::thread producer([&] {
        for (int i = 1; i <= 100000; ++i) { float pair[2] = {float(i), float(-i)}; threaded.push(pair, 1, 2, 0, 1); }
        done.store(true, std::memory_order_release);
    });
    float last = 0;
    while (true) {
        const auto n = threaded.read(left, right, 32);
        for (unsigned i = 0; i < n; ++i) { expect(left[i] > last && left[i] == -right[i], "Concurrent samples intact and ordered"); last = left[i]; }
        if (n == 0 && done.load(std::memory_order_acquire)) break;
    }
    producer.join();
    std::printf("Analysis DSP and ring: %u checks passed\n", checks);
}
