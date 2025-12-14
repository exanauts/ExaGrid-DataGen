using PowerModels
using JuMP
using HiGHS
using ArgParse
using Pkg.Artifacts
using ArgParse: @add_arg_table
using PowerModels: build_ots, ref_add_on_off_va_bounds!   # import these explicitly

# ---------------- CLI PARSER ----------------
# Example command:
#   env -u LD_PRELOAD julia --project ots_gen.jl --instance=pglib_opf_case24_ieee_rts \
#       --write_output=true --output_file=results/ots_case24.h5
function parse_cli()
    settings = ArgParseSettings()
    @add_arg_table settings begin
        "--solver"
            help = "Solver to use: highs"
            arg_type = String
            default = "highs"
        "--instance"
            help = "PGLib instance name (without .m)"
            arg_type = String
            default = "pglib_opf_case24_ieee_rts"
        "--p_range"
            help = "Active power perturbation range a,b"
            arg_type = String
            default = "0.9,1.1"
        "--q_range"
            help = "Reactive range a,b"
            arg_type = String
            default = "1.0,1.0"
        "--seed"
            help = "Random seed"
            arg_type = Int
            default = 230
        "--write_output"
            help = "Write output to HDF5 file?"
            arg_type = Bool
            default = false
        "--output_file"
            help = "Output HDF5 filename"
            arg_type = String
            default = "test_ots_001.h5"
    end

    parsed = parse_args(settings)

    opts = Dict{Symbol,Any}()
    opts[:solver] = Symbol(lowercase(parsed["solver"]))
    opts[:instance] = parsed["instance"]

    pr = split(parsed["p_range"], ",")
    opts[:p_range] = (parse(Float64, pr[1]), parse(Float64, pr[2]))

    qr = split(parsed["q_range"], ",")
    opts[:q_range] = (parse(Float64, qr[1]), parse(Float64, qr[2]))

    opts[:seed] = parsed["seed"]
    opts[:write_output] = parsed["write_output"]
    opts[:output_file] = parsed["output_file"]

    return opts
end

opts = parse_cli()

# ---------------- Load network ----------------
pglib_root = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
case_path = joinpath(pglib_root, string(opts[:instance], ".m"))

include("perturbations.jl")
include("hdf5_writer.jl")
include("powerflow_utils.jl")

PowerModels.silence()
# ------------------------------------------------------------
# Remove quadratic terms from generator cost -> MILP (HiGHS-friendly)
# NOTE: This script produces linear-cost DC-OTS results; do not compare
#       against AC-OTS or quadratic-cost baselines without restoring cost terms.
# ------------------------------------------------------------
function linearize_gen_costs!(network)
    for (id, gen) in network["gen"]
        cost = gen["cost"]

        # Dict format: {"nc2","nc1","nc0"}
        if cost isa Dict
            cost["nc2"] = 0.0   # remove quadratic term

        # Vector format: [a, b, c] or [a, b] or [a]
        elseif cost isa Vector
            if length(cost) >= 1
                cost[1] = 0.0   # zero out quadratic coefficient
            end
        end
    end
end

network = PowerModels.parse_file(case_path)

# Make OTS MILP by removing quadratic cost
linearize_gen_costs!(network)

# (optional: you can drop your manual off_angmin/off_angmax patch now)

# ---------------- Perturb loads ----------------
perturb_loads_separate!(network, opts[:p_range], opts[:q_range], opts[:seed])

# ---------------- Build DC-OTS model ----------------
pm = instantiate_model(
    network,
    DCPPowerModel,
    build_ots;
    ref_extensions = [ref_add_on_off_va_bounds!],   # <<< THIS IS THE IMPORTANT PART
)

if opts[:solver] == :highs
    JuMP.set_optimizer(pm.model, HiGHS.Optimizer)
else
    error("Unsupported solver: $(opts[:solver])")
end

# ---------------- Solve ----------------
try
    result = optimize_model!(pm)

    ensure_result_metrics!(result)
    normalize_dc_solution!(result, network)

    println("ots $(opts[:solver]) [$(result["termination_status"])]: ",
            "$(opts[:instance]) objective=$(result["objective"])")

    total_power_slack = 0.0
    total_line_slack = 0.0

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
            total_power_slack,
            total_line_slack,
        )
        verify_hdf5_structure(opts[:output_file])
    end

catch err
    println("Error during OTS optimization of $(opts[:instance]) with solver $(opts[:solver])")
    showerror(stdout, err)
end
