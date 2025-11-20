using Pkg.Artifacts
using Distributed
using ProgressMeter
using HDF5

addprocs(5)

pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")


# Push configuration and required imports to worker processes
@everywhere begin

    # Solver selection: default is :madnlp. Override with ARGS[1] or ENV["OPF_SOLVER"].
    function _choose_solver(default::Symbol=:madnlp)
        arg = isempty(ARGS) ? get(ENV, "OPF_SOLVER", "") : ARGS[1]
        if arg == "" || arg === nothing
            return default
        end
        s = Symbol(lowercase(arg))
        if s in (:madnlp, :madnlpgpu, :ipopt)
            return s
        end
        error("Unknown solver: $arg. Allowed values: ipopt, madnlp")
    end

    function _choose_instance(default::String="pglib_opf_case24_ieee_rts")
        val = length(ARGS) >= 2 ? ARGS[2] : get(ENV, "OPF_INSTANCE", "")
        return val == "" ? default : String(val)
    end

    const INSTANCE = _choose_instance("pglib_opf_case24_ieee_rts")
    const SOLVER = _choose_solver(:madnlp)

    # global INSTANCE = $INSTANCE
    # global pglib_path = $pglib_path
    using MadNLP
    using MadNLPHSL
    using PowerModels
    using JuMP
    using Random
    using HDF5
    include("acopf_model.jl")
    include("perturbations.jl")
    include("hdf5_writer.jl")

    function solve_scenario(base_network, scenario_id, p_range, q_range)
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
            JuMP.set_optimizer(pm.model, ()->MadNLP.Optimizer(linear_solver=Ma27Solver, print_level=MadNLP.INFO))
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
                JuMP.set_optimizer(pm.model, ()->MadNLP.Optimizer(linear_solver=Ma27Solver, print_level=MadNLP.INFO))
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

# Configuration
case_file = joinpath(pglib_path, "$(INSTANCE).m")
n_scenarios = 10
chunk_size = 2
output_dir = "results/$(INSTANCE)"
p_range = (0.9, 1.1)
q_range = (0.9, 1.1)

mkpath(output_dir)

println("Loading network and distributing to workers...")
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
    
    chunk_results = pmap(i -> solve_scenario(shared_network, i, p_rng, q_rng), start_idx:end_idx)

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
