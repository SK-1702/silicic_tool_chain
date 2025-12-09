#!/usr/bin/env bash
set -euo pipefail

########################################
# Simple logging helpers
########################################
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

########################################
# Paths / constants
########################################
VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
LOGFILE="$VLSI_ROOT/setup.log"

# Official OpenROAD/OpenLane repo + pinned image (same as your run_openlane.sh)
OPENLANE_REPO_URL="https://github.com/The-OpenROAD-Project/OpenLane.git"
OPENLANE_IMAGE="ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69"

OS_KIND="Linux"

########################################
# Detect OS / WSL
########################################
detect_os() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    OS_KIND="WSL"
  else
    OS_KIND="$(lsb_release -si 2>/dev/null || echo "Linux")"
  fi
  info "Detected OS: $OS_KIND"
}

########################################
# Preflight apt install
########################################
preflight_prereqs() {
  info "==== Preflight: Installing base packages (apt) ===="

  mkdir -p "$VLSI_ROOT"
  : > "$LOGFILE"

  sudo apt-get update -y >>"$LOGFILE" 2>&1

  # Core build + Python + tools
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential make cmake \
    python3 python3-pip python3-venv python3-dev \
    xz-utils \
    >>"$LOGFILE" 2>&1

  info "Base tools installed/verified."

  # GUI tools (for viewing layouts)
  info "==== GUI Tools Setup (Magic / KLayout / xschem) ===="
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    magic klayout xschem \
    >>"$LOGFILE" 2>&1
  info "GUI tools installed/verified (best-effort)."
}

########################################
# Docker setup
########################################
setup_docker() {
  info "==== Docker Setup ===="

  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$OS_KIND" == "WSL" ]]; then
      warn "Docker CLI not found, and you're on WSL."
      warn "Install Docker Desktop on Windows and enable WSL integration, then re-run this script."
      exit 1
    fi

    info "Docker CLI not found. Installing Docker via get.docker.com (student-friendly)..."
    curl -fsSL https://get.docker.com | sudo sh >>"$LOGFILE" 2>&1
  else
    info "Docker CLI found."
  fi

  # Try to start docker daemon on systemd-based Ubuntu
  if command -v systemctl >/dev/null 2>&1 && [[ "$OS_KIND" != "WSL" ]]; then
    info "Ensuring docker service is enabled and running (systemd)..."
    sudo systemctl enable --now docker >>"$LOGFILE" 2>&1 || \
      warn "Could not enable/start docker via systemd. Check 'sudo systemctl status docker'."
  fi

  # Test daemon connectivity
  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon does not seem to be running or accessible."
    warn "On native Ubuntu, you can try:"
    echo "  sudo systemctl enable --now docker"
    echo "  sudo journalctl -u docker -n 50 --no-pager   # to see errors"
  fi

  # Add user to docker group if needed
  if ! id -nG "$USER" | grep -qw docker; then
    info "Adding $USER to 'docker' group so Docker can run without sudo..."
    sudo usermod -aG docker "$USER" || warn "Failed to add user to docker group."
    warn "You may need to log out and log back in, or run:  newgrp docker"
  fi

  info "Checking Docker hello-world..."
  if ! docker run --rm hello-world >/dev/null 2>&1; then
    error "Docker is installed but cannot run containers."

    warn "Common fixes (your classmate already used these successfully):"
    echo "  sudo systemctl enable --now docker"
    echo "  sudo usermod -aG docker \"$USER\""
    echo "  newgrp docker"
    echo "  docker run --rm hello-world"

    warn "After doing that, re-run:  ./silicon_craft_pd_setup.sh"
    exit 1
  fi

  info "Docker is working."
}

########################################
# OpenLane repo + PDK
########################################
setup_openlane_repo_and_pdk() {
  info "==== OpenLane Repo + PDK Setup ===="

  mkdir -p "$VLSI_ROOT"

  if [[ ! -d "$OPENLANE_DIR" ]]; then
    info "Cloning OpenLane into: $OPENLANE_DIR"
    git clone --depth 1 "$OPENLANE_REPO_URL" "$OPENLANE_DIR" >>"$LOGFILE" 2>&1
  else
    info "OpenLane repo already exists at: $OPENLANE_DIR"
  fi

  cd "$OPENLANE_DIR"

  # Use local pdks directory inside OpenLane
  export PDK_ROOT="$OPENLANE_DIR/pdks"

  info "Running 'make' inside OpenLane with PDK_ROOT=$PDK_ROOT (this can take time)..."
  # This will: create venv, install ciel, pull image, and enable sky130A
  make >>"$LOGFILE" 2>&1

  # Ensure sky130A PDK is present
  if [[ -d "$PDK_ROOT/sky130A" ]]; then
    info "sky130A PDK present at $PDK_ROOT/sky130A"
  else
    error "sky130A PDK NOT found under $PDK_ROOT. Check $LOGFILE for OpenLane make errors."
    exit 1
  fi

  info "OpenLane 'make' completed."
}

