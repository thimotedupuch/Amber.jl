# Only accept keywords consumed by elaboration or a simulation kernel.
const _COMPONENT_KEYWORDS = Dict(
    :resistor => (:value, :material, :package, :tolerance),
    :capacitor => (:value, :package, :dielectric, :esr, :esl, :leakage_resistance,
        :dielectric_absorption, :initial_voltage, :tolerance),
    :inductor => (:value, :winding_resistance, :series_resistance, :parallel_capacitance, :tolerance),
    :conductance => (:value, :tolerance),
    :voltage_source => (:dc, :ac, :waveform, :series_resistance),
    :current_source => (:dc, :ac, :waveform),
    :vccs => (:gm,), :vcvs => (:gain,), :cccs => (:control, :gain),
    :ccvs => (:control, :transresistance),
    :diode => (:model,), :npn => (:model, :match), :nmos => (:model,), :pmos => (:model,),
    :opamp => (:model,), :switch => (:model,),
    :behavioral_current_source => (:current, :gradient, :control_count),
    :behavioral_voltage_source => (:voltage, :gradient, :control_count),
    :photodiode => (:photocurrent, :model),
    :solar_cell => (:photocurrent, :shunt_resistance, :model),
    :potentiometer => (:resistance, :position), :ideal_transformer => (:ratio,),
    :bridge_rectifier => (:model,),
    :crystal => (:motional_resistance, :motional_inductance, :motional_capacitance, :shunt_capacitance),
    :transmission_line => (:resistance, :inductance, :conductance, :capacitance, :sections),
)
function _component(k,ns...;kw...)
    unknown=setdiff(keys(kw),get(_COMPONENT_KEYWORDS,k,()))
    isempty(unknown)||throw(ArgumentError(
        "$(k) received unsupported keyword(s): "*join(string.(unknown),", ")))
    PrimitiveDraft{k,typeof(ns),typeof((;kw...))}(ns,(;kw...))
end

voltage_source(a,b;dc=0.,ac=0.,waveform=nothing,kw...)=_component(:voltage_source,a,b;dc,ac,waveform,kw...)
current_source(a,b;dc=0.,ac=0.,waveform=nothing,kw...)=_component(:current_source,a,b;dc,ac,waveform,kw...)

transconductance(control_p,control_n,output_p,output_n;gm=1.,kw...)=_component(:vccs,control_p,control_n,output_p,output_n;gm,kw...)
voltage_controlled_voltage_source(control_p,control_n,output_p,output_n;gain=1.,kw...)=_component(:vcvs,control_p,control_n,output_p,output_n;gain,kw...)

_control_name(control::BuilderPrimitive)=LocalPrimitiveReference(control.id)
_control_name(control::Symbol)=control
_control_name(control::String)=control
current_controlled_current_source(control,output_p,output_n;gain=1.,kw...)=_component(:cccs,output_p,output_n;control=_control_name(control),gain,kw...)
current_controlled_voltage_source(control,output_p,output_n;transresistance=1.,kw...)=_component(:ccvs,output_p,output_n;control=_control_name(control),transresistance,kw...)
