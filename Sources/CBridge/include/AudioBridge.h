// Audio module private declarations.
//
// The per-app volume render path lives here in C so that nothing on the Core
// Audio IO thread touches the Swift runtime (no allocation, no locks, no ARC).
//
// Signal path per tap:  tap input -> gain (ramped per buffer) -> look-ahead
// delay -> limiter gain -> device output.  The delay is always in the path
// (about 1.5 ms), so nothing switches when the gain crosses 100%; at or below
// unity the limiter gain is exactly 1 and the path is a bit-exact delayed copy.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define BOSUN_TAP_MAX_CHANNELS 32
#define BOSUN_TAP_MAX_LOOKAHEAD 256
#define BOSUN_TAP_MAX_GAIN 4.0f         // +12 dB, the top of a 200% slider
#define BOSUN_TAP_CEILING 0.999f        // limiter output never exceeds this
#define BOSUN_TAP_RELEASE_SECONDS 0.15

/// Shared between the main thread (gain target, meters) and one IO thread.
typedef struct BosunTapState {
    // Controls: written by any thread, read by the IO thread.
    _Atomic float targetGain;
    _Atomic int stereoLeft;         // >= 0: stereo input goes to these two output
    _Atomic int stereoRight;        //       channels instead of mapping 1:1
    _Atomic int mirrorStreams;      // stereo input goes to the first two channels of every output buffer
    _Atomic int inputSkip;          // leading input buffers that are NOT the tap (the device's own inputs)
    // Meters: written by the IO thread.
    _Atomic uint64_t cycles;
    _Atomic float inputPeak;        // max |sample| on the tap since last taken
    _Atomic float outputPeak;       // max |sample| written since last taken
    _Atomic float limiterFloor;     // lowest limiter gain since last taken (1 = idle)
    // IO thread only.
    float currentGain;
    uint32_t lookahead;             // frames of delay (D)
    float releaseStep;              // per-frame release coefficient
    uint32_t pos;                   // write index into the D-long rings
    uint32_t reqPos;                // write index into the (D+1)-long ring
    uint32_t reqBelow;              // entries of `required` that are < 1
    uint32_t idleRun;               // consecutive frames with released == 1
    double released;                // limiter gain after hold + release (double: a float stalls short of 1)
    double releasedSum;             // running sum of `history`
    float required[BOSUN_TAP_MAX_LOOKAHEAD + 1];
    float history[BOSUN_TAP_MAX_LOOKAHEAD];
    float delay[BOSUN_TAP_MAX_CHANNELS][BOSUN_TAP_MAX_LOOKAHEAD];
} BosunTapState;

static inline void BosunTapLimiterReset(BosunTapState *s) {
    s->pos = 0; s->reqPos = 0; s->reqBelow = 0; s->idleRun = 0;
    s->released = 1.0;
    s->releasedSum = (double)s->lookahead;
    for (uint32_t i = 0; i <= BOSUN_TAP_MAX_LOOKAHEAD; i++) s->required[i] = 1.0f;
    for (uint32_t i = 0; i < BOSUN_TAP_MAX_LOOKAHEAD; i++) s->history[i] = 1.0f;
    memset(s->delay, 0, sizeof(s->delay));
}

/// Sets the look-ahead and release for a sample rate. Call before IO starts.
static inline void BosunTapStateConfigure(void *state, double sampleRate) {
    BosunTapState *s = (BosunTapState *)state;
    if (!(sampleRate >= 8000.0)) sampleRate = 48000.0;
    double frames = floor(sampleRate * 0.0015 + 0.5);
    if (frames < 16) frames = 16;
    if (frames > BOSUN_TAP_MAX_LOOKAHEAD) frames = BOSUN_TAP_MAX_LOOKAHEAD;
    s->lookahead = (uint32_t)frames;
    s->releaseStep = (float)(1.0 - exp(-1.0 / (BOSUN_TAP_RELEASE_SECONDS * sampleRate)));
    BosunTapLimiterReset(s);
}

