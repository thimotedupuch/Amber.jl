abstract type AbstractWaveform end

_validate_model_parameters(model)=model

"""Return the named numerical parameters exposed by a device model."""
model_parameters(model)=throw(ArgumentError("model $(typeof(model)) does not implement model_parameters"))

"""Return a model copy with one numerical parameter replaced.

User-defined model types can participate in compiled parameter updates by
implementing `model_parameters(model)` and `with_model_parameter(model, name, value)`.
"""
with_model_parameter(model,name::Symbol,value)=throw(ArgumentError(
    "model $(typeof(model)) does not implement with_model_parameter"))

Base.@kwdef struct Step <: AbstractWaveform
    low::Float64=0.; high::Float64=1.; at::Float64=0.; rise::Float64=0.
end
Base.@kwdef struct Sine <: AbstractWaveform
    amplitude::Float64=1.; frequency::Float64=1.; phase::Float64=0.; offset::Float64=0.
end
Base.@kwdef struct Pulse <: AbstractWaveform
    low::Float64=0.; high::Float64=1.; frequency::Float64=1.; duty_cycle::Float64=.5
    rise::Float64=0.; fall::Float64=0.; delay::Float64=0.
end

(w::Step)(t)=t<w.at ? w.low : w.rise<=0 ? w.high : w.low+(w.high-w.low)*clamp((t-w.at)/w.rise,0,1)
(w::Sine)(t)=w.offset+w.amplitude*sin(2π*w.frequency*t+w.phase)
function (w::Pulse)(t)
    t<w.delay&&return w.low
    τ=mod(t-w.delay,1/w.frequency); on=w.duty_cycle/w.frequency
    τ<w.rise&&w.rise>0&&return w.low+(w.high-w.low)*τ/w.rise
    τ<on&&return w.high
    τ<on+w.fall&&w.fall>0&&return w.high+(w.low-w.high)*(τ-on)/w.fall
    w.low
end

function _validate_waveform(w::Pulse)
    isfinite(w.frequency)&&w.frequency>0||throw(AnalysisValidationError("pulse frequency must be finite and positive"))
    0<=w.duty_cycle<=1||throw(AnalysisValidationError("pulse duty cycle must lie in [0, 1]"))
    w.rise>=0&&w.fall>=0||throw(AnalysisValidationError("pulse rise and fall times must be non-negative"))
    w.rise+w.fall<=inv(w.frequency)||throw(AnalysisValidationError("pulse rise and fall times exceed its period"))
    w
end
function _validate_waveform(w::Step)
    isfinite(w.at)&&isfinite(w.rise)&&w.rise>=0||throw(AnalysisValidationError("step time and rise time must be finite, with non-negative rise")); w
end
function _validate_waveform(w::Sine)
    isfinite(w.frequency)&&w.frequency>=0||throw(AnalysisValidationError("sine frequency must be finite and non-negative")); w
end

"""Base type for Amber's parameterized built-in device models."""
abstract type AbstractDeviceModel end
"""Resistor technology with explicit power-law excess-noise parameters."""
abstract type AbstractResistorMaterial <: AbstractDeviceModel end
"""Lumped passive-package parasitics; values must be supplied for the actual part."""
abstract type AbstractPassivePackage <: AbstractDeviceModel end
"""Capacitor dielectric represented by loss at a specified reference frequency."""
abstract type AbstractCapacitorDielectric <: AbstractDeviceModel end

const _RESISTOR_MATERIAL_NAMES = (:ThinFilm, :ThickFilm, :MetalFilm, :CarbonFilm,
    :CarbonComposition, :MetalFoil, :Wirewound)
const _PASSIVE_PACKAGE_NAMES = (:SMD0201, :SMD0402, :SMD0603, :SMD0805, :SMD1206,
    :SMD1210, :SMD2010, :SMD2512, :Axial, :Radial, :PassivePackage)
const _CAPACITOR_DIELECTRIC_NAMES = (:C0G, :X7R, :X5R, :Polypropylene, :Polyester,
    :PPS, :Mica, :AluminumElectrolytic, :Tantalum)

