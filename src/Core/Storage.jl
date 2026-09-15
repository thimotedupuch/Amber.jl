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
            evaluated=_charge_mos_evaluate(model,kind,ntuple(j->_workspace_value(state,nodes[j]),4);temperature)
            for row in 1:4
                q=evaluated.charges[row]
                _workspace_add!(workspace.storage,nodes[row],q.value)
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
    q,_=storage_jacobian!(workspace,cc,state;temperature)
    copy(q)
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
function _step_residual_jacobian!(workspace,cc,state,qhistory,t,alpha;
        mode=:time,source_scale=1.,gmin=0.,temperature=300.)
    r,j=residual_jacobian!(workspace,cc,state,state,t,0.;mode,source_scale,gmin,temperature)
    if !iszero(alpha)
        q,c=storage_jacobian!(workspace,cc,state;temperature)
        @. r+=alpha*(q-qhistory)
        @. j.nzval+=alpha*c.nzval
    end
    r,j
end

function _bdf_storage_history(cc,previous,older,ratio,h,alpha;temperature=300.,workspace=nothing)
    workspace===nothing&&(workspace=SimulationWorkspace(cc;scalar_type=eltype(previous)))
    qprevious=_storage(cc,previous;temperature,workspace)
    qolder=_storage(cc,older;temperature,workspace)
    (((1+ratio)/h).*qprevious.-(ratio^2/((1+ratio)*h)).*qolder)./alpha
end
