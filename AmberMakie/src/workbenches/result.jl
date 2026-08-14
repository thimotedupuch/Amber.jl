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
    _contextualize!(WorkbenchHandle(figure, handle.axes, handle.plots, selection,
        cursors, measurements, copy(view.warnings), copy(view.provenance), cleanup,
        false))
end

function _operatingpoint_workbench(result::Amber.SimulationResult)
    view = operatingpointview(result)
    figure = Makie.Figure(size=(1200, 760))
    plot_handle = operatingpointplot(figure[1:5, 1], result)
    isempty(view.nodes) && isempty(view.devices) &&
        throw(ArgumentError("operating point contains no browsable nodes or devices"))
    initial = isempty(view.nodes) ? first(view.devices).name : first(view.nodes).name
    selected = Makie.Observable(initial)
    selection = Makie.Observable([Symbol(initial)])
    subscriptions = Any[]

    options = Tuple{String,String}[]
    append!(options, [("Node · $(row.name)", row.name) for row in view.nodes])
    append!(options, [("$(uppercase(String(row.kind))) · $(row.name)", row.name)
        for row in view.devices])
    Makie.Label(figure[1, 2], "Node / component browser"; halign=:left)
    menu = Makie.Menu(figure[2, 2]; options, default=1)
    push!(subscriptions, Makie.on(menu.selection) do value
        value === nothing || (selected[] = String(value))
    end)
    search = Makie.Textbox(figure[3, 2]; placeholder="Search nodes and components")
    search_results = Makie.lift(search.stored_string) do query
        filtered = operatingpointview(result; query)
        names = vcat(["V($(row.name))" for row in filtered.nodes],
            ["$(row.kind) · $(row.name)" for row in filtered.devices])
        isempty(names) ? "No matches" : join(first(names, min(12, length(names))), "\n")
    end
    Makie.Label(figure[4, 2], search_results; halign=:left, valign=:top,
        justification=:left)

    push!(subscriptions, Makie.on(selected) do name
        selection[] = [Symbol(name)]
    end)
    node_point = Makie.lift(selected) do name
        index = findfirst(row -> row.name == name, view.nodes)
        index === nothing ? [Makie.Point2f(NaN, NaN)] :
            [Makie.Point2f(index, view.nodes[index].voltage)]
    end
    powered = filter(row -> row.power !== nothing, view.devices)
    device_point = Makie.lift(selected) do name
        index = findfirst(row -> row.name == name, powered)
        index === nothing ? [Makie.Point2f(NaN, NaN)] :
            [Makie.Point2f(index, powered[index].power)]
    end
    node_highlight = Makie.scatter!(plot_handle.axes.nodes, node_point;
        color=_AMBER_COLORS.warning, marker=:diamond, markersize=16)
    device_highlight = Makie.scatter!(plot_handle.axes.devices, device_point;
        color=_AMBER_COLORS.warning, marker=:diamond, markersize=16)
    details = Makie.lift(selected) do name
        node = findfirst(row -> row.name == name, view.nodes)
        node === nothing || return "Node $(name)\nVoltage: $(engineering(view.nodes[node].voltage; unit="V"))"
        device = findfirst(row -> row.name == name, view.devices)
        device === nothing && return "$(name)"
        row = view.devices[device]
        current = row.current === nothing ? "unavailable" : engineering(row.current; unit="A")
        power = row.power === nothing ? "unavailable" : engineering(row.power; unit="W")
        region = row.region === nothing ? "n/a" : String(row.region)
        "$(uppercase(String(row.kind))) $(name)\nRegion: $(region)\nCurrent: $(current)\nPower: $(power)"
    end
    Makie.Label(figure[5, 2], details; halign=:left, justification=:left)
    convergence = view.convergence
    failed_steps = isempty(convergence.failed_steps) ? "none" :
        join(convergence.failed_steps, ", ")
    residual = convergence.dominant_residual === nothing ? "n/a" :
        "row $(convergence.dominant_residual.row), ‖r‖∞=$(engineering(convergence.dominant_residual.norm))"
    history = convergence.history_available ?
        "$(length(convergence.history)) retained samples" : "not retained by solver"
    convergence_text = "Convergence\nStatus: $(convergence.converged ? "converged" : "failed")\n" *
        "Strategy: $(something(convergence.strategy, "n/a"))\nIterations: $(something(convergence.iterations, "n/a"))\n" *
        "Continuation steps: $(something(convergence.continuation_steps, "n/a"))\nRejected steps: $(something(convergence.rejected_steps, "n/a"))\n" *
        "Failed steps: $(failed_steps)\nDominant residual: $(residual)\nHistory: $(history)"
    Makie.Label(figure[6, 2], convergence_text; halign=:left, justification=:left,
        color=convergence.converged ? :gray35 : _AMBER_COLORS.invalid)
    convergence_axis = Makie.Axis(figure[6:7, 1]; xlabel="Newton iteration",
        ylabel="Norm", yscale=log10, title="Operating-point convergence history")
    convergence_plots = Any[]
    if convergence.history_available && !isempty(convergence.history)
        iterations = getproperty.(convergence.history, :iteration)
        residuals = max.(getproperty.(convergence.history, :residual_norm), eps(Float64))
        updates = max.(getproperty.(convergence.history, :update_norm), eps(Float64))
        push!(convergence_plots, Makie.lines!(convergence_axis, iterations, residuals;
            label="Residual ‖r‖∞", color=_AMBER_COLORS.invalid))
        push!(convergence_plots, Makie.lines!(convergence_axis, iterations, updates;
            label="Update ‖Δx‖∞", color=_AMBER_COLORS.output, linestyle=:dash))
        Makie.axislegend(convergence_axis)
    else
        Makie.text!(convergence_axis, 0.5, 0.5;
            text="Iteration history was not retained", space=:relative,
            align=(:center, :center), color=:gray45)
    end
    inspector = Makie.DataInspector(figure)
    axes = merge(plot_handle.axes, (convergence=convergence_axis,))
    plots = merge(plot_handle.plots,
        (node_highlight=node_highlight, device_highlight=device_highlight,
            convergence=convergence_plots))
    measurements = Dict{Symbol,Any}(:selected => selected, :browser => menu,
        :search => search, :search_results => search_results,
        :selection_names => last.(options), :convergence => convergence)
    cleanup = () -> begin
        foreach(Makie.off, subscriptions)
        empty!(subscriptions)
        delete!(figure, inspector)
    end
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection, nothing,
        measurements, copy(view.warnings), copy(view.provenance), cleanup, false);
        help="Search nodes and components, then select one to link browser details and plot highlights.")
end

function _selector_values(value, values)
    choices = values === nothing ? [value] : collect(values)
    isempty(choices) && throw(ArgumentError("selector choices must not be empty"))
    value in choices || pushfirst!(choices, value)
    unique(choices)
end

