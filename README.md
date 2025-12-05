# **A. VISUAL WORKFLOW DIAGRAM (ASCII BLOCK DIAGRAM)**

```
 ┌────────────────────────────────────────────────────┐
 │            Silicic Tool Chain Setup                │
 └────────────────────────────────────────────────────┘
                 │
                 ▼
        ┌───────────────────┐
        │ 1. System Check   │
        │  • OS detection   │
        │  • Dependencies   │
        └───────────────────┘
                 │
                 ▼
        ┌────────────────────────┐
        │ 2. Existing Tools Check│
        │  • Magic, Ngspice      │
        │  • OpenLane/OpenROAD   │
        │  • Docker (Option A)   │
        └────────────────────────┘
                 │
                 ▼
        ┌────────────────────────┐
        │ 3. Install Missing     │
        │    Tools (Selective)   │
        └────────────────────────┘
                 │
                 ▼
        ┌────────────────────────┐
        │ 4. Validate Tools      │
        │  • version check       │
        │  • sample run          │
        └────────────────────────┘
                 │
                 ▼
        ┌────────────────────────┐
        │ 5. OpenLane Docker     │
        │    Installation        │
        └────────────────────────┘
                 │
                 ▼
        ┌────────────────────────┐
        │ 6. Run Inverter Test   │
        │  • synthesis           │
        │  • floorplan           │
        │  • place & route       │
        │  • GDS export          │
        └────────────────────────┘
                 │
                 ▼
    ┌────────────────────────────────────┐
    │  Silicic Tool Chain Ready to Use   │
    └────────────────────────────────────┘
```

---

# **B. STEP-BY-STEP TERMINAL EXPERIENCE PREVIEW**

```
$ git clone https://github.com/SK-1702/silicic_tool_chain
$ cd silicic_tool_chain

$ sudo bash silicic_tool_chain_setup.sh

──────────────────────────────────────────────
    Silicic Tool Chain – Open-Source VLSI
    Automated RTL-to-GDSII Setup (Docker)
──────────────────────────────────────────────

[INFO] Detecting Operating System...
[OK] Ubuntu 22.04 detected

[INFO] Checking Docker installation...
[OK] Docker already installed
[INFO] Docker version: 26.1.3

[INFO] Pulling OpenLane Docker image...
[OK] openlane:latest pulled successfully

[INFO] Running sanity inverter test...
--------------------------------------------
[OpenLane] Running synthesis...
[SUCCESS] synthesis completed

[OpenLane] Running floorplan...
[OpenLane] Running placement...
[OpenLane] Running routing...
[OpenLane] GDS generated at:
    ./openlane_work/inverter/runs/latest/results/final/inverter.gds

──────────────────────────────────────────────
    SETUP COMPLETED SUCCESSFULLY!
──────────────────────────────────────────────
```

---

# **C. README LANDING PAGE PREVIEW**

## 🚀 Silicic Tool Chain (Open-Source RTL-to-GDSII Automation)

The **Silicic Tool Chain** is a **complete automated VLSI physical design setup**, designed for students, researchers, and companies transitioning into open-source ASIC design.

### **✨ Features**

* One-click installer (`silicic_tool_chain_setup.sh`)
* Auto OS detection (Ubuntu, macOS, WSL)
* Selective installation (skips existing tools)
* End-to-end OpenLane Docker environment
* Automatic inverter RTL-to-GDS validation test
* Idempotent (can be rerun safely)
* Creates structured tool directories

---

## 📦 Tools Supported Automatically

| Category   | Tools                       |
| ---------- | --------------------------- |
| PD Tools   | OpenLane (Docker), OpenROAD |
| Simulation | Ngspice, Verilator          |
| Layout     | Magic, KLayout              |
| Signoff    | Netgen                      |
| Others     | Yosys, Python env           |

---

## 🛠️ Installation

```
git clone https://github.com/SK-1702/silicic_tool_chain
cd silicic_tool_chain
sudo bash silicic_tool_chain_setup.sh
```

---

## ✔ What Happens During Installation?

* Checks for Docker → installs if needed
* Pulls official OpenLane image
* Creates folder structure
* Runs full inverter RTL-to-GDS test
* Prints results & GDS path

---

## 🎯 After Installation

Open a Docker OpenLane shell:

```
./run_openlane.sh
```

Run RTL-to-GDS manually:

```
flow.tcl -design inverter
```

---

# **D. END-TO-END ARCHITECTURE DIAGRAM**

```
┌─────────────────────────────────────────────────────────────┐
│                   SILICIC VLSI TOOL CHAIN                   │
└─────────────────────────────────────────────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │  Docker Layer        │
        │  • OpenLane          │
        │  • OpenROAD          │
        │  • Yosys / ABC       │
        │  • Magic / KLayout   │
        └──────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │   PDK Layer          │
        │   • Sky130A          │
        │   • Open_PDks        │
        └──────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │  Design Layer        │
        │  • inverter          │
        │  • picorv32a         │
        │  • any custom RTL    │
        └──────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │   Flow Stages        │
        │   • Synthesis        │
        │   • Floorplan        │
        │   • Placement        │
        │   • CTS              │
        │   • Routing          │
        │   • Signoff (LVS)    │
        │   • GDS Export       │
        └──────────────────────┘
```

---
