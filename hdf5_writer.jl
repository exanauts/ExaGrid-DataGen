using HDF5
using PowerModels

function extract_grid_data(network::Dict)
    bus_ids = sort(parse.(Int, keys(network["bus"])))
    gen_ids = sort(parse.(Int, keys(network["gen"])))
    branch_ids = sort(parse.(Int, keys(network["branch"])))
    load_ids = sort(parse.(Int, keys(network["load"])))
    shunt_ids = haskey(network, "shunt") ? sort(parse.(Int, keys(network["shunt"]))) : Int[]
    
    # Bus features: [vmin, vmax, zone, area, pd_total]
    bus_features = []
    for bus_id in bus_ids
        bus = network["bus"][string(bus_id)]
        push!(bus_features, [
            Float32(bus["vmin"]),
            Float32(bus["vmax"]),
            Float32(get(bus, "zone", 0)),
            Float32(get(bus, "area", 0)),
            Float32(bus["bus_type"])
        ])
    end
    bus_matrix = collect(hcat(bus_features...)')
    
    # Generator features: [pmax, pmin, qmax, qmin, cost_c2, cost_c1, cost_c0, vg, mbase, status, pg_init]
    gen_features = []
    for gen_id in gen_ids
        gen = network["gen"][string(gen_id)]
        cost = gen["cost"]
        c2 = length(cost) >= 3 ? cost[1] : 0.0
        c1 = length(cost) >= 2 ? cost[end-1] : 0.0
        c0 = length(cost) >= 1 ? cost[end] : 0.0
        
        push!(gen_features, [
            Float32(gen["pmax"]),
            Float32(gen["pmin"]),
            Float32(gen["qmax"]),
            Float32(gen["qmin"]),
            Float32(c2),
            Float32(c1),
            Float32(c0),
            Float32(get(gen, "vg", 1.0)),
            Float32(get(gen, "mbase", 100.0)),
            Float32(gen["gen_status"]),
        ])
    end
    gen_matrix = collect(hcat(gen_features...)')
    
    # Load features: [pd, qd]
    load_features = []
    for load_id in load_ids
        load = network["load"][string(load_id)]
        push!(load_features, [
            Float32(load["pd"]),
            Float32(load["qd"])
        ])
    end
    load_matrix = collect(hcat(load_features...)')
    
    # Shunt features: [gs, bs]
    shunt_matrix = zeros(Float32, 0, 2)
    if !isempty(shunt_ids)
        shunt_features = []
        for shunt_id in shunt_ids
            shunt = network["shunt"][string(shunt_id)]
            push!(shunt_features, [
                Float32(shunt["gs"]),
                Float32(shunt["bs"])
            ])
        end
        shunt_matrix = collect(hcat(shunt_features...)')
    end
    
    ac_line_from = Int32[]
    ac_line_to = Int32[]
    ac_line_features = []
    
    transformer_from = Int32[]
    transformer_to = Int32[]
    transformer_features = []
    
    for branch_id in branch_ids
        branch = network["branch"][string(branch_id)]
        from_bus = Int32(branch["f_bus"]) - 1  # 0-indexed
        to_bus = Int32(branch["t_bus"]) - 1
        
        is_transformer = (branch["tap"] != 1.0) || (branch["shift"] != 0.0)
        
        features = [
            Float32(branch["angmin"]),
            Float32(branch["angmax"]),
            Float32(branch["br_r"]),
            Float32(branch["br_x"]),
            Float32(branch["b_fr"]),
            Float32(branch["b_to"]),
            Float32(branch["rate_a"]),
            Float32(get(branch, "rate_b", branch["rate_a"])),
            Float32(get(branch, "rate_c", branch["rate_a"])),
            Float32(branch["br_status"])
        ]
        
        if is_transformer
            push!(transformer_from, from_bus)
            push!(transformer_to, to_bus)
            push!(transformer_features, vcat(features, [
                Float32(branch["tap"]),
                Float32(branch["shift"])
            ]))
        else
            push!(ac_line_from, from_bus)
            push!(ac_line_to, to_bus)
            push!(ac_line_features, features)
        end
    end
    
    ac_line_matrix = isempty(ac_line_features) ? zeros(Float32, 0, 9) : collect(hcat(ac_line_features...)')
    transformer_matrix = isempty(transformer_features) ? zeros(Float32, 0, 11) : collect(hcat(transformer_features...)')
    
    gen_link_from = Int32[]
    gen_link_to = Int32[]
    for gen_id in gen_ids
        gen = network["gen"][string(gen_id)]
        push!(gen_link_from, Int32(gen_id - 1))  
        push!(gen_link_to, Int32(gen["gen_bus"] - 1)) 
    end
    
    load_link_from = Int32[]
    load_link_to = Int32[]
    for load_id in load_ids
        load = network["load"][string(load_id)]
        push!(load_link_from, Int32(load_id - 1))  
        push!(load_link_to, Int32(load["load_bus"] - 1))
    end
    
    shunt_link_from = Int32[]
    shunt_link_to = Int32[]
    if !isempty(shunt_ids)
        for shunt_id in shunt_ids
            shunt = network["shunt"][string(shunt_id)]
            push!(shunt_link_from, Int32(shunt_id - 1))
            push!(shunt_link_to, Int32(shunt["shunt_bus"] - 1))
        end
    end
    
    return Dict(
        "bus" => bus_matrix,
        "generator" => gen_matrix,
        "load" => load_matrix,
        "shunt" => shunt_matrix,
        "ac_line_from" => ac_line_from,
        "ac_line_to" => ac_line_to,
        "ac_line_features" => ac_line_matrix,
        "transformer_from" => transformer_from,
        "transformer_to" => transformer_to,
        "transformer_features" => transformer_matrix,
        "generator_link_from" => gen_link_from,
        "generator_link_to" => gen_link_to,
        "load_link_from" => load_link_from,
        "load_link_to" => load_link_to,
        "shunt_link_from" => shunt_link_from,
        "shunt_link_to" => shunt_link_to
    )
end

function extract_solution_data(result::Dict, network::Dict)
    solution = result["solution"]
    
    bus_ids = sort(parse.(Int, keys(solution["bus"])))
    gen_ids = sort(parse.(Int, keys(solution["gen"])))
    branch_ids = sort(parse.(Int, keys(solution["branch"])))
    
    # Bus solution: [va, vm]
    bus_solution = []
    for bus_id in bus_ids
        bus = solution["bus"][string(bus_id)]
        push!(bus_solution, [
            Float32(bus["va"]),
            Float32(bus["vm"])
        ])
    end
    bus_sol_matrix = collect(hcat(bus_solution...)')
    
    # Generator solution: [pg, qg]
    gen_solution = []
    for gen_id in gen_ids
        gen = solution["gen"][string(gen_id)]
        push!(gen_solution, [
            Float32(gen["pg"]),
            Float32(gen["qg"])
        ])
    end
    gen_sol_matrix = collect(hcat(gen_solution...)')
    
    # Branch solution: [pf, qf, pt, qt]
    ac_line_solution = []
    transformer_solution = []
    
    for branch_id in branch_ids
        branch_sol = solution["branch"][string(branch_id)]
        branch_info = network["branch"][string(branch_id)]

        features = [
            Float32(branch_sol["pf"]),
            Float32(branch_sol["qf"]),
            Float32(branch_sol["pt"]),
            Float32(branch_sol["qt"])
        ]

        is_transformer = (branch_info["tap"] != 1.0) || (branch_info["shift"] != 0.0)
        
        if is_transformer
            push!(transformer_solution, features)
        else
            push!(ac_line_solution, features)
        end
    end
    
    ac_line_sol_matrix = isempty(ac_line_solution) ? zeros(Float32, 0, 4) : collect(hcat(ac_line_solution...)')
    transformer_sol_matrix = isempty(transformer_solution) ? zeros(Float32, 0, 4) : collect(hcat(transformer_solution...)')
    
    return Dict(
        "bus" => bus_sol_matrix,
        "generator" => gen_sol_matrix,
        "ac_line_features" => ac_line_sol_matrix,
        "transformer_features" => transformer_sol_matrix,
        "objective" => Float32(result["objective"]),
        "solve_time" => Float32(result["solve_time"]),
        "status" => string(result["termination_status"])
    )
end

function write_scenario_to_hdf5(filename::String, network::Dict, result::Dict, 
                                scenario_id::Int, total_power_slack::Float64, 
                                total_line_slack::Float64)
    
    grid_data = extract_grid_data(network)
    solution_data = extract_solution_data(result, network)
    
    h5open(filename, "w") do file
        # ===== GRID GROUP =====
        grid_grp = create_group(file, "grid")
        
        # Grid/Nodes (bus, generator, load, and shunt)
        nodes_grp = create_group(grid_grp, "nodes")
        
        # Bus dataset
        bus_chunk = (min(1024, size(grid_data["bus"], 1)), size(grid_data["bus"], 2))
        create_dataset(nodes_grp, "bus", Float32, size(grid_data["bus"]),
                      chunk=bus_chunk, compress=6, shuffle=())
        nodes_grp["bus"][:, :] = grid_data["bus"]
        
        # Generator dataset
        gen_chunk = (min(1024, size(grid_data["generator"], 1)), size(grid_data["generator"], 2))
        create_dataset(nodes_grp, "generator", Float32, size(grid_data["generator"]),
                      chunk=gen_chunk, compress=6, shuffle=())
        nodes_grp["generator"][:, :] = grid_data["generator"]
        
        # Load dataset
        load_chunk = (min(1024, size(grid_data["load"], 1)), size(grid_data["load"], 2))
        create_dataset(nodes_grp, "load", Float32, size(grid_data["load"]),
                      chunk=load_chunk, compress=6, shuffle=())
        nodes_grp["load"][:, :] = grid_data["load"]
        
        # Shunt dataset (if exists)
        if size(grid_data["shunt"], 1) > 0
            shunt_chunk = (min(1024, size(grid_data["shunt"], 1)), size(grid_data["shunt"], 2))
            create_dataset(nodes_grp, "shunt", Float32, size(grid_data["shunt"]),
                          chunk=shunt_chunk, compress=6, shuffle=())
            nodes_grp["shunt"][:, :] = grid_data["shunt"]
        end
        
        # Grid/Context
        context_grp = create_group(grid_grp, "context")
        baseMVA_data = Float32[network["baseMVA"]]
        context_grp["baseMVA"] = reshape(baseMVA_data, 1, 1, 1)
        
        # Grid/Edges (ac_line, transformer, and all links)
        edges_grp = create_group(grid_grp, "edges")
        
        # AC line
        ac_line_grp = create_group(edges_grp, "ac_line")
        
        ac_line_sender_chunk = (min(1024, length(grid_data["ac_line_from"])),)
        create_dataset(ac_line_grp, "senders", Int32, (length(grid_data["ac_line_from"]),),
                      chunk=ac_line_sender_chunk, compress=6, shuffle=())
        ac_line_grp["senders"][:] = grid_data["ac_line_from"]
        
        ac_line_receiver_chunk = (min(1024, length(grid_data["ac_line_to"])),)
        create_dataset(ac_line_grp, "receivers", Int32, (length(grid_data["ac_line_to"]),),
                      chunk=ac_line_receiver_chunk, compress=6, shuffle=())
        ac_line_grp["receivers"][:] = grid_data["ac_line_to"]
        
        if size(grid_data["ac_line_features"], 1) > 0
            ac_line_feat_chunk = (min(1024, size(grid_data["ac_line_features"], 1)), 
                                  size(grid_data["ac_line_features"], 2))
            create_dataset(ac_line_grp, "features", Float32, size(grid_data["ac_line_features"]),
                          chunk=ac_line_feat_chunk, compress=6, shuffle=())
            ac_line_grp["features"][:, :] = grid_data["ac_line_features"]
        else
            ac_line_grp["features"] = grid_data["ac_line_features"]
        end
        
        # Transformer
        transformer_grp = create_group(edges_grp, "transformer")
        
        if !isempty(grid_data["transformer_from"])
            transformer_sender_chunk = (min(1024, length(grid_data["transformer_from"])),)
            create_dataset(transformer_grp, "senders", Int32, (length(grid_data["transformer_from"]),),
                        chunk=transformer_sender_chunk, compress=6, shuffle=())
            transformer_grp["senders"][:] = grid_data["transformer_from"]
            
            transformer_receiver_chunk = (min(1024, length(grid_data["transformer_to"])),)
            create_dataset(transformer_grp, "receivers", Int32, (length(grid_data["transformer_to"]),),
                        chunk=transformer_receiver_chunk, compress=6, shuffle=())
            transformer_grp["receivers"][:] = grid_data["transformer_to"]
            
            transformer_feat_chunk = (min(1024, size(grid_data["transformer_features"], 1)), 
                                    size(grid_data["transformer_features"], 2))
            create_dataset(transformer_grp, "features", Float32, size(grid_data["transformer_features"]),
                        chunk=transformer_feat_chunk, compress=6, shuffle=())
            transformer_grp["features"][:, :] = grid_data["transformer_features"]
        else
            transformer_grp["senders"] = grid_data["transformer_from"]
            transformer_grp["receivers"] = grid_data["transformer_to"]
            transformer_grp["features"] = grid_data["transformer_features"]
        end
        
        # Generator link
        gen_link_grp = create_group(edges_grp, "generator_link")
        gen_link_sender_chunk = (min(1024, length(grid_data["generator_link_from"])),)
        create_dataset(gen_link_grp, "senders", Int32, (length(grid_data["generator_link_from"]),),
                      chunk=gen_link_sender_chunk, compress=6, shuffle=())
        gen_link_grp["senders"][:] = grid_data["generator_link_from"]
        
        gen_link_receiver_chunk = (min(1024, length(grid_data["generator_link_to"])),)
        create_dataset(gen_link_grp, "receivers", Int32, (length(grid_data["generator_link_to"]),),
                      chunk=gen_link_receiver_chunk, compress=6, shuffle=())
        gen_link_grp["receivers"][:] = grid_data["generator_link_to"]
        
        # Load link 
        load_link_grp = create_group(edges_grp, "load_link")
        load_link_sender_chunk = (min(1024, length(grid_data["load_link_from"])),)
        create_dataset(load_link_grp, "senders", Int32, (length(grid_data["load_link_from"]),),
                      chunk=load_link_sender_chunk, compress=6, shuffle=())
        load_link_grp["senders"][:] = grid_data["load_link_from"]
        
        load_link_receiver_chunk = (min(1024, length(grid_data["load_link_to"])),)
        create_dataset(load_link_grp, "receivers", Int32, (length(grid_data["load_link_to"]),),
                      chunk=load_link_receiver_chunk, compress=6, shuffle=())
        load_link_grp["receivers"][:] = grid_data["load_link_to"]
        
        # Shunt link (if exists)
        if !isempty(grid_data["shunt_link_from"])
            shunt_link_grp = create_group(edges_grp, "shunt_link")
            shunt_link_sender_chunk = (min(1024, length(grid_data["shunt_link_from"])),)
            create_dataset(shunt_link_grp, "senders", Int32, (length(grid_data["shunt_link_from"]),),
                          chunk=shunt_link_sender_chunk, compress=6, shuffle=())
            shunt_link_grp["senders"][:] = grid_data["shunt_link_from"]
            
            shunt_link_receiver_chunk = (min(1024, length(grid_data["shunt_link_to"])),)
            create_dataset(shunt_link_grp, "receivers", Int32, (length(grid_data["shunt_link_to"]),),
                          chunk=shunt_link_receiver_chunk, compress=6, shuffle=())
            shunt_link_grp["receivers"][:] = grid_data["shunt_link_to"]
        end
        
        # ===== SOLUTION GROUP =====
        solution_grp = create_group(file, "solution")
        
        # Solution/Nodes
        sol_nodes_grp = create_group(solution_grp, "nodes")
        
        sol_bus_chunk = (min(1024, size(solution_data["bus"], 1)), size(solution_data["bus"], 2))
        create_dataset(sol_nodes_grp, "bus", Float32, size(solution_data["bus"]),
                      chunk=sol_bus_chunk, compress=6, shuffle=())
        sol_nodes_grp["bus"][:, :] = solution_data["bus"]
        
        sol_gen_chunk = (min(1024, size(solution_data["generator"], 1)), size(solution_data["generator"], 2))
        create_dataset(sol_nodes_grp, "generator", Float32, size(solution_data["generator"]),
                      chunk=sol_gen_chunk, compress=6, shuffle=())
        sol_nodes_grp["generator"][:, :] = solution_data["generator"]
        
        # Solution/Edges (NO senders/receivers - they're redundant with grid)
        sol_edges_grp = create_group(solution_grp, "edges")
        
        # AC line features only
        sol_ac_line_grp = create_group(sol_edges_grp, "ac_line")
        if size(solution_data["ac_line_features"], 1) > 0
            sol_ac_line_chunk = (min(1024, size(solution_data["ac_line_features"], 1)), 
                                 size(solution_data["ac_line_features"], 2))
            create_dataset(sol_ac_line_grp, "features", Float32, size(solution_data["ac_line_features"]),
                          chunk=sol_ac_line_chunk, compress=6, shuffle=())
            sol_ac_line_grp["features"][:, :] = solution_data["ac_line_features"]
        else
            sol_ac_line_grp["features"] = solution_data["ac_line_features"]
        end
        
        # Transformer features only
        sol_transformer_grp = create_group(sol_edges_grp, "transformer")
        if size(solution_data["transformer_features"], 1) > 0
            sol_transformer_chunk = (min(1024, size(solution_data["transformer_features"], 1)), 
                                     size(solution_data["transformer_features"], 2))
            create_dataset(sol_transformer_grp, "features", Float32, size(solution_data["transformer_features"]),
                          chunk=sol_transformer_chunk, compress=6, shuffle=())
            sol_transformer_grp["features"][:, :] = solution_data["transformer_features"]
        else
            sol_transformer_grp["features"] = solution_data["transformer_features"]
        end
        
        # ===== METADATA GROUP =====
        metadata_grp = create_group(file, "metadata")
        attributes(metadata_grp)["objective"] = solution_data["objective"]
        attributes(metadata_grp)["solve_time"] = solution_data["solve_time"]
        attributes(metadata_grp)["status"] = solution_data["status"]
        attributes(metadata_grp)["total_power_slack"] = Float32(total_power_slack)
        attributes(metadata_grp)["total_line_slack"] = Float32(total_line_slack)
        attributes(metadata_grp)["scenario_id"] = Int32(scenario_id)
    end
end

function verify_hdf5_structure(filename::String)
    println("\n" * "="^80)
    println("Verifying HDF5 structure: $filename")
    println("="^80)
    
    h5open(filename, "r") do file
        # === METADATA ===
        println("\n[Metadata]")
        metadata = file["metadata"]
        for attr_name in keys(attributes(metadata))
            val = read(attributes(metadata)[attr_name])
            println("  $attr_name: $val")
        end
        
        # === GRID/NODES ===
        println("\n[Grid/Nodes]")
        grid_nodes = file["grid/nodes"]
        
        println("  bus: shape=$(size(grid_nodes["bus"])), dtype=$(eltype(grid_nodes["bus"]))")
        println("  generator: shape=$(size(grid_nodes["generator"])), dtype=$(eltype(grid_nodes["generator"]))")
        println("  load: shape=$(size(grid_nodes["load"])), dtype=$(eltype(grid_nodes["load"]))")
        
        if haskey(grid_nodes, "shunt")
            println("  shunt: shape=$(size(grid_nodes["shunt"])), dtype=$(eltype(grid_nodes["shunt"]))")
        else
            println("  shunt: (not present)")
        end
        
        # === GRID/CONTEXT ===
        println("\n[Grid/Context]")
        context = file["grid/context"]
        if haskey(context, "baseMVA")
            println("  baseMVA: shape=$(size(context["baseMVA"])), dtype=$(eltype(context["baseMVA"]))")
        end
        for attr_name in keys(attributes(context))
            println("  $attr_name (attr): $(read(attributes(context)[attr_name]))")
        end
        
        # === GRID/EDGES ===
        println("\n[Grid/Edges/AC_Line]")
        ac_line = file["grid/edges/ac_line"]
        println("  senders: shape=$(size(ac_line["senders"])), dtype=$(eltype(ac_line["senders"]))")
        println("  receivers: shape=$(size(ac_line["receivers"])), dtype=$(eltype(ac_line["receivers"]))")
        println("  features: shape=$(size(ac_line["features"])), dtype=$(eltype(ac_line["features"]))")
        
        println("\n[Grid/Edges/Transformer]")
        transformer = file["grid/edges/transformer"]
        println("  senders: shape=$(size(transformer["senders"])), dtype=$(eltype(transformer["senders"]))")
        println("  receivers: shape=$(size(transformer["receivers"])), dtype=$(eltype(transformer["receivers"]))")
        println("  features: shape=$(size(transformer["features"])), dtype=$(eltype(transformer["features"]))")
        
        println("\n[Grid/Edges/Generator_Link]")
        gen_link = file["grid/edges/generator_link"]
        println("  senders: shape=$(size(gen_link["senders"])), dtype=$(eltype(gen_link["senders"]))")
        println("  receivers: shape=$(size(gen_link["receivers"])), dtype=$(eltype(gen_link["receivers"]))")
        
        println("\n[Grid/Edges/Load_Link]")
        load_link = file["grid/edges/load_link"]
        println("  senders: shape=$(size(load_link["senders"])), dtype=$(eltype(load_link["senders"]))")
        println("  receivers: shape=$(size(load_link["receivers"])), dtype=$(eltype(load_link["receivers"]))")
        
        if haskey(file["grid/edges"], "shunt_link")
            println("\n[Grid/Edges/Shunt_Link]")
            shunt_link = file["grid/edges/shunt_link"]
            println("  senders: shape=$(size(shunt_link["senders"])), dtype=$(eltype(shunt_link["senders"]))")
            println("  receivers: shape=$(size(shunt_link["receivers"])), dtype=$(eltype(shunt_link["receivers"]))")
        end
        
        # === SOLUTION/NODES ===
        println("\n[Solution/Nodes]")
        sol_nodes = file["solution/nodes"]
        println("  bus: shape=$(size(sol_nodes["bus"])), dtype=$(eltype(sol_nodes["bus"]))")
        println("  generator: shape=$(size(sol_nodes["generator"])), dtype=$(eltype(sol_nodes["generator"]))")
        
        # === SOLUTION/EDGES ===
        println("\n[Solution/Edges/AC_Line]")
        sol_ac_line = file["solution/edges/ac_line"]
        println("  features: shape=$(size(sol_ac_line["features"])), dtype=$(eltype(sol_ac_line["features"]))")
        
        println("\n[Solution/Edges/Transformer]")
        sol_transformer = file["solution/edges/transformer"]
        println("  features: shape=$(size(sol_transformer["features"])), dtype=$(eltype(sol_transformer["features"]))")
    end
    
    println("\n" * "="^80)
end

function write_array(group, name, data::Array{T, 1}) where T
    if isempty(data)
        group[name] = data
    else
        chunk = (min(1024, length(data)),)
        create_dataset(group, name, T, size(data), chunk=chunk, compress=6, shuffle=())
        group[name][:] = data
    end
end

function write_array(group, name, data::Array{T, 2}) where T
    if size(data, 1) == 0
        group[name] = data
    else
        chunk = (min(1024, size(data, 1)), size(data, 2))
        create_dataset(group, name, T, size(data), chunk=chunk, compress=6, shuffle=())
        group[name][:, :] = data
    end
end

function write_scenario_to_group(scenario_grp, network::Dict, result::Dict, 
                                 scenario_id::Int, total_power_slack::Float64, 
                                 total_line_slack::Float64)
    
    grid_data = extract_grid_data(network)
    solution_data = extract_solution_data(result, network)
    
    # === GRID GROUP ===
    grid_grp = create_group(scenario_grp, "grid")
    
    # Grid/Nodes
    nodes_grp = create_group(grid_grp, "nodes")
    write_array(nodes_grp, "bus", grid_data["bus"])
    write_array(nodes_grp, "generator", grid_data["generator"])
    write_array(nodes_grp, "load", grid_data["load"])
    write_array(nodes_grp, "shunt", grid_data["shunt"])
    
    # Grid/Context
    context_grp = create_group(grid_grp, "context")
    baseMVA_data = Float32[network["baseMVA"]]
    context_grp["baseMVA"] = reshape(baseMVA_data, 1, 1, 1)
    
    # Grid/Edges
    edges_grp = create_group(grid_grp, "edges")
    
    # AC line
    ac_line_grp = create_group(edges_grp, "ac_line")
    write_array(ac_line_grp, "senders", grid_data["ac_line_from"])
    write_array(ac_line_grp, "receivers", grid_data["ac_line_to"])
    write_array(ac_line_grp, "features", grid_data["ac_line_features"])
    
    # Transformer
    transformer_grp = create_group(edges_grp, "transformer")
    write_array(transformer_grp, "senders", grid_data["transformer_from"])
    write_array(transformer_grp, "receivers", grid_data["transformer_to"])
    write_array(transformer_grp, "features", grid_data["transformer_features"])
    
    # Generator link
    gen_link_grp = create_group(edges_grp, "generator_link")
    write_array(gen_link_grp, "senders", grid_data["generator_link_from"])
    write_array(gen_link_grp, "receivers", grid_data["generator_link_to"])
    
    # Load link
    load_link_grp = create_group(edges_grp, "load_link")
    write_array(load_link_grp, "senders", grid_data["load_link_from"])
    write_array(load_link_grp, "receivers", grid_data["load_link_to"])
    
    # Shunt link
    if !isempty(grid_data["shunt_link_from"])
        shunt_link_grp = create_group(edges_grp, "shunt_link")
        write_array(shunt_link_grp, "senders", grid_data["shunt_link_from"])
        write_array(shunt_link_grp, "receivers", grid_data["shunt_link_to"])
    end
    
    # === SOLUTION GROUP ===
    solution_grp = create_group(scenario_grp, "solution")
    
    # Solution/Nodes
    sol_nodes_grp = create_group(solution_grp, "nodes")
    write_array(sol_nodes_grp, "bus", solution_data["bus"])
    write_array(sol_nodes_grp, "generator", solution_data["generator"])
    
    # Solution/Edges
    sol_edges_grp = create_group(solution_grp, "edges")
    
    sol_ac_line_grp = create_group(sol_edges_grp, "ac_line")
    write_array(sol_ac_line_grp, "features", solution_data["ac_line_features"])
    
    sol_transformer_grp = create_group(sol_edges_grp, "transformer")
    write_array(sol_transformer_grp, "features", solution_data["transformer_features"])
    
    # === METADATA ===
    metadata_grp = create_group(scenario_grp, "metadata")
    attributes(metadata_grp)["objective"] = solution_data["objective"]
    attributes(metadata_grp)["solve_time"] = solution_data["solve_time"]
    attributes(metadata_grp)["status"] = solution_data["status"]
    attributes(metadata_grp)["total_power_slack"] = Float32(total_power_slack)
    attributes(metadata_grp)["total_line_slack"] = Float32(total_line_slack)
    attributes(metadata_grp)["scenario_id"] = Int32(scenario_id)
end

function write_chunk_to_hdf5(filename::String, chunk_results::Vector)
    
    n_scenarios = length(chunk_results)
    println("Writing $n_scenarios scenarios to: $filename")
    
    h5open(filename, "w") do file
        for result_tuple in chunk_results

            scenario_name = "scenario_$(lpad(result_tuple.id, 6, '0'))"
            scenario_grp = create_group(file, scenario_name)
            
            write_scenario_to_group(
                scenario_grp,
                result_tuple.network,
                result_tuple.result,
                result_tuple.id,
                result_tuple.power_slack,
                result_tuple.line_slack
            )
        end
        
        attributes(file)["n_scenarios"] = Int32(n_scenarios)
        attributes(file)["chunk_file"] = filename
    end
    
    println("Successfully wrote $n_scenarios scenarios to $filename")
end