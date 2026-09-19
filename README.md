<p align="center"><img src="docs/images/banner.svg" alt="CuteMotu — Keep a great interface making music." width="100%"></p>

<p align="center">
  <a href="https://github.com/rm2kdev/CuteMotu/releases"><img alt="Experimental release" src="https://img.shields.io/badge/release-v0.3.0_preview-54c9b5?style=flat-square"></a>
  <img alt="Apple silicon native" src="https://img.shields.io/badge/Apple_silicon-native_arm64-549ed2?style=flat-square">
  <img alt="MOTU 828x over USB" src="https://img.shields.io/badge/MOTU_828x-USB-9294a7?style=flat-square">
  <a href="https://ko-fi.com/rm2kdev"><img alt="Buy me a coffee on Ko-fi" src="https://img.shields.io/badge/Ko--fi-Buy_me_a_coffee-ff5f5f?style=flat-square"></a>
  <a href="LICENSE"><img alt="GPL version 3" src="https://img.shields.io/badge/license-GPL--3.0-9294a7?style=flat-square"></a>
</p>

<p align="center"><b>A native Mac USB audio driver, hardware mixer and signal-analysis suite for the MOTU 828x.</b><br>Built to give a capable piece of studio hardware a future on Apple silicon.</p>

> [!WARNING]
> **Experimental software — use entirely at your own risk.**
>
> CuteMotu is provided **“AS IS,” without warranties of any kind**, to the maximum extent permitted by applicable law. It may cause unexpected audio, excessive output levels, crashes, data loss, hearing injury or damage to audio interfaces, computers, speakers, headphones and other equipment.
>
> **To the maximum extent permitted by applicable law, the authors, maintainers, contributors and copyright holders accept no liability or responsibility for any injury, damage, loss or costs arising from installation, use, modification or inability to use this software, including hardware repair or replacement costs.** You are responsible for safe testing, monitoring levels and backups.
>
> Read the [full experimental-use, warranty and liability notice](DISCLAIMER.md). Statutory rights and liabilities that cannot legally be excluded remain unaffected.

> [!NOTE]
> **Significant AI use:** OpenAI Codex was used extensively in creating this project, including production driver and app code, signal-analysis tools, debugging, automated tests, documentation and release tooling.

<p align="center"><a href="https://github.com/rm2kdev/CuteMotu/releases/tag/v0.3.0">Download the preview</a> · <a href="docs/INSTALL.md">Installation</a> · <a href="#explore-the-mixer">Mixer gallery</a> · <a href="#six-ways-to-see-your-sound">The instruments</a> · <a href="docs/RELEASE-0.3.0.md">Release notes</a></p>

![Cute Mix connected to a MOTU 828x, showing hardware input controls and eight monitor mixes](docs/images/mixer.jpg)

## A good interface deserves a longer life

The 828x still has useful converters, routing and onboard mixing. Its useful life should not have to follow the life of an Intel application.

