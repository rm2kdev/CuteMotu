#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/tests
common=(-DOS_OBJECT_USE_OBJC=0 -std=c++17 -fblocks -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -Isrc/IPC -Isrc/Core -Isrc/Streaming -Isrc/Control -Isrc/Service)
xcrun clang++ "${common[@]}" tests/usb_recovery_tests.cpp -o build/tests/usb-recovery-tests
build/tests/usb-recovery-tests
xcrun clang++ "${common[@]}" tests/input_transfer_tests.cpp -o build/tests/input-transfer-tests
build/tests/input-transfer-tests
xcrun clang++ "${common[@]}" tests/zero_timestamp_tests.cpp -o build/tests/zero-timestamp-tests
build/tests/zero-timestamp-tests
xcrun clang++ "${common[@]}" tests/hal_registration_probe.cpp -framework CoreAudio -framework CoreFoundation -o build/tests/hal-registration-probe
build/tests/hal-registration-probe build/prototype/CuteMixUSB.driver/Contents/MacOS/CuteMixUSB
xcrun clang++ "${common[@]}" src/IPC/Client.cpp tests/ipc_tests.cpp -o build/tests/ipc-tests
xcrun clang++ "${common[@]}" -DCUTE_OFFLINE_HARNESS src/IPC/Client.cpp src/HAL/Plugin.cpp tests/hal_tests.cpp -framework CoreAudio -framework CoreFoundation -o build/tests/hal-tests
xcrun clang++ "${common[@]}" tests/lifetime_tests.cpp -o build/tests/lifetime-tests
build/tests/lifetime-tests
xcrun clang++ "${common[@]}" tests/usb_discovery_tests.cpp -o build/tests/usb-discovery-tests
build/tests/usb-discovery-tests
xcrun clang++ "${common[@]}" tests/midi_endpoint_tests.cpp src/Service/MIDI.cpp src/Core/MOTUProtocol.cpp src/Streaming/MOTUStream.cpp -framework CoreMIDI -framework CoreFoundation -o build/tests/midi-endpoint-tests
build/tests/midi-endpoint-tests
xcrun clang++ "${common[@]}" src/Service/main.mm src/Service/Synthetic.cpp src/IPC/Client.cpp src/Core/MOTUProtocol.cpp src/Streaming/MOTUStream.cpp tests/midi_unavailable.cpp -framework Foundation -framework SystemConfiguration -o build/tests/service-midi-unavailable
xcrun clang++ "${common[@]}" src/IPC/Client.cpp tests/service_startup_tests.cpp -o build/tests/service-startup-tests
python3 scripts/offline-session.py
