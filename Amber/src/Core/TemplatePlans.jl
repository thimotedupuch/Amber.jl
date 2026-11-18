"""Local topology and auxiliary layout reused by every instance of a template."""
struct PrimitiveSymbolicPlan
    kind::Symbol
    terminals::Vector{Int32}
    branch_offset::Int32
    state_offsets::UnitRange{Int32}
    state_names::Vector{Symbol}
    stamp_positions::Vector{Tuple{Int32,Int32}}
end
struct TemplateSymbolicPlan
    primitives::Vector{PrimitiveSymbolicPlan}
    auxiliary_unknowns::Int32
end
"""Caller-owned, bounded symbolic cache. No numerical values or global slots live here.

Plans are immutable by convention; compiled circuits never reference mutable cache
bookkeeping. A lock protects concurrent compilation and statistics. Clearing or
capacity eviction cannot invalidate already instantiated circuits.
"""
mutable struct SymbolicCompilationCache
    plans::Dict{String,TemplateSymbolicPlan}
    max_entries::Int
    builds::Int
    hits::Int
    evictions::Int
    lock::ReentrantLock
    function SymbolicCompilationCache(;max_entries=128)
        max_entries isa Integer && max_entries > 0 || throw(ArgumentError("cache capacity must be a positive integer"))
        new(Dict{String,TemplateSymbolicPlan}(),Int(max_entries),0,0,0,ReentrantLock())
    end
end
function symbolic_cache_stats(cache::SymbolicCompilationCache)
    lock(cache.lock) do
        (;entries=length(cache.plans),builds=cache.builds,hits=cache.hits,
            evictions=cache.evictions,max_entries=cache.max_entries)
    end
end
function Base.empty!(cache::SymbolicCompilationCache)
    lock(cache.lock) do
        empty!(cache.plans)
    end
    return cache
end
function _template_symbolic_key(body)
    io=IOBuffer()
    write(io,htol(UInt64(length(body.net_names))),htol(Int32(body.ground_net)))
    write(io,htol(UInt64(length(body.primitives))))
    for primitive in body.primitives
        kind=typeof(primitive.kernel).parameters[1]; contract=device_contract(kind)
        contract === nothing && throw(ArgumentError("unsupported device kind $kind"))
        _fingerprint_value!(io,kind)
        terminals=@view body.terminal_data[primitive.terminals]
        write(io,htol(UInt64(length(terminals))))
        for terminal in terminals
            write(io,htol(Int32(terminal)))
        end
        write(io,htol(UInt32(contract.terminals)),UInt8(contract.branch),htol(UInt32(length(contract.states))))
        for name in contract.states
            _fingerprint_value!(io,name)
        end
        positions=_DEVICE_STAMP_PLANS[kind].positions
        write(io,htol(UInt64(length(positions))))
        for (row,column) in positions
            write(io,htol(row),htol(column))
        end
    end
    # Use full canonical bytes, not a truncated digest, as the equality key.
    return String(take!(io))
end
function _build_template_symbolic_plan(body)
    primitives=PrimitiveSymbolicPlan[]; offset=Int32(0)
    for primitive in body.primitives
        kind=typeof(primitive.kernel).parameters[1]; contract=device_contract(kind)
        branch=contract.branch ? (offset+=Int32(1)) : Int32(0)
        states=(offset+Int32(1)):(offset+Int32(length(contract.states)))
        offset+=Int32(length(contract.states))
        push!(primitives,PrimitiveSymbolicPlan(kind,collect(body.terminal_data[primitive.terminals]),
            branch,states,copy(contract.states),copy(_DEVICE_STAMP_PLANS[kind].positions)))
    end
    return TemplateSymbolicPlan(primitives,offset)
end
function _template_symbolic_plan(body,cache::SymbolicCompilationCache)
    key=_template_symbolic_key(body)
    lock(cache.lock) do
        if haskey(cache.plans,key)
            cache.hits+=1
            return cache.plans[key]
        end
        plan=_build_template_symbolic_plan(body)
        if length(cache.plans) >= cache.max_entries
            cache.evictions+=length(cache.plans); empty!(cache.plans)
        end
        cache.plans[key]=plan; cache.builds+=1
        return plan
    end
end
function _design_symbolic_plans(design,cache)
    # The registry already deduplicates templates. In the default path each
    # local plan is built once, without paying persistent-cache key costs.
    if cache === nothing
        return (;root=_build_template_symbolic_plan(design.root_ir),
            templates=[_build_template_symbolic_plan(template.body) for template in design.templates.templates])
    end
    cache isa SymbolicCompilationCache || throw(ArgumentError("symbolic_cache must be a SymbolicCompilationCache"))
    return (;root=_template_symbolic_plan(design.root_ir,cache),
        templates=[_template_symbolic_plan(template.body,cache) for template in design.templates.templates])
end
function _instantiate_auxiliary_layout!(branch_by_primitive,states_by_primitive,branch_lookup,
        plan::TemplateSymbolicPlan,base::Int32,primitive_start,instance_id,template_id)
    for (index,primitive) in enumerate(plan.primitives)
        ordinal=primitive_start+index
        branch=iszero(primitive.branch_offset) ? Int32(0) : base+primitive.branch_offset
        branch_by_primitive[ordinal]=branch
        states_by_primitive[ordinal]=Int32[base+offset for offset in primitive.state_offsets]
        iszero(branch) || (branch_lookup[(instance_id,template_id,Int32(index))]=branch)
    end
    return primitive_start+length(plan.primitives),base+plan.auxiliary_unknowns
end
