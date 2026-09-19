# Installing CuteMotu v0.3.0

> [!WARNING]
> **Experimental software — use entirely at your own risk.**
>
> CuteMotu is provided **“AS IS,” without warranties of any kind**, to the maximum extent permitted by applicable law. It may cause unexpected audio, excessive output levels, crashes, data loss, hearing injury or damage to audio interfaces, computers, speakers, headphones and other equipment.
>
> **To the maximum extent permitted by applicable law, the authors, maintainers, contributors and copyright holders accept no liability or responsibility for any injury, damage, loss or costs arising from installation, use, modification or inability to use this software, including hardware repair or replacement costs.** You are responsible for safe testing, monitoring levels and backups.
>
> Read the [full experimental-use, warranty and liability notice](../DISCLAIMER.md). Statutory rights and liabilities that cannot legally be excluded remain unaffected.

This is an experimental Apple silicon USB driver for the MOTU 828x. Use **48 kHz**, internal clock and ADAT mode for both optical banks for the initial setup. It has not passed full studio acceptance. Thunderbolt is unsupported.

## Before installation

Save your DAW session and hardware mixer settings, close audio applications and Cute Mix, select the Mac's built-in output, and turn your monitor level down. Installation replaces this project's service, HAL and app and interrupts its audio. Keep a copy of your previous working driver/installer.

Only one driver can own the USB interface. Use the existing driver's supported disable/uninstall procedure if needed. If you used the earlier experimental `828x Control` DriverKit project, disable its driver through macOS Driver Extensions and reboot if macOS requests it. The installer refuses handover while `MOTU828xDriver` remains active; it does not remove that driver. Other vendor-driver conflicts also need to be resolved before USB ownership can succeed.

**Keep System Integrity Protection enabled.** CuteMotu does not need you to disable SIP or alter boot security.

## Choose your build

The release ZIP includes complete source and prebuilt `arm64` components under `build/prototype/`. Extract the archive, open Terminal and change into the extracted `CuteMotu-v0.3.0` directory. Python 3 is required by the installation scripts.

The binaries are ad-hoc signed, not Developer ID signed or notarized. A successful local signature check is not Gatekeeper approval: macOS may refuse downloaded components. This preview does not provide a notarized installation path. Build from the included source with full Xcode at `/Applications/Xcode.app` when using the development workflow:

```sh
bash scripts/build.sh
```

Do not disable macOS security features to make a downloaded build load.

## First installation / complete driver update

From the project or extracted release directory, review the exact destinations first:

```sh
python3 scripts/install-local.py --backend usb --hardware-handover
```

When ready for the interruption, install from Terminal:

```sh
sudo python3 scripts/install-local.py --backend usb --hardware-handover --apply
```

The USB flags are required: without them the script defaults to a synthetic test device. The script installs:

| Component | Destination |
| :-- | :-- |
| App | `/Applications/Cute Mix USB.app` |
| HAL | `/Library/Audio/Plug-Ins/HAL/CuteMixUSB.driver` |
| Service and control tool | `/Library/Application Support/Cute Mix USB Audio/` |
| Launch daemon | `/Library/LaunchDaemons/org.cutemix.usbaudio.service.plist` |

**Reboot after the full installation** so Core Audio discovers the HAL. Then select **Cute Motu 828x** in Sound settings, confirm **48,000 Hz** in Audio MIDI Setup, open **Cute Mix USB**, and raise monitoring gradually while checking playback. The installer does not automatically restart Core Audio or reboot.

## Update only Cute Mix

For an already working CuteMotu USB installation, quit Cute Mix and run:

```sh
python3 scripts/update-app.py
sudo python3 scripts/update-app.py --apply
open '/Applications/Cute Mix USB.app'
```

This installs app **0.3.0 / build 10**, keeps a previous-app backup, and leaves the audio service/HAL running. It is not a first-install command.

## Analyze Main L/R

1. In **Overview → Talkback & routing**, select **Main L/R** under **Return to computer**.
2. Open **Analysis**, choose **Stereo Return L** and **Stereo Return R**, and start analysis.
3. Allow the app's microphone permission when macOS asks. Interface input capture uses that permission too.

The return follows hardware routing. The analyzer does not change that route automatically. For the tuner, choose a single instrument input instead of a finished stereo mix.

## If the device does not appear

Check that the cable uses the 828x's USB connection, the interface is powered, and another driver is not claiming it. Confirm the installation completed and the Mac has rebooted. Inspect status:

```sh
'/Library/Application Support/Cute Mix USB Audio/cute-usb-control' status
```

The service log is `/var/log/cutemix-usbaudio.log`. On the tested USB path, 88.2 kHz fails timestamp validation; recovery returns to a safe base rate rather than interpreting bad packets as audio. Avoid high-rate tests for normal use. Keep the connection path and failure log for a bug report.

## Remove CuteMotu

Quit the app, select built-in audio and close DAWs. Preview, then remove only CuteMotu's components:

```sh
python3 scripts/uninstall-local.py
sudo python3 scripts/uninstall-local.py --apply
```

Reboot to unload the HAL. This does not reinstall or activate another driver; use that driver's supported installation process to restore your previous setup.
