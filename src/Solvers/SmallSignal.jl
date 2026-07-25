function small_signal(c,p::Pair;points=100,scale=:log,source=nothing,temperature=300.,kw...)
    _validate_frequency_range(p,points,scale)
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("temperature must be finite and positive"))
    cc=compile(c); operating_point_result=_require_converged(operating_point(cc;temperature,kw...),"small-signal operating point"); op=operating_point_result.values[:,1]
    fs=scale===:log ? 10 .^ range(log10(first(p)),log10(last(p)),length=points) : collect(range(first(p),last(p),length=points))
    vals=zeros(ComplexF64,cc.n,length(fs)); _,Jz=residual_jacobian(cc,op,op,0.,0.;mode=:dc,temperature)
    _,combined=residual_jacobian(cc,op,op,0.,1.;mode=:dc,temperature); Jd=combined-Jz; b=ac_excitation(cc;source)
    for (j,f) in enumerate(fs); vals[:,j]=_solve_linear(Jz+im*2π*f*Jd,b,"small-signal matrix is singular at $(f) Hz") end
    analysis=SmallSignal(Float64(first(p))=>Float64(last(p));points,scale,source)
    stats=_finalize_stats!(Dict{Symbol,Any}(:converged=>true,:temperature=>Float64(temperature),:warnings=>String[]))
    SimulationResult(cc,analysis,Float64.(fs),vals,stats)
end

simulate(c,a::SmallSignal)=small_signal(c,a.frequencies;points=a.points,scale=a.scale,source=a.source)
run(c,analyses::AbstractVector{<:AbstractAnalysis})=map(a->simulate(c,a),analyses)
