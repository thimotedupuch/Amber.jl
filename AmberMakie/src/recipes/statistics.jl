function _numeric_successes(view::EnsembleView)
    indices = [index for index in eachindex(view.metrics) if view.converged[index] && view.metrics[index] isa Real]
    indices, Float64[view.metrics[index] for index in indices]
end

function sweepplot(position, result::Amber.SweepResult; x=:parameter, metric=:value, failed=:mark, kwargs...)
    failed in (:mark, :hide) || throw(ArgumentError("failed must be :mark or :hide"))
    view = ensembleview(result)
    success = findall(view.converged)
    all(index -> view.metrics[index] isa Real, success) || throw(ArgumentError("sweep metrics must be scalar real values"))
    xs = x === :parameter ? view.parameter_values : view.indices
    all(value -> value isa Real, xs) || throw(ArgumentError("sweep x values must be real"))
    slot = _position(position); axis = Makie.Axis(slot; xlabel=result.selector, ylabel=string(metric))
    curve = Makie.lines!(axis, Float64.(xs[success]), Float64.(view.metrics[success]); kwargs...)
    failures = nothing
    if failed === :mark && any(.!view.converged)
        failed_indices = findall(.!view.converged)
        baseline = isempty(success) ? 0.0 : minimum(Float64.(view.metrics[success]))
        failures = Makie.scatter!(axis, Float64.(xs[failed_indices]), fill(baseline, length(failed_indices)); marker=:x, color=_AMBER_COLORS.invalid)
    end
    PlotHandle(slot, (sweep=axis,), (curve=curve, failures=failures), view)
end

function ensembleplot(position, result::Amber.MonteCarloResult; metric=:value, predicate=nothing, bins=30, kwargs...)
    view = ensembleview(result); _, values = _numeric_successes(view)
    isempty(values) && throw(ArgumentError("ensemble has no successful scalar values"))
    slot = _position(position); axis = Makie.Axis(slot; xlabel=string(metric), ylabel="Count")
    histogram = Makie.hist!(axis, values; bins, kwargs...)
    failed_count = count(!, result.converged)
    failure_text = failed_count == 0 ? "All $(length(result.values)) samples converged" :
        "$(failed_count) failed / $(length(result.values)) ($(round(100failed_count / length(result.values); digits=1))%)"
    Makie.text!(axis, 0.98, 0.98; text=failure_text, space=:relative,
        align=(:right, :top), color=failed_count == 0 ? :gray35 : _AMBER_COLORS.invalid,
        fontsize=11)
    if predicate !== nothing
        passed = filter(predicate, values)
        isempty(passed) || Makie.hist!(axis, passed; bins, color=(_AMBER_COLORS.nominal, 0.5))
        rate = Amber.yield_rate(result, predicate)
        Makie.text!(axis, 0.98, 0.90; text="Yield: $(round(100rate; digits=1))%",
            space=:relative, align=(:right, :top), color=_AMBER_COLORS.nominal, fontsize=11)
    end
    PlotHandle(slot, (ensemble=axis,), (histogram=histogram,), view)
end

function correlationplot(position, result::Amber.MonteCarloResult; parameter, metric=:value, kwargs...)
    key = Symbol(parameter)
    indices = [index for index in eachindex(result.values) if result.converged[index] &&
        result.values[index] isa Real && haskey(result.parameters[index], key)]
    isempty(indices) && throw(ArgumentError("no successful scalar samples contain parameter $(key)"))
    x = Float64[result.parameters[index][key] for index in indices]
    y = Float64[result.values[index] for index in indices]
    slot = _position(position); axis = Makie.Axis(slot; xlabel=String(key), ylabel=string(metric))
    plot = Makie.scatter!(axis, x, y; kwargs...)
    failed_count = count(!, result.converged)
    failed_count > 0 && Makie.text!(axis, 0.98, 0.98;
        text="$(failed_count) failed samples excluded from correlation",
        space=:relative, align=(:right, :top), color=_AMBER_COLORS.invalid, fontsize=11)
    PlotHandle(slot, (correlation=axis,), (correlation=plot,), (parameter=x, metric=y, samples=indices))
end

function compareplot(position, results; signals, alignment=:strict, kwargs...)
    alignment in (:strict, :interpolate) || throw(ArgumentError("alignment must be :strict or :interpolate"))
    result_list = collect(results); isempty(result_list) && throw(ArgumentError("results must not be empty"))
    signal_list = signals isa AbstractVector || signals isa Tuple ? collect(signals) : [signals]
    reference_axis = first(result_list).axis
    alignment === :strict && any(result -> result.axis != reference_axis, result_list) &&
        throw(ArgumentError("strict comparison requires identical axes"))
    slot = _position(position); axis = Makie.Axis(slot; xlabel="Axis", ylabel="Value")
    plots = Any[]
    for (ri, result) in enumerate(result_list), signal in signal_list
        values = real.(Amber.trace(result, signal))
        push!(plots, Makie.lines!(axis, result.axis, values; label="$(signal) [$(ri)]", kwargs...))
    end
    Makie.axislegend(axis)
    PlotHandle(slot, (comparison=axis,), plots, result_list)
end
