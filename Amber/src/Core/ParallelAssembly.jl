"""Ordered, conflict-free assembly waves bound to a compiled topology."""
struct AssemblyChunk
    batch::Int
    devices::UnitRange{Int}
end
struct ParallelAssemblyPlan
    topology::HierarchicalCompiledTopology
    waves::Vector{Vector{AssemblyChunk}}
end
# Sources may contain arbitrary waveforms; behavioral devices contain callbacks.
_parallel_safe(::ResistorBatch) = true
_parallel_safe(batch::PrimitiveBatch) = _batch_kind(batch) in
    (:resistor,:conductance,:capacitor,:inductor,:vccs,:vcvs,:cccs,:ccvs,
     :diode,:npn,:nmos,:pmos,:switch,:opamp)
_parallel_safe(::AbstractCompiledBatch) = false

"""Build dependency waves preserving serial accumulation order at every slot."""
function parallel_assembly_plan(cc::CompiledCircuit; chunk_size::Int=256)
    chunk_size > 0 || throw(ArgumentError("chunk_size must be positive"))
    rows=zeros(Int,cc.n); slots=zeros(Int,length(cc.topology.pattern.rowval))
    waves=Vector{AssemblyChunk}[]; barrier=0
    for (bi,batch) in enumerate(cc.parameters.batches)
        _inplace_batch_supported(batch) || throw(ArgumentError("unsupported assembly batch"))
        safe=_parallel_safe(batch); count=length(batch.parameters)
        width=safe ? chunk_size : max(count,1)
        for first in 1:width:count
            range=first:min(first+width-1,count)
            writes=Set{Int}(); stamps=Set{Int}()
            for d in range
                for r in view(batch.residual_slots,:,d); r==0 || push!(writes,Int(r)); end
                if batch isa PrimitiveBatch
                    batch.branch_unknowns[d]==0 || push!(writes,Int(batch.branch_unknowns[d]))
                    for r in batch.state_unknowns[d]; r==0 || push!(writes,Int(r)); end
                end
                for slot in view(batch.jacobian_slots,:,d); slot==0 || push!(stamps,Int(slot)); end
            end
            level=safe ? max(barrier,maximum((rows[r] for r in writes);init=0),maximum((slots[s] for s in stamps);init=0))+1 : length(waves)+1
            while length(waves)<level; push!(waves,AssemblyChunk[]); end
            push!(waves[level],AssemblyChunk(bi,range))
            for r in writes; rows[r]=level; end
            for s in stamps; slots[s]=level; end
            safe || (barrier=level)
        end
    end
    ParallelAssemblyPlan(cc.topology,waves)
end

function _execute_chunk!(ws,batch,range,state,t,alpha,mode,source_scale,temperature)
    view=(;residual=ws.residual,jacobian=(nzval=ws.jacobian.nzval,),
        storage=ws.storage,storage_jacobian=(nzval=ws.storage_jacobian.nzval,),device_range=range)
    _assemble_batch!(view,batch,state,ws.derivative,t,alpha,mode,source_scale,temperature)
end
"""Opt-in continuous residual/Jacobian assembly using ordered dependency waves."""
function parallel_residual_jacobian!(ws::SimulationWorkspace,cc::CompiledCircuit,plan::ParallelAssemblyPlan,
        state,previous,t,alpha;mode=:time,source_scale=1.0,gmin=0.0,temperature=300.0,threaded=true)
    _validate_workspace(ws,cc)
    plan.topology === cc.topology || throw(ArgumentError("assembly plan belongs to another topology"))
    length(state)==cc.n==length(previous) || throw(DimensionMismatch("state size"))
    for input in (state,previous), output in (ws.residual,ws.derivative,ws.jacobian.nzval)
        Base.mightalias(input,output) && throw(ArgumentError("assembly inputs must not alias output buffers"))
    end
    t=_si_value(t,Unitful.s); alpha=_si_value(alpha,inv(Unitful.s)); temperature=_si_value(temperature,Unitful.K)
    fill!(ws.residual,0);fill!(ws.jacobian.nzval,0)
    @. ws.derivative = alpha == 0 ? 0 : alpha*(state-previous)
    if gmin != 0
        for i in 1:cc.topology.hierarchy.solver_net_count
            ws.residual[i]+=gmin*state[i]
            ws.jacobian.nzval[cc.topology.pattern.diagonal_slots[i]]+=gmin
        end
    end
    for wave in plan.waves
        if threaded && length(wave)>1
            @sync for chunk in wave
                Threads.@spawn _execute_chunk!(ws,cc.parameters.batches[chunk.batch],chunk.devices,state,t,alpha,mode,source_scale,temperature)
            end
        else
            for chunk in wave
                _execute_chunk!(ws,cc.parameters.batches[chunk.batch],chunk.devices,state,t,alpha,mode,source_scale,temperature)
            end
        end
    end
    ws.residual,ws.jacobian
end
