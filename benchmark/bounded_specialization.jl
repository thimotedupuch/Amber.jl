# Run each layout in a fresh process: AMBER_BATCH_LAYOUT=bounded|tuple julia --project=. ...
using Amber, TOML, Statistics
struct BenchmarkDiverseLaw{I} end
(::BenchmarkDiverseLaw{I})(v,t) where I = I*1e-6*v[1]
struct BenchmarkDiverseGradient{I} end
(::BenchmarkDiverseGradient{I})(v,t) where I = (I*1e-6,0.0,0.0,0.0)
function diverse_benchmark_design(n)
    b=CircuitBuilder(:DiversityBench); g=ground!(b); input=node!(b,:input)
    add!(b,voltage_source(input,g;dc=1.0);name=:Source)
    for i in 1:n
        output=node!(b,Symbol(:out,i))
        add!(b,resistor(output,g;value=1000.0);name=Symbol(:R,i))
        add!(b,behavioral_current_source(((input,g),),output,g;
            current=BenchmarkDiverseLaw{i}(),gradient=BenchmarkDiverseGradient{i}());name=Symbol(:B,i))
    end
    finish(b)
end
function specialization_case(n,limit)
    built=@timed compile(diverse_benchmark_design(n);specialization_limit=limit)
    cc=built.value; workspace=SimulationWorkspace(cc); x=fill(0.1,cc.n)
    history=Amber._storage(cc,x;workspace)
    first=@timed Amber._step_residual_jacobian!(workspace,cc,x,history,0.0,1e3)
    Amber._step_residual_jacobian!(workspace,cc,x,history,0.0,1e3)
    Base.GC.gc()
    samples=[@timed Amber._step_residual_jacobian!(workspace,cc,x,history,0.0,1e3) for _ in 1:50]
    Dict("distinct_callback_types"=>n,"batches"=>length(cc.parameters.batches),
        "layout"=>string(batch_execution_plan(cc).layout),"compile_seconds"=>built.time,
        "first_evaluation_seconds"=>first.time,"first_evaluation_jit_seconds"=>first.compile_time,
        "warm_minimum_seconds"=>minimum(s.time for s in samples),
        "warm_median_seconds"=>median(s.time for s in samples),
        "warm_minimum_bytes"=>minimum(s.bytes for s in samples))
end
layout=get(ENV,"AMBER_BATCH_LAYOUT","bounded")
layout in ("bounded","tuple") || error("invalid benchmark layout")
limit=layout == "bounded" ? 0 : typemax(Int)
TOML.print(stdout,Dict("julia_version"=>string(VERSION),"cpu"=>Sys.CPU_NAME,
    "layout"=>layout,"sequence"=>"increasing diversity in a fresh process per layout",
    "cases"=>[specialization_case(n,limit) for n in (1,8,40)]);sorted=true)
