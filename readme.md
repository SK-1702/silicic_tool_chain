---

# Silicon Craft – OpenLane Student PD Flow (sky130A)

End-to-end flow for running **RTL → GDS** using OpenLane (sky130A) on WSL/Ubuntu, with:

* One-shot **toolchain setup**
* A **design runner** script with:

  * **Mode 1:** Non-interactive full flow
  * **Mode 2:** Interactive, step-by-step PD flow
* Final **GDS view in KLayout**

---

## 0. Directory Layout (Assumed)

```text
$HOME/
 ├─ silicic_tool_chain/
 │   ├─ silicon_craft_pd_setupv2.sh      <-- toolchain installer
 │   └─ run_openlane.sh                <-- design runner (interactive/non)
 └─ Silicon_Craft_PD_Workspace/
     └─ OpenLane/                      <-- OpenLane repo + pdks + designs
```

If your paths differ, adjust commands accordingly.

---

## 1. One-Time Toolchain Setup

### 1.1. Make the installer executable

From your scripts folder:

```bash
cd ~/silicic_tool_chain

chmod +x silicon_craft_pd_setupv2.sh
```

### 1.2. Run the installer

```bash
./silicon_craft_pd_setupv2.sh
```

This script will:

* Install base packages (git, Python, Docker tools, etc.)
* Install GUI tools: **Magic, KLayout, xschem** (WSLg friendly)
* Clone **OpenLane** into:
  `~/Silicon_Craft_PD_Workspace/OpenLane`
* Install & enable **sky130A PDK** via `ciel`
* Pull the OpenLane Docker image:
  `ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69`
* Run a **test inverter design**, and (if all good) auto-open `inverter.gds` in KLayout

If inverter GDS opens in KLayout at the end, your **toolchain is ready**.

---

## 2. Design Runner Script – Setup

```bash
~/silicic_tool_chain/run_openlane.sh
```

Then:

```bash
cd ~/silicic_tool_chain
chmod +x run_openlane.sh
```

---

## 3. Preparing a Design

Each design lives under:

```text
~/Silicon_Craft_PD_Workspace/OpenLane/designs/<design_name>/
```

Minimum contents:

* `config.tcl` – OpenLane configuration (PDK, clocks, etc.)
* RTL files – e.g. `picorv32a.v`, or `and_gate.v`, etc.

Example designs you already have:

You can copy from existing OpenLane reference designs as a template.

---

## 4. Non-Interactive Flow (Full RTL → GDS)

This is the **student-friendly, one-shot flow**.

From your scripts folder:

```bash
cd ~/silicic_tool_chain
./run_openlane.sh picorv32a
```

When prompted:

```text
Select OpenLane run mode:
  1) Non-interactive (full RTL → GDS)
  2) Interactive (step-by-step Tcl shell)

Enter choice [1 or 2]: 1
```

The script will:

* Launch OpenLane (inside Docker)
* Run the **full flow**:

  * synthesis
  * STA
  * floorplan
  * placement
  * CTS
  * routing
  * signoff (LVS, DRC, antenna, IR drop)
* Save logs under:
  `~/Silicon_Craft_PD_Workspace/run_picorv32a.log`
* Write final views under:
  `~/Silicon_Craft_PD_Workspace/OpenLane/designs/picorv32a/runs/RUN_YYYY.MM.DD_HH.MM.SS/results/final/`

### 4.1. Final GDS Location

Expected final GDS:

```text
~/Silicon_Craft_PD_Workspace/OpenLane/designs/picorv32a/
  runs/<run_tag>/results/final/gds/picorv32a.gds
```

The `run_openlane.sh` script:

* Searches for `results/final/gds/*.gds`
* Prints its path
* If `klayout` is installed, **auto-opens** it.

If auto-open fails, you can open manually:

```bash
cd ~/Silicon_Craft_PD_Workspace/OpenLane
klayout designs/picorv32a/runs/<run_tag>/results/final/gds/picorv32a.gds &
```

---

## 5. Interactive Flow (Step-by-Step PD)

This is the **trainer / deep-learning** flow.

### 5.1. Start interactive shell

From scripts folder:

```bash
cd ~/silicic_tool_chain
./run_openlane.sh picorv32a
```

When prompted:

```text
Enter choice [1 or 2]: 2
```

You will enter the **OpenLane Tcl shell** inside Docker:

```text
%   <-- OpenLane prompt
```

Make sure you’re in `/openlane` (it’s the mapped OpenLane repo).

---

### 5.2. Step-By-Step Commands (Example: `picorv32a`)

#### 1️⃣ Prep the design

```tcl
% prep -design picorv32a -tag picor_int -overwrite
```

This creates:

```text
designs/picorv32a/runs/picor_int/
```

with all temp/log/result dirs.

---

#### 2️⃣ Synthesis

```tcl
% run_synthesis
```

Outputs (inside `runs/picor_int/`):

* `results/synthesis/picorv32a.synthesis.v`
* `logs/synthesis/*.log`

---

#### 3️⃣ Floorplan

```tcl
% run_floorplan
```

Outputs:

* `results/floorplan/picorv32a.floorplan.def`
* Floorplan reports & logs

---

#### 4️⃣ Placement

```tcl
% run_placement
```

Outputs:

* `results/placement/picorv32a.placement.def`
* Timing reports & logs

If placement density issues appear (e.g. GPL-0302), you can tune in the same session:

```tcl
set ::env(FP_CORE_UTIL) 40
set ::env(PL_TARGET_DENSITY) 0.52
run_placement
```

---

#### 5️⃣ CTS (Clock Tree Synthesis)

```tcl
% run_cts
```

Outputs:

* `results/cts/picorv32a.cts.def`
* CTS-specific timing reports

---

#### 6️⃣ Routing

```tcl
% run_routing
```

This does:

* Global routing
* Detailed routing
* Fill insertion
* Post-route STA
* Antenna repair iterations

Outputs:

* `results/routing/picorv32a.route.def`
* Post-route timing, wirelength reports

---

#### 7️⃣ Signoff – LVS

```tcl
% run_lvs
```

Outputs:

* `logs/signoff/*lvs*.log`
* Netlists for comparison

---

#### 8️⃣ Signoff – DRC (Magic)

```tcl
% run_magic_drc
```

Outputs:

* `logs/signoff/30-drc.log`
* DRC result files under `results/signoff/`

---

#### 9️⃣ Optional – Antenna & IR Drop

```tcl
% run_antenna_check
% run_irdrop
```

> IR drop may warn if `VSRC_LOC_FILES` isn’t set; that’s expected in basic student flows.

---

#### 🔟 Final GDS & Views

Usually generated automatically after routing + signoff:

Final GDS:

```text
designs/picorv32a/runs/picor_int/results/final/gds/picorv32a.gds
```

---

### 5.3. Open Final GDS in KLayout (Interactive Run)

From Ubuntu shell (outside Docker):

```bash
cd ~/Silicon_Craft_PD_Workspace/OpenLane

klayout designs/picorv32a/runs/picor_int/results/final/gds/picorv32a.gds &
```

---
