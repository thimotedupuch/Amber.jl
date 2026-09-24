function noiseplot(position, result::Amber.NoiseResult; referred = :output, kwargs...)
    view = noiseview(result; referred)
    slot = _position(position)
    positive = filter(x -> isfinite(x) && x > 0, view.density)
    logarithmic = !isempty(positive)
    axis = _frequency_axis(
        slot, view.frequencies; yscale = logarithmic ? log10 : identity, xlabel = "Frequency (Hz)",
        ylabel = string(titlecase(String(referred)), "-referred noise density (", view.unit, ")")
    )
    if logarithmic
        axis.yminorticks = _log_minor_ticks(positive)
        axis.yminorticksvisible = true
        axis.yminorgridvisible = true
    end
    displayed = logarithmic ? [isfinite(y) && y > 0 ? y : NaN for y in view.density] : view.density
    plot = Makie.lines!(axis, view.frequencies, displayed; kwargs...)
    return PlotHandle(slot, (noise = axis,), (noise = plot,), view)
end


function _cumulative_noise(frequencies, psd)
    cumulative = zeros(Float64, length(frequencies))
    for index in 2:length(frequencies)
        cumulative[index] = cumulative[index - 1] +
            (psd[index - 1] + psd[index]) * (frequencies[index] - frequencies[index - 1]) / 2
    end
    return sqrt.(max.(cumulative, 0.0))
end

function integratednoiseplot(position, result::Amber.NoiseResult; referred = :output, kwargs...)
    view = noiseview(result; referred)
    psd = referred === :output ? Amber.noise_psd(result) : Amber.input_referred_noise_psd(result)
    cumulative = _cumulative_noise(view.frequencies, psd)
    slot = _position(position)
    axis = _frequency_axis(
        slot, view.frequencies; xlabel = "Frequency (Hz)",
        ylabel = string("Integrated ", titlecase(String(referred)), "-referred noise RMS (V)")
    )
    plot = Makie.lines!(axis, view.frequencies, cumulative; kwargs...)
    return PlotHandle(
        slot, (integrated_noise = axis,), (integrated_noise = plot,),
        (
            frequencies = view.frequencies, rms = cumulative, referred, warnings = view.warnings,
            provenance = view.provenance,
        )
    )
end

function noisecontributionplot(
        position, result::Amber.NoiseResult; top = 10,
        referred = :output, band = first(result.frequencies) => last(result.frequencies),
        group = :source, quantity = :variance, kwargs...
    )
    top >= 1 || throw(ArgumentError("top must be positive"))
    quantity in (:variance, :rms) || throw(ArgumentError("quantity must be :variance or :rms"))
    view = noisecontributionview(result; referred, band, group)
    count = min(Int(top), length(view.values))
    labels = view.labels[1:count]
    values = view.values[1:count]
    display_values = quantity === :rms ? sqrt.(values) : values
    slot = _position(position)
    axis = Makie.Axis(
        slot; xlabel = quantity === :rms ? "Integrated RMS noise (V)" : "Integrated noise variance (V²)",
        yticks = (1:count, labels), ylabel = titlecase(String(group))
    )
    plot = Makie.barplot!(axis, 1:count, display_values; direction = :x, kwargs...)
    Makie.ylims!(axis, count + 0.5, 0.5)
    return PlotHandle(slot, (noise_contributions = axis,), (noise_contributions = plot,), view)
end

function _grouped_noise_spectra(result, group, referred)
    group in (:source, :component, :mechanism) ||
        throw(ArgumentError("group must be :source, :component, or :mechanism"))
    grouped = Dict{Symbol, Vector{Float64}}()
    for contribution in result.contributions
        spectrum = if result isa Amber.PhaseNoiseResult
            contribution.output_psd
        elseif referred === :output
            contribution.output_psd
        elseif referred === :input
            contribution.input_referred_psd
        else
            throw(ArgumentError("referred must be :output or :input"))
        end
        spectrum === nothing && continue
        key = getproperty(contribution, group)
        values = get!(grouped, key, zeros(Float64, length(spectrum)))
        values .+= max.(Float64.(spectrum), 0.0)
    end
    return grouped
