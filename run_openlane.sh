#!/usr/bin/env bash
set -euo pipefail

# ---------------- Usage ----------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <design_name>"
  exit 1
fi

DESIGN_NAME="$1"

# ---------------- Paths ----------------
VLSI_ROOT="$HOME/Silicon_Craft_PD_Workspace"
OPENLANE_REPO_DIR="$VLSI_ROOT/OpenLane"
LOGFILE="$VLSI_ROOT/run_${DESIGN_NAME}.log"

OPENLANE_IMAGE="ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69"

# ---------------- Sanity checks ----------------
if [[ ! -d "$OPENLANE_REPO_DIR/designs/$DESIGN_NAME" ]]; then
  echo "[ERROR] Design '$DESIGN_NAME' not found at:"
  echo "        $OPENLANE_REPO_DIR/designs/$DESIGN_NAME"
  exit 1
fi

uid="$(id -u)"
gid="$(id -g)"

# ---------------- Mode selection ----------------
echo
echo "Select OpenLane run mode:"
echo "  1) Non-interactive (full RTL → GDS)"
echo "  2) Interactive (step-by-step Tcl shell)"
echo
read -rp "Enter choice [1 or 2]: " MODE

echo
echo "[INFO] Design      : $DESIGN_NAME"
echo "[INFO] OpenLane dir: $OPENLANE_REPO_DIR"
echo "[INFO] Docker image: $OPENLANE_IMAGE"
echo

# ============================================================
# Non-interactive mode
# ============================================================
if [[ "$MODE" == "1" ]]; then
  echo "[INFO] Running NON-INTERACTIVE OpenLane flow"
  echo "[INFO] Log: $LOGFILE"

  docker run --rm \
    -u "${uid}:${gid}" \
    -v "${OPENLANE_REPO_DIR}:/openlane" \
    -w /openlane \
    -e PDK_ROOT=/openlane/pdks \
    -e PDK=sky130A \
    -e PWD=/openlane \
    "$OPENLANE_IMAGE" \
    ./flow.tcl -design "$DESIGN_NAME" -overwrite \
    2>&1 | tee "$LOGFILE"

  echo "[INFO] Flow finished for $DESIGN_NAME"

  # ---- Auto-open GDS if present ----
  GDS_PATH="$(find "$OPENLANE_REPO_DIR/designs/$DESIGN_NAME" -maxdepth 6 -name '*.gds' 2>/dev/null | head -n1 || true)"

  if [[ -n "$GDS_PATH" ]]; then
    echo "[INFO] Found GDS: $GDS_PATH"
    if command -v klayout >/dev/null 2>&1; then
      echo "[INFO] Opening GDS in KLayout..."
      (nohup klayout "$GDS_PATH" >/dev/null 2>&1 & disown) || true
    else
      echo "[WARN] KLayout not installed; cannot auto-open GDS."
    fi
  else
    echo "[WARN] No GDS found yet. Check log:"
    echo "       $LOGFILE"
  fi

# ============================================================
# Interactive mode
# ============================================================
elif [[ "$MODE" == "2" ]]; then
  echo "[INFO] Starting INTERACTIVE OpenLane shell"
  echo
  echo "Inside OpenLane, run:"
  echo "  prep -design $DESIGN_NAME -tag ${DESIGN_NAME}_int -overwrite"
  echo "  run_synthesis"
  echo "  run_floorplan"
  echo "  run_placement"
  echo "  run_cts"
  echo "  run_routing"
  echo "  run_magic"
  echo "  run_lvs"
  echo
  echo "TIP: If you hit 'PWD not defined', run:"
  echo "  set ::env(PWD) [pwd]"
  echo

  docker run --rm -it \
    -u "${uid}:${gid}" \
    -v "${OPENLANE_REPO_DIR}:/openlane" \
    -w /openlane \
    -e PDK_ROOT=/openlane/pdks \
    -e PDK=sky130A \
    -e PWD=/openlane \
    "$OPENLANE_IMAGE" \
    ./flow.tcl -interactive

else
  echo "[ERROR] Invalid choice. Enter 1 or 2."
  exit 1
fi

