#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft – Student PD Environment Setup
# Version: v9
#
# - Ubuntu bare metal: installs docker, GUI tools, OpenLane + sky130A, runs inverter flow
# - WSL Ubuntu: ONLY allowed if Docker Desktop + WSL integration already working
##############################################

VLSI_ROOT="${VLSI_ROOT:-$HOME/Silicon_Craft_PD_Workspace}"
OPENLANE_REPO_DIR="$VLSI_ROOT/OpenLane"
OPENLANE_IMAGE="${OPENLANE_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69}"
LOGFILE="$VLSI_ROOT/setup.log"
INVERTER_DESIGN_DIR="$OPENLANE_REPO_DIR/designs/inverter"

info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){  printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

detect_os() {
  if [[ -f /proc/version ]] && grep -qi microsoft /proc/version; then
    echo "WSL"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Linux"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macOS"
  else
    echo "Unknown"
  fi
}

OS=$(detect_os)
info "Detected OS: $OS"

if [[ "$OS" == "macOS" ]]; then
  die "This script is for Ubuntu / WSL only. On macOS use Docker Desktop + manual OpenLane."
fi

if [[ "$OS" != "Linux" && "$OS" != "WSL" ]]; then
  die "Unsupported OS. Use Ubuntu or WSL Ubuntu."
fi

########################################
# 1. Preflight: apt + base packages
########################################
preflight_prereqs() {
  info "==== Preflight: Installing base packages (apt) ===="

  # --- BEST-EFFORT apt-get update ---
  # Mirrors sometimes say "File has unexpected size (Mirror sync in progress?)".
  # That should NOT kill the whole script if packages are already installed.
  if ! sudo apt-get update -y; then
    warn "apt-get update reported an error (mirror sync or network issue)."
    warn "Continuing with existing package lists. If installs fail, please rerun later."
  fi

  # Required tools – this MUST succeed or we stop.
  sudo apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential make \
    python3 python3-pip python3-venv \
    tcllib xz-utils \
    software-properties-common || die "apt-get install failed; please fix apt/network and rerun."

  info "Base tools installed/verified."
}

########################################
# 2. Docker helpers – generic checks
########################################
docker_hello_world() {
  # $1: use_sudo (0/1)
  local prefix=()
  if [[ "${1:-0}" -eq 1 ]]; then
    prefix=(sudo)
  fi
  if "${prefix[@]}" docker run --rm hello-world >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

########################################
# 3. Docker setup – Linux (bare metal)
########################################
install_docker_linux() {
  info "Docker not found. Installing Docker CE from official repo..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
  warn "You may need to log out and log in again for docker group changes to apply."
}

ensure_docker_linux() {
  info "==== Docker Setup (Linux) ===="
  if command -v docker >/dev/null 2>&1; then
    info "Docker binary found."
  else
    install_docker_linux
  fi

  # Try non-sudo first
  if docker_hello_world 0; then
    info "Docker works without sudo."
    return
  fi

  warn "Docker without sudo failed, trying with sudo and ensuring service is running..."
  sudo systemctl enable --now docker >/dev/null 2>&1 || true

  if docker_hello_world 1; then
    warn "Docker works with sudo. Script will use 'sudo docker' internally."
    alias docker='sudo docker'
    export DOCKER_USES_SUDO=1
  else
    die "Docker is installed but cannot run containers. Please fix Docker (service, permissions, network) and rerun this script."
  fi
}

########################################
# 4. Docker setup – WSL case
########################################
ensure_docker_wsl() {
  info "==== Docker Setup (WSL) ===="
  info "WSL detected – Docker must come from Docker Desktop on Windows."

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker CLI not found inside WSL."
    err "Steps (do this in Windows, NOT WSL):"
    err "  1) Install Docker Desktop for Windows."
    err "  2) In Docker Desktop → Settings → Resources → WSL integration:"
    err "     - Enable integration for this distro."
    err "  3) Start Docker Desktop."
    err "Then reopen WSL and rerun this script."
    exit 1
  fi

  info "Docker CLI found in WSL. Testing 'docker run hello-world'..."
  if docker_hello_world 0; then
    info "Docker Desktop + WSL integration is working."
  else
    die "Docker is present but cannot run containers. Start Docker Desktop, enable WSL integration for this distro, then rerun this script."
  fi
}

setup_docker() {
  if [[ "$OS" == "WSL" ]]; then
    ensure_docker_wsl
  else
    ensure_docker_linux
  fi
}

########################################
# 5. GUI tools
########################################
setup_gui_tools() {
  info "==== GUI Tools Setup (Magic / KLayout / xschem) ===="
  if [[ "$OS" == "WSL" ]]; then
    info "WSL: GUI windows need WSLg or an X server."
  fi

  # Again, allow update to be flaky but install must succeed
  if ! sudo apt-get update -y; then
    warn "apt-get update (GUI tools) failed; using cached lists."
  fi

  sudo apt-get install -y magic klayout xschem || \
    warn "Some GUI tools failed to install; you may not be able to view layouts."

  info "GUI tools installed/verified (best-effort)."
}

########################################
# 6. OpenLane + PDK
########################################
setup_openlane_repo_and_pdk() {
  info "==== OpenLane Repo + PDK Setup ===="

  local need_clone=0
  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    need_clone=1
  else
    if [[ ! -d "$OPENLANE_REPO_DIR/.git" || ! -f "$OPENLANE_REPO_DIR/Makefile" ]]; then
      warn "Existing $OPENLANE_REPO_DIR is not a valid OpenLane repo. Backing it up."
      mv "$OPENLANE_REPO_DIR" "${OPENLANE_REPO_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
      need_clone=1
    fi
  fi

  if [[ "$need_clone" -eq 1 ]]; then
    info "Cloning OpenLane into $OPENLANE_REPO_DIR"
    git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_REPO_DIR" 2>&1 | tee -a "$LOGFILE"
  else
    info "OpenLane repo already present."
  fi

  cd "$OPENLANE_REPO_DIR"

  export PDK_ROOT="$OPENLANE_REPO_DIR/pdks"
  export PDK="sky130A"
  mkdir -p "$PDK_ROOT"

  info "Running 'make' in OpenLane (downloads tools + sky130A via ciel)..."
  if ! make 2>&1 | tee -a "$LOGFILE"; then
    die "OpenLane make failed. Check $LOGFILE for details."
  fi

  if [[ -d "$PDK_ROOT/sky130A" ]]; then
    info "sky130A PDK present at $PDK_ROOT/sky130A"
  else
    warn "sky130A directory not found, but OpenLane may still have internal PDK setup via ciel."
  fi
}

pull_openlane_image() {
  info "==== OpenLane Docker Image ===="
  info "Using image: $OPENLANE_IMAGE"
  if docker image inspect "$OPENLANE_IMAGE" >/dev/null 2>&1; then
    info "Image already present."
  else
    info "Pulling image..."
    if ! docker pull "$OPENLANE_IMAGE"; then
      warn "Failed to pull explicit image; relying on image pulled by 'make'."
    fi
  fi
}

########################################
# 7. Example inverter design
########################################
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
set ::env(CLOCK_PORT)   "clk"
set ::env(CLOCK_PERIOD) "10"

# Floorplan sizing
set ::env(FP_SIZING)       "absolute"
set ::env(DIE_AREA)        "0 0 50 50"
set ::env(FP_CORE_UTIL)    10
set ::env(PL_TARGET_DENSITY) 0.30
EOF

  info "Inverter design prepared at $INVERTER_DESIGN_DIR"
}

########################################
# 8. Run OpenLane flow (Docker)
########################################
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
    info "Starting flow inside Docker (first run may be slow)..."
    "${DOCKER_RUN[@]}"
  } 2>&1 | tee -a "$LOGFILE" || warn "OpenLane flow reported an error. See $LOGFILE."

  info "OpenLane flow finished (or exited with warnings)."
}

########################################
# 9. Open GDS
########################################
open_gds_if_available() {
  info "==== Checking for resulting GDS ===="
  local gds_path
  gds_path="$(find "$INVERTER_DESIGN_DIR" -maxdepth 6 -type f -name '*.gds' | head -n1 || true)"

  if [[ -z "$gds_path" ]]; then
    warn "No GDS found under $INVERTER_DESIGN_DIR – flow may have failed. Check $LOGFILE."
    return
  fi

  info "Found GDS: $gds_path"
  if command -v klayout >/dev/null 2>&1; then
    info "Opening GDS in KLayout..."
    (nohup klayout "$gds_path" >/dev/null 2>&1 & disown) || warn "Failed to auto-open KLayout."
  else
    warn "KLayout not installed; cannot auto-open GDS."
  fi
}

########################################
# 10. Main
########################################
main() {
  info "Silicon Craft – Student PD Setup v9"
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
  info "If the flow succeeded you should see data in:"
  info "  $INVERTER_DESIGN_DIR"
  info "Log file: $LOGFILE"
}

main "$@"

