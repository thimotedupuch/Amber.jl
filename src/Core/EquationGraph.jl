"""Dependencies used to schedule evaluation and invalidate numerical caches.

`linear` declares f = G(p)x - b(t), q = C(p)x: its matrices depend only on
parameters, not on state, time, or analysis temperature. `source` identifies
independent forcing; `storage` declares a possibly nonzero q contribution.
"""
struct DeviceDependencies
    linear::Bool
    source::Bool
    storage::Bool
end

"""Device topology, observables, and numerical evaluation dependencies."""
struct DeviceContract
    terminals::Int
    branch::Bool
    states::Vector{Symbol}
    dc_path::Bool
    noise::Bool
    observables::Tuple
    dependencies::DeviceDependencies
end
_contract(terminals;branch=false,states=Symbol[],dc_path=false,noise=false,observables=(:voltage,:current,:power),
        linear=false,source=false,storage=false)=
    DeviceContract(terminals,branch,states,dc_path,noise,observables,DeviceDependencies(linear,source,storage))
const _DEVICE_SPECS = Dict{Symbol,DeviceContract}(
    :resistor=>_contract(2;dc_path=true,noise=true,linear=true), :conductance=>_contract(2;dc_path=true,noise=true,linear=true),
    :capacitor=>_contract(2;observables=(:voltage,:current,:power,:charge),linear=true,storage=true), :current_source=>_contract(2;linear=true,source=true),
    :voltage_source=>_contract(2;branch=true,dc_path=true,noise=true,linear=true,source=true), :inductor=>_contract(2;branch=true,dc_path=true,linear=true,storage=true),
    :vccs=>_contract(4;linear=true), :vcvs=>_contract(4;branch=true,dc_path=true,linear=true), :cccs=>_contract(2;linear=true),
    :ccvs=>_contract(2;branch=true,dc_path=true,linear=true), :diode=>_contract(2;dc_path=true,noise=true,storage=true,observables=(:voltage,:current,:power,:charge)),
    :npn=>_contract(3;dc_path=true,noise=true,storage=true),
    :nmos=>_contract(4;dc_path=true,noise=true,storage=true), :pmos=>_contract(4;dc_path=true,noise=true,storage=true),
    :switch=>_contract(4;dc_path=true,noise=true),
    :opamp=>_contract(5;branch=true,states=[:dominant_pole],dc_path=true,noise=true,storage=true),
    :behavioral_current_source=>_contract(10),
    :behavioral_voltage_source=>_contract(10;branch=true,dc_path=true),
)
device_contract(kind::Symbol)=get(_DEVICE_SPECS,kind,nothing)
device_contract(::Type{Val{K}}) where {K}=device_contract(K)

# Local unknowns: terminals, branch, states, then the controlling branch.
# These plans are shared by every instance of a device kind. Slot counts and
# global sparse positions are derived from the same description.
struct DeviceStampPlan
    positions::Vector{Tuple{Int32,Int32}}
end

function _describe_stamp!(emit, kind::Symbol, q, branch::Int32, states, control::Int32)
    if kind in (:resistor, :conductance, :capacitor, :diode)
        for row in q[1:2], column in q[1:2]; emit(row, column) end
    elseif kind in (:voltage_source, :inductor)
        for node in q[1:2]; emit(node, branch); emit(branch, node) end
        emit(branch, branch)
    elseif kind === :vccs
        for row in q[3:4], column in q[1:2]; emit(row, column) end
    elseif kind === :vcvs
        for node in q[3:4]; emit(node, branch); emit(branch, node) end
        for column in q[1:2]; emit(branch, column) end
    elseif kind === :cccs
        emit(q[1], control); emit(q[2], control)
    elseif kind === :ccvs
        for node in q[1:2]; emit(node, branch); emit(branch, node) end
        emit(branch, control)
    elseif kind in (:npn, :nmos, :pmos)
        for row in q, column in q; emit(row, column) end
    elseif kind === :switch
        for row in q[1:2], column in q; emit(row, column) end
    elseif kind === :opamp
        state = first(states)
        emit(q[3], branch); emit(branch, q[3]); emit(branch, branch); emit(branch, state)
        emit(branch, q[4]); emit(branch, q[5]); emit(state, state); emit(state, q[1]); emit(state, q[2])
    elseif kind === :behavioral_current_source
        for row in q[1:2], column in q[3:10]; emit(row, column) end
    elseif kind === :behavioral_voltage_source
        emit(q[1], branch); emit(q[2], branch)
        emit(branch, q[1]); emit(branch, q[2])
        for column in q[3:10]; emit(branch, column) end
    end
end

const _DEVICE_STAMP_PLANS = Dict(kind => let
    n=contract.terminals
    positions=Tuple{Int32,Int32}[]
    _describe_stamp!((r,c)->push!(positions,(r,c)),kind,Tuple(Int32.(1:n)),
        Int32(n+1),Int32.(n+2:n+1+length(contract.states)),Int32(n+2+length(contract.states)))
    DeviceStampPlan(positions)
end for (kind,contract) in _DEVICE_SPECS)

@inline function _stamp_unknown(index,terminals,branch,states,control)
    n=length(terminals)
    index<=n && return terminals[index]
    index==n+1 && return branch
    index<=n+1+length(states) && return states[index-n-1]
    control
end

function _emit_stamp_positions!(emit,kind::Symbol,terminals,branch::Int32,states,control::Int32)
    for (row,column) in _DEVICE_STAMP_PLANS[kind].positions
        emit(_stamp_unknown(row,terminals,branch,states,control),
            _stamp_unknown(column,terminals,branch,states,control))
    end
end
