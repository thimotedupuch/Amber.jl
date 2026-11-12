# Run with julia --project=. benchmark/constitutive_ir.jl
# Compare equal outputs: I, q, dI/dV, dq/dV, d²q/dV².
using Amber, TOML
function reference(model, inputs)
    v=inputs.voltage; t=inputs.temperature
    i,g=Amber._diode_conduction(model,v,t)
    return (i,charge(model,v;temperature=t),g,
        differential_capacitance(model,v;temperature=t),Amber._capacitance_slope(model,v;temperature=t))
end
function candidate(kernel, second, inputs)
    p=Amber._constitutive_value(kernel,inputs)
    return (p.current,p.charge,p.derivatives.voltage.current,
        p.derivatives.voltage.charge,Amber._equation_value(second,inputs))
end
function sample(f, args...)
    f(args...)
    runs=[@timed f(args...) for _ in 1:100]
    return Dict("minimum_seconds"=>minimum(x.time for x in runs),
        "minimum_bytes"=>minimum(x.bytes for x in runs))
end
function measure(model)
    construction=@timed Amber._constitutive_kernel(Amber._diode_constitutive_ir(model),(:voltage,))
    kernel=construction.value
    second=Amber._equation_derivative(kernel.derivatives.voltage.charge,Val(:voltage))
    inputs=(;voltage=0.4,temperature=300.0,saturation_current=model.saturation_current)
    first_candidate=@timed candidate(kernel,second,inputs)
    first_reference=@timed reference(model,inputs)
    @assert all(isapprox.(first_candidate.value,first_reference.value;rtol=1e-12,atol=1e-25))
    return Dict("construction_seconds"=>construction.time,
        "first_candidate_seconds"=>first_candidate.time,
        "first_candidate_compile_seconds"=>first_candidate.compile_time,
        "first_reference_seconds"=>first_reference.time,
        "first_reference_compile_seconds"=>first_reference.compile_time,
        "candidate"=>sample(candidate,kernel,second,inputs),
        "reference"=>sample(reference,model,inputs))
end
TOML.print(stdout,Dict("julia_version"=>string(VERSION),
    "diode"=>measure(JunctionDiode(junction_capacitance=2e-12,transit_time=1e-9)));sorted=true)
