using PowerModels
using JuMP

function variable_power_balance_slack(pm::AbstractPowerModel; nw::Int=nw_id_default)
    p_slack_pos = var(pm, nw)[:p_slack_pos] = JuMP.@variable(pm.model,
        [i in ids(pm, nw, :bus)], base_name="$(nw)_p_slack_pos",
        lower_bound = 0,
        start = 0
    )
    
    p_slack_neg = var(pm, nw)[:p_slack_neg] = JuMP.@variable(pm.model,
        [i in ids(pm, nw, :bus)], base_name="$(nw)_p_slack_neg",
        lower_bound = 0,
        start = 0
    )
    
    q_slack_pos = var(pm, nw)[:q_slack_pos] = JuMP.@variable(pm.model,
        [i in ids(pm, nw, :bus)], base_name="$(nw)_q_slack_pos",
        lower_bound = 0,
        start = 0
    )
    
    q_slack_neg = var(pm, nw)[:q_slack_neg] = JuMP.@variable(pm.model,
        [i in ids(pm, nw, :bus)], base_name="$(nw)_q_slack_neg",
        lower_bound = 0,
        start = 0
    )
    
    PowerModels.sol_component_value(pm, nw, :bus, :p_slack_pos, ids(pm, nw, :bus), p_slack_pos)
    PowerModels.sol_component_value(pm, nw, :bus, :p_slack_neg, ids(pm, nw, :bus), p_slack_neg)
    PowerModels.sol_component_value(pm, nw, :bus, :q_slack_pos, ids(pm, nw, :bus), q_slack_pos)
    PowerModels.sol_component_value(pm, nw, :bus, :q_slack_neg, ids(pm, nw, :bus), q_slack_neg)
end

function variable_line_limit_slack(pm::AbstractPowerModel; nw::Int=nw_id_default)
    s_slack = var(pm, nw)[:s_slack] = JuMP.@variable(pm.model,
        [i in ids(pm, nw, :branch)], base_name="$(nw)_s_slack",
        lower_bound = 0,
        start = 0
    )

   PowerModels.sol_component_value(pm, nw, :branch, :s_slack, ids(pm, nw, :branch), s_slack)  
end

function constraint_power_balance_with_slack(pm::AbstractPowerModel, i::Int; nw::Int=nw_id_default)
    bus = ref(pm, nw, :bus, i)
    bus_arcs = ref(pm, nw, :bus_arcs, i)
    bus_gens = ref(pm, nw, :bus_gens, i)
    bus_loads = ref(pm, nw, :bus_loads, i)
    bus_shunts = ref(pm, nw, :bus_shunts, i)
    
    p = var(pm, nw, :p)
    q = var(pm, nw, :q)
    pg = var(pm, nw, :pg)
    qg = var(pm, nw, :qg)
    
    p_slack_pos = var(pm, nw, :p_slack_pos)
    p_slack_neg = var(pm, nw, :p_slack_neg)
    q_slack_pos = var(pm, nw, :q_slack_pos)
    q_slack_neg = var(pm, nw, :q_slack_neg)
    
    cstr_p = JuMP.@constraint(pm.model,
        sum(p[a] for a in bus_arcs)
        ==
        sum(pg[g] for g in bus_gens)
        - sum(ref(pm, nw, :load, l, "pd") for l in bus_loads)
        - sum(ref(pm, nw, :shunt, s, "gs") for s in bus_shunts) * bus["vm"]^2
        + p_slack_pos[i] - p_slack_neg[i]
    )
    
    cstr_q = JuMP.@constraint(pm.model,
        sum(q[a] for a in bus_arcs)
        ==
        sum(qg[g] for g in bus_gens)
        - sum(ref(pm, nw, :load, l, "qd") for l in bus_loads)
        + sum(ref(pm, nw, :shunt, s, "bs") for s in bus_shunts) * bus["vm"]^2
        + q_slack_pos[i] - q_slack_neg[i]
    )
    
end

