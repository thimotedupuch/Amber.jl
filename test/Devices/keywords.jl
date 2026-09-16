@testset "component keyword contract" begin
    # Every primitive constructor must catch misspellings before simulation.
    constructors=(
        ()->resistor(:a,:b;vaule=1.),
        ()->capacitor(:a,:b;capacitance=1.),
        ()->inductor(:a,:b;initial_current=1.),
        ()->conductance(:a,:b;resistance=1.),
        ()->voltage_source(:a,:b;amplitude=1.),
        ()->current_source(:a,:b;series_resistance=1.),
        ()->transconductance(:a,:b,:c,:d;gain=1.),
        ()->voltage_controlled_voltage_source(:a,:b,:c,:d;gm=1.),
        ()->current_controlled_current_source(:sense,:a,:b;gm=1.),
        ()->current_controlled_voltage_source(:sense,:a,:b;gain=1.),
        ()->diode(:a,:b;ideality=2.),
        ()->npn(:a,:b,:c;forward_beta=200.),
        ()->nmos(:a,:b,:c,:d;threshold_voltage=1.),
        ()->pmos(:a,:b,:c,:d;threshold_voltage=1.),
        ()->opamp(:a,:b,:c,:d,:e;dc_gain=1.),
        ()->analog_switch(:a,:b,:c,:d;ron=1.),
        ()->behavioral_current_source((),:a,:b;current=(v,t)->0.,gradient=(v,t)->(0.,0.,0.,0.),gain=1.),
        ()->behavioral_voltage_source((),:a,:b;voltage=(v,t)->0.,gradient=(v,t)->(0.,0.,0.,0.),gain=1.),
    )
    @test_throws ArgumentError behavioral_current_source((),:a,:b;
        current=(v,t)->0.,gradient=(v,t)->(0.,0.,0.,0.),control_count=3)
    for constructor in constructors
        @test_throws ArgumentError constructor()
    end
    function add_invalid(make)
        b=CircuitBuilder(:InvalidKeyword); g=ground!(b,:g); x=node!(b,:x)
        add!(b,make(x,g);name=:dut)
    end
    for make in (
        (x,g)->resistor(x,g;package=PassivePackage(esr=1.)),
        (x,g)->resistor(x,g;package=PassivePackage(esl=1e-9)),
        (x,g)->capacitor(x,g;package=PassivePackage(series_inductance=1e-9)),
        (x,g)->capacitor(x,g;package=PassivePackage(parallel_capacitance=1e-12)),
        (x,g)->resistor(x,g;material=:ThinFilm),
        (x,g)->npn(x,x,g;match=:pair),
        (x,g)->capacitor(x,g;dielectric=:C0G),
        (x,g)->capacitor(x,g;dielectric_absorption=(fractions=[.1],time_constants=[.01])),
        (x,g)->inductor(x,g;winding_resistance=1.,series_resistance=2.),
    )
        @test_throws ArgumentError add_invalid(make)
    end
    for invalid in (-1.,NaN,-Inf)
        @test_throws ArgumentError add_invalid((x,g)->capacitor(x,g;leakage_resistance=invalid))
        @test_throws ArgumentError add_invalid((x,g)->inductor(x,g;winding_resistance=invalid))
        @test_throws ArgumentError add_invalid((x,g)->inductor(x,g;parallel_capacitance=invalid))
        @test_throws ArgumentError add_invalid((x,g)->resistor(x,g;tolerance=invalid))
        @test_throws ArgumentError JunctionDiode(series_resistance=invalid)
        @test_throws ArgumentError GummelPoonBJT(base_resistance=invalid)
        @test_throws ArgumentError BehavioralOpAmp(input_capacitance=invalid)
        @test_throws ArgumentError VoltageControlledSwitch(clock_feedthrough=invalid)
    end

    # Explicit capacitor overrides remain supported, including zero.
    b=CircuitBuilder(:Override); g=ground!(b,:g); x=node!(b,:x)
    add!(b,voltage_source(x,g;ac=1.);name=:supply)
    add!(b,capacitor(x,g;value=1e-6,package=PassivePackage(esr=10.,esl=1e-3),esr=0.,esl=0.);name=:C)
    result=small_signal(finish(b),[1000.])
    @test -current(result,:supply)[1]≈2π*1000im*1e-6
