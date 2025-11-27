# Repository Guidelines

## Project Structure & Module Organization
- Root contains Julia scripts for ACOPF dataset generation: `acopf_gen_parallel.jl` (parallel scenario batches), `acopf_gen.jl` (single-run/debug), `acopf_model.jl` (JuMP/PowerModels model builder with slack logic), `perturbations.jl` (load perturbations), and `hdf5_writer.jl` (chunked output + verification helpers).
- Dependencies are declared in `Project.toml`; artifacts such as PGLib OPF cases are managed via `Artifacts.toml` and downloaded on demand.
- Outputs are written under `results/<instance>` by default; generated HDF5 chunks follow `chunk_####.h5` naming.

## Build, Test, and Development Commands
- Install deps: `julia --project -e 'using Pkg; Pkg.instantiate()'`.
- Parallel dataset generation (typical workflow): `julia --project acopf_gen_parallel.jl --instance=pglib_opf_case118_ieee --nprocs=8 --n_scenarios=50 --chunk_size=5 --output_dir=results/case118`.
- Single run for debugging: `julia --project acopf_gen.jl --solver=madnlp --instance=pglib_opf_case24_ieee_rts --write_output=true` (writes `test_scenario_001.h5`).
- Inspect an HDF5 chunk: `julia --project -e 'using HDF5; h5open("results/case118/chunk_0001.h5") do f; println(keys(f)); end'`.

## Coding Style & Naming Conventions
- Julia style: 4-space indentation, snake_case for variables/functions, CONSTANT_CASE for constants.
- Prefer type-stable functions; avoid global mutation except for configuration constants.
- Keep CLI flags lowercase with hyphens; mirror existing ArgParse naming.
- Log messages should stay concise and progress-oriented (see `ProgressMeter` usage in `acopf_gen_parallel.jl`).

## Testing Guidelines
- No formal test suite yet; validate changes by running a small scenario set (e.g., `--n_scenarios=2 --chunk_size=1`) and confirming HDF5 outputs are created.
- When modifying model or perturbation logic, compare solver status/objective before and after changes on a fixed instance to catch regressions.
- Record solver options used (Ipopt vs MadNLP, HSL/MA27 availability) because numerical differences matter.

## Commit & Pull Request Guidelines
- Follow the existing short, imperative commit style (`refactored to make it callable with args`, `added ArgParse`). Keep subjects under ~60 chars.
- PRs should include: a short summary of the change, sample commands used for verification, any new flags or defaults, and notes on output directories/files touched.
- Add logs or screenshots only when they clarify solver behavior or performance impacts; otherwise keep PRs text-focused.

## Security & Configuration Notes
- PGLib artifacts download automatically; avoid committing downloaded data or generated HDF5 outputs.
- HSL/MA27 has licensing constraints—ensure you are authorized to use the binaries you point to; do not commit private license files.
- For GPU paths (`MadNLPGPU`), clearly document CUDA version and driver assumptions in your PR description.