function _smallsignal_workbench(result::Amber.SimulationResult; input, output,
        inputs=nothing, outputs=nothing)
    input_choices = _selector_values(input, inputs)
    output_choices = _selector_values(output, outputs)
    selected_input = Makie.Observable(input)
    selected_output = Makie.Observable(output)
    initial = frequencyview(result; input, output)
    frequencies = initial.frequencies
    response = Makie.Observable(ComplexF64.(initial.response))
    gain = Makie.lift(values -> 20log10.(abs.(values)), response)
    phase = Makie.lift(values -> rad2deg.(_unwrap(angle.(values))), response)

    figure = Makie.Figure(size=(1260, 780))
    magnitude_axis = _frequency_axis(figure[1:2, 1], frequencies;
        ylabel="Gain (dB)")
    phase_axis = _frequency_axis(figure[3:4, 1], frequencies;
        xlabel="Frequency (Hz)", ylabel="Phase (°)")
    Makie.linkxaxes!(magnitude_axis, phase_axis)
    nyquist_axis = Makie.Axis(figure[1:4, 2]; xlabel="Real", ylabel="Imaginary",
        aspect=Makie.DataAspect())
    # Both columns contain aspect-aware axes and menus, so Auto sizing follows
    # the controls' intrinsic widths and can collapse the plots. Reserve the
    # canvas explicitly for the Bode and Nyquist views.
    Makie.colsize!(figure.layout, 1, Makie.Relative(0.62))
    Makie.colsize!(figure.layout, 2, Makie.Relative(0.38))
    magnitude_plot = Makie.lines!(magnitude_axis, frequencies, gain)
    phase_plot = Makie.lines!(phase_axis, frequencies, phase)
    nyquist_plot = Makie.lines!(nyquist_axis,
        Makie.lift(values -> real.(values), response),
        Makie.lift(values -> imag.(values), response))
    critical = Makie.scatter!(nyquist_axis, [-1.0], [0.0]; marker=:x,
        color=_AMBER_COLORS.invalid)

    cursor_gain = copy(gain[])
    cursors = CursorState(frequencies, cursor_gain)
    _cursor_axis!(magnitude_axis, cursors, frequencies)
    _cursor_axis!(phase_axis, cursors, frequencies)
    cursor_indices = which -> Makie.lift(getproperty(cursors, which)) do frequency
        nearest_sample(frequencies, frequencies, frequency).index
    end
    index_a, index_b = cursor_indices(:a), cursor_indices(:b)
    point(index) = Makie.lift(index, response) do sample, values
        [Makie.Point2f(real(values[sample]), imag(values[sample]))]
    end
    marker_a = Makie.scatter!(nyquist_axis, point(index_a); color=_AMBER_COLORS.input,
        marker=:circle, markersize=14)
    marker_b = Makie.scatter!(nyquist_axis, point(index_b); color=_AMBER_COLORS.output,
        marker=:diamond, markersize=14)

    Makie.Label(figure[5, 1], "Input")
    input_menu = Makie.Menu(figure[6, 1];
        options=[(_signal_label(choice), choice) for choice in input_choices], default=1)
    Makie.Label(figure[5, 2], "Output")
    output_menu = Makie.Menu(figure[6, 2];
        options=[(_signal_label(choice), choice) for choice in output_choices], default=1)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(input_menu.selection) do choice
        choice === nothing || (selected_input[] = choice)
    end)
    push!(subscriptions, Makie.on(output_menu.selection) do choice
        choice === nothing || (selected_output[] = choice)
    end)
    append!(subscriptions, Makie.onany(selected_input, selected_output) do source, sink
        view = frequencyview(result; input=source, output=sink)
        response[] = ComplexF64.(view.response)
        copyto!(cursor_gain, gain[])
        cursors.readout[] = cursor_readout(frequencies, cursor_gain,
            cursors.a[], cursors.b[])
    end)
    push!(subscriptions, Makie.on(Makie.events(nyquist_axis).mousebutton;
            priority=10) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(nyquist_axis.scene) || return Makie.Consume(false)
        target = Makie.mouseposition(nyquist_axis)
        values = response[]
        index = argmin(abs2.(real.(values) .- target[1]) .+
            abs2.(imag.(values) .- target[2]))
        shifted = Makie.Keyboard.left_shift in Makie.events(nyquist_axis).keyboardstate ||
            Makie.Keyboard.right_shift in Makie.events(nyquist_axis).keyboardstate
        setcursor!(cursors, shifted ? :b : :a, frequencies[index])
        Makie.Consume(true)
    end)
    push!(subscriptions, Makie.on(Makie.events(figure).keyboardbutton) do event
        event.action in (Makie.Keyboard.press, Makie.Keyboard.repeat) || return
        current = nearest_sample(frequencies, frequencies, cursors.a[]).index
        if event.key == Makie.Keyboard.left
            setcursor!(cursors, :a, frequencies[max(1, current - 1)])
        elseif event.key == Makie.Keyboard.right
            setcursor!(cursors, :a, frequencies[min(length(frequencies), current + 1)])
        elseif event.key == Makie.Keyboard.home
            setcursor!(cursors, :a, first(frequencies))
            setcursor!(cursors, :b, last(frequencies))
            foreach(Makie.autolimits!, (magnitude_axis, phase_axis, nyquist_axis))
        end
    end)
    readout = Makie.lift(cursors.a, cursors.b, response) do a_frequency, b_frequency, values
        sample(frequency) = nearest_sample(frequencies, values, frequency)
        a, b = sample(a_frequency), sample(b_frequency)
        (a=(frequency=a.x, response=a.y, gain_db=20log10(abs(a.y)),
                phase_degrees=rad2deg(angle(a.y))),
            b=(frequency=b.x, response=b.y, gain_db=20log10(abs(b.y)),
                phase_degrees=rad2deg(angle(b.y))))
    end
    readout_text = Makie.lift(readout) do values
        line(label, item) = "$(label): $(engineering(item.frequency; unit="Hz")) · $(round(item.gain_db; digits=3)) dB · $(round(item.phase_degrees; digits=2))°"
        line("A", values.a) * "\n" * line("B", values.b) *
            "\n←/→ move A · Shift-click sets B · Home resets"
    end
    Makie.Label(figure[7, 1:2], readout_text; halign=:left, justification=:left)
    inspector = Makie.DataInspector(figure)
    measurements = Dict{Symbol,Any}(:selected_input => selected_input,
        :selected_output => selected_output, :input_choices => input_choices,
        :output_choices => output_choices, :frequency_readout => readout,
        :input_control => input_menu, :output_control => output_menu,
        :cursors => cursors.readout, :help =>
            "Click Bode/Nyquist to set A; Shift-click sets B; arrow keys move A; Home resets.",
        :copyrecipe_kwargs => Dict(:input => repr(input), :output => repr(output),
            :inputs => repr(input_choices), :outputs => repr(output_choices)))
    cleanup = () -> begin
        _close!(cursors); foreach(Makie.off, subscriptions); empty!(subscriptions)
        delete!(figure, inspector)
    end
    axes = (magnitude=magnitude_axis, phase=phase_axis, nyquist=nyquist_axis)
    plots = (magnitude=magnitude_plot, phase=phase_plot, nyquist=nyquist_plot,
        critical=critical, cursor_a=marker_a, cursor_b=marker_b)
    selection = Makie.lift(selected_input, selected_output) do source, sink
        [Symbol("$(sink)_over_$(source)")]
    end
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection, cursors,
        measurements, copy(initial.warnings), copy(initial.provenance), cleanup,
        false))
end

function workbench(result::Amber.SimulationResult; signals=nothing, input=nothing,
        output=nothing, inputs=nothing, outputs=nothing, view=:auto)
    result.analysis isa Amber.OperatingPoint && return _operatingpoint_workbench(result)
    if result.analysis isa Union{Amber.Transient,Amber.TransientNoise}
        figure = _workbench_figure()
        signals === nothing && throw(ArgumentError("transient workbench requires `signals`"))
        handle = traceplot(figure[1:5, 1], result; signals)
    elseif result.analysis isa Amber.SmallSignal
        (input === nothing || output === nothing) &&
            throw(ArgumentError("small-signal workbench requires `input` and `output`"))
        return _smallsignal_workbench(result; input, output, inputs, outputs)
    else
        throw(ArgumentError("no workbench is available for $(typeof(result.analysis))"))
    end
    workbench_handle = _workbench_handle(figure, handle)
    if result.analysis isa Union{Amber.Transient,Amber.TransientNoise}
        signal_choices = signals isa AbstractVector || signals isa Tuple ?
            collect(signals) : [signals]
        selected_signal = Makie.Observable{Any}(first(signal_choices))
        Makie.Label(figure[6, 2], "Signal selector"; halign=:left)
        signal_control = Makie.Menu(figure[7, 2];
            options=[(string(signal), signal) for signal in signal_choices], default=1)
        push!(workbench_handle.measurements[:control_subscriptions],
            Makie.on(signal_control.selection) do signal
                signal === nothing || (selected_signal[] = signal)
            end)
        push!(workbench_handle.measurements[:control_subscriptions],
            Makie.on(selected_signal) do signal
                index = findfirst(choice -> isequal(choice, signal), signal_choices)
                index === nothing && return
                foreach(eachindex(handle.plots)) do candidate
                    _plot_observable(handle.plots[candidate], :visible)[] =
                        candidate == index
                end
                workbench_handle.selection[] = [Symbol(string(signal))]
            end)
        workbench_handle.measurements[:selected_signal] = selected_signal
        workbench_handle.measurements[:signal_choices] = signal_choices
        workbench_handle.measurements[:signal_control] = signal_control
        workbench_handle.measurements[:copyrecipe_kwargs] =
            Dict(:signals => repr(signals))
        workbench_handle.measurements[:help] =
            "Choose a signal to isolate it, or use Show all to compare every trace; click sets A and Shift-click sets B."
    end
    _contextualize!(workbench_handle)