for (T,defaults) in (
    ((name, :(;tc1=0.,temperature_coefficient=0.,voltage_coefficient=0.,
        excess_noise_coefficient=0.,excess_current_exponent=2.,
        excess_frequency_exponent=1.,excess_reference_frequency=1.))
        for name in _RESISTOR_MATERIAL_NAMES)...,
    ((name, :(;series_inductance=0.,parallel_capacitance=0.,esr=0.,esl=0.))
        for name in _PASSIVE_PACKAGE_NAMES)...,
    ((name, :(;loss_tangent=0.,reference_frequency=0.))
        for name in _CAPACITOR_DIELECTRIC_NAMES)...,
    (:DebyeBranches,:(;time_constants=Float64[],fractions=Float64[])),
    (:JunctionDiode,:(;saturation_current=1e-12,ideality=1.2,series_resistance=0.,
        junction_capacitance=0.,junction_potential=.7,grading_coefficient=.5,transit_time=0.,
        breakdown_voltage=Inf,breakdown_current=1e-3,flicker_coefficient=0.,
        flicker_current_exponent=1.,flicker_frequency_exponent=1.,
        flicker_reference_frequency=1.)),
    (:GummelPoonBJT,:(;saturation_current=1e-14,forward_beta=100.,reverse_beta=1.,
        early_voltage=100.,base_resistance=0.,cbe_zero_bias=0.,cbc_zero_bias=0.,
        transit_time=0.,flicker_coefficient=0.,flicker_current_exponent=1.,
        flicker_frequency_exponent=1.,flicker_reference_frequency=1.)),
    (:Level1MOSFET,:(;threshold_voltage=.7,transconductance=1e-3,
        channel_length_modulation=0.,body_effect=0.,surface_potential=.6,
        gate_source_capacitance=0.,gate_drain_capacitance=0.,gate_bulk_capacitance=0.,
        channel_thermal_coefficient=2/3,flicker_coefficient=0.,
        flicker_current_exponent=2.,flicker_frequency_exponent=1.,
        flicker_reference_frequency=1.,induced_gate_noise_coefficient=0.,
        gate_channel_correlation=0.0+0.0im)),
    (:ChargeBasedMOSFET,:(;threshold_voltage=.7, slope_factor=1.3, channel_length_modulation=0.,
        mobility=.04, oxide_capacitance=5e-3, width=1e-6, length=1e-6,
        multiplicity=1., reference_temperature=300., threshold_temperature_coefficient=-1e-3,
        mobility_temperature_exponent=-1.5, gate_source_overlap=0., gate_drain_overlap=0.,
        gate_bulk_capacitance=0., drain_area=0., source_area=0.,
        drain_perimeter=0., source_perimeter=0., junction_capacitance_density=1e-3,
        junction_sidewall_capacitance=1e-10, junction_saturation_current_density=1e-6,
        junction_potential=.7, junction_grading=.5,
        channel_thermal_coefficient=1., flicker_coefficient=0.,
        flicker_current_exponent=2., flicker_frequency_exponent=1.,
        flicker_reference_frequency=1., induced_gate_noise_coefficient=0.,
        gate_channel_correlation=0.0+0.0im)),
    (:BehavioralOpAmp,:(;dc_gain=1e5,gain_bandwidth=1e6,slew_rate=Inf,
        output_resistance=10.,output_current_limit=Inf,input_offset=0.,
        input_voltage_noise_density=0.,input_voltage_flicker_corner=0.,
        input_voltage_flicker_exponent=1.,positive_input_current_noise_density=0.,
        negative_input_current_noise_density=0.,input_current_flicker_corner=0.,
        input_current_flicker_exponent=1.,voltage_current_noise_correlation=0.0+0.0im,
        saturation_recovery=0.,input_bias_current=0.,input_capacitance=0.)),
    (:VoltageControlledSwitch,:(;threshold=.5,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)),
    (:EventSwitch,:(;threshold=.5,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)),
    (:SmoothSwitch,:(;threshold=.5,transition=.05,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)))
    parent = T in _RESISTOR_MATERIAL_NAMES ? AbstractResistorMaterial :
        T in _PASSIVE_PACKAGE_NAMES ? AbstractPassivePackage :
        T in _CAPACITOR_DIELECTRIC_NAMES ? AbstractCapacitorDielectric : AbstractDeviceModel
    @eval begin
        struct $T{D<:NamedTuple} <: $parent; data::D; end
        function $T(;kw...)
            defaults=(;$defaults...)
            unknown=setdiff(keys(kw),keys(defaults))
            isempty(unknown)||throw(ArgumentError(
                $(String(T))*" received unsupported parameter(s): "*
                    join(string.(unknown),", ")))
            _validate_model_parameters($T((;defaults...,kw...)))
        end
        Base.@constprop :aggressive Base.getproperty(x::$T,s::Symbol)=
            s===:data ? getfield(x,:data) : getproperty(getfield(x,:data),s)
        model_parameters(x::$T)=x.data
        function with_model_parameter(x::$T,name::Symbol,value)
            hasproperty(x.data,name)||throw(ArgumentError("model $(nameof($T)) has no parameter $(name)"))
            _validate_model_parameters($T(merge(x.data,NamedTuple{(name,)}((value,)))))
        end
    end
