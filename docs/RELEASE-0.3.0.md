# CuteMotu v0.3.0 — Native audio, modern instruments

> [!WARNING]
> **Experimental software — use entirely at your own risk.**
>
> CuteMotu is provided **“AS IS,” without warranties of any kind**, to the maximum extent permitted by applicable law. It may cause unexpected audio, excessive output levels, crashes, data loss, hearing injury or damage to audio interfaces, computers, speakers, headphones and other equipment.
>
> **To the maximum extent permitted by applicable law, the authors, maintainers, contributors and copyright holders accept no liability or responsibility for any injury, damage, loss or costs arising from installation, use, modification or inability to use this software, including hardware repair or replacement costs.** You are responsible for safe testing, monitoring levels and backups.
>
> Read the [full experimental-use, warranty and liability notice](../DISCLAIMER.md). Statutory rights and liabilities that cannot legally be excluded remain unaffected.

**Experimental developer preview · Apple silicon · MOTU 828x USB**

This first public release combines the USB audio service, Core Audio HAL and native Cute Mix app. Start at **48 kHz**. The package is ad-hoc signed and **not notarized**; it is intended for development and testing, with a local source-build path.

## Included

- Native arm64 USB service, Core Audio input/output device and control utility.
- **Cute Mix USB 0.3.0 / build 10**: hardware mixing, routing, EQ, dynamics, reverb, presets and six analysis instruments.
- Tuner, stereo FFT, X–Y and phase plots with adjustable averaging, persistence and Freeze.
- Stereo oscilloscope with 1–200 ms time base and trigger controls.
- Sample peak, maximum peak, RMS, momentary / short-term / gated integrated LUFS.
- **HAL 0.1.6 / build 7**, publishing the output as **Cute Motu 828x**.
- Safe-rate recovery after USB faults, packet validation, silent startup and callback draining.
- Installer, app updater and uninstaller; complete corresponding source; GPL-3.0 license.

The service has no independent embedded version number. `RELEASE-MANIFEST.json` records the source commit and hashes of every packaged component. The release tag versions the complete set, while app and HAL versions remain independent.

## Download and install

Use `CuteMotu-v0.3.0-macos-arm64.zip`. Verify its hash against `SHA256SUMS.txt`:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Extract the archive and read [Installation](INSTALL.md). A full install requires administrator authentication and a reboot for Core Audio discovery. An existing working CuteMotu USB installation can use the app-only updater without restarting audio. Python 3 is required; building locally also requires full Xcode.

The ZIP includes source at the exact release commit alongside `build/prototype/` binaries. GitHub's automatic source archives do not include those binaries.

## Validation

The complete release source builds with warnings treated as errors and passes strict local code-signature verification. These checks passed during release preparation:

- Protocol, streaming, DSP and exhaustive shutdown scheduling tests with AddressSanitizer / UndefinedBehaviorSanitizer.
- Synthetic-service IPC and HAL host tests: all six format profiles, delayed publication, disconnect silence and reconnect.
- ThreadSanitizer IPC/ring and playback-volume checks.
- Mixer model, preset, range, meter and readback checks.
- Analysis DSP, ring, source mapping, timing, meter and scope checks.
- **12 independent FFmpeg loudness comparisons**, across all six sample-rate profiles; maximum difference below **0.075 LU** for the tested fixtures.

Physical evidence is narrower: audible SIP-enabled playback was confirmed by the developer on an Apple silicon Mac running macOS 26.5.1. Live input/return capture and the mixer are working at 48 kHz. The README's spectrum, X–Y, phase, scope and loudness screenshots were captured from the installed build 10 app using real stereo-return audio. These observations do not establish long-session recording reliability or calibrated loudness accuracy on every system.

## Known limitations

- **88.2 kHz fails on the tested USB path.** Recovery returns to a safe base rate and suppresses repeated requests for that failed rate during the recovery state. Use 48 kHz for this preview.
- 44.1 kHz and high-rate full-duplex acceptance remain incomplete. 96, 176.4 and 192 kHz are experimental profiles, not verified hardware support.
- Physical DIN MIDI and digital loopback are unverified. CoreMIDI endpoint initialization has failed in the installed root daemon; audio continues without MIDI.
- Sleep/wake, different USB controllers and sustained recording need further testing.
- USB only; no Thunderbolt path, Intel build or compatibility claim for other MOTU models.
- macOS 13 is the compilation target, not a tested OS matrix. macOS 27 and 28 are unverified.
- Metering is sample peak, not true peak; no loudness-range measurement or broadcast certification.
- Ad-hoc signatures are not Developer ID signatures. macOS may block downloaded components. This release does not change security settings or provide a notarized installer.

Please include reproducible steps, Mac/macOS version, sample rate and USB connection path when reporting an issue. Remove personal identifiers from logs.
