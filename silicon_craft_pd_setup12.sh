#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft – Student PD Setup v11.1
# Stable • Safe • Industry-correct
##############################################

VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
LOGFILE="$VLSI_ROOT/setup.log"
OPENLANE_IMAGE="ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69"

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

##############################################
# OS DETECTION
##############################################
detect_os() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "WSL"
  else
    echo "LINUX"
  fi
}

OS="$(detect_os)"
info "Detected OS: $OS"
info "Silicon Craft – Student PD Setup v11.1"
info "Workspace: $VLSI_ROOT"

##############################################
# APT LOCK CHECK
##############################################
wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "Another apt/dpkg process is running (Ubuntu auto-updates)."
      warn "Waiting up to 2 minutes..."
    fi
    sleep 10
    waited=$((waited+10))
    if (( waited >= 120 )); then
      err "apt is still locked."
      echo
      echo "Please do ONE of the following:"
      echo "  Option 1 (recommended): Wait 2–3 minutes and rerun the script"
      echo "  Option 2 (advanced):"
      echo "    sudo systemctl stop apt-daily.service apt-daily-upgrade.service"
      echo
      echo "Then rerun:"
      echo "  ./silicon_craft_pd_setupv11.1.sh"
      exit 1
    fi
  done
}

##############################################
# APT UPDATE (SAFE)
##############################################
safe_apt_update() {
  if ! sudo apt-get update; then
    err "apt-get update failed due to broken repository or mirror sync."
    echo
    echo "This is NOT a Silicon Craft or OpenLane issue."
    echo
    echo "Please fix manually:"
    echo "  1) Identify broken repo (shown above)"
    echo "  2) Remove it, e.g.:"
    echo "       sudo add-apt-repository --remove ppa:<broken-ppa>"
    echo "  3) Run:"
    echo "       sudo apt-get update"
    echo
    echo "After update succeeds, rerun this script."
    exit 1
  fi
}

##############################################
# BASE PACKAGES
##############################################
info "==== Preflight: Installing base packages (apt) ===="
wait_for_apt
safe_apt_update

sudo apt-get install -y \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential make python3 python3-pip python3-venv \
  tcllib xz-utils software-properties-common

info "Base tools installed/verified."

##############################################
# DOCKER HANDLING
##############################################
info "==== Docker Setup ===="

if [[ "$OS" == "WSL" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker not found inside WSL."
    echo
    echo "WSL REQUIREMENT:"
    echo "  1) Install Docker Desktop on Windows"
    echo "  2) Enable WSL integration for your distro"
    echo "Docs:"
    echo "  https://docs.docker.com/desktop/wsl/"
    echo
    echo "After Docker Desktop is running, rerun this script."
    exit 1
  fi
else
  if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    warn "Log out & log back in if docker permission fails."
  fi
fi

# Docker sanity
if docker run --rm hello-world >/dev/null 2>&1; then
  info "Docker is working."
else
  err "Docker cannot run containers."
  echo
  echo "Fix steps:"
  echo "  sudo systemctl enable --now docker"
  echo "  sudo usermod -aG docker \$USER"
  echo "  logout/login and retry"
  exit 1
fi

##############################################
# GUI TOOLS
##############################################
info "==== GUI Tools (best-effort) ===="
sudo apt-get install -y magic klayout xschem || warn "GUI tools partially installed."

##############################################
# OPENLANE SETUP
##############################################
info "==== OpenLane Setup ===="

if [[ ! -d "$OPENLANE_DIR" ]]; then
  git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_DIR"
fi

cd "$OPENLANE_DIR"
export PDK_ROOT="$OPENLANE_DIR/pdks"
export PDK="sky130A"

make

##############################################
# INVERTER DESIGN (STABLE)
##############################################
INV_DIR="$OPENLANE_DIR/designs/inverter"
rm -rf "$INV_DIR/runs" || true
mkdir -p "$INV_DIR"

cat > "$INV_DIR/inverter.v" <<EOF
module inverter(input wire a, output wire y);
  assign y = ~a;
endmodule
EOF

cat > "$INV_DIR/config.tcl" <<EOF
set ::env(DESIGN_NAME) inverter
set ::env(VERILOG_FILES) "\$::env(DESIGN_DIR)/inverter.v"
set ::env(RUN_TAG) inv_run
set ::env(CLOCK_PORT) clk
set ::env(CLOCK_PERIOD) 10
set ::env(FP_SIZING) absolute
set ::env(DIE_AREA) "0 0 50 50"
set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.3
set ::env(MAGIC_SKIP_DRC) 1
set ::env(QUIT_ON_MAGIC_DRC) 0
set ::env(GDS_ALLOW_EMPTY) 1
EOF

##############################################
# RUN FLOW
##############################################
info "==== Running OpenLane Inverter Flow ===="

docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "$OPENLANE_DIR:/openlane" \
  -w /openlane \
  -e PDK_ROOT=/openlane/pdks \
  -e PDK=sky130A \
  "$OPENLANE_IMAGE" \
  bash -lc "flow.tcl -design inverter -overwrite" \
  | tee -a "$LOGFILE"

##############################################
# DONE
##############################################
info "==== Setup Completed ===="
info "Check GDS under:"
info "  $INV_DIR/runs/inv_run/results/final/gds"

