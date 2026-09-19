# Storage q(x) in equation space for d(q(x))/dt + f(x,t) = 0.
# Stamp q_x directly: extracting it as (f_x + q_x) - f_x loses small entries.
_storage_batch!(workspace, batch::AbstractCompiledBatch, state, temperature) = nothing

function _storage_batch!(workspace, batch::PrimitiveBatch{Val{:capacitor}}, state, temperature)
    for device in eachindex(batch.parameters)
        p,n=(batch.terminals[j][device] for j in 1:2)
        c=batch.parameters[device].value
        _stamp_two_terminal!(workspace.storage,workspace.storage_jacobian.nzval,batch,device,
            c*(_workspace_value(state,p)-_workspace_value(state,n)),c)
    end
end

function _storage_batch!(workspace, batch::PrimitiveBatch{Val{:inductor}}, state, temperature)
    for device in eachindex(batch.parameters)
        branch=batch.branch_unknowns[device]; inductance=batch.parameters[device].value
        workspace.storage[Int(branch)]-=inductance*state[Int(branch)]
        _workspace_stamp!(workspace.storage_jacobian.nzval,batch.jacobian_slots[5,device],-inductance)
    end
end

function _storage_batch!(workspace, batch::PrimitiveBatch{Val{:diode}}, state, temperature)
    for device in eachindex(batch.parameters)
        p,n=(batch.terminals[j][device] for j in 1:2)
        model=batch.parameters[device].model
        v=_workspace_value(state,p)-_workspace_value(state,n)
        _stamp_two_terminal!(workspace.storage,workspace.storage_jacobian.nzval,batch,device,
            charge(model,v;temperature),differential_capacitance(model,v;temperature))
    end
end

function _storage_pair!(workspace,batch,device,nodes,width,a,b,c,state)
    q=c*(_workspace_value(state,nodes[a])-_workspace_value(state,nodes[b]))
    _workspace_add!(workspace.storage,nodes[a],q)
    _workspace_add!(workspace.storage,nodes[b],-q)
    for (row,column,value) in ((a,a,c),(a,b,-c),(b,a,-c),(b,b,c))
        _workspace_matrix_stamp!(workspace.storage_jacobian.nzval,batch,device,width,row,column,value)
    end
end

function _storage_batch!(workspace, batch::PrimitiveBatch{Val{:npn}}, state, temperature)
    for device in eachindex(batch.parameters)
        nodes=ntuple(j->batch.terminals[j][device],3); model=batch.parameters[device].model
        _storage_pair!(workspace,batch,device,nodes,3,2,3,model.cbe_zero_bias,state)
        _storage_pair!(workspace,batch,device,nodes,3,2,1,model.cbc_zero_bias,state)
    end
end

function _mos_storage!(workspace,batch,kind,state,temperature)
    for device in eachindex(batch.parameters)
        nodes=ntuple(j->batch.terminals[j][device],4); model=batch.parameters[device].model
        if model isa ChargeBasedMOSFET
            evaluated=_charge_mos_evaluate(model,kind,ntuple(j->_workspace_value(state,nodes[j]),4);temperature,
                order=workspace.storage_jacobian.nzval === nothing ? Val(0) : Val(1))
            for row in 1:4
                q=evaluated.charges[row]
                _workspace_add!(workspace.storage,nodes[row],q.value)
                workspace.storage_jacobian.nzval === nothing && continue
                for column in 1:4
                    _workspace_matrix_stamp!(workspace.storage_jacobian.nzval,batch,device,4,row,column,q.gradient[column])
                end
            end
        else
            for (a,b,c) in ((2,3,model.gate_source_capacitance),
                    (2,1,model.gate_drain_capacitance),(2,4,model.gate_bulk_capacitance))
                _storage_pair!(workspace,batch,device,nodes,4,a,b,c,state)
            end
        end
    end
end
_storage_batch!(workspace,batch::PrimitiveBatch{Val{:nmos}},state,temperature)=
    _mos_storage!(workspace,batch,:nmos,state,temperature)
_storage_batch!(workspace,batch::PrimitiveBatch{Val{:pmos}},state,temperature)=
    _mos_storage!(workspace,batch,:pmos,state,temperature)

function _storage_batch!(workspace,batch::PrimitiveBatch{Val{:opamp}},state,temperature)
    for device in eachindex(batch.parameters)
        internal=first(batch.state_unknowns[device])
        workspace.storage[Int(internal)]+=state[Int(internal)]
        _workspace_stamp!(workspace.storage_jacobian.nzval,batch.jacobian_slots[7,device],one(eltype(state)))
    end
