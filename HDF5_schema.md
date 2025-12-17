# HDF5 Schema for OPF Scenarios

## Overview

This document describes the HDF5 file format for storing Optimal Power Flow (OPF) scenarios with grid topology, perturbed loads, and optimization solutions.

## File Structure

### Single Scenario File
```
scenario_XXXXXX.h5
├── grid/                    (Group: Input network data)
├── solution/                (Group: Optimization results)
└── metadata/                (Group: Scenario metadata)
```

### Chunk File (Multiple Scenarios)
```
chunk_XXXX.h5
├── scenario_000001/
│   ├── grid/
│   ├── solution/
│   └── metadata/
├── scenario_000002/
│   ├── grid/
│   ├── solution/
│   └── metadata/
...
└── scenario_00YYYY/
    ├── grid/
    ├── solution/
    └── metadata/
```

---

## Detailed Schema

### 1. GRID GROUP
Input data representing the power network before optimization.

#### 1.1 `grid/nodes/` - Network Components

##### `grid/nodes/bus` (Dataset: Float32, shape=[n_bus, 5])
Bus/node features representing electrical buses in the network.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `vmin` | Float32 | Minimum voltage magnitude | per unit (p.u.) |
| 1 | `vmax` | Float32 | Maximum voltage magnitude | per unit (p.u.) |
| 2 | `zone` | Float32 | Zone identifier | - |
| 3 | `area` | Float32 | Area identifier | - |
| 4 | `bus_type` | Float32 | Bus type (1=PQ, 2=PV, 3=Ref) | - |

**Note:** `zone`, `area`, and `bus_type` are stored as Float32 for array homogeneity but represent integer categories.

##### `grid/nodes/generator` (Dataset: Float32, shape=[n_gen, 10])
Generator features and constraints.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `pmax` | Float32 | Maximum active power output | MW |
| 1 | `pmin` | Float32 | Minimum active power output | MW |
| 2 | `qmax` | Float32 | Maximum reactive power output | MVAr |
| 3 | `qmin` | Float32 | Minimum reactive power output | MVAr |
| 4 | `cost_c2` | Float32 | Quadratic cost coefficient (c2·pg²) | $/MW²/h |
| 5 | `cost_c1` | Float32 | Linear cost coefficient (c1·pg) | $/MW/h |
| 6 | `cost_c0` | Float32 | Constant cost coefficient | $/h |
| 7 | `vg` | Float32 | Voltage setpoint (for PV buses) | per unit |
| 8 | `mbase` | Float32 | Machine base power | MVA |
| 9 | `gen_status` | Float32 | Generator status (1=on, 0=off) | - |

**Cost Function:** `Cost = cost_c2 × pg² + cost_c1 × pg + cost_c0`

##### `grid/nodes/load` (Dataset: Float32, shape=[n_load, 2])
Load features (demand) - **perturbed values** for each scenario.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `pd` | Float32 | Active power demand | MW |
| 1 | `qd` | Float32 | Reactive power demand | MVAr |

**Note:** These are the perturbed load values specific to this scenario.

##### `grid/nodes/shunt` (Dataset: Float32, shape=[n_shunt, 2])
Shunt element features (optional, may be empty).

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `gs` | Float32 | Shunt conductance | per unit |
| 1 | `bs` | Float32 | Shunt susceptance | per unit |

#### 1.2 `grid/context/` - System-Level Parameters

##### `grid/context/baseMVA` (Dataset: Float32, shape=[1, 1, 1])
System base power for per-unit conversion.

**Value:** Typically 100.0 MVA

#### 1.3 `grid/edges/` - Network Connections

##### `grid/edges/ac_line/` - AC Transmission Lines

###### `senders` (Dataset: Int32, shape=[n_ac_line])
From-bus indices (0-indexed).

###### `receivers` (Dataset: Int32, shape=[n_ac_line])
To-bus indices (0-indexed).

###### `features` (Dataset: Float32, shape=[n_ac_line, 9])
AC line parameters.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `angmin` | Float32 | Minimum voltage angle difference | radians |
| 1 | `angmax` | Float32 | Maximum voltage angle difference | radians |
| 2 | `br_r` | Float32 | Series resistance | per unit |
| 3 | `br_x` | Float32 | Series reactance | per unit |
| 4 | `b_fr` | Float32 | Half of br_b | per unit |
| 5 | `b_to` | Float32 | Half of br_b | per unit |
| 6 | `rate_a` | Float32 | Long-term thermal rating | MVA |
| 7 | `rate_b` | Float32 | Short-term thermal rating | MVA |
| 8 | `rate_c` | Float32 | Emergency thermal rating | MVA |
| 9 | `br_status` | Float32 | Branch status (1=in-service, 0=out) | - |