end

function workbench(result::Amber.SpectrumResult; fundamental=nothing, view=:auto)
    figure = _workbench_figure()
    plot_handle = spectrumplot(figure[1:5, 1], result; fundamental)
    frequencies = result.frequencies
    cursors = CursorState(frequencies, result.amplitude_rms)
    _cursor_axis!(plot_handle.axes.spectrum, cursors, frequencies)
    readout = Makie.lift(cursors.a) do frequency
        spectrum_cursor(result, frequency; fundamental)
    end
    marker = Makie.scatter!(plot_handle.axes.spectrum,
        Makie.lift(item -> [item.frequency], readout),
        Makie.lift(item -> [item.amplitude_rms], readout);
        color=_AMBER_COLORS.warning, marker=:diamond, markersize=13)
    band_power = Makie.Observable(Amber.band_power(result,
        first(frequencies) => last(frequencies)))
    slider = Makie.IntervalSlider(figure[2, 2]; range=frequencies,
        startvalues=(first(frequencies), last(frequencies)))
    push!(cursors.subscriptions, Makie.on(slider.interval) do bounds
        setinterval!(cursors, Float64(first(bounds)) => Float64(last(bounds)))
    end)
    push!(cursors.subscriptions, Makie.on(cursors.interval) do band
        band_power[] = Amber.band_power(result, band)
    end)
    annotation = Makie.lift(readout, band_power) do item, power
        order = item.harmonic_order === nothing ? "" : " · order $(item.harmonic_order)"
        "$(uppercase(String(item.classification)))$(order)\nFrequency: $(engineering(item.frequency; unit="Hz"))\nAmplitude: $(engineering(item.amplitude_rms; unit="V RMS"))\nPhase: $(round(item.phase_degrees; digits=2))°\nPSD: $(engineering(item.psd; unit="V²/Hz"))\n\nBand RMS: $(engineering(sqrt(max(power, 0)); unit="V"))"
    end
    Makie.Label(figure[3:5, 2], annotation; halign=:left, valign=:top,
        justification=:left)
    inspector = Makie.DataInspector(figure)
    cleanup = () -> begin
        _close!(cursors)
        delete!(figure, inspector)
    end
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout,
        :interval => cursors.interval_readout, :spectrum_cursor => readout,
        :band_power => band_power, :band_control => slider,
        :copyrecipe_kwargs => fundamental === nothing ? Dict{Symbol,String}() :
            Dict(:fundamental => repr(fundamental)))
    _contextualize!(WorkbenchHandle(figure, plot_handle.axes,
        merge(plot_handle.plots, (cursor=marker,)), Makie.Observable(Symbol[]),
        cursors, measurements, _warnings(result.stats), _provenance(result), cleanup,
        false))
end

function workbench(result::Amber.HarmonicResult; view=:auto)
    figure = _workbench_figure()
    plot_handle = harmonicplot(figure[1:5, 1], result)
    components = vcat([result.fundamental], result.harmonics)
    orders = getproperty.(components, :order)
    selected_order = Makie.Observable(first(orders))
    selection = Makie.Observable([Symbol("H$(first(orders))")])
    selected = Makie.lift(selected_order) do order
        components[only(findall(==(order), orders))]
    end
    marker = Makie.scatter!(plot_handle.axes.harmonics,
        Makie.lift(item -> [item.order], selected),
        Makie.lift(item -> [item.amplitude_rms], selected);
        color=_AMBER_COLORS.warning, marker=:diamond, markersize=14)
    slider = Makie.Slider(figure[2, 2]; range=orders, startvalue=first(orders), snap=true)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(slider.value) do order
        selected_order[] = Int(order)
    end)
    push!(subscriptions, Makie.on(selected_order) do order
        order in orders || return
        selection[] = [Symbol("H$(order)")]
        slider.value[] == order || (slider.value[] = order)
    end)
    annotation = Makie.lift(selected) do item
        classification = item.order == 1 ? "FUNDAMENTAL" : "HARMONIC"
        "$(classification) H$(item.order)\nFrequency: $(engineering(item.frequency; unit="Hz"))\nAmplitude: $(engineering(item.amplitude_rms; unit="V RMS"))\nPhase: $(round(rad2deg(item.phase); digits=2))°\nFFT bin: $(item.bin)"
    end
    Makie.Label(figure[3, 2], annotation; halign=:left, justification=:left)
    metrics = "THD: $(round(100result.thd; digits=3))%\nTHD+N: $(round(100result.thdn; digits=3))%\nSNR: $(round(result.snr; digits=2)) dB\nSINAD: $(round(result.sinad; digits=2)) dB\nSFDR: $(round(result.sfdr; digits=2)) dB\nENOB: $(round(result.enob; digits=2)) bits"
    Makie.Label(figure[4:5, 2], metrics; halign=:left, valign=:top,
        justification=:left)
    inspector = Makie.DataInspector(figure)
    cleanup = () -> begin
        foreach(Makie.off, subscriptions); empty!(subscriptions)
        delete!(figure, inspector)
    end
    measurements = Dict{Symbol,Any}(:selected_order => selected_order,
        :harmonic_cursor => selected, :order_control => slider)
    _contextualize!(WorkbenchHandle(figure, plot_handle.axes,
        merge(plot_handle.plots, (cursor=marker,)), selection, nothing,
        measurements, _warnings(result.stats), _provenance(result), cleanup, false))
end

