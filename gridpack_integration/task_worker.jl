# Task Worker for GridPACK + Julia Integration
# Processes a single (scenario, contingency) task

using Pkg.Artifacts
using PowerModels
using Ipopt
using JuMP
using HDF5
using ArgParse
using DelimitedFiles

# Include shared utilities
include(joinpath(@__DIR__, "..", "acopf_model.jl"))
include(joinpath(@__DIR__, "..", "perturbations.jl"))

function parse_cli()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--task_id"
            help = "Task ID to process"
            arg_type = Int
            required = true
        "--workdir"
            help = "Working directory with network.h5 and task_queue.csv"
            arg_type = String
            default = "workdir"
        "--instance"
            help = "PGLib instance name (without .m)"
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
    return parse_args(s)
end

"""
    read_instance_from_config(workdir)

Read instance name from config file.
"""
function read_instance_from_config(workdir)
    config_file = joinpath(workdir, "config.txt")
    for line in eachline(config_file)
        if startswith(line, "instance=")
            return split(line, "=")[2]
        end
    end
    error("instance not found in config.txt")
end

"""
    read_task(task_queue_file, task_id)

Read a single task from the task queue CSV.
"""
function read_task(task_queue_file, task_id)
    data, header = readdlm(task_queue_file, ',', String, header=true)

    for i in 1:size(data, 1)
        if parse(Int, data[i, 1]) == task_id
            return (
                task_id = task_id,
                scenario_id = parse(Int, data[i, 2]),
                contingency_type = data[i, 3],
                contingency_id = data[i, 4],
                contingency_name = data[i, 5]
            )
        end
    end

    error("Task $task_id not found in $task_queue_file")
end

"""
    apply_contingency!(network, contingency_type, contingency_id)

Apply a contingency to the network.
"""
function apply_contingency!(network, contingency_type, contingency_id)
    if contingency_type == "base"
        return  # No contingency
    elseif contingency_type == "line"
        network["branch"][contingency_id]["br_status"] = 0
    elseif contingency_type == "gen"
        network["gen"][contingency_id]["gen_status"] = 0
    else
        error("Unknown contingency type: $contingency_type")
    end
end

"""
    get_load_data(network)

Extract load data with weights (pd, qd, weight_p, weight_q).
Uses uniform weights (1.0) if not available in network.
"""
function get_load_data(network)
    load_ids = sort(parse.(Int, collect(keys(network["load"]))))
    n_load = length(load_ids)
    load_data = zeros(Float32, n_load, 4)

    for (i, load_id) in enumerate(load_ids)
        load = network["load"]["$load_id"]
        pd = get(load, "pd", 0.0)
        qd = get(load, "qd", 0.0)
        # Use weight if available, otherwise default to 1.0
        weight_p = Float32(get(load, "weight", 1.0))
        weight_q = Float32(get(load, "weight", 1.0))
        load_data[i, :] = [pd, qd, weight_p, weight_q]
    end

    return load_data, load_ids
end

"""
    calculate_load_served(network, opf_result)

Calculate load served per load based on bus-level slack variables.
Distributes slack proportionally by load weight at each bus.
"""
function calculate_load_served(network, opf_result)
    load_ids = sort(parse.(Int, collect(keys(network["load"]))))
    n_load = length(load_ids)
    load_served = zeros(Float32, n_load, 2)

    # Build mapping: bus_id -> list of (load_idx, pd, qd, weight)
    bus_loads = Dict{Int, Vector{Tuple{Int, Float64, Float64, Float64}}}()
    for (i, load_id) in enumerate(load_ids)
        load = network["load"]["$load_id"]
        bus_id = load["load_bus"]
        pd = get(load, "pd", 0.0)
        qd = get(load, "qd", 0.0)
        weight = get(load, "weight", 1.0)

        if !haskey(bus_loads, bus_id)
            bus_loads[bus_id] = []
        end
        push!(bus_loads[bus_id], (i, pd, qd, weight))
    end

    # Initialize load_served = input load (no shedding by default)
    for (i, load_id) in enumerate(load_ids)
        load = network["load"]["$load_id"]
        load_served[i, :] = [get(load, "pd", 0.0), get(load, "qd", 0.0)]
    end

    # If slack variables present, distribute shedding
    #       When generation < load, p_slack_pos > 0 means load shedding
    if haskey(opf_result.result, "solution") && haskey(opf_result.result["solution"], "bus")
        for (bus_id_str, bus_sol) in opf_result.result["solution"]["bus"]
            bus_id = parse(Int, bus_id_str)

            # p_slack_pos represents load shedding (virtual generation to balance deficit)
            p_shed = get(bus_sol, "p_slack_pos", 0.0)
            q_shed = get(bus_sol, "q_slack_pos", 0.0)

            if (p_shed > 1e-6 || q_shed > 1e-6) && haskey(bus_loads, bus_id)
                loads_at_bus = bus_loads[bus_id]
                total_weight = sum(l[4] for l in loads_at_bus)

                if total_weight > 0
                    for (idx, pd, qd, weight) in loads_at_bus
                        # Distribute shedding inversely by weight (higher weight = less shed)
                        # shed proportionally to load magnitude
                        total_pd = sum(l[2] for l in loads_at_bus)
                        total_qd = sum(l[3] for l in loads_at_bus)

                        p_shed_load = total_pd > 0 ? p_shed * (pd / total_pd) : 0.0
                        q_shed_load = total_qd > 0 ? q_shed * (qd / total_qd) : 0.0

                        load_served[idx, 1] = max(0.0, pd - p_shed_load)
                        load_served[idx, 2] = max(0.0, qd - q_shed_load)
                    end
                end
            end
        end
    end

    return load_served
