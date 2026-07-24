function small_signal(c,p::Pair;points=100,scale=:log,source=nothing,kw...)
    cc=compile(c); op=operating_point(cc).values[:,1]
    fs=scale===:log ? 10 .^ range(log10(first(p)),log10(last(p)),length=points) : collect(range(first(p),last(p),length=points))
    vals=zeros(ComplexF64,cc.n,length(fs)); _,Jz=residual_jacobian(cc,op,op,0.,0.;mode=:dc)
    _,combined=residual_jacobian(cc,op,op,0.,1.;mode=:dc); Jd=combined-Jz; b=ac_excitation(cc;source)
    for (j,f) in enumerate(fs); vals[:,j]=(Jz+im*2π*f*Jd)\b end
    analysis=SmallSignal(Float64(first(p))=>Float64(last(p));points,scale,source)
    SimulationResult(cc,analysis,Float64.(fs),vals,Dict{Symbol,Any}(:converged=>true))
end

simulate(c,a::SmallSignal)=small_signal(c,a.frequencies;points=a.points,scale=a.scale,source=a.source)
run(c,analyses::AbstractVector{<:AbstractAnalysis})=map(a->simulate(c,a),analyses)
