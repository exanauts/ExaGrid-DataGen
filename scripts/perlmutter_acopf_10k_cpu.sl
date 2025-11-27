#!/bin/bash
#SBATCH -C cpu
#SBATCH -A <account>
#SBATCH -q <qos>
#SBATCH -t 04:00:00
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=128
#SBATCH --job-name=acopf_10k_cpu
#SBATCH --output=logs/acopf_10k_cpu_%A_%a.out
#SBATCH --error=logs/acopf_10k_cpu_%A_%a.err
#SBATCH --array=0-0

# Perlmutter CPU job to generate ACOPF data with acopf_gen_parallel.jl.
# Edit SBATCH lines (account/qos/time/nodes/array) before submitting.
# If INSTANCES is unset, this script will derive all PGLib instances from Artifacts.toml.

set -euo pipefail

# Move to repo root (assumes script lives in scripts/)
cd "$(dirname "$0")/.."

# Resolve instance list from env or Artifacts.toml
if [ -z "${INSTANCES:-}" ]; then
  INSTANCES=$(julia --project -e 'using Pkg.Artifacts; base = joinpath(artifact"PGLib_opf", "pglib-opf-23.07"); names = replace.(filter(endswith(".m"), readdir(base)), ".m" => ""); print(join(names, ","))')
fi

SCENARIOS_PER_INSTANCE=${SCENARIOS_PER_INSTANCE:-10000}
CHUNK_SIZE=${CHUNK_SIZE:-200}
NPROCS=${NPROCS:-32}
SOLVER=${SOLVER:-madnlp}
OUTPUT_ROOT=${OUTPUT_ROOT:-${SCRATCH:-/tmp}/exagrid}

IFS=',' read -r -a INST_ARRAY <<< "$INSTANCES"
if [ ${#INST_ARRAY[@]} -eq 0 ]; then
  echo "No instances provided via INSTANCES or Artifacts.toml." >&2
  exit 1
fi

if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
  echo "SLURM_ARRAY_TASK_ID is not set; submit with --array=0-$(( ${#INST_ARRAY[@]} - 1 ))." >&2
  exit 1
fi

if [ "$SLURM_ARRAY_TASK_ID" -ge "${#INST_ARRAY[@]}" ]; then
  echo "Array index $SLURM_ARRAY_TASK_ID exceeds instance list (${#INST_ARRAY[@]})." >&2
  exit 1
fi

INSTANCE=${INST_ARRAY[$SLURM_ARRAY_TASK_ID]}
OUTPUT_DIR=${OUTPUT_ROOT}/${INSTANCE}/10k
mkdir -p "$OUTPUT_DIR" logs

export JULIA_NUM_THREADS=${NPROCS}

srun --nodes=${SLURM_NNODES:-1} \
     --ntasks=1 \
     --ntasks-per-node=1 \
     --cpus-per-task=${NPROCS} \
  julia --project acopf_gen_parallel.jl \
    --instance=${INSTANCE} \
    --n_scenarios=${SCENARIOS_PER_INSTANCE} \
    --chunk_size=${CHUNK_SIZE} \
    --nprocs=${NPROCS} \
    --output_dir=${OUTPUT_DIR} \
    --solver=${SOLVER}

# Edit SBATCH account/qos/time/nodes and set array (example for 4 instances):
# sbatch --array=0-3 scripts/perlmutter_acopf_10k_cpu.sl
# Run for a specific set of instances (override INSTANCES):
# INSTANCES="case89pegase,case162_ieee_dtc" sbatch --array=0-1 scripts/perlmutter_acopf_10k_cpu.sl