##### `grid/edges/transformer/` - Transformers

###### `senders` (Dataset: Int32, shape=[n_transformer])
From-bus indices (0-indexed).

###### `receivers` (Dataset: Int32, shape=[n_transformer])
To-bus indices (0-indexed).

###### `features` (Dataset: Float32, shape=[n_transformer, 11])
Transformer parameters.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `angmin` | Float32 | Minimum voltage angle difference | radians |
| 1 | `angmax` | Float32 | Maximum voltage angle difference | radians |
| 2 | `br_r` | Float32 | Series resistance | per unit |
| 3 | `br_x` | Float32 | Series reactance | per unit |
| 4 | `b_fr` | Float32 | Half of br_b | per unit |
| 5 | `b_to` | Float32 | Half of br_b | per unit |
| 6 | `rate_a` | Float32 | Long-term thermal rating | MVA |
| 7 | `rate_b` | Float32 | Short-term thermal rating | MVA |
| 8 | `rate_c` | Float32 | Emergency thermal rating | MVA |
| 9 | `br_status` | Float32 | Branch status | - |
| 10 | `tap` | Float32 | Transformer tap ratio | per unit |
| 11 | `shift` | Float32 | Phase shift angle | radians |

##### `grid/edges/generator_link/` - Generator-to-Bus Connections

###### `senders` (Dataset: Int32, shape=[n_gen])
Generator indices (0-indexed).

###### `receivers` (Dataset: Int32, shape=[n_gen])
Connected bus indices (0-indexed).

**Interpretation:** `senders[i]` is connected to `receivers[i]`

##### `grid/edges/load_link/` - Load-to-Bus Connections

###### `senders` (Dataset: Int32, shape=[n_load])
Load indices (0-indexed).

###### `receivers` (Dataset: Int32, shape=[n_load])
Connected bus indices (0-indexed).

##### `grid/edges/shunt_link/` - Shunt-to-Bus Connections (Optional)

###### `senders` (Dataset: Int32, shape=[n_shunt])
Shunt indices (0-indexed).

###### `receivers` (Dataset: Int32, shape=[n_shunt])
Connected bus indices (0-indexed).

---

### 2. SOLUTION GROUP
Optimization results from solving the OPF problem.

#### 2.1 `solution/nodes/` - Nodal Solutions

##### `solution/nodes/bus` (Dataset: Float32, shape=[n_bus, 2])
Solved bus voltage values.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `va` | Float32 | Voltage angle | radians |
| 1 | `vm` | Float32 | Voltage magnitude | per unit |

##### `solution/nodes/generator` (Dataset: Float32, shape=[n_gen, 2])
Solved generator dispatch values.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `pg` | Float32 | Active power generation | MW |
| 1 | `qg` | Float32 | Reactive power generation | MVAr |

#### 2.2 `solution/edges/` - Branch Flow Solutions

**Note:** Sender/receiver arrays are NOT stored here (redundant with `grid/edges/`). Use topology from grid section.

##### `solution/edges/ac_line/features` (Dataset: Float32, shape=[n_ac_line, 4])
Power flows on AC lines.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `pf` | Float32 | Active power flow (from → to) | MW |
| 1 | `qf` | Float32 | Reactive power flow (from → to) | MVAr |
| 2 | `pt` | Float32 | Active power flow (to → from) | MW |
| 3 | `qt` | Float32 | Reactive power flow (to → from) | MVAr |

##### `solution/edges/transformer/features` (Dataset: Float32, shape=[n_transformer, 4])
Power flows on transformers.

| Index | Feature | Type | Description | Units |
|-------|---------|------|-------------|-------|
| 0 | `pf` | Float32 | Active power flow (from → to) | MW |
| 1 | `qf` | Float32 | Reactive power flow (from → to) | MVAr |
| 2 | `pt` | Float32 | Active power flow (to → from) | MW |
| 3 | `qt` | Float32 | Reactive power flow (to → from) | MVAr |

---

### 3. METADATA GROUP (Attributes)
Scalar values stored as HDF5 attributes.

#### `metadata/` Attributes

| Attribute | Type | Description | Units |
|-----------|------|-------------|-------|
| `scenario_id` | Int32 | Unique scenario identifier | - |
| `objective` | Float32 | Optimal objective function value | $ (or $/h) |
| `solve_time` | Float32 | Solver wall-clock time | seconds |
| `status` | String | Solver termination status | - |
| `total_power_slack` | Float32 | Sum of all power balance slack variables |
| `total_line_slack` | Float32 | Sum of all line limit slack variables |


- Optional components (shunt, shunt_link) may not exist in the HDF5 file if the network has no such elements