Apple is closing that chapter: **macOS Tahoe 26 is the last major macOS release for Intel Macs**, and **macOS 27 is the last release with general-purpose Rosetta support for Intel applications on Apple silicon**. Starting with macOS 28, Apple limits Rosetta to certain older games. These are separate changes: one affects Intel computers, the other affects Intel software running on newer Macs. [Apple’s release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes) · [Apple’s Rosetta guidance](https://support.apple.com/en-us/102527).

CuteMotu is a community-built way forward: an **arm64 USB service, a Core Audio plug-in and a native SwiftUI mixer**, with no Rosetta dependency. It also avoids the restricted DriverKit entitlement needed by the earlier development approach. Audible playback has been confirmed with **System Integrity Protection enabled** on the development Mac.

This is an independent replacement project, not an announcement that every MOTU driver is Intel-only or that MOTU has ended all 828x support. Check MOTU’s current software for your setup. CuteMotu’s aim is a maintainable, open-source USB path and a modern control surface; future macOS compatibility still needs testing.

## Meet Cute Mix

- **Control the real hardware.** Eight stereo monitor mixes, input and output controls, routing, EQ, dynamics, reverb and presets. Mixing and effects use the 828x’s onboard DSP; availability follows the sample rate.
- **Use it as a Mac audio device.** The output appears as **Cute Motu 828x**, with Main L/R first and optional macOS volume control.
- **Inspect what you hear.** Six instruments share selectable input pairs, a stereo return, level readings and correlation.
- **Take your time.** Adjustable chart averaging and hold, millisecond time bases, and Freeze make fast signals easier to read.
- **Keep audio local.** Analysis happens on your Mac. The analyzer does not record or upload audio.

## Explore the mixer

From the input bank to the Main L/R output, Cute Mix exposes the 828x’s hardware controls in a native Mac interface. These screenshots show the connected interface at 48 kHz; enabled and bypassed effects reflect its actual settings.

<table>
<tr>
<td width="50%"><img src="docs/images/inputs.jpg" alt="Cute Mix input bank with trim, phase, EQ, dynamics and reverb sends"><br><b>Inputs.</b> Channel trims, polarity, processing shortcuts and reverb sends, with filters for analog, S/PDIF and ADAT banks.</td>
<td width="50%"><img src="docs/images/outputs.jpg" alt="Cute Mix output bank with active Main L/R meters and hardware processing"><br><b>Outputs.</b> Stereo output meters, EQ and dynamics, plus independent reverb sends and returns.</td>
</tr>
<tr>
<td><img src="docs/images/output-equalizer.jpg" alt="Main L/R seven-band hardware equalizer with draggable points and band controls"><br><b>Seven-band EQ.</b> A response preview, draggable frequency/gain points, filter shapes, bandwidth and per-band bypass.</td>
<td><img src="docs/images/dynamics.jpg" alt="Hardware compressor and optical Leveler controls with gain-reduction meters"><br><b>Compressor &amp; Leveler.</b> Threshold, ratio, attack, release and makeup controls alongside hardware gain-reduction meters.</td>
</tr>
<tr>
<td><img src="docs/images/reverb.jpg" alt="Hardware reverb with output send and return routing and multiband decay preview"><br><b>Reverb.</b> Send/return routing and an illustrative envelope preview for the hardware’s low, mid and high decay times.</td>
<td><img src="docs/images/monitor-mix.jpg" alt="Main L/R direct-monitor mix showing channel faders, pan, mute, solo and output destination"><br><b>Direct monitor mixes.</b> Eight stereo buses with channel faders, pan, mute/solo, destination selection and reverb levels.</td>
</tr>
</table>

<details>
<summary><b>More mixer screenshots: channel settings, reverb controls, routing and device setup</b></summary>

### Channel settings

Name inputs locally, pair channels, select L/R or Mid/Side, adjust stereo width and set the reverb send. Controls are enabled according to the selected channel’s hardware capabilities.

![Input channel settings with stereo pairing, polarity, trim, width and reverb controls](docs/images/channel-settings.jpg)

### Room and multiband decay

Set room shape, size, stereo width, early reflections, pre-delay, decay and the high-frequency shelf. Low/mid/high decay ratios and crossover frequencies shape the reverb tail.

![Reverb room, timing, high-frequency shelf and multiband decay controls](docs/images/reverb-controls.jpg)

### Talkback, listenback and stereo return

Choose talkback/listenback sources and levels, and set **Return to computer** to the output you want to inspect. The screenshot shows **Main L/R**, which feeds the analyzer’s Stereo Return pair.

![Overview with eight monitor mixes, input activity and expanded Talkback and routing controls](docs/images/routing.jpg)

### Device and macOS playback

See the active clock, optical modes, sample rate and channel counts. Optional macOS volume control applies to computer playback on Main L/R; the routing reference explains the Core Audio output order. Sample-rate reliability is documented in [Where it stands](#where-it-stands).

![Device settings showing 48 kHz, internal clock, ADAT optical modes and macOS volume control](docs/images/device.jpg)

</details>

**Presets and workspace:** the header’s **Presets** menu saves and loads mixer/effects settings. **Customize layout** adjusts sidebar and channel-strip widths, footer height and the overview grid. Panel dividers can also be dragged to resize.

Click any screenshot to open it at full size. EQ curves and reverb envelopes are visual previews of the settings, not measured hardware responses.

## Six ways to see your sound

| Instrument | What it gives you |
| :-- | :-- |
| **Tuner** | Note, octave, frequency and cents for monophonic signals, with adjustable concert A. |
| **FFT** | An 8,192-point spectrum, logarithmic frequency axis, stereo traces and peak hold. |
| **X–Y** | Stereo shape, density and persistence, with a 5–200 ms time base. |
| **Phase** | Frequency-dependent phase relationships in rectangular or polar views. |
| **Oscilloscope** | Separate L/R traces, a 1–200 ms time base, selectable trigger channel, edge and level. |
| **Meters** | Sample peak, maximum peak, RMS, and momentary, short-term and gated integrated LUFS. |

<table>
<tr>
<td width="50%"><img src="docs/images/fft.jpg" alt="Live stereo FFT with averaging and peak hold"><br><b>Frequency, in detail.</b> Stereo spectrum with adjustable averaging and hold.</td>
<td width="50%"><img src="docs/images/xy.jpg" alt="Live stereo X-Y density plot"><br><b>The shape of stereo.</b> See width, correlation and polarity.</td>
</tr>
<tr>
<td><img src="docs/images/scope.jpg" alt="Live stereo oscilloscope with a 20 millisecond window"><br><b>Down to the waveform.</b> Triggered traces with a millisecond time base.</td>
<td><img src="docs/images/meters.jpg" alt="Live peak RMS and LUFS metering"><br><b>Level meets loudness.</b> Peak, RMS and three LUFS measurements together.</td>
</tr>
</table>

<details>
<summary><b>More screenshots: phase and tuner</b></summary>

![Live rectangular phase analysis](docs/images/phase.jpg)
![Tuner displaying a generated test tone](docs/images/tuner.jpg)

</details>

The mixer, FFT, X–Y, phase, scope and meter screenshots show the app connected to a real 828x at 48 kHz. The tuner screenshot uses an offline test signal. Click any image for a closer look.

**Analyze the main output:** in **Overview → Talkback & routing**, set **Return to computer → Main L/R**. In **Analysis**, select **Stereo Return L / R**, then **Start analysis**. Allow microphone access when macOS asks; it also covers interface input capture.

## Where it stands

**v0.3.0 is an experimental developer preview. Start at 48 kHz.** It is not yet a signed, notarized, plug-and-play replacement for every studio.

| Area | Current evidence / limitation |
| :-- | :-- |
| Hardware | MOTU **828x over USB**. Thunderbolt and other MOTU models are outside this release. |
| Mac | Native **Apple silicon** only. Built for macOS 13+, physically tested on macOS **26.5.1**; older targets and macOS 27/28 are unverified. |
| SIP | Enabled during confirmed playback on the development Mac. No script changes security settings. |
| 48 kHz | Audible playback, live input/return analysis and mixer operation confirmed. |
| 44.1 kHz | Implemented and exercised during development; extended full-duplex acceptance remains incomplete. |
| 88.2 kHz | **Known failure on the tested USB path.** Recovery falls back to a safe rate and blocks repeated requests for the failed rate during that recovery state. |
| 96 / 176.4 / 192 kHz | Experimental profiles; offline coverage is not a physical compatibility claim. |
| MIDI | Code and virtual tests exist. Physical DIN is unverified; installed-daemon CoreMIDI initialization has failed on the test machine. |
| Metering | Sample peaks, not inter-sample true peaks. No loudness range or broadcast certification. |
| Distribution | Ad-hoc signed; **not Developer ID signed or notarized**. Downloaded binaries may be blocked by macOS. Building locally is the development path. |

Long recording sessions, sleep/wake, different USB controllers, digital I/O and reliable high-rate operation still need hardware testing. See [the release notes](docs/RELEASE-0.3.0.md) for the validation boundary.

## Get started

Download **CuteMotu-v0.3.0-macos-arm64.zip** from [Releases](https://github.com/rm2kdev/CuteMotu/releases/tag/v0.3.0). It contains the app, service, HAL plug-in, command-line tool, installer scripts **and corresponding source**. Read [Installation](docs/INSTALL.md) before changing your audio setup; dragging the app into Applications does not install the driver.

To build from source, install full Xcode at `/Applications/Xcode.app` and Python 3, then:

```sh
git clone https://github.com/rm2kdev/CuteMotu.git
cd CuteMotu
git checkout v0.3.0
bash scripts/build.sh
```

The build creates `build/prototype/` and installs nothing. The installation guide covers first installation, an app-only update and removal. Keep SIP enabled.

## Under the hood

```mermaid
flowchart LR
    A[Mac audio apps] <--> B[Core Audio HAL]
    B <-->|Shared audio rings| C[Native USB service]
    C <-->|USB| D[MOTU 828x]
    E[Cute Mix] <-->|Mixer controls| C
    B -->|Selected input pair| F[Signal analysis]
    F --> E
```

The service owns USB transport. The HAL publishes the audio device. Bounded shared-memory rings keep UI work and synchronous control calls out of audio callbacks. Cute Mix controls the device’s hardware DSP and computes its analysis displays on the Mac. [Architecture and development](docs/DEVELOPMENT.md) · [Protocol notes](docs/PROTOCOL.md).

## Buy me a coffee

If this project saved you a few thousand on a new interface, [buy me a coffee on Ko-fi](https://ko-fi.com/rm2kdev). ☕

## Help keep the 828x useful

Reports from other Macs, USB adapters and DAWs are welcome. Include your macOS version, Mac chip, connection path, sample rate and reproducible steps. Separate “the device appeared” from actual playback/recording results. Please remove serial numbers and personal information from diagnostic logs before opening an [issue](https://github.com/rm2kdev/CuteMotu/issues).

Licensed under [GNU GPL v3](LICENSE). This project is not affiliated with or endorsed by MOTU or Apple. Product names identify compatible hardware and platforms; no vendor driver binary or firmware is included.
