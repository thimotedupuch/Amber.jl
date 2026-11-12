using Test, Amber
@testset "constitutive expression differentiation" begin
    v = Amber.EquationInput{:voltage}(); c = Amber.EquationInput{:capacitance}()
    g = Amber.EquationInput{:conductance}()
    law = Amber.ConstitutiveLaw(g*v, c*v)
    kernel = Amber._constitutive_kernel(law, (:voltage, :conductance, :capacitance))
    point = @inferred Amber._constitutive_value(kernel, (; voltage=2.0, conductance=0.01, capacitance=1e-9))
    @test point.current == 0.02
    @test point.charge == 2e-9
    @test point.derivatives.voltage == (; current=0.01, charge=1e-9)
    @test point.derivatives.conductance.current == 2.0
    @test point.derivatives.capacitance.charge == 2.0
    @test Set(Amber._equation_inputs(law.current)) == Set((:conductance, :voltage))
    @test_throws ArgumentError Amber._constitutive_kernel(law, (:voltage, :voltage))
    # An inactive branch must never overflow through eager evaluation.
    branch = Amber._equation_positive(v, v, exp(-v))
    @test Amber._equation_value(branch, (;voltage=1e4)) == 1e4
end
@testset "diode IR versus independent device kernels" begin
    for model in (JunctionDiode(), JunctionDiode(breakdown_voltage=5.0, breakdown_current=1e-6))
        law = Amber._diode_conduction_ir(model)
        kernel = Amber._constitutive_kernel(law, (:voltage, :temperature, :saturation_current))
        for temperature in (250.0, 300.0, 400.0), voltage in (-10.0, -5.1, -0.1, 0.0, 0.4, 0.8, 3.0)
            inputs = (;voltage, temperature, saturation_current=model.saturation_current)
            point = Amber._constitutive_value(kernel, inputs)
            current, conductance = Amber._diode_conduction(model, voltage, temperature)
            @test point.current ≈ current rtol=1e-12 atol=1e-25
            @test point.derivatives.voltage.current ≈ conductance rtol=1e-12 atol=1e-25
            # Central differences check temperature and parameter derivatives,
            # away from branch knees and cancellation-dominated reverse currents.
            for (name, h) in ((:temperature, 1e-3), (:saturation_current, model.saturation_current*1e-3))
                plus = merge(inputs, NamedTuple{(name,)}((getproperty(inputs,name)+h,)))
                minus = merge(inputs, NamedTuple{(name,)}((getproperty(inputs,name)-h,)))
                finite = (Amber._equation_value(law.current,plus)-Amber._equation_value(law.current,minus))/(2h)
                analytic = getproperty(point.derivatives,name).current
                @test isapprox(analytic, finite; rtol=2e-4, atol=1e-18*max(1,abs(point.current))/h)
            end
        end
    end
end
