using HiGHS
using JuMP
using UnitCommitment
using JSON
using CodecZlib
using Dates
using Compat
using OrderedCollections
using ProgressMeter
import JSON.Serializations: CommonSerialization
import JSON: StructuralContext

const CS = CommonSerialization
const SC = StructuralContext

PROJECT_DIR = "/home/zeeshanmemon/data_gen/SCUC-datagen"
INPUT_DIR = joinpath(PROJECT_DIR, "processed")
# print(INPUT_DIR)
OUTPUT_DIR = joinpath(PROJECT_DIR, "")
TIME_LIMIT = 86400.0

# Custom JSON serializer for Infinity and NaN
struct InfinityNaNSerialization <: CS end

function JSON.show_json(io::SC, ::InfinityNaNSerialization, f::AbstractFloat)
    if isinf(f)
        if f > 0
            write(io, "Infinity")
        else
            write(io, "-Infinity")
        end
    elseif isnan(f)
        write(io, "NaN")
    else
        Base.print(io, f)
    end
end

function json_with_infinity(args...; kwargs...)
    b = IOBuffer()
    JSON.show_json(b, InfinityNaNSerialization(), args...; kwargs...)
    String(take!(b))
end

function get_dataset_id(input_file)
    folder = splitpath(dirname(input_file))[end]
    base = replace(basename(input_file), "-" => "_")
    dataset_id = "scuc_" * folder * "_" * replace(base, ".json.gz" => "")
    return dataset_id
end

function get_output_file(dataset_id)
    return joinpath(OUTPUT_DIR, "solutions", dataset_id * ".json.gz")
end

function build_and_solve_uc_model(input_file, time_limit; verbose=true)
    instance = UnitCommitment.read(input_file)

    # For benchmarking and data generation purposes, we solve the UC problem without N-1 contingencies
    empty!(instance.scenarios[1].contingencies)
    empty!(instance.scenarios[1].contingencies_by_name)

    model = UnitCommitment.build_model(
        instance = instance,
        optimizer = HiGHS.Optimizer,
    )
    if !verbose
        set_silent(model)
    end
    
    UnitCommitment.optimize!(
        model, 
        UnitCommitment.XavQiuWanThi2019.Method(
            time_limit = time_limit,
        )
    )
    return model, UnitCommitment.solution(model)
end

function read_json_data(input_file)
    open(input_file, "r") do file
        stream = GzipDecompressorStream(file)
        JSON.parse(read(stream, String))
    end
end

function build_metadata(data, model, dataset_id, time_limit)
    OrderedDict(
        "dataset_id" => dataset_id,
        "application" => "unit commitment",
        "created" => Dates.now(),
        "schema_version" => "0.1",
        "UnitCommitment.jl" => OrderedDict(
            "version" => pkgversion(UnitCommitment),
            "solver" => "HiGHS",
            "solver_version" => string(Highs_versionMajor()) * "." * string(Highs_versionMinor()) * "." * string(Highs_versionPatch()),
            "solver_options" => OrderedDict(
                "time limit" => time_limit,
            ),
            "source" => data["SOURCE"],
            "parameters" => data["Parameters"],
            "solution_status" => termination_status(model),
            "objective_value" => objective_bound(model),
            "optimality_gap" => relative_gap(model),
        ),
    )
end

