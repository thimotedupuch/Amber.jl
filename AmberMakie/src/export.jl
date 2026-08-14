function _handle_figure(handle)
    handle isa WorkbenchHandle ? handle.figure : Makie.get_figure(handle.layout)
end

function _view_metadata(view)
    warnings = hasproperty(view, :warnings) ? String.(getproperty(view, :warnings)) : String[]
    provenance = hasproperty(view, :provenance) ? getproperty(view, :provenance) : Dict()
    warnings, provenance
end

function _axis_metadata(axes)
    output = Dict{String,Any}()
    for (name, axis) in pairs(axes)
        if axis isa Makie.Axis
            limits = axis.finallimits[]
            output[String(name)] = Dict(
                "x" => [Float64(limits.origin[1]),
                    Float64(limits.origin[1] + limits.widths[1])],
                "y" => [Float64(limits.origin[2]),
                    Float64(limits.origin[2] + limits.widths[2])])
        end
    end
    output
end

_metadata_value(value::Nothing) = "nothing"
_metadata_value(value::Union{Bool,Integer,AbstractFloat,String}) = value
_metadata_value(value::Symbol) = String(value)
_metadata_value(value::VersionNumber) = string(value)
_metadata_value(value::Complex) = Dict("real" => real(value), "imag" => imag(value))
_metadata_value(value::Pair) = Dict("first" => _metadata_value(first(value)),
    "last" => _metadata_value(last(value)))
_metadata_value(value::Tuple) = [_metadata_value(item) for item in value]
_metadata_value(value::NamedTuple) = Dict(String(key) => _metadata_value(item)
    for (key, item) in pairs(value))
_metadata_value(value::AbstractDict) = Dict(String(key) => _metadata_value(item)
    for (key, item) in pairs(value) if !(item isa Function))
_metadata_value(value::AbstractRange) = [_metadata_value(item) for item in value]
function _metadata_value(value::AbstractArray)
    ndims(value) <= 1 && return [_metadata_value(item) for item in value]
    ndims(value) == 2 && return [[_metadata_value(value[row, column])
        for column in axes(value, 2)] for row in axes(value, 1)]
    [_metadata_value(selectdim(value, 1, index)) for index in axes(value, 1)]
end
_metadata_value(value::Makie.Observable) = _metadata_value(value[])
function _metadata_value(value)
    if value isa Function
        return Dict("type" => string(typeof(value)), "serializable" => false)
    elseif hasproperty(value, :value) && getproperty(value, :value) isa Makie.Observable
        return Dict("type" => string(typeof(value)),
            "value" => _metadata_value(getproperty(value, :value)[]))
    elseif parentmodule(typeof(value)) === (@__MODULE__) && isstructtype(typeof(value))
        output = Dict{String,Any}("type" => string(nameof(typeof(value))))
        for field in fieldnames(typeof(value))
            output[String(field)] = _metadata_value(getfield(value, field))
        end
        return output
    end
    Dict("type" => string(typeof(value)))
end

function savefigure(path, handle::Union{PlotHandle,WorkbenchHandle}; include_metadata=true, kwargs...)
    figure = _handle_figure(handle)
    figure === nothing && throw(ArgumentError("plot handle is not attached to a figure"))
    Makie.save(path, figure; kwargs...)
    if include_metadata
        warnings, provenance = handle isa WorkbenchHandle ?
            (handle.warnings, handle.provenance) : _view_metadata(handle.view)
        measurements = handle isa WorkbenchHandle ? handle.measurements : Dict()
        sidecar = string(path, ".toml")
        open(sidecar, "w") do io
            document = Dict{String,Any}(
                "amber_makie_version" => "0.1.0",
                "handle_type" => string(nameof(typeof(handle))),
                "view_type" => string(nameof(typeof(handle isa WorkbenchHandle ?
                    handle.provenance : handle.view))),
                "warnings" => String.(warnings),
                "axis_limits" => _axis_metadata(handle.axes),
                "provenance" => _metadata_value(provenance),
                "measurements" => _metadata_value(measurements),
                "theme" => "current")
            TOML.print(io, document; sorted=true)
        end
    end
    path
