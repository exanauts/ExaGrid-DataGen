using Pkg.Artifacts
using Distributed
using ProgressMeter
using HDF5
using ArgParse

# Parse CLI options at top-level so we can call addprocs with the requested count
function parse_cli()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--solver"
            help = "Solver to use: ipopt, madnlp"
            arg_type = String
            default = "madnlp"
        "--instance"
            help = "PGLib instance name (without .m)"
            arg_type = String
            default = "pglib_opf_case24_ieee_rts"
        "--nprocs"
            help = "Number of worker processes to add"
            arg_type = Int
            default = 5
        "--n_scenarios"
            help = "Total number of scenarios to solve"
            arg_type = Int
            default = 10
        "--chunk_size"
            help = "Number of scenarios per chunk"
            arg_type = Int
            default = 2
        "--output_dir"
            help = "Directory to write results into"
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
    end

    parsed = parse_args(s)

    opts = Dict{Symbol,Any}()
    opts[:solver] = Symbol(lowercase(parsed["solver"]))
    opts[:instance] = parsed["instance"]
    opts[:nprocs] = parsed["nprocs"]
    opts[:n_scenarios] = parsed["n_scenarios"]
    opts[:chunk_size] = parsed["chunk_size"]
    opts[:output_dir] = parsed["output_dir"]
    pr = split(parsed["p_range"], ",")
    opts[:p_range] = (parse(Float64, pr[1]), parse(Float64, pr[2]))
    qr = split(parsed["q_range"], ",")
    opts[:q_range] = (parse(Float64, qr[1]), parse(Float64, qr[2]))

    if opts[:output_dir] == ""
        opts[:output_dir] = joinpath("results", opts[:instance])
    end

    return opts
end

opts = parse_cli()

addprocs(opts[:nprocs])

pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")

# Define worker-side functions and imports via @everywhere (top-level)
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

    # Constants SOLVER/INSTANCE will be set from the main process below
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
            println("adding slack variables and re-solving")
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
            for (i, bus) in result["solution"]["bus"]
                if haskey(bus, "p_slack_pos")
                    total_power_slack += bus["p_slack_pos"] + bus["p_slack_neg"] + bus["q_slack_pos"] + bus["q_slack_neg"]
                end
            end
        end
        
        total_line_slack = 0.0
        if line_limit_relaxation && haskey(result, "solution")
            for (i, branch) in result["solution"]["branch"]
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

# Configuration (use parsed options)
case_file = joinpath(pglib_path, string(opts[:instance], ".m"))
n_scenarios = opts[:n_scenarios]
chunk_size = opts[:chunk_size]
output_dir = opts[:output_dir]
p_range = opts[:p_range]
q_range = opts[:q_range]

mkpath(output_dir)

println("Loading network and distributing to workers...")
PowerModels.silence()
base_network = PowerModels.parse_file(case_file)
@everywhere shared_network = $base_network
@everywhere p_rng = $p_range
@everywhere q_rng = $q_range

println("\nSolving $n_scenarios scenarios with $(nworkers()) workers...")
all_successful_ids = Int[]

n_chunks = ceil(Int, n_scenarios / chunk_size)
@showprogress for chunk_idx in 1:n_chunks
    start_idx = (chunk_idx - 1) * chunk_size + 1
    end_idx = min(chunk_idx * chunk_size, n_scenarios)

    chunk_filename = joinpath(output_dir, "chunk_$(lpad(chunk_idx, 4, '0')).h5")

    if isfile(chunk_filename)
        println("Chunk $chunk_idx already exists, skipping...")
        continue
    end
    
    # pass SOLVER explicitly to avoid relying on worker-global constants
    chunk_results = pmap(i -> solve_scenario(shared_network, i, p_rng, q_rng, opts[:solver]), start_idx:end_idx)

    successful_results = filter(r -> r != nothing, chunk_results)

    for r in chunk_results
        if r != nothing
            push!(all_successful_ids, r.id)
        end
    end

    if !isempty(successful_results)
        write_chunk_to_hdf5(chunk_filename, successful_results)
    end

    chunk_results = nothing
    successful_results = nothing
    GC.gc()
end

println("\n" * "="^60)
println("FINAL RESULTS")
println("="^60)

println("success rate: $(length(all_successful_ids)) / $n_scenarios")
