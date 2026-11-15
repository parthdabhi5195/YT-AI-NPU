#!/usr/bin/env bash
# =============================================================================
# One-Command RTL-to-GDSII SkyWater SKY130 Silicon Tapeout Runner
# (`run_silicon_flow.sh`)
# Supports:
#   1. Native OpenLane 2 (`openlane` CLI on macOS / Linux via Nix)
#   2. Dockerized OpenLane 2 (`ghcr.io/efabless/openlane2:latest`)
#   3. Always generates physical GDSII floorplan, SVG die map & 3D-printable STL!
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ASIC_DIR="${ROOT_DIR}/asic"
OUT_DIR="${ASIC_DIR}/output"

mkdir -p "${OUT_DIR}"

echo "======================================================================"
echo " [1/2] Generating Physical GDSII Floorplan, Die SVG & 3D Silicon STL"
echo "======================================================================"
python3 "${SCRIPT_DIR}/export_3d_silicon.py"

echo ""
echo "======================================================================"
echo " [2/2] Checking OpenLane 2 / Yosys SKY130 Signoff Tapeout Toolchain"
echo "======================================================================"
if command -v openlane >/dev/null 2>&1; then
    echo "[OpenLane 2] Found native OpenLane 2 — running full SKY130 RTL-to-GDSII..."
    openlane "${ASIC_DIR}/openlane/config.json"
elif command -v docker >/dev/null 2>&1; then
    echo "[OpenLane 2] Running SKY130 RTL-to-GDSII inside ghcr.io/efabless/openlane2..."
    docker run --rm \
        -v "${ROOT_DIR}:/work" \
        -w /work/asic/openlane \
        ghcr.io/efabless/openlane2:latest \
        openlane /work/asic/openlane/config.json
else
    echo "[Info] Neither 'openlane' (Nix) nor 'docker' was detected in PATH."
    echo "       Pre-placed SKY130 GDSII, Die SVG, and 3D STL models are ready in:"
    echo "       ${OUT_DIR}/"
    echo "       To run full standard-cell PnR + DRC/LVS signoff on macOS:"
    echo "         brew install --cask docker   # then re-run ./asic/scripts/run_silicon_flow.sh"
fi
