function operating_point(c;kw...)
    cc=compile(c); z=zeros(cc.n); total_iterations=0; converged=true
    continuation=((.02,1e-6),(.1,1e-7),(.3,1e-8),(.6,1e-10),(1.,0.))
    for (source_scale,gmin) in continuation
        z,iterations,ok=_newton(cc,z,z,0.,0.;mode=:dc,source_scale,gmin,kw...)
        total_iterations+=iterations; converged&=ok
    end
    stats=Dict{Symbol,Any}(:converged=>converged,:iterations=>total_iterations,:continuation_steps=>length(continuation))
    SimulationResult(cc,OperatingPoint(),[0.],reshape(z,:,1),stats)
end

simulate(c,a::OperatingPoint)=operating_point(c)
