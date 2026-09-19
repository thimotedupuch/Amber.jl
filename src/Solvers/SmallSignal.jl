function _small_signal_frequencies(specification;points,scale)
    if specification isa Pair
        _validate_frequency_range(specification,points,scale)
        first(specification)==last(specification)&&return [Float64(first(specification))]
        return scale===:log ? collect(10 .^ range(log10(first(specification)),log10(last(specification)),length=points)) : collect(range(first(specification),last(specification),length=points))
    end
    _validate_frequency_grid(specification)
end

function small_signal(c,p::Union{Pair,AbstractVector};points=p isa AbstractVector ? length(p) : 100,scale=:log,source=nothing,temperature=300.,solver=SolverOptions(),kw...)
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("temperature must be finite and positive"))
    cc=compile(c); operating_point_result=_require_converged(operating_point(cc;temperature,solver,kw...),"small-signal operating point"); op=operating_point_result.values[:,1]
    fs=_small_signal_frequencies(p;points,scale)
    warnings=String[]
    active=String[]
    source_kinds=Dict{String,Symbol}()
    source_amplitudes=Dict{String,Any}()
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch||continue; kind=_batch_kind(batch)
        kind in (:voltage_source,:current_source)||continue
        for device in eachindex(batch.parameters)
            instance_name,device_name=_locator_device_name(cc.design,batch.locators[device])
            path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
            source_kinds[path]=kind; source_amplitudes[path]=get(batch.parameters[device],:ac,0.)
            iszero(source_amplitudes[path])||push!(active,path)
        end
    end
    if source===nothing&&length(active)>1
        throw(ArgumentError("multiple AC sources are active ($(join(active, ", "))); select source=... explicitly"))
    elseif source!==nothing
        path=String(source); haskey(source_kinds,path)||throw(ArgumentError("unknown small-signal source $(source)"))
        iszero(source_amplitudes[path])&&push!(warnings,"selected source $(source) has zero AC excitation")
    elseif isempty(active)
        push!(warnings,"the circuit has no nonzero AC excitation")
    end
    vals=zeros(ComplexF64,cc.n,length(fs)); Jz,Jd=_static_dynamic_jacobians(cc,op;mode=:dc,temperature); b=ac_excitation(cc;source)
    # Both derivatives use the compiler's union pattern, including stored
    # zeros. Frequency changes values only, so symbolic analysis is reusable.
    system=SparseMatrixCSC{ComplexF64,Int}(cc.n,cc.n,copy(Jz.colptr),copy(Jz.rowval),
        zeros(ComplexF64,length(Jz.nzval)))
    factorization=nothing
    for (j,f) in enumerate(fs)
        @. system.nzval=Jz.nzval+im*2π*f*Jd.nzval
        try
            factorization=factorization===nothing ? _new_factorization(system,solver.linear_solver) :
                lu!(factorization,system;reuse_symbolic=true)
            ldiv!(view(vals,:,j),factorization,b)
        catch error
            error isa LinearAlgebra.SingularException || rethrow()
            throw(LinearSolveError("small-signal matrix is singular at $(f) Hz"))
        end
    end
    analysis=SmallSignal(fs;source,temperature=Float64(temperature),solver=operating_point_result.analysis.solver)
    stats=_finalize_stats!(Dict{Symbol,Any}(:converged=>true,:temperature=>Float64(temperature),:warnings=>warnings,:source=>source,:active_sources=>active,:operating_point=>copy(op)))
    stats[:symbolic_factorizations]=isempty(fs) ? 0 : 1
    stats[:numeric_factorizations]=length(fs)
    SimulationResult(cc,analysis,Float64.(fs),vals,stats)
end

simulate(c,a::SmallSignal)=small_signal(c,a.frequencies;source=a.source,temperature=a.temperature,solver=a.solver)
run(c,analyses::AbstractVector{<:AbstractAnalysis})=map(a->simulate(c,a),analyses)