end

"""
    solve_pf(network)

Solve AC Power Flow using flat start.
Returns named tuple with result and convergence status.
"""
function solve_pf(network)
    result = PowerModels.solve_ac_pf(network, Ipopt.Optimizer;
        setting = Dict("output" => Dict("duals" => false)))

    converged = result["termination_status"] == MOI.LOCALLY_SOLVED

    return (
        result = result,
        converged = converged
    )
end

"""
    solve_opf(network)

Solve AC-OPF with retry using slack variables if needed.
"""
function solve_opf(network)
    power_balance_relaxation = false
    line_limit_relaxation = false

    # First attempt: strict constraints
    pm = instantiate_model(network, ACPPowerModel,
        pm -> build_opf_with_slacks(pm,
            power_balance_relaxation=false,
            line_limit_relaxation=false
        )
    )

    JuMP.set_optimizer(pm.model, Ipopt.Optimizer)
    JuMP.set_attribute(pm.model, "print_level", 0)

    result = optimize_model!(pm)

    # Retry with slack if needed
    if result["termination_status"] != MOI.LOCALLY_SOLVED
        pm = instantiate_model(network, ACPPowerModel,
            pm -> build_opf_with_slacks(pm,
                power_balance_relaxation=true,
                line_limit_relaxation=true
            )
        )
        power_balance_relaxation = true
        line_limit_relaxation = true

        JuMP.set_optimizer(pm.model, Ipopt.Optimizer)
        JuMP.set_attribute(pm.model, "print_level", 0)
        result = optimize_model!(pm)
    end

    # Calculate slack totals
    total_power_slack = 0.0
    total_line_slack = 0.0

    if power_balance_relaxation && haskey(result, "solution")
        for (i, bus) in result["solution"]["bus"]
            if haskey(bus, "p_slack_pos")
                total_power_slack += bus["p_slack_pos"] + bus["p_slack_neg"] +
                                     bus["q_slack_pos"] + bus["q_slack_neg"]
            end
        end
    end

    if line_limit_relaxation && haskey(result, "solution")
        for (i, branch) in result["solution"]["branch"]
            if haskey(branch, "s_slack")
                total_line_slack += branch["s_slack"]
            end
        end
    end

    return (
        result = result,
        power_slack = total_power_slack,
        line_slack = total_line_slack,
        converged = result["termination_status"] == MOI.LOCALLY_SOLVED
    )
end

