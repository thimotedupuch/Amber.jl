@testset "passive technology catalogue" begin
    materials = (ThinFilm, ThickFilm, MetalFilm, CarbonFilm, CarbonComposition, MetalFoil, Wirewound)
    packages = (SMD0201, SMD0402, SMD0603, SMD0805, SMD1206, SMD1210, SMD2010, SMD2512, Axial, Radial, PassivePackage)
    dielectrics = (C0G, X7R, X5R, Polypropylene, Polyester, PPS, Mica, AluminumElectrolytic, Tantalum)

    for T in materials
        material = T(excess_noise_coefficient = 1.0e-12)
        b = CircuitBuilder(:Material); g = ground!(b, :g); x = node!(b, :x); y = node!(b, :y)
        add!(b, voltage_source(x, g; dc = 1.0); name = :supply)
        add!(b, resistor(x, y; value = 1000.0, material); name = :R)
        add!(b, resistor(y, g; value = 1000.0); name = :load)
        design = finish(b); restored = deserialize_circuit(serialize_circuit(design))
        @test serialize_circuit(restored) == serialize_circuit(design)
        @test voltage(operating_point(restored), :y)[1] ≈ 0.5
        result = noise(restored, [10.0, 1000.0]; output = voltage(:y))
        contribution = only(noise_contributions(result; component = :R, mechanism = :flicker))
        # 0.5 mA bias; parallel 1 kohm resistors give a 500 ohm transfer impedance.
        @test contribution.output_psd ≈ [1.0e-12 * (0.5e-3)^2 / f * 500^2 for f in (10.0, 1000.0)]
        snapshot = provenance(operating_point(restored))[:parameters]["R"][:material]
        @test snapshot[:parameters][:excess_noise_coefficient] == 1.0e-12
        @test with_model_parameter(material, :excess_noise_coefficient, 2.0e-12).excess_noise_coefficient == 2.0e-12
        @test_throws ArgumentError T(excess_noise_coefficient = -1.0)
        @test_throws ArgumentError T(excess_reference_frequency = 0.0)
        @test_throws ArgumentError T(excess_current_exponent = NaN)
        @test_throws ArgumentError T(temperature_coefficient = 1.0e-5)
        @test_throws ArgumentError T(voltage_coefficient = 1.0e-5)
        @test_throws ArgumentError T(unknown = 1.0)
    end

    for T in packages, kind in (:resistor, :capacitor)
        package = kind === :resistor ? T(series_inductance = 2.0e-6, parallel_capacitance = 3.0e-9) : T(esr = 2.0, esl = 2.0e-6)
        b = CircuitBuilder(:Package); g = ground!(b, :g); x = node!(b, :x)
        add!(b, voltage_source(x, g; ac = 1.0); name = :supply)
        add!(b, kind === :resistor ? resistor(x, g; value = 100.0, package) : capacitor(x, g; value = 1.0e-6, package); name = :dut)
        design = finish(b); restored = deserialize_circuit(serialize_circuit(design))
        @test serialize_circuit(restored) == serialize_circuit(design)
        fs = [100.0, 1.0e4, 1.0e6]; result = small_signal(restored, fs)
        for (i, f) in enumerate(fs)
            w = 2π * f
            expected = kind === :resistor ? inv(100 + im * w * 2.0e-6) + im * w * 3.0e-9 : inv(2 + im * w * 2.0e-6 + inv(im * w * 1.0e-6))
            @test -current(result, :supply)[i] ≈ expected rtol = 1.0e-6
        end
        @test_throws ArgumentError T(esr = -1.0)
        @test_throws ArgumentError T(esl = Inf)
        @test_throws ArgumentError with_model_parameter(package, :parallel_capacitance, NaN)
    end

    for T in dielectrics
        dielectric = T(loss_tangent = 0.02, reference_frequency = 1000.0)
        b = CircuitBuilder(:Dielectric); g = ground!(b, :g); x = node!(b, :x)
        add!(b, voltage_source(x, g; ac = 1.0); name = :supply)
        add!(
            b, capacitor(
                x, g; value = 1.0e-6, dielectric, package = Radial(esr = 2.0), esr = 3.0,
                leakage_resistance = 1.0e6, dielectric_absorption = DebyeBranches(time_constants = [0.01], fractions = [0.1])
            ); name = :dut
        )
        design = finish(b); restored = deserialize_circuit(serialize_circuit(design))
        @test serialize_circuit(restored) == serialize_circuit(design)
        fs = [100.0, 1000.0, 1.0e4]; result = small_signal(restored, fs)
        loss_resistance = 0.02 / (2π * 1000 * 1.0e-6)
        for (i, f) in enumerate(fs)
            w = 2π * f
            y = im * w * 1.0e-6 + 1.0e-6 + inv(0.01 / 1.0e-7 + inv(im * w * 1.0e-7))
            @test -current(result, :supply)[i] ≈ inv(3 + loss_resistance + inv(y)) rtol = 1.0e-6
        end
        @test with_model_parameter(dielectric, :loss_tangent, 0.01).loss_tangent == 0.01
        @test_throws TopologyParameterError with_parameters(compile(restored), "dut.dielectric" => T())
        @test_throws ArgumentError T(loss_tangent = 0.01)
        @test_throws ArgumentError T(loss_tangent = -1.0)
        @test_throws ArgumentError T(reference_frequency = Inf)
        @test_throws ArgumentError with_model_parameter(dielectric, :reference_frequency, 0.0)
    end

    @circuit DielectricTransient begin
        g = ground(); x = node()
        supply = voltage_source(x, g; dc = 1.0)
        C1 = capacitor(
            x, g; value = 1.0e-6, initial_voltage = 0.0,
            dielectric = Polypropylene(loss_tangent = 2π * 0.001, reference_frequency = 1.0)
        )
    end
    # The specified tangent gives 1 kohm ESR and a 1 ms time constant.
    design = DielectricTransient()
    tr = transient(design, 0.0 => 0.005; max_step = 1.0e-5)
    @test current(tr, :supply)[end] ≈ -1.0e-3 * exp(-5) rtol = 0.03
    nr = noise(design, [100.0, 1000.0]; output = voltage(Symbol("C1.__esr")))
    @test noise_psd(nr) ≈ [4 * 1.380649e-23 * 300 * 1000 / (1 + (2π * f * 0.001)^2) for f in (100.0, 1000.0)] rtol = 1.0e-6

    @test_throws ArgumentError DebyeBranches(time_constants = [0.0], fractions = [0.1])
    @test_throws ArgumentError DebyeBranches(time_constants = [1.0], fractions = [-0.1])
    @test_throws ArgumentError DebyeBranches(time_constants = [1.0], fractions = [])
    # Preserve the original schema-3 lossless C0G data representation.
    legacy = C0G((loss_tangent = 0.0,))
    @test Amber._validate_model_parameters(legacy) === legacy
end
