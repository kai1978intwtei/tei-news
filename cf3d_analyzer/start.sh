#!/usr/bin/env bash
# CF3D Analyzer launcher (Linux/macOS).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
exec python -m cf3d_analyzer "$@"
