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
function _require_timing_result(result)
    result.analysis isa Union{Transient,TransientNoise} ||
        throw(ArgumentError("timing measurements require a transient result"))
    get(result.stats,:converged,false) ||
        throw(ArgumentError("transient did not converge; inspect explain_failure(result)"))
end

"""
    propagation_delay(result; input, output, threshold=nothing,
        input_threshold=threshold, output_threshold=threshold,
        input_edge=:auto, output_edge=:auto, occurrence=1, window=nothing)
    propagation_delay(t, vin, vout; kwargs...)

Measure one input-to-output delay in seconds using linearly interpolated
crossings. Thresholds default to each waveform's midrange (min + max)/2.
For periodic signals specify `input_edge=:rising` or `:falling` and
`output_edge=:rising` or `:falling`; `occurrence` selects the input edge in
the window. With `:auto`, multiple crossings are rejected as ambiguous.
The output must cross exactly once, in the requested direction, after the
selected input and before the next input edge or window end. Missing edges
or output recrossings return `NaN`. Nonconverged results are rejected.
Use [`switchingmetrics`](@ref) for mean inverter delays and energy per window.
"""
function propagation_delay(t,vin,vout;threshold=nothing,input_threshold=threshold,
        output_threshold=threshold,input_edge=:auto,output_edge=:auto,
        occurrence::Integer=1,window=nothing)
    x=_cmos_grid(t); a,b=Float64.(vin),Float64.(vout)
    length(a)==length(b)==length(x) || throw(ArgumentError("waveform lengths differ"))
    all(isfinite,a)&&all(isfinite,b) || throw(ArgumentError("waveforms must be finite"))
    occurrence>0 || throw(ArgumentError("occurrence must be positive"))
    all(e->e in (:auto,:rising,:falling),(input_edge,output_edge)) ||
        throw(ArgumentError("edge direction must be :auto, :rising or :falling"))
    lo,hi=window===nothing ? (first(x),last(x)) : (Float64(first(window)),Float64(last(window)))
    first(x)<=lo<hi<=last(x) || throw(ArgumentError("window must lie within the trace"))
    ta=input_threshold===nothing ? (minimum(a)+maximum(a))/2 : Float64(input_threshold)
    tb=output_threshold===nothing ? (minimum(b)+maximum(b))/2 : Float64(output_threshold)
    isfinite(ta)&&isfinite(tb) || throw(ArgumentError("thresholds must be finite"))
    direction(e)=e===:rising ? 1 : e===:falling ? -1 : 0
    all_inputs=_cmos_crossings(x,a,ta)
    inputs=filter(q->lo<=q<hi,_cmos_crossings(x,a,ta;direction=direction(input_edge)))
    all_outputs=_cmos_crossings(x,b,tb)
    if (input_edge===:auto && length(inputs)>1) ||
            (output_edge===:auto && count(q->lo<=q<=hi,all_outputs)>1)
        throw(ArgumentError("multiple crossings: specify input_edge/output_edge and a window or occurrence"))
    end
    length(inputs)>=occurrence || return NaN
    start=inputs[occurrence]
    next_input=findfirst(>(start),all_inputs)
    stop=next_input===nothing ? hi : min(hi,all_inputs[next_input])
    # A crossing at the record/window end is usable, but one coincident with
    # the next input belongs to an ambiguous response and is not paired.
    in_interval(q)=start<=q && (q<stop || (q==hi && (next_input===nothing || all_inputs[next_input]>hi)))
    hits=filter(in_interval,_cmos_crossings(x,b,tb;direction=direction(output_edge)))
    length(hits)==1 && count(in_interval,all_outputs)==1 ? only(hits)-start : NaN
end
function propagation_delay(result::SimulationResult;input,output,kwargs...)
    _require_timing_result(result)
    propagation_delay(result.axis,real.(_signal(result,input)),real.(_signal(result,output));kwargs...)
end
function overshoot(result::SimulationResult,signal)
    y=real.(_signal(result,signal)); final=last(y); initial=first(y); step=final-initial
    step==0&&return 0.; step>0 ? (maximum(y)-final)/abs(step) : (final-minimum(y))/abs(step)
end

function _cmos_derivative(x, y)
    length(x) == length(y) || throw(DimensionMismatch("transfer axes differ in length"))
    length(x) >= 2 || throw(ArgumentError("derivative requires at least two points"))
    all(>(0), diff(x)) || throw(ArgumentError("transfer input values must be unique"))
    derivative = similar(y)
    derivative[1] = (y[2] - y[1]) / (x[2] - x[1])
    derivative[end] = (y[end] - y[end - 1]) / (x[end] - x[end - 1])
    for index in 2:length(x)-1
        left = x[index] - x[index - 1]; right = x[index + 1] - x[index]
        derivative[index] = -right / (left * (left + right)) * y[index - 1] +
            (right - left) / (left * right) * y[index] +
            left / (right * (left + right)) * y[index + 1]
    end
    derivative
end

function _cmos_grid(x)
    a=Float64.(collect(x))
    length(a)>=2 && all(isfinite,a) && all(>(0),diff(a)) ||
        throw(ArgumentError("axis needs at least two finite, strictly increasing samples"))
    a
end
function _cmos_crossings(x,y,level;direction=0)
    hits=Float64[]
    for i in 2:length(x)
        a,b=y[i-1],y[i]
        isfinite(a) && isfinite(b) || continue
        rising=a<level<=b; falling=a>level>=b
        ((direction>=0 && rising) || (direction<=0 && falling)) || continue
        push!(hits,x[i-1]+(level-a)*(x[i]-x[i-1])/(b-a))
    end
    hits
