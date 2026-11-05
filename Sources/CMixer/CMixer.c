#include "CMixer.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct VMMixer {
    _Atomic float target;
    float current;
};

VMMixer *vm_create(float initial_gain) {
    VMMixer *m = calloc(1, sizeof(VMMixer));
    atomic_store(&m->target, initial_gain);
    m->current = initial_gain;
    return m;
}

void vm_destroy(VMMixer *m) { free(m); }
void vm_set_gain(VMMixer *m, float gain) { atomic_store(&m->target, gain); }

// Above 100 % the signal can exceed 1.0: compress it gently instead of clipping it.
static inline float soft_limit(float x) {
    const float knee = 0.8f;
    float a = fabsf(x);
    if (a <= knee) return x;
    float y = knee + (1.0f - knee) * tanhf((a - knee) / (1.0f - knee));
    return x < 0 ? -y : y;
}

OSStatus vm_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                   const AudioBufferList *input, const AudioTimeStamp *input_time,
                   AudioBufferList *output, const AudioTimeStamp *output_time,
                   void * _Nullable client) {
    (void)device; (void)now; (void)input_time; (void)output_time;
    VMMixer *m = client;

    UInt32 out_channels = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        out_channels += output->mBuffers[b].mNumberChannels;
    }
    if (input->mNumberBuffers == 0 || out_channels == 0) return noErr;

    // The aggregate exposes the device's inputs first and the tap last.
    const AudioBuffer *tap = &input->mBuffers[input->mNumberBuffers - 1];
    UInt32 in_channels = tap->mNumberChannels;
    if (in_channels == 0 || tap->mData == NULL) return noErr;
    const float *src = tap->mData;
    UInt32 in_frames = tap->mDataByteSize / (UInt32)sizeof(float) / in_channels;

    float target = atomic_load(&m->target);
    float gain = m->current;
    const float ramp = 0.002f; // ~10 ms at 48 kHz: avoids clicks while the slider moves

    UInt32 frames = in_frames;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        UInt32 ch = output->mBuffers[b].mNumberChannels;
        if (ch == 0) continue;
        UInt32 f = output->mBuffers[b].mDataByteSize / (UInt32)sizeof(float) / ch;
        if (f < frames) frames = f;
    }

    for (UInt32 i = 0; i < frames; i++) {
        gain += (target - gain) * ramp;
        float left = src[i * in_channels];
        float right = in_channels > 1 ? src[i * in_channels + 1] : left;
        float l = soft_limit(left * gain);
        float r = soft_limit(right * gain);

        UInt32 channel = 0;
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            UInt32 ch = output->mBuffers[b].mNumberChannels;
            float *dst = output->mBuffers[b].mData;
            for (UInt32 c = 0; c < ch; c++, channel++) {
                if (out_channels == 1) dst[i * ch + c] = 0.5f * (l + r);
                else if (channel == 0) dst[i * ch + c] = l;
                else if (channel == 1) dst[i * ch + c] = r;
            }
        }
    }
    m->current = gain;
    return noErr;
}

struct VMMeter {
    _Atomic double energy;
    _Atomic unsigned long long samples;
};

VMMeter *vm_meter_create(void) { return calloc(1, sizeof(VMMeter)); }
void vm_meter_destroy(VMMeter *m) { free(m); }

float vm_meter_take_rms(VMMeter *m) {
    double energy = atomic_exchange(&m->energy, 0.0);
    unsigned long long n = atomic_exchange(&m->samples, 0);
    return n ? (float)sqrt(energy / (double)n) : -1.0f;
}

OSStatus vm_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *input_time,
                         AudioBufferList *output, const AudioTimeStamp *output_time,
                         void * _Nullable client) {
    (void)device; (void)now; (void)input_time; (void)output; (void)output_time;
    VMMeter *m = client;
    if (input->mNumberBuffers == 0) return noErr;
    const AudioBuffer *tap = &input->mBuffers[input->mNumberBuffers - 1];
    if (tap->mData == NULL) return noErr;
    const float *src = tap->mData;
    UInt32 n = tap->mDataByteSize / (UInt32)sizeof(float);
    double e = 0;
    for (UInt32 i = 0; i < n; i++) e += (double)src[i] * src[i];
    atomic_store(&m->energy, atomic_load(&m->energy) + e);
    atomic_store(&m->samples, atomic_load(&m->samples) + n);
    return noErr;
}
