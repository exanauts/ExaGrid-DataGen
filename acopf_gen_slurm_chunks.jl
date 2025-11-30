#!/usr/bin/env julia
# Slurm-friendly ACOPF generator: dynamically assigns instances + chunks to tasks.
# Launch with multiple tasks (e.g., srun -N <nodes> --ntasks=<tasks> --cpus-per-task=64),
# without Slurm arrays. Work is round-robin partitioned across tasks so any number of
# nodes can cover an arbitrary number of instances/chunks.

using Pkg.Artifacts
using Distributed
using ProgressMeter
using HDF5
using ArgParse
using JSON
using Dates

function parse_cli()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--solver"
            help = "Solver to use: ipopt, madnlp"
            arg_type = String
            default = "madnlp"
        "--instances"
            help = "Comma-separated PGLib instances (without .m); defaults to all from artifact"
            arg_type = String
            default = ""
        "--nprocs"
            help = "Number of worker processes to add on each node"
            arg_type = Int
            default = Sys.CPU_THREADS
        "--n_scenarios"
            help = "Scenarios per instance"
            arg_type = Int
            default = 10000
        "--chunk_size"
            help = "Scenarios per chunk"
            arg_type = Int
            default = 200
        "--output_dir"
            help = "Root directory to write results into (per-instance subdirs are created)"
            arg_type = String
            default = ""
        "--p_range"
            help = "Active power perturbation range as a,b"
            arg_type = String
            default = "0.9,1.1"
        "--q_range"
            help = "Reactive power perturbation range as a,b"
            arg_type = String
            default = "0.9,1.1"
        "--resume"
            help = "Skip chunks already completed (checkpoint/existing files)"
            arg_type = Bool
            default = true
        "--force"
            help = "Ignore checkpoints and redo all chunks"
            arg_type = Bool
            default = false
    end

    parsed = parse_args(s)

    opts = Dict{Symbol,Any}()
    opts[:solver] = Symbol(lowercase(parsed["solver"]))
    opts[:instances] = parsed["instances"]
    opts[:nprocs] = parsed["nprocs"]
    opts[:n_scenarios] = parsed["n_scenarios"]
    opts[:chunk_size] = parsed["chunk_size"]
    opts[:output_dir] = parsed["output_dir"]
    pr = split(parsed["p_range"], ",")
    opts[:p_range] = (parse(Float64, pr[1]), parse(Float64, pr[2]))
    qr = split(parsed["q_range"], ",")
    opts[:q_range] = (parse(Float64, qr[1]), parse(Float64, qr[2]))
    opts[:resume] = parsed["resume"]
    opts[:force] = parsed["force"]

    if opts[:output_dir] == ""
        opts[:output_dir] = joinpath("results")
    end

    return opts
end

function resolve_instances(instances_arg::String)
    if instances_arg != ""
        return split(instances_arg, ",")
    end
    env_instances = get(ENV, "INSTANCES", "")
    if env_instances != ""
        return split(env_instances, ",")
    end
    return replace.(filter(endswith(".m"), readdir(joinpath(artifact"PGLib_opf", "pglib-opf-23.07"))), ".m" => "")
end

function build_work(instances::AbstractVector{<:AbstractString}, n_scenarios::Int, chunk_size::Int)
    work = Vector{Tuple{String,Int,Int,Int}}()
    for inst in instances
        n_chunks = ceil(Int, n_scenarios / chunk_size)
        for chunk_idx in 0:(n_chunks - 1)
            start_idx = chunk_idx * chunk_size + 1
            end_idx = min((chunk_idx + 1) * chunk_size, n_scenarios)
            push!(work, (inst, chunk_idx, start_idx, end_idx))
        end
    end
    return work
end

checkpoint_path(root::String, inst::String) = joinpath(root, inst, "checkpoint.json")

function load_completed(root::String, inst::String)
    done = Set{Int}()
    inst_dir = joinpath(root, inst)
    if isdir(inst_dir)
        for f in readdir(inst_dir; join=true)
            m = match(r"chunk_(\d{4})\.h5", basename(f))
            m === nothing && continue
            push!(done, parse(Int, m.captures[1]) - 1)
        end
    end
    ckpt_file = checkpoint_path(root, inst)
    if isfile(ckpt_file)
        try
            data = JSON.parsefile(ckpt_file)
            if haskey(data, "completed_chunks")
                for c in data["completed_chunks"]
                    push!(done, Int(c))
                end
            end
        catch e
            @warn "Failed to read checkpoint for $inst: $e"
        end
    end
    return done
end

function save_checkpoint(root::String, inst::String, completed::Set{Int}, total_chunks::Int)
    ckpt_file = checkpoint_path(root, inst)
    mkpath(dirname(ckpt_file))
    tmp = ckpt_file * ".tmp"
    open(tmp, "w") do io
        JSON.print(io, Dict(
            "completed_chunks" => collect(completed),
            "total_chunks" => total_chunks,
            "updated_at" => Dates.format(Dates.now(), Dates.ISODateTimeFormat)
        ))
    end
    mv(tmp, ckpt_file; force=true)
end

opts = parse_cli()
instances = resolve_instances(opts[:instances])
procid = parse(Int, get(ENV, "SLURM_PROCID", "0"))
ntasks = parse(Int, get(ENV, "SLURM_NTASKS", "1"))

