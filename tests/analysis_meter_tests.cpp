#include "AnalysisBridge.h"
#include "AnalysisLoudness.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <vector>

namespace {
int checks = 0;
void check(bool condition, const char* text) { ++checks; if (!condition) { std::fprintf(stderr, "FAIL %s\n", text); std::exit(1); } }
void near(double a, double b, double tolerance, const char* text) {
    if (std::abs(a-b) > tolerance) std::fprintf(stderr, "actual %.10f expected %.10f\n", a, b);
    check(std::abs(a-b) <= tolerance, text);
}
struct Meter {
    void* value = analysisMeterCreate();
    explicit Meter(double rate) { analysisMeterReset(value, rate); }
    ~Meter() { analysisMeterDestroy(value); }
    AnalysisMeterResult read() { AnalysisMeterResult r{}; analysisMeterRead(value, &r); return r; }
};
void feed(Meter& meter, const std::vector<float>& l, const std::vector<float>& r, size_t chunk) {
    for (size_t i = 0; i < l.size(); i += chunk)
        analysisMeterPush(meter.value, l.data()+i, r.data()+i, uint32_t(std::min(chunk, l.size()-i)));
}
std::vector<float> tone(int rate, double seconds, double amplitude, double frequency = 997) {
    std::vector<float> out(size_t(std::llround(rate*seconds)));
    for (size_t i = 0; i < out.size(); ++i) out[i] = float(amplitude * std::sin(2*3.14159265358979323846*frequency*double(i)/rate));
    return out;
}
double energy(double lufs) { return std::pow(10, (lufs+0.691)/10); }
}
int main(int argc, char** argv) {
    if (argc == 3) {
        // Offline reference comparison: raw interleaved stereo f32, no playback.
        Meter meter(std::atoi(argv[1])); std::ifstream file(argv[2], std::ios::binary);
        if (!file) return 2;
        float interleaved[4096], l[2048], r[2048];
        while (file.read(reinterpret_cast<char*>(interleaved), sizeof(interleaved)) || file.gcount()) {
            const auto frames = uint32_t(file.gcount() / (2*sizeof(float)));
            for (uint32_t i = 0; i < frames; ++i) { l[i] = interleaved[2*i]; r[i] = interleaved[2*i+1]; }
            analysisMeterPush(meter.value, l, r, frames);
        }
        const auto v = meter.read();
        std::printf("{\"momentary\":%.8f,\"short_term\":%.8f,\"integrated\":%.8f,\"rms_left\":%.8f,\"max_left\":%.8f,\"seconds\":%.8f}\n",
                    v.momentary,v.shortTerm,v.integrated,v.rmsLeft,v.maxLeft,v.seconds);
        return 0;
    }
    for (int rate : {44100, 48000, 88200, 96000, 176400, 192000}) {
        Meter m(rate); auto l = tone(rate, 3, 0.1);
        feed(m, l, l, 257); auto r = m.read();
        near(r.momentary, -20, 0.08, "997-Hz stereo LUFS calibration at all rates");
        near(r.shortTerm, -20, 0.08, "3-second stereo loudness");
        near(r.integrated, -20, 0.08, "Integrated stereo loudness");
        near(r.rmsLeft, -23.0103, 0.01, "400-ms RMS sine convention");
        near(r.maxLeft, -20, 0.01, "Sample peak calibration");
        near(r.seconds, 3, 1e-9, "Each new sample counted exactly once");
        check(r.momentaryReady && r.shortTermReady, "Full-window readiness");
    }
    Meter m(48000);
    auto first = tone(48000, 0.399, 0.1); feed(m,first,first,1001);
    check(!m.read().momentaryReady && !m.read().shortTermReady, "No partial-window LUFS");
    auto remainder=tone(48000,0.001,0.1); feed(m,remainder,remainder,48);
    check(m.read().momentaryReady && !m.read().shortTermReady, "Momentary starts at exactly 400 ms");
    analysisMeterReset(m.value,48000);
    auto l=tone(48000,4,0.2,80), r=tone(48000,4,0.1,8000);
    Meter other(48000); feed(m,l,r,41); feed(other,l,r,16384);
    near(m.read().integrated,other.read().integrated,1e-10,"Chunk-independent integration");
    near(m.read().momentary,other.read().momentary,1e-10,"Chunk-independent momentary");
    near(m.read().shortTerm,other.read().shortTerm,1e-10,"Chunk-independent short-term");
    auto silence=std::vector<float>(48000*4,0);
    feed(m,silence,silence,1000);
    check(m.read().momentary < -100 && m.read().shortTerm < -100,"Silence drains live loudness windows");
    check(m.read().integrated > -40,"Gated integrated loudness survives silence");
    check(m.read().maxLeft > -15,"Session peak survives silence");
    analysisMeterReset(m.value,44100);
    check(m.read().seconds == 0 && m.read().integrated == -120 && m.read().maxLeft == -120,"Reset clears session and filter history");
    std::vector<float> invalid = {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(), 1.2f};
    feed(m,invalid,invalid,3);
    check(std::isfinite(m.read().peakLeft) && m.read().clippedLeft && m.read().clippedRight,"Nonfinite inputs safe, sample over latched");
    near(m.read().maxLeft,20*std::log10(1.2),1e-5,"Peak over full scale is reported");
    analysisMeterReset(m.value,std::numeric_limits<double>::quiet_NaN());
    feed(m,invalid,invalid,3); check(m.read().seconds == 0,"Invalid rate disables measurement");
    cutemix::LoudnessHistory gate;
    for (int i=0;i<50;++i) { gate.add(energy(-23)); gate.add(energy(-60)); gate.add(energy(-80)); }
    near(gate.integrated(),-23,1e-10,"Both absolute and relative gates");
    gate.reset(); gate.add(energy(-23)); gate.add(energy(-29));
    near(gate.integrated(),cutemix::loudness((energy(-23)+energy(-29))/2),1e-10,"Ungated surviving blocks averaged in power");
    gate.reset(); gate.add(0); check(gate.integrated()==-120,"Silence has no integrated loudness");
    gate.reset(); for (size_t i=0;i<cutemix::LoudnessHistory::capacity+4;++i) gate.add(energy(-23));
    check(gate.full() && gate.blocks.size()==cutemix::LoudnessHistory::capacity,"24-hour storage bound");
    near(gate.integrated(),-23,1e-8,"Bounded integration preserves completed result");
    std::printf("Analysis meters: %d checks passed.\n",checks);
}
