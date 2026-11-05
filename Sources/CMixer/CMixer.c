#include "CMixer.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static const float eq_frequencies[VM_EQ_BANDS] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
static const double eq_q = 1.41; // one octave wide

static const float level_target = 0.1f;    // -20 dBFS RMS
static const float level_gate = 0.003f;    // about -50 dBFS: below this, silence must not be raised
static const float level_max_gain = 2.818f; // +9 dB
static const float level_min_gain = 0.25f;  // -12 dB

typedef struct {
    double b0, b1, b2, a1, a2;
    int active;
} Biquad;

typedef struct {
    Biquad bands[VM_EQ_BANDS];
} EQSet;

struct VMMixer {
    _Atomic float target;
    _Atomic float ramp;
    _Atomic float balance;
    _Atomic float peak;
    _Atomic int level_enabled;
    _Atomic float level_detect; // per-sample smoothing coefficients, which depend on the sample rate
    _Atomic float level_down;
    _Atomic float level_up;
    float current;
    float current_balance;
    float level_energy;
    float level_gain;

    // Triple buffer: the writer fills sets[back] and the reader uses sets[front], so neither
    // can ever see a half-written set. The flag marks `middle` as newer than `front`.
    EQSet sets[3];
    int back;
    int front;
    _Atomic int middle;

    double z1[VM_EQ_BANDS][2];
    double z2[VM_EQ_BANDS][2];
};

enum { EQ_FRESH = 4, EQ_INDEX = 3 };

VMMixer *vm_create(float initial_gain) {
    VMMixer *m = calloc(1, sizeof(VMMixer));
    atomic_store(&m->target, initial_gain);
    atomic_store(&m->ramp, 0.002f);
    m->current = initial_gain;
    m->level_gain = 1.0f;
    m->back = 1;
    m->front = 0;
    atomic_store(&m->middle, 2);
    return m;
}

void vm_destroy(VMMixer *m) { free(m); }

void vm_set_gain(VMMixer *m, float gain, float ramp) {
    atomic_store(&m->ramp, ramp);
    atomic_store(&m->target, gain);
}

void vm_set_balance(VMMixer *m, float balance) { atomic_store(&m->balance, balance); }

static float smoothing(double seconds, double sample_rate) {
    return (float)(1.0 - exp(-1.0 / (seconds * sample_rate)));
}

void vm_set_leveler(VMMixer *m, int enabled, double sample_rate) {
    atomic_store(&m->level_detect, smoothing(0.05, sample_rate));
    atomic_store(&m->level_down, smoothing(0.02, sample_rate)); // fast, to catch a sudden loud sound
    atomic_store(&m->level_up, smoothing(2.0, sample_rate));    // slow, so that it doesn't pump
    atomic_store(&m->level_enabled, enabled);
}

float vm_eq_frequency(int band) { return eq_frequencies[band]; }

float vm_take_peak(VMMixer *m) { return atomic_exchange(&m->peak, 0.0f); }

void vm_set_eq(VMMixer *m, const float *gains_db, double sample_rate) {
    EQSet *set = &m->sets[m->back];
    for (int i = 0; i < VM_EQ_BANDS; i++) {
        Biquad *q = &set->bands[i];
        // A band too close to Nyquist can't be realized, for example 16 kHz on a 24 kHz Bluetooth link.
        q->active = gains_db[i] != 0.0f && eq_frequencies[i] < 0.45 * sample_rate;
        if (!q->active) continue;
        // Peaking filter from Robert Bristow-Johnson's Audio EQ Cookbook.
        double a = pow(10.0, gains_db[i] / 40.0);
        double w = 2.0 * M_PI * eq_frequencies[i] / sample_rate;
        double alpha = sin(w) / (2.0 * eq_q);
        double a0 = 1.0 + alpha / a;
        q->b0 = (1.0 + alpha * a) / a0;
        q->b1 = -2.0 * cos(w) / a0;
        q->b2 = (1.0 - alpha * a) / a0;
        q->a1 = q->b1;
        q->a2 = (1.0 - alpha / a) / a0;
    }
    m->back = atomic_exchange(&m->middle, m->back | EQ_FRESH) & EQ_INDEX;
}

static inline double run_eq(VMMixer *m, const EQSet *set, double x, int channel) {
    for (int i = 0; i < VM_EQ_BANDS; i++) {
        const Biquad *q = &set->bands[i];
        if (!q->active) continue;
        double y = q->b0 * x + m->z1[i][channel];
        m->z1[i][channel] = q->b1 * x - q->a1 * y + m->z2[i][channel];
        m->z2[i][channel] = q->b2 * x - q->a2 * y;
        x = y;
    }
    return x;
}

