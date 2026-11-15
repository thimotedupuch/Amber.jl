# Run: julia --project=. benchmark/ngspice_amber_wins.jl
# Batch analyses in one ngspice process to amortize process startup and parsing.
include("ngspice_extended.jl")
function batch_comparison(kind, n, points, repeats)
    cc, deck = build_case(kind == "ac" ? "ac" : "dc", n)
    solve = kind == "ac" ? (() -> small_signal(cc,10.0=>1e6;points,scale=:linear)) : (() -> operating_point(cc))
    first=@timed solve()
    reference=first.value
    reference.stats[:converged] || error("Amber convergence")
    batch() = for _ in 1:repeats
        r=solve()
        r.stats[:converged] || error("Amber convergence")
    end
    batch() # Warm exact shape and batch loop, before timing.
    amber=minimum([@elapsed batch() for _ in 1:5])
    mktempdir() do dir
        # ngspice saves every node/branch, matching Amber's retention per solve.
        # Destroy each completed plot so both discard results between analyses.
        command=kind == "ac" ? "ac lin $points 10 1meg" : "op"
        path=joinpath(dir,"batch.cir")
        write(path,deck*".control\nset noaskquit\n$command\ndestroy \$curplot\nrepeat $repeats\n$command\ndestroy \$curplot\nend\nquit\n.endc\n.end\n")
        # Verify the full printed frequency response outside the timed batch.
        max_error = 0.0
        if kind == "ac"
            verification=joinpath(dir,"verify.cir")
            write(verification,deck*".ac lin $points 10 1meg\n.print ac vr(x1) vi(x1)\n.end\n")
            response=read(`$SPICE -b $verification`,String)
            rows=[split(l) for l in split(response,'\n') if occursin(r"^\s*\d+\s+[-+0-9.eE]+\s+[-+0-9.eE]+\s+[-+0-9.eE]+",l)]
            length(rows)==points || error("AC verification count mismatch")
            fs=[parse(Float64,r[2]) for r in rows]
            isapprox(fs,reference.axis;rtol=1e-5) || error("Frequency mismatch")
            expected=[complex(parse(Float64,r[3]),parse(Float64,r[4])) for r in rows]
            max_error=maximum(abs.(reference.values[2,:].-expected))
            max_error<1e-5 || error("Full AC response mismatch")
            if n==1
                analytic=1 ./ (1 .+ im*2π.*reference.axis.*1e-6)
                maximum(abs.(reference.values[2,:].-analytic))<1e-12 || error("Analytical RC mismatch")
            end
        end
        cmd=`$SPICE -b $path`
        output=read(cmd,String)
        occursin("Error",output) && error(output)
        length(collect(eachmatch(r"No\. of Data Rows",output))) == repeats+1 || error("ngspice analysis count mismatch")
        spice=minimum([@elapsed Base.run(pipeline(cmd;stdout=devnull,stderr=devnull)) for _ in 1:5])
        # Accuracy independently established using printed response in the other benchmark;
        # also assert analytical first-node DC voltage for identical diode loads.
        kind == "dc" && abs(reference.values[2,1]-0.5168903)>1e-3 && error("DC check")
        result=Dict("kind"=>kind,"cells"=>n,"points"=>points,"repeats"=>repeats,
            "amber_first_seconds"=>first.time,"amber_batch_seconds"=>amber,
            "ngspice_batch_process_seconds"=>spice,"amber_speedup"=>spice/amber,"full_response_max_error"=>max_error)
        println(stderr,result)
        return result
    end
end
sizes=parse.(Int,split(get(ENV,"AMBER_SPICE_CELLS","10,100,1000"),','))
points=parse(Int,get(ENV,"AMBER_SPICE_POINTS","501"))
repeats=parse(Int,get(ENV,"AMBER_SPICE_REPEATS","100"))
cases=[batch_comparison(kind,n,kind == "ac" ? points : 1,repeats) for kind in split(get(ENV,"AMBER_SPICE_KINDS","ac,dc"),',') for n in sizes]
TOML.print(stdout,Dict("cases"=>cases,"julia_version"=>string(VERSION));sorted=true)
