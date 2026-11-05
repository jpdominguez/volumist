#pragma once
#include <CoreAudio/CoreAudio.h>

CF_ASSUME_NONNULL_BEGIN

// Real-time code: no allocations, no locks and no Swift on the audio thread.
typedef struct VMMixer VMMixer;

VMMixer *vm_create(float initial_gain);
void vm_destroy(VMMixer *mixer);
void vm_set_gain(VMMixer *mixer, float gain);

// IOProc: copies the tap's audio (last input buffer) to the output, applying the gain.
OSStatus vm_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                   const AudioBufferList *input, const AudioTimeStamp *input_time,
                   AudioBufferList *output, const AudioTimeStamp *output_time,
                   void * _Nullable client);

// Meter used only by the diagnostics: accumulates the energy of the input.
typedef struct VMMeter VMMeter;
VMMeter *vm_meter_create(void);
void vm_meter_destroy(VMMeter *meter);
float vm_meter_take_rms(VMMeter *meter);
OSStatus vm_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *input_time,
                         AudioBufferList *output, const AudioTimeStamp *output_time,
                         void * _Nullable client);

CF_ASSUME_NONNULL_END
