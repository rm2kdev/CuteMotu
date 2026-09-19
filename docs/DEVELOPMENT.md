# Architecture and development

CuteMotu builds a native arm64 macOS service, an AudioServerPlugIn, a control client and the SwiftUI Cute Mix USB app. The deployment target is macOS 13; physical testing has been on macOS 26.5.1. No DriverKit extension is built by this source tree.

## Components

| Directory | Responsibility |
| :-- | :-- |
| `src/Core` | Register protocol, descriptors and bounded parsing. |
| `src/Streaming` | PCM maps, sample-rate profiles, clock recovery, rings, volume and MIDI framing. |
| `src/Service` | IOUSBHost transport, recovery, CoreMIDI and launchd service. |
| `src/IPC` | Mach/XPC setup, authenticated clients and shared-memory ABI. |
| `src/HAL` | Core Audio device, properties, streams and timing. |
| `src/Control` | Hardware DSP parameter model and command encoding. |
| `src/CueMix` | SwiftUI mixer, Core Audio input capture and analysis. |
| `tests` | Portable, sanitizer, synthetic-service and signal-analysis checks. |

The service is `org.cutemix.usbaudio.service`; the app is `org.cutemix.usbaudio.app`; the HAL is `org.cutemix.usbaudio.hal`. The visible device name is **Cute Motu 828x**. Older internal “prototype” identifiers remain stable to preserve existing installations.

Audio travels through bounded shared-memory rings. The HAL validates the mapping and supplies silence on failure. USB transfers drain before their buffers are released. Recovery retries only after cleanup, falls back to the last successful base rate after a high-rate failure and prevents repeated requests for that failed rate during the recovery state.

Mixer changes use acknowledged control commands. EQ, dynamics and reverb execute in the 828x. Signal analysis executes on the Mac, outside the audio callback. Capture callbacks copy into bounded rings; the UI consumes snapshots.

## Build and test

Use full Xcode at `/Applications/Xcode.app`, its command-line tools and Python 3 on Apple silicon. No third-party library is required for the product build.

```sh
bash scripts/build.sh
bash scripts/test.sh
bash scripts/test-prototype.sh
bash scripts/test-ipc-threading.sh
bash scripts/test-volume.sh
bash scripts/test-cuemix.sh
bash scripts/test-analysis.sh
```

`test-prototype.sh` uses an isolated temporary per-user launchd service with a synthetic backend; it does not install a HAL or open the physical interface. The other tests use offline fixtures. These results do not establish physical sample-rate or full-duplex compatibility.

With FFmpeg installed, an independent loudness comparison is available:

```sh
python3 scripts/test-loudness-reference.py
```

It generates temporary audio files, runs the project's loudness engine and FFmpeg's `ebur128` filter, and compares measurements. It does not play audio. Scope/timing tests cover triggering, bounded windows, averaging and hold behavior. The public preview's validation is summarized in [the release notes](RELEASE-0.3.0.md).

## Metering details

Peaks are sample peaks; maximum peaks persist until Reset. RMS uses 400 ms. Stereo LUFS uses BS.1770 K-weighting, 400 ms momentary and 3 s short-term windows. Integrated loudness uses overlapping 400 ms blocks and absolute/relative gating. Measurement history is bounded to 24 hours. This implementation does not claim true-peak measurement, loudness range or EBU certification.

Scope settings and chart averaging do not change the loudness measurement. Freeze holds the display while measurements continue; changing the source or losing input resets measurement state.

## Contributions

Keep real-time callbacks bounded and nonblocking. Never add synchronous IPC, UI calls or heap allocation to audio callbacks. Preserve silent startup, packet/timestamp validation and asynchronous transfer lifetimes. Record live playback, recording and transport-only evidence separately.

The original DriverKit experiment is preserved separately by the maintainer. This public tree contains the current USB/HAL implementation and does not distribute vendor binaries or disassembly.