end

"""Stacked frequency-dependent noise budget grouped by source, component, or mechanism."""
function noisebudgetplot(
        position,
        result::Union{Amber.NoiseResult, Amber.PhaseNoiseResult};
        group = :component, referred = :output, top = 10, kwargs...
    )
    top >= 1 || throw(ArgumentError("top must be positive"))
    grouped = _grouped_noise_spectra(result, group, referred)
    isempty(grouped) && throw(ArgumentError("no noise contributions are available"))
    ranked = sort!(collect(grouped); by = pair -> sum(last(pair)), rev = true)
    selected = ranked[1:min(Int(top), length(ranked))]
    frequencies = result isa Amber.PhaseNoiseResult ? result.offset_frequencies :
        result.frequencies
    labels = string.(first.(selected))
    spectra = reduce(vcat, permutedims.(last.(selected)))
    slot = _position(position)
    unit = result isa Amber.PhaseNoiseResult ? "SSB phase-noise ratio (1/Hz)" :
        (
            referred === :output ? "Output noise PSD (V²/Hz)" :
            "Input-referred noise PSD (V²/Hz)"
        )
    axis = _frequency_axis(
        slot, frequencies; xlabel = "Frequency (Hz)", ylabel = unit,
        yscale = log10
    )
    # Machine epsilon is dimensionless and can exceed an entire physical PSD.
    positive = filter(x -> isfinite(x) && x > 0, vec(spectra))
    isempty(positive) && (axis.yscale = identity)
    floor_value = isempty(positive) ? 0.0 : max(floatmin(Float64), minimum(positive) * 1.0e-3)
    cumulative = fill(floor_value, length(frequencies))
    plots = Any[]
    for index in axes(spectra, 1)
        upper = cumulative .+ spectra[index, :]
        push!(
            plots, Makie.band!(
                axis, frequencies, cumulative, upper;
                label = labels[index], kwargs...
            )
        )
        cumulative = upper
    end
    Makie.axislegend(axis; position = :lt)
    return PlotHandle(
        slot, (noise_budget = axis,), (noise_budget = plots,),
        (
            frequencies, labels, spectra, total = vec(sum(spectra; dims = 1)), floor_value, group,
            referred = result isa Amber.PhaseNoiseResult ? :phase : referred,
            warnings = _warnings(result.stats), provenance = _provenance(result),
        )
    )
end

function _integrated_phase_noise(result::Amber.PhaseNoiseResult, band)
    low, high = Float64(first(band)), Float64(last(band))
    first(result.offset_frequencies) <= low < high <= last(result.offset_frequencies) ||
        throw(ArgumentError("phase-noise integration band must lie within the offset grid"))
    return sqrt(
        max(
            2 * _band_variance(
                result.offset_frequencies,
                result.phase_noise_ratio, low, high
            ), 0.0
        )
    )
end

function _phase_contribution_view(
        result::Amber.PhaseNoiseResult, band;
        group = :component
    )
    low, high = Float64(first(band)), Float64(last(band))
    first(result.offset_frequencies) <= low < high <= last(result.offset_frequencies) ||
        throw(ArgumentError("phase-noise band must lie within the offset grid"))
    grouped = _grouped_noise_spectra(result, group, :output)
    totals = Pair{Symbol, Float64}[]
    for (label, spectrum) in grouped
        push!(
            totals, label => 2 * _band_variance(
                result.offset_frequencies,
                spectrum, low, high
            )
        )
    end
    sort!(totals; by = last, rev = true)
    total = 2 * _band_variance(
        result.offset_frequencies,
        result.phase_noise_ratio, low, high
    )
    return NoiseContributionView(
        string.(first.(totals)), last.(totals), total,
        low => high, :phase, _warnings(result.stats), _provenance(result)
    )
end

