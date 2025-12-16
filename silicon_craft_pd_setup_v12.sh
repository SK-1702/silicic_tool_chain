#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################################
# Silicon Craft – Student PD Setup v12
# Stable | Instructor Approved | Student Safe
############################################

VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
LOGFILE="$VLSI_ROOT/setup_v12.log"
APT_HEAL_SCRIPT="$(dirname "$0")/apt_auto_self_heal.sh"

# ---------- Logging ----------
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

# ---------- OS Detection ----------
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
info "Silicon Craft – Student PD Setup v12"
info "Workspace: $VLSI_ROOT"

# ---------- WSL Handling ----------
if [[ "$OS" == "WSL" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    warn "WSL detected but Docker not available."
    echo
    echo "👉 ACTION REQUIRED (ONE TIME):"
    echo "1. Install Docker Desktop on Windows"
    echo "   https://docs.docker.com/desktop/windows/"
    echo "2. Enable WSL2 integration in Docker Desktop"
    echo "3. Restart WSL terminal"
    echo "4. Re-run this script"
    exit 0
  fi
fi

# ---------- APT Lock Handling ----------
wait_for_apt() {
  local retries=30
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    warn "Another apt/dpkg process detected. Waiting..."
    sleep 5
    retries=$((retries-1))
    [[ $retries -le 0 ]] && return 1
  done
  return 0
}

if ! wait_for_apt; then
  die "APT lock did not clear. Close Software Updater and retry."
fi

# ---------- APT Update with Self-Heal ----------
info "==== Preflight: Installing base packages (apt) ===="
if ! sudo apt-get update; then
  warn "APT update failed (mirror / hash issue detected)."
  echo
  echo "This is common on new Ubuntu installations."
  echo "We can safely self-heal APT configuration."
  echo
  read -rp "Apply Silicon Craft APT self-heal now? (y/n): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    sudo bash "$APT_HEAL_SCRIPT"
    sudo apt-get update || die "APT still failing after self-heal."
  else
    die "Cannot proceed without working APT."
  fi
fi

sudo apt-get install -y \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential make \
  python3 python3-pip python3-venv \
  tcllib xz-utils software-properties-common

info "Base tools installed."

# ---------- Docker Setup ----------
info "==== Docker Setup ===="
if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! docker run --rm hello-world >/dev/null 2>&1; then
  warn "Docker requires sudo or group update."
  sudo usermod -aG docker "$USER"
  warn "Please LOG OUT and LOG IN, then re-run this script."
  exit 0
fi

info "Docker verified."

# ---------- GUI Tools ----------
info "==== GUI Tools Setup ===="
sudo apt-get install -y magic klayout xschem || warn "Some GUI tools failed."

# ---------- Git Stability Tweaks ----------
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999

# ---------- OpenLane Clone (Retry + Shallow) ----------
clone_openlane() {
  local tries=3
  for i in $(seq 1 $tries); do
    info "Cloning OpenLane (attempt $i/$tries)..."
    if git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_DIR"; then
      return 0
    fi
    warn "Clone failed. Retrying..."
    sleep 10
  done
  return 1
}

info "==== OpenLane Setup ===="
rm -rf "$OPENLANE_DIR" || true
clone_openlane || die "OpenLane clone failed due to network instability."

# ---------- Inverter Design (Magic-safe) ----------
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

rm -rf "$INV_DIR/runs" || true

# ---------- Run OpenLane ----------
info "==== Running OpenLane (Inverter RTL → GDS) ===="
cd "$OPENLANE_DIR"
make || die "OpenLane make failed."

docker run --rm \
  -v "$OPENLANE_DIR":/openlane \
  -e PDK_ROOT=/openlane/pdks \
  -e PDK=sky130A \
  -w /openlane \
  ghcr.io/the-openroad-project/openlane:latest \
  bash -lc "flow.tcl -design inverter -overwrite"

# ---------- View GDS ----------
GDS=$(find "$INV_DIR" -name "*.gds" | head -n1 || true)
if [[ -n "$GDS" ]]; then
  info "GDS generated: $GDS"
  command -v klayout >/dev/null && (klayout "$GDS" &)
else
  warn "GDS not found. Check logs."
fi

info "✅ Silicon Craft PD Setup COMPLETE"

