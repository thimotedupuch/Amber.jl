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
    # Retain the original grid: NaNs break the line at failed simulations.
    displayed = [view.converged[i] ? Float64(view.metrics[i]) : NaN for i in eachindex(xs)]
    curve = Makie.lines!(axis, Float64.(xs), displayed; kwargs...)
    failures = nothing
    if failed === :mark && any(.!view.converged)
        failed_indices = findall(.!view.converged)
        baseline = isempty(success) ? 0.0 : minimum(Float64.(view.metrics[success]))
        failures = Makie.scatter!(axis, Float64.(xs[failed_indices]), fill(baseline, length(failed_indices)); marker=:x, color=_AMBER_COLORS.invalid)
    end
    PlotHandle(slot, (sweep=axis,), (curve=curve, failures=failures), view)
end

function ensembleplot(position, result::Amber.MonteCarloResult; metric=:value,
        predicate=nothing, bins=30, confidence=true, kwargs...)
    view = ensembleview(result); _, values = _numeric_successes(view)
    isempty(values) && throw(ArgumentError("ensemble has no successful scalar values"))
    slot = _position(position); axis = Makie.Axis(slot; xlabel=string(metric), ylabel="Count")
    histogram = Makie.hist!(axis, values; bins, kwargs...)
    confidence_band = nothing
    mean_marker = nothing
    if confidence && length(values) >= 2
        interval = Amber.confidence_interval(result)
        confidence_band = Makie.vspan!(axis, first(interval), last(interval);
            color=(_AMBER_COLORS.output, 0.15))
        mean_marker = Makie.vlines!(axis, [sum(values) / length(values)];
            color=_AMBER_COLORS.output, linestyle=:dash)
    end
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
    PlotHandle(slot, (ensemble=axis,),
        (histogram=histogram, confidence=confidence_band, mean=mean_marker), view)
end

function _quantile_sorted(values, probability)
    isempty(values) && throw(ArgumentError("quantile requires values"))
    position = 1 + (length(values) - 1) * probability
    lower = floor(Int, position); upper = ceil(Int, position)
    lower == upper && return values[lower]
    values[lower] + (position - lower) * (values[upper] - values[lower])
end

function outlier_samples(result::Amber.MonteCarloResult; fence=1.5)
    fence > 0 || throw(ArgumentError("outlier fence must be positive"))
    indices = [index for index in eachindex(result.values)
        if result.converged[index] && result.values[index] isa Real]
    length(indices) >= 4 || return Int[]
    values = sort(Float64[result.values[index] for index in indices])
    q1, q3 = _quantile_sorted(values, 0.25), _quantile_sorted(values, 0.75)
    width = q3 - q1
    lower, upper = q1 - fence * width, q3 + fence * width
    [index for index in indices if result.values[index] < lower || result.values[index] > upper]
end

function correlationplot(position, result::Amber.MonteCarloResult; parameter,
        metric=:value, mark_outliers=true, kwargs...)
    key = Symbol(parameter)
    indices = [index for index in eachindex(result.values) if result.converged[index] &&
        result.values[index] isa Real && haskey(result.parameters[index], key)]
    isempty(indices) && throw(ArgumentError("no successful scalar samples contain parameter $(key)"))
    x = Float64[result.parameters[index][key] for index in indices]
    y = Float64[result.values[index] for index in indices]
    slot = _position(position); axis = Makie.Axis(slot; xlabel=String(key), ylabel=string(metric))
    plot = Makie.scatter!(axis, x, y; kwargs...)
    outlier_indices = mark_outliers ? intersect(indices, outlier_samples(result)) : Int[]
    outlier_positions = [only(findall(==(sample), indices)) for sample in outlier_indices]
    outlier_plot = isempty(outlier_positions) ? nothing : Makie.scatter!(axis,
        x[outlier_positions], y[outlier_positions]; color=_AMBER_COLORS.invalid,
        marker=:diamond, markersize=13)
    failed_count = count(!, result.converged)
    failed_count > 0 && Makie.text!(axis, 0.98, 0.98;
        text="$(failed_count) failed samples excluded from correlation",
        space=:relative, align=(:right, :top), color=_AMBER_COLORS.invalid, fontsize=11)
    PlotHandle(slot, (correlation=axis,),
        (correlation=plot, outliers=outlier_plot),
        (parameter=x, metric=y, samples=indices, outliers=outlier_indices))
