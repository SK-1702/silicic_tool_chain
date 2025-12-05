#!/usr/bin/env bash

set -e

##############################################
#  Silicon Craft VLSI RTL2GDS Setup Script
#  Option A: Docker-Based Only
#  OS-aware | Idempotent | Auto-Test
##############################################

VLSI_ROOT="$HOME/Silicon_Craft_tool_setup"
OPENLANE_IMAGE="ghcr.io/efabless/openlane:latest"
LOGFILE="$VLSI_ROOT/openlane_inverter_test.log"

echo ""
echo "==============================================="
echo " Silicon Craft RTL2GDS Environment Setup Script"
echo "==============================================="
echo ""

##############################################
# Detect OS
##############################################
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if grep -i microsoft /proc/version >/dev/null 2>&1; then
            echo "WSL"
        else
            echo "Linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS"
    else
        echo "Unsupported"
    fi
}

OS=$(detect_os)
echo "[INFO] Detected OS: $OS"
echo ""

if [[ "$OS" == "Unsupported" ]]; then
    echo "[ERROR] Your OS is not supported by this script."
    exit 1
fi


##############################################
# Check + Install Docker
##############################################
check_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "[INFO] Docker is already installed."
        return 0
    else
        return 1
    fi
}

install_docker_linux() {
    echo "[INFO] Installing Docker for Linux..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    echo "[INFO] Docker installed. Please log out and log in again if group change doesn't apply."
}

install_docker_mac() {
    echo "[INFO] Docker Desktop is required on macOS."
    echo "[INFO] Download from: https://www.docker.com/products/docker-desktop/"
    echo "[INFO] Install it and re-run this script."
    exit 1
}

echo "-----------------------------------------------"
echo "[STEP 1] Docker Setup"
echo "-----------------------------------------------"

if check_docker; then
    echo "[INFO] Docker OK."
else
    if [[ "$OS" == "macOS" ]]; then
        install_docker_mac
    else
        install_docker_linux
    fi
fi

echo ""


##############################################
# Test Docker
##############################################
echo "[INFO] Testing Docker..."
if ! docker run --rm hello-world >/dev/null 2>&1; then
    echo "[ERROR] Docker test failed. Fix Docker installation."
    exit 1
fi
echo "[INFO] Docker test OK."
echo ""


##############################################
# Pull OpenLane Docker Image
##############################################
echo "-----------------------------------------------"
echo "[STEP 2] Pulling OpenLane Docker Image"
echo "-----------------------------------------------"

if docker image inspect "$OPENLANE_IMAGE" >/dev/null 2>&1; then
    echo "[INFO] OpenLane image already present. Skipping pull."
else
    echo "[INFO] Pulling OpenLane image..."
    docker pull "$OPENLANE_IMAGE"
fi

echo ""


##############################################
# Create Directory Structure
##############################################
echo "-----------------------------------------------"
echo "[STEP 3] Creating Directory Structure"
echo "-----------------------------------------------"

mkdir -p "$VLSI_ROOT/OpenLane/designs/inverter"
mkdir -p "$VLSI_ROOT/pdks"

echo "[INFO] Base directories created under $VLSI_ROOT"
echo ""


##############################################
# Prepare Inverter Test Design
##############################################
cat > "$VLSI_ROOT/OpenLane/designs/inverter/config.json" <<EOF
{
    "DESIGN_NAME": "inverter",
    "VERILOG_FILES": "dir::inverter.v",
    "CLOCK_PERIOD": 10
}
EOF

cat > "$VLSI_ROOT/OpenLane/designs/inverter/inverter.v" <<EOF
module inverter (
    input  wire a,
    output wire y
);
assign y = ~a;
endmodule
EOF

echo "[INFO] Inverter test design prepared."
echo ""


##############################################
# Run OpenLane Inverter Test
##############################################
echo "-----------------------------------------------"
echo "[STEP 4] Running OpenLane Inverter Flow"
echo "-----------------------------------------------"
echo ""

echo "[INFO] Running OpenLane inverter test... (this may take 5–10 min)"

docker run --rm -u $(id -u):$(id -g) \
    -v "$VLSI_ROOT/OpenLane/designs":/openlane/designs \
    -v "$VLSI_ROOT/pdks":/openlane/pdks \
    "$OPENLANE_IMAGE" \
    flow.tcl -design inverter -overwrite | tee "$LOGFILE"

if grep -q "Flow complete" "$LOGFILE"; then
    echo ""
    echo "==============================================="
    echo "[SUCCESS] OpenLane inverter flow completed!"
    echo "Log file: $LOGFILE"
    echo "==============================================="
else
    echo ""
    echo "==============================================="
    echo "[ERROR] OpenLane inverter test FAILED."
    echo "Check log file: $LOGFILE"
    echo "==============================================="
    exit 1
fi


echo ""
echo "[INFO] Silicon Craft OpenLane environment setup completed successfully!"
echo ""

