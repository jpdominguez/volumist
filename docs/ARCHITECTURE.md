# How Volumist works

Volumist is a menu bar app built on Core Audio process taps, which arrived in macOS 14.2. It needs no audio driver.

## Audio path

For an app with custom settings, Volumist creates:

1. A **process tap** on all of the app's audio processes, with `CATapMuted`. macOS stops sending those processes'
   audio to the hardware and exposes it to Volumist instead.
2. A **private aggregate device** that combines the tap with the chosen output device.
3. An **IOProc** on that aggregate that copies the tap's audio to the output, applying the gain.

```text
Default path:   App ───────────────────────────────▶ Output device

Adjusted path:  App ──▶ Process tap (muted) ──▶ vm_ioproc ──▶ Chosen output device
                                                 EQ → leveler → gain → balance → limiter
```

Apps with default settings have no muting tap, so their audio is untouched.

Taps belong to the Volumist process, so quitting it restores normal audio.

## Source layout

| Path | Role |
| --- | --- |
| `Sources/CMixer` | Real-time C code: equalizer, gain ramp, balance, soft limiter, channel mapping, meters. |
| `Sources/Volumist/AudioEngine.swift` | Watches apps and devices, and reconciles them with the saved settings. |
| `Sources/Volumist/TapSession.swift` | Owns one app's tap, aggregate device and IOProc. |
| `Sources/Volumist/MeterTap.swift` | Reads the level of an app without changing its audio. |
| `Sources/Volumist/UpdateChecker.swift` | The optional update check. |
| `Sources/Volumist/AppResolver.swift` | Maps a process to the app it belongs to. |
| `Sources/Volumist/Permission.swift` | Checks and requests the audio capture permission. |
| `Sources/Volumist/CoreAudioHelpers.swift` | Thin wrappers over the Core Audio property API. |
| `Sources/Volumist/VolumistApp.swift` | SwiftUI interface and entry point. |
| `Sources/Volumist/Screens.swift` | The welcome and What's New screens, and which one opens at launch. |
| `Sources/Volumist/SelfTest.swift` | Diagnostics modes. |

## The reconcile loop

`AudioEngine.reconcile()` is the only place that compares actual state with desired state, and it is idempotent. It
runs whenever the process list, a process's playing state, the device list or the default output changes, when a
setting changes, and every 2 seconds as a safety net.

For each app it decides:

- **Should a tap exist?** Yes if the app has custom settings and the permission is granted. A 3-second hold stops the
  tap being rebuilt while a slider passes through 100%.
- **Should I/O run?** Yes if the app played in the last 20 seconds, even while muted, and always once when a tap is
  created. A tap that has never run doesn't mute its app.
- **Which device?** The chosen one if it is connected, otherwise the system output.

## Lowering during calls

Each audio process reports whether it is using the microphone (`kAudioProcessPropertyIsRunningInput`), and
`AudioEngine.refreshCall` treats a user app doing so as a call. System services are ignored, since some keep the
microphone open permanently, as are gaps of under 2 seconds.

Some apps release the microphone when you mute yourself, so `CallTracker` keeps a known call app in its call while it
is still playing, for up to 3 minutes since it last used the microphone. The limit covers apps that leave their output
open after a call. Browsers and apps added by the user don't get this, because playing is normal for them.

An app is lowered if a call is active, it isn't in the call, it hasn't been excluded, and it is playing. Its gain is
its normal gain multiplied by the lowering level, which uses the same curve as the sliders. Apps at their defaults
get a tap for the duration of the call, and lose it once they have faded back up. Fades take about a second at
48 kHz, and longer at lower sample rates, because the ramp is applied per sample.

## Equalizer

Each app has ten peaking biquad filters per channel, one octave wide, designed with the formulas from Robert
Bristow-Johnson's Audio EQ Cookbook and run in double precision. Bands at 0 dB are skipped, as are bands above 45% of
the sample rate. Coefficients are recalculated when the aggregate is created, because each output can have its own
sample rate.

New coefficients reach the audio thread through a lock-free triple buffer: the main thread writes one set, the audio
thread reads another, and the third is exchanged atomically, so neither can see a half-written set.

## Leveler

