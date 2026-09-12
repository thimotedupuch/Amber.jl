"""Sampled inverter characteristic and extracted unity-gain noise margins."""
struct InverterView <: AbstractDisplayView
    input::Vector{Float64}
    output::Vector{Float64}
    gain::Vector{Float64}
    measurements::NamedTuple
    warnings::Vector{String}
    source::Any
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
    inverterview(vin, vout)
    inverterview(sweep; output)

Extract VIL/VIH at dVout/dVin = -1 and VM at Vout = Vin using linear
interpolation. VOH = Vout(VIL), VOL = Vout(VIH), NML = VIL - VOL,
NMH = VOH - VIH. A complete, monotone characteristic with exactly two
unity-gain crossings is required for margins; otherwise they are NaN.
Monotonicity allows adjacent increases up to `monotonic_atol=1e-9` volts
for solver roundoff. Refine the DC grid to check convergence of these sampled measurements.
"""
function inverterview(vin,vout;source=nothing,monotonic_atol=1e-9)
    isfinite(monotonic_atol) && monotonic_atol>=0 || throw(ArgumentError("monotonic_atol must be finite and nonnegative"))
    x=_cmos_grid(vin); y=Float64.(collect(vout))
    length(x)==length(y) || throw(ArgumentError("input/output lengths differ"))
    gain=_finite_derivative(x,y)
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
    InverterView(x,y,gain,m,warnings,source)
end
function inverterview(s::Amber.SweepResult;output,kwargs...)
    y=[s.converged[i] ? Float64(real(only(Amber.voltage(s.simulations[i],output)))) : NaN for i in eachindex(s.parameter_values)]
    inverterview(s.parameter_values,y;source=s,kwargs...)
end

"""Plot inverter transfer, unity-gain boundaries, noise margins, and differential gain."""
function inverterplot(position,v::InverterView;axis=(;))
    slot=_position(position); grid=Makie.GridLayout(slot)
    ax=Makie.Axis(grid[1,1];merge((xlabel="Input (V)",ylabel="Output (V)"),axis)...)
    curve=Makie.lines!(ax,v.input,v.output)
    Makie.lines!(ax,v.input,v.input;color=:gray,linestyle=:dash)
    m=v.measurements
    if isfinite(m.vil)
        Makie.vlines!(ax,[m.vil,m.vih];color=:gray,linestyle=:dot)
        Makie.scatter!(ax,[m.vil,m.vih],[m.voh,m.vol])
    end
    label=isfinite(m.nml) ? "NML = $(engineering(m.nml;unit="V"))   NMH = $(engineering(m.nmh;unit="V"))" : first(v.warnings)
    Makie.Label(grid[0,1],label;tellwidth=false)
    gx=Makie.Axis(grid[2,1];xlabel="Input (V)",ylabel="dVout / dVin")
    gp=Makie.lines!(gx,v.input,v.gain); Makie.hlines!(gx,[-1.];linestyle=:dash,color=:gray)
    Makie.linkxaxes!(ax,gx)
    PlotHandle(slot,(transfer=ax,gain=gx),(transfer=curve,gain=gp),v)
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
function switchingmetrics(r::Amber.SimulationResult;input,output,supply,vdd,window)
    get(r.stats,:converged,true) || throw(ArgumentError("transient did not converge"))
    switchingmetrics(r.axis,real.(Amber.voltage(r,input)),real.(Amber.voltage(r,output)),
        -real.(Amber.power(r,supply));vdd,window)
end

"""Load × supply study with retained per-point measurements and failures."""
struct SwitchingView <: AbstractDisplayView
    loads::Vector{Float64}
    supplies::Vector{Float64}
    points::Matrix{Any}
    failures::Vector{NamedTuple}
end
"""
    switchingview(measure; loads, supplies)

