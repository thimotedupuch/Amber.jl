function _continuation_step(cc,z,start,target,temperature,depth,maxdepth;kw...)
    source_scale,gmin=target
    candidate,iterations,ok=_newton(cc,z,z,0.,0.;mode=:dc,source_scale,gmin,temperature,kw...)
    ok&&return candidate,iterations,true,0
    depth>=maxdepth&&return z,iterations,false,1

    start_source,start_gmin=start
    midpoint_source=(start_source+source_scale)/2
    midpoint_gmin=if iszero(gmin)
        start_gmin/10
    elseif iszero(start_gmin)
        gmin*10
    else
        sqrt(start_gmin*gmin)
    end
    midpoint=(midpoint_source,midpoint_gmin)
    if midpoint==start||midpoint==target
        return z,iterations,false,1
    end

    middle,middle_iterations,middle_ok,middle_rejections=
        _continuation_step(cc,z,start,midpoint,temperature,depth+1,maxdepth;kw...)
    iterations+=middle_iterations
    middle_ok||return z,iterations,false,1+middle_rejections
    result,final_iterations,final_ok,final_rejections=
        _continuation_step(cc,middle,midpoint,target,temperature,depth+1,maxdepth;kw...)
    result,iterations+final_iterations,final_ok,1+middle_rejections+final_rejections
end

function _pseudo_transient_operating_point(cc,temperature;kw...)
    z=zeros(cc.n)
    _,initial_jacobian=residual_jacobian(cc,z,z,0.,0.;mode=:dc,
        source_scale=1.,temperature)
    node_rows=collect(values(cc.node_index))
    row_norms=zeros(cc.n)
    for column in 1:cc.n, pointer in nzrange(initial_jacobian,column)
        row_norms[initial_jacobian.rowval[pointer]]+=abs(initial_jacobian.nzval[pointer])
    end
    matrix_scale=isempty(node_rows) ? 1e-3 : max(maximum(row_norms[node_rows]),1e-3)
    conductances=matrix_scale.*(1.,.1,.01,.003,.001,.0003,.0001,1e-5,1e-6,0.)
    total_iterations=0
    for conductance in conductances
        forcing=zeros(cc.n)
        for index in node_rows
            forcing[index]=conductance*z[index]
        end
        candidate,iterations,ok=_newton(cc,z,z,0.,0.;mode=:dc,source_scale=1.,
            gmin=conductance,temperature,forcing,kw...)
        total_iterations+=iterations
        ok||return z,total_iterations,false,length(conductances)
        z=candidate
    end
    z,total_iterations,true,length(conductances)
end

function operating_point(c;temperature=300.,continuation_maxdepth=10,kw...)
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("temperature must be finite and positive"))
    continuation_maxdepth>=0||throw(AnalysisValidationError("continuation_maxdepth must be non-negative"))
    cc=compile(c); z=zeros(cc.n); total_iterations=0; converged=false
    failed_continuation_steps=Int[]; rejected_continuation_steps=0
    fallback_trigger=nothing; strategy=:source_gmin
    continuation=((.02,1e-6),(.1,1e-7),(.3,1e-8),(.6,1e-10),(1.,0.))
    accepted=(0.,1e-5)
    for (step,target) in enumerate(continuation)
        candidate,iterations,ok,rejections=
            _continuation_step(cc,z,accepted,target,temperature,0,continuation_maxdepth;kw...)
        total_iterations+=iterations; rejected_continuation_steps+=rejections
        if ok
            z=candidate; accepted=target; converged=target==(1.,0.)
        else
            fallback_trigger=step
            fallback,fallback_iterations,fallback_ok,_=
                _pseudo_transient_operating_point(cc,temperature;kw...)
            total_iterations+=fallback_iterations
            if fallback_ok
                z=fallback; converged=true; strategy=:pseudo_transient
            else
                push!(failed_continuation_steps,step); converged=false
            end
            break
        end
    end
    stats=Dict{Symbol,Any}(:converged=>converged,:iterations=>total_iterations,
        :continuation_steps=>length(continuation),
        :rejected_continuation_steps=>rejected_continuation_steps,
        :failed_continuation_steps=>failed_continuation_steps,:strategy=>strategy,
        :fallback_trigger=>fallback_trigger,:temperature=>Float64(temperature))
    stats[:warnings]=!isempty(failed_continuation_steps) ?
        ["source/gmin continuation and pseudo-transient fallback both failed"] :
        strategy===:pseudo_transient ?
            ["source/gmin continuation failed; pseudo-transient fallback converged"] : String[]
    _finalize_stats!(stats)
    if !converged
        final_residual=residual(cc,z,zero(z),0.;mode=:dc)
        stats[:dominant_residual]=(row=argmax(abs.(final_residual)),norm=norm(final_residual,Inf))
    end
    SimulationResult(cc,OperatingPoint(),[0.],reshape(z,:,1),stats)
end

simulate(c,a::OperatingPoint)=operating_point(c)