Each app can have an automatic gain control aiming for -20 dBFS RMS, between -12 and +9 dB. The level is measured with
a 50 ms window on the louder channel. The gain falls with a 20 ms time constant, to catch sudden loud sounds, and
rises over 2 seconds, so that it doesn't pump. Below -50 dBFS the gain is held, so silence isn't raised and the next
sound starts at the same level. `Tests/mixer-test.c` covers this behavior.

## Level meters

An app with a session reports its level from the mixer, after gain and limiting. Any other playing app gets a
`MeterTap` while the window is open: an unmuted tap on a private aggregate that outputs silence. It reads the audio
without changing its path, and it is removed when the window closes, so there is no cost the rest of the time.

## Update check

`UpdateChecker` is off by default. When enabled, it runs at launch and every 24 hours, and requests the latest release
from the GitHub API. It only shows a link to the release page and never downloads anything. The **Check Now** button
makes the same request once, whether or not the automatic check is on.

## Two outputs

An app with a second output gets one aggregate with both devices. The first is the clock, and the second has drift
compensation. The aggregate's output buffers follow the order of its subdevices, so `vm_set_first_output_channels` tells
the mixer where the second device starts. Both get the same processed audio, and a mono device gets a mix that ignores
balance. A pair that macOS refuses falls back to the first output, and isn't tried again until the setting changes.

## Output volumes

The window has a general volume for each output. Outputs with a volume of their own use it, whether or not they are the
Mac's current output. For the rest, such as many HDMI monitors, Volumist lowers what it plays there through
`vm_set_output_gains`, so any app playing on such an output gets a tap while its level is below 100%.

## Launch screens

A menu bar app opens no window, so `LaunchScreen` decides whether something should appear at launch. A new user gets
the welcome screen, which also holds back the permission prompt until they have read why it is needed. After an update,
What's New lists the versions not seen yet. `lastSeenVersion` records the last version opened. Versions before 1.3 didn't
save it, so existing settings are what tell an update from a new user.

The notes come from `CHANGELOG.md`, which `scripts/build.sh` copies into the app: its bullets are what users read, and a
release without an entry for its version shows nothing. Nothing is fetched from the network.

## Design decisions

**The tap stays muted between playbacks.** The tap keeps muting an adjusted app even while its I/O is stopped, so the
first moments of playback are silent rather than a burst at full volume. A tap has to have run at least once for this
to work, so every new tap starts its I/O once, even if the app is idle.

**Failures must stay audible.** If a tap can't be started, it is destroyed so the app returns to normal audio. No tap
is created without the capture permission, because taps deliver silence without it.

**Sample rate changes rebuild the aggregate.** This happens, for example, when Bluetooth headphones switch profile
because an app opened their microphone.

**Volume curve.** Gain is the square of the slider position, which feels closer to perceived loudness: 50% is about
-12 dB, and 150% is about +7 dB.

**Gain ramp.** The gain moves towards its target sample by sample over about 10 ms, so slider moves don't click.

**Channel mapping.** Taps deliver a stereo mixdown. Mono outputs get the average of both channels, and on outputs with
more than two channels only the first two are used.

## Private APIs

Two functions have no public equivalent. Both are loaded dynamically, and Volumist degrades gracefully without them:

| Function | Used for | Without it |
| --- | --- | --- |
| `TCCAccessPreflight`, `TCCAccessRequest` | Checking and requesting the audio capture permission. | The state is unknown and no taps are created. |
| `responsibility_get_pid_responsible_for_pid` | Finding the app behind a helper process. | Falls back to the app bundle in the process path. |

They are the reason Volumist can't be submitted to the Mac App Store in its current form.

## Known gaps

- Two outputs with different sample rates are untested, including Bluetooth headphones in call mode next to wired
  outputs. If macOS creates the aggregate but plays them badly, Volumist can't detect it.
- `ci.yml` builds and checks the interface on macOS 15, macOS 26 and Intel, but runners have no audio hardware. Real
  audio has only been tested on Apple silicon, and macOS 14 can't be tested there at all.
- Apps that choose their own device are sent to Volumist's selected output once adjusted, because a tap mixes all of a
  process's audio together.
- Taps deliver stereo, so surround audio is downmixed for adjusted apps.
