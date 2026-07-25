function _small_signal_frequencies(specification;points,scale)
    if specification isa Pair
        _validate_frequency_range(specification,points,scale)
        first(specification)==last(specification)&&return [Float64(first(specification))]
        return scale===:log ? collect(10 .^ range(log10(first(specification)),log10(last(specification)),length=points)) : collect(range(first(specification),last(specification),length=points))
    end
    _validate_frequency_grid(specification)
end

function small_signal(c,p::Union{Pair,AbstractVector};points=p isa AbstractVector ? length(p) : 100,scale=:log,source=nothing,temperature=300.,kw...)
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("temperature must be finite and positive"))
    cc=compile(c); operating_point_result=_require_converged(operating_point(cc;temperature,kw...),"small-signal operating point"); op=operating_point_result.values[:,1]
    fs=_small_signal_frequencies(p;points,scale)
    warnings=String[]
    active=[x.name for x in cc.circuit.components if x.kind in (:voltage_source,:current_source)&&!iszero(get(x.parameters,:ac,0.))]
    if source===nothing&&length(active)>1
        throw(ArgumentError("multiple AC sources are active ($(join(active, ", "))); select source=... explicitly"))
    elseif source!==nothing
        index=findfirst(x->x.name===source,cc.circuit.components)
        index===nothing&&throw(ArgumentError("unknown small-signal source $(source)"))
        selected=cc.circuit.components[index]
        selected.kind in (:voltage_source,:current_source)||throw(ArgumentError("$(source) is not an independent source"))
        iszero(get(selected.parameters,:ac,0.))&&push!(warnings,"selected source $(source) has zero AC excitation")
    elseif isempty(active)
        push!(warnings,"the circuit has no nonzero AC excitation")
    end
    vals=zeros(ComplexF64,cc.n,length(fs)); _,Jz=residual_jacobian(cc,op,op,0.,0.;mode=:dc,temperature)
    _,combined=residual_jacobian(cc,op,op,0.,1.;mode=:dc,temperature); Jd=combined-Jz; b=ac_excitation(cc;source)
    for (j,f) in enumerate(fs); vals[:,j]=_solve_linear(Jz+im*2π*f*Jd,b,"small-signal matrix is singular at $(f) Hz") end
    analysis=SmallSignal(fs;source,temperature=Float64(temperature))
    stats=_finalize_stats!(Dict{Symbol,Any}(:converged=>true,:temperature=>Float64(temperature),:warnings=>warnings,:source=>source,:active_sources=>active))
    SimulationResult(cc,analysis,Float64.(fs),vals,stats)
end

simulate(c,a::SmallSignal)=small_signal(c,a.frequencies;source=a.source,temperature=a.temperature)
run(c,analyses::AbstractVector{<:AbstractAnalysis})=map(a->simulate(c,a),analyses)
