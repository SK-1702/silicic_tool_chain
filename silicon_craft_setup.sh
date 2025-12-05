#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##############################################
# Silicon Craft VLSI RTL2GDS Setup Script
# Docker-based OpenLane + Automatic GUI Support
# Supports: Ubuntu (native), WSL2, macOS
##############################################

VLSI_ROOT="${VLSI_ROOT:-$HOME/Silicon_Craft_tool_setup}"
OPENLANE_IMAGE="${OPENLANE_IMAGE:-ghcr.io/efabless/openlane:latest}"
LOGFILE="$VLSI_ROOT/openlane_inverter_test.log"
INVERTER_DESIGN_DIR="$VLSI_ROOT/OpenLane/designs/inverter"
GUI_OK=0

info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

# ---------------------
# Detect OS: Linux / WSL / macOS
# ---------------------
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS"
    elif [[ -f /proc/version ]] && grep -qi microsoft /proc/version; then
        echo "WSL"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Linux"
    else
        echo "Unsupported"
    fi
}

OS=$(detect_os)
info "Detected OS: $OS"
if [[ "$OS" == "Unsupported" ]]; then
    die "Unsupported OS. Supported: macOS, Linux, WSL."
fi

# ---------------------
# Helpers: apt / brew install-if-missing
# ---------------------
apt_install_if_missing(){
    pkg="$1"
    cmd_check="$2" # command to check for presence (e.g. magic, klayout)
    if ! command -v ${cmd_check} >/dev/null 2>&1; then
        info "Installing $pkg via apt..."
        sudo apt-get update -y
        sudo apt-get install -y "$pkg"
    else
        info "$pkg already installed (skipping apt install)."
    fi
}

brew_install_if_missing(){
    formula="$1"
    cmd_check="$2"
    if ! command -v ${cmd_check} >/dev/null 2>&1; then
        info "Installing $formula via brew..."
        brew install "$formula" || true
    else
        info "$formula already installed (skipping brew install)."
    fi
}

