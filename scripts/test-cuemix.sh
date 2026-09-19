#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/tests/cuemix
for file in src/CueMix/ControlBridge.cpp src/Control/MOTUDSP.cpp src/Core/MOTUProtocol.cpp src/IPC/Client.cpp; do
  xcrun clang++ -std=c++17 -fblocks -O1 -Wall -Wextra -Werror -Isrc/Control -Isrc/Core -Isrc/Streaming -Isrc/IPC -c "$file" -o "build/tests/cuemix/$(basename "$file" .cpp).o"
done
xcrun swiftc -parse-as-library -import-objc-header src/CueMix/ControlBridge.h -framework SwiftUI -framework AppKit -lc++ src/CueMix/HardwareModel.swift src/CueMix/ParameterValue.swift tests/cuemix_model_tests.swift build/tests/cuemix/*.o -o build/tests/cuemix-model-tests
build/tests/cuemix-model-tests
