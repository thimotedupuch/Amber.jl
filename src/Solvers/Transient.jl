function _apply_initial_conditions!(z,cc)
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:capacitor}} || continue
        for device in eachindex(batch.parameters)
            parameters=batch.parameters[device]
            hasproperty(parameters,:initial_voltage)||continue
            a=Int(batch.terminals[1][device]); b=Int(batch.terminals[2][device])
            value=Float64(parameters.initial_voltage)
            if a>0&&b==0; z[a]=value
            elseif a==0&&b>0; z[b]=-value
            elseif a>0&&b>0; z[a]=z[b]+value
            end
        end
    end
    z
end

function transient(c,p::Pair;overrides=nothing,kw...)
    cc=compile(c)
    updates=_override_pairs(overrides)
    updated=isempty(updates) ? cc : with_parameters(cc,(String(first(pair))=>last(pair) for pair in updates)...)
    _transient(updated,p;kw...)
end

function _waveform_events(cc,t0,t1)
    events=Float64[]
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch || continue
        kind=_batch_kind(batch)
        kind in (:voltage_source,:current_source)||continue
        for parameters in batch.parameters
            waveform=get(parameters,:waveform,nothing)
            if waveform isa Step
                push!(events,waveform.at); waveform.rise>0&&push!(events,waveform.at+waveform.rise)
            elseif waveform isa Pulse
                period=inv(waveform.frequency); first_cycle=floor(Int,(t0-waveform.delay)/period)-1; last_cycle=ceil(Int,(t1-waveform.delay)/period)+1
                for cycle in first_cycle:last_cycle
                    start=waveform.delay+cycle*period
                    append!(events,(start,start+waveform.rise,start+waveform.duty_cycle*period,start+waveform.duty_cycle*period+waveform.fall))
                end
            end
        end
    end
    filter!(time->t0<time<t1,events); events
end

function _merge_time_grid(times,nominal_step)
    sorted=sort!(Float64.(times)); merged=Float64[]; tolerance=max(eps(maximum(abs,sorted))*16,nominal_step*1e-10)
    for time in sorted
        if isempty(merged)||time-last(merged)>tolerance
            push!(merged,time)
        end
    end
    merged
end

function _prescribed_node_voltage(cc,node::Integer,t)
    node==0&&return 0.
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:voltage_source}}||continue
        for device in eachindex(batch.parameters)
            positive=Int(batch.terminals[1][device]); negative=Int(batch.terminals[2][device])
            if positive==node&&negative==0
                return _source_value(batch.parameters[device],t,:time)
            elseif positive==0&&negative==node
                return -_source_value(batch.parameters[device],t,:time)
            end
        end
    end
    nothing
end

function _apply_switch_events!(history,cc,previous_time,time)
    applied=false
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:switch}}||continue
        for device in eachindex(batch.parameters)
            model=batch.parameters[device].model; model.charge_injection==0&&continue
            control_positive=Int(batch.terminals[3][device]); control_negative=Int(batch.terminals[4][device])
            positive_before=_prescribed_node_voltage(cc,control_positive,previous_time)
            negative_before=_prescribed_node_voltage(cc,control_negative,previous_time)
            positive_after=_prescribed_node_voltage(cc,control_positive,time)
            negative_after=_prescribed_node_voltage(cc,control_negative,time)
            any(isnothing,(positive_before,negative_before,positive_after,negative_after))&&continue
            before=positive_before-negative_before; after=positive_after-negative_after
            before>=model.threshold>after||continue
            held=Int(batch.terminals[2][device]); held==0&&continue; capacitance=0.
            for candidate in cc.parameters.batches
                candidate isa PrimitiveBatch{Val{:capacitor}}||continue
                for capacitor in eachindex(candidate.parameters)
                    (candidate.terminals[1][capacitor]==held||candidate.terminals[2][capacitor]==held)&&
                        (capacitance+=Float64(candidate.parameters[capacitor].value))
                end
            end
            capacitance>0||continue
            history[held]+=model.charge_injection/capacitance; applied=true
        end
    end
    applied
end

function _initial_transient_state(cc,initial;temperature=300.,workspace=nothing,solver=SolverOptions())
    if initial===:discharged
        z=zeros(cc.n)
    elseif initial isa AbstractVector
        length(initial)==cc.n||throw(DimensionMismatch("initial state does not match the compiled circuit"))
        all(isfinite,initial)||throw(ArgumentError("initial state must be finite"))
        z=Float64.(initial)
    else
        result=_require_converged(operating_point(cc;temperature,workspace,solver),"transient operating point")
        z=copy(result.values[:,1])
    end
    _apply_initial_conditions!(z,cc)
end

function _mandatory_times(cc,t0,t1,saveat,event_mode)
    times=Float64[t1]
    if saveat!==nothing
        append!(times,collect((t0+saveat):saveat:t1))
    end
    event_mode===:exact&&append!(times,_waveform_events(cc,t0,t1))
    _merge_time_grid(filter(time->t0<time<=t1,times),something(saveat,(t1-t0)/100))
