using JuMP
using PowerModels
using HiGHS
using Ipopt
using Pkg.Artifacts
using ArgParse
using ArgParse: ArgParseSettings, @add_arg_table
import MathOptInterface

const MOI = MathOptInterface

include("opb_utils.jl")
include("hdf5_writer.jl")

function parse_cli()
    positional_case = nothing
    positional_solver = nothing
    idx = 1
    while idx <= length(ARGS) && !startswith(ARGS[idx], "-")
        if positional_case === nothing
            positional_case = ARGS[idx]
        elseif positional_solver === nothing
            positional_solver = ARGS[idx]
        else
            break
        end
        idx += 1
    end

    remaining_argv = idx <= length(ARGS) ? ARGS[idx:end] : String[]

    settings = ArgParseSettings()
    @add_arg_table settings begin
        "--instance"
            help = "PGLib instance name without .m"
            arg_type = String
            default = nothing
        "--solver"
            help = "Solver to use: highs | ipopt"
            arg_type = String
            default = nothing
        "--write_output"
            help = "Write OPB solution to an HDF5 file"
            arg_type = Bool
            default = false
        "--output_file"
            help = "Output HDF5 filename"
            arg_type = String
            default = "test_opb_001.h5"
    end

    parsed = parse_args(remaining_argv, settings)

    instance = something(parsed["instance"], positional_case, "pglib_opf_case24_ieee_rts")
    solver = lowercase(something(parsed["solver"], positional_solver, "highs"))

    return Dict(
        :instance => instance,
        :solver => Symbol(solver),
        :write_output => parsed["write_output"],
        :output_file => parsed["output_file"]
    )
end


# Extract quadratic cost coefficients robustly
function extract_cost_coeffs(cost)
    # Case 1: Dict format
    if cost isa Dict
        a = get(cost, "nc2", 0.0)
        b = get(cost, "nc1", 0.0)
        c = get(cost, "nc0", 0.0)
        return a, b, c
    end

    # Case 2: Vector format
    if cost isa Vector
        if length(cost) == 3
            return cost[1], cost[2], cost[3]
        elseif length(cost) == 2
            return 0.0, cost[1], cost[2]
        elseif length(cost) == 1
            return 0.0, 0.0, cost[1]
        elseif length(cost) == 0
            # EMPTY COST => zero cost generator
            return 0.0, 0.0, 0.0
        else
            error("Unknown cost vector format: $cost")
        end
    end

    error("Unknown cost format: $cost")
end



function opb_data_from_network(network)

    gens = network["gen"]
    loads = haskey(network, "load") ? network["load"] : Dict()

    gen_list = Vector{Dict{Symbol,Float64}}()
    gen_ids = sort(collect(keys(gens)))

    # === Extract generator data ===
    for g in gen_ids
        ginfo = gens[g]
        cost = ginfo["cost"]

        a, b, c = extract_cost_coeffs(cost)

        pmin = ginfo["pmin"]
        pmax = ginfo["pmax"]

        push!(gen_list, Dict(
            :pmin => pmin,
            :pmax => pmax,
            :a => a,
            :b => b,
            :c => c
        ))
    end

    # === Compute total demand from load table ===
    total_demand = 0.0
    for (id, loadinfo) in loads
        total_demand += loadinfo["pd"]      # active demand
    end

    return gen_list, total_demand, gen_ids
end

function normalize_generator_costs!(network)
    for (_, gen) in network["gen"]
        cost = gen["cost"]
        if cost isa Dict
            a, b, c = extract_cost_coeffs(cost)
            gen["cost"] = [a, b, c]
        end
    end
end

# ------------------------------------------------------------
# ------------------------------------------------------------
# Build OPB JuMP model (pure ED, no network)
# NOTE: OPB treats the system as a single demand snapshot without temporal coupling.
# ------------------------------------------------------------
function build_opb(gen_data, total_demand)
    m = Model()

    G = length(gen_data)
    @variable(m, p[1:G])

    # Bounds for each generator
    for g in 1:G
        set_lower_bound(p[g], gen_data[g][:pmin])
        set_upper_bound(p[g], gen_data[g][:pmax])
    end

    # Quadratic cost objective
    @objective(m, Min,
        sum(gen_data[g][:a] * p[g]^2 +
            gen_data[g][:b] * p[g] +
            gen_data[g][:c] for g in 1:G)
    )

    # Single power balance constraint
    @constraint(m, sum(p[g] for g in 1:G) == total_demand)

    return m
end


# ------------------------------------------------------------
# Main program
# Example invocations:
#   env -u LD_PRELOAD julia --project opb_gen.jl pglib_opf_case14_ieee highs --write_output=true --output_file=results/opb_case14.h5
#   env -u LD_PRELOAD julia --project opb_gen.jl --instance=pglib_opf_case118_ieee --solver=ipopt --write_output=true --output_file=results/opb_case118.h5
# ------------------------------------------------------------
function main()
    opts = parse_cli()

    case_name = opts[:instance]
    solver_sym = opts[:solver]

    # Locate PGLib artifact
    pglib_root = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
    case_path = joinpath(pglib_root, case_name * ".m")

    # Load MATPOWER case
    network = PowerModels.parse_file(case_path)
    normalize_generator_costs!(network)
    println("=== DEBUG: GENERATOR COSTS ===")
    for (i, ginfo) in network["gen"]
        println("Gen $i cost = ", ginfo["cost"])
    end
    println("\n=== DEBUG: GEN LIMITS ===")
    for (g, ginfo) in network["gen"]
        println("Gen $g: pmin=$(ginfo["pmin"]), pmax=$(ginfo["pmax"])")
    end

    # Extract OPB data
    gen_data, total_demand, gen_ids = opb_data_from_network(network)

    println("\nLoaded case: $case_name")
    println("Generators: $(length(gen_data))")
    println("Total Demand: $total_demand\n")

    # Build OPB model
    m = build_opb(gen_data, total_demand)

    # Select solver
    if solver_sym == :highs
        set_optimizer(m, HiGHS.Optimizer)
    elseif solver_sym == :ipopt
        set_optimizer(m, Ipopt.Optimizer)
    else
        error("Unknown solver: $solver_sym")
    end

    solve_elapsed = @elapsed optimize!(m)
    status = termination_status(m)
    objective = objective_value(m)

    println("\n=== OPB Solution Results ===")
    println("Termination status: ", status)
    println("Objective value: ", objective)
    println("Generator outputs (p_g):")

    gen_solution = Dict{String,Dict{String,Float64}}()
    gen_vars = m[:p]
    for (idx, gen_id) in enumerate(gen_ids)
        pg_val = value(gen_vars[idx])
        println("  Gen $(gen_id): ", pg_val)
        gen_solution[string(gen_id)] = Dict("pg" => pg_val, "qg" => 0.0)
        network["gen"][gen_id]["pg"] = pg_val
        network["gen"][gen_id]["qg"] = 0.0
    end

    solve_time_attr = try
        MOI.get(JuMP.backend(m), MOI.SolveTime())
    catch
        nothing
    end

    solve_time = solve_time_attr isa Real ? float(solve_time_attr) : solve_elapsed

    result = Dict{String,Any}(
        "objective" => objective,
        "termination_status" => string(status),
        "solve_time" => solve_time,
        "solution" => Dict("gen" => gen_solution)
    )

    augment_opb_solution!(result, network)

    if opts[:write_output]
        write_scenario_to_hdf5(opts[:output_file], network, result, 1, 0.0, 0.0)
        verify_hdf5_structure(opts[:output_file])
    end
end

main()

