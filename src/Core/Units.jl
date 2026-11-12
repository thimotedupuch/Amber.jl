import Unitful
using Unitful: NoUnits, @u_str, uconvert, ustrip, uconvertrp, uconvertp

# Re-export Unitful's units so circuit notation keeps its familiar spelling.
for unit in (:Ω, :V, :A, :F, :H, :C, :s, :Hz, :S, :K, :m)
    @eval const $unit = getfield(Unitful, $(QuoteNode(unit)))
    for prefix in (:f, :p, :n, :μ, :m, :k, :M, :G, :T)
        name = Symbol(prefix, unit)
        @eval const $name = getfield(Unitful, $(QuoteNode(name)))
    end
end
const percent = Unitful.percent
const dB = Unitful.dB
const ° = Unitful.°

# Solver kernels store SI scalars. Convert quantities only at public boundaries.
const _PARAMETER_UNITS = Dict(
    :resistor => Dict(:value => Unitful.Ω),
    :capacitor => Dict(:value => Unitful.F, :esr => Unitful.Ω, :esl => Unitful.H,
        :leakage_resistance => Unitful.Ω, :initial_voltage => Unitful.V),
    :inductor => Dict(:value => Unitful.H, :winding_resistance => Unitful.Ω,
        :series_resistance => Unitful.Ω, :parallel_capacitance => Unitful.F),
    :conductance => Dict(:value => Unitful.S),
    :voltage_source => Dict(:dc => Unitful.V, :ac => Unitful.V, :series_resistance => Unitful.Ω),
    :current_source => Dict(:dc => Unitful.A, :ac => Unitful.A),
    :vccs => Dict(:gm => Unitful.S),
    :vcvs => Dict(:gain => Unitful.NoUnits),
    :cccs => Dict(:gain => Unitful.NoUnits),
    :ccvs => Dict(:transresistance => Unitful.Ω),
)
function _component_parameter(kind, name, value::Unitful.AbstractQuantity)
    units = get(_PARAMETER_UNITS, kind, nothing)
    target = name === :tolerance ? Unitful.NoUnits : isnothing(units) ? nothing : get(units, name, nothing)
    isnothing(target) && throw(ArgumentError("Unitful quantities are not yet supported for $kind.$name"))
    return float(Unitful.ustrip(target, value))
end
_component_parameter(kind, name, value) = name === :waveform && value !== nothing && !(value isa AbstractParameterExpression) ? SIWaveform(value, kind) : value

_si_value(value, units) = value
_si_value(value::Unitful.AbstractQuantity, units) = float(Unitful.ustrip(units, value))
_si_value(values::AbstractArray, units) = map(value -> _si_value(value, units), values)

