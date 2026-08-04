@testset "results" begin
    result=small_signal(HierarchicalFilter(),10Hz=>100kHz;points=10)
    @test abs(voltage(result,:output)[1])>.9
    @test length(current(result,"First.R1"))==10
    @test voltage(result,"First.output")≈voltage(result,:middle)
    @test haskey(provenance(result),:topology_fingerprint)
    transient_result=transient(LowPass(),0s=>200μs;saveat=10μs)
    @test all(isfinite,current(transient_result,:C1))
    @test all(isfinite,power(transient_result,:R1))
    diode_result=transient(HalfWaveRectifier(),0s=>1ms;max_step=100μs)
    @test all(isfinite,current(diode_result,:D1))
    @test all(isfinite,charge(diode_result,:D1))
    sampler_module=Module(:SamplerResultTest)
    Base.include(sampler_module,normpath(joinpath(@__DIR__,"..","..","examples","06_sample_and_hold","circuit.jl")))
    sampler=getfield(sampler_module,:SampleAndHold)()
    sampler_op=operating_point(sampler)
    @test length(state(sampler_op,:Buffer,:dominant_pole))==1
    @circuit NamedObservation() begin
        reference=ground(); output=node(); source=voltage_source(output,reference;dc=3V)
        observe(voltage(output);name=:output)
    end
    named=NamedObservation()
    @test voltage(operating_point(named),:output)[1]≈3V
    rectifier_result=transient(HalfWaveRectifier(),0s=>2ms;max_step=100μs)
    validity=validity_report(rectifier_result)
    @test haskey(validity[:devices],"D1")
    @test haskey(validity[:devices],"C1")
    @test haskey(provenance(rectifier_result),:parameters)
    table=result_table(result)
    @test length(table)==length(result.axis)
    @test hasproperty(first(table),:frequency)
    @test hasproperty(first(table),:output)

    builder=CircuitBuilder(:UnsupportedValue); ground!(builder,:gnd)
    @test_throws MethodError add!(builder,"not a primitive")
end


@testset "result snapshots" begin
    compiled=compile(LowPass()); result=operating_point(compiled); before=current(result,:R1)
    updated=with_parameters(compiled,"R1.value"=>20kΩ)
    @test current(result,:R1)==before
    @test provenance(result)[:parameters]["R1"][:value]!=provenance(operating_point(updated))[:parameters]["R1"][:value]
end
