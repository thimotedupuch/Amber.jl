# Runs on both the current tree and the pre-cache baseline (copy this driver).
using Amber, TOML, Statistics
@subcircuit TemplateBenchCell(input,output,reference;R=1000.0,C=1e-9) begin
    R1=resistor(input,output;value=R)
    C1=capacitor(output,reference;value=C)
end
function template_bench_design(n)
    b=CircuitBuilder(:TemplateBench); g=ground!(b); nodes=node_array!(b,:x,0:n)
    add!(b,voltage_source(nodes[0],g;dc=1.0);name=:Source)
    instances!(b,TemplateBenchCell,1:n;name=i->(:stage,i),
        connections=i->(input=nodes[i-1],output=nodes[i],reference=g))
    finish(b)
end
function sample_compile(f,design)
    f(design)
    Base.GC.gc() # separate allocation debt from the previous strategy/sample group
    samples=[@timed f(design) for _ in 1:20]
    Dict("minimum_seconds"=>minimum(x.time for x in samples),
        "median_seconds"=>median(x.time for x in samples),
        "minimum_bytes"=>minimum(x.bytes for x in samples),
        "sample_seconds"=>[x.time for x in samples])
end
function template_bench_case(n)
    design=template_bench_design(n)
    case=Dict{String,Any}("instances"=>n,"default"=>sample_compile(compile,design))
    if isdefined(Amber,:SymbolicCompilationCache)
        cache=SymbolicCompilationCache()
        case["persistent_cache"]=sample_compile(d->compile(d;symbolic_cache=cache),design)
        case["builds"]=symbolic_cache_stats(cache).builds
        case["hits"]=symbolic_cache_stats(cache).hits
    end
    return case
end
TOML.print(stdout,Dict("julia_version"=>string(VERSION),"cpu"=>Sys.CPU_NAME,
    "threads"=>Threads.nthreads(),"samples"=>20,"label"=>get(ENV,"AMBER_BENCH_LABEL","current"),
    "cases"=>[template_bench_case(n) for n in (1,16,128,512)]);sorted=true)
