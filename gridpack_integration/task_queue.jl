# Task Queue Generator for GridPACK + Julia Integration
# Generates task_queue.csv and network.h5 for distributed processing

using Pkg.Artifacts
using PowerModels
using HDF5
using ArgParse
using DelimitedFiles

# Include shared utilities
include(joinpath(@__DIR__, "..", "julia_only", "enumerate_contingencies.jl"))

function parse_cli()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--instance"
            help = "PGLib instance name (without .m)"
            arg_type = String
            default = "pglib_opf_case24_ieee_rts"
        "--n_scenarios"
            help = "Number of scenarios"
            arg_type = Int
            default = 10
        "--contingency_type"
            help = "Contingency type: all, line, gen, n2, file"
            arg_type = String
            default = "all"
        "--contingency_file"
            help = "Path to contingency list CSV (when --contingency_type=file)"
            arg_type = String
            default = ""
        "--min_voltage"
            help = "Minimum bus voltage (kV) for filtering contingencies"
            arg_type = Float64
            default = 0.0
        "--max_contingencies"
            help = "Maximum number of contingencies (for N-2 or large systems)"
            arg_type = Int
            default = 0
        "--output_dir"
            help = "Output directory for task queue and network"
            arg_type = String
            default = "workdir"
        "--p_range"
            help = "Active power perturbation range as a,b"
            arg_type = String
            default = "0.9,1.1"
        "--q_range"
            help = "Reactive power perturbation range as a,b"
            arg_type = String
            default = "0.9,1.1"
    end
    return parse_args(s)
end

"""
    write_network_hdf5(network, filepath)

Write base network to HDF5 for workers to read.
"""
function write_network_hdf5(network, filepath)
    h5open(filepath, "w") do f
        # Buses
        bus_ids = sort(parse.(Int, collect(keys(network["bus"]))))
        n_bus = length(bus_ids)
        bus_data = zeros(Float32, n_bus, 6)
        for (i, bus_id) in enumerate(bus_ids)
            bus = network["bus"]["$bus_id"]
            bus_data[i, :] = [
                bus_id,
                get(bus, "vmin", 0.9),
                get(bus, "vmax", 1.1),
                get(bus, "zone", 1),
                get(bus, "area", 1),
                get(bus, "bus_type", 1)
            ]
        end
        f["bus"] = bus_data

        # Generators
        gen_ids = sort(parse.(Int, collect(keys(network["gen"]))))
        n_gen = length(gen_ids)
        gen_data = zeros(Float32, n_gen, 12)
        for (i, gen_id) in enumerate(gen_ids)
            gen = network["gen"]["$gen_id"]
            cost = get(gen, "cost", [0.0, 0.0, 0.0])
            gen_data[i, :] = [
                gen_id,
                get(gen, "gen_bus", 0),
                get(gen, "pmax", 0),
                get(gen, "pmin", 0),
                get(gen, "qmax", 0),
                get(gen, "qmin", 0),
                length(cost) >= 3 ? cost[1] : 0,
                length(cost) >= 2 ? cost[2] : 0,
                length(cost) >= 1 ? cost[end] : 0,
                get(gen, "vg", 1.0),
                get(gen, "mbase", 100),
                get(gen, "gen_status", 1)
            ]
        end
        f["gen"] = gen_data

        # Branches
        branch_ids = sort(parse.(Int, collect(keys(network["branch"]))))
        n_branch = length(branch_ids)
        branch_data = zeros(Float32, n_branch, 14)
        for (i, br_id) in enumerate(branch_ids)
            br = network["branch"]["$br_id"]
            branch_data[i, :] = [
                br_id,
                get(br, "f_bus", 0),
                get(br, "t_bus", 0),
                get(br, "br_r", 0),
                get(br, "br_x", 0),
                get(br, "b_fr", 0),
                get(br, "b_to", 0),
                get(br, "rate_a", 0),
                get(br, "rate_b", 0),
                get(br, "rate_c", 0),
                get(br, "tap", 1.0),
                get(br, "shift", 0),
                get(br, "angmin", -pi/2),
                get(br, "angmax", pi/2)
            ]
        end
        f["branch"] = branch_data

        # Loads
        load_ids = sort(parse.(Int, collect(keys(network["load"]))))
        n_load = length(load_ids)
        load_data = zeros(Float32, n_load, 4)
        for (i, load_id) in enumerate(load_ids)
            load = network["load"]["$load_id"]
            load_data[i, :] = [
                load_id,
                get(load, "load_bus", 0),
                get(load, "pd", 0),
                get(load, "qd", 0)
            ]
        end
        f["load"] = load_data

        # Context
        f["baseMVA"] = Float32[get(network, "baseMVA", 100)]

        # Store ID mappings for workers
        f["bus_ids"] = Int32.(bus_ids)
        f["gen_ids"] = Int32.(gen_ids)
        f["branch_ids"] = Int32.(branch_ids)
        f["load_ids"] = Int32.(load_ids)
    end
end