# ---------------------
# GUI Auto-detection + Auto-fix
# ---------------------
setup_gui_environment(){
    info "Starting GUI auto-configuration..."
    mkdir -p "$VLSI_ROOT"
    case "$OS" in
        "WSL")
            # prefer WSLg if available
            if [[ -d /mnt/wslg ]]; then
                info "WSLg detected. Using WSLg display."
                export DISPLAY="${DISPLAY:-:0}"
                export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"
                GUI_BACKEND="wslg"
            else
                info "No WSLg detected. Setting up X server fallback (VcXsrv) and X11 support."
                # Install necessary host packages in WSL
                sudo apt-get update -y
                sudo apt-get install -y x11-apps mesa-utils dbus-x11 xauth || true

                # Try to auto-start VcXsrv on Windows via powershell (best-effort)
                if command -v powershell.exe >/dev/null 2>&1; then
                    # download and install vcxsrv silently if not present
                    VCXSRV_EXE="/mnt/c/Program Files/VcXsrv/vcxsrv.exe"
                    if [[ ! -f "$VCXSRV_EXE" ]]; then
                        info "Downloading VcXsrv installer on Windows (silent install)..."
                        powershell.exe -Command "Invoke-WebRequest -Uri 'https://github.com/ArcticaProject/vcxsrv/releases/latest/download/vcxsrv-setup.exe' -OutFile 'vcxsrv-setup.exe'"
                        powershell.exe -Command "Start-Process -FilePath 'vcxsrv-setup.exe' -ArgumentList '/S' -Wait"
                    else
                        info "VcXsrv already installed on Windows."
                    fi
                    info "Starting VcXsrv on Windows..."
                    powershell.exe -Command "Start-Process -FilePath 'C:\\Program Files\\VcXsrv\\vcxsrv.exe' -ArgumentList ':0 -multiwindow -clipboard -silent-dup-error' -WindowStyle Hidden" >/dev/null 2>&1 || true
                else
                    warn "powershell.exe not available from WSL — cannot auto-install/start VcXsrv. Will attempt DISPLAY export."
                fi

                # set DISPLAY based on host resolver
                if grep -q nameserver /etc/resolv.conf 2>/dev/null; then
                    HOST_IP=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
                    export DISPLAY="${HOST_IP}:0.0"
                else
                    export DISPLAY=":0"
                fi
                export LIBGL_ALWAYS_INDIRECT=1
                GUI_BACKEND="vcxsrv"
            fi
            ;;
        "Linux")
            info "Native Linux detected. Ensuring X11 basics are installed."
            # If no DISPLAY present, try to install X client packages (non-destructive)
            if [[ -z "${DISPLAY:-}" ]]; then
                export DISPLAY=":0"
            fi
            sudo apt-get update -y
            sudo apt-get install -y x11-apps mesa-utils libx11-6 libglu1-mesa || true
            GUI_BACKEND="x11"
            ;;
        "macOS")
            info "macOS detected. Ensuring XQuartz is installed."
            if ! command -v brew >/dev/null 2>&1; then
                info "Homebrew not found. Installing Homebrew (non-interactive)..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null || true
                # ensure brew in PATH for this session
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
            fi
            if ! pgrep -x XQuartz >/dev/null 2>&1; then
                if ! command -v XQuartz >/dev/null 2>&1; then
                    info "Installing XQuartz via brew cask..."
                    brew install --cask xquartz || true
                fi
                info "Starting XQuartz..."
                open -a XQuartz || true
            else
                info "XQuartz already running."
            fi
            export DISPLAY="${DISPLAY:-:0}"
            GUI_BACKEND="xquartz"
            ;;
        *)
            warn "Unknown OS for GUI setup."
            GUI_BACKEND="none"
            ;;
    esac

    # Install GUI viewers (idempotent)
    info "Installing / verifying Magic, KLayout, Xschem (host viewers)."
    case "$OS" in
        "macOS")
            # brew installs might not have exact formulas; attempt best-effort
            if ! command -v magic >/dev/null 2>&1; then
                brew install magic || true
            else
                info "magic present"
            fi
            if ! command -v klayout >/dev/null 2>&1; then
                brew install klayout || true
            else
                info "klayout present"
            fi
            if ! command -v xschem >/dev/null 2>&1; then
                brew install xschem || true
            else
                info "xschem present"
            fi
            ;;
        *)
            # Ubuntu/WSL
            if ! command -v magic >/dev/null 2>&1; then
                sudo apt-get install -y magic || true
            else
                info "magic present"
            fi
            if ! command -v klayout >/dev/null 2>&1; then
                sudo apt-get install -y klayout || true
            else
                info "klayout present"
            fi
            if ! command -v xschem >/dev/null 2>&1; then
                sudo apt-get install -y xschem || true
            else
                info "xschem present"
            fi
            ;;
    esac

    # GUI test: try launching magic in background (silent) to verify display
    info "Validating GUI by launching Magic (silent)..."
    if command -v magic >/dev/null 2>&1; then
        # try to run magic in XR mode without console; allow it short time to start then kill
        if (magic -d XR -noconsole </dev/null >/dev/null 2>&1 &); then
            sleep 2
            # if process exists, assume ok
            pkill -f "magic" >/dev/null 2>&1 || true
            GUI_OK=1
            info "Magic launched successfully — GUI functional."
        else
            warn "Magic failed to launch in GUI mode. Attempting repair steps..."
            GUI_OK=0
        fi
    else
        warn "Magic not found on host; GUI viewers unavailable."
        GUI_OK=0
    fi

    # If GUI failed, attempt a lightweight repair (restart X server / re-export DISPLAY)
    if [[ "$GUI_OK" -ne 1 ]]; then
        warn "Attempting GUI repair..."
        case "$OS" in
            "WSL")
                # re-export display from resolv.conf and retry
                if grep -q nameserver /etc/resolv.conf 2>/dev/null; then
                    HOST_IP=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
                    export DISPLAY="${HOST_IP}:0.0"
                else
                    export DISPLAY=":0"
                fi
                export LIBGL_ALWAYS_INDIRECT=1
                ;;
            "Linux")
                export DISPLAY=":0"
                ;;
            "macOS")
                open -a XQuartz || true
                export DISPLAY=":0"
                ;;
        esac
        sleep 2
        if command -v magic >/dev/null 2>&1 && (magic -d XR -noconsole </dev/null >/dev/null 2>&1 &) ; then
            sleep 2
            pkill -f "magic" >/dev/null 2>&1 || true
            GUI_OK=1
            info "GUI repair succeeded."
        else
            warn "Automatic GUI repair failed. GUI will be considered unavailable and flow will proceed headless."
            GUI_OK=0
        fi
    fi

    info "GUI configuration finished (backend: ${GUI_BACKEND})."
}

# ---------------------
# Install Docker if missing
# ---------------------
check_docker(){
    command -v docker >/dev/null 2>&1
}

install_docker_linux(){
    info "Installing Docker Engine (get.docker.com)..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    info "Docker installed. You may need to re-login for group to take effect."
}

install_docker_mac(){
    die "Please install Docker Desktop manually on macOS: https://www.docker.com/products/docker-desktop/"
}

# ---------------------
# Prepare OpenLane inverter design
# ---------------------
prepare_inverter_design(){
    mkdir -p "$INVERTER_DESIGN_DIR"
    cat > "$INVERTER_DESIGN_DIR/config.json" <<'EOF'
{
    "DESIGN_NAME": "inverter",
    "VERILOG_FILES": "dir::inverter.v",
    "CLOCK_PERIOD": 10
}
EOF

    cat > "$INVERTER_DESIGN_DIR/inverter.v" <<'EOF'
module inverter (
    input  wire a,
    output wire y
);
assign y = ~a;
endmodule
EOF
    info "Inverter design prepared at $INVERTER_DESIGN_DIR"
}