end

function _error_norm(high,low,previous,cc,reltol,abstol)
    indices=cc.hierarchical_topology === nothing ?
        sort!(vcat(collect(values(cc.node_index)),collect(values(cc.states)))) :
        findall(!=(BranchCurrentUnknown),cc.hierarchical_topology.layout.kinds)
    isempty(indices)&&return 0.
    maximum(abs(high[index]-low[index])/(abstol+reltol*max(abs(high[index]),abs(previous[index]),1e-12)) for index in indices)
end

function _transient_adaptive(cc,t0,t1;saveat,max_step,method,reltol,abstol,maxiters,
        initial,event_mode,temperature,workspace,line_search_minimum,voltage_abstol,
        state_abstol,linear_solver,solver)
    z=_initial_transient_state(cc,initial;temperature,workspace,solver); times=Float64[t0]; states=Vector{Vector{Float64}}([copy(z)])
    mandatory=_mandatory_times(cc,t0,t1,saveat,event_mode); mandatory_index=1
    span=t1-t0; maximum_step=something(max_step,saveat,span/10); dt=min(maximum_step,span/100)
    minimum_step=max(eps(max(abs(t0),abs(t1),1.))*32,span*1e-12)
    total_iterations=0; rejected=0; failed_steps=Int[]; failed_residuals=Any[]; tolerance_failed_steps=Int[]
    while last(times)<t1
        time=last(times)
        while mandatory_index<=length(mandatory)&&mandatory[mandatory_index]<=time+minimum_step; mandatory_index+=1 end
        boundary=mandatory_index<=length(mandatory) ? mandatory[mandatory_index] : t1
        next_time=min(time+dt,boundary,t1); h=next_time-time; previous=copy(z)
        event_history=copy(previous); event_applied=event_mode===:exact&&_apply_switch_events!(event_history,cc,time,next_time)
        use_bdf2=method===:bdf2&&length(states)>=2&&!event_applied
        if use_bdf2
            previous_h=times[end]-times[end-1]; ratio=h/previous_h; α=(1+2ratio)/((1+ratio)*h)
            history=((1+ratio) .* previous ./ h .- ratio^2 .* states[end-1] ./ ((1+ratio)*h)) ./ α
            high,iterations,good=_newton(cc,z,history,next_time,α;reltol,abstol,maxiters,temperature,workspace,line_search_minimum,voltage_abstol,state_abstol,linear_solver)
            low,low_iterations,low_good=_newton(cc,z,event_history,next_time,inv(h);reltol,abstol,maxiters,temperature,workspace,line_search_minimum,voltage_abstol,state_abstol,linear_solver)
            iterations+=low_iterations; good&=low_good; error=_error_norm(high,low,previous,cc,reltol,abstol); candidate=high
        else
            full,iterations,good=_newton(cc,z,event_history,next_time,inv(h);reltol,abstol,maxiters,temperature,workspace,line_search_minimum,voltage_abstol,state_abstol,linear_solver)
            midpoint=time+h/2
            half,half_iterations,half_good=_newton(cc,z,previous,midpoint,2/h;reltol,abstol,maxiters,temperature,workspace,line_search_minimum,voltage_abstol,state_abstol,linear_solver)
            second_history=copy(half); event_mode===:exact&&_apply_switch_events!(second_history,cc,midpoint,next_time)
            refined,second_iterations,second_good=_newton(cc,half,second_history,next_time,2/h;reltol,abstol,maxiters,temperature,workspace,line_search_minimum,voltage_abstol,state_abstol,linear_solver)
            iterations+=half_iterations+second_iterations; good&=half_good&second_good
            error=_error_norm(refined,full,previous,cc,reltol,abstol); candidate=refined
        end
        total_iterations+=iterations
        if good&&error<=1
            z=candidate; push!(times,next_time); push!(states,copy(z))
            factor=error==0 ? 2. : clamp(.9*error^(-1/2),.25,2.)
            dt=min(maximum_step,max(minimum_step,h*factor))
        else
            rejected+=1; dt=max(minimum_step,h*max(.1,min(.5,.9*max(error,1e-12)^(-1/2))))
            if h<=minimum_step
                z=candidate; push!(times,next_time); push!(states,copy(z)); push!(failed_steps,length(times))
                derivative=workspace === nothing ? inv(h).*(z.-event_history) : workspace.derivative
                if workspace !== nothing
                    @inbounds @simd for index in eachindex(derivative)
                        derivative[index]=inv(h)*(z[index]-event_history[index])
                    end
                end
                final_residual=_solver_residual(cc,workspace,z,derivative,next_time;temperature)
                push!(failed_residuals,(row=argmax(abs.(final_residual)),norm=norm(final_residual,Inf)))
                error>1&&push!(tolerance_failed_steps,length(times))
            end
        end
    end
    values_matrix=hcat(states...)
    if saveat!==nothing
        requested=_merge_time_grid(vcat(t0,collect((t0+saveat):saveat:t1),t1),saveat)
        indices=[findmin(abs.(times.-time))[2] for time in requested]
        times=times[indices]; values_matrix=values_matrix[:,indices]
    end
    analysis=Transient(t0=>t1;saveat,max_step,method,adaptive=true,temperature,solver)
    stats=Dict{Symbol,Any}(:converged=>isempty(failed_steps),:iterations=>total_iterations,:failed_steps=>failed_steps,:failed_residuals=>failed_residuals,:tolerance_failed_steps=>tolerance_failed_steps,:rejected_steps=>rejected,:temperature=>Float64(temperature))
    stats[:warnings]=isempty(failed_steps) ? String[] : ["one or more minimum-size steps were accepted without satisfying convergence or error tolerances"]
    _finalize_stats!(stats;partial=true)
    SimulationResult(cc,analysis,times,values_matrix,stats)
