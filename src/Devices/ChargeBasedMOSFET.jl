# Four-terminal second-order forward differentiation. The Hessian is needed for
# d/dv [dQ/dv * vdot] in Amber's voltage-based DAE, including away from DC.
struct _MOSJet
    value::Float64
    gradient::NTuple{4,Float64}
    hessian::NTuple{16,Float64}
end
_MOSJet(x::Real)=_MOSJet(Float64(x),ntuple(_->0.,4),ntuple(_->0.,16))
_mos_variable(x,i)=_MOSJet(Float64(x),ntuple(j->Float64(i==j),4),ntuple(_->0.,16))
Base.:+(a::_MOSJet,b::_MOSJet)=_MOSJet(a.value+b.value,a.gradient.+b.gradient,a.hessian.+b.hessian)
Base.:-(a::_MOSJet)=_MOSJet(-a.value,.-a.gradient,.-a.hessian)
Base.:-(a::_MOSJet,b::_MOSJet)=a+(-b)
function Base.:*(a::_MOSJet,b::_MOSJet)
    _MOSJet(a.value*b.value,a.gradient.*b.value.+b.gradient.*a.value,
        ntuple(16) do k
            i=(k-1)÷4+1; j=(k-1)%4+1
            a.hessian[k]*b.value+b.hessian[k]*a.value+
                a.gradient[i]*b.gradient[j]+b.gradient[i]*a.gradient[j]
        end)
end
function _mos_lift(x::_MOSJet,value,first,second)
    _MOSJet(value,x.gradient.*first,ntuple(16) do k
        i=(k-1)÷4+1; j=(k-1)%4+1
        first*x.hessian[k]+second*x.gradient[i]*x.gradient[j]
    end)
end
Base.sqrt(x::_MOSJet)=_mos_lift(x,sqrt(x.value),.5/sqrt(x.value),-.25/x.value^1.5)
Base.inv(x::_MOSJet)=_mos_lift(x,inv(x.value),-inv(x.value)^2,2inv(x.value)^3)
Base.:/(a::_MOSJet,b::_MOSJet)=a*inv(b)
for op in (:+,:-,:*,:/)
    @eval Base.$op(a::_MOSJet,b::Real)=Base.$op(a,_MOSJet(b))
    @eval Base.$op(a::Real,b::_MOSJet)=Base.$op(_MOSJet(a),b)
end
Base.:^(a::_MOSJet,n::Integer)=n==0 ? _MOSJet(1.) : n==1 ? a :
    _mos_lift(a,a.value^n,n*a.value^(n-1),n*(n-1)*a.value^(n-2))

# Solve 2q + log(q) = v in log space; no exponential overflow in strong inversion.
function _mos_inversion(v::_MOSJet)
    x=v.value
    if x < -36
        q=exp(x)
    else
        y=x>1 ? log(x/2) : x
        for _ in 1:20
            q=exp(y); step=(2q+y-x)/(2q+1); y-=step
            abs(step)<2e-15 && break
        end
        q=exp(y)
    end
    _mos_lift(v,q,q/(1+2q),q/(1+2q)^3)
end

# Ward-Dutton drain partition after cancelling (qs-qd)^2 analytically.
# This remains regular at Vds=0; swapping endpoints gives the source charge.
function _mos_partition(a,b)
    (16a^3+24b^3+32a^2*b+48a*b^2+25a^2+45b^2+50a*b+10a+20b)/
        (60*(a+b+1)^2)
end

function _mos_junction_charge(v,capacitance,model)
    potential=model.junction_potential; grading=model.junction_grading
    transition=.9potential
    if v.value<=transition
        base=1-v.value/potential
        value=capacitance*potential/(1-grading)*(1-base^(1-grading))
        first=capacitance*base^(-grading)
        second=capacitance*grading/potential*base^(-grading-1)
    else
        base=.1
        at_transition=capacitance*potential/(1-grading)*(1-base^(1-grading))
        first=capacitance*base^(-grading)
        value=at_transition+first*(v.value-transition); second=0.
    end
    _mos_lift(v,value,first,second)
end

function _mos_junction_current(v,saturation,ut)
    x=v.value/ut
    # Smooth exponential continuation above 40 avoids overflow during Newton.
    if x>40
        value=exp(40)*(1+x-40)-1; slope=exp(40)
        curvature=0.
    else
        value=expm1(x); slope=exp(x); curvature=slope
    end
    _mos_lift(v,saturation*value,saturation*slope/ut,saturation*curvature/ut^2)
end