end

function _linear_alignment(source_x, source_y, target_x)
    issorted(source_x) || throw(ArgumentError("comparison axes must be sorted"))
    length(unique(source_x)) == length(source_x) ||
        throw(ArgumentError("comparison axes must not contain duplicate values"))
    output = fill(NaN, length(target_x))
    for (index, x) in enumerate(target_x)
        first(source_x) <= x <= last(source_x) || continue
        upper = searchsortedfirst(source_x, x)
        if upper == 1 || source_x[upper] == x
            output[index] = source_y[upper]
        else
            lower = upper - 1
            fraction = (x - source_x[lower]) / (source_x[upper] - source_x[lower])
            output[index] = source_y[lower] + fraction * (source_y[upper] - source_y[lower])
        end
    end
    output
end

function _tolerance_values(reference, tolerance)
    tolerance === nothing && return nothing
    if tolerance isa Real
        tolerance >= 0 || throw(ArgumentError("tolerance must be non-negative"))
        return fill(Float64(tolerance), length(reference))
    elseif tolerance isa NamedTuple && haskey(tolerance, :atol) && haskey(tolerance, :rtol)
        tolerance.atol >= 0 && tolerance.rtol >= 0 ||
            throw(ArgumentError("atol and rtol must be non-negative"))
        return Float64(tolerance.atol) .+ Float64(tolerance.rtol) .* abs.(reference)
    end
    throw(ArgumentError("tolerance must be a non-negative number or (; atol, rtol)"))
end

function compareplot(position, results; signals, alignment=:strict, delta=:absolute,
        tolerance=nothing, kwargs...)
    alignment in (:strict, :interpolate) || throw(ArgumentError("alignment must be :strict or :interpolate"))
    delta in (:absolute, :relative) || throw(ArgumentError("delta must be :absolute or :relative"))
    result_list = collect(results); isempty(result_list) && throw(ArgumentError("results must not be empty"))
    signal_list = signals isa AbstractVector || signals isa Tuple ? collect(signals) : [signals]
    isempty(signal_list) && throw(ArgumentError("signals must not be empty"))
    reference_axis = first(result_list).axis
    alignment === :strict && any(result -> result.axis != reference_axis, result_list) &&
        throw(ArgumentError("strict comparison requires identical axes"))
    slot = _position(position); layout = Makie.GridLayout(slot)
    axis = Makie.Axis(layout[1, 1]; ylabel="Value")
    delta_axis = Makie.Axis(layout[2, 1]; xlabel="Axis",
        ylabel=delta === :absolute ? "Δ" : "Relative Δ")
    Makie.linkxaxes!(axis, delta_axis)
    overlay_plots, delta_plots = Any[], Any[]
    aligned = Dict{Tuple{Int,Any},Vector{Float64}}()
    diagnostics = NamedTuple[]
    for signal in signal_list
        reference = Float64.(real.(Amber.trace(first(result_list), signal)))
        allowed = _tolerance_values(reference, tolerance)
        if allowed !== nothing
            displayed_allowed = delta === :absolute ? allowed :
                [reference[index] == 0 ? NaN : allowed[index] / abs(reference[index])
                    for index in eachindex(reference)]
            Makie.band!(delta_axis, reference_axis, -displayed_allowed, displayed_allowed;
                color=(_AMBER_COLORS.nominal, 0.15))
        end
        for (ri, result) in enumerate(result_list)
            raw = Float64.(real.(Amber.trace(result, signal)))
            values = alignment === :strict || result.axis == reference_axis ? raw :
                _linear_alignment(result.axis, raw, reference_axis)
            aligned[(ri, signal)] = values
            difference = values .- reference
            displayed_delta = delta === :absolute ? difference :
                [reference[index] == 0 ? NaN : difference[index] / abs(reference[index])
                    for index in eachindex(reference)]
            valid = findall(isfinite, difference)
            mismatch = allowed === nothing ? Int[] :
                [index for index in valid if abs(difference[index]) > allowed[index]]
            push!(diagnostics, (result=ri, signal, compared=length(valid),
                outside_domain=length(reference) - length(valid), mismatches=length(mismatch),
                maximum_delta=isempty(valid) ? NaN : maximum(abs, difference[valid])))
            push!(overlay_plots, Makie.lines!(axis, reference_axis, values;
                label="$(signal) [$(ri)]", kwargs...))
            ri == 1 || push!(delta_plots, Makie.lines!(delta_axis, reference_axis,
                displayed_delta; label="$(signal) [$(ri)]"))
            isempty(mismatch) || Makie.scatter!(delta_axis, reference_axis[mismatch],
                displayed_delta[mismatch]; color=_AMBER_COLORS.invalid, marker=:x)
        end
    end
    Makie.axislegend(axis)
    PlotHandle(layout, (comparison=axis, delta=delta_axis),
        (overlays=overlay_plots, deltas=delta_plots),
        (results=result_list, axis=reference_axis, aligned, diagnostics,
            alignment, delta, tolerance))