function workbench(result::Amber.NoiseResult; referred=:output, view=:auto)
    frequencies = result.frequencies
    psd = referred === :output ? Amber.noise_psd(result) : Amber.input_referred_noise_psd(result)
    psd === nothing && throw(ArgumentError("input-referred noise is unavailable for this result"))
    density = sqrt.(max.(psd, 0.0))
    figure = Makie.Figure(size=(1200, 760))
    density_handle = noiseplot(figure[1:3, 1], result; referred)
    integrated_handle = integratednoiseplot(figure[4:6, 1], result; referred)

    initial = first(frequencies) => last(frequencies)
    contribution = noisecontributionview(result; referred, band=initial, group=:component)
    contribution_values = Makie.Observable(sqrt.(contribution.values))
    contribution_labels = Makie.Observable(contribution.labels)
    contribution_axis = Makie.Axis(figure[1:4, 2]; xlabel="Integrated RMS noise (V)",
        ylabel="Component")
    contribution_plot = Makie.barplot!(contribution_axis, contribution_values;
        direction=:x)
    contribution_axis.yticks = (collect(eachindex(contribution.labels)), contribution.labels)

    cursors = CursorState(frequencies, density)
    _cursor_axis!(density_handle.axes.noise, cursors, frequencies)
    _cursor_axis!(integrated_handle.axes.integrated_noise, cursors, frequencies)
    slider = Makie.IntervalSlider(figure[5, 2]; range=frequencies,
        startvalues=(first(frequencies), last(frequencies)))
    band_rms = Makie.Observable(sqrt(max(_band_variance(frequencies, psd,
        first(initial), last(initial)), 0.0)))
    selected_contributions = Makie.Observable(contribution)
    push!(cursors.subscriptions, Makie.on(slider.interval) do bounds
        setinterval!(cursors, Float64(first(bounds)) => Float64(last(bounds)))
    end)
    push!(cursors.subscriptions, Makie.on(cursors.interval) do band
        current = noisecontributionview(result; referred, band, group=:component)
        contribution_values[] = sqrt.(current.values)
        contribution_labels[] = current.labels
        contribution_axis.yticks[] = (collect(eachindex(current.labels)), current.labels)
        selected_contributions[] = current
        band_rms[] = sqrt(max(current.total_variance, 0.0))
        Makie.autolimits!(contribution_axis)
    end)
    metric_text = Makie.lift(band_rms, cursors.interval) do rms, band
        "Selected band\n$(engineering(first(band); unit="Hz")) – $(engineering(last(band); unit="Hz"))\nRMS: $(engineering(rms; unit="V"))"
    end
    Makie.Label(figure[6, 2], metric_text; halign=:left, justification=:left)
    inspector = Makie.DataInspector(figure)
    axes = (noise=density_handle.axes.noise,
        integrated_noise=integrated_handle.axes.integrated_noise,
        noise_contributions=contribution_axis)
    plots = (noise=density_handle.plots.noise,
        integrated_noise=integrated_handle.plots.integrated_noise,
        noise_contributions=contribution_plot)
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout,
        :interval => cursors.interval_readout, :band_rms => band_rms,
        :contributions => selected_contributions, :band_control => slider,
        :copyrecipe_kwargs => Dict(:referred => repr(referred)))
    warnings = _warnings(result.stats)
    cleanup = () -> begin
        _close!(cursors)
        delete!(figure, inspector)
    end
    _contextualize!(WorkbenchHandle(figure, axes, plots, Makie.Observable(Symbol[]),
        cursors, measurements, warnings, _provenance(result), cleanup, false))
end

function workbench(result::Amber.PhaseNoiseResult; carrier_frequency=nothing,
        band=first(result.offset_frequencies) => last(result.offset_frequencies), view=:auto)
    figure = Makie.Figure(size=(1260, 820))
    handle = phasenoiseplot(figure[1:3, 1], result; carrier_frequency, band)
    budget = noisebudgetplot(figure[4:6, 1], result; group=:component)
    initial_contributions = _phase_contribution_view(result, band; group=:component)
    contribution_values = Makie.Observable(sqrt.(max.(initial_contributions.values, 0.0)))
    contribution_labels = Makie.Observable(initial_contributions.labels)
    contribution_axis = Makie.Axis(figure[1:4, 2];
        xlabel="Integrated phase contribution (rad RMS)", ylabel="Component")
    contribution_plot = Makie.barplot!(contribution_axis, contribution_values;
        direction=:x)
    contribution_axis.yticks = (collect(eachindex(initial_contributions.labels)),
        initial_contributions.labels)
    cursors = CursorState(result.offset_frequencies, result.phase_noise_dbc_per_hz)
    _cursor_axis!(handle.axes.phase_noise, cursors, result.offset_frequencies)
    _cursor_axis!(budget.axes.noise_budget, cursors, result.offset_frequencies)
    slider = Makie.IntervalSlider(figure[5, 2]; range=result.offset_frequencies,
        startvalues=(Float64(first(band)), Float64(last(band))))
    integrated = Makie.Observable(_integrated_phase_noise(result, band))
    selected_contributions = Makie.Observable(initial_contributions)
    push!(cursors.subscriptions, Makie.on(slider.interval) do bounds
        setinterval!(cursors, Float64(first(bounds)) => Float64(last(bounds)))
    end)
    push!(cursors.subscriptions, Makie.on(cursors.interval) do selected
        integrated[] = _integrated_phase_noise(result, selected)
        contributions = _phase_contribution_view(result, selected; group=:component)
        selected_contributions[] = contributions
        contribution_values[] = sqrt.(max.(contributions.values, 0.0))
        contribution_labels[] = contributions.labels
        contribution_axis.yticks[] = (collect(eachindex(contributions.labels)),
            contributions.labels)
        Makie.autolimits!(contribution_axis)
    end)
    metric = Makie.lift(integrated) do phase
        carrier_frequency === nothing ?
            "Integrated phase: $(engineering(phase; unit="rad RMS"))" :
            "Integrated jitter: $(engineering(phase / (2π * carrier_frequency); unit="s RMS"))"
    end
    Makie.Label(figure[6, 2], metric; halign=:left)
    validity = Amber.validity_report(result)
    validity_warnings = String.(get(validity, :warnings, String[]))
    validity_text = isempty(validity_warnings) ?
        "Validity: no device-model warnings" :
        "Validity\n" * join(validity_warnings, "\n")
    Makie.Label(figure[7, 1:2], validity_text; halign=:left, justification=:left,
        color=isempty(validity_warnings) ? :gray40 : _AMBER_COLORS.warning)
    inspector = Makie.DataInspector(figure)
    cleanup = () -> begin
        _close!(cursors)
        delete!(figure, inspector)
    end
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout,
        :interval => cursors.interval_readout, :integrated_phase => integrated,
        :band_control => slider, :contributions => selected_contributions,
        :validity => validity,
        :copyrecipe_kwargs => Dict(:carrier_frequency => repr(carrier_frequency),
            :band => repr(band)))
    axes = (phase_noise=handle.axes.phase_noise,
        noise_budget=budget.axes.noise_budget,
        phase_contributions=contribution_axis)
    plots = (phase_noise=handle.plots.phase_noise,
        noise_budget=budget.plots.noise_budget,
        phase_contributions=contribution_plot)
    _contextualize!(WorkbenchHandle(figure, axes, plots, Makie.Observable(Symbol[]),
        cursors, measurements, _warnings(result.stats), _provenance(result), cleanup,
        false))
end

function workbench(result::Amber.PeriodicNoiseResult; view=:auto, scale=:db,
        pss=nothing, signals=nothing)
    pss === nothing || pss isa Amber.PSSResult ||
        throw(ArgumentError("pss must be a PSSResult"))
    pss === nothing || signals !== nothing ||
        throw(ArgumentError("periodic-noise orbit linking requires signals"))
    figure = Makie.Figure(size=pss === nothing ? (1000, 700) : (1200, 820))
    handle = periodicnoiseplot(pss === nothing ? figure[1:5, 1] : figure[1:3, 1],
        result; scale)
    orbit_handle = pss === nothing ? nothing : traceplot(figure[4:6, 1], pss.orbit;
        signals)
    cursors = CursorState(result.offset_frequencies, sqrt.(max.(result.output_psd, 0.0)))
    _cursor_axis!(handle.axes.periodic_noise, cursors, result.offset_frequencies)
    selected_sideband = Makie.Observable(result.sidebands[
        argmin(abs.(result.sidebands .- result.output_harmonic))])
    selection = Makie.Observable([Symbol("sideband_$(selected_sideband[])")])
    sideband_control = Makie.Slider(figure[2, 2]; range=result.sidebands,
        startvalue=selected_sideband[], snap=true)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(sideband_control.value) do sideband
        selected_sideband[] = Int(sideband)
    end)
    push!(subscriptions, Makie.on(selected_sideband) do sideband
        selection[] = [Symbol("sideband_$(sideband)")]
    end)
    sideband_line = Makie.hlines!(handle.axes.periodic_noise, selected_sideband;
        color=_AMBER_COLORS.warning, linewidth=2)
    sideband_readout = Makie.lift(selected_sideband, cursors.a) do sideband, offset
        row = only(findall(==(sideband), result.sidebands))
        sample = nearest_sample(result.offset_frequencies,
            vec(result.sideband_psd[row, :]), offset)
        translated = pss === nothing ? nothing : sample.x + sideband / pss.period
        (sideband, offset=sample.x, psd=sample.y, translated_frequency=translated)
    end
    label_text = Makie.lift(sideband_readout) do item
        translated = item.translated_frequency === nothing ? "" :
            "\nPSS-linked frequency: $(engineering(item.translated_frequency; unit="Hz"))"
        "Periodic-noise sideband $(item.sideband)\nOutput harmonic: $(result.output_harmonic)\nOffset: $(engineering(item.offset; unit="Hz"))\nPSD: $(engineering(item.psd; unit="V²/Hz"))$(translated)"
    end
    Makie.Label(figure[1, 2], label_text;
        halign=:left, justification=:left)
    inspector = Makie.DataInspector(figure)
    cleanup = () -> begin
        _close!(cursors)
        foreach(Makie.off, subscriptions); empty!(subscriptions)
        delete!(figure, inspector)
    end
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout,
        :interval => cursors.interval_readout, :selected_sideband => selected_sideband,
        :sideband_readout => sideband_readout, :sideband_control => sideband_control,
        :pss => pss, :copyrecipe_kwargs => begin
            kwargs = Dict{Symbol,String}(:scale => repr(scale))
            if pss !== nothing
                kwargs[:pss] = "pss"
                kwargs[:signals] = repr(signals)
            end
            kwargs
        end)
    axes = (periodic_noise=handle.axes.periodic_noise,
        orbit=orbit_handle === nothing ? nothing : orbit_handle.axes.trace)
    plots = (sidebands=handle.plots.sidebands, selected_sideband=sideband_line,
        orbit=orbit_handle === nothing ? nothing : orbit_handle.plots)
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection,
        cursors, measurements, _warnings(result.stats), _provenance(result), cleanup,
        false))