function _charge_mos_evaluate(model::ChargeBasedMOSFET,kind,voltages;temperature=300.)
    kind in (:nmos,:pmos) || throw(ArgumentError("MOS polarity must be :nmos or :pmos"))
    isfinite(temperature)&&temperature>0 || throw(ArgumentError("temperature must be finite and positive"))
    polarity=kind===:nmos ? 1. : -1.
    vd,vg,vs,vb=ntuple(i->polarity*_mos_variable(voltages[i],i),4)
    ut=_thermal_voltage(temperature); n=model.slope_factor
    threshold=model.threshold_voltage+model.threshold_temperature_coefficient*(temperature-model.reference_temperature)
    mobility=model.mobility*(temperature/model.reference_temperature)^model.mobility_temperature_exponent
    beta=mobility*model.oxide_capacitance*model.width/model.length*model.multiplicity
    pinch=(vg-vb-threshold)/n
    qs=_mos_inversion((pinch-(vs-vb))/ut)
    qd=_mos_inversion((pinch-(vd-vb))/ut)
    channel=polarity*(2n*beta*ut^2)*(qs-qd)*(qs+qd+1)*
        (1+model.channel_length_modulation*(sqrt((vd-vs)^2+ut^2)-ut))
    scale=-polarity*2n*model.oxide_capacitance*model.width*model.length*model.multiplicity*ut
    drain_charge=scale*_mos_partition(qs,qd)
    source_charge=scale*_mos_partition(qd,qs)
    gate_charge=-drain_charge-source_charge
    bulk_charge=_MOSJet(0.)
    charges=[drain_charge,gate_charge,source_charge,bulk_charge]
    currents=[channel,_MOSJet(0.),-channel,_MOSJet(0.)]
    for (other,capacitance) in ((1,model.gate_drain_overlap*model.width),
            (3,model.gate_source_overlap*model.width),(4,model.gate_bulk_capacitance))
        overlap=polarity*capacitance*model.multiplicity*(vg-(vd,vg,vs,vb)[other])
        charges[2]+=overlap; charges[other]-=overlap
    end
    for (terminal,area,perimeter) in ((1,model.drain_area,model.drain_perimeter),
            (3,model.source_area,model.source_perimeter))
        junction_voltage=vb-(vd,vg,vs,vb)[terminal]
        capacitance=model.multiplicity*(model.junction_capacitance_density*area+
            model.junction_sidewall_capacitance*perimeter)
        charge=polarity*_mos_junction_charge(junction_voltage,capacitance,model)
        # Junction current density is specified at the analysis temperature;
        # no undocumented bandgap/temperature law is assumed for this parameter.
        saturation=model.multiplicity*model.junction_saturation_current_density*area
        current=polarity*_mos_junction_current(junction_voltage,saturation,ut)
        charges[4]+=charge; charges[terminal]-=charge
        currents[4]+=current; currents[terminal]-=current
    end
    (;currents=Tuple(currents),charges=Tuple(charges),channel,
      source_inversion=qs.value,drain_inversion=qd.value,
      thermal_conductance=mobility*abs(drain_charge.value+source_charge.value)/model.length^2)
end

function _mosfet_channel(model::ChargeBasedMOSFET,kind::Symbol,vd,vg,vs,vb;temperature=300.)
    channel=_charge_mos_evaluate(model,kind,(vd,vg,vs,vb);temperature).channel
    channel.value,channel.gradient
end

"""
    terminal_charges(model::ChargeBasedMOSFET, kind, vd, vg, vs, vb; temperature=300)

Quasi-static charges in coulombs, ordered/named `(drain, gate, source, bulk)`.
`kind` is `:nmos` or `:pmos`; voltages use physical terminal polarities.
The four charges sum to zero. See the charge-based MOS model manual for scope.
"""
function terminal_charges(model::ChargeBasedMOSFET,kind,vd,vg,vs,vb;temperature=300.)
    evaluated=_charge_mos_evaluate(model,kind,(vd,vg,vs,vb);temperature)
    NamedTuple{(:drain,:gate,:source,:bulk)}(map(q->q.value,evaluated.charges))
end

"""
    mosfet_operating_point(model::ChargeBasedMOSFET, kind, vd, vg, vs, vb; temperature=300)

Characterize one transistor without building a circuit. Returns channel `id`,
`gm`, `gds`, `gmb`, `gm_over_id`, `intrinsic_gain`, terminal currents/charges,
`capacitance_matrix` (dQᵢ/dVⱼ in drain/gate/source/bulk order), and normalized
source/drain inversion charges. Ratios are `NaN` when their denominator is zero.
`gm`, `gds`, and `gmb` are signed derivatives at the physical drain terminal.
"""
function mosfet_operating_point(model::ChargeBasedMOSFET,kind,vd,vg,vs,vb;temperature=300.)
    e=_charge_mos_evaluate(model,kind,(vd,vg,vs,vb);temperature)
    id=e.channel.value; gds,gm,_,gmb=e.channel.gradient
    names=(:drain,:gate,:source,:bulk)
    (;id,gm,gds,gmb,gm_over_id=iszero(id) ? NaN : abs(gm/id),
      intrinsic_gain=iszero(gds) ? NaN : abs(gm/gds),
      currents=NamedTuple{names}(map(x->x.value,e.currents)),
      charges=NamedTuple{names}(map(x->x.value,e.charges)),
      capacitance_matrix=[e.charges[i].gradient[j] for i in 1:4,j in 1:4],
      source_inversion=e.source_inversion,drain_inversion=e.drain_inversion,
      temperature=Float64(temperature))
end