"""
    write_result_hdf5(filepath, task, network, pf_result, opf_result)

Write task result to HDF5 file with both PF and OPF solutions.
"""
function write_result_hdf5(filepath, task, network, pf_result, opf_result)
    h5open(filepath, "w") do f
        # Task info
        g_task = create_group(f, "task")
        attributes(g_task)["task_id"] = Int32(task.task_id)
        attributes(g_task)["scenario_id"] = Int32(task.scenario_id)
        attributes(g_task)["contingency_type"] = task.contingency_type
        attributes(g_task)["contingency_id"] = task.contingency_id
        attributes(g_task)["contingency_name"] = task.contingency_name

        # Power Flow status
        g_pf_status = create_group(f, "pf_status")
        attributes(g_pf_status)["converged"] = Int8(pf_result.converged ? 1 : 0)
        attributes(g_pf_status)["termination_status"] = string(pf_result.result["termination_status"])
        attributes(g_pf_status)["solve_time"] = Float32(get(pf_result.result, "solve_time", 0.0))

        # OPF status
        g_opf_status = create_group(f, "opf_status")
        attributes(g_opf_status)["converged"] = Int8(opf_result.converged ? 1 : 0)
        attributes(g_opf_status)["termination_status"] = string(opf_result.result["termination_status"])
        attributes(g_opf_status)["objective"] = Float32(get(opf_result.result, "objective", 0.0))
        attributes(g_opf_status)["solve_time"] = Float32(get(opf_result.result, "solve_time", 0.0))
        attributes(g_opf_status)["power_slack"] = Float32(opf_result.power_slack)
        attributes(g_opf_status)["line_slack"] = Float32(opf_result.line_slack)

        # Common data
        bus_ids = sort(parse.(Int, collect(keys(network["bus"]))))
        gen_ids = sort(parse.(Int, collect(keys(network["gen"]))))
        n_bus = length(bus_ids)
        n_gen = length(gen_ids)

        # Load data with weights (pd, qd, weight_p, weight_q)
        load_data, load_ids = get_load_data(network)
        n_load = length(load_ids)

        g_load = create_group(f, "load")
        g_load["data"] = load_data  # [n_load, 4]: pd, qd, weight_p, weight_q

        # Write PF solution if converged
        if pf_result.converged
            g_pf = create_group(f, "pf_solution")

            # PF Bus solution (va, vm)
            pf_bus_sol = zeros(Float32, n_bus, 2)
            for (i, bus_id) in enumerate(bus_ids)
                if haskey(pf_result.result["solution"]["bus"], "$bus_id")
                    bus = pf_result.result["solution"]["bus"]["$bus_id"]
                    pf_bus_sol[i, :] = [get(bus, "va", 0), get(bus, "vm", 1)]
                end
            end
            g_pf["bus"] = pf_bus_sol

            # PF Generator solution (pg, qg)
            pf_gen_sol = zeros(Float32, n_gen, 2)
            for (i, gen_id) in enumerate(gen_ids)
                if haskey(pf_result.result["solution"]["gen"], "$gen_id")
                    gen = pf_result.result["solution"]["gen"]["$gen_id"]
                    pf_gen_sol[i, :] = [get(gen, "pg", 0), get(gen, "qg", 0)]
                end
            end
            g_pf["generator"] = pf_gen_sol

            # PF Load served (for PF, no shedding - served = input)
            pf_load_served = load_data[:, 1:2]  # pd, qd (no shedding in PF)
            g_pf["load"] = pf_load_served
        end

        # Write OPF solution if converged
        if opf_result.converged
            g_opf = create_group(f, "opf_solution")

            # OPF Bus solution (va, vm)
            opf_bus_sol = zeros(Float32, n_bus, 2)
            for (i, bus_id) in enumerate(bus_ids)
                if haskey(opf_result.result["solution"]["bus"], "$bus_id")
                    bus = opf_result.result["solution"]["bus"]["$bus_id"]
                    opf_bus_sol[i, :] = [get(bus, "va", 0), get(bus, "vm", 1)]
                end
            end
            g_opf["bus"] = opf_bus_sol

            # OPF Generator solution (pg, qg)
            opf_gen_sol = zeros(Float32, n_gen, 2)
            for (i, gen_id) in enumerate(gen_ids)
                if haskey(opf_result.result["solution"]["gen"], "$gen_id")
                    gen = opf_result.result["solution"]["gen"]["$gen_id"]
                    opf_gen_sol[i, :] = [get(gen, "pg", 0), get(gen, "qg", 0)]
                end
            end
            g_opf["generator"] = opf_gen_sol

            # OPF Load served (may have shedding via slack)
            opf_load_served = calculate_load_served(network, opf_result)
            g_opf["load"] = opf_load_served
        end
    end
end

# Main execution
function main()
    opts = parse_cli()

    task_id = opts["task_id"]
    workdir = opts["workdir"]

    # Parse perturbation ranges
    pr = split(opts["p_range"], ",")
    p_range = (parse(Float64, pr[1]), parse(Float64, pr[2]))
    qr = split(opts["q_range"], ",")
    q_range = (parse(Float64, qr[1]), parse(Float64, qr[2]))

    # Read task
    task_queue_file = joinpath(workdir, "task_queue.csv")
    task = read_task(task_queue_file, task_id)

    # Get instance name from config or command line
    instance = opts["instance"]
    if instance == ""
        instance = read_instance_from_config(workdir)
    end

    # Load network from original .m file 
    pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
    case_file = joinpath(pglib_path, "$(instance).m")

    PowerModels.silence()
    network = PowerModels.parse_file(case_file)

    # Apply load perturbation
    perturb_loads_separate!(network, p_range, q_range, task.scenario_id)

    # Apply contingency
    apply_contingency!(network, task.contingency_type, task.contingency_id)

    # Step 1: Solve AC Power Flow
    pf_result = solve_pf(network)
    pf_status = pf_result.converged ? "PF_OK" : "PF_FAIL"

    # Step 2: Solve AC-OPF
    opf_result = solve_opf(network)
    opf_status = opf_result.converged ? "OPF_OK" : "OPF_FAIL"

    # Write result
    result_file = joinpath(workdir, "results", "task_$(lpad(task_id, 6, '0')).h5")
    write_result_hdf5(result_file, task, network, pf_result, opf_result)

    # Print status
    println("Task $task_id: $pf_status / $opf_status ($(task.contingency_name))")
end

main()
