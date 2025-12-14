###Alternate script for OPB solver 
using PowerModels
using JuMP
using HiGHS
using Pkg.Artifacts

function main()
    if length(ARGS) < 2
        println("Usage: julia opb_pm.jl <pglib_case> <solver: highs|ipopt>")
        return
    end

    case_name = ARGS[1]
    solver_name = ARGS[2]

    # PGLib path
    pglib_root = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
    case_path = joinpath(pglib_root, case_name * ".m")

    # Choose solver
    optimizer =
        solver_name == "highs" ? HiGHS.Optimizer :
        solver_name == "ipopt" ? Ipopt.Optimizer :
        error("Unknown solver")

    println("Solving OPB using PowerModels…")

    result = solve_opb(case_path, NFAPowerModel, optimizer)

    println("\n=== PowerModels OPB Result ===")
    println("Status: ", result["termination_status"])
    println("Objective: ", result["objective"])

    println("\nGenerator Outputs:")
    for (id, gdata) in result["solution"]["gen"]
        println(" Gen $id => Pg = ", gdata["pg"])
    end
end

main()
