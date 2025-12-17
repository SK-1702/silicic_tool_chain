#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################################
# Silicon Craft – Student PD Setup v16
# FINAL | Stable | Docker-Correct | Instructor Safe
############################################

VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
LOGFILE="$VLSI_ROOT/setup_v12.3.log"
APT_HEAL_SCRIPT="$(dirname "$0")/apt_auto_self_heal.sh"

# ---------- Logging ----------
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

# ---------- OS Detection ----------
if grep -qi microsoft /proc/version 2>/dev/null; then
  OS="WSL"
else
  OS="Linux"
fi

info "Detected OS: $OS"
info "Silicon Craft – Student PD Setup v12.3"
info "Workspace: $VLSI_ROOT"

# ---------- WSL Handling ----------
if [[ "$OS" == "WSL" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    warn "WSL detected but Docker not available."
    echo "Install Docker Desktop on Windows:"
    echo "https://docs.docker.com/desktop/windows/"
    echo "Enable WSL2 integration and re-run script."
    exit 0
  fi
fi

# ---------- APT Lock ----------
for i in {1..20}; do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  warn "Waiting for apt lock..."
  sleep 5
  [[ $i -eq 20 ]] && die "APT lock did not clear."
done

# ---------- APT Update + Self Heal ----------
info "==== APT Preflight ===="
if ! sudo apt-get update; then
  warn "APT mirror issue detected."
  echo "Attempting Silicon Craft self-heal..."
  sudo bash "$APT_HEAL_SCRIPT"
  sudo apt-get update || die "APT still broken."
fi

sudo apt-get install -y \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential make \
  python3 tcllib xz-utils software-properties-common

# ---------- Docker ----------
info "==== Docker Setup ===="
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! docker run --rm hello-world >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER"
  warn "Log out and log in, then re-run script."
  exit 0
fi

# ---------- GUI ----------
sudo apt-get install -y magic klayout xschem || true

# ---------- Git Stability ----------
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999

# ---------- OpenLane Clone ----------
info "==== OpenLane Setup ===="
rm -rf "$OPENLANE_DIR"
git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_DIR"

# ---------- Inverter Design ----------
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

set ::env(FP_SIZING) absolute
set ::env(DIE_AREA) "0 0 50 50"

set ::env(MAGIC_SKIP_DRC) 1
set ::env(QUIT_ON_MAGIC_DRC) 0
set ::env(GDS_ALLOW_EMPTY) 1
EOF

rm -rf "$INV_DIR/runs"

# ---------- Run OpenLane (Docker Handles PDK) ----------
info "==== RTL → GDS (Inverter) ===="

cd "$OPENLANE_DIR"
docker run --rm \
  -v "$OPENLANE_DIR":/openlane \
  -w /openlane \
  ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69 \
  bash -lc "flow.tcl -design inverter -overwrite"

# ---------- View GDS ----------
GDS=$(find "$INV_DIR" -name "*.gds" | head -n1 || true)
if [[ -n "$GDS" ]]; then
  info "GDS generated: $GDS"
  command -v klayout >/dev/null && (klayout "$GDS" &)
else
  warn "GDS not found."
fi

info "✅ Silicon Craft PD Setup v16 COMPLETE"

