using Pkg.Artifacts
using PowerModels
# using Ipopt
using JuMP
using MadNLPHSL, MadNLPGPU

pglib_path = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")

using MadNLP
using MadNLPHSL

include("acopf_model.jl")
include("perturbations.jl")
include("hdf5_writer.jl")

# Solver selection: default is :madnlp. Override with ARGS[1] or ENV["OPF_SOLVER"].
function _choose_solver(default::Symbol=:madnlp)
    arg = isempty(ARGS) ? get(ENV, "OPF_SOLVER", "") : ARGS[1]
    if arg == "" || arg === nothing
        return default
    end
    s = Symbol(lowercase(arg))
    if s in (:madnlp, :madnlpgpu, :ipopt)
        return s
    end
    error("Unknown solver: $arg. Allowed values: ipopt, madnlp")
end

const SOLVER = _choose_solver(:madnlp)

network = PowerModels.parse_file(joinpath(pglib_path, "pglib_opf_case24_ieee_rts.m"))
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
result = optimize_model!(pm)

println("Objective value: $(result["objective"])")

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

output_file = "test_scenario_001.h5"
write_scenario_to_hdf5(output_file, network, result, 1, total_power_slack, total_line_slack)

verify_hdf5_structure(output_file)



