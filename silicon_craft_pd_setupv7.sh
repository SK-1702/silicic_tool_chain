#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft – Student PD Setup (v7 FINAL)
##############################################

### -------- CONFIG --------
VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
OPENLANE_IMAGE="ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69"
LOGFILE="$VLSI_ROOT/setup.log"
INVERTER_DIR="$OPENLANE_DIR/designs/inverter"

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

### -------- LOGGING --------
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERROR]\033[0m $*"; }
die(){ err "$*"; exit 1; }

### -------- OS CHECK --------
detect_os() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "WSL"
  else
    echo "Linux"
  fi
}

OS=$(detect_os)
info "Detected OS: $OS"

### -------- APT LOCK HANDLER --------
wait_for_apt_lock() {
  local waited=0
  local timeout=600

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "APT is busy (auto-updates). Waiting..."
    fi

    sleep 10
    waited=$((waited+10))

    if (( waited == 120 )); then
      warn "Stopping background apt services (safe)..."
      sudo systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    fi

    if (( waited >= timeout )); then
      die "APT lock still held. Reboot system and rerun script."
    fi
  done
}

### -------- PRE-REQS --------
install_prereqs() {
  info "Installing base packages"
  wait_for_apt_lock
  sudo apt-get update -y

  wait_for_apt_lock
  sudo apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential make \
    python3 python3-pip python3-venv tcllib xz-utils
}

### -------- DOCKER --------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed"
    return
  fi

  info "Installing Docker"
  curl -fsSL https://get.docker.com | sudo sh

  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER" || true
}

select_docker_cmd() {
  if docker ps >/dev/null 2>&1; then
    DOCKER_CMD="docker"
  elif sudo docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo docker"
    warn "Docker group not active yet – using sudo docker"
  else
    die "Docker daemon not accessible"
  fi
}

check_docker() {
  info "Checking Docker integrity"
  $DOCKER_CMD run --rm hello-world >/dev/null 2>&1 \
    || die "Docker cannot run containers"
}

### -------- GUI TOOLS --------
install_gui_tools() {
  info "Installing GUI tools (Magic / KLayout / xschem)"
  wait_for_apt_lock
  sudo apt-get install -y magic klayout xschem || warn "GUI tools optional"
}

### -------- OPENLANE --------
setup_openlane() {
  info "Setting up OpenLane"

  if [[ ! -d "$OPENLANE_DIR" ]]; then
    git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_DIR"
  fi

  cd "$OPENLANE_DIR"
  export PDK_ROOT="$OPENLANE_DIR/pdks"
  export PDK="sky130A"

  export DOCKER="$DOCKER_CMD"
  make || die "OpenLane make failed"
}

pull_openlane_image() {
  info "Ensuring OpenLane Docker image"
  $DOCKER_CMD pull "$OPENLANE_IMAGE" || warn "Image may already exist"
}

### -------- SAMPLE DESIGN --------
prepare_inverter() {
  mkdir -p "$INVERTER_DIR"

  cat > "$INVERTER_DIR/inverter.v" <<EOF
module inverter(input a, output y);
  assign y = ~a;
endmodule
EOF

  cat > "$INVERTER_DIR/config.tcl" <<EOF
set ::env(DESIGN_NAME) inverter
set ::env(VERILOG_FILES) "\$::env(DESIGN_DIR)/inverter.v"
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_PERIOD) 10
set ::env(FP_SIZING) absolute
set ::env(DIE_AREA) "0 0 50 50"
set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.30
EOF
}

run_inverter() {
  info "Running OpenLane inverter demo"

  $DOCKER_CMD run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$OPENLANE_DIR:/openlane" \
    -e PDK_ROOT=/openlane/pdks \
    -e PDK=sky130A \
    -w /openlane \
    "$OPENLANE_IMAGE" \
    flow.tcl -design inverter -overwrite \
    | tee -a "$LOGFILE"
}

open_gds() {
  local gds
  gds=$(find "$INVERTER_DIR" -name "*.gds" | head -n1 || true)

  if [[ -n "$gds" && $(command -v klayout) ]]; then
    info "Opening GDS in KLayout"
    klayout "$gds" >/dev/null 2>&1 &
  fi
}

### -------- MAIN --------
main() {
  info "Silicon Craft – Student PD Setup v7"
  info "Workspace: $VLSI_ROOT"

  install_prereqs
  install_docker
  select_docker_cmd
  check_docker
  install_gui_tools
  setup_openlane
  pull_openlane_image
  prepare_inverter
  run_inverter
  open_gds

  info "✅ Setup complete. Ready for RTL → GDS flows."
}

main

