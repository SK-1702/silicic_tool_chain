#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft – PD Environment Setup
# (Uses OpenLane Docker Only)
#
# Tested on: Ubuntu / WSL2 Ubuntu
# What it does:
#   - Creates PD workspace under $HOME/Silicon_Craft_PD_Workspace
#   - Installs Docker (if needed) and makes sure it can run containers
#   - Installs Magic, KLayout, xschem (best-effort)
#   - Clones official OpenLane repo + installs sky130A PDK (via `make`)
#   - Prepares simple "inverter" design inside OpenLane/designs
#   - Runs OpenLane RTL2GDS flow in Docker
#   - Tries to open final GDS in KLayout (if available)
##############################################

# ------------ Configuration ------------
VLSI_ROOT="${VLSI_ROOT:-$HOME/Silicon_Craft_PD_Workspace}"
OPENLANE_REPO_DIR="$VLSI_ROOT/OpenLane"
OPENLANE_IMAGE="${OPENLANE_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69}"
LOGFILE="$VLSI_ROOT/setup.log"
INVERTER_DESIGN_DIR="$OPENLANE_REPO_DIR/designs/inverter"

# Docker command wrapper (may become "sudo docker" later)
DOCKER_BIN="docker"

# ------------ Logging helpers ------------
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){  printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

# ------------ OS detection ------------
detect_os() {
  if [[ -f /proc/version ]] && grep -qi microsoft /proc/version; then
    echo "WSL"
  elif [[ "${OSTYPE:-}" == "linux-gnu"* ]]; then
    echo "Linux"
  elif [[ "${OSTYPE:-}" == "darwin"* ]]; then
    echo "macOS"
  else
    echo "Unknown"
  fi
}

OS=$(detect_os)
info "Detected OS: $OS"

if [[ "$OS" == "macOS" ]]; then
  die "This installer is currently tested only on Ubuntu / WSL2. For macOS, please use Docker Desktop + manual steps."
fi

if [[ "$OS" != "Linux" && "$OS" != "WSL" ]]; then
  die "Unsupported OS for student script. Please use Ubuntu or WSL2 Ubuntu."
fi

# ------------ Preflight: apt & basic tools ------------
preflight_prereqs() {
  info "==== Preflight: Installing base packages (apt) ===="
  sudo apt-get update -y

  sudo apt-get install -y \
    git curl ca-certificates gnupg lsb-release \
    build-essential make python3 python3-pip python3-venv \
    xz-utils wget \
    tcllib

  info "Base tools installed/verified."
}

# ------------ Docker setup ------------

check_docker_cli() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

install_docker_ubuntu() {
  info "Docker CLI not found. Installing Docker via get.docker.com (student-friendly)..."
  curl -fsSL https://get.docker.com | sudo sh
  # Add current user to docker group (for future shells); script will still
  # be able to use sudo docker if needed.
  sudo usermod -aG docker "$USER" || true
  warn "You may need to LOG OUT and LOG IN again for docker group changes to take effect."
}

ensure_docker_running() {
  info "Checking Docker hello-world..."

  # On real Linux (not WSL), try to make sure docker.service is running
  if [[ "$OS" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet docker; then
      info "Docker service not active; trying to enable and start via systemctl..."
      if ! sudo systemctl enable --now docker >/dev/null 2>&1; then
        warn "Failed to enable/start docker.service via systemctl (may be fine on some setups)."
      fi
    fi
  fi

  # First try as normal user
  DOCKER_BIN="docker"
  if "$DOCKER_BIN" run --rm hello-world >/dev/null 2>&1; then
    info "Docker is working (user-mode)."
    return
  fi

  warn "Docker hello-world failed as current user. Trying with sudo..."

  # Try with sudo docker
  if sudo docker run --rm hello-world >/dev/null 2>&1; then
    info "Docker is working via sudo."
    DOCKER_BIN="sudo docker"
    return
  fi

  die "Docker is installed but cannot run containers even with sudo. Check docker service/permissions, then re-run this script."
}

setup_docker() {
  info "==== Docker Setup ===="
  if check_docker_cli; then
    info "Docker CLI found."
  else
    install_docker_ubuntu
  fi

  ensure_docker_running
}

# ------------ GUI tools: Magic, KLayout, xschem ------------

setup_gui_tools() {
  info "==== GUI Tools Setup (Magic / KLayout / xschem) ===="
  if [[ "$OS" == "WSL" ]]; then
    info "WSL detected. WSLg usually provides GUI support. If not, configure your X server manually."
  fi

  # GUI tools are "best-effort" – failures should NOT kill the script.
  if ! sudo apt-get update -y; then
    warn "apt-get update failed during GUI tools setup (likely mirror sync issue)."
    warn "Skipping Magic/KLayout/xschem install for now. You can install them later manually:"
    warn "  sudo apt-get update && sudo apt-get install magic klayout xschem"
    return
  fi

  if ! sudo apt-get install -y magic klayout xschem; then
    warn "Some GUI tools failed to install (Magic/KLayout/xschem)."
    warn "Layout viewing might be limited, but RTL2GDS flow will still work."
    return
  fi

  info "GUI tools installed/verified (best-effort)."
}

# ------------ OpenLane repo + PDK (sky130A) ------------

setup_openlane_repo_and_pdk() {
  info "==== OpenLane Repo + PDK Setup ===="

  local need_clone=0

  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    need_clone=1
  else
    # If the directory exists but is not a proper repo, back it up
    if [[ ! -d "$OPENLANE_REPO_DIR/.git" || ! -f "$OPENLANE_REPO_DIR/Makefile" ]]; then
      warn "Existing $OPENLANE_REPO_DIR is not a valid OpenLane repo (missing .git/Makefile)."
      local backup="${OPENLANE_REPO_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
      warn "Backing it up to: $backup"
      mv "$OPENLANE_REPO_DIR" "$backup"
      need_clone=1
    fi
  fi

  if [[ "$need_clone" -eq 1 ]]; then
    info "Cloning OpenLane repository into: $OPENLANE_REPO_DIR"
    git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_REPO_DIR" 2>&1 | tee -a "$LOGFILE"
  else
    info "OpenLane repo already exists at: $OPENLANE_REPO_DIR"
  fi

  cd "$OPENLANE_REPO_DIR"

  # Force PDK_ROOT into the repo's pdks/ directory so that inside Docker
  # /openlane/pdks/sky130A actually exists.
  export PDK_ROOT="$OPENLANE_REPO_DIR/pdks"
  export PDK="sky130A"
  mkdir -p "$PDK_ROOT"

  info "Running 'make' inside OpenLane with PDK_ROOT=$PDK_ROOT (this can take time)..."
  # Use sudo so make's internal docker calls succeed even if only root can talk to docker
  if ! sudo env "PDK_ROOT=$PDK_ROOT" "PDK=$PDK" make 2>&1 | tee -a "$LOGFILE"; then
    die "OpenLane 'make' failed – check $LOGFILE for details."
  fi

  # Sanity check: did we get a sky130A directory?
  if [[ -d "$PDK_ROOT/sky130A" ]]; then
    info "sky130A PDK present at $PDK_ROOT/sky130A"
  else
    warn "After make, $PDK_ROOT/sky130A is still missing. OpenLane may fall back to internal PDK handling."
  fi

  info "OpenLane 'make' completed."
}

# ------------ (Optional) explicit image pull ------------

pull_openlane_image() {
  info "==== OpenLane Docker Image (optional) ===="
  info "Using OpenLane image: $OPENLANE_IMAGE"

  if $DOCKER_BIN image inspect "$OPENLANE_IMAGE" >/dev/null 2>&1; then
    info "OpenLane image already present locally."
  else
    info "Pulling OpenLane image: $OPENLANE_IMAGE"
    if ! $DOCKER_BIN pull "$OPENLANE_IMAGE"; then
      warn "Failed to pull explicit OpenLane image: $OPENLANE_IMAGE. The repo's 'make' already pulled what it needs, so this is not fatal."
    fi
  fi
}

# ------------ Prepare inverter design (inside repo) ------------

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
# OpenLane design config for a simple inverter (student demo)
# PDN is kept ENABLED – we just give enough area so PDN can be built.

set ::env(DESIGN_NAME) "inverter"

# RTL source
set ::env(VERILOG_FILES) "$::env(DESIGN_DIR)/inverter.v"

# Dummy clock (design is combinational, but OpenLane expects a clock)
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_PERIOD) "10"

# --- Floorplan sizing ---
# Force an absolute die size so the PDN grid has room.
# (Units are microns; 0 0 50 50 = 50µm x 50µm core, huge for 1 inverter but safe.)
set ::env(FP_SIZING) "absolute"
set ::env(DIE_AREA) "0 0 50 50"

# Lower utilization and target density so the cell doesn't try to fill the die.
set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.30

# Keep PDN ON (default), so student flow includes real power grid step.
EOF

  info "Inverter design prepared at: $INVERTER_DESIGN_DIR"
}

# ------------ Run OpenLane flow in Docker ------------

run_openlane_inverter() {
  info "==== Running OpenLane RTL2GDS Flow (inverter) ===="

  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    die "OpenLane repo directory not found at $OPENLANE_REPO_DIR. Something went wrong earlier."
  fi
  if [[ ! -d "$OPENLANE_REPO_DIR/pdks/sky130A" ]]; then
    warn "sky130A PDK directory not found at $OPENLANE_REPO_DIR/pdks/sky130A; flow may fail."
  fi

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  local DOCKER_RUN=("$DOCKER_BIN" run --rm -u "${uid}:${gid}")
  DOCKER_RUN+=(-v "$OPENLANE_REPO_DIR":/openlane)
  DOCKER_RUN+=(-e PDK_ROOT=/openlane/pdks)
  DOCKER_RUN+=(-e PDK=sky130A)
  DOCKER_RUN+=(-w /openlane)
  DOCKER_RUN+=("$OPENLANE_IMAGE")
  DOCKER_RUN+=("bash" "-lc" "flow.tcl -design inverter -overwrite")

  {
    info "Starting OpenLane flow inside Docker (this may take time on first run)..."
    "${DOCKER_RUN[@]}"
  } 2>&1 | tee -a "$LOGFILE" || warn "OpenLane flow reported an error. Check $LOGFILE for details."

  info "OpenLane flow completed (or exited with warnings)."
}

# ------------ Open resulting GDS (if any) ------------

open_gds_if_available() {
  info "==== Checking for resulting GDS ===="
  local gds_path
  gds_path="$(find "$INVERTER_DESIGN_DIR" -maxdepth 6 -type f -name '*.gds' | head -n1 || true)"

  if [[ -z "$gds_path" ]]; then
    warn "No GDS file found under $INVERTER_DESIGN_DIR yet. The OpenLane run may have failed or is incomplete."
    return
  fi

  info "Found GDS: $gds_path"

  if command -v klayout >/dev/null 2>&1; then
    info "Opening GDS in KLayout..."
    (nohup klayout "$gds_path" >/dev/null 2>&1 & disown) || warn "Failed to open KLayout automatically."
  else
    warn "KLayout is not available; cannot auto-open GDS."
  fi
}

# ------------ Main flow ------------

main() {
  info "Silicon Craft – Student PD Setup"
  info "Workspace root: $VLSI_ROOT"

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

