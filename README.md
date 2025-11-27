# ExaGrid-DataGen

ExaGrid-DataGen is a Julia toolkit designed to generate large-scale AC Optimal Power Flow (ACOPF) datasets by solving perturbed MATPOWER-format power system test cases. These datasets support machine learning research, optimization benchmarking, and power systems studies. Outputs are efficiently stored in compressed HDF5 format.

## Getting Started

### Clone the repository

```sh
git clone https://github.com/exanauts/ExaGrid-DataGen.git
cd ExaGrid-DataGen
```

### Install Julia and dependencies

Ensure Julia 1.6 or newer is installed, then from the repository root:

```sh
julia --project -e 'using Pkg; Pkg.instantiate()'
```

### Problem instances

MATPOWER case files are automatically managed by Julia’s artifact system via `Artifacts.toml`. The relevant PGLib OPF instances are downloaded on-demand, so no manual data fetching is required.

## Usage

### Generate OPF datasets with parallel scenario solving

Run the main generator script with desired options:

```sh
julia acopf_gen_parallel.jl [OPTIONS]
```

### Command-Line Arguments

| Argument       | Default Value                  | Description                                                   |
|----------------|-------------------------------|---------------------------------------------------------------|
| `--solver`     | `madnlp`                      | Solver to use: either `madnlp` (default) or `ipopt`.          |
| `--instance`   | `pglib_opf_case24_ieee_rts`   | PGLib/MATPOWER case name (without `.m`) to solve.             |
| `--nprocs`     | `5`                           | Number of parallel Julia workers to add.                       |
| `--n_scenarios`| `10`                          | Total number of perturbed scenarios to solve.                 |
| `--chunk_size` | `2`                           | Number of scenarios per output chunk (saved to separate files).|
| `--output_dir` | *auto*: `results/<instance>`  | Directory to store output HDF5 files.                          |
| `--p_range`    | `"0.9,1.1"`                   | Range of active power (P) perturbation, format: `min,max`.    |
| `--q_range`    | `"0.9,1.1"`                   | Range of reactive power (Q) perturbation, format: `min,max`.  |

### Example

```sh
julia acopf_gen_parallel.jl --solver=ipopt --instance=pglib_opf_case118_ieee --nprocs=8 --n_scenarios=50 --chunk_size=5 --output_dir=outputs/case118 --p_range=0.9,1.1 --q_range=0.95,1.05
```

## Technical Details

- The script perturbs the base network loads within the specified power ranges to generate scenarios.
- It solves each scenario using either **MadNLP.jl** or **Ipopt.jl** solvers.
- For stability and efficiency, strong recommendation is given to use the **HSL MA27** linear solver. Both solvers support it:
  - See [MadNLP.jl's installation instructions](https://github.com/MadNLP/MadNLP.jl#installation)
  - See [Ipopt.jl's HSL integration guide](https://jump.dev/Ipopt.jl/stable/installation/#hsl)
- The output per chunk is saved as an HDF5 file containing network data, solver results, objectives, and slack variables information.

## Output Data Structure

Each chunk HDF5 file contains one group per scenario (`scenario_000001`, etc.) plus top-level attributes `n_scenarios` and `chunk_file`. For each scenario:
- `metadata` attrs: `objective`, `solve_time` (seconds), `status` (MOI status string), `total_power_slack`, `total_line_slack`, `scenario_id`.
- `grid/context`: dataset `baseMVA` (1x1x1 Float32).
- `grid/nodes` (Float32 matrices, rows = entities): `bus` `[vmin, vmax, zone, area, bus_type]`; `generator` `[pmax, pmin, qmax, qmin, cost_c2, cost_c1, cost_c0, vg, mbase, status]`; `load` `[pd, qd]`; optional `shunt` `[gs, bs]`.
- `grid/edges`: `ac_line` senders/receivers (Int32, 0-based bus indices) with features `[angmin, angmax, br_r, br_x, b_fr, b_to, rate_a, rate_b, rate_c, br_status]`; `transformer` senders/receivers with features above plus `[tap, shift]`; `generator_link` (gen id−1 -> gen bus−1); `load_link` (load id−1 -> load bus−1); optional `shunt_link`.
- `solution/nodes`: `bus` `[va, vm]`; `generator` `[pg, qg]`.
- `solution/edges`: `ac_line/features` and `transformer/features` `[pf, qf, pt, qt]` ordered consistently with `grid/edges`.

## Troubleshooting and Notes

- If you face issues with artifacts or case files, verify Julia’s artifact system and network settings.
- Ensure that the solvers are compiled with HSL support when solving large or difficult cases to prevent solver failures.

## Contribution & Support

Contributions and bug reports are welcome via GitHub issues and pull requests. Please cite this repository if used in research.
