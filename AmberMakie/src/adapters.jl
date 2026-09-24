abstract type AbstractDisplayView end

struct TraceView{X <: AbstractVector, Y <: AbstractVector} <: AbstractDisplayView
    axis::X
    values::Y
    label::String
    quantity::Symbol
    unit::String
    warnings::Vector{String}
    provenance::Dict
end

struct FrequencyView{F <: AbstractVector, R <: AbstractVector} <: AbstractDisplayView
    frequencies::F
    response::R
    input_label::String
    output_label::String
    warnings::Vector{String}
    provenance::Dict
end

struct SpectrumView{F <: AbstractVector, A <: AbstractVector, P <: AbstractVector} <: AbstractDisplayView
    frequencies::F
    amplitude_rms::A
    psd::P
    window::Symbol
    warnings::Vector{String}
    provenance::Dict
end

struct SpectrumCursorReadout
    index::Int
    frequency::Float64
    amplitude_rms::Float64
    phase_degrees::Float64
    psd::Float64
    classification::Symbol
    harmonic_order::Union{Nothing, Int}
end

struct SpectrogramView{T <: AbstractVector, F <: AbstractVector, P <: AbstractMatrix} <: AbstractDisplayView
    times::T
    frequencies::F
    psd::P
    signal::String
    window::Symbol
    overlap::Float64
    warnings::Vector{String}
    provenance::Dict
end

struct NoiseView{F <: AbstractVector, D <: AbstractVector} <: AbstractDisplayView
    frequencies::F
    density::D
    referred::Symbol
    unit::String
    warnings::Vector{String}
    provenance::Dict
end

struct NoiseContributionView{V <: AbstractVector} <: AbstractDisplayView
    labels::Vector{String}
    values::V
    total_variance::Float64
    band::Pair{Float64, Float64}
    referred::Symbol
    warnings::Vector{String}
    provenance::Dict
end

struct NetworkView{F <: AbstractVector, V <: AbstractVector} <: AbstractDisplayView
    frequencies::F
    values::V
    parameter::Symbol
    element::Tuple{Int, Int}
    port_labels::Vector{String}
    reference_impedances::Vector{Float64}
    warnings::Vector{String}
    provenance::Dict
end

struct EnsembleView{X <: AbstractVector, M <: AbstractVector} <: AbstractDisplayView
    indices::X
    metrics::M
    converged::BitVector
    failures::Vector
    parameter_values::Vector
    warnings::Vector{String}
    provenance::Dict
end

struct OperatingPointView <: AbstractDisplayView
    nodes::Vector{NamedTuple}
    devices::Vector{NamedTuple}
    convergence::NamedTuple
    warnings::Vector{String}
    provenance::Dict
end

struct EyeDiagramView <: AbstractDisplayView
    phases::Vector{Vector{Float64}}
    values::Vector{Vector{Float64}}
    period::Float64
    unit_intervals::Int
    signal::String
    violations::Vector{NamedTuple}
    warnings::Vector{String}
    provenance::Dict
end

struct JitterView <: AbstractDisplayView
    crossings::Vector{Float64}
    nominal_period::Float64
    tie::Vector{Float64}
    period_jitter::Vector{Float64}
    cycle_to_cycle::Vector{Float64}
    threshold::Float64
    edge::Symbol
    signal::String
    warnings::Vector{String}
    provenance::Dict
end

function _threshold_crossings(times, values, threshold, edge)
    crossings = Float64[]
    for index in 1:(length(times) - 1)
        first_value = values[index] - threshold
        second_value = values[index + 1] - threshold
        matches = edge === :rising ? first_value < 0 <= second_value :
            first_value > 0 >= second_value
        matches || continue
        difference = values[index + 1] - values[index]
        iszero(difference) && continue
        fraction = (threshold - values[index]) / difference
        push!(crossings, times[index] + fraction * (times[index + 1] - times[index]))
    end
    return crossings
end

function jitterview(
        result::Amber.SimulationResult; signal, threshold = nothing,
        edge = :rising, nominal_period = nothing
    )
    result.analysis isa Union{Amber.Transient, Amber.TransientNoise} ||
        throw(ArgumentError("jitterview requires a transient result"))
    edge in (:rising, :falling) ||
        throw(ArgumentError("edge must be :rising or :falling"))
    values = Float64.(real.(Amber.trace(result, signal)))
    isempty(values) && throw(ArgumentError("jitter trace is empty"))
    level = threshold === nothing ? (minimum(values) + maximum(values)) / 2 : Float64(threshold)
    crossings = _threshold_crossings(result.axis, values, level, edge)
    length(crossings) >= 3 || throw(
        ArgumentError(
            "jitter analysis requires at least three threshold crossings"
        )
    )
    periods = diff(crossings)
    nominal = nominal_period === nothing ? sort(periods)[cld(length(periods), 2)] :
        Float64(nominal_period)
    nominal > 0 || throw(ArgumentError("nominal_period must be positive"))
    ideal = first(crossings) .+ (0:(length(crossings) - 1)) .* nominal
    tie = crossings .- ideal
    period_jitter = periods .- nominal
    cycle_to_cycle = diff(periods)
    return JitterView(
        crossings, nominal, tie, period_jitter, cycle_to_cycle, level,
        Symbol(edge), _signal_label(signal), _warnings(result.stats), _provenance(result)
    )
