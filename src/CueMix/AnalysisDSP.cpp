#include "AnalysisBridge.h"
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <vector>

namespace {
constexpr double pi = 3.14159265358979323846;
double db(double amplitude) { return std::max(-120.0, 20 * std::log10(std::max(1e-6, amplitude))); }
float clean(float x) { return std::isfinite(x) ? std::clamp(x, -4.0f, 4.0f) : 0.0f; }
struct Engine {
    FFTSetup fft = vDSP_create_fftsetup(13, kFFTRadix2);
    std::array<float, AnalysisFFT> window{}, real[2]{}, imag[2]{};
    std::array<float, AnalysisWindow> mono{};
    double windowSum = 0;
    Engine() {
        for (int i = 0; i < AnalysisFFT; ++i) {
            window[i] = float(0.5 - 0.5 * std::cos(2 * pi * i / AnalysisFFT));
            windowSum += window[i];
        }
    }
    ~Engine() { if (fft) vDSP_destroy_fftsetup(fft); }
    void pitch(const float* input, uint32_t count, double rate, AnalysisResult& result) {
        // Average/downsample to ~12 kHz; YIN's cumulative normalized difference
        // rejects aperiodic input and chooses the first reliable period.
        const unsigned stride = std::max(1u, unsigned(rate / 12000));
        const unsigned n = count / stride;
        const double sr = rate / stride;
        for (unsigned i = 0; i < n; ++i) {
            double v = 0;
            for (unsigned j = 0; j < stride; ++j) v += clean(input[i * stride + j]);
            mono[i] = float(v / stride);
        }
        const unsigned length = n / 2;
        const unsigned maxLag = std::min(length - 1, unsigned(std::ceil(sr / 40)) + 2);
        const unsigned minLag = std::max(2u, unsigned(sr / 1500));
        double mean = 0, energy = 0;
        for (unsigned i = 0; i < n; ++i) mean += mono[i];
        mean /= n;
        for (unsigned i = 0; i < n; ++i) { mono[i] -= float(mean); energy += mono[i] * mono[i]; }
        if (energy / n < 1e-6) return; // -60 dBFS RMS, reject DC/silence.
        std::vector<double> cmnd(maxLag + 1, 1);
        double sum = 0;
        unsigned best = 0;
        for (unsigned lag = 1; lag <= maxLag; ++lag) {
            double diff = 0;
            for (unsigned i = 0; i < length; ++i) { const double delta = mono[i] - mono[i + lag]; diff += delta * delta; }
            sum += diff;
            cmnd[lag] = sum > 1e-12 ? diff * lag / sum : 1;
            if (lag > minLag && cmnd[lag - 1] < 0.15 && cmnd[lag] >= cmnd[lag - 1]) { best = lag - 1; break; }
        }
        if (!best || best >= maxLag) return;
        // Refine at the original rate. Interpolating only the downsampled YIN
        // curve biases upper-register notes by several cents.
        const unsigned center = best * stride;
        const unsigned first = std::max(2u, center - stride - 1);
        const unsigned last = std::min(count / 2 - 1, center + stride + 1);
        std::vector<double> fine(last - first + 1);
        unsigned minimum = 0;
        for (unsigned lag = first; lag <= last; ++lag) {
            double diff = 0;
            for (unsigned i = 0; i < count / 2; ++i) {
                const double delta = clean(input[i]) - clean(input[i + lag]); diff += delta * delta;
            }
            fine[lag - first] = diff;
            if (diff < fine[minimum]) minimum = lag - first;
        }
        if (minimum == 0 || minimum + 1 == fine.size()) return;
        const double a = fine[minimum - 1], b = fine[minimum], c = fine[minimum + 1];
        const double denom = a - 2*b + c;
        const double delta = std::abs(denom) > 1e-12 ? std::clamp(0.5 * (a - c) / denom, -0.5, 0.5) : 0;
        const double f = rate / (first + minimum + delta);
        if (f >= 39.9 && f <= 1501) { result.frequency = f; result.confidence = std::clamp(1 - cmnd[best], 0.0, 1.0); }
    }
};
}
void* analysisEngineCreate() { auto e = std::make_unique<Engine>(); return e->fft ? e.release() : nullptr; }
void analysisEngineDestroy(void* engine) { delete static_cast<Engine*>(engine); }
void analysisProcess(void* engine, const float* left, const float* right, uint32_t count,
                     double rate, uint32_t tunerRight, AnalysisResult* output,
                     float* spectrumLeft, float* spectrumRight, float* phase) {
    if (!output || !spectrumLeft || !spectrumRight || !phase) return;
    *output = {};
    output->rmsLeft = output->rmsRight = output->peakLeft = output->peakRight = -120;
    std::fill_n(spectrumLeft, AnalysisBins, -120.0f);
    std::fill_n(spectrumRight, AnalysisBins, -120.0f);
    std::fill_n(phase, AnalysisBins, 0.0f);
    if (!engine || !left || !right || count < AnalysisWindow || count > AnalysisWindow || !std::isfinite(rate) || rate < 32000 || rate > 192000) return;
    auto& e = *static_cast<Engine*>(engine);
    double ll = 0, rr = 0, lr = 0, sumL = 0, sumR = 0, peakL = 0, peakR = 0;
    const unsigned start = count - AnalysisFFT;
    for (unsigned i = 0; i < AnalysisFFT; ++i) {
        const double l = clean(left[start + i]), r = clean(right[start + i]);
        ll += l*l; rr += r*r; lr += l*r; sumL += l; sumR += r;
        peakL = std::max(peakL, std::abs(l)); peakR = std::max(peakR, std::abs(r));
        e.real[0][i] = float(l) * e.window[i]; e.real[1][i] = float(r) * e.window[i];
        e.imag[0][i] = e.imag[1][i] = 0;
    }
    output->rmsLeft = db(std::sqrt(ll / AnalysisFFT)); output->rmsRight = db(std::sqrt(rr / AnalysisFFT));
    output->peakLeft = db(peakL); output->peakRight = db(peakR);
    const double varL = ll - sumL * sumL / AnalysisFFT, varR = rr - sumR * sumR / AnalysisFFT;
    if (varL / AnalysisFFT > 1e-10 && varR / AnalysisFFT > 1e-10) {
        output->correlation = std::clamp((lr - sumL * sumR / AnalysisFFT) / std::sqrt(varL * varR), -1.0, 1.0);
        output->correlationValid = 1;
    }
    for (int ch = 0; ch < 2; ++ch) { DSPSplitComplex split{e.real[ch].data(), e.imag[ch].data()}; vDSP_fft_zip(e.fft, &split, 1, 13, FFT_FORWARD); }
    for (int i = 0; i < AnalysisBins; ++i) {
        const double scale = (i == 0 || i == AnalysisFFT / 2 ? 1.0 : 2.0) / e.windowSum;
        spectrumLeft[i] = float(db(std::hypot(e.real[0][i], e.imag[0][i]) * scale));
        spectrumRight[i] = float(db(std::hypot(e.real[1][i], e.imag[1][i]) * scale));
        const double crossReal = double(e.real[0][i]) * e.real[1][i] + double(e.imag[0][i]) * e.imag[1][i];
        const double crossImag = double(e.imag[0][i]) * e.real[1][i] - double(e.real[0][i]) * e.imag[1][i];
        phase[i] = float(std::atan2(crossImag, crossReal));
    }
    e.pitch(tunerRight ? right : left, count, rate, *output);
}
