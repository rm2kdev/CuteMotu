#pragma once
#include <stdint.h>
#include "AnalysisBridge.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint32_t key,bits,kind,revision; } CueValue;
typedef struct { uint64_t ready,revision,ack,status,messages,errors,writes,count,epoch; } CueStatus;
uint32_t cueOpen(uint32_t* connection);
void cueClose(uint32_t connection);
uint32_t cueSubscribe(uint32_t connection);
uint32_t cueSnapshot(uint32_t connection,uint32_t after,CueValue* values,uint32_t* count,CueStatus* status);
uint32_t cueEdit(uint32_t connection,CueValue value,uint64_t* ticket);
uint32_t cueMeters(uint32_t connection,float* peaks);
uint32_t cueDSPMeters(uint32_t connection,float* peaks,uint64_t* generation,uint32_t* count);
int cueValid(CueValue value);

#ifdef __cplusplus
}
#endif