end

function copyrecipe(handle::PlotHandle)
    view = handle.view
    call = if view isa SpectrumView
        "spectrumplot(position, result)"
    elseif view isa SpectrogramView
        "spectrogramplot(position, result; signal=$(repr(view.signal)), window=$(repr(view.window)), overlap=$(view.overlap))"
    elseif view isa NoiseView
        "noiseplot(position, result; referred=$(repr(view.referred)))"
    elseif view isa NoiseContributionView
        "noisecontributionplot(position, result; referred=$(repr(view.referred)), band=$(repr(view.band)))"
    elseif view isa NetworkView
        "networkplot(position, result; parameter=$(repr(view.parameter)), element=$(repr(view.element)))"
    elseif view isa TraceView
        "traceplot(position, result; signals=[signal]) # displayed as $(repr(view.label))"
    elseif view isa EyeDiagramView
        "eyediagramplot(position, result; signal=$(repr(view.signal)), period=$(view.period), unit_intervals=$(view.unit_intervals))"
    elseif view isa OperatingPointView
        "operatingpointplot(position, result)"
    elseif view isa NamedTuple && haskey(view, :alignment) && haskey(view, :delta)
        "compareplot(position, results; signals, alignment=$(repr(view.alignment)), delta=$(repr(view.delta)), tolerance=$(repr(view.tolerance)))"
    elseif view isa NamedTuple && haskey(view, :jitter) && haskey(view, :kind)
        jitter = view.jitter
        "jitterplot(position, result; signal=$(repr(jitter.signal)), nominal_period=$(jitter.nominal_period), threshold=$(jitter.threshold), edge=$(repr(jitter.edge)), kind=$(repr(view.kind)))"
    else
        nothing
    end
    call === nothing && return "# No self-contained copy recipe is available for $(nameof(typeof(view))); retain the original data arguments."
    "handle = $(call)$(_axis_recipe(handle.axes))$(_style_recipe(handle.plots))"
end

function _axis_recipe(axes; handle_name="handle")
    lines = String[]
    for (name, axis) in pairs(axes)
        axis isa Makie.Axis || continue
        limits = axis.finallimits[]
        xmin, ymin = limits.origin
        xmax, ymax = limits.origin .+ limits.widths
        push!(lines, "Makie.xlims!($(handle_name).axes.$(name), $(repr(xmin)), $(repr(xmax)))")
        push!(lines, "Makie.ylims!($(handle_name).axes.$(name), $(repr(ymin)), $(repr(ymax)))")
    end
    isempty(lines) ? "" : "\n" * join(lines, "\n")
end

function _style_recipe!(lines, value, expression)
    visible = _plot_observable(value, :visible)
    if visible !== nothing
        push!(lines, "$(expression).visible[] = $(repr(visible[]))")
        for attribute in (:color, :linestyle, :linewidth, :marker, :markersize)
            observable = _plot_observable(value, attribute)
            observable === nothing && continue
            setting = observable[]
            setting isa Union{Nothing,Bool,Number,Symbol,String,Tuple} || continue
            push!(lines, "$(expression).$(attribute)[] = $(repr(setting))")
        end
    elseif value isa NamedTuple
        for (name, child) in pairs(value)
            _style_recipe!(lines, child, string(expression, ".", name))
        end
    elseif value isa AbstractDict
        for (name, child) in pairs(value)
            _style_recipe!(lines, child, string(expression, "[", repr(name), "]"))
        end
    elseif value isa AbstractVector
        for (index, child) in pairs(value)
            _style_recipe!(lines, child, string(expression, "[", index, "]"))
        end
    end
    lines
end

