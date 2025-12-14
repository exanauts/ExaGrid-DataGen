using JuMP
using PowerModels
using HiGHS
using Ipopt
using Pkg.Artifacts


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

    # === Extract generator data ===
    for g in sort(collect(keys(gens)))
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

    return gen_list, total_demand
end



# ------------------------------------------------------------
# Build OPB JuMP model (pure ED, no network)
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
# Usage example:
#   julia run_opb.jl pglib_opf_case14_ieee highs
# ------------------------------------------------------------
function main()
    if length(ARGS) < 2
        println("Usage: julia run_opb.jl <pglib_case_without_dot_m> <solver: highs|ipopt>")
        return
    end

    case_name = ARGS[1]
    solver_name = ARGS[2]

    # Locate PGLib artifact
    pglib_root = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
    case_path = joinpath(pglib_root, case_name * ".m")

    # Load MATPOWER case
    network = PowerModels.parse_file(case_path)
    println("=== DEBUG: GENERATOR COSTS ===")
    for (i, ginfo) in network["gen"]
        println("Gen $i cost = ", ginfo["cost"])
    end
    println("\n=== DEBUG: GEN LIMITS ===")
    for (g, ginfo) in network["gen"]
        println("Gen $g: pmin=$(ginfo["pmin"]), pmax=$(ginfo["pmax"])")
    end


    # println("\n=== DEBUG: GEN KEYS ===")
    # for (g, ginfo) in network["gen"]
    #     println("Generator $g keys = ", keys(ginfo))
    # end

    # println("\n=== DEBUG: BUS KEYS ===")
    # for (i, businfo) in network["bus"]
    #     println("Bus $i keys = ", keys(businfo))
    # end

    # println("\n=== DEBUG: RAW COST FOR GEN 1 ===")
    # println(network["gen"]["1"]["cost"])

    # Extract OPB data
    gen_data, total_demand = opb_data_from_network(network)

    println("\nLoaded case: $case_name")
    println("Generators: $(length(gen_data))")
    println("Total Demand: $total_demand\n")

    # Build OPB model
    m = build_opb(gen_data, total_demand)

    # Select solver
    if solver_name == "highs"
        set_optimizer(m, HiGHS.Optimizer)
    elseif solver_name == "ipopt"
        set_optimizer(m, Ipopt.Optimizer)
    else
        error("Unknown solver: $solver_name")
    end

    # Solve
    optimize!(m)

    println("\n=== OPB Solution Results ===")
    println("Termination status: ", termination_status(m))
    println("Objective value: ", objective_value(m))
    println("Generator outputs (p_g):")
    for g in 1:length(gen_data)
        println("  Gen $g: ", value(m[:p][g]))
    end
end

main()