end

function eyediagramview(
        result::Amber.SimulationResult; signal, period,
        unit_intervals::Integer = 2, offset = first(result.axis), mask = nothing
    )
    result.analysis isa Union{Amber.Transient, Amber.TransientNoise} ||
        throw(ArgumentError("eyediagramview requires a transient result"))
    period = Float64(period)
    period > 0 || throw(ArgumentError("period must be positive"))
    unit_intervals >= 1 || throw(ArgumentError("unit_intervals must be positive"))
    times = result.axis; trace = Float64.(real.(Amber.trace(result, signal)))
    length(times) == length(trace) || throw(DimensionMismatch("trace and time lengths differ"))
    window = unit_intervals * period
    cycle = floor.(Int, (times .- Float64(offset)) ./ window)
    phases = Vector{Float64}[]; values = Vector{Float64}[]
    violations = NamedTuple[]
    for index in unique(cycle)
        indices = findall(==(index), cycle)
        length(indices) >= 2 || continue
        local_phase = (times[indices] .- Float64(offset) .- index * window) ./ period
        local_values = trace[indices]
        push!(phases, local_phase); push!(values, local_values)
        mask === nothing || foreach(eachindex(local_phase)) do point
            mask(local_phase[point], local_values[point]) && push!(
                violations,
                (
                    time = times[indices[point]], phase = local_phase[point],
                    value = local_values[point], cycle = index,
                )
            )
        end
    end
    warnings = _warnings(result.stats)
    isempty(phases) && push!(warnings, "record does not contain a complete eye trace")
    return EyeDiagramView(
        phases, values, period, Int(unit_intervals), _signal_label(signal),
        violations, warnings, _provenance(result)
    )
end

function operatingpointview(result::Amber.SimulationResult; query = "", kind = nothing)
    result.analysis isa Amber.OperatingPoint ||
        throw(ArgumentError("operatingpointview requires an operating-point result"))
    needle = query === nothing ? "" : lowercase(String(query))
    matches(name) = isempty(needle) || occursin(needle, lowercase(String(name)))
    node_rows = NamedTuple[]
    for node in Amber.nets(result.compiled.design; limit = typemax(Int))
        name = string(node.path)
        matches(name) || continue
        value = node.ground ? 0.0 : Float64(real(only(Amber.voltage(result, name))))
        push!(node_rows, (name, voltage = value, ground = node.ground))
    end
    device_rows = NamedTuple[]
    for device in Amber.devices(result.compiled.design; limit = typemax(Int))
        kind === nothing || device.kind === Symbol(kind) || continue
        name = string(device.path)
        matches(name) || continue
        current = try
            Float64(real(only(Amber.current(result, name))))
        catch
            nothing
        end
        power = try
            Float64(real(only(Amber.power(result, name))))
        catch
            nothing
        end
        region = try
            Symbol(string(Amber.region(result, name)))
        catch
            nothing
        end
        push!(device_rows, (name, kind = device.kind, current, power, region))
    end
    stats = result.stats
    convergence = (
        converged = Bool(get(stats, :converged, false)),
        iterations = get(stats, :iterations, nothing),
        strategy = get(stats, :strategy, nothing),
        continuation_steps = get(stats, :continuation_steps, nothing),
        rejected_steps = get(stats, :rejected_continuation_steps, nothing),
        failed_steps = copy(get(stats, :failed_continuation_steps, Int[])),
        dominant_residual = get(stats, :dominant_residual, nothing),
        history = copy(get(stats, :residual_history, Any[])),
        history_available = haskey(stats, :residual_history),
        temperature = get(stats, :temperature, nothing),
    )
    return OperatingPointView(
        node_rows, device_rows, convergence, _warnings(stats),
        _provenance(result)
    )
end

function diagnosticgroups(result)
    report = Amber.validity_report(result)
    warnings = String.(get(report, :warnings, String[]))
    device_names = sort!(String.(collect(keys(get(report, :devices, Dict())))))
    grouped = Dict{String, Vector{String}}("General" => String[])
    for warning in warnings
        owner = findfirst(name -> startswith(warning, name * ":"), device_names)
        key = owner === nothing ? "General" : device_names[owner]
        push!(get!(grouped, key, String[]), warning)
    end
    filter!(pair -> !isempty(last(pair)), grouped)
    return (groups = grouped, devices = get(report, :devices, Dict()), warnings, report)