end

@testset "elaborated model updates require rebuilding" begin
    b=CircuitBuilder(:ModelUpdates); g=ground!(b,:g); x=node!(b,:x)
    add!(b,voltage_source(x,g;dc=.1);name=:supply)
    add!(b,diode(x,g;model=JunctionDiode(series_resistance=2.));name=:D)
    add!(b,npn(x,x,g;model=GummelPoonBJT(base_resistance=10.));name=:Q)
    add!(b,analog_switch(x,g,x,g;model=SmoothSwitch(clock_feedthrough=1e-12));name=:S)
    out=node!(b,:out)
    add!(b,opamp(x,g,out,x,g;model=BehavioralOpAmp(input_capacitance=1e-12,input_bias_current=1e-9));name=:A)
    cc=compile(finish(b))
    for (name,model,parameter,value) in (
        ("D",JunctionDiode(series_resistance=3.),:series_resistance,3.),
        ("Q",GummelPoonBJT(base_resistance=20.),:base_resistance,20.),
        ("S",SmoothSwitch(clock_feedthrough=2e-12),:clock_feedthrough,2e-12),
        ("A",BehavioralOpAmp(input_capacitance=2e-12,input_bias_current=1e-9),:input_capacitance,2e-12),
        ("A",BehavioralOpAmp(input_capacitance=1e-12,input_bias_current=2e-9),:input_bias_current,2e-9),
    )
        @test_throws TopologyParameterError with_parameters(cc,"$name.$parameter"=>value)
        @test_throws TopologyParameterError with_parameters(cc,"$name.model"=>model)
    end
    # Numerical model changes still affect the equations, by either update API.
    before=operating_point(cc)
    after=operating_point(with_parameters(cc,"D.ideality"=>2.))
    replaced=operating_point(with_parameters(cc,"D.model"=>JunctionDiode(series_resistance=2.,ideality=2.)))
    @test abs(current(after,:D)[1])<abs(current(before,:D)[1])
    @test current(after,:D)≈current(replaced,:D)
end

@testset "capacitor updates preserve derived effects" begin
    function capacitor_circuit(;kw...)
        b=CircuitBuilder(:CapacitorUpdate); g=ground!(b,:g); x=node!(b,:x)
        add!(b,voltage_source(x,g;ac=1.);name=:supply)
        add!(b,capacitor(x,g;value=1e-6,kw...);name=:C)
        compile(deserialize_circuit(serialize_circuit(finish(b))))
    end
    for cc in (
        capacitor_circuit(dielectric=C0G(loss_tangent=.02,reference_frequency=1000.)),
        capacitor_circuit(dielectric_absorption=DebyeBranches(time_constants=[.01],fractions=[.1])),
    )
        @test_throws TopologyParameterError with_parameters(cc,"C.value"=>2e-6)
    end
    cc=capacitor_circuit(dielectric=C0G(),dielectric_absorption=DebyeBranches())
    result=small_signal(with_parameters(cc,"C.value"=>2e-6),[1000.])
    @test -current(result,:supply)[1]≈2π*1000im*2e-6
end

@testset "current control updates require recompilation" begin
    b=CircuitBuilder(:ControlUpdate); g=ground!(b,:g); x=node!(b,:x); y=node!(b,:y)
    add!(b,voltage_source(x,g;dc=1.);name=:supply)
    add!(b,resistor(x,g;value=1.);name=:load)
    add!(b,resistor(y,g;value=1.);name=:output_load)
    add!(b,current_controlled_current_source(:supply,y,g;gain=1.);name=:F)
    @test_throws TopologyParameterError with_parameters(compile(finish(b)),"F.control"=>:load)
end
