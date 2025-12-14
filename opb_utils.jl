using Random

# ------------------------------------------------------------
# Clean, self-contained load perturbation function
# ------------------------------------------------------------
function perturb_loads!(network, p_range::Tuple{Float64,Float64}, seed::Int)
    rng = Random.MersenneTwister(seed)

    lo, hi = p_range

    for (_id, load) in network["load"]
        scale = lo + (hi - lo) * rand(rng)   # simple uniform sampling
        load["pd"] *= scale
    end
end

function augment_opb_solution!(result::Dict, network::Dict)
    solution = get!(result, "solution", Dict{String,Any}())

    if !haskey(solution, "bus")
        bus_solution = Dict{String,Dict{String,Float64}}()
        for (bus_id, bus_data) in network["bus"]
            bus_solution[bus_id] = Dict(
                "va" => get(bus_data, "va", 0.0),
                "vm" => get(bus_data, "vm", 1.0)
            )
        end
        solution["bus"] = bus_solution
    end

    if !haskey(solution, "gen")
        gen_solution = Dict{String,Dict{String,Float64}}()
        for (gen_id, gen_data) in network["gen"]
            gen_solution[gen_id] = Dict(
                "pg" => get(gen_data, "pg", 0.0),
                "qg" => get(gen_data, "qg", 0.0)
            )
        end
        solution["gen"] = gen_solution
    end

    branch_solution = get!(solution, "branch", Dict{String,Dict{String,Float64}}())
    for (branch_id, _) in network["branch"]
        branch_sol = get!(branch_solution, branch_id, Dict{String,Float64}())
        branch_sol["pf"] = get(branch_sol, "pf", 0.0)
        branch_sol["qf"] = get(branch_sol, "qf", 0.0)
        branch_sol["pt"] = get(branch_sol, "pt", 0.0)
        branch_sol["qt"] = get(branch_sol, "qt", 0.0)
    end

    if !haskey(result, "objective")
        result["objective"] = NaN
    end
    if !haskey(result, "solve_time")
        result["solve_time"] = NaN
    end
    if !haskey(result, "termination_status")
        result["termination_status"] = "UNKNOWN"
    end

    return result
end