all_work = build_work(instances, opts[:n_scenarios], opts[:chunk_size])
if isempty(all_work)
@info "No work to schedule."
return
end

my_work = [w for (i, w) in enumerate(all_work) if ((i - 1) % ntasks) == procid]
if isempty(my_work)
@info "Task $procid has no assigned work (ntasks=$ntasks)."
return
end

total_chunks = ceil(Int, opts[:n_scenarios] / opts[:chunk_size])
completed_map = Dict{String,Set{Int}}()

addprocs(opts[:nprocs])

pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")

@everywhere begin
using MadNLP
using MadNLPHSL
using PowerModels
using Ipopt
using JuMP
using Random
using HDF5
include("acopf_model.jl")
include("perturbations.jl")
include("hdf5_writer.jl")

function solve_scenario(base_network, scenario_id, p_range, q_range, SOLVER)
    power_balance_relaxation = false
    line_limit_relaxation = false

    network = deepcopy(base_network)
    perturb_loads_separate!(network, p_range, q_range, scenario_id)

    pm = instantiate_model(network, ACPPowerModel,
	pm -> build_opf_with_slacks(pm,
	    power_balance_relaxation=false,
	    line_limit_relaxation=false
	)
    )

    if SOLVER == :ipopt
	JuMP.set_optimizer(pm.model, Ipopt.Optimizer)
    elseif SOLVER == :madnlp
	JuMP.set_optimizer(pm.model, ()->MadNLP.Optimizer(linear_solver=Ma27Solver, print_level=MadNLP.WARN))
    else
	error("Unsupported solver on worker: $(SOLVER)")
    end

    result = optimize_model!(pm)

    if result["termination_status"] != MOI.LOCALLY_SOLVED
	pm = instantiate_model(network, ACPPowerModel,
	    pm -> build_opf_with_slacks(pm,
		power_balance_relaxation=true,
		line_limit_relaxation=true
	    )
	)
	power_balance_relaxation = true
	line_limit_relaxation = true

	if SOLVER == :ipopt
	    JuMP.set_optimizer(pm.model, Ipopt.Optimizer)
	elseif SOLVER == :madnlp
	    JuMP.set_optimizer(pm.model, ()->MadNLP.Optimizer(linear_solver=Ma27Solver, print_level=MadNLP.WARN))
	else
	    error("Unsupported solver on worker: $(SOLVER)")
	end
	result = optimize_model!(pm)
	if result["termination_status"] != MOI.LOCALLY_SOLVED
	    return nothing
	end
    end

    total_power_slack = 0.0
    if power_balance_relaxation && haskey(result, "solution")
	for (_, bus) in result["solution"]["bus"]
	    if haskey(bus, "p_slack_pos")
		total_power_slack += bus["p_slack_pos"] + bus["p_slack_neg"] + bus["q_slack_pos"] + bus["q_slack_neg"]
	    end
	end
    end

    total_line_slack = 0.0
    if line_limit_relaxation && haskey(result, "solution")
	for (_, branch) in result["solution"]["branch"]
	    if haskey(branch, "s_slack")
		total_line_slack += branch["s_slack"]
	    end
	end
    end

    return (
	id = scenario_id,
	network = network,
	result = result,
	obj = result["objective"],
	time = result["solve_time"],
	status = string(result["termination_status"]),
	power_slack = total_power_slack,
	line_slack = total_line_slack
    )
end
end

@everywhere p_rng = $(opts[:p_range])
@everywhere q_rng = $(opts[:q_range])

PowerModels.silence()

for (inst, chunk_idx, start_idx, end_idx) in my_work
case_file = joinpath(pglib_path, string(inst, ".m"))
instance_output_dir = joinpath(opts[:output_dir], inst)
mkpath(instance_output_dir)

completed = get!(completed_map, inst) do
    opts[:force] ? Set{Int}() : load_completed(opts[:output_dir], inst)
end

chunk_filename = joinpath(instance_output_dir, "chunk_$(lpad(chunk_idx + 1, 4, '0')).h5")
if opts[:resume] && !opts[:force] && (chunk_idx in completed || isfile(chunk_filename))
    println("[$inst] Chunk $(chunk_idx+1) already done, skipping.")
    push!(completed, chunk_idx)
    save_checkpoint(opts[:output_dir], inst, completed, total_chunks)
    continue
end

base_network = PowerModels.parse_file(case_file)
@everywhere shared_network = $base_network

println("Task $procid handling $inst chunk $(chunk_idx+1) scenarios $start_idx:$end_idx (ntasks=$ntasks)")

scenario_ids = start_idx:end_idx
chunk_results = pmap(i -> solve_scenario(shared_network, i, p_rng, q_rng, opts[:solver]), scenario_ids)
successful_results = filter(!isnothing, chunk_results)

if isempty(successful_results)
    @warn "[$inst] No successful solves for chunk $chunk_idx (scenarios $start_idx:$end_idx)"
    continue
end

write_chunk_to_hdf5(chunk_filename, successful_results)
println("[$inst] Chunk $(chunk_idx+1) complete: wrote $(length(successful_results)) / $(length(chunk_results)) scenarios")

push!(completed, chunk_idx)
save_checkpoint(opts[:output_dir], inst, completed, total_chunks)
end

