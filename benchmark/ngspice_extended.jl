# Run: julia --project=Amber benchmark/ngspice_extended.jl
using Amber, TOML
const SPICE = abspath(joinpath(@__DIR__, "../spice_comp/.pixi/envs/default/bin/ngspice"))
function build_case(kind, n)
    b = CircuitBuilder(:ExtendedComparison); g = ground!(b, :gnd)
    x = node_array!(b, :x, 0:n)
    nonlinear = kind != "ac"
    add!(b, voltage_source(x[0], g; dc=nonlinear ? 1.0 : 0.0, ac=1.0,
        waveform=Step(at=0.0)); name=:V)
    deck = "Extended comparison\nV x0 0 DC $(nonlinear ? 1 : 0) AC 1 PULSE(0 1 0 1p 1p 1 2)\n"
    for i in 1:n
        # Independent diode loads avoid attenuation making most ladder diodes inactive.
        input = nonlinear ? x[0] : x[i-1]
        add!(b, resistor(input,x[i];value=1000.0);name=(:R,i))
        add!(b, capacitor(x[i],g;value=1e-9);name=(:C,i))
        deck *= "R$i x$(nonlinear ? 0 : i-1) x$i 1k\nC$i x$i 0 1n\n"
        if nonlinear
            add!(b, diode(x[i],g;model=JunctionDiode(saturation_current=1e-12,ideality=1.0));name=(:D,i))
            deck *= "D$i x$i 0 DM\n"
        end
    end
    deck *= ".model DM D(IS=1e-12 N=1)\n.options tnom=26.85 reltol=1e-6 abstol=1e-12\n.temp 26.85\n"
    return compile(finish(b)), deck
end
function compare_extended(kind,n)
    cc,deck=build_case(kind,n)
    transient_step = parse(Float64,get(ENV,"AMBER_SPICE_STEP","1e-7"))
    solve = kind == "ac" ? (() -> small_signal(cc, 10.0=>1e6;points=501,scale=:linear)) :
        kind == "dc" ? (() -> operating_point(cc)) :
        (() -> transient(cc,0.0=>1e-4; adaptive=false,initial=:discharged,max_step=transient_step,saveat=transient_step,solver=SolverOptions(reltol=1e-6)))
    first=@timed solve(); first.value.stats[:converged] || error("Amber failed")
    samples=[@elapsed solve() for _ in 1:5]
    analysis=kind == "ac" ? ".ac lin 501 10 1meg\n.print ac vr(x1) vi(x1)" :
        kind == "dc" ? ".op" : ".tran $transient_step 100u 0 $transient_step uic\n.print tran v(x1)"
    mktempdir() do dir
        file=joinpath(dir,"case.cir"); write(file,deck*analysis*"\n.end\n")
        cmd=`$SPICE -b $file`; output=read(cmd,String)
        rows=[split(l) for l in split(output,'\n') if occursin(r"^\s*\d+\s+[-+0-9.eE]+\s+[-+0-9.eE]+",l)]
        kind != "dc" && isempty(rows) && error("No ngspice data")
        if kind == "ac"
            length(rows) == size(first.value.values, 2) || error("AC frequency count mismatch")
            spice_frequencies = [parse(Float64,row[2]) for row in rows]
            isapprox(spice_frequencies, first.value.axis; rtol=1e-5) || error("AC frequency grid mismatch")
            spice_values = [complex(parse(Float64,row[3]),parse(Float64,row[4])) for row in rows]
            maximum(abs.(first.value.values[2,:] .- spice_values)) < 1e-5 || error("AC sweep mismatch")
            expected=last(spice_values)
        elseif kind == "dc"
            # .op prints indexed node voltage rows as well as source currents; find x1 explicitly.
            m=match(r"(?m)^\s*x1\s+([-+0-9.eE]+)",output)
            m === nothing && error("Missing DC x1")
            expected=parse(Float64,m[1])
        else
            spice_times = [parse(Float64,row[2]) for row in rows]
            spice_voltages = [parse(Float64,row[3]) for row in rows]
            # Interpolate ngspice's adaptive samples onto Amber's saved grid;
            # compare the complete startup, not just its settled endpoint.
            errors = Float64[]
            for (j,t) in enumerate(first.value.axis)
                t < spice_times[1] && continue
                k = clamp(searchsortedlast(spice_times,t),1,length(spice_times)-1)
                fraction = (t-spice_times[k])/(spice_times[k+1]-spice_times[k])
                value = spice_voltages[k] + fraction*(spice_voltages[k+1]-spice_voltages[k])
                push!(errors,abs(first.value.values[2,j]-value))
            end
            maximum(errors) < 1e-2 || error("Transient trajectory mismatch: $(maximum(errors)) V")
            expected=last(spice_voltages)
        end
        actual=first.value.values[2,end]
        abs(actual-expected)<1e-3 || error("Mismatch $kind $n: $actual vs $expected")
        spice=[@elapsed Base.run(pipeline(cmd;stdout=devnull,stderr=devnull)) for _ in 1:5]
        result=Dict("kind"=>kind,"cells"=>n,"amber_first_seconds"=>first.time,
            "amber_warm_seconds"=>minimum(samples),"ngspice_process_seconds"=>minimum(spice),
            "endpoint_error"=>abs(actual-expected),
            "trajectory_max_error"=>kind == "transient" ? maximum(errors) : 0.0,
            "amber_retained_bytes"=>Base.summarysize(first.value),
            "amber_steps_or_points"=>length(first.value.axis),
            "transient_max_step"=>kind == "transient" ? transient_step : 0.0)
        println(stderr,result)
        return result
    end
end
if abspath(PROGRAM_FILE) == @__FILE__
    cases=[compare_extended(kind,n) for kind in split(get(ENV,"AMBER_SPICE_KINDS","dc,transient,ac"),',') for n in parse.(Int,split(get(ENV,"AMBER_SPICE_CELLS","10,100,1000"),','))]
    TOML.print(stdout,Dict("cases"=>cases,"julia_version"=>string(VERSION));sorted=true)
end
