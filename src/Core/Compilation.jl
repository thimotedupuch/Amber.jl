struct CompiledTopology
    node_index::Dict{Int,Int}
    branches::Dict{Int,Int}
    states::Dict{Tuple{Int,Symbol},Int}
    n::Int
    fingerprint::String
    jacobian_pattern::SparseMatrixCSC{Float64,Int}
end

struct CompiledCircuit
    circuit::Circuit
    topology::CompiledTopology
    fingerprint::String
end

function Base.getproperty(compiled::CompiledCircuit,name::Symbol)
    name in (:circuit,:topology,:fingerprint)&&return getfield(compiled,name)
    name in (:node_index,:branches,:states,:n,:jacobian_pattern)&&return getproperty(getfield(compiled,:topology),name)
    getfield(compiled,name)
end
Base.propertynames(::CompiledCircuit,private=false)=(:circuit,:topology,:fingerprint,:node_index,:branches,:states,:n,:jacobian_pattern)

function _jacobian_pattern(circuit,node_index,branches,states,n)
    entries=Set{Tuple{Int,Int}}()
    add(i,j)=(i>0&&j>0&&push!(entries,(i,j));nothing)
    idx(node)=node.id==0 ? 0 : node_index[node.id]
    for (ci,component) in enumerate(circuit.components)
        q=idx.(component.terminals); kind=component.kind
        if kind in (:resistor,:conductance,:capacitor,:diode)
            for i in q[1:2],j in q[1:2]; add(i,j) end
        elseif kind in (:voltage_source,:inductor)
            branch=branches[ci]; for i in q[1:2]; add(i,branch); add(branch,i) end; add(branch,branch)
        elseif kind===:vccs
            for i in q[3:4],j in q[1:2]; add(i,j) end
        elseif kind===:vcvs
            branch=branches[ci]; for i in q[3:4]; add(i,branch); add(branch,i) end; for j in q[1:2]; add(branch,j) end
        elseif kind===:cccs
            for i in q; add(i,_control_branch_index(circuit,branches,component)) end
        elseif kind===:ccvs
            branch=branches[ci]; control=_control_branch_index(circuit,branches,component)
            for i in q; add(i,branch); add(branch,i) end; add(branch,control)
        elseif kind===:npn
            for i in q,j in q; add(i,j) end
        elseif kind in (:nmos,:pmos)
            for i in q,j in q; add(i,j) end
        elseif kind===:switch
            for i in q[1:2],j in q; add(i,j) end
        elseif kind===:opamp
            branch=branches[ci]; state=states[(ci,:dominant_pole)]
            add(q[3],branch); add(branch,q[3]); add(branch,branch); add(branch,state); add(branch,q[4]); add(branch,q[5])
            add(state,state); add(state,q[1]); add(state,q[2])
        end
    end
    for index in values(node_index); add(index,index) end
    ordered=sort!(collect(entries)); rows=first.(ordered); columns=last.(ordered)
    pattern=sparse(rows,columns,ones(Float64,length(rows)),n,n); fill!(pattern.nzval,0.); pattern
end

function _control_branch_index(circuit,branches,component)
    index=findfirst(candidate->candidate.name===component.parameters[:control],circuit.components)
    branches[index]
end

"""Create an isolated compiled-circuit snapshot for a simulation result."""
function _snapshot_compiled(cc::CompiledCircuit)
    CompiledCircuit(deepcopy(cc.circuit),cc.topology,cc.fingerprint)
end

_topology_signature(circuit)=string(circuit.name,[(component.kind,getfield.(component.terminals,:id),get(component.parameters,:control,nothing)) for component in circuit.components])

function compile(c::Circuit)
    errors=filter(d->d.severity===:error,check(c))
    isempty(errors)||throw(CircuitValidationError(errors))
    frozen=deepcopy(c)
    graph=equation_graph(frozen)
    signature=serialize_circuit(frozen)
    topology_signature=_topology_signature(frozen)
    pattern=_jacobian_pattern(frozen,graph.node_index,graph.branches,graph.states,graph.unknown_count)
    topology=CompiledTopology(graph.node_index,graph.branches,graph.states,graph.unknown_count,bytes2hex(sha1(topology_signature)),pattern)
    compiled=CompiledCircuit(frozen,topology,bytes2hex(sha1(signature)))
    for component in frozen.components
        component.kind in (:cccs,:ccvs)&&_control_branch(compiled,component)
    end
    compiled
end
function compile(compiled::CompiledCircuit)
    errors=filter(d->d.severity===:error,check(compiled.circuit)); isempty(errors)||throw(CircuitValidationError(errors))
    frozen=deepcopy(compiled.circuit); topology_hash=bytes2hex(sha1(_topology_signature(frozen)))
    topology_hash==compiled.topology.fingerprint||return compile(frozen)
    CompiledCircuit(frozen,compiled.topology,bytes2hex(sha1(serialize_circuit(frozen))))
end

_idx(cc,n)=n.id==0 ? 0 : cc.node_index[n.id]
_v(z,i)=i==0 ? zero(eltype(z)) : z[i]
_thermal_voltage(temperature)=1.380649e-23*Float64(temperature)/1.602176634e-19
function _limited_exponential(argument)
    # Keep the exponential and its derivative finite without making the
    # device locally constant.  A hard upper clamp gives Newton a zero diode
    # conductance exactly when a large trial voltage most needs a restoring
    # slope.  The tangent-line continuation is C1 at the limit and is the
    # usual safe extension used by circuit simulators during globalization.
    if argument>80.
        expvalue=exp(80.)
        expvalue*(1+argument-80.)-1,expvalue
    elseif argument < -80.
        expvalue=exp(-80.)
        expvalue-1,zero(expvalue)
    else
        expvalue=exp(argument)
        expvalue-1,expvalue
    end
