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

function charge(model::JunctionDiode,voltage::Real)
    vt=.025852*model.ideality
    _junction_depletion(model,voltage)+model.transit_time*model.saturation_current*expm1(clamp(voltage/vt,-80,40))
end

function differential_capacitance(model::JunctionDiode,voltage::Real)
    potential=model.junction_potential; transition=.9*potential
    depletion=model.junction_capacitance==0 ? 0. : model.junction_capacitance*(1-min(voltage,transition)/potential)^(-model.grading_coefficient)
    vt=.025852*model.ideality
    depletion+model.transit_time*model.saturation_current*exp(clamp(voltage/vt,-80,40))/vt
end
