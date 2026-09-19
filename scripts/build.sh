#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/prototype/objects build/prototype/CuteMixUSB.driver/Contents/MacOS 'build/prototype/Cute Mix USB.app/Contents/MacOS'
common=(-DOS_OBJECT_USE_OBJC=0 -std=c++17 -fblocks -Wall -Wextra -Werror -O2 -g -target arm64-apple-macos13.0 -Isrc/IPC -Isrc/Core -Isrc/Streaming -Isrc/Control -Isrc/Service)
sources=(src/Core/MOTUProtocol.cpp src/Streaming/MOTUStream.cpp src/Control/MOTUDSP.cpp src/IPC/Client.cpp)
for source in "${sources[@]}"; do
  xcrun clang++ "${common[@]}" -c "$source" -o "build/prototype/objects/$(basename "$source" .cpp).o"
done
objects=(build/prototype/objects/MOTUProtocol.o build/prototype/objects/MOTUStream.o build/prototype/objects/MOTUDSP.o build/prototype/objects/Client.o)
xcrun clang++ "${common[@]}" src/Service/main.mm src/Service/USB.mm src/Service/USBDiscovery.mm src/Service/Synthetic.cpp src/Service/MIDI.cpp "${objects[@]}" -framework Foundation -framework IOUSBHost -framework IOKit -framework CoreMIDI -framework SystemConfiguration -o build/prototype/cute-usb-service
xcrun clang++ "${common[@]}" -bundle src/HAL/Plugin.cpp build/prototype/objects/Client.o -framework CoreAudio -framework CoreFoundation -o build/prototype/CuteMixUSB.driver/Contents/MacOS/CuteMixUSB
xcrun clang++ "${common[@]}" src/Probe/service-control.cpp build/prototype/objects/Client.o -framework CoreFoundation -o build/prototype/cute-usb-control
bash scripts/build-app.sh
python3 scripts/write-plists.py
for artifact in build/prototype/cute-usb-service build/prototype/cute-usb-control build/prototype/CuteMixUSB.driver 'build/prototype/Cute Mix USB.app'; do
  codesign --force --sign - "$artifact"
  codesign --verify --strict "$artifact"
done
printf 'Built service, HAL plug-in, control tool and Cute Mix USB app. Nothing installed.\n'
