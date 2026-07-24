struct CompiledCircuit
    circuit::Circuit
    node_index::Dict{Int,Int}
    branches::Dict{Int,Int}
    states::Dict{Tuple{Int,Symbol},Int}
    n::Int
    fingerprint::String
end

function compile(c::Circuit)
    errors=filter(d->d.severity===:error,check(c))
    isempty(errors)||throw(ArgumentError(join(getfield.(errors,:message),'\n')))
    graph=equation_graph(c)
    signature=string(c.name,[(x.kind,map(n->n.id,x.terminals),get(x.parameters,:control,nothing)) for x in c.components])
    compiled=CompiledCircuit(c,graph.node_index,graph.branches,graph.states,graph.unknown_count,bytes2hex(sha1(signature)))
    for component in c.components
        component.kind in (:cccs,:ccvs)&&_control_branch(compiled,component)
    end
    compiled
end
compile(c::CompiledCircuit)=c

_idx(cc,n)=n.id==0 ? 0 : cc.node_index[n.id]
_v(z,i)=i==0 ? zero(eltype(z)) : z[i]
function _source_value(p,t,mode)
    mode===:dc&&return get(p,:dc,0.)
    waveform=get(p,:waveform,nothing)
    waveform===nothing ? get(p,:dc,0.) : waveform(t)
end
function _stampg!(r,z,a,b,g)
    v=_v(z,a)-_v(z,b); a>0&&(r[a]+=g*v); b>0&&(r[b]-=g*v)
end

function _known_node_voltage(cc,node,t,mode)
    node.id==0&&return 0.
    for component in cc.circuit.components
        component.kind===:voltage_source||continue; p,n=component.terminals
        if p.id==node.id&&n.id==0; return _source_value(component.parameters,t,mode)
        elseif p.id==0&&n.id==node.id; return -_source_value(component.parameters,t,mode)
        end
    end
    nothing
end

function _switch_control(cc,component,z,q,t,mode)
    _v(z,q[3])-_v(z,q[4])
end

function _switch_conductance(model,control)
    if model isa SmoothSwitch
        transition=max(abs(model.transition),eps(Float64)); fraction=(1+tanh((control-model.threshold)/transition))/2
        fraction/model.ron+(1-fraction)/model.roff
    else
        inv(control>=model.threshold ? model.ron : model.roff)
    end
end

function _switch_conductance_derivative(model,control)
    model isa SmoothSwitch||return 0.
    transition=max(abs(model.transition),eps(Float64)); argument=(control-model.threshold)/transition
    .5*(1-tanh(argument)^2)/transition*(inv(model.ron)-inv(model.roff))
end

function _control_branch(cc,component)
    control_name=component.parameters[:control]
    control_index=findfirst(candidate->candidate.name===control_name,cc.circuit.components)
    control_index===nothing&&throw(ArgumentError("$(component.name) refers to unknown controlling component $(control_name)"))
    branch=get(cc.branches,control_index,nothing)
    branch===nothing&&throw(ArgumentError("$(component.name) requires branch current from $(control_name), but that component has no MNA branch current"))
    branch
end

