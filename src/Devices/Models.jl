abstract type AbstractWaveform end

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

for (T,defaults) in ((:ThinFilm,:(;tc1=0.,temperature_coefficient=0.,voltage_coefficient=0.,excess_noise=false)),
    (:SMD0603,:(;series_inductance=0.,parallel_capacitance=0.,esr=0.,esl=0.)),
    (:C0G,:(;loss_tangent=0.)),
    (:DebyeBranches,:(;time_constants=Float64[],fractions=Float64[])),
    (:JunctionDiode,:(;saturation_current=1e-12,ideality=1.2,series_resistance=0.,junction_capacitance=0.,junction_potential=.7,grading_coefficient=.5,transit_time=0.,breakdown_voltage=Inf,breakdown_current=1e-3)),
    (:GummelPoonBJT,:(;saturation_current=1e-14,forward_beta=100.,reverse_beta=1.,early_voltage=100.,base_resistance=0.,cbe_zero_bias=0.,cbc_zero_bias=0.,transit_time=0.,flicker_noise=false)),
    (:BehavioralOpAmp,:(;dc_gain=1e5,gain_bandwidth=1e6,slew_rate=1e6,output_resistance=10.,output_current_limit=Inf,input_offset=0.,input_voltage_noise=0.,saturation_recovery=0.,input_bias_current=0.,input_capacitance=0.)),
    (:VoltageControlledSwitch,:(;threshold=.5,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)),
    (:EventSwitch,:(;threshold=.5,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)),
    (:SmoothSwitch,:(;threshold=.5,transition=.05,ron=1.,roff=1e12,charge_injection=0.,clock_feedthrough=0.)))
    @eval begin
        struct $T; data::NamedTuple; end
        $T(;kw...)=$T((;$defaults...,kw...))
        Base.getproperty(x::$T,s::Symbol)=s===:data ? getfield(x,:data) : getproperty(getfield(x,:data),s)
    end
end

struct IdealResistor; value::Float64; end
struct IdealCapacitor; value::Float64; end
