#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft – Student PD Environment Setup
# v8 – WSL-aware + stronger Docker handling
#
# - Ubuntu bare metal:
#     * Installs Docker if missing
#     * Starts docker.service
#     * Adds user to docker group
#     * Runs OpenLane make with sudo if needed
#
# - WSL (Ubuntu on Windows):
#     * Does NOT install Docker
#     * Requires Docker Desktop + WSL2 integration
##############################################

# ------------ Global config ------------
VLSI_ROOT="${VLSI_ROOT:-$HOME/Silicon_Craft_PD_Workspace}"
OPENLANE_REPO_DIR="$VLSI_ROOT/OpenLane"
OPENLANE_IMAGE="${OPENLANE_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69}"
LOGFILE="$VLSI_ROOT/setup.log"
INVERTER_DESIGN_DIR="$OPENLANE_REPO_DIR/designs/inverter"

# If user was just added to docker group in THIS shell,
# we can't rely on group yet → use sudo for make.
NEED_SUDO_FOR_DOCKER_MAKE=0

# ------------ Logging helpers ------------
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){  printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

# ------------ OS detection ------------
detect_os() {
  if [[ -f /proc/version ]] && grep -qiE "microsoft|wsl" /proc/version; then
    echo "WSL"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Linux"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macOS"
  else
    echo "Unknown"
  fi
}

OS="$(detect_os)"
info "Detected OS: $OS"

if [[ "$OS" == "macOS" ]]; then
  die "This installer is for Ubuntu / WSL2 only. On macOS use Docker Desktop + manual OpenLane."
fi

if [[ "$OS" != "Linux" && "$OS" != "WSL" ]]; then
  die "Unsupported OS. Please use Ubuntu or Ubuntu under WSL2."
fi

# ------------ Apt preflight with lock wait ------------
wait_for_apt() {
  local timeout=180   # seconds
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "Another apt/dpkg process is running (Software Updater / apt). Waiting for it to finish..."
    fi
    sleep 5
    waited=$((waited + 5))
    if (( waited >= timeout )); then
      die "Timed out waiting for apt/dpkg lock. Close Software Updater / 'apt' and rerun this script."
    fi
  done
}

preflight_prereqs() {
  info "==== Preflight: Installing base packages (apt) ===="
  wait_for_apt
  sudo apt-get update -y

  sudo apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential make \
    python3 python3-pip python3-venv \
    xz-utils tcllib

  info "Base tools installed/verified."
}

# ------------ Docker setup ------------

install_docker_ubuntu() {
  info "Docker CLI not found. Installing Docker via get.docker.com..."
  curl -fsSL https://get.docker.com | sudo sh
}

start_docker_service_if_needed() {
  if command -v systemctl >/dev/null 2>&1; then
    if ! sudo systemctl is-active --quiet docker; then
      info "Starting docker.service..."
      sudo systemctl enable --now docker || warn "Could not enable/start docker via systemctl."
    fi
  fi
}

ensure_docker_linux() {
  info "==== Docker Setup (Linux) ===="

  if ! command -v docker >/dev/null 2>&1; then
    install_docker_ubuntu
  else
    info "Docker already installed."
  fi

  start_docker_service_if_needed

  # Check group membership
  if id -nG "$USER" | grep -qw docker; then
    info "User '$USER' is already in the 'docker' group."
  else
    warn "User '$USER' is NOT in 'docker' group. Adding now..."
    if sudo usermod -aG docker "$USER"; then
      NEED_SUDO_FOR_DOCKER_MAKE=1
      warn "Group change will fully apply after logout/login. Using sudo for Docker-dependent steps in this run."
    else
      warn "Failed to add '$USER' to 'docker' group. Will use 'sudo docker' when needed."
      NEED_SUDO_FOR_DOCKER_MAKE=1
    fi
  fi

  # Prefer direct docker, but fall back to sudo docker if needed
  info "Checking Docker integrity (hello-world)..."
  if docker run --rm hello-world >/dev/null 2>&1; then
    info "Docker can run containers without sudo."
    return
  fi

  warn "Plain 'docker run hello-world' failed. Trying with sudo..."
  if sudo docker run --rm hello-world >/dev/null 2>&1; then
    info "Docker works with 'sudo docker'."
    alias docker='sudo docker'
  else
    die "Docker is installed but cannot run containers. Check 'sudo systemctl status docker' and rerun this script."
  fi
}

ensure_docker_wsl() {
  info "==== Docker Setup (WSL) ===="
  info "WSL detected – Docker must come from Docker Desktop on Windows."

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker CLI not found inside WSL."
    cat <<EOF
Please do the following on Windows (outside WSL) and then rerun this script:

1) Install Docker Desktop for Windows:
   https://www.docker.com/products/docker-desktop/

2) In Docker Desktop:
   - Settings → General → ensure "Use the WSL 2 based engine" is enabled
   - Settings → Resources → WSL Integration → enable your Ubuntu distro