function build_graph_nodes(data)
    nodes = OrderedDict(
        "generator" => OrderedDict(),
        "storage" => OrderedDict(),
        "price-sensitive load" => OrderedDict(),
        "bus" => OrderedDict(),
        "reserve" => OrderedDict(),
    )
    # Generators
    for (k,v) in data["Generators"]
        gen_type = get(v, "Type", "generator")
        node = OrderedDict(
            "bus_id" => v["Bus"],
            "type" => gen_type,
            "physical" => OrderedDict(),
            "economic" => OrderedDict(),
            "operational" => OrderedDict(),
        )
        if gen_type == "Profiled"
            node["physical"]["Minimum power (MW)"] = get(v, "Minimum power (MW)", 0.0)
            node["physical"]["Maximum power (MW)"] = v["Maximum power (MW)"]
            node["economic"]["Costs (\$/MW)"] = v["Costs (\$/MW)"]
        else
            node["physical"]["Ramp up limit (MW)"] = get(v, "Ramp up limit (MW)", Inf)
            node["physical"]["Ramp down limit (MW)"] = get(v, "Ramp down limit (MW)", Inf)
            node["physical"]["Startup limit (MW)"] = get(v, "Startup limit (MW)", Inf)
            node["physical"]["Shutdown limit (MW)"] = get(v, "Shutdown limit (MW)", Inf)
            node["physical"]["Minimum uptime (h)"] = get(v, "Minimum uptime (h)", 1)
            node["physical"]["Minimum downtime (h)"] = get(v, "Minimum downtime (h)", 1)
            node["physical"]["Reserve eligibility"] = get(v, "Reserve eligibility", [])
            node["physical"]["Initial status (h)"] = v["Initial status (h)"]
            node["physical"]["Initial power (MW)"] = v["Initial power (MW)"]
            node["economic"]["Production cost curve (MW)"] = v["Production cost curve (MW)"]
            node["economic"]["Production cost curve (\$)"] = v["Production cost curve (\$)"]
            node["economic"]["Startup costs (\$)"] = get(v, "Startup costs (\$)", [0.0])
            node["economic"]["Startup delays (h)"] = get(v, "Startup delays (h)", [1])
            node["operational"]["Must run?"] = get(v, "Must run?", false)
            node["operational"]["Commitment status"] = get(v, "Commitment status", nothing)
        end
        nodes["generator"][k] = node
    end
    # Storage
    if haskey(data, "Storage")
        for (k, v) in data["Storage"]
            nodes["storage"][k] = OrderedDict(
                "bus_id" => v["Bus"],
                "physical" => OrderedDict(
                    "Minimum level (MWh)" => get(v, "Minimum level (MWh)", 0.0),
                    "Maximum level (MWh)" => v["Maximum level (MWh)"],
                    "Minimum charge rate (MW)" => get(v, "Minimum charge rate (MW)", 0.0),
                    "Maximum charge rate (MW)" => v["Maximum charge rate (MW)"],
                    "Minimum discharge rate (MW)" => get(v, "Minimum discharge rate (MW)", 0.0),
                    "Maximum discharge rate (MW)" => v["Maximum discharge rate (MW)"],
                    "Initial level (MWh)" => get(v, "Initial level (MWh)", 0.0),
                    "Last period minimum level (MWh)" => get(v, "Last period minimum level (MWh)", v["Minimum level (MWh)"]),
                    "Last period maximum level (MWh)" => get(v, "Last period maximum level (MWh)", v["Maximum level (MWh)"]),
                ),
                "economic" => OrderedDict(
                    "Charge cost (\$/MW)" => v["Charge cost (\$/MW)"],
                    "Discharge cost (\$/MW)" => v["Discharge cost (\$/MW)"],
                ),
                "operational" => OrderedDict(
                    "Allow simultaneous charging and discharging" => get(v, "Allow simultaneous charging and discharging", true),
                    "Charge efficiency" => get(v, "Charge efficiency", 1.0),
                    "Discharge efficiency" => get(v, "Discharge efficiency", 1.0),
                    "Loss factor" => get(v, "Loss factor", 0.0),
                ),
            )
        end
    end
    # Price-sensitive loads
    if haskey(data, "Price-sensitive loads")
        for (k, v) in data["price-sensitive load"]
            nodes["price-sensitive load"][k] = OrderedDict(
                "bus_id" => v["Bus"],
                "economic" => OrderedDict(
                    "Revenue (\$/MW)" => v["Revenue (\$/MW)"],
                    "Demand (MW)" => v["Demand (MW)"],
                ),
            )
        end
    end
    # Buses
    for (k,v) in data["Buses"]
        bus_type = get(v, "Type", "bus")
        nodes["bus"][k] = OrderedDict(
            "Type" => bus_type,
            "temporal" => OrderedDict("Load (MW)" => v["Load (MW)"]),
            "operational" => OrderedDict(),
        )
    end
    # Reserves
    for (k,v) in data["Reserves"]
        nodes["reserve"][k] = OrderedDict(
            "type" => v["Type"],
            "operational" => OrderedDict(
                "Amount (MW)" => v["Amount (MW)"],
                "Shortfall penalty (\$/MW)" => get(v, "Shortfall penalty (\$/MW)", -1),
            ),
        )
    end
    return nodes
end

function build_graph_edges(data)
    edges = OrderedDict(
        "transmission line" => OrderedDict(),
    )
    for (k,v) in data["Transmission lines"]
        edges["transmission line"][k] = OrderedDict(
            "from" => v["Source bus"], 
            "to" => v["Target bus"], 
            "physical" => OrderedDict(
                "Reactance (ohms)" => v["Reactance (ohms)"],
                "Susceptance (S)" => v["Susceptance (S)"],
                "Normal flow limit (MW)" => get(v, "Normal flow limit (MW)", Inf),
                "Emergency flow limit (MW)" => get(v, "Emergency flow limit (MW)", Inf),
                "Flow limit penalty (\$/MW)" => get(v, "Flow limit penalty (\$/MW)", 5000.0),
            ),
            "operational" => OrderedDict(),
        )
    end
    return edges
end

