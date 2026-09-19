#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// The capture owns one input-only AUHAL. All calls except its internal render
// callback must be serialized on the analysis worker. No output is opened.
void* analysisCaptureOpen(uint32_t device, uint32_t left, uint32_t right, int32_t* error);
void analysisCaptureClose(void* capture);
int analysisCaptureSelect(void* capture, uint32_t left, uint32_t right);
uint32_t analysisCaptureRead(void* capture, float* left, float* right, uint32_t capacity,
                             uint64_t* dropped, int32_t* error);
enum { AnalysisWindow = 16384, AnalysisFFT = 8192, AnalysisBins = 4097 };
typedef struct {
    double frequency, confidence, rmsLeft, rmsRight, peakLeft, peakRight, correlation;
    uint32_t correlationValid;
} AnalysisResult;
void* analysisEngineCreate(void);
void analysisEngineDestroy(void* engine);
// Magnitudes are peak-amplitude dBFS (0 dBFS for a bin-centred full-scale sine).
// Phase is arg(FFT(left) * conj(FFT(right))), in radians. No signal => -120 dBFS.
void analysisProcess(void* engine, const float* left, const float* right, uint32_t count,
                     double rate, uint32_t tunerRight, AnalysisResult* result,
                     float* spectrumLeft, float* spectrumRight, float* phase);
typedef struct {
    double peakLeft, peakRight, maxLeft, maxRight, rmsLeft, rmsRight;
    double momentary, shortTerm, integrated, seconds;
    uint32_t momentaryReady, shortTermReady, clippedLeft, clippedRight, integratedFull;
} AnalysisMeterResult;
// Serial worker only. Push each newly captured sample exactly once, never the
// overlapping FFT history. Reset at source/rate changes or capture gaps.
void* analysisMeterCreate(void);
void analysisMeterDestroy(void* meter);
void analysisMeterReset(void* meter, double rate);
void analysisMeterPush(void* meter, const float* left, const float* right, uint32_t count);
void analysisMeterRead(void* meter, AnalysisMeterResult* result);
#ifdef __cplusplus
}
#endif
