using Pkg.Artifacts
using PowerModels
using JuMP
using Ipopt
using ArgParse

function parse_cli()
    settings = ArgParseSettings()
    @add_arg_table settings begin
        "--solver"
            help = "Solver to use: ipopt"
            arg_type = String
            default = "ipopt"
        "--instance"
            help = "PGLib instance name (without .m)"
            arg_type = String
            default = "pglib_opf_case24_ieee_rts"
        "--p_range"
            help = "Active power perturbation range as a,b"
            arg_type = String
            default = "0.9,1.1"
        "--q_range"
            help = "Reactive power perturbation range as a,b"
            arg_type = String
            default = "0.9,1.1"
        "--seed"
            help = "Random seed used in perturbations"
            arg_type = Int
            default = 230
        "--write_output"
            help = "Whether to write output to an HDF5 file"
            arg_type = Bool
            default = false
        "--output_file"
            help = "Output HDF5 filename when --write_output=true"
            arg_type = String
            default = "test_acpf_001.h5"
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

pglib_root = joinpath(artifact"PGLib_opf", "pglib-opf-23.07")
case_path = joinpath(pglib_root, string(opts[:instance], ".m"))

include("perturbations.jl")
include("hdf5_writer.jl")
include("powerflow_utils.jl")

PowerModels.silence()
network = PowerModels.parse_file(case_path)

perturb_loads_separate!(network, opts[:p_range], opts[:q_range], opts[:seed])

pm = instantiate_model(network, ACPPowerModel, PowerModels.build_pf)

if opts[:solver] == :ipopt
    JuMP.set_optimizer(pm.model, Ipopt.Optimizer)
else
    error("Unsupported solver for AC power flow: $(opts[:solver])")
end

try
    result = optimize_model!(pm)
    ensure_result_metrics!(result)

    println("acpf $(opts[:solver]) [$(result["termination_status"])]: $(opts[:instance])")

    if opts[:write_output]
        write_scenario_to_hdf5(opts[:output_file], network, result, 1, 0.0, 0.0)
        verify_hdf5_structure(opts[:output_file])
    end
catch err
    println("Error during AC power flow of $(opts[:instance]) with solver $(opts[:solver])")
    showerror(stdout, err, catch_backtrace())
end