########################################
# Docker image pull (optional but nice)
########################################
pull_openlane_image() {
  info "==== OpenLane Docker Image (optional) ===="
  info "Using OpenLane image: $OPENLANE_IMAGE"

  if docker image inspect "$OPENLANE_IMAGE" >/dev/null 2>&1; then
    info "OpenLane image already present locally."
  else
    info "Pulling OpenLane image..."
    docker pull "$OPENLANE_IMAGE" >>"$LOGFILE" 2>&1 || \
      warn "Failed to pull $OPENLANE_IMAGE; OpenLane may still pull internally later."
  fi
}

########################################
# Prepare a simple inverter design
########################################
prepare_inverter_design() {
  info "==== Preparing Sample Inverter Design ===="

  local ddir="$OPENLANE_DIR/designs/inverter"
  mkdir -p "$ddir/src"

  cat >"$ddir/src/inverter.v" <<'EOF'
module inverter (
    input  wire a,
    output wire y
);
  assign y = ~a;
endmodule
EOF

  cat >"$ddir/config.tcl" <<'EOF'
set ::env(DESIGN_NAME) inverter
set ::env(VERILOG_FILES) "\
  $::env(DESIGN_DIR)/src/inverter.v"

set ::env(CLOCK_PORT) "a"
set ::env(CLOCK_PERIOD) "10.0"

set ::env(FP_CORE_UTIL) 30
set ::env(FP_ASPECT_RATIO) 1.0
set ::env(FP_IO_VEXTEND) 2
set ::env(FP_IO_HEXTEND) 2
EOF

  info "Inverter design prepared at: $ddir"
}

########################################
# Run OpenLane flow on inverter (non-interactive)
########################################
run_openlane_inverter() {
  info "==== Running OpenLane RTL2GDS Flow (inverter) ===="
  info "Starting OpenLane flow (this may take time on first run, as PDK + tools are used)..."

  cd "$OPENLANE_DIR"

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  # Use the pinned image; PDK is under /openlane/pdks inside the container
  if ! docker run --rm \
      -u "${uid}:${gid}" \
      -v "$OPENLANE_DIR:/openlane" \
      -w /openlane \
      -e PDK_ROOT=/openlane/pdks \
      -e PDK=sky130A \
      "$OPENLANE_IMAGE" \
      ./flow.tcl -design inverter -overwrite \
      2>&1 | tee -a "$LOGFILE"
  then
    warn "OpenLane flow reported an error. Check $LOGFILE for details."
  else
    info "OpenLane flow completed (or exited with warnings)."
  fi
}

########################################
# Try to open final GDS in KLayout
########################################
open_gds_if_available() {
  info "==== Checking for resulting GDS ===="

  local gds_path
  gds_path="$(find "$OPENLANE_DIR/designs/inverter" -maxdepth 6 -name 'inverter.gds' 2>/dev/null | head -n1 || true)"

  if [[ -n "$gds_path" ]]; then
    info "Found GDS: $gds_path"
    if command -v klayout >/dev/null 2>&1; then
      info "Opening GDS in KLayout..."
      (nohup klayout "$gds_path" >/dev/null 2>&1 & disown) || \
        warn "Failed to open KLayout automatically."
    else
      warn "KLayout is not available; cannot auto-open GDS."
    fi
  else
    warn "No GDS file found under $OPENLANE_DIR/designs/inverter yet. The OpenLane run may have failed or is incomplete."
  fi
}

########################################
# Main
########################################
main() {
  detect_os
  info "Silicon Craft – Student PD Setup"
  info "Workspace root: $VLSI_ROOT"

  preflight_prereqs
  setup_docker
  setup_openlane_repo_and_pdk
  pull_openlane_image
  prepare_inverter_design
  run_openlane_inverter
  open_gds_if_available

  info "==== Student PD environment setup finished ===="
  info "If the flow succeeded, you should see OpenLane data under:"
  info "  $OPENLANE_DIR/designs/inverter"
  info "Log file: $LOGFILE"
}

main "$@"

