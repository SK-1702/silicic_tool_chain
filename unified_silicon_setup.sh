#!/bin/bash
# unified_silicon_setup.sh
# The "God Script" for Silicon Craft Toolchain Setup
#
# Merged from 20+ iterations including:
# - v17 (Docker Stability)
# - v15 (APT Self-Healing & Clone Retry)
# - updated2 (Native Build & Complex GUI detection)
# - v20 (Universal Native Flow: Yosys + OpenLane + Interactive)
#
# Features:
# - Auto-detects OS (Ubuntu/WSL/macOS)
# - Self-heals APT errors (locks, mirrors, bad repos)
# - Universal Mode: Supports both Docker AND Native (Source Build)
# - Interactive Mode Ready (Native & Docker)
# - Robust Git cloning (Buffers + Retries)

set -eou pipefail
IFS=$'\n\t'

# ==============================================================================
# CONFIGURATION
# ==============================================================================
VLSI_ROOT="${HOME}/Silicon_Craft_PD_Workspace"
LOGFILE="$VLSI_ROOT/unified_setup.log"
OPENLANE_DIR="$VLSI_ROOT/OpenLane"
OPENROAD_DIR="$VLSI_ROOT/OpenROAD"
YOSYS_DIR="$VLSI_ROOT/yosys"
# Default known-good image
OPENLANE_IMAGE_TAG="ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69"

mkdir -p "$VLSI_ROOT"
# Redirect all output to log and stdout
exec > >(tee -a "$LOGFILE") 2>&1

# ==============================================================================
# LOGGING
# ==============================================================================
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

echo "=========================================================="
echo "   Silicon Craft Unified Setup (Universal Edition)   "
echo "   Date: $(date)"
echo "   Log: $LOGFILE"
echo "=========================================================="

# ==============================================================================
# CORE: OS DETECTION
# ==============================================================================
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

