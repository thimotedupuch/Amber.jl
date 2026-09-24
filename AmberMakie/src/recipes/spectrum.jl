function spectrumplot(
        position, result::Amber.SpectrumResult; scale = :rms,
        frequency_scale = :linear, include_dc = frequency_scale === :linear,
        full_scale = nothing, impedance = 50.0, band = nothing, fundamental = nothing, kwargs...
    )
    scale in (:rms, :psd, :dbv, :dbfs, :dbm) ||
        throw(ArgumentError("scale must be :rms, :psd, :dbv, :dbfs, or :dbm"))
    frequency_scale in (:linear, :log) || throw(ArgumentError("frequency_scale must be :linear or :log"))
    view = spectrumview(result)
    impedance > 0 || throw(ArgumentError("impedance must be positive"))
    if scale === :rms
        values = view.amplitude_rms; ylabel = "Amplitude RMS (V)"
    elseif scale === :psd
        values = view.psd; ylabel = "PSD (V²/Hz)"
    elseif scale === :dbv
        values = 20log10.(max.(view.amplitude_rms, floatmin(Float64))); ylabel = "Amplitude (dBV RMS)"
    elseif scale === :dbfs
        full_scale === nothing && throw(ArgumentError("scale=:dbfs requires full_scale RMS"))
        full_scale > 0 || throw(ArgumentError("full_scale must be positive"))
        values = 20log10.(max.(view.amplitude_rms ./ full_scale, floatmin(Float64))); ylabel = "Amplitude (dBFS RMS)"
    else
        values = 10log10.(max.(view.amplitude_rms .^ 2 ./ impedance ./ 1.0e-3, floatmin(Float64))); ylabel = "Power (dBm into $(engineering(impedance; unit = "Ω")))"
    end
    frequency_scale === :log && include_dc && throw(ArgumentError("DC cannot be displayed on a logarithmic frequency axis; use include_dc=false"))
    indices = include_dc ? collect(eachindex(view.frequencies)) : findall(>(0), view.frequencies)
    slot = _position(position)
    axis = frequency_scale === :log ? _frequency_axis(
            slot, view.frequencies[indices];
            xlabel = "Frequency (Hz)", ylabel
        ) : Makie.Axis(slot; xlabel = "Frequency (Hz)", ylabel)
    plot = Makie.stem!(axis, view.frequencies[indices], values[indices]; kwargs...)
    band_annotation = nothing
    if band !== nothing
        low, high = Float64(first(band)), Float64(last(band))
        power = Amber.band_power(result, low => high)
        band_annotation = Makie.vspan!(axis, low, high; color = (_AMBER_COLORS.nominal, 0.12))
        Makie.text!(
            axis, 0.98, 0.98; space = :relative, align = (:right, :top),
            text = "Band RMS: $(engineering(sqrt(power); unit = "V"))"
        )
    end
    if fundamental !== nothing
        classifications = [
            spectrum_cursor(result, frequency; fundamental).classification
                for frequency in view.frequencies[indices]
        ]
        harmonic_indices = findall(classification -> classification in (:fundamental, :harmonic), classifications)
        isempty(harmonic_indices) || Makie.scatter!(
            axis,
            view.frequencies[indices][harmonic_indices], values[indices][harmonic_indices];
            color = ifelse.(
                classifications[harmonic_indices] .=== :fundamental,
                _AMBER_COLORS.output, _AMBER_COLORS.candidate
            ), markersize = 8
        )
    end
    return PlotHandle(slot, (spectrum = axis,), (spectrum = plot, band = band_annotation), view)
end

function harmonicplot(position, result::Amber.HarmonicResult; orders = :all, color = nothing, kwargs...)
    components = vcat([result.fundamental], result.harmonics)
    orders === :all || (components = filter(c -> c.order in orders, components))
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel = "Harmonic order", ylabel = "Amplitude RMS")
    colors = color === nothing ? [_AMBER_COLORS.output; fill(_AMBER_COLORS.input, max(length(components) - 1, 0))] : color
    plot = Makie.barplot!(
        axis, getproperty.(components, :order), getproperty.(components, :amplitude_rms);
        color = colors, kwargs...
    )
    summary = "THD $(round(100result.thd; digits = 2))%\nSINAD $(round(result.sinad; digits = 1)) dB\nSFDR $(round(result.sfdr; digits = 1)) dB"
    Makie.text!(
        axis, 0.98, 0.98; text = summary, space = :relative,
        align = (:right, :top), fontsize = 11, color = :gray25
    )
    return PlotHandle(slot, (harmonics = axis,), (harmonics = plot,), result)
end

function spectrogramplot(
        position, result::Amber.SimulationResult; signal, window = :hann,
        samples = min(256, length(result.axis)), overlap = 0.5, nfft = nothing,
        detrend = :mean, scale = :db, floor_db = -180, kwargs...
    )
    scale in (:psd, :db) || throw(ArgumentError("scale must be :psd or :db"))
    view = spectrogramview(result; signal, window, samples, overlap, nfft, detrend)
    values = scale === :psd ? view.psd : 10 .* log10.(max.(view.psd, 10.0^(floor_db / 10)))
    slot = _position(position); layout = Makie.GridLayout(slot)
    axis = Makie.Axis(layout[1, 1]; xlabel = "Time (s)", ylabel = "Frequency (Hz)")
    plot = Makie.heatmap!(axis, view.times, view.frequencies, permutedims(values); kwargs...)
    Makie.Colorbar(layout[1, 2], plot; label = scale === :psd ? "PSD" : "PSD (dB/Hz)")
    return PlotHandle(layout, (spectrogram = axis,), (spectrogram = plot,), view)
end

function waterfallplot(
        position, x::AbstractVector, sweeps::AbstractVector,
        values::AbstractMatrix; scale = :linear, floor_db = -180, kwargs...
    )
    size(values) == (length(x), length(sweeps)) || throw(
        DimensionMismatch(
            "waterfall values must have size (length(x), length(sweeps))"
        )
    )
    scale in (:linear, :db) || throw(ArgumentError("scale must be :linear or :db"))
    displayed = scale === :linear ? Float64.(real.(values)) :
        20log10.(max.(abs.(values), 10.0^(floor_db / 20)))
    slot = _position(position)
    axis = Makie.Axis3(slot; xlabel = "X", ylabel = "Sweep", zlabel = scale === :db ? "Value (dB)" : "Value")
    plots = [
        Makie.lines!(
            axis, Float64.(x), fill(Float64(sweeps[index]), length(x)),
            displayed[:, index]; color = index, colormap = :viridis, colorrange = (1, length(sweeps)),
            kwargs...
        ) for index in eachindex(sweeps)
    ]
    return PlotHandle(
        slot, (waterfall = axis,), (waterfall = plots,),
        (x = Float64.(x), sweeps = Float64.(sweeps), values = displayed, scale)
    )
end