function residual(cc::CompiledCircuit,z,zd,t;mode=:time,source_scale=1.,gmin=0.)
    r=zeros(eltype(z),cc.n)
    if gmin!=0
        for index in values(cc.node_index); r[index]+=gmin*z[index] end
    end
    for (ci,x) in enumerate(cc.circuit.components)
        p=x.parameters; q=map(n->_idx(cc,n),x.terminals); k=x.kind
        if k===:resistor
            _stampg!(r,z,q[1],q[2],inv(Float64(p[:value])))
        elseif k===:conductance
            _stampg!(r,z,q[1],q[2],Float64(p[:value]))
        elseif k===:capacitor
            C=Float64(p[:value]); i=C*(_v(zd,q[1])-_v(zd,q[2])); q[1]>0&&(r[q[1]]+=i); q[2]>0&&(r[q[2]]-=i)
            haskey(p,:leakage_resistance)&&_stampg!(r,z,q[1],q[2],inv(Float64(p[:leakage_resistance])))
        elseif k===:current_source
            i=source_scale*_source_value(p,t,mode); q[1]>0&&(r[q[1]]+=i); q[2]>0&&(r[q[2]]-=i)
        elseif k===:vccs
            i=Float64(p[:gm])*(_v(z,q[1])-_v(z,q[2])); q[3]>0&&(r[q[3]]+=i); q[4]>0&&(r[q[4]]-=i)
        elseif k===:vcvs
            bi=cc.branches[ci]; i=z[bi]; q[3]>0&&(r[q[3]]+=i); q[4]>0&&(r[q[4]]-=i)
            r[bi]+=_v(z,q[3])-_v(z,q[4])-Float64(p[:gain])*(_v(z,q[1])-_v(z,q[2]))
        elseif k===:cccs
            control=_control_branch(cc,x); i=Float64(p[:gain])*z[control]
            q[1]>0&&(r[q[1]]+=i); q[2]>0&&(r[q[2]]-=i)
        elseif k===:ccvs
            control=_control_branch(cc,x); branch=cc.branches[ci]; i=z[branch]
            q[1]>0&&(r[q[1]]+=i); q[2]>0&&(r[q[2]]-=i)
            r[branch]+=_v(z,q[1])-_v(z,q[2])-Float64(p[:transresistance])*z[control]
        elseif k===:voltage_source
            bi=cc.branches[ci]; i=z[bi]; q[1]>0&&(r[q[1]]+=i); q[2]>0&&(r[q[2]]-=i)
            val=source_scale*_source_value(p,t,mode); r[bi]+=_v(z,q[1])-_v(z,q[2])-val
            rs=get(p,:series_resistance,0.); rs!=0&&(r[bi]-=rs*i)
        elseif k===:inductor
            bi=cc.branches[ci]; i=z[bi]; q[1]>0&&(r[q[1]]+=i); q[2]>0&&(r[q[2]]-=i)
            r[bi]+=_v(z,q[1])-_v(z,q[2])-Float64(p[:value])*zd[bi]
        elseif k===:diode
            md=p[:model]; vd=_v(z,q[1])-_v(z,q[2]); vt=.025852*md.ideality
            id=md.saturation_current*expm1(clamp(vd/vt,-80,40)); q[1]>0&&(r[q[1]]+=id); q[2]>0&&(r[q[2]]-=id)
            capacitance=differential_capacitance(md,vd)
            capacitance!=0&&_stampg!(r,zd,q[1],q[2],capacitance)
        elseif k===:npn
            md=p[:model]; vc,vb,ve=_v(z,q[1]),_v(z,q[2]),_v(z,q[3])
            ic=md.saturation_current*expm1(clamp((vb-ve)/.025852,-80,40))*(1+(vc-ve)/max(md.early_voltage,1e-9)); ib=ic/md.forward_beta
            q[1]>0&&(r[q[1]]+=ic); q[2]>0&&(r[q[2]]+=ib); q[3]>0&&(r[q[3]]-=ic+ib)
            md.cbe_zero_bias!=0&&_stampg!(r,zd,q[2],q[3],md.cbe_zero_bias)
            md.cbc_zero_bias!=0&&_stampg!(r,zd,q[2],q[1],md.cbc_zero_bias)
        elseif k===:switch
            md=p[:model]; ctrl=_switch_control(cc,x,z,q,t,mode); _stampg!(r,z,q[1],q[2],_switch_conductance(md,ctrl))
        elseif k===:opamp
            md=p[:model]; bi=cc.branches[ci]; si=cc.states[(ci,:dominant_pole)]; io=z[bi]; q[3]>0&&(r[q[3]]+=io)
            target=md.dc_gain*(_v(z,q[1])-_v(z,q[2])+md.input_offset)
            limited=clamp(z[si],_v(z,q[5]),_v(z,q[4]))
            pole=2π*md.gain_bandwidth/max(md.dc_gain,1.)
            r[bi]+=_v(z,q[3])-limited-md.output_resistance*io
            r[si]+=zd[si]-pole*(target-z[si])
        end
    end
    r
end

"""Right-hand side for independent small-signal source phasors."""
function ac_excitation(cc::CompiledCircuit;source=nothing)
    b=zeros(ComplexF64,cc.n)
    for (ci,x) in enumerate(cc.circuit.components)
        source!==nothing&&x.name!==source&&continue
        amplitude=ComplexF64(get(x.parameters,:ac,0.))
        if x.kind===:voltage_source
            b[cc.branches[ci]]+=amplitude
        elseif x.kind===:current_source
            a,n=map(node->_idx(cc,node),x.terminals)
            a>0&&(b[a]-=amplitude); n>0&&(b[n]+=amplitude)
        end
    end
    b
end

_add!(J,i,j,value)=(i>0&&j>0&&(J[i,j]+=value);nothing)
function _stamp_conductance!(J,a,b,g)
    _add!(J,a,a,g); _add!(J,a,b,-g); _add!(J,b,a,-g); _add!(J,b,b,g)
end

