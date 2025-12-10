#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft – Student PD Setup v10
# - Ubuntu Desktop / Laptop
# - WSL2 Ubuntu (with Docker Desktop on Windows)
#
# Creates:  $HOME/Silicon_Craft_PD_Workspace
# Installs:
#   - Docker (Linux only)
#   - Magic / KLayout / xschem
#   - OpenLane repo + sky130A PDK
# Runs:
#   - Inverter RTL → GDS
##############################################

VLSI_ROOT="${VLSI_ROOT:-$HOME/Silicon_Craft_PD_Workspace}"
OPENLANE_REPO_DIR="$VLSI_ROOT/OpenLane"
PDK_ROOT="$OPENLANE_REPO_DIR/pdks"
OPENLANE_IMAGE="${OPENLANE_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69}"
LOGFILE="$VLSI_ROOT/setup.log"
INVERTER_DESIGN_DIR="$OPENLANE_REPO_DIR/designs/inverter"

# ---------- Logging ----------
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){  printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
touch "$LOGFILE"

# ---------- OS detection ----------
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

OS="$(detect_os)"
info "Detected OS: $OS"

if [[ "$OS" == "macOS" ]]; then
  die "This script is only for Ubuntu / WSL2 Ubuntu. On macOS, use Docker Desktop + manual OpenLane setup."
fi

if [[ "$OS" != "Linux" && "$OS" != "WSL" ]]; then
  die "Unsupported OS. Please use Ubuntu or WSL2 Ubuntu."
fi

# ---------- APT helpers ----------
wait_for_apt_lock() {
  local lockfile="/var/lib/dpkg/lock-frontend"
  local max_wait=60
  local waited=0

  while fuser "$lockfile" >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "Another apt/dpkg process is running (Software Updater or apt). Waiting for it to finish..."
    fi
    sleep 3
    waited=$((waited+3))
    if (( waited >= max_wait )); then
      die "Timed out waiting for apt/dpkg lock. Close Software Updater or any apt process and rerun this script."
    fi
  done
}

run_apt_update() {
  wait_for_apt_lock
  if ! sudo apt-get update -y; then
    die "apt-get update failed (mirror/network problem). Please run 'sudo apt-get update' manually and ensure it succeeds, then rerun this script."
  fi
}

preflight_prereqs() {
  info "==== Preflight: Installing base packages (apt) ===="
  run_apt_update

  sudo apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential make python3 python3-pip python3-venv \
    tcllib xz-utils software-properties-common

  info "Base tools installed/verified."
}

# ---------- Docker – WSL helper message ----------
wsl_docker_hint() {
  cat << 'EOF'
[ERROR] Docker cannot run inside WSL yet.

To fix this:

  1) Install Docker Desktop on Windows:
       https://docs.docker.com/desktop/install/windows/

  2) In Docker Desktop → Settings → Resources → WSL integration:
       ✔ Enable integration for this Ubuntu WSL distro.

  3) In Windows PowerShell:
       wsl --shutdown

  4) Reopen Ubuntu (WSL) and test:
       docker run --rm hello-world

Once that works, rerun this script:
  ./silicon_craft_pd_setup_v10.sh

EOF
}

# ---------- Docker setup (Linux) ----------
linux_install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed"
    return
  fi

  info "Installing Docker Engine via get.docker.com ..."
  curl -fsSL https://get.docker.com | sudo sh

  info "Enabling Docker service"
  sudo systemctl enable --now docker

  info "Adding user '$USER' to docker group"
  sudo usermod -aG docker "$USER" || true

  warn "You may need to LOG OUT and LOG IN again so docker group membership takes effect."
}

linux_ensure_docker_works() {
  # prefer non-sudo if possible
  if docker info >/dev/null 2>&1; then
    info "Docker works without sudo."
    if docker run --rm hello-world >/dev/null 2>&1; then
      info "Docker hello-world successful."
      return 0
    fi
  fi

  # try via sudo (service not started or permissions)
  warn "Docker failed without sudo – trying with sudo docker..."
  if sudo docker info >/dev/null 2>&1; then
    if sudo docker run --rm hello-world >/dev/null 2>&1; then
      warn "Docker works with sudo but not as normal user."
      cat << 'EOF'
[INFO] Next step:

  - Log out from your Ubuntu session (or reboot).
  - Log back in so docker group membership is refreshed.
  - Then re-run the script:

      ./silicon_craft_pd_setup_v10.sh

After that, Docker should work without sudo.
EOF
      exit 0
    fi
  fi

  die "Docker daemon is installed but cannot run containers. Check 'sudo systemctl status docker' and fix before rerunning."
}

setup_docker() {
  if [[ "$OS" == "WSL" ]]; then
    info "==== Docker Setup (WSL) ===="
    if command -v docker >/dev/null 2>&1 && docker run --rm hello-world >/dev/null 2>&1; then
      info "Docker inside WSL is already working."
      return
    fi
    wsl_docker_hint
    exit 1
  fi

  info "==== Docker Setup (Linux) ===="
  linux_install_docker_if_needed
  linux_ensure_docker_works
}

