# Run: julia --project=. benchmark/ngspice_cmos.jl
using Amber,TOML
const CMOS_SPICE=abspath(joinpath(@__DIR__,"../spice_comp/.pixi/envs/default/bin/ngspice"))
function cmos_design(n,kind; topology="bank")
    topology in ("bank","chain") || error("unknown CMOS topology")
    b=CircuitBuilder(:CMOSComparison);g=ground!(b,:gnd);s=node!(b,:supply);input=node!(b,:input);out=node_array!(b,:out,1:n)
    dc=kind=="transient" ? 0.0 : 2.5
    waveform=kind=="transient" ? Pulse(low=0.0,high=5.0,frequency=1e7,duty_cycle=.5,rise=1e-9,fall=1e-9,delay=1e-8) : nothing
    add!(b,voltage_source(s,g;dc=5.0);name=:VDD);add!(b,voltage_source(input,g;dc,ac=1.0,waveform);name=:Input)
    nm=Level1MOSFET(threshold_voltage=.7,transconductance=.002,channel_length_modulation=.03)
    pm=Level1MOSFET(threshold_voltage=.7,transconductance=.001,channel_length_modulation=.03)
    io=IOBuffer();println(io,"Matched level1 CMOS bank\nVDD supply 0 5\nVIN input 0 DC $dc AC 1 PULSE(0 5 10n 1n 1n 49n 100n)")
    for i in 1:n
        gate=topology == "chain" && i>1 ? out[i-1] : input
        gate_name=topology == "chain" && i>1 ? "out$(i-1)" : "input"
        add!(b,nmos(out[i],gate,g,g;model=nm);name=(:N,i));add!(b,pmos(out[i],gate,s,s;model=pm);name=(:P,i))
        add!(b,capacitor(out[i],g;value=1e-11);name=(:C,i))
        println(io,"MN$i out$i $gate_name 0 0 NM W=1u L=1u\nMP$i out$i $gate_name supply supply PM W=1u L=1u\nC$i out$i 0 10p")
    end
    # Amber level1 has no body diode or intrinsic Meyer charge. Suppress those in
    # ngspice; use the same explicit 10pF load and zero overlap/body capacitances.
    println(io,".model NM NMOS(LEVEL=1 VTO=.7 KP=.002 LAMBDA=.03 GAMMA=0 TOX=1e6 IS=1e-30)\n.model PM PMOS(LEVEL=1 VTO=-.7 KP=.001 LAMBDA=.03 GAMMA=0 TOX=1e6 IS=1e-30)\n.options TNOM=26.85 RELTOL=1e-6 ABSTOL=1e-12 VNTOL=1e-9 METHOD=GEAR MAXORD=2\n.temp 26.85")
    return finish(b),String(take!(io))