"""Assemble the residual and sparse Newton matrix for `zd = α*(z-previous)`."""
function residual_jacobian(cc::CompiledCircuit,z,previous,t,α;mode=:time,source_scale=1.,gmin=0.)
    zd=α==0 ? zero(z) : α.*(z.-previous)
    r=residual(cc,z,zd,t;mode,source_scale,gmin)
    J=spzeros(eltype(z),cc.n,cc.n)
    if gmin!=0
        for index in values(cc.node_index); J[index,index]+=gmin end
    end
    for (ci,x) in enumerate(cc.circuit.components)
        p=x.parameters; q=map(n->_idx(cc,n),x.terminals); k=x.kind
        if k===:resistor
            _stamp_conductance!(J,q[1],q[2],inv(Float64(p[:value])))
        elseif k===:conductance
            _stamp_conductance!(J,q[1],q[2],Float64(p[:value]))
        elseif k===:capacitor
            g=α*Float64(p[:value])+inv(Float64(get(p,:leakage_resistance,Inf)))
            _stamp_conductance!(J,q[1],q[2],g)
        elseif k===:voltage_source
            branch=cc.branches[ci]
            _add!(J,q[1],branch,1); _add!(J,q[2],branch,-1)
            _add!(J,branch,q[1],1); _add!(J,branch,q[2],-1)
            _add!(J,branch,branch,-Float64(get(p,:series_resistance,0.)))
        elseif k===:vccs
            gm=Float64(p[:gm]); _add!(J,q[3],q[1],gm); _add!(J,q[3],q[2],-gm); _add!(J,q[4],q[1],-gm); _add!(J,q[4],q[2],gm)
        elseif k===:vcvs
            branch=cc.branches[ci]; gain=Float64(p[:gain]); _add!(J,q[3],branch,1); _add!(J,q[4],branch,-1)
            _add!(J,branch,q[3],1); _add!(J,branch,q[4],-1); _add!(J,branch,q[1],-gain); _add!(J,branch,q[2],gain)
        elseif k===:cccs
            control=_control_branch(cc,x); gain=Float64(p[:gain]); _add!(J,q[1],control,gain); _add!(J,q[2],control,-gain)
        elseif k===:ccvs
            control=_control_branch(cc,x); branch=cc.branches[ci]; resistance=Float64(p[:transresistance])
            _add!(J,q[1],branch,1); _add!(J,q[2],branch,-1); _add!(J,branch,q[1],1); _add!(J,branch,q[2],-1); _add!(J,branch,control,-resistance)
        elseif k===:inductor
            branch=cc.branches[ci]
            _add!(J,q[1],branch,1); _add!(J,q[2],branch,-1)
            _add!(J,branch,q[1],1); _add!(J,branch,q[2],-1)
            _add!(J,branch,branch,-α*Float64(p[:value]))
        elseif k===:diode
            md=p[:model]; vd=_v(z,q[1])-_v(z,q[2]); vt=.025852*md.ideality
            gd=md.saturation_current*exp(clamp(vd/vt,-80,40))/vt+α*differential_capacitance(md,vd)
            _stamp_conductance!(J,q[1],q[2],gd)
        elseif k===:npn
            md=p[:model]; vc,vb,ve=_v(z,q[1]),_v(z,q[2]),_v(z,q[3]); vt=.025852
            ev=exp(clamp((vb-ve)/vt,-80,40)); transport=md.saturation_current*(ev-1)
            early=1+(vc-ve)/max(md.early_voltage,1e-9)
            dvc=transport/max(md.early_voltage,1e-9)
            dvb=md.saturation_current*ev/vt*early
            dve=-dvb-dvc
            β=md.forward_beta
            for (column,derivative) in zip(q,(dvc,dvb,dve))
                _add!(J,q[1],column,derivative)
                _add!(J,q[2],column,derivative/β)
                _add!(J,q[3],column,-derivative*(1+inv(β)))
            end
            md.cbe_zero_bias!=0&&_stamp_conductance!(J,q[2],q[3],α*md.cbe_zero_bias)
            md.cbc_zero_bias!=0&&_stamp_conductance!(J,q[2],q[1],α*md.cbc_zero_bias)
        elseif k===:switch
            md=p[:model]; control=_switch_control(cc,x,z,q,t,mode)
            conductance=_switch_conductance(md,control); _stamp_conductance!(J,q[1],q[2],conductance)
            derivative=_switch_conductance_derivative(md,control)*(_v(z,q[1])-_v(z,q[2]))
            _add!(J,q[1],q[3],derivative); _add!(J,q[1],q[4],-derivative)
            _add!(J,q[2],q[3],-derivative); _add!(J,q[2],q[4],derivative)
        elseif k===:opamp
            md=p[:model]; branch=cc.branches[ci]; state=cc.states[(ci,:dominant_pole)]; _add!(J,q[3],branch,1)
            low,high=_v(z,q[5]),_v(z,q[4]); pole=2π*md.gain_bandwidth/max(md.dc_gain,1.); internal=z[state]
            _add!(J,branch,q[3],1); _add!(J,branch,branch,-md.output_resistance)
            _add!(J,state,state,α+pole)
            _add!(J,state,q[1],-pole*md.dc_gain); _add!(J,state,q[2],pole*md.dc_gain)
            if internal<low
                _add!(J,branch,q[5],-1)
            elseif internal>high
                _add!(J,branch,q[4],-1)
            else
                _add!(J,branch,state,-1)
            end
        end
    end
    r,J
end
