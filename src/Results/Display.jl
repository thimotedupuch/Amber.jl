# Text/plain is shared by the Julia REPL and notebook display systems. Keep
# display bounded and read-only: never solve, reconstruct traces, or compute
# model-validity metrics just to show a result.
# Reports have already computed their findings; displaying one only formats data.
_report_label(key)=uppercasefirst(replace(string(key),'_'=>' '))
function _show_report_fields(io,fields,indent="  ")
    for key in sort!(collect(keys(fields));by=string)
        value=fields[key]
        print(io,'\n',indent,_report_label(key),": ")
        if value isa Union{AbstractDict,NamedTuple}
            _show_report_fields(io,value,indent*"  ")
        else
            if value isa Symbol
                print(io,replace(string(value),'_'=>' '))
            elseif value isa AbstractFloat
                print(io,round(value;sigdigits=6))
            else
                show(IOContext(io,:limit=>true),value)
            end
            unit=key in (:maximum_forward_current,:ripple_current_rms,:collector_current,:base_current) ? " A" :
                key in (:maximum_reverse_voltage,:vbe,:vce) ? " V" : ""
            print(io,unit)
        end
    end
end

function Base.show(io::IO,r::EngineeringReport)
    print(io,r[:analysis]," report")
    stats=get(r,:statistics,nothing)
    if stats!==nothing&&haskey(stats,:converged)
        print(io," — ",get(stats,:partial,false) ? "PARTIAL" : stats[:converged] ? "solver converged" : "solver did not converge")
    end
    for warning in get(r,:warnings,String[])
        print(io,"\n  Warning: ",warning)
    end
    if haskey(r,:interval)&&!isempty(get(r,:axis_unit,""))
        print(io,"\n  Saved range: ",first(r[:interval])," → ",last(r[:interval])," ",get(r,:axis_unit,""),
            " (",r[:samples]," samples)")
    end
    if haskey(r,:device_window)&&!isempty(r[:devices])
        w=r[:device_window]
        label=w.scope===:full_record ? "full saved record" : "selected saved samples"
        print(io,"\n  Device metrics: ",label,"; ",first(w.interval)," → ",last(w.interval)," ",w.axis_unit,
            " (",w.samples," samples)")
        w.axis_unit=="s"&&w.scope===:full_record&&print(io,"; includes startup if present")
        if w.requested!==nothing
            print(io,"\n  Requested window: ",first(w.requested)," → ",last(w.requested)," ",w.axis_unit)
        end
        print(io,"\n  Current RMS: ",w.rms_method===:time_weighted_trapezoidal ? "time weighted (trapezoidal integral of squared current)" : "sample RMS")
    end
    for path in sort!(collect(keys(get(r,:devices,Dict()))))
        print(io,"\n  ",path)
        _show_report_fields(io,r[:devices][path],"    ")
    end
    hidden=(:analysis,:statistics,:devices,:warnings,:interval,:axis_unit,:device_window,:detailed)
    _show_report_fields(io,Dict(k=>v for (k,v) in r if !(k in hidden)&&!(k===:samples&&haskey(r,:interval))))
    if get(r,:detailed,false)&&stats!==nothing
        print(io,"\n  Solver statistics:")
        _show_report_fields(io,stats,"    ")
    elseif stats!==nothing
        summary_keys=(:iterations,:steps,:rejected_steps,:method,:failure_reason)
        _show_report_fields(io,Dict(k=>stats[k] for k in summary_keys if haskey(stats,k)))
    end
end
Base.show(io::IO,::MIME"text/plain",r::EngineeringReport)=show(io,r)

const _InteractiveResult = Union{SimulationResult,NoiseResult}
_result_axis(r::SimulationResult)=r.axis
_result_axis(r::NoiseResult)=r.frequencies
_result_name(r::SimulationResult)=string(nameof(typeof(r.analysis)))
_result_name(::NoiseResult)="Noise"
_result_axis_unit(r::SimulationResult)=r.analysis isa SmallSignal ? "Hz" :
    r.analysis isa Union{Transient,TransientNoise} ? "s" : ""
_result_axis_unit(::NoiseResult)="Hz"

