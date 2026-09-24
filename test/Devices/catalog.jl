@subcircuit CatalogueTemplate(input, output, reference) begin
    T = ideal_transformer(input, reference, output, reference; ratio = 2.0)
    varistor(output, reference)
end

@testset "expanded device catalogue" begin
    # All constructors must compile, solve and survive a persistence round trip.
    constructors = (
        (:zener, (x, g) -> zener(x, g), -0.1),
        (:schottky, (x, g) -> schottky(x, g), 0.1),
        (:led, (x, g) -> led(x, g), 0.1),
        (:photodiode, (x, g) -> photodiode(x, g; photocurrent = 1.0e-3), -0.1),
        (:solar_cell, (x, g) -> solar_cell(x, g; photocurrent = 0.01), 0.1),
        (:varistor, (x, g) -> varistor(x, g; vref = 1.0), 0.5),
        (:thermistor, (x, g) -> thermistor(x, g), 0.5),
        (:njfet, (x, g) -> njfet(x, g, g), 1.0),
        (:pjfet, (x, g) -> pjfet(x, g, g), -1.0),
        (:vcr, (x, g) -> voltage_controlled_resistor(x, g, x, g), 0.5),
        (:crystal, (x, g) -> crystal(x, g), 0.5),
    )
    for (label, constructor, bias) in constructors
        @testset "$label persistence and DC" begin
            b = CircuitBuilder(label); g = ground!(b, :gnd); x = node!(b, :x)
            add!(b, voltage_source(x, g; dc = bias); name = :supply)
            add!(b, constructor(x, g); name = :dut)
            design = finish(b); restored = deserialize_circuit(serialize_circuit(design))
            @test serialize_circuit(restored) == serialize_circuit(design)
            result = operating_point(restored)
            @test result.stats[:converged]
            @test voltage(result, :x)[1] ≈ bias
        end
    end

    @circuit CatalogSignals begin
        g = ground(); x = node(); y = node(); product = node(); limited = node(); decision = node()
        voltage_source(x, g; dc = 0.2, ac = 1.0); voltage_source(y, g; dc = 3.0)
        analog_multiplier(x, g, y, g, product, g; gain = 2.0)
        voltage_limiter(x, g, limited, g; low = -2.0, high = 2.0, gain = 3.0)
        comparator(x, g, decision, g)
        resistor(product, g; value = 1.0e3); resistor(limited, g; value = 1.0e3); resistor(decision, g; value = 1.0e3)
    end
    design = deserialize_circuit(serialize_circuit(CatalogSignals()))
    op = operating_point(design)
    @test voltage(op, :product)[1] ≈ 1.2
    @test voltage(op, :limited)[1] ≈ 2tanh(0.3)
    @test voltage(op, :decision)[1] ≈ 5.0
    ac = small_signal(design, [100.0])
    @test voltage(ac, :product)[1] ≈ 6.0
    @test voltage(ac, :limited)[1] ≈ 3 / cosh(0.3)^2

    @circuit CatalogTransformer begin
        g = ground(); p = node(); s = node(); w = node()
        supply = voltage_source(p, g; dc = 10.0)
        T = ideal_transformer(p, g, s, g; ratio = 2.0)
        potentiometer(s, w, g; resistance = 100.0, position = 0.25)
    end
    op = operating_point(deserialize_circuit(serialize_circuit(CatalogTransformer())))
    @test voltage(op, :s)[1] ≈ 5.0
    @test voltage(op, :w)[1] ≈ 1.25
    @test current(op, :supply)[1] ≈ -0.025

    @circuit CatalogLine begin
        g = ground(); input = node(); output = node()
        voltage_source(input, g; dc = 1.0, ac = 1.0, waveform = Step(high = 1.0, at = 1.0e-7))
        transmission_line(input, output, g; resistance = 10.0, inductance = 1.0e-6, capacitance = 1.0e-9, sections = 4)
        resistor(output, g; value = 100.0)
    end
    line = deserialize_circuit(serialize_circuit(CatalogLine()))
    @test voltage(operating_point(line), :output)[1] ≈ 100 / 110
    @test abs(voltage(small_signal(line, [1.0]), :output)[1]) ≈ 100 / 110 rtol = 1.0e-6
    tr = transient(line, 0.0 => 2.0e-6; max_step = 1.0e-8)
    @test tr.stats[:converged]
    @test voltage(tr, :output)[end] ≈ 100 / 110 rtol = 0.01

    for bias in (-5.0, 5.0)
        b = CircuitBuilder(:Bridge); g = ground!(b, :gnd); x = node!(b, :x); p = node!(b, :p); n = node!(b, :n)
        add!(b, voltage_source(x, g; dc = bias))
        add!(b, bridge_rectifier(x, g, p, n); name = :bridge)
        add!(b, resistor(p, n; value = 1.0e3))
        op = operating_point(deserialize_circuit(serialize_circuit(finish(b))))
        @test 3.0 < voltage(op, :p)[1] - voltage(op, :n)[1] < 4.0
    end

    # Independent constitutive checks, including source/drain and polarity reversal.
    for polarity in (-1.0, 1.0)
        law = Amber.CatalogLaw(:jfet, (0.001, -2.0, 0.0, polarity))
        @test law((polarity * 3.0, 0.0, 0.0, 0.0), 0.0) ≈ polarity * 0.001
        @test law((polarity * 1.0, 0.0, 0.0, 0.0), 0.0) ≈ polarity * 0.00075
        @test law((polarity * 3.0, polarity * (-3.0), 0.0, 0.0), 0.0) == 0.0
        @test law((-polarity * 3.0, -polarity * 3.0, 0.0, 0.0), 0.0) ≈ -polarity * 0.001
    end
    laws = (
        Amber.CatalogLaw(:multiplier, (2.0, 0.1)), Amber.CatalogLaw(:limiter, (-2.0, 3.0, 4.0, 0.1)),
        Amber.CatalogLaw(:vcr, (1.0, 100.0, 0.2, 0.4)), Amber.CatalogLaw(:varistor, (2.0, 0.01, 3.0)),
        Amber.CatalogLaw(:jfet, (0.001, -2.0, 0.02, 1.0)), Amber.CatalogLaw(:jfet, (0.001, -2.0, 0.02, -1.0)),
    )
    for law in laws, x in (-4.0, -0.3, 0.3, 4.0), y in (-3.0, -0.2, 2.0)
        v = (x, y, 0.0, 0.0); analytic = Amber.CatalogGradient(law)(v, 0.0)
        for j in 1:4
            h = 1.0e-6
            plus = ntuple(i -> v[i] + (i == j ? h : 0.0), 4)
            minus = ntuple(i -> v[i] - (i == j ? h : 0.0), 4)
            numerical = (law(plus, 0.0) - law(minus, 0.0)) / (2h)
            @test analytic[j] ≈ numerical atol = 1.0e-8 rtol = 1.0e-5
        end
    end
    @test_throws ArgumentError zener(:a, :b; breakdown_voltage = -1.0)
    @test_throws ArgumentError thermistor(:a, :b; temperature = 0.0)
    @test_throws ArgumentError potentiometer(:a, :w, :b; position = 1.0)
    @test_throws ArgumentError ideal_transformer(:a, :b, :c, :d; ratio = 0.0)
    @test_throws ArgumentError transmission_line(:a, :b, :g; sections = 0)
    @test_throws ArgumentError njfet(:d, :g, :s; pinch_off = 1.0)
    @test_throws ArgumentError voltage_limiter(:a, :b, :c, :d; low = 1.0, high = 0.0)
    @test_throws ArgumentError varistor(:a, :b; exponent = 0.5)
