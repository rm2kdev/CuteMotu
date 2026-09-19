#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/prototype/objects 'build/prototype/Cute Mix USB.app/Contents/MacOS'
common=(-DOS_OBJECT_USE_OBJC=0 -std=c++17 -fblocks -Wall -Wextra -Werror -O2 -g -target arm64-apple-macos13.0 -Isrc/IPC -Isrc/Core -Isrc/Streaming -Isrc/Control)
for source in src/Core/MOTUProtocol.cpp src/Control/MOTUDSP.cpp src/IPC/Client.cpp src/CueMix/ControlBridge.cpp src/CueMix/AnalysisCapture.cpp src/CueMix/AnalysisDSP.cpp src/CueMix/AnalysisMeter.cpp; do
  xcrun clang++ "${common[@]}" -c "$source" -o "build/prototype/objects/$(basename "$source" .cpp).o"
done
xcrun swiftc -parse-as-library -O -target arm64-apple-macos13.0 -import-objc-header src/CueMix/ControlBridge.h -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework AVFoundation -lc++ src/CueMix/*.swift build/prototype/objects/ControlBridge.o build/prototype/objects/Client.o build/prototype/objects/MOTUDSP.o build/prototype/objects/MOTUProtocol.o build/prototype/objects/AnalysisCapture.o build/prototype/objects/AnalysisDSP.o build/prototype/objects/AnalysisMeter.o -o 'build/prototype/Cute Mix USB.app/Contents/MacOS/Cute Mix USB'
python3 scripts/write-plists.py --app-only
codesign --force --sign - 'build/prototype/Cute Mix USB.app'
codesign --verify --strict 'build/prototype/Cute Mix USB.app'
printf 'Built Cute Mix USB with signal analysis. Service and HAL unchanged. Nothing installed.\n'