static inline void *BosunTapStateCreate(float gain) {
    BosunTapState *s = (BosunTapState *)calloc(1, sizeof(BosunTapState));
    if (!s) return NULL;
    if (!(gain >= 0.0f)) gain = 0.0f;
    if (gain > BOSUN_TAP_MAX_GAIN) gain = BOSUN_TAP_MAX_GAIN;
    atomic_store(&s->targetGain, gain);
    atomic_store(&s->stereoLeft, -1);
    atomic_store(&s->stereoRight, -1);
    atomic_store(&s->limiterFloor, 1.0f);
    s->currentGain = gain;
    BosunTapStateConfigure(s, 48000.0);
    return s;
}
static inline void BosunTapStateDestroy(void *state) { free(state); }
static inline void BosunTapStateSetGain(void *state, float gain) {
    if (!(gain >= 0.0f)) gain = 0.0f;
    if (gain > BOSUN_TAP_MAX_GAIN) gain = BOSUN_TAP_MAX_GAIN;
    atomic_store(&((BosunTapState *)state)->targetGain, gain);
}
/// Where stereo input lands on the output. `left`/`right` are 0-based output
/// channel indexes, or -1 for plain 1:1 mapping. `mirror` copies the pair to
/// the first two channels of every output buffer (multi-output devices).
static inline void BosunTapStateSetStereoMap(void *state, int left, int right, int mirror) {
    BosunTapState *s = (BosunTapState *)state;
    atomic_store(&s->stereoLeft, left);
    atomic_store(&s->stereoRight, right);
    atomic_store(&s->mirrorStreams, mirror);
}
/// The aggregate device's input side lists the output device's own input
/// streams (a headset's microphone, say) before the tap. Those must never be
/// played: `count` leading input buffers are ignored.
static inline void BosunTapStateSetInputSkip(void *state, int count) {
    atomic_store(&((BosunTapState *)state)->inputSkip, count < 0 ? 0 : count);
}
static inline uint32_t BosunTapStateLookahead(void *state) { return ((BosunTapState *)state)->lookahead; }
static inline uint64_t BosunTapStateCycles(void *state) {
    return atomic_load(&((BosunTapState *)state)->cycles);
}
/// Each of these returns the meter and clears it.
static inline float BosunTapStateTakeInputPeak(void *state) {
    return atomic_exchange(&((BosunTapState *)state)->inputPeak, 0.0f);
}
static inline float BosunTapStateTakeOutputPeak(void *state) {
    return atomic_exchange(&((BosunTapState *)state)->outputPeak, 0.0f);
}
static inline float BosunTapStateTakeLimiterFloor(void *state) {
    return atomic_exchange(&((BosunTapState *)state)->limiterFloor, 1.0f);
}

typedef struct { float *samples; UInt32 stride; } BosunTapChannel;

/// Flattens a buffer list (interleaved or not), ignoring the first `skip`
/// buffers, into per-channel cursors and lowers `frames` to the shortest buffer.
static inline UInt32 BosunTapCollect(const AudioBufferList *list, UInt32 skip, BosunTapChannel *out, UInt32 max, UInt32 *frames) {
    UInt32 n = 0;
    if (!list) return 0;
    for (UInt32 b = skip; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buf = &list->mBuffers[b];
        UInt32 channels = buf->mNumberChannels;
        if (!buf->mData || channels == 0) continue;
        UInt32 f = buf->mDataByteSize / (channels * (UInt32)sizeof(float));
        if (f < *frames) *frames = f;
        for (UInt32 c = 0; c < channels && n < max; c++) {
            out[n].samples = (float *)buf->mData + c;
            out[n].stride = channels;
            n++;
        }
    }
    return n;
}

