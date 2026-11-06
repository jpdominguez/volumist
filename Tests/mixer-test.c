// Tests the real-time mixer with synthetic audio. Run with scripts/test.sh.
#include "CMixer.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { RATE = 48000, BLOCK = 512 };
static int failures = 0;

static void expect(const char *name, double value, double low, double high) {
    int ok = value >= low && value <= high;
    printf("%-4s %-44s %.4f (expected %.4f to %.4f)\n", ok ? "ok" : "FAIL", name, value, low, high);
    if (!ok) failures++;
}

// Plays a 440 Hz sine with the given RMS, and returns the output RMS of the last `measure` seconds.
static double play(VMMixer *m, double rms, double seconds, double measure) {
    static float in[BLOCK * 2], out[BLOCK * 2];
    static double phase = 0;
    AudioBufferList input = {1, {{2, sizeof in, in}}};
    AudioBufferList output = {1, {{2, sizeof out, out}}};
    AudioTimeStamp time = {0};
    long blocks = (long)(seconds * RATE / BLOCK);
    long first = blocks - (long)(measure * RATE / BLOCK);
    double energy = 0;
    long count = 0;
    for (long b = 0; b < blocks; b++) {
        for (int i = 0; i < BLOCK; i++) {
            float x = (float)(rms * sqrt(2.0) * sin(phase));
            phase += 2 * M_PI * 440 / RATE;
            in[2 * i] = in[2 * i + 1] = x;
        }
        vm_ioproc(0, &time, &input, &time, &output, &time, m);
        if (b >= first) {
            for (int i = 0; i < BLOCK * 2; i++) energy += (double)out[i] * out[i];
            count += BLOCK * 2;
        }
    }
    return count ? sqrt(energy / count) : 0;
}

// Plays a stereo sine into outputs with the given channels, and returns each output channel's RMS.
static void route(VMMixer *m, const UInt32 *channels, UInt32 buffers, double *rms) {
    static float in[BLOCK * 2], out[2][BLOCK * 4];
    AudioBufferList *output = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    output->mNumberBuffers = buffers;
    UInt32 total = 0;
    for (UInt32 b = 0; b < buffers; b++) {
        output->mBuffers[b] = (AudioBuffer){channels[b], BLOCK * channels[b] * (UInt32)sizeof(float), out[b]};
        total += channels[b];
    }
    AudioBufferList input = {1, {{2, sizeof in, in}}};
    AudioTimeStamp time = {0};
    double phase = 0;
    for (UInt32 c = 0; c < total; c++) rms[c] = 0;
    for (int block = 0; block < 200; block++) {
        for (int i = 0; i < BLOCK; i++, phase += 2 * M_PI * 440 / RATE) {
            in[i * 2] = in[i * 2 + 1] = (float)(0.1 * sqrt(2.0) * sin(phase));
        }
        vm_ioproc(0, &time, &input, &time, output, &time, m);
        if (block < 100) continue; // once balance has settled
        UInt32 channel = 0;
        for (UInt32 b = 0; b < buffers; b++) {
            for (UInt32 c = 0; c < channels[b]; c++, channel++) {
                for (int i = 0; i < BLOCK; i++) {
                    double x = out[b][i * channels[b] + c];
                    rms[channel] += x * x;
                }
            }
        }
    }
    for (UInt32 c = 0; c < total; c++) rms[c] = sqrt(rms[c] / (100.0 * BLOCK));
    free(output);
}

int main(void) {
    VMMixer *m = vm_create(1);
    expect("disabled: passes audio unchanged", play(m, 0.1, 1, 0.5), 0.0999, 0.1001);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_leveler(m, 1, RATE);
    expect("target level stays at the target", play(m, 0.1, 10, 1), 0.095, 0.105);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_leveler(m, 1, RATE);
    expect("quiet audio is raised by at most 9 dB", play(m, 0.01, 20, 1), 0.026, 0.0285);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_leveler(m, 1, RATE);
    expect("loud audio is lowered by at most 12 dB", play(m, 0.5, 5, 1), 0.12, 0.13);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_leveler(m, 1, RATE);
    play(m, 0.05, 15, 1);
    play(m, 0.4, 0.02, 0.02); // sudden loud sound after quiet audio
    expect("a sudden loud sound is caught within 150 ms", play(m, 0.4, 0.15, 0.03), 0.09, 0.2);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_leveler(m, 1, RATE);
    double before = play(m, 0.05, 15, 1);
    expect("silence stays silent", play(m, 0, 10, 1), 0, 0.00001);
    expect("the level is the same after silence", play(m, 0.05, 0.3, 0.1), before * 0.9, before * 1.1);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_leveler(m, 1, RATE);
    play(m, 0.01, 20, 1);
    vm_set_leveler(m, 0, RATE);
    expect("turning it off returns to unity gain", play(m, 0.1, 1, 0.2), 0.0995, 0.1005);
    vm_destroy(m);

    double rms[6];
    m = vm_create(1);
    vm_set_balance(m, -1);
    route(m, (UInt32[]){2}, 1, rms);
    expect("stereo, balance left: left plays", rms[0], 0.099, 0.101);
    expect("stereo, balance left: right is silent", rms[1], 0, 0.001);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_balance(m, 1);
    route(m, (UInt32[]){1}, 1, rms);
    expect("mono, balance right: the level doesn't change", rms[0], 0.099, 0.101);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_balance(m, -1);
    vm_set_first_output_channels(m, 2);
    route(m, (UInt32[]){2, 2}, 2, rms);
    expect("two outputs: first left plays", rms[0], 0.099, 0.101);
    expect("two outputs: first right is silent", rms[1], 0, 0.001);
    expect("two outputs: second left plays", rms[2], 0.099, 0.101);
    expect("two outputs: second right is silent", rms[3], 0, 0.001);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_balance(m, 1);
    vm_set_first_output_channels(m, 1);
    route(m, (UInt32[]){1, 2}, 2, rms);
    expect("mono then stereo: mono keeps its level", rms[0], 0.099, 0.101);
    expect("mono then stereo: left is silent", rms[1], 0, 0.001);
    expect("mono then stereo: right plays", rms[2], 0.099, 0.101);
    vm_destroy(m);

    m = vm_create(1);
    vm_set_first_output_channels(m, 4);
    route(m, (UInt32[]){4, 2}, 2, rms);
    expect("four channels: extra channels stay silent", rms[2] + rms[3], 0, 0.001);
    expect("second output after four channels plays", rms[4], 0.099, 0.101);
    vm_destroy(m);

    printf(failures ? "%d FAILED\n" : "All passed\n", failures);
    return failures != 0;
}
