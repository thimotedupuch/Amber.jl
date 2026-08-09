abstract type AbstractWaveform end

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

for (T,defaults) in ((:ThinFilm,:(;tc1=0.,temperature_coefficient=0.,voltage_coefficient=0.,
        excess_noise_coefficient=0.,excess_current_exponent=2.,
        excess_frequency_exponent=1.,excess_reference_frequency=1.)),
    (:SMD0603,:(;series_inductance=0.,parallel_capacitance=0.,esr=0.,esl=0.)),
    (:C0G,:(;loss_tangent=0.)),
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
    (:BehavioralOpAmp,:(;dc_gain=1e5,gain_bandwidth=1e6,slew_rate=1e6,
        output_resistance=10.,output_current_limit=Inf,input_offset=0.,
        input_voltage_noise_density=0.,input_voltage_flicker_corner=0.,
        input_voltage_flicker_exponent=1.,positive_input_current_noise_density=0.,
        negative_input_current_noise_density=0.,input_current_flicker_corner=0.,
        input_current_flicker_exponent=1.,voltage_current_noise_correlation=0.0+0.0im,
        saturation_recovery=0.,input_bias_current=0.,input_capacitance=0.)),
    (:VoltageControlledSwitch,:(;threshold=.5,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)),
    (:EventSwitch,:(;threshold=.5,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)),
    (:SmoothSwitch,:(;threshold=.5,transition=.05,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)))
    @eval begin
        struct $T{D<:NamedTuple}; data::D; end
        function $T(;kw...)
            defaults=(;$defaults...)
            unknown=setdiff(keys(kw),keys(defaults))
            isempty(unknown)||throw(ArgumentError(
                $(String(T))*" received unsupported parameter(s): "*
                    join(string.(unknown),", ")))
            $T((;defaults...,kw...))
        end
        Base.@constprop :aggressive Base.getproperty(x::$T,s::Symbol)=
            s===:data ? getfield(x,:data) : getproperty(getfield(x,:data),s)
        model_parameters(x::$T)=x.data
        function with_model_parameter(x::$T,name::Symbol,value)
            hasproperty(x.data,name)||throw(ArgumentError("model $(nameof($T)) has no parameter $(name)"))
            $T(merge(x.data,NamedTuple{(name,)}((value,))))
        end
    end
end

struct IdealResistor; value::Float64; end
struct IdealCapacitor; value::Float64; end
