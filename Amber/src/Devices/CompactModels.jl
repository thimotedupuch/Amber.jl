"""Optional, language-neutral callback interface for compact-model characterization.

The callback accepts `(voltages, temperature)` in SI and returns a named tuple
with `currents`, `charges`, `conductance`, and `capacitance`. Terminal currents
flow into the device; matrices differentiate terminal currents/charges with
respect to terminal voltages. No netlist parser or simulator ABI is implied.
"""
struct CompactModelCallback{F}
    terminals::Int
    evaluate::F
    function CompactModelCallback(terminals::Integer, evaluate::F) where F
        terminals >= 2 || throw(ArgumentError("a compact model needs at least two terminals"))
        new{F}(Int(terminals), evaluate)
    end
end

"""Evaluate and validate a compact-model callback, including terminal conservation.

This is a characterization boundary, not yet a circuit primitive. External
libraries may wrap their native calls inside the Julia callback.
"""
function compact_model_point(model::CompactModelCallback, voltages; temperature=300.0, atol=1e-12, rtol=1e-8)
    n = model.terminals
    length(voltages) == n || throw(DimensionMismatch("terminal voltage count"))
    v = Float64[_si_value(x, Unitful.V) for x in voltages]
    t = Float64(_si_value(temperature, Unitful.K))
    all(isfinite,v) && isfinite(t) && t > 0 || throw(ArgumentError("finite voltages and positive temperature required"))
    atol >= 0 && rtol >= 0 && isfinite(atol) && isfinite(rtol) || throw(ArgumentError("finite nonnegative tolerances required"))
    p = model.evaluate(v,t)
    for name in (:currents, :charges, :conductance, :capacitance)
        hasproperty(p,name) || throw(ArgumentError("callback omitted $name"))
        x = getproperty(p,name)
        size(x) == (name in (:currents,:charges) ? (n,) : (n,n)) || throw(DimensionMismatch("invalid $name dimensions"))
        all(isfinite,x) || throw(ArgumentError("nonfinite $name"))
        sums = ndims(x) == 1 ? [sum(x)] : vec(sum(x; dims=1))
        all(y -> abs(y) <= atol + rtol * maximum(abs,x), sums) || throw(ArgumentError("$name violates terminal conservation"))
        if ndims(x) == 2
            all(y -> abs(y) <= atol + rtol * maximum(abs,x), sum(x; dims=2)) || throw(ArgumentError("$name violates reference invariance"))
        end
    end
    return p
end
