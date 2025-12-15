#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Silicon Craft – Student PD Setup v11
# - Robust Docker handling (daemon, group, sudo fallback)
# - WSL detection -> instruct Docker Desktop + exit
# - apt lock waiting
# - python3-venv auto-install
# - git clone retry (with --depth fallback)
# - Ensure sky130A PDK present
# - Prepare inverter design with RUN_TAG + Magic DRC skip
# - Run OpenLane in Docker, open GDS in klayout (if available)

VLSI_ROOT="${VLSI_ROOT:-$HOME/Silicon_Craft_PD_Workspace}"
OPENLANE_REPO_DIR="$VLSI_ROOT/OpenLane"
OPENLANE_IMAGE="${OPENLANE_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69}"
LOGFILE="$VLSI_ROOT/setup_v11.log"
INVERTER_DESIGN_DIR="$OPENLANE_REPO_DIR/designs/inverter"

# helpers
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){  printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

mkdir -p "$VLSI_ROOT"
: > "$LOGFILE"

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
  die "This installer is tested for Ubuntu/WSL. macOS: use Docker Desktop + manual steps."
fi

# wait for apt/dpkg lock (student friendly)
wait_for_apt_lock() {
  local tries=0 max=30
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if [[ $tries -ge $max ]]; then
      die "Timed out waiting for apt/dpkg lock. Close other package managers and re-run."
    fi
    if [[ $tries -eq 0 ]]; then
      warn "Another apt/dpkg process detected (Software Updater?). Waiting for it to finish..."
    fi
    sleep 2
    ((tries++))
  done
}

preflight_prereqs() {
  info "==== Preflight: Installing base packages (apt) ===="
  wait_for_apt_lock
  sudo apt-get update -y
  wait_for_apt_lock
  sudo apt-get install -y \
    git curl ca-certificates gnupg lsb-release \
    build-essential make python3 python3-pip python3-venv \
    xz-utils wget tcllib software-properties-common || die "apt install failed"
  info "Base tools installed/verified."
}

# Docker helpers
is_wsl() { [[ "$OS" == "WSL" ]]; }
docker_cli_present() { command -v docker >/dev/null 2>&1; }

wsl_instructions_and_exit() {
  cat <<'MSG'
Detected WSL. Please install Docker Desktop on Windows and enable "Use the WSL 2 based engine"
and enable integration for your distro (Settings → Resources → WSL Integration).
After installing and enabling, open a new WSL shell and re-run this script.

Docker Desktop: https://www.docker.com/products/docker-desktop   (https://apps.microsoft.com/detail/xp8cbj40xlbwkx?hl=en-GB&gl=IN)
MSG
  exit 0
}

install_docker_ubuntu() {
  info "Docker CLI not found. Installing Docker via get.docker.com..."
  curl -fsSL https://get.docker.com | sudo sh || die "Docker install failed"
  sudo usermod -aG docker "$USER" || warn "usermod -aG docker failed"
  info "Docker installed (you may need to logout/login for group changes to apply)."
}

start_enable_docker_daemon() {
  if command -v systemctl >/dev/null 2>&1; then
    info "Ensuring docker daemon is enabled & started..."
    sudo systemctl enable --now docker || warn "systemctl start docker failed (continuing, will try retries)"
  else
    warn "systemctl not available; ensure dockerd is running manually."
  fi
}

# Try docker run hello-world with retries, use sudo fallback if needed.
ensure_docker_running() {
  info "Checking Docker functionality (hello-world)..."
  local tries=0 max=12
  while true; do
    if docker run --rm hello-world >/dev/null 2>&1; then
      info "Docker works without sudo."
      return 0
    fi
    # try with sudo
    if sudo docker run --rm hello-world >/dev/null 2>&1; then
      warn "Docker requires sudo. We'll use sudo for Docker calls during this run."
      export SILICON_USE_SUDO_DOCKER=1
      return 0
    fi
    # if docker binary missing
    if ! docker_cli_present; then
      die "docker binary missing after installation. Re-open shell and re-run."
    fi
    ((tries++))
    if [[ $tries -ge $max ]]; then
      die "Docker cannot run containers after retries. Check 'sudo systemctl status docker' and 'sudo journalctl -u docker -n 200'."
    fi
    info "Waiting for docker daemon to be ready... (try $tries/$max)"
    sleep 3
  done
}

docker_cmd() {
  if [[ "${SILICON_USE_SUDO_DOCKER:-0}" == "1" ]]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

setup_docker() {
  info "==== Docker Setup ===="
  if is_wsl; then
    wsl_instructions_and_exit
  fi

  if docker_cli_present; then
    info "Docker binary found."
  else
    install_docker_ubuntu
  fi

  # Ensure daemon started
  start_enable_docker_daemon

  # ensure docker works
  ensure_docker_running
}

# GUI tools best effort
setup_gui_tools() {
  info "==== GUI Tools Setup (Magic / KLayout / xschem) ===="
  if is_wsl; then
    info "WSL detected. WSLg usually provides GUI support if enabled."
  fi
  wait_for_apt_lock
  sudo apt-get update -y
  sudo apt-get install -y magic klayout xschem || warn "Some GUI tools failed to install; layout viewing might be limited."
  info "GUI tools installed/verified (best-effort)."
}

# Clone OpenLane with retries
clone_openlane_repo() {
  info "==== OpenLane Repo + PDK Setup ===="
  mkdir -p "$VLSI_ROOT"
  if [[ -d "$OPENLANE_REPO_DIR" && -d "$OPENLANE_REPO_DIR/.git" ]]; then
    info "OpenLane repo already exists at: $OPENLANE_REPO_DIR"
    return 0
  fi

  local tries=0 max=4
  while [[ $tries -lt $max ]]; do
    if git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_REPO_DIR" 2>&1 | tee -a "$LOGFILE"; then
      info "Cloned OpenLane successfully."
      return 0
    fi
    warn "git clone failed (network/mirror). Retrying... ($((tries+1))/$max)"
    ((tries++))
    sleep 5
  done

  warn "Full clone failed; attempting shallow clone (--depth 1)."
  if git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_REPO_DIR" 2>&1 | tee -a "$LOGFILE"; then
    info "Shallow clone succeeded."
    return 0
  fi

  die "Failed to clone OpenLane repository. Check network and try again."
}

# Run 'make' inside OpenLane to fetch PDK and images; ensure python3-venv present
run_openlane_make() {
  cd "$OPENLANE_REPO_DIR"
  info "Running 'make' inside OpenLane (this may take time)..."

  # Ensure python3-venv exists
  if ! dpkg -s python3-venv >/dev/null 2>&1; then
    info "Installing python3-venv needed for virtualenv creation..."
    wait_for_apt_lock
    sudo apt-get install -y python3-venv || die "Failed to install python3-venv"
  fi

  # Run make. If make fails due to docker permission, try with sudo docker set.
  if make 2>&1 | tee -a "$LOGFILE"; then
    info "OpenLane 'make' completed."
  else
    warn "OpenLane 'make' reported errors. Will continue and check PDK presence."
  fi
}

ensure_pdk() {
  local PDK_ROOT="$OPENLANE_REPO_DIR/pdks"
  if [[ -d "$PDK_ROOT/sky130A" ]]; then
    info "sky130A PDK present at $PDK_ROOT/sky130A"
  else
    warn "sky130A PDK missing at $PDK_ROOT/sky130A. The 'make' step may have failed to download it."
    warn "You can re-run: cd $OPENLANE_REPO_DIR && make"
    # do not die; let flow attempt to run (OpenLane may still work if PDK mounted inside container)
  fi
}

# Prepare inverter (safe config with RUN_TAG and Magic skip)
prepare_inverter_design() {
  info "==== Preparing Sample Inverter Design ===="
  mkdir -p "$INVERTER_DESIGN_DIR"

  cat > "$INVERTER_DESIGN_DIR/inverter.v" <<'EOF'
module inverter (
    input  wire a,
    output wire y
);
  assign y = ~a;
endmodule
EOF

  cat > "$INVERTER_DESIGN_DIR/config.tcl" <<'EOF'
# Inverter demo config (stable & safe)
set ::env(DESIGN_NAME) "inverter"
set ::env(VERILOG_FILES) "$::env(DESIGN_DIR)/inverter.v"
# Force a fixed run tag (avoid mixing leftover run dirs)
set ::env(RUN_TAG) "inv_run"
# Dummy clock for tool compatibility
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_PERIOD) "10"
# Floorplan sizing (safe for tiny design)
set ::env(FP_SIZING) "absolute"
set ::env(DIE_AREA) "0 0 50 50"
set ::env(FP_CORE_UTIL) 10
set ::env(PL_TARGET_DENSITY) 0.30
# Make OpenLane tolerant for very small designs
set ::env(MAGIC_SKIP_DRC) 1
set ::env(QUIT_ON_MAGIC_DRC) 0
set ::env(MAGIC_ALLOW_NON_MANHATTAN) 1
set ::env(RUN_MAGIC) 1
set ::env(GDS_ALLOW_EMPTY) 1
EOF

  info "Inverter design prepared at: $INVERTER_DESIGN_DIR"
}

# Run OpenLane inside container (use docker_cmd wrapper)
run_openlane_design_in_docker() {
  local design="$1"
  [[ -d "$OPENLANE_REPO_DIR" ]] || die "OpenLane repo missing"

  # Clean previous tiny-run artifacts to avoid mixing
  if [[ -d "$OPENLANE_REPO_DIR/designs/$design/runs" ]]; then
    info "Cleaning previous runs for $design to avoid stale state..."
    rm -rf "$OPENLANE_REPO_DIR/designs/$design/runs" || warn "Failed to fully remove previous runs"
  fi

  local uid gid
  uid="$(id -u)" gid="$(id -g)"

  local DOCKER_ARGS=(--rm -u "${uid}:${gid}" -v "$OPENLANE_REPO_DIR":/openlane -w /openlane)
  DOCKER_ARGS+=(-e PDK_ROOT=/openlane/pdks -e PDK=sky130A)

  info "Starting OpenLane flow inside Docker for design: $design"
  # If we need to use sudo for docker, docker_cmd will call sudo docker
  docker_cmd run "${DOCKER_ARGS[@]}" "$OPENLANE_IMAGE" bash -lc "flow.tcl -design ${design} -overwrite" 2>&1 | tee -a "$LOGFILE" || warn "OpenLane flow reported an error. Check logs."
}

open_gds_if_available() {
  local design="$1"
  local gds_path
  gds_path="$(find "$OPENLANE_REPO_DIR/designs/$design" -maxdepth 6 -type f -name '*.gds' | head -n1 || true)"
  if [[ -z "$gds_path" ]]; then
    warn "No GDS file found under designs/$design yet. Check $LOGFILE for errors."
    return 1
  fi
  info "Found GDS: $gds_path"
  if command -v klayout >/dev/null 2>&1; then
    info "Opening GDS in KLayout..."
    (nohup klayout "$gds_path" >/dev/null 2>&1 & disown) || warn "Failed to auto-open KLayout."
  else
    warn "KLayout not installed; cannot auto-open GDS."
  fi
}

# ----------------- main -----------------
main() {
  info "Silicon Craft – Student PD Setup v11"
  info "Workspace: $VLSI_ROOT"

  preflight_prereqs

  if is_wsl; then
    setup_gui_tools   # still attempt gui install if desired
    setup_docker     # will call wsl_instructions_and_exit and exit
    exit 0
  fi

  setup_docker
  setup_gui_tools
  clone_openlane_repo
  run_openlane_make
  ensure_pdk

  prepare_inverter_design

  # Remove very old runs for inverter to avoid MAGIC current_gds errors
  if [[ -d "$OPENLANE_REPO_DIR/designs/inverter/runs" ]]; then
    rm -rf "$OPENLANE_REPO_DIR/designs/inverter/runs" || true
  fi

  run_openlane_design_in_docker inverter

  open_gds_if_available inverter

  info "==== Student PD environment setup finished ===="
  info "If the flow succeeded, you should see OpenLane data under $OPENLANE_REPO_DIR/designs/inverter"
  info "Log file: $LOGFILE"
}

main "$@"

