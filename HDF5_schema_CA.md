# HDF5 Schema - Contingency Analysis (CA)

## Overview

This document extends the HDF5 schema to support contingency analysis data storage. Each file contains one scenario with multiple post-contingency OPF solutions.

## File Structure

```
scenario_XXXXXX.h5
├── grid/                    (Group: Input network with perturbed loads)
├── base_solution/           (Group: Pre-contingency OPF solution)
├── contingencies/           (Group: Contingency definitions)
├── post_contingency/        (Group: Post-contingency OPF solutions)
└── metadata/                (Group: Scenario metadata)
```

---

## Detailed Schema

### 1. GRID GROUP
Input network data with perturbed loads.

#### 1.1 `grid/nodes/load` (Dataset: Float32, shape=[n_load, 4])
| Index | Feature | Description | Units |
|-------|---------|-------------|-------|
| 0 | `pd` | Active power demand | MW |
| 1 | `qd` | Reactive power demand | MVAr |
| 2 | `weight_p` | Load shedding priority weight (P) | - |
| 3 | `weight_q` | Load shedding priority weight (Q) | - |

**Note:** Weights default to 1.0 if not in network data. See `HDF5_schema.md` for complete grid specification.

---

### 2. BASE_SOLUTION GROUP
PF and OPF solutions for the base case (no contingency applied).

#### 2.1 Structure
```
base_solution/
├── pf/nodes/          (Power Flow solution)
│   ├── bus            [n_bus, 2]
│   ├── generator      [n_gen, 2]
│   └── load           [n_load, 2]
└── opf/nodes/         (Optimal Power Flow solution)
    ├── bus            [n_bus, 2]
    ├── generator      [n_gen, 2]
    └── load           [n_load, 2]
```

#### 2.2 Node Datasets (same for pf/ and opf/)

##### `bus` (Dataset: Float32, shape=[n_bus, 2])
| Index | Feature | Description | Units |
|-------|---------|-------------|-------|
| 0 | `va` | Voltage angle | radians |
| 1 | `vm` | Voltage magnitude | per unit |

##### `generator` (Dataset: Float32, shape=[n_gen, 2])
| Index | Feature | Description | Units |
|-------|---------|-------------|-------|
| 0 | `pg` | Active power generation | MW |
| 1 | `qg` | Reactive power generation | MVAr |

##### `load` (Dataset: Float32, shape=[n_load, 2])
| Index | Feature | Description | Units |
|-------|---------|-------------|-------|
| 0 | `pd_served` | Active power actually served | MW |
| 1 | `qd_served` | Reactive power actually served | MVAr |

#### 2.3 Attributes (`base_solution/opf/`)
| Attribute | Type | Description |
|-----------|------|-------------|
| `objective` | Float32 | Optimal cost |
| `solve_time` | Float32 | Solver time (seconds) |
| `status` | String | Solver termination status (e.g., LOCALLY_SOLVED) |

---

### 3. CONTINGENCIES GROUP
Definitions of all contingencies analyzed.

#### 3.1 Attributes
| Attribute | Type | Description |
|-----------|------|-------------|
| `count` | Int32 | Number of contingencies |

#### 3.2 Datasets

##### `contingencies/types` (Dataset: Int8, shape=[n_cont])
Contingency type for each contingency.

| Value | Type | Description |
|-------|------|-------------|
| 0 | LINE | Line/branch outage |
| 1 | GEN | Generator outage |

##### `contingencies/ids` (Dataset: String, shape=[n_cont])
Element ID (branch or generator) that is taken out of service.

##### `contingencies/names` (Dataset: String, shape=[n_cont])
Human-readable contingency names (e.g., `LINE_1_2_5`, `GEN_3_7`).

---

### 4. POST_CONTINGENCY GROUP
PF and OPF solutions after each contingency is applied.

#### 4.1 Structure
```
post_contingency/
├── contingency_000001/
│   ├── @pf_converged      Int8 (1=yes, 0=no)
│   ├── @opf_converged     Int8 (1=yes, 0=no)
│   ├── pf/nodes/
│   │   ├── bus            [n_bus, 2]
│   │   ├── generator      [n_gen, 2]
│   │   └── load           [n_load, 2]
│   └── opf/
│       ├── @objective     Float32
│       ├── @solve_time    Float32
│       ├── @status        String
│       └── nodes/
│           ├── bus        [n_bus, 2]
│           ├── generator  [n_gen, 2]
│           └── load       [n_load, 2]
├── contingency_000002/
│   └── ...
└── contingency_NNNNNN/
```

#### 4.2 Contingency Attributes (`post_contingency/contingency_XXXXXX/`)
| Attribute | Type | Description |
|-----------|------|-------------|
| `pf_converged` | Int8 | 1 if PF converged, 0 otherwise |
| `opf_converged` | Int8 | 1 if OPF converged, 0 otherwise |

#### 4.3 OPF Attributes (`post_contingency/contingency_XXXXXX/opf/`)
| Attribute | Type | Description |
|-----------|------|-------------|
| `objective` | Float32 | Optimal cost |
| `solve_time` | Float32 | Solver time (seconds) |
| `status` | String | Solver termination status (e.g., LOCALLY_SOLVED) |

#### 4.4 Node Datasets (same structure as base_solution)
- `bus` [n_bus, 2]: va, vm
- `generator` [n_gen, 2]: pg, qg
- `load` [n_load, 2]: pd_served, qd_served

---

### 5. METADATA GROUP (Attributes)

| Attribute | Type | Description |
|-----------|------|-------------|
| `scenario_id` | Int32 | Unique scenario identifier |
| `n_contingencies` | Int32 | Total contingencies analyzed |
| `n_pf_converged` | Int32 | Number of PF that converged |
| `n_opf_converged` | Int32 | Number of OPF that converged |
| `total_solve_time` | Float32 | Sum of all solve times (seconds) |

---

## Notes

- Grid topology is stored once per scenario (with perturbed loads)
- Base solution = OPF with no contingency (all elements in service)
- Post-contingency solutions share the same grid topology but with one element removed
- Failed contingencies (non-convergent) are not written to HDF5
- All indices are 0-based for consistency with Python/C++

---

*Last Updated: 2025-01-18*