3) Back in WSL, verify:
   docker run --rm hello-world

When that works, run:
   ./silicon_craft_pd_setupv8.sh
EOF
    exit 1
  fi

  info "Docker CLI found in WSL. Testing 'docker run hello-world'..."
  if docker run --rm hello-world >/dev/null 2>&1; then
    info "Docker Desktop + WSL integration is working."
  else
    die "Docker is present but cannot run containers. Fix Docker Desktop / WSL integration and rerun this script."
  fi
}

setup_docker() {
  if [[ "$OS" == "WSL" ]]; then
    ensure_docker_wsl
  else
    ensure_docker_linux
  fi
}

# ------------ GUI tools ------------

setup_gui_tools() {
  info "==== GUI Tools Setup (Magic / KLayout / xschem) ===="
  if [[ "$OS" == "WSL" ]]; then
    info "WSL detected – WSLg or an X server is required for GUI. Tools will still be installed."
  fi
  wait_for_apt
  sudo apt-get update -y
  sudo apt-get install -y magic klayout xschem || \
    warn "Some GUI tools failed to install; layout viewing might be limited."
  info "GUI tools installed/verified (best-effort)."
}

# ------------ OpenLane repo + PDK ------------

setup_openlane_repo_and_pdk() {
  info "==== OpenLane Repo + PDK Setup ===="

  local need_clone=0

  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    need_clone=1
  else
    if [[ ! -d "$OPENLANE_REPO_DIR/.git" || ! -f "$OPENLANE_REPO_DIR/Makefile" ]]; then
      warn "Existing $OPENLANE_REPO_DIR is not a valid OpenLane repo. Backing up."
      local backup="${OPENLANE_REPO_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
      mv "$OPENLANE_REPO_DIR" "$backup"
      need_clone=1
    fi
  fi

  if (( need_clone == 1 )); then
    info "Cloning OpenLane into: $OPENLANE_REPO_DIR"
    git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_REPO_DIR" 2>&1 | tee -a "$LOGFILE"
  else
    info "OpenLane repo already exists at: $OPENLANE_REPO_DIR"
  fi

  cd "$OPENLANE_REPO_DIR"

  export PDK_ROOT="$OPENLANE_REPO_DIR/pdks"
  export PDK="sky130A"
  mkdir -p "$PDK_ROOT"

  info "Running 'make' inside OpenLane (this downloads tools + PDK; can take time)..."
  if (( NEED_SUDO_FOR_DOCKER_MAKE == 1 )); then
    info "Using sudo for OpenLane make because docker group membership is new in this session."
    sudo -E make 2>&1 | tee -a "$LOGFILE"
  else
    make 2>&1 | tee -a "$LOGFILE"
  fi

  if [[ -d "$PDK_ROOT/sky130A" ]]; then
    info "sky130A PDK present at $PDK_ROOT/sky130A"
  else
    warn "sky130A PDK folder not found at $PDK_ROOT/sky130A. OpenLane may still use internal handling, but flows may fail."
  fi

  info "OpenLane 'make' completed."
}

