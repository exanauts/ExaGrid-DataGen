#!/usr/bin/env julia

# Example command:
#   env -u LD_PRELOAD julia --project tnep_gen.jl --instance=pglib_opf_case24_ieee_rts \
#       --line_derate=0.3 --construction_cost=4 --write_output=true \
#       --output_file=results/tnep_case24_derate0.3_cost4.h5

using Pkg.Artifacts
using PowerModels
using JuMP
using HiGHS
using ArgParse
using Random

include("hdf5_writer.jl")
include("powerflow_utils.jl")

# ------------------------------------------------------------
# 1) Load perturbation (active & reactive)
# NOTE: Applies independent multiplicative perturbations per bus; total demand
#       is not preserved, which is intentional for TNEP stress testing.
# ------------------------------------------------------------
function perturb_loads_separate!(network,
                                 p_range::Tuple{Float64,Float64},
                                 q_range::Tuple{Float64,Float64},
                                 seed::Int)
    Random.seed!(seed)

    total_before = 0.0
    for (_, load) in network["load"]
        total_before += load["pd"]
    end
    println("Total load BEFORE perturbation: ", total_before)

    for (_, load) in network["load"]
        load["pd"] *= rand(p_range[1]:0.0001:p_range[2])
        load["qd"] *= rand(q_range[1]:0.0001:q_range[2])
    end

    total_after = 0.0
    for (_, load) in network["load"]
        total_after += load["pd"]
    end
    println("Total load AFTER perturbation:  ", total_after)
end

# ------------------------------------------------------------
# 2) Derate existing lines (to create congestion)
# ------------------------------------------------------------
function derate_existing_lines!(network, line_derate::Float64)
    for (_, br) in network["branch"]
        for key in ("rate_a", "rate_b", "rate_c")
            if haskey(br, key) && br[key] > 0
                br[key] *= line_derate
            end
        end
    end
    println("All existing line ratings scaled by factor ", line_derate)
end

# ------------------------------------------------------------
# 3) Create ne_branch (parallel expansion candidates)
# NOTE: Models only duplicate capacity along existing corridors, not greenfield
#       right-of-way selection or alternative topologies.
# ------------------------------------------------------------
function add_parallel_ne_branches!(network; construction_cost::Float64 = 10.0)
    ne = Dict{String,Any}()
    idx = 1

    for (_, br) in network["branch"]
        newbr = deepcopy(br)
        newbr["index"] = idx
        # give each candidate a uniform construction cost
        newbr["construction_cost"] = construction_cost
        newbr["br_status"] = 1  # candidate is buildable
        ne[string(idx)] = newbr
        idx += 1
    end

    network["ne_branch"] = ne
    println("Added ", length(ne), " candidate expansion branches (parallel lines).")
end

# ------------------------------------------------------------
# 4) CLI parser
# ------------------------------------------------------------
function parse_cli()
    settings = ArgParseSettings()
    @add_arg_table settings begin
        "--solver"
            help = "MILP solver (use highs)"
            default = "highs"

        "--instance"
            help = "PGLib OPF case name (without .m)"
            default = "pglib_opf_case24_ieee_rts"

        "--p_range"
            help = "Active power perturbation range a,b"
            default = "1.05,1.15"

        "--q_range"
            help = "Reactive power perturbation range a,b"
            default = "1.0,1.0"

        "--seed"
            help = "Random seed for perturbations"
            arg_type = Int
            default = 230

        "--line_derate"
            help = "Scale factor on existing line ratings (e.g. 0.5)"
            default = "0.6"

        "--construction_cost"
            help = "Construction cost per candidate line (e.g. 10.0)"
            default = "10.0"
        "--write_output"
            help = "Write solved scenario to an HDF5 file"
            arg_type = Bool
            default = false
        "--output_file"
            help = "Output HDF5 filename"
            arg_type = String
            default = "test_tnep_001.h5"
    end

    args = parse_args(settings)

    return Dict(
        :solver            => Symbol(args["solver"]),
        :instance          => args["instance"],
        :p_range           => Tuple(parse.(Float64, split(args["p_range"], ","))),
        :q_range           => Tuple(parse.(Float64, split(args["q_range"], ","))),
        :seed              => args["seed"],
        :line_derate       => parse(Float64, args["line_derate"]),
        :construction_cost => parse(Float64, args["construction_cost"]),
        :write_output      => args["write_output"],
        :output_file       => args["output_file"]
    )
end

# ------------------------------------------------------------
# 5) MAIN
# ------------------------------------------------------------
function main()
    opts = parse_cli()

    casefile = joinpath(
        artifact"PGLib_opf",
        "pglib-opf-23.07",
        opts[:instance] * ".m"
    )

    PowerModels.silence()
    network = PowerModels.parse_file(casefile)

    println("Perturbing loads...")
    perturb_loads_separate!(network, opts[:p_range], opts[:q_range], opts[:seed])

    println("Derating existing lines...")
    derate_existing_lines!(network, opts[:line_derate])

    println("Adding parallel candidate expansion branches...")
    add_parallel_ne_branches!(network; construction_cost = opts[:construction_cost])

    println("Building TNEP model (PowerModels.build_tnep)...")
    pm = instantiate_model(
        network,
        DCPPowerModel,
        build_tnep;
        ref_extensions = [ref_add_on_off_va_bounds!, ref_add_ne_branch!]
    )

    if opts[:solver] != :highs
        error("For TNEP you should use a MILP solver like HiGHS. Use --solver=highs")
    end
    JuMP.set_optimizer(pm.model, HiGHS.Optimizer)

    println("Solving TNEP...")
    result = optimize_model!(pm)
    ensure_result_metrics!(result)
    normalize_dc_solution!(result, network)

    println("\n===== TNEP RESULTS =====")
    println("Status     : ", result["termination_status"])
    println("Objective  : ", result["objective"])

    # --------------------------------------------------------
    # 6) Inspect built expansions robustly
    # --------------------------------------------------------
    println("\nBuilt expansions (branch_ne = 1):")
    built_any = false

    for (n, nw_ref) in nws(pm)
        if !haskey(nw_ref, :ne_branch)
            continue
        end
        # JuMP decision variables for candidate lines in network n
        branch_ne_vars = var(pm, n, :branch_ne)

        for (i, br) in nw_ref[:ne_branch]
            x = value(branch_ne_vars[i])
            if x > 1e-6
                println("  nw=", n,
                        "  cand_id=", i,
                        "  buses=(", br["f_bus"], " → ", br["t_bus"], ")",
                        "  built=", x)
                built_any = true
            end
        end
    end

    if !built_any
        println("  (none built)")
        println("  To encourage expansions, try for example:")
        println("    --p_range=1.10,1.20      (higher loads)")
        println("    --line_derate=0.4        (tighter line limits)")
        println("    --construction_cost=3.0  (cheaper lines)")
    end

    if opts[:write_output]
        output_dir = dirname(opts[:output_file])
        if !isempty(output_dir) && output_dir != "."
            mkpath(output_dir)
        end
        write_scenario_to_hdf5(
            opts[:output_file],
            network,
            result,
            1,
            0.0,
            0.0,
        )
        verify_hdf5_structure(opts[:output_file])
    end

    println("\nDone.")
end

main()
