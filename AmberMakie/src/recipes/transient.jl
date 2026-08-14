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
    units = unique(view.unit for view in views)
    mixed_units = length(units) > 1
    ax = Makie.Axis(slot; xlabel="Time (s)",
        ylabel=mixed_units ? "Value (mixed units)" : only(units), axis...)
    plots = [Makie.lines!(ax, view.axis[selected], _transform(view.values[selected], transform);
        label=mixed_units ? "$(view.label) [$(view.unit)]" : view.label, kwargs...)
        for view in views]
    Makie.axislegend(ax)
    PlotHandle(slot, (trace=ax,), plots, views)
end

function eyediagramplot(position, result::Amber.SimulationResult; signal, period,
        unit_intervals::Integer=2, offset=first(result.axis), mask=nothing, kwargs...)
    view = eyediagramview(result; signal, period, unit_intervals, offset, mask)
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel="Unit intervals", ylabel=view.signal,
        title="Eye diagram · $(length(view.phases)) traces")
    traces = [Makie.lines!(axis, phase, values;
        color=(_AMBER_COLORS.output, 0.18), kwargs...)
        for (phase, values) in zip(view.phases, view.values)]
    violations = nothing
    if !isempty(view.violations)
        violations = Makie.scatter!(axis, getproperty.(view.violations, :phase),
            getproperty.(view.violations, :value); color=_AMBER_COLORS.invalid,
            marker=:x, markersize=8)
    end
    Makie.xlims!(axis, 0, view.unit_intervals)
    Makie.text!(axis, 0.98, 0.98; space=:relative, align=(:right, :top),
        text=mask === nothing ? "No mask supplied" :
            "Mask violations: $(length(view.violations))",
        color=isempty(view.violations) ? :gray40 : _AMBER_COLORS.invalid)
    PlotHandle(slot, (eye=axis,), (traces=traces, violations=violations), view)
end

function _bathtub_curve(view::JitterView; points=201)
    points >= 3 || throw(ArgumentError("bathtub curve requires at least three points"))
    offsets = collect(range(-view.nominal_period / 2, view.nominal_period / 2; length=points))
    errors = Vector{Float64}(undef, length(offsets))
    sample_count = length(view.tie)
    floor_probability = 0.5 / sample_count
    for (index, offset) in enumerate(offsets)
        left = count(value -> value < -view.nominal_period / 2 - offset, view.tie)
        right = count(value -> value > view.nominal_period / 2 - offset, view.tie)
        errors[index] = max((left + right) / (2sample_count), floor_probability)
    end
    offsets, errors
end

function jitterplot(position, result::Amber.SimulationResult; signal,
        kind=:tie, threshold=nothing, edge=:rising, nominal_period=nothing,
        bins=40, points=201, kwargs...)
    kind in (:tie, :period, :cycle_to_cycle, :histogram, :bathtub) ||
        throw(ArgumentError("kind must be :tie, :period, :cycle_to_cycle, :histogram, or :bathtub"))
    view = jitterview(result; signal, threshold, edge, nominal_period)
    slot = _position(position)
    if kind === :histogram
        axis = Makie.Axis(slot; xlabel="TIE (s)", ylabel="Count")
        plot = Makie.hist!(axis, view.tie; bins, kwargs...)
        display = (x=view.tie, y=nothing)
    elseif kind === :bathtub
        offsets, ber = _bathtub_curve(view; points)
        axis = Makie.Axis(slot; xlabel="Sampling offset (s)", ylabel="Estimated BER",
            yscale=log10)
        plot = Makie.lines!(axis, offsets, ber; kwargs...)
        display = (x=offsets, y=ber)
    else
        values = kind === :tie ? view.tie : kind === :period ?
            view.period_jitter : view.cycle_to_cycle
        label = kind === :tie ? "TIE (s)" : kind === :period ?
            "Period jitter (s)" : "Cycle-to-cycle jitter (s)"
        axis = Makie.Axis(slot; xlabel="Edge / cycle", ylabel=label)
        plot = Makie.lines!(axis, collect(eachindex(values)), values; kwargs...)
        Makie.hlines!(axis, [0.0]; color=:gray50, linestyle=:dash)
        display = (x=collect(eachindex(values)), y=values)
    end
    rms = sqrt(sum(abs2, view.tie) / length(view.tie))
    peak_to_peak = maximum(view.tie) - minimum(view.tie)
    Makie.text!(axis, 0.98, 0.98; space=:relative, align=(:right, :top),
        text="TIE RMS: $(engineering(rms; unit="s"))\nTIE p-p: $(engineering(peak_to_peak; unit="s"))",
        color=:gray35)
    PlotHandle(slot, (jitter=axis,), (jitter=plot,),
        (jitter=view, kind, display, rms, peak_to_peak))
end