function _result_status(r)
    get(r.stats,:partial,false)&&return "PARTIAL — requested analysis incomplete"
    get(r.stats,:converged,false) ? "solver converged" : "solver did not converge"
end

function Base.show(io::IO,r::_InteractiveResult)
    count=length(_result_axis(r))
    print(io,_result_name(r)," result (",_result_status(r),", ",count,count==1 ? " sample)" : " samples)")
end

function _display_excerpt(message)
    text=replace(string(message),'\n'=>' ')
    length(text)>180 ? first(text,180)*"…" : text
end

function _show_warnings(io,warnings)
    for warning in first(warnings,min(3,length(warnings)))
        print(io,"\n  Warning: ",_display_excerpt(warning))
    end
    length(warnings)>3&&print(io,"\n  … ",length(warnings)-3," more warning(s); inspect result.stats[:warnings].")
end

function Base.show(io::IO,::MIME"text/plain",r::_InteractiveResult)
    show(io,r)
    axis=_result_axis(r); unit=_result_axis_unit(r)
    if !isempty(axis)&&!isempty(unit)
        print(io,"\n  Saved range: ",first(axis)," → ",last(axis)," ",unit)
    end
    if r isa SimulationResult && r.analysis isa Transient && get(r.stats,:partial,false)
        print(io,"\n  Requested stop: ",last(r.analysis.interval)," s; later samples are unavailable.")
    end
    if r isa SimulationResult && r.analysis isa OperatingPoint
        design=r.compiled.design
        shown=0
        for (index,segment) in enumerate(design.root_ir.net_names)
            index==design.root_ir.ground_net&&continue
            shown+=1
            shown>6&&break
            name=_render_segment((_name(design.names,segment.base),segment.index))
            # DC results have one sample; no dynamic trace reconstruction.
            print(io,"\n  ",name," = ",only(voltage(r,name))," V")
        end
        shown>6&&print(io,"\n  … more nodes; inspect result_table(result).")
    end
    _show_warnings(io,get(r.stats,:warnings,String[]))
    if !get(r.stats,:converged,false)
        print(io,"\n  Next: explain_failure(result); inspect result.stats before using values.")
    elseif r isa NoiseResult
        print(io,"\n  Inspect: noise_density(result), integrated_noise(result, low => high), validity_report(result).")
    else
        print(io,"\n  Inspect: voltage(result, :node), result_table(result), report(result).")
    end
end

const _InteractiveStudy = Union{SweepResult,MonteCarloResult}
function Base.show(io::IO,r::_InteractiveStudy)
    print(io,r isa SweepResult ? "Sweep" : "Monte Carlo"," result (",
        count(r.converged)," successful, ",count(!,r.converged)," failed)")
end
function Base.show(io::IO,::MIME"text/plain",r::_InteractiveStudy)
    show(io,r)
    r isa SweepResult&&print(io,"\n  Parameter: ",r.selector)
    if !isempty(r.failures)
        failure=first(r.failures)
        print(io,"\n  First failure: ",_display_excerpt(failure.message))
        print(io,"\n  Inspect result.failures for every failed point; successful(result) excludes failures.")
    else
        print(io,"\n  Inspect: successful(result), report(result).")
    end
end

function Base.show(io::IO,design::CircuitDesign)
    info=summary(design)
    print(io,"CircuitDesign ",info.name," (",info.nets," root nets, ",
        info.instances," instances, ",info.primitive_devices," devices)")
end
function Base.show(io::IO,::MIME"text/plain",design::CircuitDesign)
    show(io,design)
    print(io,"\n  Inspect: describe(circuit), nets(circuit), devices(circuit).")
    print(io,"\n  Validate before simulation: check(circuit).")
end

function Base.show(io::IO,compiled::CompiledCircuit)
    print(io,"CompiledCircuit ",_name(compiled.design.names,compiled.design.name),
        " (",compiled.n," unknowns)")
end
function Base.show(io::IO,::MIME"text/plain",compiled::CompiledCircuit)
    show(io,compiled)
    print(io,"\n  Inspect: describe(compiled.design). Reuse topology with with_parameters(compiled, ...).")
end