# Model kernels use SI values; this table also validates dimensions on updates.
const _MODEL_PARAMETER_UNITS = Dict(
    :series_inductance => Unitful.H, :parallel_capacitance => Unitful.F,
    :esr => Unitful.Ω, :esl => Unitful.H,
    :temperature_coefficient => inv(Unitful.K), :tc1 => inv(Unitful.K),
    :voltage_coefficient => inv(Unitful.V),
    :reference_frequency => Unitful.Hz, :excess_reference_frequency => Unitful.Hz,
    :flicker_reference_frequency => Unitful.Hz,
    :time_constants => Unitful.s, :transit_time => Unitful.s,
    :saturation_current => Unitful.A, :breakdown_current => Unitful.A,
    :series_resistance => Unitful.Ω, :base_resistance => Unitful.Ω,
    :junction_capacitance => Unitful.F, :cbe_zero_bias => Unitful.F, :cbc_zero_bias => Unitful.F,
    :junction_potential => Unitful.V, :breakdown_voltage => Unitful.V,
    :early_voltage => Unitful.V, :threshold_voltage => Unitful.V,
    :transconductance => Unitful.A / Unitful.V^2,
    :channel_length_modulation => inv(Unitful.V), :body_effect => sqrt(Unitful.V),
    :surface_potential => Unitful.V,
    :gate_source_capacitance => Unitful.F, :gate_drain_capacitance => Unitful.F,
    :gate_bulk_capacitance => Unitful.F,
    :mobility => Unitful.m^2 / (Unitful.V * Unitful.s),
    :oxide_capacitance => Unitful.F / Unitful.m^2,
    :width => Unitful.m, :length => Unitful.m,
    :reference_temperature => Unitful.K,
    :threshold_temperature_coefficient => Unitful.V / Unitful.K,
    :gate_source_overlap => Unitful.F / Unitful.m,
    :gate_drain_overlap => Unitful.F / Unitful.m,
    :drain_area => Unitful.m^2, :source_area => Unitful.m^2,
    :drain_perimeter => Unitful.m, :source_perimeter => Unitful.m,
    :junction_capacitance_density => Unitful.F / Unitful.m^2,
    :junction_sidewall_capacitance => Unitful.F / Unitful.m,
    :junction_saturation_current_density => Unitful.A / Unitful.m^2,
    :gain_bandwidth => Unitful.Hz, :slew_rate => Unitful.V / Unitful.s,
    :output_resistance => Unitful.Ω, :output_current_limit => Unitful.A,
    :input_offset => Unitful.V, :input_bias_current => Unitful.A,
    :input_capacitance => Unitful.F,
    :input_voltage_noise_density => Unitful.V / sqrt(Unitful.Hz),
    :positive_input_current_noise_density => Unitful.A / sqrt(Unitful.Hz),
    :negative_input_current_noise_density => Unitful.A / sqrt(Unitful.Hz),
    :input_voltage_flicker_corner => Unitful.Hz, :input_current_flicker_corner => Unitful.Hz,
    :saturation_recovery => Unitful.s,
    :threshold => Unitful.V, :transition => Unitful.V,
    :ron => Unitful.Ω, :roff => Unitful.Ω, :charge_injection => Unitful.C,
    :clock_feedthrough => Unitful.F,
)
_model_parameter(name, value) = _si_value(value, get(_MODEL_PARAMETER_UNITS, name, Unitful.NoUnits))
_model_parameters(values::NamedTuple) = (; (name => _model_parameter(name, value) for (name, value) in pairs(values))...)

const _ANALYSIS_PARAMETER_UNITS = Dict(
    :temperature => Unitful.K, :voltage_abstol => Unitful.V,
    :current_abstol => Unitful.A, :min_step => Unitful.s,
    :timestep => Unitful.s, :saveat => Unitful.s, :max_step => Unitful.s,
    :low_frequency_cutoff => Unitful.Hz, :frequencies => Unitful.Hz,
)
_analysis_parameter(name, value) = _si_value(value, get(_ANALYSIS_PARAMETER_UNITS, name, Unitful.NoUnits))
_analysis_parameter(name, value::Pair) = name === :interval ? _si_value(first(value), Unitful.s) => _si_value(last(value), Unitful.s) : value

for (kind, units) in (
    :photodiode => Dict(:photocurrent => Unitful.A),
    :solar_cell => Dict(:photocurrent => Unitful.A, :shunt_resistance => Unitful.Ω),
    :potentiometer => Dict(:resistance => Unitful.Ω, :position => Unitful.NoUnits),
    :ideal_transformer => Dict(:ratio => Unitful.NoUnits),
    :crystal => Dict(:motional_resistance => Unitful.Ω, :motional_inductance => Unitful.H,
        :motional_capacitance => Unitful.F, :shunt_capacitance => Unitful.F),
    :transmission_line => Dict(:resistance => Unitful.Ω, :inductance => Unitful.H,
        :conductance => Unitful.S, :capacitance => Unitful.F),
)
    _PARAMETER_UNITS[kind] = units
end

_normalized_component_parameters(kind, parameters) = (; (name => _component_parameter(kind, name, value) for (name, value) in pairs(parameters))...)

# Voltage/current gains are root-power ratios; Unitful keeps that distinction explicit.
_model_parameter(name, value::Unitful.Gain) = name === :dc_gain ?
    Unitful.uconvertrp(Unitful.NoUnits, value) : Unitful.uconvert(get(_MODEL_PARAMETER_UNITS, name, Unitful.NoUnits), value)

function _component_parameter(kind, name, value::Unitful.Gain)
    kind in (:vcvs, :cccs) && name === :gain ||
        throw(ArgumentError("logarithmic gains require a dimensionless voltage or current gain"))
    return Unitful.uconvertrp(Unitful.NoUnits, value)
end
