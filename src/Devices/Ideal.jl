_params(kw)=Dict{Symbol,Any}(kw)
_component(k,ns...;kw...)=Component(k,AbstractNode[ns...],_params(kw),:unnamed)

voltage_source(a,b;dc=0.,ac=0.,waveform=nothing,kw...)=_component(:voltage_source,a,b;dc,ac,waveform,kw...)
current_source(a,b;dc=0.,ac=0.,waveform=nothing,kw...)=_component(:current_source,a,b;dc,ac,waveform,kw...)

transconductance(control_p,control_n,output_p,output_n;gm=1.,kw...)=_component(:vccs,control_p,control_n,output_p,output_n;gm,kw...)
voltage_controlled_voltage_source(control_p,control_n,output_p,output_n;gain=1.,kw...)=_component(:vcvs,control_p,control_n,output_p,output_n;gain,kw...)

_control_name(control::Component)=control.name
_control_name(control::Symbol)=control
_control_name(control::String)=Symbol(control)
current_controlled_current_source(control,output_p,output_n;gain=1.,kw...)=_component(:cccs,output_p,output_n;control=_control_name(control),gain,kw...)
current_controlled_voltage_source(control,output_p,output_n;transresistance=1.,kw...)=_component(:ccvs,output_p,output_n;control=_control_name(control),transresistance,kw...)
