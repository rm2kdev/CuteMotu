#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
./scripts/build.sh
./scripts/test.sh
./scripts/test-prototype.sh
./scripts/test-ipc-threading.sh
./scripts/test-volume.sh
./scripts/test-cuemix.sh
./scripts/build-rate-capture.sh
python3 scripts/install-local.py
python3 scripts/uninstall-local.py