function _style_recipe(plots)
    lines = _style_recipe!(String[], plots, "handle.plots")
    isempty(lines) ? "" : "\n" * join(lines, "\n")
end

function _workbench_constructor(handle)
    kwargs = get(handle.measurements, :copyrecipe_kwargs, Dict{Symbol,String}())
    isempty(kwargs) && return "handle = workbench(result)"
    rendered = join(("$(name)=$(code)" for (name, code) in pairs(kwargs)), ", ")
    "handle = workbench(result; $(rendered))"
end

function copyrecipe(handle::WorkbenchHandle)
    cursor = handle.cursors === nothing ? "" :
        "\nsetcursor!(handle.cursors, :a, $(handle.cursors.a[]))\nsetcursor!(handle.cursors, :b, $(handle.cursors.b[]))\nsetinterval!(handle.cursors, $(repr(handle.cursors.interval[])))"
    selectors = String[]
    if haskey(handle.measurements, :selected_sample)
        push!(selectors, "selectsample!(handle, $(handle.measurements[:selected_sample][]))")
    elseif haskey(handle.measurements, :selected)
        push!(selectors, "selectcomponent!(handle, $(repr(handle.measurements[:selected][])))")
    end
    for key in (:selected_order, :selected_sideband, :mode_index,
            :selected_input, :selected_output, :selected_parameter, :selected_element,
            :selected_state)
        haskey(handle.measurements, key) || continue
        push!(selectors, "handle.measurements[$(repr(key))][] = $(repr(handle.measurements[key][]))")
    end
    haskey(handle.measurements, :selected_signal) &&
        push!(selectors, "selectsignal!(handle, $(repr(handle.measurements[:selected_signal][])))")
    isolated = get(handle.measurements, :isolated_trace, nothing)
    isolated === nothing || isolated[] === nothing ||
        push!(selectors, "isolatetrace!(handle, $(repr(isolated[])))")
    selection_recipe = isempty(selectors) ? "" : "\n" * join(selectors, "\n")
    "$(_workbench_constructor(handle))$(selection_recipe)$(cursor)" *
        "$(_axis_recipe(handle.axes))$(_style_recipe(handle.plots))"
end

function _report_template(result, template)
    template !== :auto && return Symbol(template)
    result isa Amber.NoiseResult && return :noise
    result isa Amber.SpectrumResult && return :spectrum
    result isa Amber.PSSResult && return :stability
    result isa Amber.NetworkResult && return :network
    result isa Amber.LoopGainResult && return :stability
    result isa Amber.SimulationResult && result.analysis isa Union{Amber.Transient,Amber.TransientNoise} && return :transient
    result isa Amber.SimulationResult && result.analysis isa Amber.SmallSignal && return :frequency
    throw(ArgumentError("no automatic report template is available for $(typeof(result))"))
end

function _report_metrics(result)
    if result isa Amber.NoiseResult
        variance = _band_variance(result.frequencies, result.output_psd,
            first(result.frequencies), last(result.frequencies))
        return (frequency_points=length(result.frequencies),
            integrated_noise_rms=sqrt(max(variance, 0.0)),
            frequency_start=first(result.frequencies), frequency_stop=last(result.frequencies))
    elseif result isa Amber.SpectrumResult
        return (signal_rms=result.signal_rms, signal_peak=result.signal_peak,
            crest_factor=Amber.crest_factor(result), sample_rate=result.sample_rate,
            window=result.window)
    elseif result isa Amber.PSSResult
        return (period=result.period, closure_residual=result.residual_norm,
            iterations=result.iterations,
            unstable_multipliers=count(>(1 + sqrt(eps(Float64))), abs.(result.floquet_multipliers)))
    elseif result isa Amber.NetworkResult
        return (ports=length(result.ports), frequency_points=length(result.frequencies),
            frequency_start=first(result.frequencies), frequency_stop=last(result.frequencies))
    elseif result isa Amber.LoopGainResult
        return (gain_margin_db=result.margins.gain_margin,
            phase_margin_degrees=result.margins.phase_margin,
            gain_crossover=result.margins.gain_crossover,
            phase_crossover=result.margins.phase_crossover)
    elseif result isa Amber.SimulationResult
        return (points=length(result.axis), axis_start=first(result.axis),
            axis_stop=last(result.axis), converged=get(result.stats, :converged, true),
            iterations=get(result.stats, :iterations, nothing))
    end
    NamedTuple()
