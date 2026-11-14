using Amber, TOML, Statistics
function reference(model,input)
    i,g=Amber._diode_conduction(model,input.voltage,input.temperature)
    return (i,charge(model,input.voltage;temperature=input.temperature),g,
        differential_capacitance(model,input.voltage;temperature=input.temperature),
        Amber._capacitance_slope(model,input.voltage;temperature=input.temperature))
end
function tree_value(kernel,second,input)
    p=Amber._constitutive_value(kernel,input)
    return (p.current,p.charge,p.derivatives.voltage.current,p.derivatives.voltage.charge,
        Amber._equation_value(second,input))
end
program_all(out,workspace,program,input)=evaluate_constitutive!(out,workspace,program,input)
program_values(out,workspace,program,input)=evaluate_constitutive!(out,workspace,program,input;outputs=1:2)
function program_sample(f,args...)
    f(args...); Base.GC.gc()
    samples=[@timed f(args...) for _ in 1:100]
    Dict("minimum_seconds"=>minimum(s.time for s in samples),"median_seconds"=>median(s.time for s in samples),
        "minimum_bytes"=>minimum(s.bytes for s in samples))
end
function program_measure()
    model=JunctionDiode(junction_capacitance=2e-12,transit_time=1e-9)
    law=Amber._diode_constitutive_ir(model)
    kernel=Amber._constitutive_kernel(law,(:voltage,)); second=Amber._equation_derivative(kernel.derivatives.voltage.charge,Val(:voltage))
    requests=[ConstitutiveRequest(:current),ConstitutiveRequest(:charge),ConstitutiveRequest(:current,(:voltage,)),
        ConstitutiveRequest(:charge,(:voltage,)),ConstitutiveRequest(:charge,(:voltage,:voltage))]
    build=@timed compile_constitutive(law;requests); program=build.value; workspace=ConstitutiveWorkspace(program)
    input=(;voltage=0.4,temperature=300.0,saturation_current=model.saturation_current)
    numeric=Float64[getproperty(input,name) for name in program.input_names]; out=zeros(5); values=zeros(2)
    @assert isapprox(program_all(out,workspace,program,numeric),collect(reference(model,input));rtol=1e-12,atol=1e-25)
    all_nodes=workspace.evaluated_nodes
    program_values(values,workspace,program,numeric); value_nodes=workspace.evaluated_nodes
    Dict("nodes"=>length(program.instructions),"all_evaluated_nodes"=>all_nodes,"values_evaluated_nodes"=>value_nodes,
        "construction_seconds"=>build.time,"construction_jit_seconds"=>build.compile_time,
        "handwritten"=>program_sample(reference,model,input),"tree"=>program_sample(tree_value,kernel,second,input),
        "program_all"=>program_sample(program_all,out,workspace,program,numeric),
        "program_values"=>program_sample(program_values,values,workspace,program,numeric))
end
TOML.print(stdout,Dict("julia_version"=>string(VERSION),"cpu"=>Sys.CPU_NAME,"diode"=>program_measure());sorted=true)