"""
    generate_task_queue(network, n_scenarios, opts)

Generate list of (scenario, contingency) task pairs.

Parameters:
- network: PowerModels network dictionary
- n_scenarios: Number of scenarios
- opts: Parsed command line options containing:
  - contingency_type: "all", "line", "gen", "n2", "file"
  - contingency_file: Path to CSV file (when type="file")
  - min_voltage: Minimum voltage for filtering
  - max_contingencies: Maximum number of contingencies
"""
function generate_task_queue(network, n_scenarios, opts)
    contingency_type = opts["contingency_type"]
    min_voltage = opts["min_voltage"]
    max_cont = opts["max_contingencies"]

    # Enumerate contingencies based on type
    if contingency_type == "file"
        if opts["contingency_file"] == ""
            error("--contingency_file required when --contingency_type=file")
        end
        contingencies = read_contingencies_from_file(opts["contingency_file"], network)
        println("  Loaded $(length(contingencies)) contingencies from file")

    elseif contingency_type == "n2"
        max_count = max_cont > 0 ? max_cont : nothing
        contingencies = enumerate_n2_contingencies(network; max_count=max_count)
        println("  Generated $(length(contingencies)) N-2 contingencies")

    else
        # N-1 contingencies with optional filtering
        all_contingencies = enumerate_n1_contingencies(network; min_voltage=min_voltage)

        if contingency_type == "line"
            contingencies = filter(c -> c.type == :line, all_contingencies)
        elseif contingency_type == "gen"
            contingencies = filter(c -> c.type == :gen, all_contingencies)
        else  # "all"
            contingencies = all_contingencies
        end

        # Apply max limit if specified
        if max_cont > 0 && length(contingencies) > max_cont
            contingencies = contingencies[1:max_cont]
            println("  Limited to $max_cont contingencies")
        end
    end

    tasks = []
    task_id = 0

    for scenario_id in 1:n_scenarios
        # Base case (no contingency)
        push!(tasks, (
            task_id = task_id,
            scenario_id = scenario_id,
            contingency_type = "base",
            contingency_id = "",
            contingency_name = "BASE_CASE"
        ))
        task_id += 1

        # Contingency cases
        for cont in contingencies
            push!(tasks, (
                task_id = task_id,
                scenario_id = scenario_id,
                contingency_type = string(cont.type),
                contingency_id = cont.id,
                contingency_name = cont.name
            ))
            task_id += 1
        end
    end

    return tasks, contingencies
end

"""
    write_task_queue_csv(tasks, filepath)

Write task queue to CSV file.
"""
function write_task_queue_csv(tasks, filepath)
    open(filepath, "w") do f
        # Header
        println(f, "task_id,scenario_id,contingency_type,contingency_id,contingency_name")
        # Data
        for t in tasks
            println(f, "$(t.task_id),$(t.scenario_id),$(t.contingency_type),$(t.contingency_id),$(t.contingency_name)")
        end
    end
end

"""
    write_config(opts, n_tasks, filepath)

Write configuration file for workers.
"""
function write_config(opts, n_tasks, filepath)
    open(filepath, "w") do f
        println(f, "# Task queue configuration")
        println(f, "instance=$(opts["instance"])")
        println(f, "n_scenarios=$(opts["n_scenarios"])")
        println(f, "n_tasks=$n_tasks")
        println(f, "contingency_type=$(opts["contingency_type"])")
        println(f, "p_range=$(opts["p_range"])")
        println(f, "q_range=$(opts["q_range"])")
    end
end

# Main execution
function main()
    opts = parse_cli()

    println("="^70)
    println("TASK QUEUE GENERATOR")
    println("="^70)

    # Load network
    pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
    case_file = joinpath(pglib_path, "$(opts["instance"]).m")

    PowerModels.silence()
    network = PowerModels.parse_file(case_file)

    n_buses = length(network["bus"])
    n_branches = length(network["branch"])
    n_gens = length(network["gen"])

    println("\nNetwork: $(opts["instance"])")
    println("  Buses: $n_buses, Branches: $n_branches, Generators: $n_gens")

    # Create output directory
    mkpath(opts["output_dir"])
    mkpath(joinpath(opts["output_dir"], "results"))

    # Write network HDF5
    network_file = joinpath(opts["output_dir"], "network.h5")
    write_network_hdf5(network, network_file)
    println("\nWritten: $network_file")

    # Generate task queue
    tasks, contingencies = generate_task_queue(network, opts["n_scenarios"], opts)
    n_tasks = length(tasks)

    task_file = joinpath(opts["output_dir"], "task_queue.csv")
    write_task_queue_csv(tasks, task_file)
    println("Written: $task_file")

    # Write contingency list (for reference/debugging)
    cont_file = joinpath(opts["output_dir"], "contingencies.csv")
    write_contingencies_to_file(cont_file, contingencies)
    println("Written: $cont_file")

    # Write config
    config_file = joinpath(opts["output_dir"], "config.txt")
    write_config(opts, n_tasks, config_file)
    println("Written: $config_file")

    # Summary
    n_contingencies = length(contingencies)
    println("\n" * "="^70)
    println("SUMMARY")
    println("="^70)
    println("Scenarios: $(opts["n_scenarios"])")
    println("Contingencies per scenario: $n_contingencies (+ 1 base case)")
    println("Total tasks: $n_tasks")
    println("Contingency type: $(opts["contingency_type"])")
    if opts["min_voltage"] > 0
        println("Min voltage filter: $(opts["min_voltage"]) kV")
    end
    println("Output directory: $(opts["output_dir"])")
    println("="^70)
end

main()
