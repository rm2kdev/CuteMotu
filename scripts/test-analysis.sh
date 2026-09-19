#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -Isrc/CueMix tests/analysis_tests.cpp src/CueMix/AnalysisDSP.cpp -framework Accelerate -o build/tests/analysis-tests
build/tests/analysis-tests
xcrun swiftc -parse-as-library src/CueMix/AnalysisSources.swift tests/analysis_sources_tests.swift -o build/tests/analysis-sources-tests
build/tests/analysis-sources-tests
xcrun swiftc -O -parse-as-library -import-objc-header src/CueMix/AnalysisBridge.h src/CueMix/AnalysisFrame.swift src/CueMix/AnalysisTiming.swift src/CueMix/AnalysisScope.swift tests/analysis_timing_tests.swift -o build/tests/analysis-timing-tests
build/tests/analysis-timing-tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -Isrc/CueMix tests/analysis_meter_tests.cpp src/CueMix/AnalysisMeter.cpp -o build/tests/analysis-meter-tests
build/tests/analysis-meter-tests
xcrun swiftc -O -parse-as-library src/CueMix/AnalysisScope.swift tests/analysis_scope_tests.swift -o build/tests/analysis-scope-tests
build/tests/analysis-scope-tests