/// One frame of limiter gain for a frame whose loudest (already boosted)
/// sample is `peak`. Returns the gain for the frame leaving the delay line.
///
/// required[n] = ceiling / peak when limiting is needed, else 1.
/// held[n]     = min(required[n-D .. n])            (look-ahead + hold)
/// released[n] = min(held[n], one-pole rise towards 1)
/// gain[n]     = mean(released[n-D+1 .. n])         (smooth attack over D frames)
/// Every term of that mean covers frame n-D, so gain[n] <= required[n-D]: the
/// delayed frame can never leave above the ceiling. The final min() makes that
/// hold even against rounding in the running sum.
static inline float BosunTapLimiterStep(BosunTapState *s, float peak, int limiting) {
    const uint32_t D = s->lookahead;
    float need = (limiting && peak > BOSUN_TAP_CEILING) ? BOSUN_TAP_CEILING / peak : 1.0f;

    // Ring of D+1 required gains; the slot being overwritten is frame n-D-1.
    if (s->required[s->reqPos] < 1.0f) s->reqBelow--;
    s->required[s->reqPos] = need;
    if (need < 1.0f) s->reqBelow++;
    s->reqPos = (s->reqPos + 1) % (D + 1);
    float delayedNeed = s->required[s->reqPos];     // frame n-D, now the oldest

    float held = 1.0f;
    if (s->reqBelow > 0) {
        for (uint32_t i = 0; i <= D; i++) if (s->required[i] < held) held = s->required[i];
    }

    double rising = s->released + (1.0 - s->released) * (double)s->releaseStep;
    if (rising > 0.99999) rising = 1.0;
    if (rising > (double)held) rising = (double)held;
    s->released = rising;
    float released = (float)rising;

    s->releasedSum += (double)released - (double)s->history[s->pos];
    s->history[s->pos] = released;
    if (released == 1.0f) {
        // Once the whole window is idle the mean is exactly 1 again; pin it so
        // the unity path stays bit-exact for ever.
        if (s->idleRun < D) s->idleRun++;
        if (s->idleRun >= D) s->releasedSum = (double)D;
    } else {
        s->idleRun = 0;
    }
    float gain = (float)(s->releasedSum / (double)D);
    if (gain > delayedNeed) gain = delayedNeed;
    if (gain > 1.0f) gain = 1.0f;
    return gain;
}

/// Copies Float32 tap input to Float32 device output through the gain, delay
/// and limiter. Output that has no matching input stays silent.
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
    UInt32 inCount = BosunTapCollect(input, (UInt32)atomic_load(&state->inputSkip), in, BOSUN_TAP_MAX_CHANNELS, &frames);
    UInt32 outCount = BosunTapCollect(output, 0, out, BOSUN_TAP_MAX_CHANNELS, &frames);
    float target = atomic_load(&state->targetGain);
    if (inCount == 0 || outCount == 0 || frames == 0 || frames == UINT32_MAX) {
        // Nothing to play: drop what is in the delay line so stale audio
        // cannot leak out when input returns.
        state->currentGain = target;
        BosunTapLimiterReset(state);
        return;
    }

    // Work out which output channel(s) each input channel feeds.
    // dst[c][0..dstCount[c]) are indexes into `out`.
    UInt32 channels = inCount;
    const BosunTapChannel *src[BOSUN_TAP_MAX_CHANNELS];
    BosunTapChannel dst[BOSUN_TAP_MAX_CHANNELS][2];
    UInt32 dstCount[BOSUN_TAP_MAX_CHANNELS];
    int left = atomic_load(&state->stereoLeft), right = atomic_load(&state->stereoRight);
    int mirror = atomic_load(&state->mirrorStreams);
    UInt32 mirrored = 0;
    if (inCount <= 2 && mirror && output->mNumberBuffers > 1) {
        // Multi-output device: the pair goes to the front of every stream.
        channels = 2;
        mirrored = 1;
    } else if (inCount <= 2 && left >= 0 && right >= 0 && (UInt32)left < outCount && (UInt32)right < outCount) {
        channels = 2;
        src[0] = &in[0]; src[1] = &in[inCount - 1];
        dst[0][0] = out[left]; dst[1][0] = out[right];
        dstCount[0] = dstCount[1] = 1;
    } else if (inCount == 1 && outCount >= 2) {
        channels = 1;                               // mono tap feeds both front channels
        src[0] = &in[0];
        dst[0][0] = out[0]; dst[0][1] = out[1];
        dstCount[0] = 2;
    } else {
        channels = inCount < outCount ? inCount : outCount;
        for (UInt32 c = 0; c < channels; c++) { src[c] = &in[c]; dst[c][0] = out[c]; dstCount[c] = 1; }
    }
    if (mirrored) { src[0] = &in[0]; src[1] = &in[inCount - 1]; }

    const uint32_t D = state->lookahead;
    float gain = state->currentGain;
    const float step = (target - gain) / (float)frames;
    float inPeak = 0.0f, outPeak = 0.0f, floorGain = 1.0f;
    float frame[BOSUN_TAP_MAX_CHANNELS];

    for (UInt32 f = 0; f < frames; f++) {
        gain += step;
        float peak = 0.0f;
        for (UInt32 c = 0; c < channels; c++) {
            float x = src[c]->samples[(size_t)f * src[c]->stride];
            float ax = fabsf(x);
            if (ax > inPeak) inPeak = ax;
            float y = x * gain;
            frame[c] = y;
            float ay = fabsf(y);
            if (ay > peak) peak = ay;
        }
        // Only limit while boosting: at or below 100% the app's own samples
        // pass through untouched, exactly as they would without Bosun.
        float reduce = BosunTapLimiterStep(state, peak, gain > 1.0f);
        if (reduce < floorGain) floorGain = reduce;
        uint32_t slot = state->pos;
        for (UInt32 c = 0; c < channels; c++) {
            float y = state->delay[c][slot] * reduce;
            state->delay[c][slot] = frame[c];
            if (reduce < 1.0f) {
                // Rounding in the product can land one ulp over; make the bound exact.
                if (y > BOSUN_TAP_CEILING) y = BOSUN_TAP_CEILING;
                else if (y < -BOSUN_TAP_CEILING) y = -BOSUN_TAP_CEILING;
            }
            float ay = fabsf(y);
            if (ay > outPeak) outPeak = ay;
            if (mirrored) {
                for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
                    const AudioBuffer *buf = &output->mBuffers[b];
                    if (!buf->mData || buf->mNumberChannels == 0) continue;
                    UInt32 ch = buf->mNumberChannels > 1 ? c : 0;
                    if (buf->mNumberChannels == 1 && c == 1) continue;
                    ((float *)buf->mData)[(size_t)f * buf->mNumberChannels + ch] = y;
                }
            } else {
                for (UInt32 d = 0; d < dstCount[c]; d++) dst[c][d].samples[(size_t)f * dst[c][d].stride] = y;
            }
        }
        state->pos = (slot + 1) % D;
    }
    state->currentGain = target;
    if (inPeak > atomic_load(&state->inputPeak)) atomic_store(&state->inputPeak, inPeak);
    if (outPeak > atomic_load(&state->outputPeak)) atomic_store(&state->outputPeak, outPeak);
    if (floorGain < atomic_load(&state->limiterFloor)) atomic_store(&state->limiterFloor, floorGain);
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

