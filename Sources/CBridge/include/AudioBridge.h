// Audio module private declarations.
//
// The per-app volume render path lives here in C so that nothing on the Core
// Audio IO thread touches the Swift runtime (no allocation, no locks, no ARC).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/// Shared between the main thread (gain target, meters) and one IO thread.
typedef struct BosunTapState {
    _Atomic float targetGain;   // written by any thread, read by the IO thread
    float currentGain;          // IO thread only; ramps towards targetGain
    _Atomic uint64_t cycles;    // IO cycles rendered so far
    _Atomic float inputPeak;    // max |sample| seen on the tap since last reset
    _Atomic float outputPeak;   // max |sample| written since last reset
} BosunTapState;

static inline void *BosunTapStateCreate(float gain) {
    BosunTapState *s = (BosunTapState *)calloc(1, sizeof(BosunTapState));
    if (!s) return NULL;
    atomic_store(&s->targetGain, gain);
    s->currentGain = gain;
    return s;
}
static inline void BosunTapStateDestroy(void *state) { free(state); }
static inline void BosunTapStateSetGain(void *state, float gain) {
    if (!(gain >= 0.0f)) gain = 0.0f;
    if (gain > 1.0f) gain = 1.0f;       // never amplify: the path cannot clip
    atomic_store(&((BosunTapState *)state)->targetGain, gain);
}
static inline uint64_t BosunTapStateCycles(void *state) {
    return atomic_load(&((BosunTapState *)state)->cycles);
}
/// Returns and clears the peak meters.
static inline float BosunTapStateTakeInputPeak(void *state) {
    return atomic_exchange(&((BosunTapState *)state)->inputPeak, 0.0f);
}
static inline float BosunTapStateTakeOutputPeak(void *state) {
    return atomic_exchange(&((BosunTapState *)state)->outputPeak, 0.0f);
}

#define BOSUN_TAP_MAX_CHANNELS 64
typedef struct { float *samples; UInt32 stride; } BosunTapChannel;

/// Flattens a buffer list (interleaved or not) into per-channel cursors and
/// lowers `frames` to the shortest buffer.
static inline UInt32 BosunTapCollect(const AudioBufferList *list, BosunTapChannel *out, UInt32 *frames) {
    UInt32 n = 0;
    if (!list) return 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buf = &list->mBuffers[b];
        UInt32 channels = buf->mNumberChannels;
        if (!buf->mData || channels == 0) continue;
        UInt32 f = buf->mDataByteSize / (channels * (UInt32)sizeof(float));
        if (f < *frames) *frames = f;
        for (UInt32 c = 0; c < channels && n < BOSUN_TAP_MAX_CHANNELS; c++) {
            out[n].samples = (float *)buf->mData + c;
            out[n].stride = channels;
            n++;
        }
    }
    return n;
}

/// Copies Float32 tap input to Float32 device output, scaled by a gain that
/// is ramped across the buffer so volume changes never click. Output that has
/// no matching input stays silent.
static inline void BosunTapRender(void *statePtr, const AudioBufferList *input, AudioBufferList *output) {
    BosunTapState *state = (BosunTapState *)statePtr;
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    if (!state) return;
    atomic_fetch_add(&state->cycles, 1);

    BosunTapChannel in[BOSUN_TAP_MAX_CHANNELS], out[BOSUN_TAP_MAX_CHANNELS];
    UInt32 frames = UINT32_MAX;
    UInt32 inCount = BosunTapCollect(input, in, &frames);
    UInt32 outCount = BosunTapCollect(output, out, &frames);
    float target = atomic_load(&state->targetGain);
    if (inCount == 0 || outCount == 0 || frames == 0 || frames == UINT32_MAX) {
        state->currentGain = target;
        return;
    }

    float start = state->currentGain;
    float step = (target - start) / (float)frames;
    // A mono tap feeds both front channels; otherwise channels map 1:1.
    UInt32 pairs = inCount < outCount ? inCount : outCount;
    if (inCount == 1 && outCount >= 2) pairs = 2;
    float inPeak = 0.0f, outPeak = 0.0f;
    for (UInt32 c = 0; c < pairs; c++) {
        const BosunTapChannel src = in[inCount == 1 ? 0 : c];
        const BosunTapChannel dst = out[c];
        float gain = start;
        for (UInt32 f = 0; f < frames; f++) {
            gain += step;
            float x = src.samples[(size_t)f * src.stride];
            float y = x * gain;
            dst.samples[(size_t)f * dst.stride] = y;
            float ax = fabsf(x), ay = fabsf(y);
            if (ax > inPeak) inPeak = ax;
            if (ay > outPeak) outPeak = ay;
        }
    }
    state->currentGain = target;
    if (inPeak > atomic_load(&state->inputPeak)) atomic_store(&state->inputPeak, inPeak);
    if (outPeak > atomic_load(&state->outputPeak)) atomic_store(&state->outputPeak, outPeak);
}

/// AudioDeviceIOProc for the private aggregate device (tap in, speakers out).
static inline OSStatus BosunTapIOProc(AudioObjectID device, const AudioTimeStamp *now,
                                      const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                      AudioBufferList *output, const AudioTimeStamp *outputTime,
                                      void *client) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    BosunTapRender(client, input, output);
    return 0;
}

/// Swift cannot take the address of a static inline function directly in every
/// toolchain, so hand it out through a getter.
static inline AudioDeviceIOProc BosunTapIOProcPointer(void) { return BosunTapIOProc; }