end

function yieldplot(position, result::Amber.MonteCarloResult; predicate=nothing,
        limits=nothing, metric=:value, kwargs...)
    predicate === nothing && limits === nothing &&
        throw(ArgumentError("yieldplot requires predicate or limits"))
    if limits !== nothing
        low, high = Float64(first(limits)), Float64(last(limits))
        low <= high || throw(ArgumentError("yield limits must be increasing"))
        predicate === nothing && (predicate = value -> value isa Real && low <= value <= high)
    end
    view = ensembleview(result); indices, values = _numeric_successes(view)
    isempty(values) && throw(ArgumentError("ensemble has no successful scalar values"))
    passed = [predicate(value) for value in values]
    slot = _position(position); axis = Makie.Axis(slot; xlabel="Sample", ylabel=string(metric))
    limits === nothing || Makie.band!(axis, [first(indices), last(indices)],
        fill(Float64(first(limits)), 2), fill(Float64(last(limits)), 2);
        color=(_AMBER_COLORS.nominal, 0.15))
    plot = Makie.scatter!(axis, indices, values;
        color=ifelse.(passed, _AMBER_COLORS.nominal, _AMBER_COLORS.invalid), kwargs...)
    interval = Amber.yield_confidence_interval(result, predicate)
    rate = Amber.yield_rate(result, predicate)
    Makie.text!(axis, 0.98, 0.98; space=:relative, align=(:right, :top),
        text="Yield $(round(100rate; digits=1))%\n$(round(100first(interval); digits=1))–$(round(100last(interval); digits=1))% CI")
    PlotHandle(slot, (yield=axis,), (samples=plot,),
        (samples=indices, values, passed, rate, confidence_interval=interval, limits))
end

function failureplot(position, result::Union{Amber.SweepResult,Amber.MonteCarloResult}; kwargs...)
    failures = result.failures
    counts = Dict{Symbol,Int}()
    for failure in failures
        kind = result isa Amber.SweepResult ? failure.error_type : failure.exception_type
        counts[kind] = get(counts, kind, 0) + 1
    end
    ranked = sort!(collect(counts); by=last, rev=true)
    labels = isempty(ranked) ? ["none"] : string.(first.(ranked))
    values = isempty(ranked) ? [0] : last.(ranked)
    slot = _position(position); axis = Makie.Axis(slot; xlabel="Failures",
        yticks=(eachindex(labels), labels), ylabel="Error type")
    plot = Makie.barplot!(axis, eachindex(values), values; direction=:x,
        color=_AMBER_COLORS.invalid, kwargs...)
    PlotHandle(slot, (failures=axis,), (failures=plot,),
        (failures=copy(failures), labels, counts=values))
end

