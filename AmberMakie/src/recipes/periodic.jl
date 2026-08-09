function pssplot(position, result::Amber.PSSResult; signals, cycles=1, kwargs...)
    cycles >= 1 || throw(ArgumentError("cycles must be positive"))
    orbit = result.orbit; signal_list = signals isa AbstractVector || signals isa Tuple ? collect(signals) : [signals]
    slot = _position(position); axis = Makie.Axis(slot; xlabel="Time (s)", ylabel="Value")
    plots = Any[]
    for signal in signal_list
        values = Amber.trace(orbit, signal)
        times = reduce(vcat, [orbit.axis .+ (cycle - 1) * result.period for cycle in 1:cycles])
        repeated = repeat(values, cycles)
        push!(plots, Makie.lines!(axis, times, real.(repeated); label=string(signal), kwargs...))
    end
    Makie.axislegend(axis)
    PlotHandle(slot, (pss=axis,), plots, result)
end

function orbitplot(position, result::Amber.PSSResult; x, y, kwargs...)
    xv, yv = Amber.trace(result.orbit, x), Amber.trace(result.orbit, y)
    slot = _position(position); axis = Makie.Axis(slot; xlabel=string(x), ylabel=string(y))
    plot = Makie.lines!(axis, real.(xv), real.(yv); kwargs...)
    PlotHandle(slot, (orbit=axis,), (orbit=plot,), result)
end
