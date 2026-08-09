function spectrumplot(position, result::Amber.SpectrumResult; scale=:rms,
        frequency_scale=:linear, include_dc=frequency_scale === :linear, kwargs...)
    scale in (:rms, :psd) || throw(ArgumentError("scale must be :rms or :psd"))
    frequency_scale in (:linear, :log) || throw(ArgumentError("frequency_scale must be :linear or :log"))
    view = spectrumview(result)
    values = scale === :rms ? view.amplitude_rms : view.psd
    indices = include_dc ? collect(eachindex(view.frequencies)) : findall(>(0), view.frequencies)
    slot = _position(position)
    axis = frequency_scale === :log ? _frequency_axis(slot, view.frequencies[indices];
        xlabel="Frequency (Hz)", ylabel=scale === :rms ? "Amplitude RMS" : "PSD") :
        Makie.Axis(slot; xlabel="Frequency (Hz)", ylabel=scale === :rms ? "Amplitude RMS" : "PSD")
    plot = Makie.stem!(axis, view.frequencies[indices], values[indices]; kwargs...)
    PlotHandle(slot, (spectrum=axis,), (spectrum=plot,), view)
end

function harmonicplot(position, result::Amber.HarmonicResult; orders=:all, color=nothing, kwargs...)
    components = vcat([result.fundamental], result.harmonics)
    orders === :all || (components = filter(c -> c.order in orders, components))
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel="Harmonic order", ylabel="Amplitude RMS")
    colors = color === nothing ? [_AMBER_COLORS.output; fill(_AMBER_COLORS.input, max(length(components) - 1, 0))] : color
    plot = Makie.barplot!(axis, getproperty.(components, :order), getproperty.(components, :amplitude_rms);
        color=colors, kwargs...)
    summary = "THD $(round(100result.thd; digits=2))%\nSINAD $(round(result.sinad; digits=1)) dB\nSFDR $(round(result.sfdr; digits=1)) dB"
    Makie.text!(axis, 0.98, 0.98; text=summary, space=:relative,
        align=(:right, :top), fontsize=11, color=:gray25)
    PlotHandle(slot, (harmonics=axis,), (harmonics=plot,), result)
end
