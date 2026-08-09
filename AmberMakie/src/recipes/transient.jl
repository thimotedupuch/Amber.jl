function _transform(values, transform)
    transform === :identity && return values
    transform === :real && return real.(values)
    transform === :imag && return imag.(values)
    transform === :magnitude && return abs.(values)
    transform === :phase && return rad2deg.(angle.(values))
    throw(ArgumentError("transform must be :identity, :real, :imag, :magnitude, or :phase"))
end

function traceplot(position, result::Amber.SimulationResult; signals, interval=nothing,
        transform=:identity, axis=(;), kwargs...)
    signal_list = signals isa AbstractVector || signals isa Tuple ? collect(signals) : [signals]
    isempty(signal_list) && throw(ArgumentError("signals must not be empty"))
    views = traceview.(Ref(result), signal_list)
    any(view -> eltype(view.values) <: Complex && transform === :identity, views) &&
        throw(ArgumentError("complex traces require an explicit transform"))
    selected = interval === nothing ? eachindex(result.axis) :
        findall(x -> first(interval) <= x <= last(interval), result.axis)
    isempty(selected) && throw(ArgumentError("interval contains no samples"))
    slot = _position(position)
    ax = Makie.Axis(slot; xlabel="Time (s)", ylabel=only(unique(view.unit for view in views)), axis...)
    plots = [Makie.lines!(ax, view.axis[selected], _transform(view.values[selected], transform);
        label=view.label, kwargs...) for view in views]
    Makie.axislegend(ax)
    PlotHandle(slot, (trace=ax,), plots, views)
end