end

struct IdealResistor; value::Float64; end
struct IdealCapacitor; value::Float64; end

# Keep neutral values readable in existing snapshots, but never accept a
# requested physical effect that the assembly kernels do not implement.
function _unsupported_model_effects(model, neutral)
    for (name,value) in pairs(neutral)
        getproperty(model,name)==value||throw(ArgumentError(
            "$(nameof(typeof(model))).$(name) is not implemented; only $(value) is supported"))
    end
    model
end
function _finite_nonnegative_parameter(name, value)
    value isa Real && isfinite(value) && value >= 0 ||
        throw(ArgumentError("$(name) must be finite and non-negative"))
    value
end
function _validate_model_parameters(model::AbstractResistorMaterial)
    _unsupported_model_effects(model,(;tc1=0.,temperature_coefficient=0.,voltage_coefficient=0.))
    for name in (:excess_noise_coefficient,:excess_current_exponent,:excess_frequency_exponent)
        _finite_nonnegative_parameter(name,getproperty(model,name))
    end
    _finite_nonnegative_parameter(:excess_reference_frequency,model.excess_reference_frequency)>0 ||
        throw(ArgumentError("excess_reference_frequency must be positive"))
    model
end
function _validate_model_parameters(model::AbstractPassivePackage)
    for (name,value) in pairs(model.data)
        _finite_nonnegative_parameter(name,value)
    end
    model
end
function _validate_model_parameters(model::AbstractCapacitorDielectric)
    _finite_nonnegative_parameter(:loss_tangent,model.loss_tangent)
    frequency=get(model.data,:reference_frequency,0.) # Legacy lossless C0G snapshots.
    _finite_nonnegative_parameter(:reference_frequency,frequency)
    model.loss_tangent>0 && frequency==0 && throw(ArgumentError(
        "nonzero loss_tangent requires an explicit positive reference_frequency"))
    model
end
function _validate_model_parameters(model::DebyeBranches)
    length(model.time_constants)==length(model.fractions) ||
        throw(ArgumentError("Debye time constants and fractions must have equal lengths"))
    for tau in model.time_constants
        _finite_nonnegative_parameter(:time_constant,tau)>0 ||
            throw(ArgumentError("Debye time constants must be positive"))
    end
    for fraction in model.fractions
        _finite_nonnegative_parameter(:fraction,fraction)
    end
    model
end
_validate_model_parameters(model::GummelPoonBJT)=_unsupported_model_effects(model,(;transit_time=0.))
_validate_model_parameters(model::BehavioralOpAmp)=_unsupported_model_effects(model,
    (;slew_rate=Inf,output_current_limit=Inf,saturation_recovery=0.))

function _validate_model_parameters(model::ChargeBasedMOSFET)
    for (name,value) in pairs(model.data)
        value isa Number && isfinite(value) || throw(ArgumentError("$(name) must be finite"))
    end
    for name in (:mobility,:oxide_capacitance,:width,:length,:multiplicity,
                 :reference_temperature,:junction_potential,:flicker_reference_frequency)
        getproperty(model,name)>0 || throw(ArgumentError("$(name) must be positive"))
    end
    model.slope_factor>=1 || throw(ArgumentError("slope_factor must be at least one"))
    0<=model.junction_grading<1 || throw(ArgumentError("junction_grading must lie in [0, 1)"))
    for name in (:channel_length_modulation,:gate_source_overlap,:gate_drain_overlap,:gate_bulk_capacitance,
                 :drain_area,:source_area,:drain_perimeter,:source_perimeter,
                 :junction_capacitance_density,:junction_sidewall_capacitance,
                 :junction_saturation_current_density,:channel_thermal_coefficient,
                 :flicker_coefficient,:induced_gate_noise_coefficient)
        getproperty(model,name)>=0 || throw(ArgumentError("$(name) must be non-negative"))
    end
    abs(model.gate_channel_correlation)<=1 || throw(ArgumentError("gate_channel_correlation magnitude must not exceed one"))
    model
end

const _PASSIVE_MODELS = Tuple(getfield(@__MODULE__, name) for name in
    (_RESISTOR_MATERIAL_NAMES..., _PASSIVE_PACKAGE_NAMES..., _CAPACITOR_DIELECTRIC_NAMES...))
