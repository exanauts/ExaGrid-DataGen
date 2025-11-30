#!/usr/bin/env julia
# Basic aggregation for ACOPF HDF5 outputs: solve time, objective, slack, status counts.

using HDF5
using Statistics
using Printf

function read_scenarios(path::String)
    # Use a flexible vector type so we can push NamedTuples read from HDF5.
    # Previously `Tuple[]` caused a MethodError when pushing NamedTuples.
    records = Vector{Any}()
    h5open(path, "r") do f
        for name in keys(f)
            startswith(name, "scenario_") || continue
            md = f[name]["metadata"]
            attrs = attributes(md)
            objective   = read(attrs["objective"])
            solve_time  = read(attrs["solve_time"])
            status      = String(read(attrs["status"]))
            p_slack     = read(attrs["total_power_slack"])
            l_slack     = read(attrs["total_line_slack"])
            push!(records, (
                file = path,
                scenario = name,
                objective = objective,
                solve_time = solve_time,
                status = status,
                power_slack = p_slack,
                line_slack = l_slack
            ))
        end
    end
    return records
end

function summarize(records)
    if isempty(records)
        println("No scenarios found.")
        return
    end
    times   = [r.solve_time for r in records]
    objs    = [r.objective for r in records]
    pslack  = [r.power_slack for r in records]
    lslack  = [r.line_slack for r in records]

    status_counts = Dict{String,Int}()
    for r in records
        status_counts[r.status] = get(status_counts, r.status, 0) + 1
    end

    @printf "Total scenarios: %d across %d files\n" length(records) length(unique(r.file for r in records))
    @printf "Solve time (s): mean=%.3f median=%.3f min=%.3f max=%.3f\n" mean(times) median(times) minimum(times) maximum(times)
    @printf "Objective:       mean=%.6g median=%.6g min=%.6g max=%.6g\n" mean(objs) median(objs) minimum(objs) maximum(objs)
    @printf "Power slack:     mean=%.3e max=%.3e\n" mean(pslack) maximum(pslack)
    @printf "Line slack:      mean=%.3e max=%.3e\n" mean(lslack) maximum(lslack)
    println("Status counts:")
    for (k,v) in sort(collect(status_counts); by=x->x[1])
        println("  $(rpad(k, 20)): $v")
    end
end

function main(args)
    isempty(args) && error("Provide one or more HDF5 files (globs expanded by shell).")
    files = collect(args)
    all_records = reduce(vcat, (read_scenarios(f) for f in files); init=Tuple[])
    summarize(all_records)
end

main(ARGS)
