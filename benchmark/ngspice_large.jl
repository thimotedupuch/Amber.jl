# Run: julia --project=. benchmark/ngspice_large.jl
using Amber, TOML
const NGSPICE=abspath(joinpath(@__DIR__,"../spice_comp/.pixi/envs/default/bin/ngspice"))
function large_design(topology,n)
    b=CircuitBuilder(:LargeComparison); g=ground!(b,:gnd); x=node_array!(b,:x,0:n)
    add!(b,voltage_source(x[0],g;dc=1.0,ac=1.0);name=:V)
    io=IOBuffer(); println(io,"Large RC $topology\nV x0 0 DC 1 AC 1")
    for i in 1:n
        previous=topology=="bank" ? 0 : i-1
        add!(b,resistor(x[previous],x[i];value=1000.0);name=(:R,i))
        add!(b,capacitor(x[i],g;value=1e-9);name=(:C,i))
        println(io,"R$i x$previous x$i 1k\nC$i x$i 0 1n")
    end
    return finish(b),String(take!(io))
end
function large_compare(topology,n,kind,points,repeats)
    build=@timed large_design(topology,n)
    compilation=@timed compile(build.value[1]); cc=compilation.value; deck=build.value[2]
    solve=kind=="ac" ? (() -> small_signal(cc,10.0=>1e6;points,scale=:linear)) : (() -> operating_point(cc))
    first=@timed solve(); first.value.stats[:converged] || error("Amber failed")
    function batch()
        for _ in 1:repeats
            r=solve();r.stats[:converged] || error("Amber failed")
        end
    end
    batch()
    samples=[@timed batch() for _ in 1:3]; amber=minimum(s.time for s in samples)
    mktempdir() do dir
        cmdtext=kind=="ac" ? "ac lin $points 10 1meg" : "op"
        path=joinpath(dir,"large.cir")
        write(path,deck*".control\nset noaskquit\nrepeat $repeats\n$cmdtext\ndestroy \$curplot\nend\nquit\n.endc\n.end\n")
        cmd=`$NGSPICE -b $path`; output=read(cmd,String)
        length(collect(eachmatch(r"No\. of Data Rows",output)))==repeats || error("ngspice analysis count")
        spice=minimum([@elapsed Base.run(pipeline(cmd;stdout=devnull,stderr=devnull)) for _ in 1:3])
        # Full first-node frequency response validation outside timing.
        maxerror=0.0
        if kind=="ac"
            check=joinpath(dir,"check.cir");write(check,deck*".ac lin $points 10 1meg\n.print ac vr(x1) vi(x1)\n.end\n")
            printed=read(`$NGSPICE -b $check`,String)
            rows=[split(l) for l in split(printed,'\n') if occursin(r"^\s*\d+\s+[-+0-9.eE]+\s+[-+0-9.eE]+\s+[-+0-9.eE]+",l)]
            length(rows)==points || error("AC samples")
            expected=[complex(parse(Float64,r[3]),parse(Float64,r[4])) for r in rows]
            maxerror=maximum(abs.(first.value.values[2,:].-expected)); maxerror<1e-5 || error("AC mismatch")
            if topology=="bank"
                analytical=1 ./ (1 .+ im*2π.*first.value.axis.*1e-6)
                maximum(abs.(first.value.values[2,:].-analytical))<1e-12 || error("Analytic mismatch")
            end
        else
            maximum(abs.(first.value.values[1:n+1,1].-1))<1e-6 || error("DC mismatch")
            check=joinpath(dir,"check.cir")
            write(check,deck*".control\nop\nprint v(x1) v(x$n)\nquit\n.endc\n.end\n")
            printed=read(`$NGSPICE -b $check`,String)
            voltages=[parse(Float64,m.captures[1]) for m in eachmatch(r"v\(x\d+\)\s*=\s*([-+0-9.eE]+)",printed)]
            length(voltages)==2 || error("ngspice DC verification output")
            maxerror=maximum(abs.(voltages.-1));maxerror<1e-6 || error("ngspice DC mismatch")
        end
        result=Dict("topology"=>topology,"cells"=>n,"primitive_devices"=>2n+1,"unknowns"=>cc.n,
            "kind"=>kind,"points"=>points,"repeats"=>repeats,"amber_warm_batch_seconds"=>amber,
            "ngspice_batch_process_seconds"=>spice,"amber_speedup"=>spice/amber,
            "amber_first_analysis_seconds"=>first.time,"construction_seconds"=>build.time,
            "compilation_seconds"=>compilation.time,"amber_result_retained_bytes"=>Base.summarysize(first.value),
            "amber_batch_allocated_bytes"=>minimum(s.bytes for s in samples),"max_response_error"=>maxerror)
        println(stderr,result); flush(stderr); return result
    end
end
sizes=parse.(Int,split(get(ENV,"AMBER_SPICE_CELLS","10000,50000"),','))
points=parse(Int,get(ENV,"AMBER_SPICE_POINTS","101"));repeats=parse(Int,get(ENV,"AMBER_SPICE_REPEATS","3"))
cases=[large_compare(topology,n,kind,points,repeats) for topology in split(get(ENV,"AMBER_SPICE_TOPOLOGIES","path,bank"),',') for n in sizes for kind in split(get(ENV,"AMBER_SPICE_KINDS","ac,dc"),',')]
TOML.print(stdout,Dict("cases"=>cases,"julia_version"=>string(VERSION),"threads"=>Threads.nthreads());sorted=true)
