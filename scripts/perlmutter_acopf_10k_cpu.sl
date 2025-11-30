#!/bin/bash
#SBATCH -C cpu
#SBATCH -A amsc004
#SBATCH -q regular
#SBATCH -t 00:30:00
#SBATCH -N 128
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=64
#SBATCH --job-name=acopf_10k_cpu
#SBATCH --output=logs/acopf_10k_cpu_%j.out
#SBATCH --error=logs/acopf_10k_cpu_%j.err

set -euo pipefail
module load julia

# Move to repo root (assumes script lives in scripts/)
cd $SLURM_SUBMIT_DIR
mkdir -p logs

# Resolve instance list from env or Artifacts.toml
if [ -z "${INSTANCES:-}" ]; then
  INSTANCES=$(julia --project -e 'using Pkg.Artifacts; base = joinpath(artifact"PGLib_opf", "pglib-opf-23.07"); names = replace.(filter(endswith(".m"), readdir(base)), ".m" => ""); print(join(names, ","))')
fi

SCENARIOS_PER_INSTANCE=${SCENARIOS_PER_INSTANCE:-10000}
CHUNK_SIZE=${CHUNK_SIZE:-500}
NPROCS=${NPROCS:-64}
SOLVER=${SOLVER:-madnlp}
OUTPUT_ROOT=${OUTPUT_ROOT:-${SCRATCH:-/tmp}/exagrid/pglib_opf/10K}
RESUME=${RESUME:-true}
FORCE=${FORCE:-false}

SRUN_NTASKS=${SLURM_NTASKS:-1}

srun --ntasks=${SRUN_NTASKS} \
     --ntasks-per-node=1 \
     --cpus-per-task=${NPROCS} \
  julia --project acopf_gen_slurm_chunks.jl \
    --instances=${INSTANCES} \
    --n_scenarios=${SCENARIOS_PER_INSTANCE} \
    --chunk_size=${CHUNK_SIZE} \
    --nprocs=${NPROCS} \
    --output_dir=${OUTPUT_ROOT} \
    --solver=${SOLVER} \
    --resume=${RESUME} \
    --force=${FORCE}

# Edit SBATCH account/qos/time/nodes and set array (example for 4 instances):
# sbatch scripts/perlmutter_acopf_10k_cpu.sl
# Run for a specific set of instances (override INSTANCES):
# INSTANCES="case89pegase,case162_ieee_dtc" sbatch scripts/perlmutter_acopf_200_cpu.sl
