_signal(result,signal)=signal isa Observable ? _observable(result,signal) : voltage(result,signal)

struct Comparison{T}
    axis::Vector{Float64}
    reference::Vector{T}
    candidate::Vector{T}
    error::Vector{T}
end

function compare(reference::SimulationResult,candidate::SimulationResult;observable)
    reference.axis==candidate.axis||throw(ArgumentError("results must share the same analysis axis"))
    a=_signal(reference,observable); b=_signal(candidate,observable)
    Comparison(reference.axis,a,b,b-a)
end

struct PeakToPeakMetric
    observable::Observable
    window::Union{Nothing,Pair{Float64,Float64}}
end
peak_to_peak(observable;window=nothing)=PeakToPeakMetric(observable,window)
function (metric::PeakToPeakMetric)(result::SimulationResult)
    values=_signal(result,metric.observable)
    indices=metric.window===nothing ? eachindex(values) : findall(t->first(metric.window)<=t<=last(metric.window),result.axis)
    isempty(indices)&&throw(ArgumentError("metric window does not overlap the result"))
    maximum(real.(values[indices]))-minimum(real.(values[indices]))
end

struct PeriodicMetrics
    frequency::Float64
    amplitude::Float64
    thd::Float64
end
function periodic_metrics(result::SimulationResult;signal,window=first(result.axis)=>last(result.axis))
    indices=findall(t->first(window)<=t<=last(window),result.axis); length(indices)>=4||throw(ArgumentError("periodic window is too short"))
    t=result.axis[indices]; y=Float64.(real.(_signal(result,signal)[indices])); y.-=sum(y)/length(y)
    crossings=Float64[]
    for i in 2:length(y)
        if y[i-1]<=0<y[i]
            fraction=-y[i-1]/(y[i]-y[i-1]); push!(crossings,t[i-1]+fraction*(t[i]-t[i-1]))
        end
    end
    frequency=length(crossings)>=2 ? inv(sum(diff(crossings))/length(diff(crossings))) : 0.
    amplitude=(maximum(y)-minimum(y))/2
    if frequency==0
        thd=NaN
    else
        duration=t[end]-t[1]; fundamental=2/length(t)*abs(sum(y.*exp.(-im*2π*frequency.*t)))
        harmonics=sum((2/length(t)*abs(sum(y.*exp.(-im*2π*k*frequency.*t))))^2 for k in 2:5)
        thd=fundamental==0 ? NaN : sqrt(harmonics)/fundamental
    end
    PeriodicMetrics(frequency,amplitude,thd)
end

struct SamplingMetrics
    acquisition_time::Float64
    hold_droop::Float64
    aperture_error::Float64
    charge_injection_step::Float64
end
function sampling_metrics(result::SimulationResult;input,held,clock)
    vin=real.(_signal(result,input)); vhold=real.(_signal(result,held)); clk=real.(_signal(result,clock)); t=result.axis
    threshold=(minimum(clk)+maximum(clk))/2; rises=findall(i->clk[i-1]<threshold<=clk[i],2:length(clk)); falls=findall(i->clk[i-1]>=threshold>clk[i],2:length(clk))
    acquisition=isempty(rises)||isempty(falls) ? NaN : t[first(falls)]-t[first(rises)]
    droops=Float64[]
    for falling in falls
        next_rise=findfirst(rising->rising>falling,rises)
        next_rise===nothing&&continue; ending=rises[next_rise]-1
        ending>falling&&push!(droops,abs(vhold[ending]-vhold[falling]))
    end
    droop=isempty(droops) ? NaN : maximum(droops)
    edge=isempty(falls) ? 1 : first(falls); aperture=abs(vhold[edge]-vin[edge])
    injection=edge>1 ? abs(vhold[edge]-vhold[edge-1]) : 0.
    SamplingMetrics(acquisition,droop,aperture,injection)
end

function _first_crossing(t,y,level)
    for i in 2:length(y)
        if (y[i-1]-level)*(y[i]-level)<=0&&y[i]!=y[i-1]
            f=(level-y[i-1])/(y[i]-y[i-1]); return t[i-1]+f*(t[i]-t[i-1])
        end
    end
    NaN
end
function propagation_delay(result::SimulationResult;input,output)
    a=real.(_signal(result,input)); b=real.(_signal(result,output))
    ta=_first_crossing(result.axis,a,(first(a)+last(a))/2); tb=_first_crossing(result.axis,b,(first(b)+last(b))/2)
    tb-ta
end
function overshoot(result::SimulationResult,signal)
    y=real.(_signal(result,signal)); final=last(y); initial=first(y); step=final-initial
    step==0&&return 0.; step>0 ? (maximum(y)-final)/abs(step) : (final-minimum(y))/abs(step)
end