function add_solution_to_graph!(output_data, solution)
    # Generators
    for (k,v) in output_data["graph"]["nodes"]["generator"]
        for k2 in ["Thermal production (MW)", "Thermal production cost (\$)", "Startup cost (\$)", "Is on", "Switch on", "Switch off", "Profiled production (MW)", "Profiled production cost (\$)"]
            if haskey(solution, k2)
                v["operational"][k2] = solution[k2][k]
            end
        end
    end
    # Storage
    for (k,v) in output_data["graph"]["nodes"]["storage"]
        for k2 in ["Storage level (MWh)", "Is charging", "Storage charging rates (MW)", "Storage charging cost (\$)", "Is discharging", "Storage discharging rates (MW)", "Storage discharging cost (\$)"]
            if haskey(solution, k2)
                v["operational"][k2] = solution[k2][k]
            end
        end
    end
    # Price-sensitive loads
    for (k,v) in output_data["graph"]["nodes"]["price-sensitive load"]
        v["operational"]["Price-sensitive loads (MW)"] = solution["Price-sensitive loads (MW)"][k]
    end
    # Buses
    for (k,v) in output_data["graph"]["nodes"]["bus"]
        for k2 in ["Net injection (MW)", "Load curtail (MW)"]
            v["operational"][k2] = solution[k2][k]
        end
    end
    # Transmission lines
    for (k,v) in output_data["graph"]["edges"]["transmission line"]
        v["operational"]["Line overflow (MW)"] = solution["Line overflow (MW)"][k]
    end
    # Reserves
    for (k,v) in output_data["graph"]["nodes"]["reserve"]
        for k2 in ["Spinning reserve (MW)", "Spinning reserve shortfall (MW)", "Up-flexiramp (MW)", "Up-flexiramp shortfall (MW)", "Down-flexiramp (MW)", "Down-flexiramp shortfall (MW)"]
            if haskey(solution, k2)
                v["operational"][k2] = get(solution[k2], k, Dict())
            end
        end
    end
end

function write_output(output_file, output_data)
    open(output_file, "w") do file
        stream = GzipCompressorStream(file)
        write(stream, json_with_infinity(output_data, indent=2))
        close(stream)
    end
end

function get_input_files()
    input_files = String[]
    for case_dir in readdir(INPUT_DIR)
        case_path = joinpath(INPUT_DIR, case_dir)
        if isdir(case_path)
            append!(input_files, filter(f -> endswith(f, ".json.gz"), 
                map(f -> joinpath(case_path, f), readdir(case_path))))
        end
    end
    return input_files
end

function get_files_to_process()
    input_files = get_input_files()
    to_process = String[]
    
    # Create output directory if it doesn't exist
    mkpath(OUTPUT_DIR)
    
    n_total = length(input_files)
    n_existing = 0
    
    for input_file in input_files
        dataset_id = get_dataset_id(input_file)
        output_file = get_output_file(dataset_id)
        if !isfile(output_file)
            push!(to_process, input_file)
        else
            n_existing += 1
        end
    end
    
    println("Found $n_total total input files")
    println("$n_existing files already have solutions")
    println("$(length(to_process)) files need to be processed")
    
    return to_process
end

function process_single_file(input_file; verbose=true)
    try
        dataset_id = get_dataset_id(input_file)
        output_file = get_output_file(dataset_id)
        
        model, solution = build_and_solve_uc_model(input_file, TIME_LIMIT; verbose=verbose)
        data = read_json_data(input_file)
        metadata = build_metadata(data, model, dataset_id, TIME_LIMIT)
        nodes = build_graph_nodes(data)
        edges = build_graph_edges(data)
        output_data = OrderedDict("metadata" => metadata, "graph" => OrderedDict("nodes" => nodes, "edges" => edges))
        add_solution_to_graph!(output_data, solution)
        write_output(output_file, output_data)
        return true
    catch e
        println("Error processing file $input_file: ", e)
        return false
    end
end

# Main run
function main()
    if length(ARGS) > 0
        # If input file is provided, process just that file
        INPUT_FILE = ARGS[1]
        if !isfile(INPUT_FILE)
            error("Input file does not exist: $INPUT_FILE")
            exit(1)
        end
        process_single_file(INPUT_FILE)
    else
        # Otherwise process all files using multi-threading
        files_to_process = get_files_to_process()
        
        if isempty(files_to_process)
            println("No files to process")
            return
        end
        
        n_files = length(files_to_process)
        println("Processing $n_files files using $(Threads.nthreads()) threads...")
        
        results = fill(false, n_files)
        progress = Progress(n_files)
        
        # Use threading for parallel processing
        Threads.@threads for i in 1:n_files
            results[i] = process_single_file(files_to_process[i]; verbose=false)
            next!(progress)
        end
        
        successful = count(results)
        println("\nCompleted processing. Successfully processed $successful out of $n_files files.")
    end
end

main()