// Returns the gain for this sample, given its energy.
static inline float run_leveler(VMMixer *m, float energy, int enabled, float detect, float down, float up) {
    if (!enabled) {
        m->level_energy = 0;
        m->level_gain += (1.0f - m->level_gain) * 0.0005f;
        return m->level_gain;
    }
    m->level_energy += (energy - m->level_energy) * detect;
    if (m->level_energy > level_gate * level_gate) {
        float wanted = level_target / sqrtf(m->level_energy);
        wanted = fminf(fmaxf(wanted, level_min_gain), level_max_gain);
        m->level_gain += (wanted - m->level_gain) * (wanted < m->level_gain ? down : up);
    }
    return m->level_gain; // held during silence, so that the next sound doesn't jump
}

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

    if (atomic_load(&m->middle) & EQ_FRESH) {
        m->front = atomic_exchange(&m->middle, m->front) & EQ_INDEX;
    }
    const EQSet *eq = &m->sets[m->front];

    float target = atomic_load(&m->target);
    float ramp = atomic_load(&m->ramp);
    float balance_target = atomic_load(&m->balance);
    int level_enabled = atomic_load(&m->level_enabled);
    float level_detect = atomic_load(&m->level_detect);
    float level_down = atomic_load(&m->level_down);
    float level_up = atomic_load(&m->level_up);
    float gain = m->current;
    float balance = m->current_balance;
    float peak = 0;

    UInt32 frames = in_frames;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        UInt32 ch = output->mBuffers[b].mNumberChannels;
        if (ch == 0) continue;
        UInt32 f = output->mBuffers[b].mDataByteSize / (UInt32)sizeof(float) / ch;
        if (f < frames) frames = f;
    }

    for (UInt32 i = 0; i < frames; i++) {
        gain += (target - gain) * ramp;
        balance += (balance_target - balance) * 0.002f;
        float left = src[i * in_channels];
        float right = in_channels > 1 ? src[i * in_channels + 1] : left;
        left = (float)run_eq(m, eq, left, 0);
        right = (float)run_eq(m, eq, right, 1);
        float level = run_leveler(m, fmaxf(left * left, right * right), level_enabled,
                                  level_detect, level_down, level_up);
        left *= level;
        right *= level;
        float l = soft_limit(left * gain * (balance > 0 ? 1.0f - balance : 1.0f));
        float r = soft_limit(right * gain * (balance < 0 ? 1.0f + balance : 1.0f));
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));

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
    m->current_balance = balance;

    // Denormals are very slow on Intel, and decaying filter state ends up as denormals in silence.
    for (int i = 0; i < VM_EQ_BANDS; i++) {
        for (int c = 0; c < 2; c++) {
            if (fabs(m->z1[i][c]) < 1e-25) m->z1[i][c] = 0;
            if (fabs(m->z2[i][c]) < 1e-25) m->z2[i][c] = 0;
        }
    }

    if (peak > atomic_load(&m->peak)) atomic_store(&m->peak, peak);
    return noErr;
}

struct VMMeter {
    _Atomic double left;
    _Atomic double right;
    _Atomic unsigned long long frames;
    _Atomic float peak;
};

VMMeter *vm_meter_create(void) { return calloc(1, sizeof(VMMeter)); }
void vm_meter_destroy(VMMeter *m) { free(m); }

VMMeterReading vm_meter_take(VMMeter *m) {
    double left = atomic_exchange(&m->left, 0.0);
    double right = atomic_exchange(&m->right, 0.0);
    unsigned long long n = atomic_exchange(&m->frames, 0);
    VMMeterReading reading = {.rms = -1, .left = -1, .right = -1, .peak = atomic_exchange(&m->peak, 0.0f)};
    if (n > 0) {
        reading.rms = (float)sqrt((left + right) / (2.0 * (double)n));
        reading.left = (float)sqrt(left / (double)n);
        reading.right = (float)sqrt(right / (double)n);
    }
    return reading;
}

OSStatus vm_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *input_time,
                         AudioBufferList *output, const AudioTimeStamp *output_time,
                         void * _Nullable client) {
    (void)device; (void)now; (void)input_time; (void)output_time;
    VMMeter *m = client;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    if (input->mNumberBuffers == 0) return noErr;
    const AudioBuffer *tap = &input->mBuffers[input->mNumberBuffers - 1];
    UInt32 channels = tap->mNumberChannels;
    if (tap->mData == NULL || channels == 0) return noErr;
    const float *src = tap->mData;
    UInt32 frames = tap->mDataByteSize / (UInt32)sizeof(float) / channels;
    double left = 0, right = 0;
    float peak = 0;
    for (UInt32 i = 0; i < frames; i++) {
        float l = src[i * channels];
        float r = channels > 1 ? src[i * channels + 1] : l;
        left += (double)l * l;
        right += (double)r * r;
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));
    }
    atomic_store(&m->left, atomic_load(&m->left) + left);
    atomic_store(&m->right, atomic_load(&m->right) + right);
    atomic_store(&m->frames, atomic_load(&m->frames) + frames);
    if (peak > atomic_load(&m->peak)) atomic_store(&m->peak, peak);
    return noErr;
}
