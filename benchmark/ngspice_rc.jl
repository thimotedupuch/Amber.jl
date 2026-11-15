# Run from the repository root: julia --project=. benchmark/ngspice_rc.jl
using Amber, TOML
@subcircuit SpiceComparisonCell(input, output, reference) begin
    R = resistor(input, output; value = 1e3)
    C = capacitor(output, reference; value = 1e-9)
end
function ladder(n)
    b = CircuitBuilder(:RCLadder)
    g = ground!(b, :gnd); x = node_array!(b, :x, 0:n)
    add!(b, voltage_source(x[0], g; dc=1.0, waveform=Step(at=0.0)); name=:Source)
    instances!(b, SpiceComparisonCell, 1:n; name=i->(:cell,i),
        connections=i->(input=x[i-1],output=x[i],reference=g))
    compile(finish(b))
end
function compare(n, executable)
    build = @timed ladder(n)
    cc = build.value
    solve() = transient(cc, 0.0=>1e-4; adaptive=false, initial=:discharged, saveat=1e-6,max_step=1e-6)
    dcfirst = @timed operating_point(cc)
    dcfirst.value.stats[:converged] || error("Amber DC failed")
    dcwarm = minimum([@elapsed operating_point(cc) for _ in 1:5])
    first = @timed solve()
    first.value.stats[:converged] || error("Amber failed")
    warm = [@elapsed solve() for _ in 1:5]
    mktempdir() do dir
        deck = joinpath(dir,"ladder.cir")
        open(deck,"w") do io
            println(io,"RC ladder\nV1 x0 0 PULSE(0 1 0 1p 1p 1 2)")
            for i in 1:n
                println(io,"R$i x$(i-1) x$i 1k\nC$i x$i 0 1n")
            end
            println(io,".tran 1u 100u 0 1u uic\n.print tran v(x1) v(x$n)\n.end")
        end
        dcdeck = joinpath(dir,"dc.cir")
        write(dcdeck, replace(read(deck,String), ".tran 1u 100u 0 1u uic"=>".op", ".print tran"=>".print dc"))
        dccmd = `$executable -b $dcdeck`
        Base.run(pipeline(dccmd;stdout=devnull,stderr=devnull))
        spicedc = minimum([@elapsed Base.run(pipeline(dccmd;stdout=devnull,stderr=devnull)) for _ in 1:5])
        cmd = `$executable -b $deck`
        Base.run(pipeline(cmd;stdout=devnull,stderr=devnull))
        output = read(cmd, String)
        rows = [split(line) for line in split(output, '\n') if occursin(r"^\s*\d+\s+[-+0-9.eE]+\s+[-+0-9.eE]+\s+[-+0-9.eE]+\s*$", line)]
        isempty(rows) && error("ngspice produced no transient samples")
        spice_first = parse(Float64,last(rows)[3])
        amber_first = first.value.values[2,end]
        abs(amber_first-spice_first) < 1e-3 || error("transient endpoints disagree")
        maximum(abs.(dcfirst.value.values[1:n+1,1] .- 1.0)) < 1e-6 || error("incorrect DC voltage")
        spice = [@elapsed Base.run(pipeline(cmd;stdout=devnull,stderr=devnull)) for _ in 1:5]
        return Dict("cells"=>n,"amber_build_seconds"=>build.time,
            "amber_dc_warm_seconds"=>dcwarm,"ngspice_dc_process_seconds"=>spicedc,
            "amber_first_solve_seconds"=>first.time,"amber_warm_seconds"=>minimum(warm),
            "ngspice_process_seconds"=>minimum(spice),
            "amber_accepted_steps"=>length(first.value.stats[:accepted_step_sizes]),
            "amber_final_first_node"=>amber_first, "ngspice_final_first_node"=>spice_first)
    end
end
exe = abspath(joinpath(@__DIR__,"../spice_comp/.pixi/envs/default/bin/ngspice"))
isfile(exe) || error("Run pixi install --manifest-path spice_comp/pixi.toml first")
cells = parse.(Int,split(get(ENV,"AMBER_SPICE_CELLS","100,1000,10000"),','))
TOML.print(stdout,Dict("cases"=>[compare(n,exe) for n in cells],
    "julia_version"=>string(VERSION),"threads"=>Threads.nthreads());sorted=true)