end

@testset "catalogue physical references and assembly" begin
    @circuit CrystalReference begin
        g = ground(); x = node()
        supply = voltage_source(x, g; ac = 1.0)
        crystal(
            x, g; motional_resistance = 20.0, motional_inductance = 0.01,
            motional_capacitance = 1.0e-10, shunt_capacitance = 5.0e-12
        )
    end
    fs = [1.0e4, 1 / (2π * sqrt(0.01 * 1.0e-10)), 1.0e6]
    ac = small_signal(CrystalReference(), fs)
    for (i, f) in enumerate(fs)
        ω = 2π * f
        expected = im * ω * 5.0e-12 + inv(20 + im * ω * 0.01 + inv(im * ω * 1.0e-10))
        # AC extracts the small capacitance matrix by subtracting Jacobians.
        @test -current(ac, :supply)[i] ≈ expected rtol = 1.0e-6
    end
    @circuit PhotoReference begin
        g = ground(); x = node()
        supply = voltage_source(x, g; dc = 0.0)
        photodiode(x, g; photocurrent = 2.0e-3)
        thermistor(x, g; rnom = 1.0e4, temperature = 298.15)
    end
    @test current(operating_point(PhotoReference()), :supply)[1] ≈ 2.0e-3
    # Series resistance must carry photocurrent as well as junction current.
    # With negligible junction conduction, the short-circuit current is set by
    # the photocurrent divider between series and shunt resistances.
    @circuit SolarSeriesReference begin
        g = ground(); x = node()
        supply = voltage_source(x, g; dc = 0.0)
        solar_cell(
            x, g; photocurrent = 1.0e-3, shunt_resistance = 100.0,
            model = JunctionDiode(saturation_current = 1.0e-30, series_resistance = 100.0)
        )
    end
    solar = deserialize_circuit(serialize_circuit(SolarSeriesReference()))
    @test current(operating_point(solar), :supply)[1] ≈ 0.5e-3 rtol = 1.0e-6
    @test thermistor(:a, :b; rnom = 1.0e4, temperature = 298.15).parameters.value ≈ 1.0e4
    @test thermistor(:a, :b; rnom = 1.0e4, temperature = 320.0).parameters.value < 1.0e4
    @test Amber.CatalogLaw(:varistor, (100.0, 0.001, 10.0))((100.0, 0.0, 0.0, 0.0), 0.0) ≈ 0.001

    @circuit CatalogJacobian begin
        g = ground(); x = node(); y = node(); out = node()
        voltage_source(x, g; dc = 0.4); voltage_source(y, g; dc = -0.2)
        voltage_controlled_resistor(x, g, y, g; rmin = 10.0, rmax = 1.0e3)
        njfet(x, y, g)
        varistor(x, g; vref = 1.0, exponent = 3.0)
        analog_multiplier(x, g, y, g, out, g)
        resistor(out, g; value = 100.0)
    end
    compiled = compile(CatalogJacobian()); point = operating_point(compiled).values[:, 1]
    _, analytic = Amber.residual_jacobian(compiled, point, point, 0.0, 0.0)
    numerical = Amber._jacobian(z -> Amber.residual(compiled, z, zeros(length(z)), 0.0), point)
    @test Matrix(analytic) ≈ numerical atol = 1.0e-7 rtol = 1.0e-5

    b = CircuitBuilder(:CatalogueHierarchy); g = ground!(b, :g); x = node!(b, :x); y = node!(b, :y)
    add!(b, voltage_source(x, g; dc = 2.0))
    instance!(b, CatalogueTemplate; instance_name = :stage, connections = (input = x, output = y, reference = g))
    add!(b, resistor(y, g; value = 1.0e3))
    restored = deserialize_circuit(serialize_circuit(finish(b)))
    @test voltage(operating_point(restored), :y)[1] ≈ 1.0
end
