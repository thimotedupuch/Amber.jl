function _unwrap(values)
    isempty(values) && return Float64[]
    output = Float64.(values)
    offset = 0.0
    for index in 2:length(output)
        jump = values[index] - values[index - 1]
        jump > π && (offset -= 2π)
        jump < -π && (offset += 2π)
        output[index] += offset
    end
    return output
end

function bodeplot(
        position, response::Union{Amber.LinearFrequencyResponse, Amber.LoopGainResult};
        input = 1, output = 1, magnitude = :db, unwrap = true, kwargs...
    )
    magnitude in (:db, :linear) || throw(ArgumentError("magnitude must be :db or :linear"))
    frequencies, values = _frequency_response(response; input, output)
    slot = _position(position); layout = Makie.GridLayout(slot)
    magnitude_axis = _frequency_axis(layout[1, 1], frequencies; ylabel = magnitude === :db ? "Gain (dB)" : "Gain")
    phase_axis = _frequency_axis(layout[2, 1], frequencies; xlabel = "Frequency (Hz)", ylabel = "Phase (°)")
    Makie.linkxaxes!(magnitude_axis, phase_axis)
    gain = magnitude === :db ? 20log10.(abs.(values)) : abs.(values)
    phase = rad2deg.(unwrap ? _unwrap(angle.(values)) : angle.(values))
    plots = (
        magnitude = Makie.lines!(magnitude_axis, frequencies, gain; kwargs...),
        phase = Makie.lines!(phase_axis, frequencies, phase; kwargs...),
    )
    return PlotHandle(layout, (magnitude = magnitude_axis, phase = phase_axis), plots, response)
end

function bodeplot(
        position, result::Amber.SimulationResult; input, output, magnitude = :db,
        unwrap = true, kwargs...
    )
    magnitude in (:db, :linear) || throw(ArgumentError("magnitude must be :db or :linear"))
    view = frequencyview(result; input, output)
    slot = _position(position)
    layout = Makie.GridLayout(slot)
    magnitude_axis = _frequency_axis(layout[1, 1], view.frequencies; ylabel = magnitude === :db ? "Gain (dB)" : "Gain")
    phase_axis = _frequency_axis(layout[2, 1], view.frequencies; xlabel = "Frequency (Hz)", ylabel = "Phase (°)")
    Makie.linkxaxes!(magnitude_axis, phase_axis)
    gain = magnitude === :db ? 20 .* log10.(abs.(view.response)) : abs.(view.response)
    raw_phase = angle.(view.response)
    phase = rad2deg.(unwrap ? _unwrap(raw_phase) : raw_phase)
    label = string(view.output_label, " / ", view.input_label)
    plots = (
        magnitude = Makie.lines!(magnitude_axis, view.frequencies, gain; label, kwargs...),
        phase = Makie.lines!(phase_axis, view.frequencies, phase; label, kwargs...),
    )
    Makie.axislegend(magnitude_axis)
    return PlotHandle(layout, (magnitude = magnitude_axis, phase = phase_axis), plots, view)
end
