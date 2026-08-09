function _workbench_figure()
    Makie.Figure(size=(1000, 700))
end

function _primary_view(handle)
    view = handle.view isa AbstractVector ? first(handle.view) : handle.view
    view isa TraceView && return view.axis, real.(view.values), view
    view isa FrequencyView && return view.frequencies, 20 .* log10.(abs.(view.response)), view
    view isa SpectrumView && return view.frequencies, view.amplitude_rms, view
    view isa NoiseView && return view.frequencies, view.density, view
    view isa NetworkView && return view.frequencies, abs.(view.values), view
    nothing
end

function _workbench_handle(figure, handle)
    selection = Makie.Observable(Symbol[])
    primary = _primary_view(handle)
    primary === nothing && return WorkbenchHandle(figure, handle.axes, handle.plots,
        selection, nothing, Dict{Symbol,Any}(), String[], Dict(), () -> nothing, false)
    x, y, view = primary
    cursors = CursorState(x, y)
    foreach(axis -> _cursor_axis!(axis, cursors, x), values(handle.axes))
    Makie.Label(figure[1, 2], "Measurement interval"; halign=:left)
    interval_slider = Makie.IntervalSlider(figure[2, 2]; range=x, startvalues=(first(x), last(x)))
    push!(cursors.subscriptions, Makie.on(interval_slider.interval) do bounds
        setinterval!(cursors, first(bounds) => last(bounds))
    end)
    cursor_text = Makie.lift(cursors.readout) do measurement
        "A: $(engineering(measurement.a.x))\nB: $(engineering(measurement.b.x))\nΔx: $(engineering(measurement.delta_x))\nΔy: $(engineering(real(measurement.delta_y)))"
    end
    interval_text = Makie.lift(cursors.interval_readout) do measurement
        "RMS: $(engineering(measurement.rms))\nMean: $(engineering(measurement.mean))\nPeak-to-peak: $(engineering(measurement.peak_to_peak))"
    end
    Makie.Label(figure[3, 2], cursor_text; halign=:left, justification=:left)
    Makie.Label(figure[4, 2], interval_text; halign=:left, justification=:left)
    warning_text = isempty(view.warnings) ? "No warnings" : "Warnings\n" * join(view.warnings, "\n")
    Makie.Label(figure[5, 2], warning_text; halign=:left, justification=:left,
        color=isempty(view.warnings) ? :gray40 : _AMBER_COLORS.warning)
    inspector = Makie.DataInspector(figure)
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout, :interval => cursors.interval_readout)
    cleanup = () -> begin
        _close!(cursors)
        delete!(figure, inspector)
    end
    WorkbenchHandle(figure, handle.axes, handle.plots, selection, cursors, measurements,
        copy(view.warnings), copy(view.provenance), cleanup, false)
end

function workbench(result::Amber.SimulationResult; signals=nothing, input=nothing, output=nothing, view=:auto)
    figure = _workbench_figure()
    if result.analysis isa Union{Amber.Transient,Amber.TransientNoise}
        signals === nothing && throw(ArgumentError("transient workbench requires `signals`"))
        handle = traceplot(figure[1:5, 1], result; signals)
    elseif result.analysis isa Amber.SmallSignal
        (input === nothing || output === nothing) &&
            throw(ArgumentError("small-signal workbench requires `input` and `output`"))
        handle = bodeplot(figure[1:5, 1], result; input, output)
    else
        throw(ArgumentError("no workbench is available for $(typeof(result.analysis))"))
    end
    _workbench_handle(figure, handle)
end

function workbench(result::Amber.SpectrumResult; view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, spectrumplot(figure[1:5, 1], result))
end

function workbench(result::Amber.HarmonicResult; view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, harmonicplot(figure[1:5, 1], result))
end

function workbench(result::Amber.NoiseResult; referred=:output, view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, noiseplot(figure[1:5, 1], result; referred))
end

function workbench(result::Amber.NetworkResult; parameter=:s, element=(2, 1), view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, networkplot(figure[1:5, 1], result; parameter, element))
end

function workbench(result::Amber.LoopGainResult; view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, marginplot(figure[1:5, 1], result))
end

function workbench(result::Amber.PSSResult; signals, view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, pssplot(figure[1:5, 1], result; signals))
end

function workbench(result::Amber.SweepResult; view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, sweepplot(figure[1:5, 1], result))
end

function workbench(result::Amber.MonteCarloResult; predicate=nothing, view=:auto)
    figure = _workbench_figure()
    _workbench_handle(figure, ensembleplot(figure[1:5, 1], result; predicate))
end
