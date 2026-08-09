abstract type AbstractDisplayView end

struct TraceView{X<:AbstractVector,Y<:AbstractVector} <: AbstractDisplayView
    axis::X
    values::Y
    label::String
    quantity::Symbol
    unit::String
    warnings::Vector{String}
    provenance::Dict
end

struct FrequencyView{F<:AbstractVector,R<:AbstractVector} <: AbstractDisplayView
    frequencies::F
    response::R
    input_label::String
    output_label::String
    warnings::Vector{String}
    provenance::Dict
end

struct SpectrumView{F<:AbstractVector,A<:AbstractVector,P<:AbstractVector} <: AbstractDisplayView
    frequencies::F
    amplitude_rms::A
    psd::P
    window::Symbol
    warnings::Vector{String}
    provenance::Dict
end

struct NoiseView{F<:AbstractVector,D<:AbstractVector} <: AbstractDisplayView
    frequencies::F
    density::D
    referred::Symbol
    unit::String
    warnings::Vector{String}
    provenance::Dict
end

struct NetworkView{F<:AbstractVector,V<:AbstractVector} <: AbstractDisplayView
    frequencies::F
    values::V
    parameter::Symbol
    element::Tuple{Int,Int}
    port_labels::Vector{String}
    reference_impedances::Vector{Float64}
    warnings::Vector{String}
    provenance::Dict
end

struct EnsembleView{X<:AbstractVector,M<:AbstractVector} <: AbstractDisplayView
    indices::X
    metrics::M
    converged::BitVector
    failures::Vector
    parameter_values::Vector
    warnings::Vector{String}
    provenance::Dict
end

_warnings(stats) = String.(get(stats, :warnings, String[]))
_provenance(result) = try Dict(Amber.provenance(result)) catch; Dict{Any,Any}() end

function _signal_metadata(signal)
    text = string(signal)
    if occursin("current", lowercase(text))
        return :current, "A"
    elseif occursin("power", lowercase(text))
        return :power, "W"
    elseif occursin("charge", lowercase(text))
        return :charge, "C"
    end
    :voltage, "V"
end

function _signal_label(signal)
    hasproperty(signal, :kind) || return string(signal)
    kind = getproperty(signal, :kind)
    target = getproperty(signal, :target)
    extra = getproperty(signal, :extra)
    prefix = kind === :voltage ? "V" : kind === :current ? "I" : uppercasefirst(String(kind))
    extra === nothing ? "$(prefix)($(target))" : "$(prefix)($(target), $(extra))"
end

function traceview(result::Amber.SimulationResult, signal; label=nothing)
    result.analysis isa Union{Amber.Transient,Amber.TransientNoise} ||
        throw(ArgumentError("traceview requires a transient result"))
    values = collect(Amber.trace(result, signal))
    length(values) == length(result.axis) || throw(DimensionMismatch("trace and axis lengths differ"))
    quantity, unit = _signal_metadata(signal)
    TraceView(result.axis, values, something(label, _signal_label(signal)), quantity, unit,
        _warnings(result.stats), _provenance(result))
end

function frequencyview(result::Amber.SimulationResult; input, output)
    result.analysis isa Amber.SmallSignal ||
        throw(ArgumentError("frequencyview requires a small-signal result"))
    response = collect(Amber.transfer(result; input, output))
    FrequencyView(Amber.frequencies(result), response, _signal_label(input), _signal_label(output),
        _warnings(result.stats), _provenance(result))
end

function spectrumview(result::Amber.SpectrumResult)
    SpectrumView(result.frequencies, result.amplitude_rms, result.psd, result.window,
        _warnings(result.stats), _provenance(result))
end

function noiseview(result::Amber.NoiseResult; referred=:output)
    referred in (:output, :input) || throw(ArgumentError("referred must be :output or :input"))
    density = referred === :output ? Amber.noise_density(result) : Amber.input_referred_noise_density(result)
    density === nothing && throw(ArgumentError("input-referred noise is unavailable for this result"))
    NoiseView(result.frequencies, density, referred, "V/√Hz", _warnings(result.stats),
        _provenance(result))
end

function networkview(result::Amber.NetworkResult; parameter=:s, element=(2, 1))
    matrix = Amber.network_parameters(result, Symbol(parameter))
    row, column = element
    checkbounds(matrix, row, column, :)
    labels = [something(port.name, Symbol("port", index)) |> string for (index, port) in enumerate(result.ports)]
    NetworkView(result.frequencies, vec(matrix[row, column, :]), Symbol(parameter),
        (row, column), labels, getproperty.(result.ports, :reference_impedance),
        _warnings(result.stats), _provenance(result))
end

function ensembleview(result::Union{Amber.SweepResult,Amber.MonteCarloResult})
    values = result isa Amber.SweepResult ? result.metrics : result.values
    parameters = result isa Amber.SweepResult ? result.parameter_values : result.parameters
    EnsembleView(collect(eachindex(values)), collect(values), copy(result.converged),
        copy(result.failures), collect(parameters), String[], _provenance(result))
end