end
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

function residual(cc::CompiledCircuit,z,zd,t;mode=:time,source_scale=1.,gmin=0.,temperature=300.)
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
            md=p[:model]; vd=_v(z,q[1])-_v(z,q[2]); id,_=_diode_conduction(md,vd,temperature); q[1]>0&&(r[q[1]]+=id); q[2]>0&&(r[q[2]]-=id)
            capacitance=differential_capacitance(md,vd;temperature)
            capacitance!=0&&_stampg!(r,zd,q[1],q[2],capacitance)
        elseif k===:npn
            md=p[:model]; vc,vb,ve=_v(z,q[1]),_v(z,q[2]),_v(z,q[3]); vt=_thermal_voltage(temperature)
            forward,_=_limited_exponential((vb-ve)/vt); reverse,_=_limited_exponential((vb-vc)/vt)
            forward_current=md.saturation_current*forward; reverse_current=md.saturation_current*reverse
            αf=md.forward_beta/(md.forward_beta+1); αr=md.reverse_beta/(md.reverse_beta+1)
            ic=αf*forward_current*(1+(vc-ve)/md.early_voltage)-reverse_current
            ib=(1-αf)*forward_current+(1-αr)*reverse_current
            q[1]>0&&(r[q[1]]+=ic); q[2]>0&&(r[q[2]]+=ib); q[3]>0&&(r[q[3]]-=ic+ib)
            md.cbe_zero_bias!=0&&_stampg!(r,zd,q[2],q[3],md.cbe_zero_bias)
            md.cbc_zero_bias!=0&&_stampg!(r,zd,q[2],q[1],md.cbc_zero_bias)
        elseif k in (:nmos,:pmos)
            md=p[:model]; vd,vg,vs,vb=_v(z,q[1]),_v(z,q[2]),_v(z,q[3]),_v(z,q[4])
            channel,_=_mosfet_channel(md,k,vd,vg,vs,vb)
            q[1]>0&&(r[q[1]]+=channel); q[3]>0&&(r[q[3]]-=channel)
            md.gate_source_capacitance!=0&&_stampg!(r,zd,q[2],q[3],md.gate_source_capacitance)
            md.gate_drain_capacitance!=0&&_stampg!(r,zd,q[2],q[1],md.gate_drain_capacitance)
            md.gate_bulk_capacitance!=0&&_stampg!(r,zd,q[2],q[4],md.gate_bulk_capacitance)
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
function residual_jacobian(cc::CompiledCircuit,z,previous,t,α;mode=:time,source_scale=1.,gmin=0.,temperature=300.)
    zd=α==0 ? zero(z) : α.*(z.-previous)
    r=residual(cc,z,zd,t;mode,source_scale,gmin,temperature)
    J=SparseMatrixCSC{eltype(z),Int}(cc.jacobian_pattern)
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
            md=p[:model]; vd=_v(z,q[1])-_v(z,q[2]); _,conduction=_diode_conduction(md,vd,temperature); gd=conduction+α*differential_capacitance(md,vd;temperature)
            _stamp_conductance!(J,q[1],q[2],gd)
        elseif k===:npn
            md=p[:model]; vc,vb,ve=_v(z,q[1]),_v(z,q[2]),_v(z,q[3]); vt=_thermal_voltage(temperature)
            forward,forward_slope=_limited_exponential((vb-ve)/vt); reverse,reverse_slope=_limited_exponential((vb-vc)/vt)
            If=md.saturation_current*forward; Ir=md.saturation_current*reverse
            gf=md.saturation_current*forward_slope/vt; gr=md.saturation_current*reverse_slope/vt
            αf=md.forward_beta/(md.forward_beta+1); αr=md.reverse_beta/(md.reverse_beta+1); early=1+(vc-ve)/md.early_voltage
            dic=(αf*If/md.early_voltage+gr, αf*gf*early-gr, αf*(-gf*early-If/md.early_voltage))
            dib=(-(1-αr)*gr, (1-αf)*gf+(1-αr)*gr, -(1-αf)*gf)
            for index in eachindex(q)
                _add!(J,q[1],q[index],dic[index]); _add!(J,q[2],q[index],dib[index]); _add!(J,q[3],q[index],-dic[index]-dib[index])
            end
            md.cbe_zero_bias!=0&&_stamp_conductance!(J,q[2],q[3],α*md.cbe_zero_bias)
            md.cbc_zero_bias!=0&&_stamp_conductance!(J,q[2],q[1],α*md.cbc_zero_bias)
        elseif k in (:nmos,:pmos)
            md=p[:model]; vd,vg,vs,vb=_v(z,q[1]),_v(z,q[2]),_v(z,q[3]),_v(z,q[4])
            _,derivatives=_mosfet_channel(md,k,vd,vg,vs,vb)
            for index in eachindex(q)
                _add!(J,q[1],q[index],derivatives[index])
                _add!(J,q[3],q[index],-derivatives[index])
            end
            _stamp_conductance!(J,q[2],q[3],α*md.gate_source_capacitance)
            _stamp_conductance!(J,q[2],q[1],α*md.gate_drain_capacitance)
            _stamp_conductance!(J,q[2],q[4],α*md.gate_bulk_capacitance)
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
