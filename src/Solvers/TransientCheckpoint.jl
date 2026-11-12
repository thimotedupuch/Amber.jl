"""Write a restart state to portable TOML. Resume deliberately restarts integration at order one."""
function save_checkpoint(path::AbstractString, result::SimulationResult{<:Any,<:Transient})
    isempty(result.axis) && throw(ArgumentError("cannot checkpoint an empty result"))
    data = Dict("schema" => 1, "time" => last(result.axis),
        "state" => collect(result.values[:, end]),
        "topology" => string(result.compiled.topology.topology_fingerprint),
        "parameters" => string(result.compiled.parameters.fingerprint),
        "temperature" => result.analysis.temperature, "method" => string(result.analysis.method))
    open(path, "w") do io
        TOML.print(io, data; sorted = true)
    end
    return path
end

"""Resume a checkpoint against exactly matching circuit parameters. BDF history is restarted."""
function resume_transient(c, path::AbstractString, stop; kwargs...)
    data = TOML.parsefile(path)
    get(data, "schema", 0) == 1 || throw(ArgumentError("unsupported checkpoint schema"))
    cc = compile(c)
    data["topology"] == string(cc.topology.topology_fingerprint) || throw(ArgumentError("checkpoint topology mismatch"))
    data["parameters"] == string(cc.parameters.fingerprint) || throw(ArgumentError("checkpoint parameter mismatch"))
    result = transient(cc, data["time"] => stop;
        initial = Float64.(data["state"]), temperature = data["temperature"],
        method = Symbol(data["method"]), kwargs...)
    result.stats[:checkpoint_restart] = :first_order
    result.stats[:checkpoint_time] = data["time"]
    return result
end