end

function workbench(result::Amber.NetworkResult; parameter=:s, element=(1, 1), view=:auto)
    parameter = Symbol(parameter)
    parameter in (:s, :z, :y) ||
        throw(ArgumentError("parameter must be :s, :z, or :y"))
    port_count = length(result.ports)
    row, column = Int.(element)
    1 <= row <= port_count && 1 <= column <= port_count ||
        throw(BoundsError((port_count, port_count), element))
    element = (row, column)
    figure = Makie.Figure(size=(1320, 860))
    frequencies = result.frequencies
    selected_parameter = Makie.Observable(parameter)
    selected_element = Makie.Observable(element)
    network_values = Makie.lift(selected_parameter, selected_element) do kind, selected
        ComplexF64.(networkview(result; parameter=kind, element=selected).values)
    end
    smith_values = Makie.lift(selected_element) do selected
        ComplexF64.(networkview(result; parameter=:s, element=selected).values)
    end
    impedance_values = Makie.lift(selected_element) do selected
        ComplexF64.(networkview(result; parameter=:z, element=selected).values)
    end
    gain = Makie.lift(values -> 20log10.(abs.(values)), network_values)
    phase = Makie.lift(values -> rad2deg.(_unwrap(angle.(values))), network_values)

    magnitude_axis = _frequency_axis(figure[1:2, 1], frequencies;
        ylabel="Magnitude (dB)")
    phase_axis = _frequency_axis(figure[3:4, 1], frequencies;
        xlabel="Frequency (Hz)", ylabel="Phase (°)")
    Makie.linkxaxes!(magnitude_axis, phase_axis)
    magnitude_plot = Makie.lines!(magnitude_axis, frequencies, gain)
    phase_plot = Makie.lines!(phase_axis, frequencies, phase)

    smith_title = Makie.lift(selected_element) do (selected_row, selected_column)
        reference = result.ports[selected_column].reference_impedance
        "S$(selected_row)$(selected_column) · Z₀=$(engineering(reference; unit="Ω"))"
    end
    smith_axis = Makie.Axis(figure[1:2, 2]; title=smith_title,
        aspect=Makie.DataAspect(), xgridvisible=false, ygridvisible=false,
        xticksvisible=false, yticksvisible=false, xticklabelsvisible=false,
        yticklabelsvisible=false)
    _smith_grid!(smith_axis)
    smith_plot = Makie.lines!(smith_axis,
        Makie.lift(values -> real.(values), smith_values),
        Makie.lift(values -> imag.(values), smith_values))
    marker_indices = unique(round.(Int, exp.(range(log(1), log(length(frequencies));
        length=clamp(7, 2, length(frequencies))))))
    smith_direction = Makie.scatter!(smith_axis,
        Makie.lift(values -> real.(values[marker_indices]), smith_values),
        Makie.lift(values -> imag.(values[marker_indices]), smith_values);
        color=log10.(frequencies[marker_indices]), colormap=:viridis, markersize=7)
    Makie.xlims!(smith_axis, -1.08, 1.08); Makie.ylims!(smith_axis, -1.08, 1.08)

    impedance_axis = _frequency_axis(figure[3, 2], frequencies;
        ylabel="Real Z (Ω)")
    reactance_axis = _frequency_axis(figure[4, 2], frequencies;
        xlabel="Frequency (Hz)", ylabel="Imaginary Z (Ω)")
    # Aspect-aware Smith axes and intrinsic-width controls otherwise leave both
    # top-level columns at their minimum widths in static backends.
    Makie.colsize!(figure.layout, 1, Makie.Relative(0.52))
    Makie.colsize!(figure.layout, 2, Makie.Relative(0.48))
    Makie.linkxaxes!(impedance_axis, reactance_axis)
    impedance_plot = Makie.lines!(impedance_axis, frequencies,
        Makie.lift(values -> real.(values), impedance_values))
    reactance_plot = Makie.lines!(reactance_axis, frequencies,
        Makie.lift(values -> imag.(values), impedance_values))

    cursor_gain = copy(gain[])
    cursors = CursorState(frequencies, cursor_gain)
    foreach(axis -> _cursor_axis!(axis, cursors, frequencies),
        (magnitude_axis, phase_axis, impedance_axis, reactance_axis))

    function electrical_readout(frequency, selected)
        selected[1] == selected[2] &&
            return smith_cursor_readout(result, frequency; element=selected)
        sample = nearest_sample(frequencies, smith_values[], frequency)
        (index=sample.index, frequency=Float64(sample.x),
            reflection=ComplexF64(sample.y), impedance=nothing,
            admittance=nothing,
            reference_impedance=Float64(result.ports[selected[2]].reference_impedance))
    end
    smith_a = Makie.Observable{Any}(electrical_readout(cursors.a[], element))
    smith_b = Makie.Observable{Any}(electrical_readout(cursors.b[], element))
    append!(cursors.subscriptions,
        Makie.onany(cursors.a, selected_element) do frequency, selected
            smith_a[] = electrical_readout(frequency, selected)
        end)
    append!(cursors.subscriptions,
        Makie.onany(cursors.b, selected_element) do frequency, selected
            smith_b[] = electrical_readout(frequency, selected)
        end)
    point_a = Makie.lift(smith_a) do readout
        [Makie.Point2f(real(readout.reflection), imag(readout.reflection))]
    end
    point_b = Makie.lift(smith_b) do readout
        [Makie.Point2f(real(readout.reflection), imag(readout.reflection))]
    end
    marker_a = Makie.scatter!(smith_axis, point_a;
        color=_AMBER_COLORS.input, marker=:circle, markersize=14)
    marker_b = Makie.scatter!(smith_axis, point_b;
        color=_AMBER_COLORS.output, marker=:diamond, markersize=14)

    labels = [something(port.name, Symbol("port$(index)")) |> string
        for (index, port) in enumerate(result.ports)]
    elements = [(candidate_row, candidate_column)
        for candidate_row in 1:port_count for candidate_column in 1:port_count]
    element_options = [("$(labels[candidate_row]) ← $(labels[candidate_column]) · [$candidate_row,$candidate_column]",
            (candidate_row, candidate_column))
        for (candidate_row, candidate_column) in elements]
    Makie.Label(figure[5, 1], "Network parameter"; halign=:left)
    parameter_control = Makie.Menu(figure[6, 1];
        options=[("S", :s), ("Z", :z), ("Y", :y)],
        default=findfirst(==(parameter), (:s, :z, :y)))
    Makie.Label(figure[5, 2], "Port / matrix element"; halign=:left)
    element_control = Makie.Menu(figure[6, 2]; options=element_options,
        default=findfirst(==(element), elements))
    slider = Makie.IntervalSlider(figure[7, 1:2]; range=frequencies,
        startvalues=(first(frequencies), last(frequencies)))
    subscriptions = Any[]
    push!(subscriptions, Makie.on(parameter_control.selection) do value
        value === nothing || (selected_parameter[] = Symbol(value))
    end)
    push!(subscriptions, Makie.on(element_control.selection) do value
        value === nothing || (selected_element[] = Tuple(Int.(value)))
    end)
    append!(subscriptions, Makie.onany(selected_parameter, selected_element) do _, _
        copyto!(cursor_gain, gain[])
        cursors.readout[] = cursor_readout(frequencies, cursor_gain,
            cursors.a[], cursors.b[])
    end)
    push!(cursors.subscriptions, Makie.on(slider.interval) do bounds
        setcursor!(cursors, :a, first(bounds))
        setcursor!(cursors, :b, last(bounds))
        setinterval!(cursors, first(bounds) => last(bounds))
    end)
    push!(subscriptions, Makie.on(Makie.events(smith_axis).mousebutton;
            priority=10) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(smith_axis.scene) || return Makie.Consume(false)
        target = Makie.mouseposition(smith_axis)
        values = smith_values[]
        index = argmin(abs2.(real.(values) .- target[1]) .+
            abs2.(imag.(values) .- target[2]))
        shifted = Makie.Keyboard.left_shift in Makie.events(smith_axis).keyboardstate ||
            Makie.Keyboard.right_shift in Makie.events(smith_axis).keyboardstate
        setcursor!(cursors, shifted ? :b : :a, frequencies[index])
        Makie.Consume(true)
    end)
    readout_text = Makie.lift(smith_a, smith_b) do a, b
        format(label, value) = "$(label): $(engineering(real(value); unit="Ω")) $(imag(value) < 0 ? "−" : "+") j$(engineering(abs(imag(value)); unit="Ω"))"
        line(label, item) = item.impedance === nothing ?
            "$(label) · $(engineering(item.frequency; unit="Hz"))\nSᵢⱼ: $(round(real(item.reflection); digits=5)) $(imag(item.reflection) < 0 ? "−" : "+") j$(round(abs(imag(item.reflection)); digits=5))\nZ/Y conversion applies to reflection terms only" :
            "$(label) · $(engineering(item.frequency; unit="Hz"))\n$(format("Z", item.impedance))\nY: $(engineering(abs(item.admittance); unit="S")) ∠ $(round(rad2deg(angle(item.admittance)); digits=2))°"
        line("A", a) * "\n\n" * line("B", b)
    end
    Makie.Label(figure[8, 1:2], readout_text; halign=:left, justification=:left)
    inspector = Makie.DataInspector(figure)
    axes = (magnitude=magnitude_axis, phase=phase_axis,
        smith=smith_axis, impedance=impedance_axis, reactance=reactance_axis)
    plots = (magnitude=magnitude_plot, phase=phase_plot,
        smith=smith_plot, smith_direction=smith_direction,
        smith_cursor_a=marker_a, smith_cursor_b=marker_b,
        impedance=impedance_plot, reactance=reactance_plot)
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout,
        :interval => cursors.interval_readout, :smith_a => smith_a, :smith_b => smith_b,
        :frequency_control => slider, :selected_parameter => selected_parameter,
        :selected_element => selected_element, :parameter_control => parameter_control,
        :element_control => element_control, :element_choices => elements,
        :help => "Choose S/Z/Y and any port matrix element. Click traces to set A; Shift-click sets B.",
        :copyrecipe_kwargs => Dict(:parameter => repr(parameter),
            :element => repr(element)))
    cleanup = () -> begin
        _close!(cursors)
        foreach(Makie.off, subscriptions); empty!(subscriptions)
        delete!(figure, inspector)
    end
    selection = Makie.lift(selected_parameter, selected_element) do kind, selected
        [Symbol("$(uppercase(String(kind)))$(selected[1])$(selected[2])")]
    end
    semantic = networkview(result; parameter, element)
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection,
        cursors, measurements, copy(semantic.warnings), copy(semantic.provenance),
        cleanup, false))