end

_warnings(stats) = String.(get(stats, :warnings, String[]))
_provenance(result) = try
    Dict(Amber.provenance(result))
catch
    Dict{Any, Any}()
end

function _signal_metadata(signal)
    text = string(signal)
    if occursin("current", lowercase(text))
        return :current, "A"
    elseif occursin("power", lowercase(text))
        return :power, "W"
    elseif occursin("charge", lowercase(text))
        return :charge, "C"
    end
    return :voltage, "V"
end

function _signal_label(signal)
    hasproperty(signal, :kind) || return string(signal)
    kind = getproperty(signal, :kind)
    target = getproperty(signal, :target)
    extra = getproperty(signal, :extra)
    prefix = kind === :voltage ? "V" : kind === :current ? "I" : uppercasefirst(String(kind))
    return extra === nothing ? "$(prefix)($(target))" : "$(prefix)($(target), $(extra))"
end

function traceview(result::Amber.SimulationResult, signal; label = nothing)
    result.analysis isa Union{Amber.Transient, Amber.TransientNoise} ||
        throw(ArgumentError("traceview requires a transient result"))
    values = collect(Amber.trace(result, signal))
    length(values) == length(result.axis) || throw(DimensionMismatch("trace and axis lengths differ"))
    quantity, unit = _signal_metadata(signal)
    return TraceView(
        result.axis, values, something(label, _signal_label(signal)), quantity, unit,
        _warnings(result.stats), _provenance(result)
    )
end

function frequencyview(result::Amber.SimulationResult; input, output)
    result.analysis isa Amber.SmallSignal ||
        throw(ArgumentError("frequencyview requires a small-signal result"))
    response = collect(Amber.transfer(result; input, output))
    return FrequencyView(
        Amber.frequencies(result), response, _signal_label(input), _signal_label(output),
        _warnings(result.stats), _provenance(result)
    )
end

function spectrumview(result::Amber.SpectrumResult)
    return SpectrumView(
        result.frequencies, result.amplitude_rms, result.psd, result.window,
        _warnings(result.stats), _provenance(result)
    )
end

function spectrum_cursor(result::Amber.SpectrumResult, frequency::Real; fundamental = nothing)
    isempty(result.frequencies) && throw(ArgumentError("spectrum contains no bins"))
    index = argmin(abs.(result.frequencies .- frequency))
    classification = index == 1 && iszero(result.frequencies[index]) ? :dc : :spur
    order = nothing
    if fundamental !== nothing
        fundamental_frequency = Float64(fundamental)
        fundamental_frequency > 0 || throw(ArgumentError("fundamental must be positive"))
        candidate = round(Int, result.frequencies[index] / fundamental_frequency)
        bin_width = length(result.frequencies) > 1 ?
            minimum(diff(result.frequencies)) : Inf
        if candidate >= 1 && abs(result.frequencies[index] - candidate * fundamental_frequency) <= bin_width / 2
            order = candidate
            classification = candidate == 1 ? :fundamental : :harmonic
        end
    end
    return SpectrumCursorReadout(
        index, result.frequencies[index], result.amplitude_rms[index],
        rad2deg(angle(result.coefficients[index])), result.psd[index], classification, order
    )
end

function spectrum_cursor(result::Amber.HarmonicResult, frequency::Real)
    readout = spectrum_cursor(
        result.spectrum, frequency;
        fundamental = result.fundamental.frequency
    )
    known = vcat([result.fundamental], result.harmonics)
    component = findfirst(item -> item.bin == readout.index, known)
    component === nothing && return readout
    item = known[component]
    return SpectrumCursorReadout(
        readout.index, readout.frequency, readout.amplitude_rms,
        readout.phase_degrees, readout.psd, item.order == 1 ? :fundamental : :harmonic,
        item.order
    )
end