// MARK: Input level meter

typedef struct BosunMeterState {
    _Atomic float peak;
    _Atomic uint64_t cycles;
} BosunMeterState;

static inline void *BosunMeterStateCreate(void) { return calloc(1, sizeof(BosunMeterState)); }
static inline void BosunMeterStateDestroy(void *state) { free(state); }
static inline float BosunMeterStateTakePeak(void *state) {
    return atomic_exchange(&((BosunMeterState *)state)->peak, 0.0f);
}
static inline uint64_t BosunMeterStateCycles(void *state) {
    return atomic_load(&((BosunMeterState *)state)->cycles);
}

/// Peak of everything on the input side of a device. Nothing is stored or
/// forwarded; samples are only measured.
static inline void BosunMeterMeasure(void *statePtr, const AudioBufferList *input) {
    BosunMeterState *state = (BosunMeterState *)statePtr;
    if (!state) return;
    atomic_fetch_add(&state->cycles, 1);
    if (!input) return;
    float peak = 0.0f;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buf = &input->mBuffers[b];
        if (!buf->mData) continue;
        const float *p = (const float *)buf->mData;
        UInt32 n = buf->mDataByteSize / (UInt32)sizeof(float);
        for (UInt32 i = 0; i < n; i++) {
            float a = fabsf(p[i]);
            if (a > peak) peak = a;
        }
    }
    if (peak > atomic_load(&state->peak)) atomic_store(&state->peak, peak);
}

static inline OSStatus BosunMeterIOProc(AudioObjectID device, const AudioTimeStamp *now,
                                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                        AudioBufferList *output, const AudioTimeStamp *outputTime,
                                        void *client) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    if (output) {
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        }
    }
    BosunMeterMeasure(client, input);
    return 0;
}
static inline AudioDeviceIOProc BosunMeterIOProcPointer(void) { return BosunMeterIOProc; }
