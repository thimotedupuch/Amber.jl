diode(a,b;model=JunctionDiode(),kw...)=_component(:diode,a,b;model,kw...)
npn(c,b,e;model=GummelPoonBJT(),kw...)=_component(:npn,c,b,e;model,kw...)
nmos(d,g,s,b;model=Level1MOSFET(),kw...)=_component(:nmos,d,g,s,b;model,kw...)
pmos(d,g,s,b;model=Level1MOSFET(),kw...)=_component(:pmos,d,g,s,b;model,kw...)

"""Channel current leaving the drain and its derivatives with respect to d, g, s, b."""
function _mosfet_channel(model::Level1MOSFET,kind::Symbol,vd,vg,vs,vb)
    polarity=kind===:nmos ? 1. : -1.
    ud,ug,us,ub=polarity.*(vd,vg,vs,vb)
    reverse=ud<us
    high,low=reverse ? (us,ud) : (ud,us)
    twice_phi=2*model.surface_potential
    root_argument=max(twice_phi+low-ub,eps(Float64))
    root=sqrt(root_argument)
    body_slope=root_argument>eps(Float64) ? model.body_effect/(2root) : 0.
    threshold=model.threshold_voltage+model.body_effect*(root-sqrt(twice_phi))
    overdrive=ug-low-threshold
    overdrive<=0&&return (zero(promote_type(typeof(vd),Float64)),(0.,0.,0.,0.))
    vds=high-low; β=model.transconductance; λ=model.channel_length_modulation
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
    capacitance=model.junction_capacitance; potential=model.junction_potential; grading=model.grading_coefficient
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
    vt=_thermal_voltage(temperature)*model.ideality
    _junction_depletion(model,voltage)+model.transit_time*model.saturation_current*expm1(clamp(voltage/vt,-80,40))
end

function differential_capacitance(model::JunctionDiode,voltage::Real;temperature=300.)
    potential=model.junction_potential; transition=.9*potential
    depletion=model.junction_capacitance==0 ? 0. : model.junction_capacitance*(1-min(voltage,transition)/potential)^(-model.grading_coefficient)
    vt=_thermal_voltage(temperature)*model.ideality; _,slope=_limited_exponential(voltage/vt)
    depletion+model.transit_time*model.saturation_current*slope/vt
end

function _diode_conduction(model,voltage,temperature)
    vt=_thermal_voltage(temperature)*model.ideality
    forward,forward_slope=_limited_exponential(voltage/vt)
    current=model.saturation_current*forward; conductance=model.saturation_current*forward_slope/vt
    if isfinite(model.breakdown_voltage)
        avalanche_argument=(-voltage-model.breakdown_voltage)/vt
        if avalanche_argument>0
            avalanche,avalanche_slope=_limited_exponential(avalanche_argument)
            current-=model.breakdown_current*avalanche
            conductance+=model.breakdown_current*avalanche_slope/vt
        end
    end
    current,conductance
end
