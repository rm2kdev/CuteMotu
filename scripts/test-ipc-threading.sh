#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/tests
xcrun clang++ -DOS_OBJECT_USE_OBJC=0 -std=c++17 -fblocks -Wall -Wextra -Werror -g -O1 -fsanitize=thread -Isrc/IPC -Isrc/Core -Isrc/Streaming src/IPC/Client.cpp tests/ipc_tests.cpp -o build/tests/ipc-tsan-tests
build/tests/ipc-tsan-tests