end
function cmos_compare(n,kind,step,repeats; topology="bank")
    stop=parse(Float64,get(ENV,"AMBER_SPICE_STOP","2.1e-7"))
    construction=@timed cmos_design(n,kind;topology);compilation=@timed compile(construction.value[1]);cc=compilation.value;deck=construction.value[2]
    options=SolverOptions(reltol=1e-6,current_abstol=1e-12,voltage_abstol=1e-9)
    # SolverOptions controls Newton convergence. Fixed-step integration has no
    # local truncation-error acceptance test; ngspice RELTOL also controls LTE.
    solve=kind=="dc" ? (() -> operating_point(cc;solver=options)) : kind=="ac" ? (() -> small_signal(cc,1e3=>1e8;points=101,scale=:linear,solver=options)) :
        (() -> transient(cc,0.0=>stop;max_step=step,saveat=step,adaptive=false,event_mode=:exact,solver=options))
    first=@timed solve();first.value.stats[:converged] || error("Amber failed")
    batch()=for _ in 1:repeats
        r=solve();r.stats[:converged] || error("Amber failed")
    end
    batch();samples=[@timed batch() for _ in 1:3];amber=minimum(s.time for s in samples)
    command=kind=="dc" ? "op" : kind=="ac" ? "ac lin 101 1k 100meg" : "tran $step $stop 0 $step"
    mktempdir() do dir
        path=joinpath(dir,"batch.cir");write(path,deck*".control\nrepeat $repeats\n$command\ndestroy \$curplot\nend\nquit\n.endc\n.end\n")
        cmd=`$CMOS_SPICE -b $path`;output=read(cmd,String)
        ngspice_points=[parse(Int,m.captures[1]) for m in eachmatch(r"No\. of Data Rows\s*:\s*(\d+)",output)]
        length(ngspice_points)==repeats || error("ngspice count")
        all(==(ngspice_points[1]),ngspice_points) || error("ngspice repeated analyses have different work counts")
        spice=minimum([@elapsed Base.run(pipeline(cmd;stdout=devnull,stderr=devnull)) for _ in 1:3])
        maxerror=0.0
        for node in unique([1,n])
            check=joinpath(dir,"check$node.cir")
            ac=kind=="ac"
            printline=kind=="dc" ? ".control\nop\nprint v(out$node)\nquit\n.endc" : ".$command\n.print $(ac ? "ac vr(out$node) vi(out$node)" : "tran v(out$node)")"
            write(check,deck*printline*"\n.end\n");printed=read(`$CMOS_SPICE -b $check`,String)
            values=first.value.values[node+2,:]
            if kind=="dc"
                m=match(r"v\(out\d+\)\s*=\s*([-+0-9.eE]+)",printed);m===nothing && error("DC output")
                maxerror=max(maxerror,abs(values[1]-parse(Float64,m[1])))
            else
                rows=[split(l) for l in split(printed,'\n') if occursin(r"^\s*\d+\s+[-+0-9.eE]+\s+[-+0-9.eE]+",l)]
                isempty(rows) && error("No verification rows")
                times=[parse(Float64,r[2]) for r in rows]
                if ac
                    length(rows)==length(values) || error("AC grid count")
                    expected=[complex(parse(Float64,r[3]),parse(Float64,r[4])) for r in rows]
                    maxerror=max(maxerror,maximum(abs.(values.-expected)))
                else
                    expected=[parse(Float64,r[3]) for r in rows];errors=Float64[]
                    for (j,t) in enumerate(first.value.axis)
                        t<times[1] && continue
                        k=clamp(searchsortedlast(times,t),1,length(times)-1)
                        f=(t-times[k])/(times[k+1]-times[k]);v=expected[k]+f*(expected[k+1]-expected[k])
                        push!(errors,abs(values[j]-v))
                    end
                    maxerror=max(maxerror,maximum(errors))
                end
            end
        end
        bank_spread=0.0
        if topology=="bank" && kind=="transient"
            # Identical independent gates must agree throughout the saved trace,
            # not only at the two outputs exported to ngspice verification.
            for j in axes(first.value.values,2), i in 3:n+2
                bank_spread=max(bank_spread,abs(first.value.values[i,j]-first.value.values[3,j]))
            end
            bank_spread<1e-10 || error("Identical bank outputs disagree: $bank_spread V")
        end
        if topology=="chain" && kind=="transient"
            last_values=first.value.values[n+2,:]
            maximum(last_values)>4.0 && minimum(last_values)<1.0 || error("Final chain node did not switch; increase AMBER_SPICE_STOP")
        end
        maxerror<(kind=="transient" ? .05 : 1e-4) || error("CMOS $kind mismatch: $maxerror")
        result=Dict("topology"=>topology,"checked_nodes"=>unique([1,n]),"inverters"=>n,"mosfets"=>2n,"unknowns"=>cc.n,"kind"=>kind,"stop"=>stop,"repeats"=>repeats,"step"=>step,
            "amber_warm_batch_seconds"=>amber,"ngspice_batch_process_seconds"=>spice,"amber_speedup"=>spice/amber,
            "bank_output_max_spread"=>bank_spread,"max_response_error"=>maxerror,"response_error_grid"=>kind=="transient" ? "Amber saved times; ngspice linearly interpolated" : "matching analysis samples",
            "amber_adaptive"=>false,"amber_newton_reltol"=>options.reltol,"ngspice_reltol"=>1e-6,
            "amber_saved_points"=>length(first.value.axis),"ngspice_points_per_analysis"=>ngspice_points[1],
            "amber_accepted_steps"=>kind=="transient" ? length(first.value.stats[:accepted_step_sizes]) : 0,
            "amber_newton_iterations"=>get(first.value.stats,:iterations,0),
            "amber_first_seconds"=>first.time,"construction_seconds"=>construction.time,"compilation_seconds"=>compilation.time,
            "amber_retained_values_bytes"=>sizeof(first.value.values),"amber_batch_allocated_bytes"=>minimum(s.bytes for s in samples))
        println(stderr,result);flush(stderr);return result
    end
end
if abspath(PROGRAM_FILE) == @__FILE__
    sizes=parse.(Int,split(get(ENV,"AMBER_SPICE_CELLS","1,100,1000"),','));step=parse(Float64,get(ENV,"AMBER_SPICE_STEP","6.25e-11"));repeats=parse(Int,get(ENV,"AMBER_SPICE_REPEATS","3"))
    topology=get(ENV,"AMBER_SPICE_TOPOLOGY","bank")
    cases=[cmos_compare(n,kind,step,repeats;topology) for kind in split(get(ENV,"AMBER_SPICE_KINDS","dc,ac,transient"),',') for n in sizes]
    TOML.print(stdout,Dict("cases"=>cases,"julia_version"=>string(VERSION),"threads"=>Threads.nthreads());sorted=true)
end
