"""
Shared utilities for DC power formulations and dataset exports.
"""

function normalize_dc_solution!(result::Dict, network::Dict)
    # Ensure downstream writers see the same keys as the AC pipeline expects.
    solution = get(result, "solution", nothing)
    solution === nothing && return result

    if haskey(solution, "bus")
        for (_, bus) in solution["bus"]
            bus["va"] = get(bus, "va", 0.0)
            bus["vm"] = get(bus, "vm", 1.0)
        end
    end

    if haskey(solution, "gen")
        for (_, gen) in solution["gen"]
            gen["pg"] = get(gen, "pg", 0.0)
            gen["qg"] = get(gen, "qg", 0.0)
        end
    end

    if haskey(solution, "branch")
        for (_, branch) in solution["branch"]
            branch["pf"] = get(branch, "pf", 0.0)
            branch["pt"] = get(branch, "pt", 0.0)
            branch["qf"] = get(branch, "qf", 0.0)
            branch["qt"] = get(branch, "qt", 0.0)
        end
    end

    return result
end

function ensure_result_metrics!(result::Dict; default_objective::Float64=0.0)
    result["objective"] = get(result, "objective", default_objective)
    result["solve_time"] = get(result, "solve_time", 0.0)
    return result
end