end

_storage_batches!(workspace,::Tuple{},state,temperature)=nothing
function _storage_batches!(workspace,batches::Tuple,state,temperature)
    _storage_batch!(workspace,first(batches),state,temperature)
    _storage_batches!(workspace,Base.tail(batches),state,temperature)
end

"""Assemble stored charge/flux and its Jacobian in independent reusable buffers."""
function storage_jacobian!(workspace::SimulationWorkspace,cc::CompiledCircuit,state;temperature=300.)
    length(state)==cc.n||throw(DimensionMismatch("state must match the compiled unknown count"))
    fill!(workspace.storage,0); fill!(workspace.storage_jacobian.nzval,0)
    _storage_batches!(workspace,cc.parameters.batches,state,temperature)
    workspace.storage,workspace.storage_jacobian
end

function _storage(cc,state;temperature=300.,workspace=nothing)
    workspace===nothing&&(workspace=SimulationWorkspace(cc;scalar_type=eltype(state)))
    fill!(workspace.storage,0)
    _storage_batches!(_assembly_view(workspace,Val(false)),cc.parameters.batches,state,temperature)
    copy(workspace.storage)
end

function _static_dynamic_jacobians(cc,state,t=0.;temperature=300.,mode=:time)
    workspace=SimulationWorkspace(cc;scalar_type=eltype(state))
    _static_dynamic_jacobians!(workspace,cc,state,t;temperature,mode)
end

function _static_dynamic_jacobians!(workspace,cc,state,t=0.;temperature=300.,mode=:time)
    _,g=residual_jacobian!(workspace,cc,state,state,t,0.;temperature,mode)
    _,c=storage_jacobian!(workspace,cc,state;temperature)
    g,c
end

# qhistory is the BDF-weighted combination of previous q values, not q of a
# weighted combination of previous voltages. Both Newton and its line search
# must evaluate this same discrete residual.
function _step_batch!(view,batch,state,zero_derivative,t,alpha,mode,source_scale,temperature)
    _assemble_batch!(view,batch,state,zero_derivative,t,zero(alpha),mode,source_scale,temperature)
    (iszero(alpha) || !_has_storage(batch)) || _storage_batch!(view,batch,state,temperature)
end

# Evaluate current and charge once. The discretized conservative equation uses
# f_x + alpha*q_x, so it needs no charge Hessian (unlike q_x*xdot).
function _step_batch!(view,batch::PrimitiveBatch{K},state,zero_derivative,t,alpha,mode,source_scale,temperature) where {K<:Union{Val{:nmos},Val{:pmos}}}
    for device in eachindex(batch.parameters)
        model=batch.parameters[device].model
        if !(model isa ChargeBasedMOSFET)
            # A batch has one concrete model type, so the fallback runs once.
            _assemble_batch!(view,batch,state,zero_derivative,t,zero(alpha),mode,source_scale,temperature)
            iszero(alpha) || _storage_batch!(view,batch,state,temperature)
            return nothing
        end
        nodes=ntuple(j->batch.terminals[j][device],4)
        matrix=view.jacobian.nzval
        evaluated=_charge_mos_evaluate(model,_batch_kind(batch),ntuple(j->_workspace_value(state,nodes[j]),4);
            temperature,order=matrix === nothing ? Val(0) : Val(1))
        for row in 1:4
            f=evaluated.currents[row]; q=evaluated.charges[row]
            _workspace_add!(view.residual,nodes[row],f.value)
            iszero(alpha) || _workspace_add!(view.storage,nodes[row],q.value)
            matrix === nothing && continue
            for column in 1:4
                _workspace_matrix_stamp!(matrix,batch,device,4,row,column,f.gradient[column])
                iszero(alpha) || _workspace_matrix_stamp!(view.storage_jacobian.nzval,batch,device,4,row,column,q.gradient[column])
            end
        end
    end
    nothing
end

_step_batches!(view,::Tuple{},args...) = nothing
function _step_batches!(view,batches::Tuple,args...)
    _linear_batch(first(batches)) || _step_batch!(view,first(batches),args...)
    _step_batches!(view,Base.tail(batches),args...)
end

_constant_batches!(view,::Tuple{},zero_state) = nothing
function _constant_batches!(view,batches::Tuple,zero_state)
    batch=first(batches)
    if _linear_batch(batch)
        _assemble_batch!(view,batch,zero_state,zero_state,0.,0.,:matrix,0.,300.)
        _has_storage(batch) && _storage_batch!(view,batch,zero_state,300.)
    end
    _constant_batches!(view,Base.tail(batches),zero_state)