function _pearson(x, y)
    length(x) > 1 || return NaN
    xcentered = x .- sum(x) / length(x); ycentered = y .- sum(y) / length(y)
    denominator = sqrt(sum(abs2, xcentered) * sum(abs2, ycentered))
    denominator == 0 ? NaN : sum(xcentered .* ycentered) / denominator
end

function _tied_ranks(values)
    order = sortperm(values)
    ranks = zeros(Float64, length(values))
    first_index = 1
    while first_index <= length(order)
        last_index = first_index
        while last_index < length(order) &&
                values[order[last_index + 1]] == values[order[first_index]]
            last_index += 1
        end
        rank = (first_index + last_index) / 2
        ranks[order[first_index:last_index]] .= rank
        first_index = last_index + 1
    end
    ranks
end

"""Spearman rank correlation with average ranks for ties."""
function rank_correlation(x::AbstractVector, y::AbstractVector)
    length(x) == length(y) || throw(DimensionMismatch("correlation vectors differ in length"))
    length(x) > 1 || return NaN
    all(isfinite, x) && all(isfinite, y) ||
        throw(ArgumentError("rank correlation requires finite values"))
    _pearson(_tied_ranks(x), _tied_ranks(y))
end

function parametermatrixplot(position, result::Amber.MonteCarloResult;
        parameters=nothing, include_metric=true, metric=:value,
        correlation=:spearman, kwargs...)
    correlation in (:spearman, :pearson) ||
        throw(ArgumentError("correlation must be :spearman or :pearson"))
    available_set = Set{Symbol}()
    foreach(draw -> union!(available_set, Base.keys(draw)), result.parameters)
    available = sort!(collect(available_set); by=string)
    selected_keys = parameters === nothing ? available : Symbol.(collect(parameters))
    isempty(selected_keys) && throw(ArgumentError("no stored Monte Carlo parameters are available"))
    indices = [index for index in eachindex(result.values) if result.converged[index] &&
        (!include_metric || result.values[index] isa Real) &&
        all(key -> haskey(result.parameters[index], key), selected_keys)]
    length(indices) >= 2 || throw(ArgumentError("at least two complete successful samples are required"))
    columns = [Float64[result.parameters[index][key] for index in indices] for key in selected_keys]
    labels = string.(selected_keys)
    if include_metric
        push!(columns, Float64[result.values[index] for index in indices]); push!(labels, string(metric))
    end
    correlate = correlation === :spearman ? rank_correlation : _pearson
    matrix = [correlate(columns[row], columns[column])
        for row in eachindex(columns), column in eachindex(columns)]
    slot = _position(position); axis = Makie.Axis(slot;
        xticks=(eachindex(labels), labels), yticks=(eachindex(labels), labels),
        xaxisposition=:top, aspect=Makie.DataAspect())
    plot = Makie.heatmap!(axis, matrix; colorrange=(-1, 1), kwargs...)
    Makie.Colorbar(slot[1, 2], plot;
        label=correlation === :spearman ? "Spearman rank correlation" : "Pearson correlation")
    PlotHandle(slot, (parameter_matrix=axis,), (parameter_matrix=plot,),
        (parameters=selected_keys, labels, samples=indices, correlations=matrix,
            correlation))
end

function sampleplot(position, result::Amber.MonteCarloResult, sample::Integer; kwargs...)
    checkbounds(result.values, sample)
    parameters = sort!(collect(result.parameters[sample]); by=pair -> string(first(pair)))
    labels = string.(first.(parameters)); values = Float64.(last.(parameters))
    isempty(values) && throw(ArgumentError("sample $(sample) has no stored parameters"))
    slot = _position(position); axis = Makie.Axis(slot; xticks=(eachindex(labels), labels),
        ylabel="Sampled value", title="Sample $(sample), seed $(result.seeds[sample])")
    plot = Makie.barplot!(axis, eachindex(values), values;
        color=result.converged[sample] ? _AMBER_COLORS.nominal : _AMBER_COLORS.invalid,
        kwargs...)
    PlotHandle(slot, (sample=axis,), (parameters=plot,),
        (sample=Int(sample), seed=result.seeds[sample], converged=result.converged[sample],
            metric=result.values[sample], parameters=Dict(parameters)))