end

function workbench(result::Amber.LoopGainResult; view=:auto)
    figure = _workbench_figure()
    _contextualize!(_workbench_handle(figure,
        marginplot(figure[1:5, 1], result)))
end

function workbench(result::Amber.PSSResult; signals, view=:auto)
    figure = Makie.Figure(size=(1240, 900))
    plot_handle = pssplot(figure[1:4, 1], result; signals)
    modes = [floquet_mode(result, index) for index in eachindex(result.floquet_multipliers)]
    selected_index = Makie.Observable(argmax(abs.(result.floquet_multipliers)))
    selected_mode = Makie.lift(index -> modes[index], selected_index)
    participation = Makie.lift(mode -> mode.participation, selected_mode)
    selected_state = Makie.Observable(argmax(modes[selected_index[]].participation))
    selected_state_label = Makie.lift(selected_state) do state
        first(modes).state_labels[state]
    end
    state_trace = Makie.lift(selected_state) do state
        real.(result.orbit.values[state, :])
    end
    mode_axis = Makie.Axis(figure[1:3, 2]; xlabel="Mode participation", ylabel="State",
        yticks=(collect(eachindex(first(modes).state_labels)), first(modes).state_labels))
    mode_plot = Makie.barplot!(mode_axis, participation; direction=:x)
    participation_marker = Makie.scatter!(mode_axis,
        Makie.lift(selected_state, participation) do state, values
            [Makie.Point2f(values[state], state)]
        end; color=_AMBER_COLORS.warning, marker=:diamond, markersize=13)
    state_axis = Makie.Axis(figure[5:6, 1]; xlabel="Time (s)",
        ylabel="Raw state", title=selected_state_label)
    state_plot = Makie.lines!(state_axis, result.orbit.axis, state_trace;
        color=_AMBER_COLORS.warning)
    floquet_point = Makie.lift(selected_mode) do mode
        [Makie.Point2f(real(mode.multiplier), imag(mode.multiplier))]
    end
    mode_marker = Makie.scatter!(plot_handle.axes.floquet, floquet_point;
        color=_AMBER_COLORS.warning, marker=:diamond, markersize=14)
    selector = Makie.Slider(figure[4, 2]; range=eachindex(modes),
        startvalue=selected_index[], snap=true)
    signal_choices = signals isa AbstractVector || signals isa Tuple ?
        collect(signals) : [signals]
    selected_signal = Makie.Observable{Any}(first(signal_choices))
    Makie.Label(figure[7, 2], "Orbit signal selector"; halign=:left)
    signal_control = Makie.Menu(figure[8, 2];
        options=[(string(signal), signal) for signal in signal_choices], default=1)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(selector.value) do index
        selected_index[] = Int(index)
    end)
    push!(subscriptions, Makie.on(signal_control.selection) do signal
        signal === nothing || (selected_signal[] = signal)
    end)
    push!(subscriptions, Makie.on(selected_signal) do signal
        index = findfirst(choice -> isequal(choice, signal), signal_choices)
        index === nothing && return
        foreach(eachindex(plot_handle.plots.traces)) do candidate
            _plot_observable(plot_handle.plots.traces[candidate], :visible)[] =
                candidate == index
        end
    end)
    push!(subscriptions, Makie.on(selected_mode) do mode
        selected_state[] = argmax(mode.participation)
    end)
    push!(subscriptions, Makie.on(Makie.events(plot_handle.axes.floquet).mousebutton;
            priority=9) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(plot_handle.axes.floquet.scene) ||
            return Makie.Consume(false)
        target = Makie.mouseposition(plot_handle.axes.floquet)
        multipliers = result.floquet_multipliers
        selected_index[] = argmin(abs2.(real.(multipliers) .- target[1]) .+
            abs2.(imag.(multipliers) .- target[2]))
        selector.value[] = selected_index[]
        Makie.Consume(true)
    end)
    push!(subscriptions, Makie.on(Makie.events(mode_axis).mousebutton;
            priority=9) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(mode_axis.scene) || return Makie.Consume(false)
        state = clamp(round(Int, Makie.mouseposition(mode_axis)[2]),
            1, length(first(modes).state_labels))
        selected_state[] = state
        Makie.Consume(true)
    end)
    mode_text = Makie.lift(selected_mode) do mode
        stability = mode.stable ? "stable" : "unstable"
        "Mode $(mode.index) · $(stability)\nλ = $(round(real(mode.multiplier); digits=6)) $(imag(mode.multiplier) < 0 ? "−" : "+") j$(round(abs(imag(mode.multiplier)); digits=6))\n|λ| = $(round(abs(mode.multiplier); digits=6))"
    end
    state_text = Makie.lift(selected_mode, selected_state_label, selected_state,
            participation) do mode, label, state, values
        "$(label)\nParticipation in mode $(mode.index): $(round(100values[state]; digits=2))%"
    end
    Makie.Label(figure[5, 2], mode_text; halign=:left, justification=:left)
    Makie.Label(figure[6, 2], state_text; halign=:left, justification=:left)
    first_trace = copy(state_trace[])
    cursors = CursorState(result.orbit.axis, first_trace)
    _cursor_axis!(plot_handle.axes.pss, cursors, result.orbit.axis)
    _cursor_axis!(state_axis, cursors, result.orbit.axis)
    push!(subscriptions, Makie.on(state_trace) do values
        copyto!(first_trace, values)
        cursors.readout[] = cursor_readout(result.orbit.axis, first_trace,
            cursors.a[], cursors.b[])
    end)
    inspector = Makie.DataInspector(figure)
    axes = merge(plot_handle.axes, (mode_participation=mode_axis,
        linked_state=state_axis))
    plots = merge(plot_handle.plots, (selected_mode=mode_marker,
        mode_participation=mode_plot, selected_participation=participation_marker,
        linked_state=state_plot))
    measurements = Dict{Symbol,Any}(:cursors => cursors.readout,
        :interval => cursors.interval_readout, :selected_mode => selected_mode,
        :mode_index => selected_index, :mode_control => selector,
        :selected_signal => selected_signal, :signal_choices => signal_choices,
        :signal_control => signal_control,
        :selected_state => selected_state, :selected_state_label => selected_state_label,
        :state_trace => state_trace,
        :help => "Click a Floquet multiplier to select its mode; click participation bars to inspect the linked orbit state.",
        :copyrecipe_kwargs => Dict(:signals => repr(signals)))
    cleanup = () -> begin
        _close!(cursors); foreach(Makie.off, subscriptions); empty!(subscriptions)
        delete!(figure, inspector)
    end
    selection = Makie.lift(selected_index, selected_state, selected_signal) do mode, state, signal
        [Symbol("mode_$(mode)"), Symbol("state_$(state)"), Symbol(string(signal))]
    end
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection, cursors, measurements,
        _warnings(result.stats), _provenance(result), cleanup, false))