end

function _transient(c,p::Pair;saveat=nothing,max_step=nothing,method=:bdf2,adaptive=nothing,
        reltol=nothing,abstol=nothing,maxiters=nothing,initial=nothing,event_mode=nothing,
        temperature=300.,solver=SolverOptions())
    voltage_abstol = something(abstol, solver.voltage_abstol)
    state_abstol = something(abstol, solver.state_abstol)
    reltol,abstol,maxiters,_ = _solver_values(solver;reltol,abstol,maxiters)
    _validate_transient(p;saveat,max_step,method,event_mode,reltol,abstol,maxiters)
    cc=compile(c); t0,t1=Float64(first(p)),Float64(last(p))
    workspace=cc.parameters === nothing ? nothing : SimulationWorkspace(cc)
    use_adaptive=adaptive===nothing ? saveat===nothing&&max_step===nothing : Bool(adaptive)
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("temperature must be finite and positive"))
    use_adaptive&&return _transient_adaptive(cc,t0,t1;saveat,max_step,method,reltol,abstol,
        maxiters,initial,event_mode,temperature,workspace,
        line_search_minimum=solver.line_search_minimum,voltage_abstol,state_abstol,
        linear_solver=solver.linear_solver,solver)
    dt=something(saveat,max_step,(t1-t0)/1000); max_step!==nothing&&(dt=min(dt,max_step))
    ts=_merge_time_grid(vcat(t0,collect((t0+dt):dt:t1),t1),dt)
    event_mode===:exact&&(ts=_merge_time_grid(vcat(ts,_waveform_events(cc,t0,t1)),dt))
    nt=length(ts); vals=zeros(cc.n,nt)
    z=_initial_transient_state(cc,initial;temperature,workspace,solver)
    vals[:,1]=z; total=0; ok=true; failed_steps=Int[]; failed_residuals=Any[]
    for j in 2:nt
        h=ts[j]-ts[j-1]; prev=copy(z)
        event_history=copy(prev); event_applied=event_mode===:exact&&_apply_switch_events!(event_history,cc,ts[j-1],ts[j])
        if method===:bdf2&&j>2&&!event_applied
            previous_h=ts[j-1]-ts[j-2]; ratio=h/previous_h
            α=(1+2ratio)/((1+ratio)*h)
            history=((1+ratio) .* prev ./ h .- ratio^2 .* vals[:,j-2] ./ ((1+ratio)*h)) ./ α
        else
            α=inv(h); history=event_history
        end
        z,it,good=_newton(cc,z,history,ts[j],α;reltol,abstol,maxiters,temperature,workspace,
            line_search_minimum=solver.line_search_minimum,voltage_abstol,state_abstol,
            linear_solver=solver.linear_solver)
        vals[:,j]=z; total+=it; ok&=good
        if !good
            push!(failed_steps,j)
            derivative=workspace === nothing ? α.*(z.-history) : workspace.derivative
            if workspace !== nothing
                @inbounds @simd for index in eachindex(derivative)
                    derivative[index]=α*(z[index]-history[index])
                end
            end
            final_residual=_solver_residual(cc,workspace,z,derivative,ts[j];temperature)
            push!(failed_residuals,(row=argmax(abs.(final_residual)),norm=norm(final_residual,Inf)))
        end
    end
    analysis=Transient(Float64(t0)=>Float64(t1);saveat,max_step,method,adaptive=false,temperature,solver)
    stats=Dict{Symbol,Any}(:converged=>ok,:iterations=>total,:failed_steps=>failed_steps,:failed_residuals=>failed_residuals,:temperature=>Float64(temperature),
        :warnings=>isempty(failed_steps) ? String[] : ["one or more fixed-grid steps did not converge"])
    _finalize_stats!(stats;partial=true)
    SimulationResult(cc,analysis,ts,vals,stats)
end

simulate(c,a::Transient)=transient(c,a.interval;saveat=a.saveat,max_step=a.max_step,
    method=a.method,adaptive=a.adaptive,temperature=a.temperature,overrides=a.overrides,solver=a.solver)