function constraint_thermal_limit_from_with_slack(pm::AbstractPowerModel, i::Int; nw::Int=nw_id_default)
    branch = ref(pm, nw, :branch, i)
    p_fr = var(pm, nw, :p, (i, branch["f_bus"], branch["t_bus"]))
    q_fr = var(pm, nw, :q, (i, branch["f_bus"], branch["t_bus"]))
    s_slack = var(pm, nw, :s_slack)
    
    rate_a = branch["rate_a"]
    
    if rate_a < Inf
        JuMP.@constraint(pm.model, p_fr^2 + q_fr^2 <= rate_a^2 + s_slack[i])
    end
end

function constraint_thermal_limit_to_with_slack(pm::AbstractPowerModel, i::Int; nw::Int=nw_id_default)
    branch = ref(pm, nw, :branch, i)
    p_to = var(pm, nw, :p, (i, branch["t_bus"], branch["f_bus"]))
    q_to = var(pm, nw, :q, (i, branch["t_bus"], branch["f_bus"]))
    s_slack = var(pm, nw, :s_slack)
    
    rate_a = branch["rate_a"]
    
    if rate_a < Inf
        JuMP.@constraint(pm.model, p_to^2 + q_to^2 <= rate_a^2 + s_slack[i])
    end
end

function objective_min_cost_with_penalties(pm::AbstractPowerModel; nw::Int=nw_id_default, power_balance_relaxation::Bool=false, line_limit_relaxation::Bool=false)
    penalty_p = 3e5 
    penalty_q = 3e5 
    penalty_s = 3e5  

    pg = var(pm, nw, :pg)
    
    gen_cost = JuMP.@expression(pm.model, 
        sum(
            sum(gen["cost"][i] * pg[g]^(length(gen["cost"]) - i) for i in 1:length(gen["cost"]))
            for (g, gen) in ref(pm, nw, :gen)
        )
    )

    obj_expr = gen_cost

    if power_balance_relaxation
        p_slack_pos = var(pm, nw, :p_slack_pos)
        p_slack_neg = var(pm, nw, :p_slack_neg)
        q_slack_pos = var(pm, nw, :q_slack_pos)
        q_slack_neg = var(pm, nw, :q_slack_neg)

        power_balance_penalty = JuMP.@expression(pm.model,
            penalty_p * sum(p_slack_pos[i] + p_slack_neg[i] for i in ids(pm, nw, :bus))
            + penalty_q * sum(q_slack_pos[i] + q_slack_neg[i] for i in ids(pm, nw, :bus))
        )
        obj_expr += power_balance_penalty
    end
    
    if line_limit_relaxation
        s_slack = var(pm, nw, :s_slack)
        line_limit_penalty = JuMP.@expression(pm.model,
            penalty_s * sum(s_slack[i] for i in ids(pm, nw, :branch))
        )
        obj_expr += line_limit_penalty
    end
    
    return JuMP.@objective(pm.model, Min, obj_expr)   
end

function build_opf_with_slacks(pm::AbstractPowerModel; power_balance_relaxation::Bool=false, line_limit_relaxation::Bool=false)
    PowerModels.variable_bus_voltage(pm)
    PowerModels.variable_gen_power(pm)
    PowerModels.variable_branch_power(pm)
    
    if power_balance_relaxation
        variable_power_balance_slack(pm)
    end
        
    if line_limit_relaxation
        variable_line_limit_slack(pm)
    end

    objective_min_cost_with_penalties(pm, power_balance_relaxation=power_balance_relaxation, line_limit_relaxation=line_limit_relaxation)
    
    for i in ids(pm, :ref_buses)
        PowerModels.constraint_theta_ref(pm, i)
    end
    
    for i in ids(pm, :bus)
        if power_balance_relaxation
            constraint_power_balance_with_slack(pm, i)
        else
            PowerModels.constraint_power_balance(pm, i)
        end
    end
    
    for i in ids(pm, :branch)
        PowerModels.constraint_ohms_yt_from(pm, i)
        PowerModels.constraint_ohms_yt_to(pm, i)
        
        PowerModels.constraint_voltage_angle_difference(pm, i)
        
        if line_limit_relaxation
            constraint_thermal_limit_from_with_slack(pm, i)
            constraint_thermal_limit_to_with_slack(pm, i)
        else
            PowerModels.constraint_thermal_limit_from(pm, i)
            PowerModels.constraint_thermal_limit_to(pm, i) 
        end
        

    end
end