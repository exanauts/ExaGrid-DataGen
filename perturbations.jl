using Random
using PowerModels

function perturb_loads_separate!(network::Dict, 
    p_range::Tuple{Float64,Float64},
    q_range::Tuple{Float64,Float64},
    seed::Int)
    
    Random.seed!(seed)
    
    for (id, load) in network["load"]
        p_scale = p_range[1] + (p_range[2] - p_range[1]) * rand()
        q_scale = q_range[1] + (q_range[2] - q_range[1]) * rand()
        
        # println("scaling factors are $(p_scale) and $(q_scale) for load id $(id)")
        load["pd"] *= p_scale
        load["qd"] *= q_scale
    end
    
    return network
end