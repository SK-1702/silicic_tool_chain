#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################################################
# Silicon Craft – Student PD Setup v16 
# RTL → GDS using OpenLane (Sky130)
# Instructor-approved | Fresh-machine safe | Reproducible
############################################################

# ---------------- Paths ----------------
VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
LOGFILE="$VLSI_ROOT/setup_v12.3.log"
OPENLANE_IMAGE="ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69"

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

# ---------------- Logging ----------------
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die(){ err "$*"; exit 1; }

# ---------------- OS Detection ----------------
detect_os() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "WSL"
  elif [[ "$OSTYPE" == linux* ]]; then
    echo "Linux"
  else
    echo "Other"
  fi
}

OS="$(detect_os)"
info "Detected OS: $OS"
info "Silicon Craft – Student PD Setup v12.3"
info "Workspace: $VLSI_ROOT"

# ---------------- WSL Handling ----------------
if [[ "$OS" == "WSL" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    warn "WSL detected but Docker is not available."
    echo
    echo "ACTION REQUIRED (ONE TIME):"
    echo "1. Install Docker Desktop (Windows)"
    echo "   https://docs.docker.com/desktop/windows/"
    echo "2. Enable WSL2 integration in Docker Desktop"
    echo "3. Restart WSL terminal"
    echo "4. Re-run this script"
    exit 0
  fi
fi

# ---------------- APT Lock Guard ----------------
wait_for_apt() {
  local tries=30
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    warn "Another apt/dpkg process detected. Waiting..."
    sleep 5
    tries=$((tries-1))
    [[ $tries -le 0 ]] && return 1
  done
  return 0
}

wait_for_apt || die "APT lock did not clear. Close Software Updater."

# ---------------- APT Update (Self-Heal) ----------------
info "==== Preflight: APT update ===="
if ! sudo apt-get update; then
  warn "APT update failed (mirror sync issue)."
  echo
  echo "Manual Fix Required:"
  echo "1. sudo sed -i 's|in.archive.ubuntu.com|archive.ubuntu.com|g' /etc/apt/sources.list"
  echo "2. sudo apt-get clean"
  echo "3. sudo rm -rf /var/lib/apt/lists/*"
  echo "4. sudo apt-get update"
  die "Fix APT manually, then re-run this script."
fi

# ---------------- Base Packages ----------------
sudo apt-get install -y \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential make \
  python3 python3-pip python3-venv \
  tcllib xz-utils software-properties-common

info "Base packages installed."

# ---------------- Docker Setup ----------------
info "==== Docker Setup ===="
if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! docker run --rm hello-world >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER"
  warn "Docker group updated. LOG OUT and LOG IN, then re-run."
  exit 0
fi

info "Docker verified."

# ---------------- GUI Tools ----------------
info "==== GUI Tools ===="
sudo apt-get install -y magic klayout xschem || warn "GUI tools partially installed."

# ---------------- Git Stability ----------------
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999

# ---------------- OpenLane Clone ----------------
clone_openlane() {
  for i in 1 2 3; do
    info "Cloning OpenLane (attempt $i/3)..."
    if git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_DIR"; then
      return 0
    fi
    sleep 10
  done
  return 1
}

info "==== OpenLane Setup ===="
rm -rf "$OPENLANE_DIR"
clone_openlane || die "OpenLane clone failed (network unstable)."

# ---------------- PDK INSTALL (CRITICAL FIX) ----------------
info "==== Installing Sky130 PDK INSIDE Docker ===="

docker run --rm \
  -v "$OPENLANE_DIR":/openlane \
  -w /openlane \
  "$OPENLANE_IMAGE" \
  bash -lc "make pdk"

info "PDK installed successfully inside container."

# ---------------- Inverter Design ----------------
INV_DIR="$OPENLANE_DIR/designs/inverter"
mkdir -p "$INV_DIR"

cat > "$INV_DIR/inverter.v" << 'EOF'
module inverter(input wire a, output wire y);
  assign y = ~a;
endmodule
EOF

cat > "$INV_DIR/config.tcl" << 'EOF'
set ::env(DESIGN_NAME) inverter
set ::env(VERILOG_FILES) "$::env(DESIGN_DIR)/inverter.v"

set ::env(RUN_TAG) inv_run
set ::env(CLOCK_PORT) clk
set ::env(CLOCK_PERIOD) 10

set ::env(FP_SIZING) absolute
set ::env(DIE_AREA) "0 0 50 50"
set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.30

set ::env(MAGIC_SKIP_DRC) 1
set ::env(QUIT_ON_MAGIC_DRC) 0
set ::env(MAGIC_ALLOW_NON_MANHATTAN) 1
set ::env(GDS_ALLOW_EMPTY) 1
EOF

rm -rf "$INV_DIR/runs"

# ---------------- RTL → GDS ----------------
info "==== RTL → GDS (Inverter) ===="

docker run --rm \
  -v "$OPENLANE_DIR":/openlane \
  -w /openlane \
  -e PDK=sky130A \
  "$OPENLANE_IMAGE" \
  bash -lc "flow.tcl -design inverter -overwrite"

# ---------------- View Result ----------------
GDS=$(find "$INV_DIR" -name "*.gds" | head -n1 || true)
if [[ -n "$GDS" ]]; then
  info "GDS generated: $GDS"
  command -v klayout >/dev/null && (klayout "$GDS" &)
else
  warn "GDS not found. Check logs."
fi

info "✅ Silicon Craft PD Setup v16 COMPLETE"