# ==============================================================================
# CORE: APT SELF-HEAL (Embedded)
# ==============================================================================
run_apt_self_heal() {
    if [[ "$OS" == "macOS" ]]; then return; fi
    
    info "Running APT Self-Heal Logic..."
    
    # 1. Wait for Locks
    local retries=20
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        warn "Waiting for apt lock... ($retries left)"
        sleep 5
        retries=$((retries-1))
        [[ $retries -le 0 ]] && die "APT lock stuck. Please reboot."
    done

    # 2. Backup Sources
    if [[ ! -f /etc/apt/sources.list.bak ]]; then
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi

    # 3. Disable CD-ROM
    sudo sed -i 's/^deb cdrom:/# deb cdrom:/g' /etc/apt/sources.list

    # 4. Normalize Mirrors
    sudo sed -i 's|http://in.archive.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list
    
    # 5. Recover dpkg
    sudo dpkg --configure -a || true
    
    # 6. Try Update
    if ! sudo apt-get update; then
        warn "APT update failed. Trying aggressive cleanup..."
        sudo rm -rf /var/lib/apt/lists/*
        sudo apt-get clean
        sudo apt-get update || die "APT is broken. Check internet/proxy."
    fi
    info "APT Self-Heal Complete."
}

# ==============================================================================
# PREFLIGHT DEPENDENCIES
# ==============================================================================
install_base_deps() {
    info "Installing Base Dependencies..."
    if [[ "$OS" == "Linux" || "$OS" == "WSL" ]]; then
        run_apt_self_heal
        sudo apt-get install -y git curl wget build-essential make python3 python3-pip python3-venv \
                                tcllib xz-utils software-properties-common ca-certificates gnupg lsb-release \
                                magic klayout xschem || warn "Some packages (GUI) failed."
    elif [[ "$OS" == "macOS" ]]; then
        if ! command -v brew >/dev/null; then
             /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew install git python3 make python-tk
    fi
}

# ==============================================================================
# HELPER: GUI AUTO-CONFIG
# ==============================================================================
setup_gui_environment() {
    info "Configuring GUI Environment..."
    if [[ "$OS" == "WSL" ]]; then
        if [[ -d /mnt/wslg ]]; then
            info "WSLg detected (Native Wayland/X11)."
            export DISPLAY="${DISPLAY:-:0}"
        else
            info "WSLg not detected. Configuring X11 Forwarding (VCXSRV)..."
            HOST_IP=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
            export DISPLAY="${DISPLAY:-${HOST_IP:-:0}:0}"
            export LIBGL_ALWAYS_INDIRECT=1
            echo "export DISPLAY=$DISPLAY" >> "$VLSI_ROOT/env.sh"
            echo "export LIBGL_ALWAYS_INDIRECT=1" >> "$VLSI_ROOT/env.sh"
        fi
    elif [[ "$OS" == "Linux" ]]; then
         [[ -z "${DISPLAY:-}" ]] && export DISPLAY=":0"
    fi
}

# ==============================================================================
# HELPER: PERSISTENCE
# ==============================================================================
persist_env() {
    info "Making configuration permanent..."
    local ENV_FILE="$VLSI_ROOT/env.sh"
    touch "$ENV_FILE"
    
    local SOURCE_CMD="source \"$ENV_FILE\""
    
    # Check if already in bashrc
    if ! grep -Fq "$SOURCE_CMD" "$HOME/.bashrc"; then
        echo "" >> "$HOME/.bashrc"
        echo "# Silicon Craft Toolchain Setup" >> "$HOME/.bashrc"
        echo "$SOURCE_CMD" >> "$HOME/.bashrc"
        info "Added startup command to ~/.bashrc"
    else
        info "~/.bashrc already configured."
    fi
}

# ==============================================================================
# HELPER: RESOURCE CHECK
# ==============================================================================
CHECKED_CORES=$(nproc)
check_resources() {
    if [[ "$OS" == "Linux" || "$OS" == "WSL" ]]; then
        local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        if [[ $total_ram_kb -lt 16000000 ]]; then
            warn "Detected less than 16GB RAM."
            warn "Switching to 'Safe Mode' (Low Parallelism)."
            CHECKED_CORES=2
            if [[ $total_ram_kb -lt 8000000 ]]; then
                 warn "Very Low RAM (<8GB). Using single thread."
                 CHECKED_CORES=1
            fi
        else
            info "RAM looks good. Using full power ($CHECKED_CORES cores)."
        fi
    fi
}

# ==============================================================================
# HELPER: GIT CLONE ROBUST
# ==============================================================================
git_bootstrap() {
    git config --global http.postBuffer 1048576000
    git config --global http.lowSpeedLimit 0
    git config --global http.lowSpeedTime 999999

    local target_dir="$1"
    local repo_url="$2"
    
    if [[ -d "$target_dir" ]]; then
        info "Repo directory exists at $target_dir"
        if [[ ! -d "$target_dir/.git" ]]; then
            warn "Directory exists but is not a valid git repo. Deleting and re-cloning..."
            rm -rf "$target_dir"
        else
            info "Pulling updates..."
            (cd "$target_dir" && git pull) || warn "Git pull failed."
            return
        fi
    fi

    for i in 1 2 3; do
        info "Cloning $(basename "$repo_url") (Attempt $i)..."
        if git clone --depth 1 "$repo_url" "$target_dir"; then
            return 0
        fi
        warn "Clone failed. Retrying in 10s..."
        sleep 10
    done
    die "Failed to clone $repo_url after 3 attempts."
}

# ==============================================================================
# HELPER: NATIVE PDK (Volare)
# ==============================================================================
install_pdk_native() {
    info "Installing Sky130 PDK (Native)..."
    if ! command -v volare >/dev/null; then
        info "Installing Volare..."
        # PEP 668 Fix: Try with --break-system-packages (newer Ubuntu), fall back to standard (older Ubuntu)
        pip3 install volare --user --break-system-packages || pip3 install volare --user || die "Failed to install volare."
        export PATH="$HOME/.local/bin:$PATH"
    fi
    export PDK_ROOT="$VLSI_ROOT/pdk"
    mkdir -p "$PDK_ROOT"
    info "Downloading Sky130 PDK to $PDK_ROOT..."
    volare enable --pdk sky130 --pdk-root "$PDK_ROOT" 78b7bc32ddb4b6f14f76883c2e2dc5b5de9d1cbc
    info "PDK Installed."
    echo "export PDK_ROOT=$PDK_ROOT" >> "$VLSI_ROOT/env.sh"
    echo "export PDK=sky130A" >> "$VLSI_ROOT/env.sh"
}

# ==============================================================================
# MODE 1: DOCKER FLOW
# ==============================================================================
setup_docker_mode() {
    info "==== DOCKER MODE ===="
    
    if ! command -v docker >/dev/null; then
        if [[ "$OS" == "WSL" ]]; then
            err "Docker command not found in WSL."
            die "Please install Docker Desktop on Windows and enable WSL Integration."
        elif [[ "$OS" == "Linux" ]]; then
            warn "Docker not found. Installing..."
            curl -fsSL https://get.docker.com | sudo sh
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon not reachable. Attempting fix..."
        sudo usermod -aG docker "$USER" || true
        die "Docker daemon not running inside WSL/Linux. If you just added yourself to group, please REBOOT."
    fi
    
    git_bootstrap "$OPENLANE_DIR" "https://github.com/The-OpenROAD-Project/OpenLane.git"
    cd "$OPENLANE_DIR"
    info "Building/Pulling OpenLane Environment..."
    make
    
    info "Docker Mode Complete."
}

# ==============================================================================
# MODE 2: NATIVE / UNIVERSAL FLOW
# ==============================================================================
install_yosys_native() {
    info "Checking/Installing Yosys (Essential for Native Flow)..."
    if command -v yosys >/dev/null; then
        info "Yosys already installed: $(yosys -V)"
        return
    fi
    
    info "Building Yosys from source..."
    git_bootstrap "$YOSYS_DIR" "https://github.com/YosysHQ/yosys.git"
    cd "$YOSYS_DIR"
    make config-gcc
    make -j"$CHECKED_CORES"
    sudo make install
    info "Yosys built and installed."
}

setup_native_mode() {
    info "==== NATIVE UNIVERSAL MODE ===="
    if [[ "$OS" != "Linux" && "$OS" != "WSL" ]]; then
        die "Native mode strictly requires Linux/WSL (Ubuntu 20.04+)."
    fi

    # 1. Extensive Deps
    info "Installing Universal Native Dependencies..."
    run_apt_self_heal
    sudo apt-get install -y build-essential cmake python3-dev python3-pip python3-venv \
       libeigen3-dev libboost-all-dev tcl-dev tk-dev libx11-dev libglu1-mesa-dev \
       libglew-dev libxmu-dev libxi-dev pkg-config ninja-build libyaml-cpp-dev \
       flex bison libreadline-dev libffi-dev qtbase5-dev qt5-qmake libqt5svg5-dev \
       gperf || warn "Some packages failed."

    # 1.5 Prepare Env
    mkdir -p "$VLSI_ROOT/external/install"
    
    # 2. Build Yosys (New for Universal)
    install_yosys_native

    # 3. Yaml-cpp (Source Build Fix)
    if ! sudo find /usr -name "yaml-cppConfig.cmake" | grep -q yaml; then
        info "Building yaml-cpp from source..."
        cd "$VLSI_ROOT/external"
        git_bootstrap "yaml-cpp" "https://github.com/jbeder/yaml-cpp.git"
        cd yaml-cpp && mkdir -p build && cd build
        cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX="$VLSI_ROOT/external/install"
        make -j"$CHECKED_CORES" && make install
        export CMAKE_PREFIX_PATH="$VLSI_ROOT/external/install:${CMAKE_PREFIX_PATH:-}"
    fi

    # 4. Spdlog
    if [[ ! -f "$VLSI_ROOT/external/install/lib/libspdlog.a" ]]; then
        info "Building spdlog..."
        cd "$VLSI_ROOT/external"
        git_bootstrap "spdlog" "https://github.com/gabime/spdlog.git"
        cd spdlog && git checkout v1.12.0 || true
        mkdir -p build && cd build
        cmake .. -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DSPDLOG_FMT_EXTERNAL=OFF -DCMAKE_INSTALL_PREFIX="$VLSI_ROOT/external/install"
        make -j"$CHECKED_CORES" && make install
    fi

    # 5. OpenROAD Build
    info "Cloning OpenROAD..."
    git_bootstrap "$OPENROAD_DIR" "https://github.com/The-OpenROAD-Project/OpenROAD.git"
    cd "$OPENROAD_DIR"
    git submodule update --init --recursive

    # C++20 Fixes (System Lemon Header Patch)
    if [[ -f "/usr/include/lemon/bits/array_map.h" ]]; then
        if grep -q "allocator.construct" "/usr/include/lemon/bits/array_map.h"; then
             info "Patching system LEMON header for C++20..."
             sudo sed -i 's/allocator\.construct(&(\(.*\)), \(.*\));/std::allocator_traits<Allocator>::construct(allocator, \&(\1), \2);/g' /usr/include/lemon/bits/array_map.h
             sudo sed -i 's/allocator\.destroy(&(\(.*\)));/std::allocator_traits<Allocator>::destroy(allocator, \&(\1));/g' /usr/include/lemon/bits/array_map.h
        fi
    fi

    info "Compiling OpenROAD..."
    export CC=gcc CXX=g++ CFLAGS="-std=gnu11" CXXFLAGS="-std=gnu++20" OPENROAD_DISABLE_LEMON_ALLOCATOR=1
    
    if [[ -x "$OPENROAD_DIR/build/src/openroad" ]]; then
        info "✅ OpenROAD binary found at $OPENROAD_DIR/build/src/openroad"
        info "Skipping recompilation to save time."
    else
        rm -rf build && mkdir build && cd build
        (cd .. && git checkout CMakeLists.txt)
        cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF -DBUILD_TESTING=OFF
        make -j"$CHECKED_CORES"
        info "Native Build Complete (OpenROAD)."
    fi
    
    # 6. Install PDK
    install_pdk_native

    # 7. Configure OpenLane Native
    info "Setting up OpenLane Native Environment..."
    git_bootstrap "$OPENLANE_DIR" "https://github.com/The-OpenROAD-Project/OpenLane.git"
    
    # Export Critical Env Vars for Native Mode
    echo "export OPENLANE_ROOT=$OPENLANE_DIR" >> "$VLSI_ROOT/env.sh"
    echo "export PATH=$OPENROAD_DIR/build/src:\$PATH" >> "$VLSI_ROOT/env.sh"
    echo "export OPENLANE_LOCAL_INSTALL=1" >> "$VLSI_ROOT/env.sh"
    
    info "✅ Native Universal Setup Complete."
    info "To run interactive mode: cd $OPENLANE_DIR && ./flow.tcl -interactive"
}

# ==============================================================================
# MAIN ENTRY POINT
# ==============================================================================
install_base_deps
setup_gui_environment

echo ""
echo "Select Setup Mode:"
echo " 1) Docker (Standard/Student) - Safe, Containerized."
echo " 2) Native (Expert/Universal) - Compiles Yosys, OpenROAD, OpenLane locally."
read -p "Choice [1/2]: " CHOICE

case "$CHOICE" in
    1) setup_docker_mode ;;
    2) 
       check_resources 
       setup_native_mode 
       ;;
    *) die "Invalid choice." ;;
esac

persist_env

info "Done. Log file: $LOGFILE"
info "Please restart your terminal."