end

function _ensure_constant_matrices!(workspace,cc)
    if workspace.constant_topology === cc.topology &&
            workspace.constant_fingerprint == cc.parameters.matrix_fingerprint
        return nothing
    end
    fill!(workspace.constant_jacobian.nzval,0)
    fill!(workspace.constant_storage_jacobian.nzval,0)
    fill!(workspace.derivative,0)
    fill!(workspace.residual,0); fill!(workspace.storage,0)
    view=(;residual=workspace.residual,jacobian=workspace.constant_jacobian,
        storage=workspace.storage,storage_jacobian=workspace.constant_storage_jacobian)
    _constant_batches!(view,cc.parameters.batches,workspace.derivative)
    workspace.constant_topology=cc.topology
    workspace.constant_fingerprint=cc.parameters.matrix_fingerprint
    workspace.constant_assemblies+=1
    nothing
end

_forcing_batch!(r,batch,t,mode,source_scale) = nothing
function _forcing_batch!(r,batch::PrimitiveBatch{Val{:current_source}},t,mode,source_scale)
    for device in eachindex(batch.parameters)
        current=source_scale*_source_value(batch.parameters[device],t,mode)
        _workspace_add!(r,batch.terminals[1][device],current)
        _workspace_add!(r,batch.terminals[2][device],-current)
    end
end
function _forcing_batch!(r,batch::PrimitiveBatch{Val{:voltage_source}},t,mode,source_scale)
    for device in eachindex(batch.parameters)
        r[Int(batch.branch_unknowns[device])]-=source_scale*_source_value(batch.parameters[device],t,mode)
    end
end
_forcing_batches!(r,::Tuple{},args...) = nothing
function _forcing_batches!(r,batches::Tuple,args...)
    _has_forcing(first(batches)) && _forcing_batch!(r,first(batches),args...)
    _forcing_batches!(r,Base.tail(batches),args...)
end

function _step_evaluate!(workspace,cc,state,qhistory,t,alpha,want_jacobian::Val{J};
        mode=:time,source_scale=1.,gmin=0.,temperature=300.) where {J}
    r=J ? workspace.residual : workspace.candidate_residual
    _ensure_constant_matrices!(workspace,cc)
    mul!(r,workspace.constant_jacobian,state)
    fill!(workspace.derivative,0)
    J && copyto!(workspace.jacobian.nzval,workspace.constant_jacobian.nzval)
    if !iszero(alpha)
        mul!(workspace.storage,workspace.constant_storage_jacobian,state)
        J && copyto!(workspace.storage_jacobian.nzval,workspace.constant_storage_jacobian.nzval)
    end
    _forcing_batches!(r,cc.parameters.batches,t,mode,source_scale)
    view=_assembly_view(workspace,want_jacobian;residual=r)
    _step_batches!(view,cc.parameters.batches,state,workspace.derivative,t,alpha,mode,source_scale,temperature)
    if !iszero(alpha)
        @. r+=alpha*(workspace.storage-qhistory)
        J && (@. workspace.jacobian.nzval+=alpha*workspace.storage_jacobian.nzval)
    end
    if !iszero(gmin)
        for index in 1:cc.topology.hierarchy.solver_net_count
            r[index]+=gmin*state[index]
            _workspace_stamp!(view.jacobian.nzval,Int32(cc.topology.pattern.diagonal_slots[index]),gmin)
        end
    end
    r
end

function _step_residual_jacobian!(workspace,cc,state,qhistory,t,alpha;kwargs...)
    r=_step_evaluate!(workspace,cc,state,qhistory,t,alpha,Val(true);kwargs...)
    r,workspace.jacobian
end
_step_residual!(workspace,cc,state,qhistory,t,alpha;kwargs...) =
    _step_evaluate!(workspace,cc,state,qhistory,t,alpha,Val(false);kwargs...)

function _bdf_storage_history(cc,previous,older,ratio,h,alpha;temperature=300.,workspace=nothing)
    workspace===nothing&&(workspace=SimulationWorkspace(cc;scalar_type=eltype(previous)))
    qprevious=_storage(cc,previous;temperature,workspace)
    qolder=_storage(cc,older;temperature,workspace)
    (((1+ratio)/h).*qprevious.-(ratio^2/((1+ratio)*h)).*qolder)./alpha
end