end

function _report_value(value)
    value === nothing && return "n/a"
    value isa Bool && return value ? "yes" : "no"
    value isa Real && return engineering(value)
    string(value)
end

function _report_metric_text(metrics)
    join(("$(replace(titlecase(String(key)), '_' => ' ')): $(_report_value(value))"
        for (key, value) in pairs(metrics)), "   ")
end

function _report_provenance_text(provenance)
    version = get(provenance, :amber_version, get(provenance, "amber_version", "unknown"))
    fingerprint = get(provenance, :topology_fingerprint,
        get(provenance, :design_fingerprint, get(provenance, "topology_fingerprint", "n/a")))
    "Amber $(version) · topology $(fingerprint)"
end

_provenance_get(provenance, key, default=nothing) =
    get(provenance, key, get(provenance, String(key), default))

function _report_metric_table(position, metrics)
    grid = Makie.GridLayout(position)
    labels = Any[]
    push!(labels, Makie.Label(grid[1, 1:6], "Measurements";
        halign=:left, fontsize=11, font=:bold))
    for (index, (key, value)) in enumerate(pairs(metrics))
        row = 1 + cld(index, 3)
        column = 2mod(index - 1, 3) + 1
        name = replace(titlecase(String(key)), '_' => ' ')
        push!(labels, Makie.Label(grid[row, column], name;
            halign=:left, fontsize=9, color=:gray45))
        push!(labels, Makie.Label(grid[row, column + 1], _report_value(value);
            halign=:left, fontsize=10, font=:bold, color=:gray20))
    end
    (layout=grid, labels)
end

function _report_annotation(template, result; input=nothing, output=nothing,
        parameter=:s, element=(2, 1))
    if template === :noise
        return "Integrated over $(engineering(first(result.frequencies); unit="Hz"))–$(engineering(last(result.frequencies); unit="Hz")); component ranking uses variance over the same band."
    elseif template === :spectrum
        return "$(uppercase(String(result.window))) window · $(engineering(result.sample_rate; unit="Sa/s")) sample rate · RMS and PSD views share FFT bins."
    elseif template === :transient
        return "Time-domain traces and spectrogram use the same stored simulation samples."
    elseif template === :frequency
        return "Transfer $(output) / $(input); Bode and Nyquist panels use the same complex response."
    elseif template === :network
        return "$(uppercase(String(parameter)))$(element[1])$(element[2]) over $(length(result.frequencies)) frequency points; Smith panel displays the corresponding S element."
    elseif template === :stability && result isa Amber.PSSResult
        return "Periodic orbit closure and Floquet multipliers; the unit circle is the stability boundary."
    elseif template === :stability
        return "Loop-gain margins and Nyquist contour share the evaluated frequency grid."
    end
    ""
end

function _report_provenance_block(position, provenance, template, warnings)
    grid = Makie.GridLayout(position)
    version = _provenance_get(provenance, :amber_version, "unknown")
    fingerprint = _provenance_get(provenance, :topology_fingerprint,
        _provenance_get(provenance, :design_fingerprint, "n/a"))
    analysis = _provenance_get(provenance, :analysis, titlecase(String(template)))
    units = _provenance_get(provenance, :unit_system, :SI)
    header = Makie.Label(grid[1, 1:4], "Provenance";
        halign=:left, fontsize=10, font=:bold)
    entries = [("Amber", version), ("Analysis", analysis),
        ("Topology", fingerprint), ("Units", units),
        ("Warnings", length(warnings))]
    labels = Any[header]
    for (index, (name, value)) in enumerate(entries)
        push!(labels, Makie.Label(grid[2, index], "$(name): $(value)";
            halign=:left, fontsize=8, color=:gray45))
    end
    (layout=grid, labels)
