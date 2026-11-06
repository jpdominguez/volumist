#pragma once
#include <CoreAudio/CoreAudio.h>

CF_ASSUME_NONNULL_BEGIN

// Real-time code: no allocations, no locks and no Swift on the audio thread.
#define VM_EQ_BANDS 10

typedef struct VMMixer VMMixer;

VMMixer *vm_create(float initial_gain);
void vm_destroy(VMMixer *mixer);

// `ramp` is the fraction of the remaining distance covered per sample: larger is faster.
void vm_set_gain(VMMixer *mixer, float gain, float ramp);

// -1 is fully left, 0 is centered, 1 is fully right.
void vm_set_balance(VMMixer *mixer, float balance);

// For an aggregate with two outputs: how many channels the first one has. 0 means a single output.
// Call before starting I/O.
void vm_set_first_output_channels(VMMixer *mixer, UInt32 channels);

// Gains in dB for the bands in vm_eq_frequency order. Call from a single non-real-time thread.
void vm_set_eq(VMMixer *mixer, const float *gains_db, double sample_rate);
float vm_eq_frequency(int band);

// Automatic volume leveling: raises quiet passages and lowers loud ones, up to +9 and -12 dB.
void vm_set_leveler(VMMixer *mixer, int enabled, double sample_rate);

// The peak since the last call, after gain and limiting.
float vm_take_peak(VMMixer *mixer);

// IOProc: copies the tap's audio (last input buffer) to the output, applying EQ, gain and balance.
OSStatus vm_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                   const AudioBufferList *input, const AudioTimeStamp *input_time,
                   AudioBufferList *output, const AudioTimeStamp *output_time,
                   void * _Nullable client);

// Passive meter: reads a tap's input and outputs silence.
typedef struct VMMeter VMMeter;
typedef struct {
    float rms;
    float left;
    float right;
    float peak;
} VMMeterReading;

VMMeter *vm_meter_create(void);
void vm_meter_destroy(VMMeter *meter);
VMMeterReading vm_meter_take(VMMeter *meter);
OSStatus vm_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *input_time,
                         AudioBufferList *output, const AudioTimeStamp *output_time,
                         void * _Nullable client);

CF_ASSUME_NONNULL_END
