using Pkg.Artifacts
using PowerModels
using Ipopt
using JuMP
using MadNLP, MadNLPHSL#, MadNLPGPU
using ArgParse

# Parse CLI options at top-level so we can call addprocs with the requested count
function parse_cli()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--solver"
            help = "Solver to use: ipopt, madnlp"
            arg_type = String
            default = "madnlp"
        "--instance"
            help = "PGLib instance name (without .m)"
            arg_type = String
            default = "pglib_opf_case24_ieee_rts"
        "--write_output"
            help = "Whether to write output to HDF5 file"
            arg_type = Bool
            default = false
    end

    parsed = parse_args(s)

    opts = Dict{Symbol,Any}()
    opts[:solver] = Symbol(lowercase(parsed["solver"]))
    opts[:instance] = parsed["instance"]
    opts[:write_output] = parsed["write_output"]

    return opts
end

opts = parse_cli()

pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")

include("acopf_model.jl")
include("perturbations.jl")
include("hdf5_writer.jl")

const SOLVER = opts[:solver]
const INSTANCE = opts[:instance]

PowerModels.silence()
network = PowerModels.parse_file(joinpath(pglib_path, "$(INSTANCE).m"))
perturb_loads_separate!(network, (0.9, 1.1), (0.9, 1.1), 230)
power_balance_relaxation = false
line_limit_relaxation = false
pm = instantiate_model(network, ACPPowerModel, 
    pm -> build_opf_with_slacks(pm,
        power_balance_relaxation=power_balance_relaxation,
        line_limit_relaxation=line_limit_relaxation
    )
)

if SOLVER == :madnlp
    JuMP.set_optimizer(pm.model, ()->MadNLP.Optimizer(linear_solver=Ma27Solver, print_level=MadNLP.INFO))
elseif SOLVER == :madnlpgpu
    JuMP.set_optimizer(pm.model, ()->MadNLP.Optimizer(linear_solver=CUDSSSolver, print_level=MadNLP.INFO))
elseif SOLVER == :ipopt
    JuMP.set_optimizer(pm.model, ()->Ipopt.Optimizer())
else
    error("Unsupported solver: $SOLVER")
end

try
    result = optimize_model!(pm)

    println("$SOLVER [$(result["termination_status"])]: $INSTANCE with objective value $(result["objective"])")

    total_power_slack = 0.0
    total_line_slack = 0.0 

    if power_balance_relaxation == true
        for (i, bus) in result["solution"]["bus"]
            if haskey(bus, "p_slack_pos")
                total_power_slack += bus["p_slack_pos"] + bus["p_slack_neg"] + bus["q_slack_pos"] + bus["q_slack_neg"]
            end
        end
        println("Total power balance slack: $(total_power_slack)")
    end
    
    if line_limit_relaxation == true
        for (i, branch) in result["solution"]["branch"]
            if haskey(branch, "s_slack") && branch["s_slack"] > 1e-6
                total_line_slack += branch["s_slack"]
            end
        end
        println("Total line slack: $(total_line_slack) MVA")
    end

    if opts[:write_output]
        output_file = "test_scenario_001.h5"
        write_scenario_to_hdf5(output_file, network, result, 1, total_power_slack, total_line_slack)
        verify_hdf5_structure(output_file)
    end
catch e
    println("Error during optimization: $INSTANCE with solver $SOLVER")
    # exit(1)
end

