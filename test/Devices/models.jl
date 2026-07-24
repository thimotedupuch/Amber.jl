@testset "device models" begin
    @test compile(RealisticRC()).n>0
    @test JunctionDiode(ideality=1.7).ideality==1.7
    @test Sine(amplitude=2V,frequency=1kHz)(0.25ms)≈2V
    @test 120dB≈1e6
    @test 180°≈π
    practical=PracticalLowPassForElaboration=RealisticRC()
    @test any(x->x.name==Symbol("R1.package_inductance"),practical.components)
    @test any(x->x.name==Symbol("C1.esr"),practical.components)
    rectifier=HalfWaveRectifier()
    @test any(x->x.name==Symbol("D1.series_resistance"),rectifier.components)
    @test count(x->startswith(String(x.name),"C1.da"),rectifier.components)==6
    diode_model=JunctionDiode(junction_capacitance=15pF,transit_time=2ns)
    for diode_voltage in range(-1V,.6V;length=20)
        step=1e-6
        numerical=(charge(diode_model,diode_voltage+step)-charge(diode_model,diode_voltage-step))/(2step)
        @test numerical≈differential_capacitance(diode_model,diode_voltage) rtol=1e-5
    end
    sampler_module=Module(:DeviceElaborationSampler)
    Base.include(sampler_module,normpath(joinpath(@__DIR__,"..","..","examples","06_sample_and_hold","circuit.jl")))
    sampler=getfield(sampler_module,:SampleAndHold)()
    @test any(x->x.name==Symbol("S1.clock_feedthrough"),sampler.components)
    @test any(x->x.name==Symbol("Buffer.input_capacitance"),sampler.components)
    @test count(x->occursin("bias_current",String(x.name)),sampler.components)==2
    practical_inductor=Circuit(:PracticalInductor); inductor_ground=ground!(practical_inductor,:gnd); inductor_node=node!(practical_inductor,:input)
    add!(practical_inductor,voltage_source(inductor_node,inductor_ground;dc=1V);name=:source)
    add!(practical_inductor,inductor(inductor_node,inductor_ground;value=1mH,winding_resistance=2Ω,parallel_capacitance=5pF);name=:L1)
    @test any(x->x.name==Symbol("L1.winding_resistance"),practical_inductor.components)
    @test any(x->x.name==Symbol("L1.parallel_capacitance"),practical_inductor.components)
    amplifier_module=Module(:BJTElaborationAmplifier)
    Base.include(amplifier_module,normpath(joinpath(@__DIR__,"..","..","examples","03_common_emitter","circuit.jl")))
    amplifier=getfield(amplifier_module,:CommonEmitterAmplifier)()
    @test any(x->x.name==Symbol("Q1.base_resistance"),amplifier.components)
    smooth=SmoothSwitch(threshold=1V,transition=.1V,ron=10Ω,roff=1GΩ)
    @test Amber._switch_conductance(smooth,2V)>Amber._switch_conductance(smooth,0V)
    @test Amber._switch_conductance_derivative(smooth,1V)>0
    @test EventSwitch(threshold=2V).threshold==2V
end
