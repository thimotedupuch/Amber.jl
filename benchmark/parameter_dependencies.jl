using Amber, TOML, Statistics
function dependency_benchmark_design(n)
    b=CircuitBuilder(:DependencyBench); g=ground!(b); input=node!(b,:input)
    add!(b,voltage_source(input,g;dc=1.0);name=:Supply)
    dielectric=Polypropylene(loss_tangent=0.02,reference_frequency=1000.0)
    absorption=DebyeBranches(time_constants=[0.01],fractions=[0.1])
    for i in 1:n
        add!(b,capacitor(input,g;value=1e-6,esr=3.0,dielectric,dielectric_absorption=absorption);name=Symbol(:C,i))
    end
    compile(finish(b))
end
function dependency_sample(cc,handle,value)
    with_parameters(cc,handle=>value); Base.GC.gc()
    samples=[@timed with_parameters(cc,handle=>value) for _ in 1:30]
    Dict("median_seconds"=>median(s.time for s in samples),"minimum_seconds"=>minimum(s.time for s in samples),
        "minimum_bytes"=>minimum(s.bytes for s in samples))
end
function dependency_case(n)
    cc=dependency_benchmark_design(n)
    source=parameter_handle(cc,"Supply.dc"); capacitor=parameter_handle(cc,"C1.value")
    Dict("capacitors"=>n,"rules"=>length(cc.parameters.dependency_graph.rules),
        "unrelated_forcing"=>dependency_sample(cc,source,2.0),
        "derived_capacitance"=>dependency_sample(cc,capacitor,2e-6))
end
TOML.print(stdout,Dict("julia_version"=>string(VERSION),"cpu"=>Sys.CPU_NAME,
    "cases"=>[dependency_case(n) for n in (1,16,128)]);sorted=true)