end

function workbench(result::Amber.SweepResult; view=:auto)
    isempty(result.metrics) && throw(ArgumentError("sweep workbench requires points"))
    figure = Makie.Figure(size=(1180, 760))
    sweep_handle = sweepplot(figure[1:4, 1], result)
    failure_handle = failureplot(figure[1:3, 2], result)
    selected_sample = Makie.Observable(1)
    selection = Makie.Observable([:sweep_1])
    selected_point = Makie.lift(selected_sample) do sample
        x = result.parameter_values[sample]
        y = result.metrics[sample]
        x isa Real && y isa Real ? [Makie.Point2f(Float64(x), Float64(y))] :
            [Makie.Point2f(NaN, NaN)]
    end
    marker = Makie.scatter!(sweep_handle.axes.sweep, selected_point;
        color=_AMBER_COLORS.warning, marker=:diamond, markersize=14)
    slider = Makie.Slider(figure[5, 1:2]; range=eachindex(result.metrics),
        startvalue=1, snap=true)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(slider.value) do sample
        selected_sample[] = Int(sample)
    end)
    push!(subscriptions, Makie.on(selected_sample) do sample
        1 <= sample <= length(result.metrics) || return
        selection[] = [Symbol("sweep_$(sample)")]
        slider.value[] == sample || (slider.value[] = sample)
    end)
    push!(subscriptions, Makie.on(Makie.events(sweep_handle.axes.sweep).mousebutton;
            priority=9) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(sweep_handle.axes.sweep.scene) || return Makie.Consume(false)
        target = Makie.mouseposition(sweep_handle.axes.sweep)[1]
        numeric = findall(value -> value isa Real, result.parameter_values)
        isempty(numeric) || (selected_sample[] = numeric[argmin(abs.(
            Float64.(result.parameter_values[numeric]) .- target))])
        Makie.Consume(true)
    end)
    details = Makie.lift(selected_sample) do sample
        failure = findfirst(item -> item.index == sample, result.failures)
        failure_text = failure === nothing ? "" :
            "\nFailure: $(result.failures[failure].error_type)\n$(result.failures[failure].message)"
        status = result.converged[sample] ? "converged" : "failed"
        metric = result.metrics[sample] === nothing ? "—" : engineering(result.metrics[sample])
        "Point $(sample) · $(status)\n$(result.selector): $(engineering(result.parameter_values[sample]))\nMetric: $(metric)$(failure_text)"
    end
    Makie.Label(figure[4, 2], details; halign=:left, justification=:left,
        valign=:top)
    numeric_metrics = Float64[result.metrics[index] for index in eachindex(result.metrics)
        if result.converged[index] && result.metrics[index] isa Real]
    cards = isempty(numeric_metrics) ? "No successful scalar metrics" :
        "Converged: $(count(result.converged))/$(length(result.metrics))\nMinimum: $(engineering(minimum(numeric_metrics)))\nMaximum: $(engineering(maximum(numeric_metrics)))\nMean: $(engineering(sum(numeric_metrics) / length(numeric_metrics)))"
    Makie.Label(figure[5, 2], cards; halign=:left, justification=:left)
    inspector = Makie.DataInspector(figure)
    axes = (sweep=sweep_handle.axes.sweep, failures=failure_handle.axes.failures)
    plots = (sweep=sweep_handle.plots.curve, failures=failure_handle.plots.failures,
        selected=marker)
    measurements = Dict{Symbol,Any}(:selected_sample => selected_sample,
        :sample_range => eachindex(result.metrics), :sample_control => slider,
        :details => details)
    cleanup = () -> begin
        foreach(Makie.off, subscriptions); empty!(subscriptions)
        delete!(figure, inspector)
    end
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection, nothing,
        measurements, [failure.message for failure in result.failures],
        _provenance(result), cleanup, false))
end

