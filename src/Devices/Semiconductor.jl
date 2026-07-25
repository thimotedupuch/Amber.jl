diode(a,b;model=JunctionDiode(),kw...)=_component(:diode,a,b;model,kw...)
npn(c,b,e;model=GummelPoonBJT(),kw...)=_component(:npn,c,b,e;model,kw...)

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
        avalanche,avalanche_slope=_limited_exponential((-voltage-model.breakdown_voltage)/vt)
        current-=model.breakdown_current*avalanche
        conductance+=model.breakdown_current*avalanche_slope/vt
    end
    current,conductance
end