end

function reportfigure(result; template=:auto, signals=nothing, signal=nothing,
        input=nothing, output=nothing, parameter=:s, element=(2, 1),
        size=(1100, 760), theme=theme_amber_publication())
    selected = _report_template(result, template)
    Makie.with_theme(theme) do
        figure = Makie.Figure(; size)
        title = Makie.Label(figure[1, 1], "Amber · $(titlecase(String(selected))) report";
            fontsize=18, halign=:left)
        layout = Makie.GridLayout(figure[2, 1])
        handles = PlotHandle[]
        if selected === :noise && result isa Amber.NoiseResult
            push!(handles, noiseplot(layout[1, 1], result))
            push!(handles, integratednoiseplot(layout[2, 1], result))
            push!(handles, noisecontributionplot(layout[1:2, 2], result; group=:component))
        elseif selected === :spectrum && result isa Amber.SpectrumResult
            push!(handles, spectrumplot(layout[1, 1], result; scale=:dbv))
            push!(handles, spectrumplot(layout[2, 1], result; scale=:psd))
        elseif selected === :transient && result isa Amber.SimulationResult
            signals === nothing && throw(ArgumentError("transient report requires signals"))
            chosen = signal === nothing ? (signals isa AbstractVector || signals isa Tuple ? first(signals) : signals) : signal
            push!(handles, traceplot(layout[1, 1], result; signals))
            push!(handles, spectrogramplot(layout[2, 1], result; signal=chosen,
                samples=min(256, length(result.axis))))
        elseif selected === :frequency && result isa Amber.SimulationResult
            input === nothing && throw(ArgumentError("frequency report requires input"))
            output === nothing && throw(ArgumentError("frequency report requires output"))
            push!(handles, bodeplot(layout[1:2, 1], result; input, output))
            view = frequencyview(result; input, output)
            push!(handles, nyquistplot(layout[1:2, 2], view))
        elseif selected === :stability && result isa Amber.LoopGainResult
            push!(handles, marginplot(layout[1:2, 1], result))
            push!(handles, nyquistplot(layout[1:2, 2], result))
        elseif selected === :stability && result isa Amber.PSSResult
            signals === nothing && throw(ArgumentError("PSS report requires signals"))
            push!(handles, pssplot(layout[1, 1], result; signals))
        elseif selected === :network && result isa Amber.NetworkResult
            push!(handles, networkplot(layout[1:2, 1], result; parameter, element))
            push!(handles, smithplot(layout[1:2, 2], result; element))
        else
            throw(ArgumentError("template $(selected) does not support $(typeof(result))"))
        end
        metrics = _report_metrics(result)
        provenance = try Dict(Amber.provenance(result)) catch; Dict() end
        warnings = String.(_provenance_get(provenance, :warnings, String[]))
        metric_table = _report_metric_table(figure[3, 1], metrics)
        annotation_text = _report_annotation(selected, result; input, output,
            parameter, element)
        annotation = Makie.Label(figure[4, 1], annotation_text;
            halign=:left, fontsize=9, color=:gray35)
        provenance_block = _report_provenance_block(figure[5, 1], provenance,
            selected, warnings)
        PlotHandle(figure, (report=layout, metrics=metric_table.layout,
                provenance=provenance_block.layout),
            (title=title, sections=handles, metric_labels=metric_table.labels,
                annotation=annotation, provenance_labels=provenance_block.labels),
            (template=selected, result_type=string(typeof(result)), metrics, warnings,
                provenance, metric_table, annotation_text, provenance_block))
    end
end
