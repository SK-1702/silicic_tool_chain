#!/usr/bin/env bash
set -e

############################################
# Silicon Craft – APT Auto Self-Heal Script
# Purpose:
#   Fix mirror sync, DEP-11, bad PPAs,
#   CD-ROM repos, broken dpkg state
#
# Supported: Ubuntu 22.04 / 24.04
############################################

# --- Root check ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root:"
  echo "   sudo $0"
  exit 1
fi

echo "🔧 Silicon Craft – APT Auto Self-Heal Starting..."

# --- Backup sources ---
echo "📦 Backing up sources.list"
cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%F_%T)

# --- Disable CD-ROM entries ---
echo "🚫 Disabling CD-ROM repositories"
sed -i 's/^deb cdrom:/# deb cdrom:/g' /etc/apt/sources.list

# --- Normalize mirrors (India → global fallback) ---
echo "🌐 Normalizing Ubuntu mirrors"
sed -i 's|http://in.archive.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list

# --- Fix mirrors in sources.list.d ---
echo "📂 Fixing mirrors in sources.list.d"
for f in /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] || continue
  sed -i 's|http://in.archive.ubuntu.com|http://archive.ubuntu.com|g' "$f"
done

# --- Remove obsolete LLVM Xenial repo ---
echo "🧹 Removing obsolete LLVM Xenial repo"
rm -f /etc/apt/sources.list.d/llvm-toolchain-xenial*.list || true

# --- Disable DEP-11 metadata (hash mismatch killer) ---
echo "🛑 Disabling DEP-11 metadata downloads"
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99no-dep11 << 'EOF'
Acquire::IndexTargets {
  deb::DEP-11 {
    DefaultEnabled "false";
  };
};
EOF

# --- dpkg recovery ---
echo "🔁 Recovering dpkg state (if needed)"
dpkg --configure -a || true

# --- Full APT cleanup ---
echo "🧹 Cleaning APT cache"
rm -rf /var/lib/apt/lists/*
apt clean
apt autoclean

# --- Retry apt update ---
echo "🔄 Running apt update (retry-safe)"
if apt update; then
  echo "✅ APT self-heal completed successfully."
else
  echo "❌ APT update still failing."
  echo "👉 Please check network or proxy and retry later."
  exit 1
fi