end
function _cmos_interp(x,y,t)
    i=clamp(searchsortedlast(x,t),1,length(x)-1)
    y[i]+(y[i+1]-y[i])*(t-x[i])/(x[i+1]-x[i])
end

"""
    invertermetrics(vin, vout; monotonic_atol=1e-9)
    invertermetrics(sweep; output, monotonic_atol=1e-9)

Return a named tuple with `input`, `output`, differential `gain`,
`measurements`, `warnings`, and the source sweep (or `nothing` for raw data).
Extract VIL/VIH at dVout/dVin = -1 and VM at Vout = Vin using linear
interpolation. VOH = Vout(VIL), VOL = Vout(VIH), NML = VIL - VOL,
NMH = VOH - VIH. A complete, monotone characteristic with exactly two
unity-gain crossings is required for margins; otherwise they are NaN.
Monotonicity allows adjacent increases up to `monotonic_atol=1e-9` volts
for solver roundoff. Refine the DC grid to check convergence of these sampled measurements.
"""
function invertermetrics(vin,vout;source=nothing,monotonic_atol=1e-9)
    isfinite(monotonic_atol) && monotonic_atol>=0 || throw(ArgumentError("monotonic_atol must be finite and nonnegative"))
    x=_cmos_grid(vin); y=Float64.(collect(vout))
    length(x)==length(y) || throw(ArgumentError("input/output lengths differ"))
    gain=_cmos_derivative(x,y)
    crossings=_cmos_crossings(x,gain,-1.)
    switches=_cmos_crossings(x,y.-x,0.)
    valid=all(isfinite,y) && all(<=(monotonic_atol),diff(y)) && length(crossings)==2 &&
        first(gain)>-1 && last(gain)>-1
    vil,vih=valid ? crossings : (NaN,NaN)
    voh=valid ? _cmos_interp(x,y,vil) : NaN
    vol=valid ? _cmos_interp(x,y,vih) : NaN
    vm=all(isfinite,y) && length(switches)==1 ? only(switches) : NaN
    m=(vil=vil,vih=vih,voh=voh,vol=vol,nml=vil-vol,nmh=voh-vih,vm=vm)
    warnings=valid ? String[] : ["Noise margins unavailable: require a complete monotone transfer with two unity-gain crossings and low-gain endpoints."]
    (input=x,output=y,gain=gain,measurements=m,warnings=warnings,source=source)
end
function invertermetrics(s::SweepResult;output,kwargs...)
    y=[s.converged[i] ? Float64(real(only(voltage(s.simulations[i],output)))) : NaN for i in eachindex(s.parameter_values)]
    invertermetrics(s.parameter_values,y;source=s,kwargs...)
end

"""
    switchingmetrics(result; input, output, supply, vdd, window)
    switchingmetrics(t, vin, vout, delivered_power; vdd, window)

Average inverter tPHL/tPLH over input edges in the explicit window, measured
at VDD/2. Each edge must have exactly one opposite output crossing and no recrossing before
the next input edge or window end; otherwise that delay is NaN. Energy is
the trapezoidal integral of delivered supply power over the entire window,
including leakage. The result overload negates Amber's absorbed supply power.
Use a settled full cycle for energy/cycle. All time and energy units are SI.
The result overload rejects nonconverged or non-transient results. Refine
the timestep and compare both delays and energy before claiming accuracy.
"""
function switchingmetrics(t,vin,vout,p;vdd,window)
    x=_cmos_grid(t); a,b,p=Float64.(vin),Float64.(vout),Float64.(p)
    all(length(z)==length(x) for z in (a,b,p)) || throw(ArgumentError("waveform lengths differ"))
    all(z->all(isfinite,z),(a,b,p)) || throw(ArgumentError("waveforms must be finite"))
    isfinite(vdd) && vdd>0 || throw(ArgumentError("vdd must be positive"))
    lo,hi=Float64(first(window)),Float64(last(window))
    first(x)<=lo<hi<=last(x) || throw(ArgumentError("window must lie within the trace"))
    rises=_cmos_crossings(x,a,vdd/2;direction=1)
    falls=_cmos_crossings(x,a,vdd/2;direction=-1)
    edges=sort(vcat([(t,1) for t in rises],[(t,-1) for t in falls]))
    outup=_cmos_crossings(x,b,vdd/2;direction=1)
    outdown=_cmos_crossings(x,b,vdd/2;direction=-1)
    phl=Float64[]; plh=Float64[]
    for (i,(edge,dir)) in enumerate(edges)
        lo<=edge<hi || continue
        stop=i<length(edges) ? min(hi,edges[i+1][1]) : hi
        hits=filter(q->edge<=q<stop,dir==1 ? outdown : outup)
        count_all=count(q->edge<=q<stop,outup)+count(q->edge<=q<stop,outdown)
        push!(dir==1 ? phl : plh,length(hits)==1 && count_all==1 ? only(hits)-edge : NaN)
    end
    tx=vcat(lo,x[lo.<x.<hi],hi); py=[_cmos_interp(x,p,q) for q in tx]
    energy=sum(diff(tx).*(py[1:end-1].+py[2:end])./2)
    avg(z)=isempty(z) ? NaN : sum(z)/length(z)
    (tphl=avg(phl),tplh=avg(plh),energy=energy,phl=phl,plh=plh,window=(lo,hi))
end
function switchingmetrics(r::SimulationResult;input,output,supply,vdd,window)
    _require_timing_result(r)
    switchingmetrics(r.axis,real.(_signal(r,input)),real.(_signal(r,output)),
        -real.(power(r,supply));vdd,window)
end
