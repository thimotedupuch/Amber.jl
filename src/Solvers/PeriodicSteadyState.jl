Base.@kwdef struct PeriodicSteadyState <: AbstractAnalysis
    period::Float64
    saveat::Float64
    max_step::Union{Nothing,Float64}=nothing
    method::Symbol=:bdf2
    event_mode::Union{Nothing,Symbol}=nothing
    temperature::Float64=300.
end

struct PSSResult
    orbit::SimulationResult
    period::Float64
    residual_norm::Float64
    iterations::Int
    monodromy::Matrix{Float64}
    floquet_multipliers::Vector{ComplexF64}
    stats::Dict{Symbol,Any}
end

floquet_multipliers(result::PSSResult)=result.floquet_multipliers

function _pss_cycle(cc,start,period,state;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters)
    transient(cc,start=>(start+period);initial=state,saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters,adaptive=false)
end

function _period_map_jacobian(cc,start,period,state,endpoint;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters,fd_step)
    count=length(state); jacobian=zeros(Float64,count,count)
    for index in eachindex(state)
        delta=fd_step*max(abs(state[index]),1.); perturbed=copy(state); perturbed[index]+=delta
        cycle=_pss_cycle(cc,start,period,perturbed;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters)
        jacobian[:,index]=(cycle.values[:,end]-endpoint)/delta
    end
    jacobian
end

function periodic_steady_state(c;period,saveat=Float64(period)/200,max_step=nothing,method=:bdf2,event_mode=nothing,
        temperature=300.,initial=nothing,reltol=1e-7,abstol=1e-9,maxiters=12,newton_damping=1.,fd_step=sqrt(eps(Float64)))
    period=Float64(period); period>0&&isfinite(period)||throw(AnalysisValidationError("PSS period must be finite and positive"))
    saveat=Float64(saveat); saveat>0||throw(AnalysisValidationError("PSS saveat must be positive"))
    maxiters>0||throw(AnalysisValidationError("PSS maxiters must be positive")); 0<newton_damping<=1||throw(AnalysisValidationError("PSS Newton damping must lie in (0, 1]"))
    cc=compile(c); state=_initial_transient_state(cc,initial;temperature); cycle=nothing; monodromy=zeros(cc.n,cc.n); residual_norm=Inf
    iteration_count=0; converged=false
    for iteration in 1:maxiters
        iteration_count=iteration
        cycle=_pss_cycle(cc,0.,period,state;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters=120)
        endpoint=cycle.values[:,end]; residual=endpoint-state; residual_norm=norm(residual,Inf)
        scale=max(norm(state,Inf),norm(endpoint,Inf),1.)
        if residual_norm<=abstol+reltol*scale
            monodromy=_period_map_jacobian(cc,0.,period,state,endpoint;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters=120,fd_step)
            converged=true; break
        end
        monodromy=_period_map_jacobian(cc,0.,period,state,endpoint;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters=120,fd_step)
        correction=_solve_linear(monodromy-I,-residual,"PSS shooting Jacobian is singular")
        state .+= newton_damping.*correction
    end
    if !converged
        cycle=_pss_cycle(cc,0.,period,state;saveat,max_step,method,event_mode,temperature,reltol,abstol,maxiters=120)
        residual_norm=norm(cycle.values[:,end]-state,Inf)
    end
    multipliers=ComplexF64.(eigvals(monodromy)); warnings=converged ? String[] : ["PSS shooting did not converge"]
    stats=_finalize_stats!(Dict{Symbol,Any}(:converged=>converged,:iterations=>iteration_count,:residual_norm=>residual_norm,:temperature=>Float64(temperature),:warnings=>warnings);partial=true)
    PSSResult(cycle,period,residual_norm,iteration_count,monodromy,multipliers,stats)
end

provenance(result::PSSResult)=Dict(:amber_version=>v"0.1.0",:topology_fingerprint=>result.orbit.compiled.fingerprint,
    :analysis=>"PeriodicSteadyState",:statistics=>copy(result.stats),:unit_system=>:SI,:warnings=>copy(result.stats[:warnings]))
report(result::PSSResult)=Dict(:analysis=>"PeriodicSteadyState",:period=>result.period,:statistics=>copy(result.stats),:floquet_multipliers=>result.floquet_multipliers)
