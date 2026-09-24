@testset "component keyword contract" begin
    # Every primitive constructor must catch misspellings before simulation.
    constructors = (
        () -> resistor(:a, :b; vaule = 1.0),
        () -> capacitor(:a, :b; capacitance = 1.0),
        () -> inductor(:a, :b; initial_current = 1.0),
        () -> conductance(:a, :b; resistance = 1.0),
        () -> voltage_source(:a, :b; amplitude = 1.0),
        () -> current_source(:a, :b; series_resistance = 1.0),
        () -> transconductance(:a, :b, :c, :d; gain = 1.0),
        () -> voltage_controlled_voltage_source(:a, :b, :c, :d; gm = 1.0),
        () -> current_controlled_current_source(:sense, :a, :b; gm = 1.0),
        () -> current_controlled_voltage_source(:sense, :a, :b; gain = 1.0),
        () -> diode(:a, :b; ideality = 2.0),
        () -> npn(:a, :b, :c; forward_beta = 200.0),
        () -> nmos(:a, :b, :c, :d; threshold_voltage = 1.0),
        () -> pmos(:a, :b, :c, :d; threshold_voltage = 1.0),
        () -> opamp(:a, :b, :c, :d, :e; dc_gain = 1.0),
        () -> analog_switch(:a, :b, :c, :d; ron = 1.0),
        () -> behavioral_current_source((), :a, :b; current = (v, t) -> 0.0, gradient = (v, t) -> (0.0, 0.0, 0.0, 0.0), gain = 1.0),
        () -> behavioral_voltage_source((), :a, :b; voltage = (v, t) -> 0.0, gradient = (v, t) -> (0.0, 0.0, 0.0, 0.0), gain = 1.0),
    )
    @test_throws ArgumentError behavioral_current_source(
        (), :a, :b;
        current = (v, t) -> 0.0, gradient = (v, t) -> (0.0, 0.0, 0.0, 0.0), control_count = 3
    )
    for constructor in constructors
        @test_throws ArgumentError constructor()
    end
    function add_invalid(make)
        b = CircuitBuilder(:InvalidKeyword); g = ground!(b, :g); x = node!(b, :x)
        add!(b, make(x, g); name = :dut)
    end
    for make in (
            (x, g) -> resistor(x, g; package = PassivePackage(esr = 1.0)),
            (x, g) -> resistor(x, g; package = PassivePackage(esl = 1.0e-9)),
            (x, g) -> capacitor(x, g; package = PassivePackage(series_inductance = 1.0e-9)),
            (x, g) -> capacitor(x, g; package = PassivePackage(parallel_capacitance = 1.0e-12)),
            (x, g) -> resistor(x, g; material = :ThinFilm),
            (x, g) -> npn(x, x, g; match = :pair),
            (x, g) -> capacitor(x, g; dielectric = :C0G),
            (x, g) -> capacitor(x, g; dielectric_absorption = (fractions = [0.1], time_constants = [0.01])),
            (x, g) -> inductor(x, g; winding_resistance = 1.0, series_resistance = 2.0),
        )
        @test_throws ArgumentError add_invalid(make)
    end
    for invalid in (-1.0, NaN, -Inf)
        @test_throws ArgumentError add_invalid((x, g) -> capacitor(x, g; leakage_resistance = invalid))
        @test_throws ArgumentError add_invalid((x, g) -> inductor(x, g; winding_resistance = invalid))
        @test_throws ArgumentError add_invalid((x, g) -> inductor(x, g; parallel_capacitance = invalid))
        @test_throws ArgumentError add_invalid((x, g) -> resistor(x, g; tolerance = invalid))
        @test_throws ArgumentError JunctionDiode(series_resistance = invalid)
        @test_throws ArgumentError GummelPoonBJT(base_resistance = invalid)
        @test_throws ArgumentError BehavioralOpAmp(input_capacitance = invalid)
        @test_throws ArgumentError VoltageControlledSwitch(clock_feedthrough = invalid)
    end

    # Explicit capacitor overrides remain supported, including zero.
    b = CircuitBuilder(:Override); g = ground!(b, :g); x = node!(b, :x)
    add!(b, voltage_source(x, g; ac = 1.0); name = :supply)
    add!(b, capacitor(x, g; value = 1.0e-6, package = PassivePackage(esr = 10.0, esl = 1.0e-3), esr = 0.0, esl = 0.0); name = :C)
    result = small_signal(finish(b), [1000.0])
    @test -current(result, :supply)[1] ≈ 2π * 1000im * 1.0e-6
