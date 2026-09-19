#!/bin/bash
# A separate app, fixture-only. Never opens an input or plays a test signal.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
preview_dir='build/Analysis Preview.app'
mkdir -p "$preview_dir/Contents/MacOS"
sources=()
for file in src/CueMix/*.swift; do
  if [[ "$file" != src/CueMix/CueMixApp.swift ]]; then sources+=("$file"); fi
done
xcrun swiftc -parse-as-library -O -DANALYSIS_PREVIEW -target arm64-apple-macos13.0 -import-objc-header src/CueMix/ControlBridge.h -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework AVFoundation -lc++ "${sources[@]}" tests/analysis_preview.swift build/prototype/objects/ControlBridge.o build/prototype/objects/Client.o build/prototype/objects/MOTUDSP.o build/prototype/objects/MOTUProtocol.o build/prototype/objects/AnalysisCapture.o build/prototype/objects/AnalysisDSP.o build/prototype/objects/AnalysisMeter.o -o "$preview_dir/Contents/MacOS/Analysis Preview"
python3 - <<'PY'
import pathlib, plistlib
pathlib.Path('build/Analysis Preview.app/Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.cutemix.analysis.preview', CFBundleName='Analysis Preview', CFBundleExecutable='Analysis Preview', CFBundlePackageType='APPL', LSMinimumSystemVersion='13.0')))
PY
codesign --force --sign - "$preview_dir"
open "$preview_dir"