function workbench(result::Amber.MonteCarloResult; predicate=nothing, circuit=nothing,
        metric=identity, view=:auto)
    isempty(result.values) && throw(ArgumentError("Monte Carlo workbench requires samples"))
    figure = Makie.Figure(size=(1540, 880))
    ensemble = ensembleplot(figure[1:2, 1], result; predicate)
    failures = failureplot(figure[3:4, 1], result)
    axes = Dict{Symbol,Any}(:ensemble => ensemble.axes.ensemble,
        :failures => failures.axes.failures)
    plots = Dict{Symbol,Any}(:ensemble => ensemble.plots.histogram,
        :failures => failures.plots.failures)
    outliers = outlier_samples(result)
    selected_sample = Makie.Observable(1)
    selection = Makie.Observable([:sample_1])
    selected_metric = Makie.lift(selected_sample) do sample
        value = result.values[sample]
        result.converged[sample] && value isa Real ? [Float64(value)] : [NaN]
    end
    ensemble_marker = Makie.vlines!(ensemble.axes.ensemble, selected_metric;
        color=_AMBER_COLORS.warning, linewidth=3)
    plots[:selected_metric] = ensemble_marker

    available = sort!(collect(union((Set(keys(draw)) for draw in result.parameters)...));
        by=string)
    complete = count(index -> result.converged[index] && result.values[index] isa Real &&
        all(key -> haskey(result.parameters[index], key), available), eachindex(result.values))
    correlation = nothing
    correlation_marker = nothing
    if !isempty(available) && complete >= 2
        matrix = parametermatrixplot(figure[1:3, 2], result;
            parameters=available, correlation=:spearman)
        axes[:parameter_matrix] = matrix.axes.parameter_matrix
        plots[:parameter_matrix] = matrix.plots.parameter_matrix
        correlation = correlationplot(figure[1:3, 3], result;
            parameter=first(available))
        axes[:correlation] = correlation.axes.correlation
        plots[:correlation] = correlation.plots.correlation
        correlation_marker = Makie.scatter!(correlation.axes.correlation,
            Makie.lift(selected_sample) do sample
                position = findfirst(==(sample), correlation.view.samples)
                position === nothing ? [Makie.Point2f(NaN, NaN)] :
                    [Makie.Point2f(correlation.view.parameter[position],
                        correlation.view.metric[position])]
            end; color=_AMBER_COLORS.warning, marker=:diamond, markersize=15)
        plots[:selected_correlation] = correlation_marker
    else
        Makie.Label(figure[1:3, 2:3], "Rank correlation unavailable\nStored parameters and two successful samples are required";
            justification=:center, color=:gray45)
    end

    sample_summary = Makie.lift(selected_sample) do sample
        parameters = sort!(collect(result.parameters[sample]); by=pair -> string(first(pair)))
        parameter_text = isempty(parameters) ? "No stored parameters" :
            join(("$(name): $(engineering(value))" for (name, value) in parameters), "\n")
        status = result.converged[sample] ? "converged" : "failed"
        sample in outliers && (status *= " · outlier")
        stored = result.values[sample] === nothing ? "—" : engineering(result.values[sample])
        "Sample $(sample) · $(status)\nSeed: $(result.seeds[sample])\nMetric: $(stored)\n\n$(parameter_text)"
    end
    Makie.Label(figure[4, 2:3], sample_summary; halign=:left, valign=:top,
        justification=:left)
    sample_slider = Makie.Slider(figure[5, 1:3]; range=1:length(result.values),
        startvalue=1, snap=true)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(sample_slider.value) do sample
        selected_sample[] = Int(sample)
    end)
    push!(subscriptions, Makie.on(selected_sample) do sample
        1 <= sample <= length(result.values) || return
        selection[] = [Symbol("sample_$(sample)")]
        sample_slider.value[] == sample || (sample_slider.value[] = sample)
    end)
    push!(subscriptions, Makie.on(Makie.events(ensemble.axes.ensemble).mousebutton;
            priority=9) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(ensemble.axes.ensemble.scene) ||
            return Makie.Consume(false)
        target = Makie.mouseposition(ensemble.axes.ensemble)[1]
        candidates = [index for index in eachindex(result.values)
            if result.converged[index] && result.values[index] isa Real]
        isempty(candidates) || (selected_sample[] = candidates[argmin(abs.(
            Float64[result.values[index] for index in candidates] .- target))])
        Makie.Consume(true)
    end)
    if correlation !== nothing
        push!(subscriptions, Makie.on(Makie.events(correlation.axes.correlation).mousebutton;
                priority=9) do event
            event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
                return Makie.Consume(false)
            Makie.is_mouseinside(correlation.axes.correlation.scene) ||
                return Makie.Consume(false)
            target = Makie.mouseposition(correlation.axes.correlation)
            scale_x = max(maximum(correlation.view.parameter) -
                minimum(correlation.view.parameter), eps(Float64))
            scale_y = max(maximum(correlation.view.metric) -
                minimum(correlation.view.metric), eps(Float64))
            position = argmin(abs2.((correlation.view.parameter .- target[1]) ./ scale_x) .+
                abs2.((correlation.view.metric .- target[2]) ./ scale_y))
            selected_sample[] = correlation.view.samples[position]
            Makie.Consume(true)
        end)
    end
    push!(subscriptions, Makie.on(Makie.events(failures.axes.failures).mousebutton;
            priority=9) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press ||
            return Makie.Consume(false)
        Makie.is_mouseinside(failures.axes.failures.scene) ||
            return Makie.Consume(false)
        row = round(Int, Makie.mouseposition(failures.axes.failures)[2])
        if 1 <= row <= length(failures.view.labels) && !isempty(result.failures)
            kind = failures.view.labels[row]
            failure = findfirst(item -> string(item.exception_type) == kind,
                result.failures)
            failure === nothing || (selected_sample[] = result.failures[failure].sample)
        end
        Makie.Consume(true)
    end)

    numeric = Float64[result.values[index] for index in eachindex(result.values)
        if result.converged[index] && result.values[index] isa Real]
    center = isempty(numeric) ? NaN : sum(numeric) / length(numeric)
    spread = length(numeric) < 2 ? NaN : sqrt(sum(abs2, numeric .- center) / (length(numeric) - 1))
    yield_text = predicate === nothing ? "Yield: no predicate" :
        "Yield: $(round(100Amber.yield_rate(result, predicate); digits=1))%"
    cards = "Samples: $(length(result.values))   Converged: $(count(result.converged))   Failed: $(count(!, result.converged))\n" *
        "Mean: $(engineering(center))   σ: $(engineering(spread))   $(yield_text)"
    Makie.Label(figure[6, 1:3], cards; halign=:left, justification=:left)

    replay_result = Makie.Observable{Any}(nothing)
    replay_text = Makie.lift(replay_result) do comparison
        comparison === nothing && return circuit === nothing ?
            "Replay unavailable: construct the workbench with `circuit` and `metric`." :
            "Replay ready for the selected sample."
        status = comparison.matches ? "MATCH" : "DIFFERS"
        "Replay $(status) · sample $(comparison.sample)\nStored: $(engineering(comparison.stored)) · replayed: $(engineering(comparison.replayed))"
    end
    Makie.Label(figure[7, 1:3], replay_text; halign=:left, justification=:left,
        color=Makie.lift(replay_result) do comparison
            comparison === nothing || comparison.matches ? :gray40 : _AMBER_COLORS.invalid
        end)
    measurements = Dict{Symbol,Any}(:selected_sample => selected_sample,
        :sample_range => 1:length(result.values), :sample_control => sample_slider,
        :replay_result => replay_result, :replay_text => replay_text,
        :outliers => outliers, :linked_parameter => isempty(available) ? nothing : first(available),
        :help => "Click the histogram, parameter correlation, or a failure category to select and inspect that sample.",
        :copyrecipe_kwargs => begin
            kwargs = Dict{Symbol,String}()
            predicate === nothing || (kwargs[:predicate] = "predicate")
            if circuit !== nothing
                kwargs[:circuit] = "circuit"
                kwargs[:metric] = "metric"
            end
            kwargs
        end)
    if circuit !== nothing
        measurements[:replay] = function (sample)
            checkbounds(result.values, sample)
            replayed = Amber.replay_sample(result, circuit, sample; metric)
            stored = result.values[sample]
            matches = stored isa Real && replayed isa Real ? isapprox(stored, replayed) :
                isequal(stored, replayed)
            comparison = (sample=Int(sample), stored, replayed, matches)
            replay_result[] = comparison
            comparison
        end
    end
    inspector = Makie.DataInspector(figure)
    cleanup = () -> begin
        foreach(Makie.off, subscriptions)
        empty!(subscriptions)
        delete!(figure, inspector)
    end
    warnings = ["$(failure.exception_type): $(failure.message)" for failure in result.failures]
    _contextualize!(WorkbenchHandle(figure, axes, plots, selection, nothing,
        measurements, warnings, _provenance(result), cleanup, false))
end