end

@testset "elaborated model updates require rebuilding" begin
    b = CircuitBuilder(:ModelUpdates); g = ground!(b, :g); x = node!(b, :x)
    add!(b, voltage_source(x, g; dc = 0.1); name = :supply)
    add!(b, diode(x, g; model = JunctionDiode(series_resistance = 2.0)); name = :D)
    add!(b, npn(x, x, g; model = GummelPoonBJT(base_resistance = 10.0)); name = :Q)
    add!(b, analog_switch(x, g, x, g; model = SmoothSwitch(clock_feedthrough = 1.0e-12)); name = :S)
    out = node!(b, :out)
    add!(b, opamp(x, g, out, x, g; model = BehavioralOpAmp(input_capacitance = 1.0e-12, input_bias_current = 1.0e-9)); name = :A)
    cc = compile(finish(b))
    for (name, model, parameter, value) in (
            ("D", JunctionDiode(series_resistance = 3.0), :series_resistance, 3.0),
            ("Q", GummelPoonBJT(base_resistance = 20.0), :base_resistance, 20.0),
            ("S", SmoothSwitch(clock_feedthrough = 2.0e-12), :clock_feedthrough, 2.0e-12),
            ("A", BehavioralOpAmp(input_capacitance = 2.0e-12, input_bias_current = 1.0e-9), :input_capacitance, 2.0e-12),
            ("A", BehavioralOpAmp(input_capacitance = 1.0e-12, input_bias_current = 2.0e-9), :input_bias_current, 2.0e-9),
        )
        @test_throws TopologyParameterError with_parameters(cc, "$name.$parameter" => value)
        @test_throws TopologyParameterError with_parameters(cc, "$name.model" => model)
    end
    # Numerical model changes still affect the equations, by either update API.
    before = operating_point(cc)
    after = operating_point(with_parameters(cc, "D.ideality" => 2.0))
    replaced = operating_point(with_parameters(cc, "D.model" => JunctionDiode(series_resistance = 2.0, ideality = 2.0)))
    @test abs(current(after, :D)[1]) < abs(current(before, :D)[1])
    @test current(after, :D) ≈ current(replaced, :D)
end

@testset "capacitor updates preserve derived effects" begin
    function capacitor_circuit(; kw...)
        b = CircuitBuilder(:CapacitorUpdate); g = ground!(b, :g); x = node!(b, :x)
        add!(b, voltage_source(x, g; ac = 1.0); name = :supply)
        add!(b, capacitor(x, g; value = 1.0e-6, kw...); name = :C)
        compile(deserialize_circuit(serialize_circuit(finish(b))))
    end
    for cc in (
            capacitor_circuit(dielectric = C0G(loss_tangent = 0.02, reference_frequency = 1000.0)),
            capacitor_circuit(dielectric_absorption = DebyeBranches(time_constants = [0.01], fractions = [0.1])),
        )
        @test_throws TopologyParameterError with_parameters(cc, "C.value" => 2.0e-6)
    end
    cc = capacitor_circuit(dielectric = C0G(), dielectric_absorption = DebyeBranches())
    result = small_signal(with_parameters(cc, "C.value" => 2.0e-6), [1000.0])
    @test -current(result, :supply)[1] ≈ 2π * 1000im * 2.0e-6
end

@testset "current control updates require recompilation" begin
    b = CircuitBuilder(:ControlUpdate); g = ground!(b, :g); x = node!(b, :x); y = node!(b, :y)
    add!(b, voltage_source(x, g; dc = 1.0); name = :supply)
    add!(b, resistor(x, g; value = 1.0); name = :load)
    add!(b, resistor(y, g; value = 1.0); name = :output_load)
    add!(b, current_controlled_current_source(:supply, y, g; gain = 1.0); name = :F)
    @test_throws TopologyParameterError with_parameters(compile(finish(b)), "F.control" => :load)
end
