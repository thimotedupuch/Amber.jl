function operating_point(c;temperature=300.,kw...)
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("temperature must be finite and positive"))
    cc=compile(c); z=zeros(cc.n); total_iterations=0; converged=false; failed_continuation_steps=Int[]
    continuation=((.02,1e-6),(.1,1e-7),(.3,1e-8),(.6,1e-10),(1.,0.))
    for (step,(source_scale,gmin)) in enumerate(continuation)
        z,iterations,ok=_newton(cc,z,z,0.,0.;mode=:dc,source_scale,gmin,temperature,kw...)
        total_iterations+=iterations; converged=ok
        ok||push!(failed_continuation_steps,step)
    end
    stats=Dict{Symbol,Any}(:converged=>converged,:iterations=>total_iterations,:continuation_steps=>length(continuation),:failed_continuation_steps=>failed_continuation_steps,:temperature=>Float64(temperature))
    stats[:warnings]=isempty(failed_continuation_steps) ? String[] : ["one or more continuation stages failed before the final operating point"]
    _finalize_stats!(stats)
    if !converged
        final_residual=residual(cc,z,zero(z),0.;mode=:dc)
        stats[:dominant_residual]=(row=argmax(abs.(final_residual)),norm=norm(final_residual,Inf))
    end
    SimulationResult(cc,OperatingPoint(),[0.],reshape(z,:,1),stats)
end

simulate(c,a::OperatingPoint)=operating_point(c)