end

function _sweep_curve(result::Amber.SweepResult)
    indices = [index for index in eachindex(result.metrics)
        if result.converged[index] && result.parameter_values[index] isa Real &&
            result.metrics[index] isa Real]
    length(indices) >= 2 || throw(ArgumentError(
        "transfer characteristic requires at least two successful scalar points"))
    order = sortperm(Float64[result.parameter_values[index] for index in indices])
    selected = indices[order]
    Float64[result.parameter_values[index] for index in selected],
        Float64[result.metrics[index] for index in selected], selected
end

function _finite_derivative(x, y)
    length(x) == length(y) || throw(DimensionMismatch("transfer axes differ in length"))
    length(x) >= 2 || throw(ArgumentError("derivative requires at least two points"))
    all(>(0), diff(x)) || throw(ArgumentError("transfer input values must be unique"))
    derivative = similar(y)
    derivative[1] = (y[2] - y[1]) / (x[2] - x[1])
    derivative[end] = (y[end] - y[end - 1]) / (x[end] - x[end - 1])
    for index in 2:length(x)-1
        left = x[index] - x[index - 1]; right = x[index + 1] - x[index]
        derivative[index] = -right / (left * (left + right)) * y[index - 1] +
            (right - left) / (left * right) * y[index] +
            left / (right * (left + right)) * y[index + 1]
    end
    derivative
end

function transfercharacteristicplot(position, forward::Amber.SweepResult;
        reverse=nothing, input_label=forward.selector, output_label=:value, kwargs...)
    x, y, samples = _sweep_curve(forward)
    derivative = _finite_derivative(x, y)
    reverse_values = nothing; hysteresis = nothing
    if reverse !== nothing
        reverse isa Amber.SweepResult || throw(ArgumentError("reverse must be a SweepResult"))
        reverse_x, reverse_y, _ = _sweep_curve(reverse)
        reverse_values = _linear_alignment(reverse_x, reverse_y, x)
        all(isfinite, reverse_values) || throw(ArgumentError(
            "forward and reverse sweep domains must overlap completely"))
        hysteresis = y .- reverse_values
    end
    slot = _position(position); layout = Makie.GridLayout(slot)
    transfer_axis = Makie.Axis(layout[1, 1]; ylabel=string(output_label))
    derivative_axis = Makie.Axis(layout[2, 1]; xlabel=String(input_label),
        ylabel="d$(output_label)/d$(input_label)")
    Makie.linkxaxes!(transfer_axis, derivative_axis)
    forward_plot = Makie.lines!(transfer_axis, x, y; label="forward", kwargs...)
    reverse_plot = reverse_values === nothing ? nothing :
        Makie.lines!(transfer_axis, x, reverse_values; label="reverse", linestyle=:dash)
    reverse_values === nothing || Makie.axislegend(transfer_axis)
    derivative_plot = Makie.lines!(derivative_axis, x, derivative;
        color=_AMBER_COLORS.input)
    hysteresis_plot = hysteresis === nothing ? nothing :
        Makie.band!(transfer_axis, x, min.(y, reverse_values), max.(y, reverse_values);
            color=(_AMBER_COLORS.warning, 0.16))
    PlotHandle(layout, (transfer=transfer_axis, derivative=derivative_axis),
        (forward=forward_plot, reverse=reverse_plot, derivative=derivative_plot,
            hysteresis=hysteresis_plot),
        (input=x, output=y, derivative, reverse=reverse_values, hysteresis, samples))
end