# ------------ Explicit OpenLane image pull (optional) ------------

pull_openlane_image() {
  info "==== OpenLane Docker Image (optional) ===="
  info "Using OpenLane image: $OPENLANE_IMAGE"

  if docker image inspect "$OPENLANE_IMAGE" >/dev/null 2>&1; then
    info "OpenLane image already present."
  else
    info "Pulling $OPENLANE_IMAGE ..."
    if ! docker pull "$OPENLANE_IMAGE"; then
      warn "Failed to pull explicit OpenLane image; relying on image pulled via make."
    fi
  fi
}

# ------------ Prepare inverter demo design ------------

prepare_inverter_design() {
  info "==== Preparing Sample Inverter Design ===="
  mkdir -p "$INVERTER_DESIGN_DIR"

  cat > "$INVERTER_DESIGN_DIR/inverter.v" << 'EOF'
module inverter (
    input  wire a,
    output wire y
);
  assign y = ~a;
endmodule
EOF

  cat > "$INVERTER_DESIGN_DIR/config.tcl" << 'EOF'
set ::env(DESIGN_NAME) "inverter"
set ::env(VERILOG_FILES) "$::env(DESIGN_DIR)/inverter.v"

# Dummy clock
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_PERIOD) "10"

# Absolute die sizing so PDN has space
set ::env(FP_SIZING) "absolute"
set ::env(DIE_AREA) "0 0 50 50"

set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.30
EOF

  info "Inverter design prepared at: $INVERTER_DESIGN_DIR"
}

# ------------ Run inverter flow in Docker ------------

run_openlane_inverter() {
  info "==== Running OpenLane RTL2GDS Flow (inverter) ===="

  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    die "OpenLane repo not found at $OPENLANE_REPO_DIR"
  fi

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  local DOCKER_RUN=(docker run --rm -u "${uid}:${gid}")
  DOCKER_RUN+=(-v "$OPENLANE_REPO_DIR":/openlane)
  DOCKER_RUN+=(-e PDK_ROOT=/openlane/pdks)
  DOCKER_RUN+=(-e PDK=sky130A)
  DOCKER_RUN+=(-w /openlane)
  DOCKER_RUN+=("$OPENLANE_IMAGE")
  DOCKER_RUN+=("bash" "-lc" "flow.tcl -design inverter -overwrite")

  {
    info "Starting OpenLane flow inside Docker (first run may take time)..."
    "${DOCKER_RUN[@]}"
  } 2>&1 | tee -a "$LOGFILE" || warn "OpenLane flow reported an error. Check $LOGFILE."

  info "OpenLane flow finished (or exited with warnings)."
}

# ------------ Open GDS if available ------------

open_gds_if_available() {
  info "==== Checking for resulting GDS ===="
  local gds_path
  gds_path="$(find "$INVERTER_DESIGN_DIR" -maxdepth 6 -type f -name '*.gds' | head -n1 || true)"

  if [[ -z "$gds_path" ]]; then
    warn "No GDS found under $INVERTER_DESIGN_DIR. The flow may have failed."
    return
  fi

  info "Found GDS: $gds_path"
  if command -v klayout >/dev/null 2>&1; then
    info "Opening GDS in KLayout..."
    (nohup klayout "$gds_path" >/dev/null 2>&1 & disown) || warn "Failed to auto-open KLayout."
  else
    warn "KLayout not found; cannot auto-open GDS."
  fi
}

# ------------ Main ------------

main() {
  info "Silicon Craft – Student PD Setup v8"
  info "Workspace: $VLSI_ROOT"

  preflight_prereqs
  setup_docker
  setup_gui_tools
  setup_openlane_repo_and_pdk
  pull_openlane_image
  prepare_inverter_design
  run_openlane_inverter
  open_gds_if_available

  info "==== Student PD environment setup finished ===="
  info "If the flow succeeded, you should see OpenLane data under:"
  info "  $INVERTER_DESIGN_DIR"
  info "Log file: $LOGFILE"
}

main "$@"

