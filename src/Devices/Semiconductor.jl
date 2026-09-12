diode(a,b;model=JunctionDiode(),kw...)=_component(:diode,a,b;model,kw...)
npn(c,b,e;model=GummelPoonBJT(),kw...)=_component(:npn,c,b,e;model,kw...)
function _mosfet_component(kind,d,g,s,b;model=Level1MOSFET(),width=nothing,length=nothing,
        multiplicity=nothing,drain_area=nothing,source_area=nothing,
        drain_perimeter=nothing,source_perimeter=nothing,kw...)
    for (name,value) in pairs((;width,length,multiplicity,drain_area,source_area,drain_perimeter,source_perimeter))
        value===nothing && continue
        model isa ChargeBasedMOSFET || throw(ArgumentError("explicit MOS geometry requires ChargeBasedMOSFET"))
        model=with_model_parameter(model,name,Float64(value))
    end
    _component(kind,d,g,s,b;model,kw...)
end
nmos(d,g,s,b;kw...)=_mosfet_component(:nmos,d,g,s,b;kw...)
pmos(d,g,s,b;kw...)=_mosfet_component(:pmos,d,g,s,b;kw...)

"""Channel current leaving the drain and its derivatives with respect to d, g, s, b."""
function _mosfet_channel(model::Level1MOSFET,kind::Symbol,vd,vg,vs,vb;temperature=300.)
    data=getfield(model,:data)
    polarity=kind===:nmos ? 1. : -1.
    ud,ug,us,ub=polarity.*(vd,vg,vs,vb)
    reverse=ud<us
    high,low=reverse ? (us,ud) : (ud,us)
    twice_phi=2*data.surface_potential
    root_argument=max(twice_phi+low-ub,eps(Float64))
    root=sqrt(root_argument)
    body_slope=root_argument>eps(Float64) ? data.body_effect/(2root) : 0.
    threshold=data.threshold_voltage+data.body_effect*(root-sqrt(twice_phi))
    overdrive=ug-low-threshold
    overdrive<=0&&return (zero(promote_type(typeof(vd),Float64)),(0.,0.,0.,0.))
    vds=high-low; β=data.transconductance; λ=data.channel_length_modulation
    if vds<overdrive
        base=β*(overdrive*vds-vds^2/2)
        current=base*(1+λ*vds)
        d_overdrive=β*vds*(1+λ*vds)
        d_vds=β*((overdrive-vds)*(1+λ*vds)+λ*(overdrive*vds-vds^2/2))
    else
        current=β*overdrive^2/2*(1+λ*vds)
        d_overdrive=β*overdrive*(1+λ*vds)
        d_vds=β*overdrive^2*λ/2
    end
    d_high=d_vds
    d_gate=d_overdrive
    d_low=-d_vds-d_overdrive*(1+body_slope)
    d_bulk=d_overdrive*body_slope
    if reverse
        normalized=-current
        derivatives=(-d_low,-d_gate,-d_high,-d_bulk)
    else
        normalized=current
        derivatives=(d_high,d_gate,d_low,d_bulk)
    end
    polarity*normalized,derivatives
end

function _junction_depletion(model::JunctionDiode,voltage)
    data=getfield(model,:data)
    capacitance=data.junction_capacitance; potential=data.junction_potential; grading=data.grading_coefficient
    capacitance==0&&return zero(voltage)
    transition=.9*potential
    base(v)=abs(1-grading)<1e-12 ? -capacitance*potential*log1p(-v/potential) : capacitance*potential/(1-grading)*(1-(1-v/potential)^(1-grading))
    if voltage<=transition
        base(voltage)
    else
        qtransition=base(transition); ctransition=capacitance*(1-transition/potential)^(-grading)
        qtransition+ctransition*(voltage-transition)
    end
end

function charge(model::JunctionDiode,voltage::Real;temperature=300.)
    data=getfield(model,:data); vt=_thermal_voltage(temperature)*data.ideality
    _junction_depletion(model,voltage)+data.transit_time*data.saturation_current*expm1(clamp(voltage/vt,-80,40))
end

function differential_capacitance(model::JunctionDiode,voltage::Real;temperature=300.)
    data=getfield(model,:data); potential=data.junction_potential; transition=.9*potential
    depletion=data.junction_capacitance==0 ? 0. : data.junction_capacitance*(1-min(voltage,transition)/potential)^(-data.grading_coefficient)
    vt=_thermal_voltage(temperature)*data.ideality; _,slope=_limited_exponential(voltage/vt)
    depletion+data.transit_time*data.saturation_current*slope/vt
end

function _diode_conduction(model::JunctionDiode,voltage,temperature)
    data=getfield(model,:data); vt=_thermal_voltage(temperature)*data.ideality
    forward,forward_slope=_limited_exponential(voltage/vt)
    current=data.saturation_current*forward; conductance=data.saturation_current*forward_slope/vt
    if isfinite(data.breakdown_voltage)
        avalanche_argument=(-voltage-data.breakdown_voltage)/vt
        if avalanche_argument>0
            avalanche,avalanche_slope=_limited_exponential(avalanche_argument)
            current-=data.breakdown_current*avalanche
            conductance+=data.breakdown_current*avalanche_slope/vt
        end
    end
    current,conductance
end