# ---------------------
# run OpenLane inside docker (with optional GUI forwarding)
# ---------------------
run_openlane_inverter(){
    info "Running OpenLane inverter flow inside Docker. Logs -> $LOGFILE"

    mkdir -p "$VLSI_ROOT/OpenLane/designs"
    mkdir -p "$VLSI_ROOT/pdks"
    mkdir -p "$VLSI_ROOT/results"

    # GUI forwarding - pass DISPLAY and X11 socket if GUI is configured on host
    DOCKER_RUN=(docker run --rm -u "$(id -u):$(id -g)")
    # mount designs and pdks
    DOCKER_RUN+=(-v "$VLSI_ROOT/OpenLane/designs":/openlane/designs -v "$VLSI_ROOT/pdks":/openlane/pdks -v "$VLSI_ROOT/results":/openlane/results -w /openlane/designs)
    # forward X11 if GUI available
    if [[ "${DISPLAY:-}" != "" ]]; then
        # mount X11 socket if exists
        if [[ -S /tmp/.X11-unix/X0 ]]; then
            DOCKER_RUN+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
        fi
        DOCKER_RUN+=(-e DISPLAY="$DISPLAY")
        # for WSL with X server on host IP, also set LIBGL_ALWAYS_INDIRECT
        if [[ -n "${LIBGL_ALWAYS_INDIRECT:-}" ]]; then
            DOCKER_RUN+=(-e LIBGL_ALWAYS_INDIRECT=1)
        fi
        # mount runtime dir if present
        if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]]; then
            DOCKER_RUN+=(-v "$XDG_RUNTIME_DIR":"$XDG_RUNTIME_DIR" -e XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR")
        fi
    fi

    # append image and command
    DOCKER_RUN+=("$OPENLANE_IMAGE" "flow.tcl -design inverter -overwrite")

    # run and tee logs
    "${DOCKER_RUN[@]}" 2>&1 | tee "$LOGFILE" || return 1
    return 0
}

# ---------------------
# Auto-open layout in host viewer (if GUI OK)
# ---------------------
open_layout_if_available(){
    # try to find final gds path
    GDS_PATH="$(find "$VLSI_ROOT/OpenLane/designs/inverter" -type f -path "*/results/*/final/*.gds" -print -quit || true)"
    # fallback: find any .gds under runs
    if [[ -z "$GDS_PATH" ]]; then
        GDS_PATH="$(find "$VLSI_ROOT/OpenLane/designs/inverter" -type f -name '*.gds' -print -quit || true)"
    fi

    if [[ -z "$GDS_PATH" ]]; then
        warn "No GDS file found to open."
        return
    fi

    info "GDS found at: $GDS_PATH"

    if [[ "$GUI_OK" -eq 1 ]]; then
        if command -v klayout >/dev/null 2>&1; then
            info "Launching KLayout to view GDS..."
            nohup klayout "$GDS_PATH" >/dev/null 2>&1 & disown || true
        elif command -v magic >/dev/null 2>&1; then
            info "Launching Magic to view GDS..."
            nohup magic -T "$GDS_PATH" >/dev/null 2>&1 & disown || true
        else
            warn "No host viewer (klayout/magic) available to open GDS."
        fi
    else
        info "GUI not available; skipping automatic layout opening."
    fi
}

# ---------------------
# Main flow
# ---------------------
main(){
    info "Starting Silicon Craft setup (root: $VLSI_ROOT)"

    # create root
    mkdir -p "$VLSI_ROOT"

    # 1) Setup GUI environment (auto-detect & auto-fix)
    setup_gui_environment

    # 2) Docker setup
    info "Checking Docker..."
    if check_docker; then
        info "Docker present."
    else
        if [[ "$OS" == "macOS" ]]; then
            install_docker_mac
        else
            install_docker_linux
        fi
    fi

    # quick docker health test
    info "Testing Docker by running hello-world..."
    if ! docker run --rm hello-world >/dev/null 2>&1; then
        warn "docker hello-world failed. Trying again after short wait..."
        sleep 3
        if ! docker run --rm hello-world >/dev/null 2>&1; then
            die "Docker not functioning correctly. Please ensure Docker daemon is running."
        fi
    fi
    info "Docker is functioning."

    # 3) Pull OpenLane image (idempotent)
    info "Ensuring OpenLane docker image: $OPENLANE_IMAGE"
    if docker image inspect "$OPENLANE_IMAGE" >/dev/null 2>&1; then
        info "OpenLane image already present. Pulling to refresh manifest..."
        docker pull "$OPENLANE_IMAGE" >/dev/null 2>&1 || true
    else
        info "Pulling OpenLane image..."
        docker pull "$OPENLANE_IMAGE"
    fi

    # 4) Prepare inverter design
    prepare_inverter_design

    # 5) Run flow
    if run_openlane_inverter; then
        info "OpenLane inverter flow finished. Log: $LOGFILE"
    else
        warn "OpenLane inverter flow returned error. Check the log at $LOGFILE"
        # proceed to attempt open anyway if GDS exists
    fi

    # 6) Decide whether GUI is available (GUI_OK set earlier by setup step)
    if [[ "$GUI_OK" -eq 1 ]]; then
        info "GUI available on host. Will attempt to open final GDS automatically."
    else
        info "GUI not available on host. Skipping auto-open."
    fi

    open_layout_if_available

    info "Silicon Craft OpenLane setup completed. Workspace: $VLSI_ROOT"
}

main

