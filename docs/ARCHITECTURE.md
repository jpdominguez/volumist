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

Adjusted path:  App ──▶ Process tap (muted) ──▶ vm_ioproc (gain) ──▶ Chosen output device
```

Apps at 100% on the system output have no tap, so their audio is untouched.

Taps belong to the Volumist process, so quitting it restores normal audio.

## Source layout

| Path | Role |
| --- | --- |
| `Sources/CMixer` | Real-time C code: gain ramp, soft limiter, channel mapping. |
| `Sources/Volumist/AudioEngine.swift` | Watches apps and devices, and reconciles them with the saved settings. |
| `Sources/Volumist/TapSession.swift` | Owns one app's tap, aggregate device and IOProc. |
| `Sources/Volumist/AppResolver.swift` | Maps a process to the app it belongs to. |
| `Sources/Volumist/Permission.swift` | Checks and requests the audio capture permission. |
| `Sources/Volumist/CoreAudioHelpers.swift` | Thin wrappers over the Core Audio property API. |
| `Sources/Volumist/VolumistApp.swift` | SwiftUI interface and entry point. |
| `Sources/Volumist/SelfTest.swift` | Diagnostics modes. |

## The reconcile loop

`AudioEngine.reconcile()` is the only place that compares actual state with desired state, and it is idempotent. It
runs whenever the process list, a process's playing state, the device list or the default output changes, when a
setting changes, and every 2 seconds as a safety net.

For each app it decides:

- **Should a tap exist?** Yes if the app has custom settings and the permission is granted. A 3-second hold stops the
  tap being rebuilt while a slider passes through 100%.
- **Should I/O run?** Yes if the gain is above zero and the app played in the last 20 seconds. When muted, the tap
  alone is enough.
- **Which device?** The chosen one if it is connected, otherwise the system output.

## Design decisions

**The tap stays muted between playbacks.** The tap keeps muting an adjusted app even while its I/O is stopped, so the
first moments of playback are silent, never a burst at full volume. Starting the I/O takes a fraction of a second.

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

- Apps that choose their own device are sent to Volumist's selected output once adjusted, because a tap mixes all of a
  process's audio together.
- Taps deliver stereo, so surround audio is downmixed for adjusted apps.