# ---------- GUI tools ----------
setup_gui_tools() {
  info "==== GUI Tools Setup (Magic / KLayout / xschem) ===="
  run_apt_update
  if ! sudo apt-get install -y magic klayout xschem; then
    warn "Some GUI tools failed to install; you may not be able to view layouts locally."
  fi
  info "GUI tools installed/verified (best-effort)."
}

# ---------- Git tuning + OpenLane clone ----------
tune_git_for_slow_network() {
  git config --global http.postBuffer 524288000 || true
  git config --global http.lowSpeedLimit 0 || true
  git config --global http.lowSpeedTime 999999 || true
}

clone_openlane_with_retry() {
  local attempts=3
  local delay=10

  tune_git_for_slow_network

  for i in $(seq 1 "$attempts"); do
    info "Cloning OpenLane (attempt $i/$attempts)..."
    if git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_REPO_DIR"; then
      info "OpenLane cloned successfully."
      return 0
    fi
    warn "OpenLane clone failed (likely network issue). Retrying in ${delay}s..."
    sleep "$delay"
  done

  die "OpenLane clone failed after $attempts attempts. Check your internet connection and try again."
}

setup_openlane_repo_and_pdk() {
  info "==== OpenLane Repo + PDK Setup ===="

  local need_clone=0
  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    need_clone=1
  else
    if [[ ! -d "$OPENLANE_REPO_DIR/.git" || ! -f "$OPENLANE_REPO_DIR/Makefile" ]]; then
      warn "Existing $OPENLANE_REPO_DIR is not a valid OpenLane repo (missing .git/Makefile)."
      local backup="${OPENLANE_REPO_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
      warn "Backing it up to: $backup"
      mv "$OPENLANE_REPO_DIR" "$backup"
      need_clone=1
    else
      info "OpenLane repo already exists at: $OPENLANE_REPO_DIR"
    fi
  fi

  if (( need_clone == 1 )); then
    clone_openlane_with_retry
  fi

  cd "$OPENLANE_REPO_DIR"

  export PDK_ROOT
  export PDK="sky130A"
  mkdir -p "$PDK_ROOT"

  info "Running 'make' inside OpenLane with PDK_ROOT=$PDK_ROOT (this may take time)..."
  if ! make 2>&1 | tee -a "$LOGFILE"; then
    die "OpenLane 'make' failed. Check $LOGFILE for details."
  fi

  if [[ -d "$PDK_ROOT/sky130A" ]]; then
    info "sky130A PDK present at $PDK_ROOT/sky130A"
  else
    warn "After make, $PDK_ROOT/sky130A is still missing. The flow may still work because OpenLane handles PDK via ciel."
  fi
}

# ---------- Prepare inverter design ----------
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

# Dummy clock for OpenLane
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_PERIOD) "10"

# Floorplan
set ::env(FP_SIZING) "absolute"
set ::env(DIE_AREA) "0 0 50 50"
set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.30
EOF

  info "Inverter design prepared at: $INVERTER_DESIGN_DIR"
}

# ---------- Run inverter flow in Docker ----------
run_openlane_inverter() {
  info "==== Running OpenLane RTL2GDS Flow (inverter) ===="

  if [[ ! -d "$OPENLANE_REPO_DIR" ]]; then
    die "OpenLane repo not found at $OPENLANE_REPO_DIR"
  fi

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  local DOCKER_CMD=("docker")
  # If docker needs sudo (Linux case) but we know it works, allow sudo docker
  if ! docker info >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD=("sudo" "docker")
  fi

  "${DOCKER_CMD[@]}" run --rm \
    -u "${uid}:${gid}" \
    -v "$OPENLANE_REPO_DIR:/openlane" \
    -e PDK_ROOT=/openlane/pdks \
    -e PDK=sky130A \
    -w /openlane \
    "$OPENLANE_IMAGE" \
    bash -lc "flow.tcl -design inverter -overwrite" \
    2>&1 | tee -a "$LOGFILE" || warn "OpenLane flow reported an error. See $LOGFILE"

  info "OpenLane flow completed (or exited with warnings)."
}

# ---------- Open GDS ----------
open_gds_if_available() {
  info "==== Checking for resulting GDS ===="
  local gds_path
  gds_path="$(find "$INVERTER_DESIGN_DIR" -maxdepth 6 -type f -name '*.gds' | head -n1 || true)"

  if [[ -z "$gds_path" ]]; then
    warn "No GDS file found under $INVERTER_DESIGN_DIR. Flow may have failed."
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

# ---------- Main ----------
main() {
  info "Silicon Craft – Student PD Setup v10"
  info "Workspace: $VLSI_ROOT"

  preflight_prereqs
  setup_docker
  setup_gui_tools
  setup_openlane_repo_and_pdk
  prepare_inverter_design
  run_openlane_inverter
  open_gds_if_available

  info "==== Student PD environment setup finished ===="
  info "If flow succeeded, check:"
  info "  $INVERTER_DESIGN_DIR"
  info "Log file: $LOGFILE"
}

main "$@"