Call `measure(load, supply)` for each grid point. Return `switchingmetrics`
(or a NamedTuple with tphl, tplh, energy and optional result). Exceptions are
retained in `failures` and plotted as gaps. Coordinates use farads and volts.
"""
function switchingview(measure;loads,supplies)
    l=_cmos_grid(loads); s=_cmos_grid(supplies)
    all(>(0),l) && all(>(0),s) || throw(ArgumentError("loads and supplies must be positive"))
    points=Matrix{Any}(undef,length(l),length(s)); failures=NamedTuple[]
    for i in eachindex(l),j in eachindex(s)
        try
            p=measure(l[i],s[j])
            all(k->getproperty(p,k) isa Real,(:tphl,:tplh,:energy)) || throw(ArgumentError("measurements must be real"))
            points[i,j]=p
        catch e
            e isa InterruptException && rethrow()
            points[i,j]=nothing
            push!(failures,(load=l[i],supply=s[j],message=sprint(showerror,e)))
        end
    end
    SwitchingView(l,s,points,failures)
end
"""Plot tPHL, tPLH and total supply energy versus load, with one curve per supply."""
function switchingplot(position,v::SwitchingView)
    slot=_position(position); grid=Makie.GridLayout(slot); axes=Makie.Axis[]; plots=Any[]
    for (i,(key,label)) in enumerate(((:tphl,"tPHL (s)"),(:tplh,"tPLH (s)"),(:energy,"Supply energy / window (J)")))
        ax=Makie.Axis(grid[1,i];xlabel="Load (F)",ylabel=label,xtickformat=_engineering_ticks,ytickformat=_engineering_ticks)
        push!(axes,ax)
        for j in eachindex(v.supplies)
            y=[p===nothing ? NaN : getproperty(p,key) for p in v.points[:,j]]
            push!(plots,Makie.scatterlines!(ax,v.loads,y;label=engineering(v.supplies[j];unit="V")))
        end
    end
    Makie.Legend(grid[0,:],first(axes);orientation=:horizontal,tellwidth=false)
    incomplete=count(p->p===nothing || !all(isfinite(getproperty(p,k)) for k in (:tphl,:tplh,:energy)),v.points)
    Makie.Label(grid[2,:],"$(length(v.points)-incomplete)/$(length(v.points)) complete points · energy includes leakage";tellwidth=false)
    PlotHandle(slot,(tphl=axes[1],tplh=axes[2],energy=axes[3]),(curves=plots,),v)
end

"""Conditioned offset or mismatch samples, including failed samples and provenance."""
struct MismatchView <: AbstractDisplayView
    groups::Vector{NamedTuple}
    quantity::String
    unit::String
end
"""
    mismatchview(groups; quantity="Input offset", unit="V")

Each group provides temperature (K), width/length (m), and `samples` (real,
missing or nothing), or `result` (Amber MonteCarloResult). Optional fields,
including seeds and simulation results, are retained in `source`. Groups must
have unique temperature/geometry. No statistical device assumptions are imposed.
"""
function mismatchview(groups;quantity="Input offset",unit="V")
    output=NamedTuple[]; seen=Set()
    for g in groups
        condition=(Float64(g.temperature),Float64(g.width),Float64(g.length))
        all(x->isfinite(x)&&x>0,condition) || throw(ArgumentError("temperature and geometry must be positive"))
        condition in seen && throw(ArgumentError("duplicate temperature/geometry group")); push!(seen,condition)
        raw=hasproperty(g,:samples) ? collect(g.samples) : [g.result.converged[i] ? g.result.values[i] : nothing for i in eachindex(g.result.values)]
        values=Float64[x for x in raw if x isa Real && isfinite(x)]
        n=length(values); mean=n==0 ? NaN : sum(values)/n
        std=n<2 ? NaN : sqrt(sum((values.-mean).^2)/(n-1))
        push!(output,(temperature=condition[1],width=condition[2],length=condition[3],
            samples=raw,values=values,mean=mean,std=std,failed=length(raw)-n,source=g))
    end
    isempty(output) && throw(ArgumentError("at least one group required"))
    MismatchView(output,String(quantity),String(unit))
end
"""Plot per-condition empirical CDFs and mean ± sample standard deviation; show valid/total counts."""
function mismatchplot(position,v::MismatchView)
    slot=_position(position); grid=Makie.GridLayout(slot)
    labels=["$(g.temperature) K, W/L=$(engineering(g.width;unit="m"))/$(engineering(g.length;unit="m"))  n=$(length(g.values))/$(length(g.samples))" for g in v.groups]
    ax=Makie.Axis(grid[1,1];xlabel=v.quantity*" ("*v.unit*")",ylabel="Empirical CDF",xtickformat=_engineering_ticks)
    sx=Makie.Axis(grid[2,1];xlabel="Condition",ylabel="Mean ± σ ("*v.unit*")",xticks=(1:length(labels),string.(1:length(labels))),ytickformat=_engineering_ticks)
    curves=Any[]
    for (i,g) in enumerate(v.groups)
        if !isempty(g.values)
            ys=sort(g.values); n=length(ys)
            # Repeated x coordinates make the empirical CDF's jumps explicit.
            push!(curves,Makie.lines!(ax,repeat(ys;inner=2),collect(Iterators.flatten(((j-1)/n,j/n) for j in 1:n));label="$i: "*labels[i]))
        else
            push!(curves,Makie.lines!(ax,[NaN],[NaN];label="$i: "*labels[i]))
        end
    end
    means=[g.mean for g in v.groups]; deviations=[g.std for g in v.groups]
    Makie.errorbars!(sx,1:length(labels),means,deviations)
    dots=Makie.scatter!(sx,1:length(labels),means)
    Makie.Legend(grid[1:2,2],ax;tellheight=false)
    PlotHandle(slot,(distribution=ax,summary=sx),(curves=curves,means=dots),v)
end
