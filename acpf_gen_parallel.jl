using Pkg.Artifacts
using Distributed
using ArgParse
using PowerModels

function parse_cli()
    settings = ArgParseSettings()
    @add_arg_table settings begin
        "--solver"
            help = "Solver to use: ipopt"
            arg_type = String
            default = "ipopt"
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
            help = "Number of scenarios per output chunk"
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
        "--seed_offset"
            help = "Base seed added to scenario id for reproducible perturbations"
            arg_type = Int
            default = 230
    end

    parsed = parse_args(settings)

    opts = Dict{Symbol,Any}()
    opts[:solver] = Symbol(lowercase(parsed["solver"]))
    opts[:instance] = parsed["instance"]
    opts[:nprocs] = parsed["nprocs"]
    opts[:n_scenarios] = parsed["n_scenarios"]
    opts[:chunk_size] = parsed["chunk_size"]
    opts[:output_dir] = parsed["output_dir"] == "" ? joinpath("results_pf", parsed["instance"]) : parsed["output_dir"]
    pr = split(parsed["p_range"], ",")
    opts[:p_range] = (parse(Float64, pr[1]), parse(Float64, pr[2]))
    qr = split(parsed["q_range"], ",")
    opts[:q_range] = (parse(Float64, qr[1]), parse(Float64, qr[2]))
    opts[:seed_offset] = parsed["seed_offset"]

    return opts
end

opts = parse_cli()

addprocs(opts[:nprocs])

pglib_root = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
case_path = joinpath(pglib_root, string(opts[:instance], ".m"))

@everywhere begin
    using PowerModels
    using JuMP
    using Ipopt
    include("perturbations.jl")
    include("hdf5_writer.jl")
    include("powerflow_utils.jl")

    function solve_acpf_scenario(base_network, scenario_id, p_range, q_range, solver_sym, seed_offset)
        network = deepcopy(base_network)
        perturb_loads_separate!(network, p_range, q_range, seed_offset + scenario_id)

        pm = instantiate_model(network, ACPPowerModel, PowerModels.build_pf)

        if solver_sym == :ipopt
            JuMP.set_optimizer(pm.model, Ipopt.Optimizer)
        else
            error("Unsupported solver for AC power flow on worker: $(solver_sym)")
        end

        result = try
            optimize_model!(pm)
        catch err
            println("AC power flow scenario $(scenario_id) failed with solver $(solver_sym):")
            showerror(stdout, err)
            println()
            return nothing
        end

        ensure_result_metrics!(result)

        return (
            id = scenario_id,
            network = network,
            result = result,
            obj = result["objective"],
            time = result["solve_time"],
            status = string(result["termination_status"]),
            power_slack = 0.0,
            line_slack = 0.0
        )
    end
end

PowerModels.silence()
base_network = PowerModels.parse_file(case_path)

mkpath(opts[:output_dir])

println("Solving $(opts[:n_scenarios]) AC power flow scenarios on $(nworkers()) workers...")

n_chunks = ceil(Int, opts[:n_scenarios] / opts[:chunk_size])

for chunk_idx in 1:n_chunks
    start_idx = (chunk_idx - 1) * opts[:chunk_size] + 1
    end_idx = min(chunk_idx * opts[:chunk_size], opts[:n_scenarios])

    chunk_filename = joinpath(opts[:output_dir], "chunk_$(lpad(chunk_idx, 4, '0')).h5")
    if isfile(chunk_filename)
        println("Chunk $chunk_idx exists, skipping...")
        continue
    end

    scenario_range = collect(start_idx:end_idx)
    chunk_results = pmap(i -> solve_acpf_scenario(base_network, i, opts[:p_range], opts[:q_range], opts[:solver], opts[:seed_offset]), scenario_range)

    successful = filter(!isnothing, chunk_results)

    if !isempty(successful)
        write_chunk_to_hdf5(chunk_filename, successful)
    end
end

println("AC power flow scenario generation complete. Outputs stored in $(opts[:output_dir])")