function sensitivityplot(position, sensitivities::AbstractDict; top=20,
        metric=:value, kwargs...)
    top >= 1 || throw(ArgumentError("top must be positive"))
    entries = Pair{String,Float64}[]
    for (name, value) in pairs(sensitivities)
        value isa Real || throw(ArgumentError("sensitivity values must be real"))
        isfinite(value) || throw(ArgumentError("sensitivity values must be finite"))
        push!(entries, string(name) => Float64(value))
    end
    isempty(entries) && throw(ArgumentError("sensitivities must not be empty"))
    sort!(entries; by=pair -> abs(last(pair)), rev=true)
    resize!(entries, min(top, length(entries)))
    labels, values = first.(entries), last.(entries)
    slot = _position(position); axis = Makie.Axis(slot;
        xlabel="Sensitivity of $(metric)", ylabel="Parameter",
        yticks=(collect(eachindex(labels)), labels))
    colors = ifelse.(values .>= 0, _AMBER_COLORS.nominal, _AMBER_COLORS.invalid)
    plot = Makie.barplot!(axis, collect(eachindex(values)), values;
        direction=:x, color=colors, kwargs...)
    Makie.vlines!(axis, [0.0]; color=:gray45)
    PlotHandle(slot, (sensitivity=axis,), (sensitivity=plot,),
        (labels=labels, values=values, metric=metric))
end

function yieldmapplot(position, result::Amber.MonteCarloResult;
        x, y, predicate, bins=12, contours=true, kwargs...)
    xkey, ykey = Symbol(x), Symbol(y)
    xkey == ykey && throw(ArgumentError("yield-map parameters must differ"))
    nx, ny = bins isa Integer ? (Int(bins), Int(bins)) : (Int(first(bins)), Int(last(bins)))
    nx >= 2 && ny >= 2 || throw(ArgumentError("yield-map bins must be at least two"))
    indices = [index for index in eachindex(result.values)
        if haskey(result.parameters[index], xkey) && haskey(result.parameters[index], ykey)]
    isempty(indices) && throw(ArgumentError("no samples contain both yield-map parameters"))
    xvalues = Float64[result.parameters[index][xkey] for index in indices]
    yvalues = Float64[result.parameters[index][ykey] for index in indices]
    extrema(xvalues)[1] < extrema(xvalues)[2] ||
        throw(ArgumentError("yield-map x parameter is constant"))
    extrema(yvalues)[1] < extrema(yvalues)[2] ||
        throw(ArgumentError("yield-map y parameter is constant"))
    xedges = collect(range(minimum(xvalues), maximum(xvalues); length=nx + 1))
    yedges = collect(range(minimum(yvalues), maximum(yvalues); length=ny + 1))
    totals = zeros(Int, nx, ny); passed = zeros(Int, nx, ny)
    sample_bins = Dict{Int,Tuple{Int,Int}}()
    for (sample, xv, yv) in zip(indices, xvalues, yvalues)
        xi = clamp(searchsortedlast(xedges, xv), 1, nx)
        yi = clamp(searchsortedlast(yedges, yv), 1, ny)
        totals[xi, yi] += 1
        passed[xi, yi] += result.converged[sample] && predicate(result.values[sample])
        sample_bins[sample] = (xi, yi)
    end
    rates = [totals[xi, yi] == 0 ? NaN : passed[xi, yi] / totals[xi, yi]
        for xi in 1:nx, yi in 1:ny]
    xcenters = (xedges[1:end-1] .+ xedges[2:end]) ./ 2
    ycenters = (yedges[1:end-1] .+ yedges[2:end]) ./ 2
    slot = _position(position); layout = Makie.GridLayout(slot)
    axis = Makie.Axis(layout[1, 1]; xlabel=String(xkey), ylabel=String(ykey),
        title="Two-parameter yield map")
    heatmap = Makie.heatmap!(axis, xedges, yedges, rates;
        colorrange=(0, 1), colormap=:RdYlGn, kwargs...)
    contour_plot = nothing
    if contours && count(isfinite, rates) >= 4
        contour_plot = Makie.contour!(axis, xcenters, ycenters, rates;
            levels=[0.5, 0.9], color=:black, linewidth=1)
    end
    Makie.Colorbar(layout[1, 2], heatmap; label="Yield")
    PlotHandle(layout, (yield_map=axis,),
        (yield_map=heatmap, contours=contour_plot),
        (x=xcenters, y=ycenters, xedges, yedges, rates, totals, passed,
            samples=indices, sample_bins, parameters=(xkey, ykey)))
end