function phasenoiseplot(
        position, result::Amber.PhaseNoiseResult;
        band = first(result.offset_frequencies) => last(result.offset_frequencies),
        carrier_frequency = nothing, kwargs...
    )
    phase_rms = _integrated_phase_noise(result, band)
    carrier_frequency === nothing || carrier_frequency > 0 ||
        throw(ArgumentError("carrier_frequency must be positive"))
    integrated = carrier_frequency === nothing ? phase_rms : phase_rms / (2π * carrier_frequency)
    metric = carrier_frequency === nothing ?
        "Integrated phase: $(engineering(integrated; unit = "rad RMS"))" :
        "Integrated jitter: $(engineering(integrated; unit = "s RMS"))"
    slot = _position(position); axis = _frequency_axis(
        slot, result.offset_frequencies;
        xlabel = "Offset frequency (Hz)", ylabel = "Phase noise (dBc/Hz)"
    )
    plot = Makie.lines!(
        axis, result.offset_frequencies,
        result.phase_noise_dbc_per_hz; kwargs...
    )
    Makie.vspan!(
        axis, Float64(first(band)), Float64(last(band));
        color = (_AMBER_COLORS.nominal, 0.12)
    )
    carrier = carrier_frequency === nothing ? "Carrier frequency not supplied" :
        "Carrier: $(engineering(carrier_frequency; unit = "Hz"))"
    Makie.text!(
        axis, 0.98, 0.98; text = "$(carrier)\n$(metric)", space = :relative,
        align = (:right, :top)
    )
    warnings = _warnings(result.stats)
    isempty(warnings) || Makie.text!(
        axis, 0.02, 0.02; text = join(warnings, "\n"),
        space = :relative, align = (:left, :bottom), color = _AMBER_COLORS.warning
    )
    return PlotHandle(
        slot, (phase_noise = axis,), (phase_noise = plot,),
        (
            offset_frequencies = result.offset_frequencies,
            phase_noise_dbc_per_hz = result.phase_noise_dbc_per_hz, band,
            carrier_frequency, integrated, phase_rms, warnings,
            provenance = _provenance(result),
        )
    )
end

function periodicnoiseplot(
        position, result::Amber.PeriodicNoiseResult;
        scale = :db, floor_db = -240, kwargs...
    )
    scale in (:psd, :db) || throw(ArgumentError("scale must be :psd or :db"))
    values = scale === :psd ? result.sideband_psd :
        10log10.(max.(result.sideband_psd, 10.0^(floor_db / 10)))
    size(values) == (length(result.sidebands), length(result.offset_frequencies)) ||
        throw(DimensionMismatch("periodic-noise sideband matrix dimensions are inconsistent"))
    slot = _position(position); layout = Makie.GridLayout(slot)
    axis = _frequency_axis(
        layout[1, 1], result.offset_frequencies;
        xlabel = "Offset frequency (Hz)", ylabel = "PSS sideband"
    )
    axis.yticks = (result.sidebands, string.(result.sidebands))
    frequencies = result.offset_frequencies
    length(frequencies) >= 2 || throw(ArgumentError("periodic-noise plot requires at least two offsets"))
    ratios = frequencies[2:end] ./ frequencies[1:(end - 1)]
    all(>(1), ratios) || throw(ArgumentError("offset frequencies must be strictly increasing"))
    frequency_edges = vcat(
        first(frequencies) / sqrt(first(ratios)),
        sqrt.(frequencies[1:(end - 1)] .* frequencies[2:end]),
        last(frequencies) * sqrt(last(ratios))
    )
    plot = Makie.heatmap!(axis, frequency_edges, result.sidebands, values'; kwargs...)
    Makie.Colorbar(layout[1, 2], plot; label = scale === :psd ? "PSD" : "PSD (dB/Hz)")
    return PlotHandle(
        layout, (periodic_noise = axis,), (sidebands = plot,),
        (
            offset_frequencies = result.offset_frequencies, sidebands = result.sidebands,
            sideband_psd = result.sideband_psd, output_harmonic = result.output_harmonic,
            warnings = _warnings(result.stats), provenance = _provenance(result),
        )
    )
end