function spectrogramview(
        result::Amber.SimulationResult; signal, window = :hann,
        samples = min(256, length(result.axis)), overlap = 0.5, nfft = nothing, detrend = :mean
    )
    result.analysis isa Union{Amber.Transient, Amber.TransientNoise} ||
        throw(ArgumentError("spectrogramview requires a transient result"))
    kind = Symbol(window)
    count = Int(samples)
    4 <= count <= length(result.axis) ||
        throw(ArgumentError("samples must be between 4 and the transient sample count"))
    0 <= overlap < 1 || throw(ArgumentError("overlap must lie in [0, 1)"))
    step = max(1, round(Int, count * (1 - overlap)))
    starts = collect(1:step:(length(result.axis) - count + 1))
    isempty(starts) && throw(ArgumentError("transient is too short for the selected window"))
    transform_length = nfft === nothing ? count : Int(nfft)
    transform_length >= count || throw(ArgumentError("nfft must be at least samples"))
    spectra = [
        Amber.spectrum(
            result; signal, window = kind,
            interval = result.axis[start] => result.axis[start + count - 1],
            nfft = transform_length, detrend
        ) for start in starts
    ]
    reference = first(spectra).frequencies
    all(
        spectrum -> length(spectrum.frequencies) == length(reference) &&
            all(isapprox.(spectrum.frequencies, reference; rtol = 1.0e-6, atol = 0)), spectra
    ) ||
        throw(ArgumentError("spectrogram windows produced incompatible frequency grids"))
    times = [(result.axis[start] + result.axis[start + count - 1]) / 2 for start in starts]
    psd = reduce(hcat, getproperty.(spectra, :psd))
    warnings = unique(
        vcat(
            _warnings(result.stats),
            (String.(get(spectrum.stats, :warnings, String[])) for spectrum in spectra)...
        )
    )
    return SpectrogramView(
        times, reference, psd, _signal_label(signal), kind, Float64(overlap),
        warnings, _provenance(result)
    )
end

function noiseview(result::Amber.NoiseResult; referred = :output)
    referred in (:output, :input) || throw(ArgumentError("referred must be :output or :input"))
    density = referred === :output ? Amber.noise_density(result) : Amber.input_referred_noise_density(result)
    density === nothing && throw(ArgumentError("input-referred noise is unavailable for this result"))
    return NoiseView(
        result.frequencies, density, referred, "V/√Hz", _warnings(result.stats),
        _provenance(result)
    )
end

function _band_variance(frequencies, psd, low, high)
    edge(edge_frequency) = begin
        exact = findfirst(==(edge_frequency), frequencies)
        exact !== nothing && return psd[exact]
        upper = searchsortedfirst(frequencies, edge_frequency)
        lower = upper - 1
        fraction = (edge_frequency - frequencies[lower]) /
            (frequencies[upper] - frequencies[lower])
        psd[lower] + fraction * (psd[upper] - psd[lower])
    end
    inside = findall(frequency -> low < frequency < high, frequencies)
    selected_frequencies = vcat(low, frequencies[inside], high)
    selected_psd = vcat(edge(low), psd[inside], edge(high))
    return sum(
        (selected_psd[index] + selected_psd[index + 1]) *
            (selected_frequencies[index + 1] - selected_frequencies[index]) / 2
            for index in 1:(length(selected_frequencies) - 1)
    )
end

function noisecontributionview(
        result::Amber.NoiseResult; referred = :output,
        band = first(result.frequencies) => last(result.frequencies), group = :source
    )
    referred in (:output, :input) || throw(ArgumentError("referred must be :output or :input"))
    group in (:source, :component, :mechanism) ||
        throw(ArgumentError("group must be :source, :component, or :mechanism"))
    low, high = Float64(first(band)), Float64(last(band))
    first(result.frequencies) <= low < high <= last(result.frequencies) ||
        throw(ArgumentError("band must lie within the evaluated frequency range"))
    totals = Dict{Symbol, Float64}()
    for contribution in result.contributions
        values = referred === :output ? contribution.output_psd : contribution.input_referred_psd
        values === nothing && continue
        variance = _band_variance(result.frequencies, values, low, high)
        key = getproperty(contribution, group)
        totals[key] = get(totals, key, 0.0) + max(variance, 0.0)
    end
    ranked = sort!(collect(totals); by = last, rev = true)
    total_psd = referred === :output ? Amber.noise_psd(result) : Amber.input_referred_noise_psd(result)
    total_psd === nothing && throw(ArgumentError("input-referred noise is unavailable for this result"))
    total = _band_variance(result.frequencies, total_psd, low, high)
    return NoiseContributionView(
        string.(first.(ranked)), last.(ranked), total, low => high,
        referred, _warnings(result.stats), _provenance(result)
    )
end

function networkview(result::Amber.NetworkResult; parameter = :s, element = (2, 1))
    matrix = Amber.network_parameters(result, Symbol(parameter))
    row, column = element
    checkbounds(matrix, row, column, :)
    labels = [something(port.name, Symbol("port", index)) |> string for (index, port) in enumerate(result.ports)]
    return NetworkView(
        result.frequencies, vec(matrix[row, column, :]), Symbol(parameter),
        (row, column), labels, getproperty.(result.ports, :reference_impedance),
        _warnings(result.stats), _provenance(result)
    )
end

function ensembleview(result::Union{Amber.SweepResult, Amber.MonteCarloResult})
    values = result isa Amber.SweepResult ? result.metrics : result.values
    parameters = result isa Amber.SweepResult ? result.parameter_values : result.parameters
    return EnsembleView(
        collect(eachindex(values)), collect(values), copy(result.converged),
        copy(result.failures), collect(parameters), String[], _provenance(result)
    )
end
