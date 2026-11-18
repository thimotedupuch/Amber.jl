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
@testset "complete diode charge IR and continuous DAE tangent" begin
    for grading in (0.5, 1.0), temperature in (250.0, 340.0)
        model = JunctionDiode(junction_capacitance=2e-12, junction_potential=0.7,
            grading_coefficient=grading, transit_time=1e-9, breakdown_voltage=5.0)
        law = Amber._diode_constitutive_ir(model)
        kernel = Amber._constitutive_kernel(law, (:voltage, :temperature, :saturation_current))
        second = Amber._equation_derivative(kernel.derivatives.voltage.charge, Val(:voltage))
        for voltage in (-10.0, -0.2, 0.0, 0.4, 0.62, 0.64, 0.8, 3.0)
            inputs = (;voltage, temperature, saturation_current=model.saturation_current)
            point = Amber._constitutive_value(kernel, inputs)
            @test point.charge ≈ charge(model, voltage; temperature) rtol=1e-12 atol=1e-25
            @test point.derivatives.voltage.charge ≈ differential_capacitance(model,voltage;temperature) rtol=1e-12 atol=1e-25
            @test Amber._equation_value(second,inputs) ≈ Amber._capacitance_slope(model,voltage;temperature) rtol=1e-12 atol=1e-25
            # Full continuous DAE tangent includes q_xx * xdot, not just alpha*q_x.
            rate=0.13; alpha=1e6; h=1e-7
            function residual(delta)
                shifted=merge(inputs,(;voltage=voltage+delta))
                p=Amber._constitutive_value(kernel,shifted)
                p.current + p.derivatives.voltage.charge*(rate+alpha*delta)
            end
            expected=point.derivatives.voltage.current + alpha*point.derivatives.voltage.charge + rate*Amber._equation_value(second,inputs)
            @test isapprox((residual(h)-residual(-h))/(2h),expected;rtol=1e-5,atol=1e-18)
        end
    end
    # Zero capacitance must avoid evaluating a needless depletion expression.
    model=JunctionDiode(junction_capacitance=0.0,transit_time=0.0)
    kernel=Amber._constitutive_kernel(Amber._diode_constitutive_ir(model),(:voltage,))
    @test Amber._constitutive_value(kernel,(;voltage=2.0,temperature=300.0,saturation_current=model.saturation_current)).charge == 0
end
@testset "IR law agrees with global diode assembly" begin
    model=JunctionDiode(junction_capacitance=2e-12,transit_time=1e-9)
    builder=CircuitBuilder(:IRDiode)
    g=ground!(builder); p=node!(builder,:p); n=node!(builder,:n)
    add!(builder,diode(p,n;model);name=:D)
    add!(builder,resistor(n,g;value=1e6);name=:Bias)
    cc=compile(finish(builder)); ws=SimulationWorkspace(cc)
    kernel=Amber._constitutive_kernel(Amber._diode_constitutive_ir(model),(:voltage,))
    second=Amber._equation_derivative(kernel.derivatives.voltage.charge,Val(:voltage))
    for voltage in (-0.2,0.4,0.8), temperature in (270.0,350.0)
        x=[voltage+0.1,0.1]; rate=0.13; alpha=1e6
        previous=x-[rate/alpha,0.0]
        inputs=(;voltage,temperature,saturation_current=model.saturation_current)
        point=Amber._constitutive_value(kernel,inputs)
        # Use the actual floating-point integration rate from state history.
        actual_rate=alpha*((x[1]-previous[1])-(x[2]-previous[2]))
        i=point.current+point.derivatives.voltage.charge*actual_rate
        tangent=point.derivatives.voltage.current+alpha*point.derivatives.voltage.charge+
            Amber._equation_value(second,inputs)*actual_rate
        r,j=residual_jacobian!(ws,cc,x,previous,0.0,alpha;temperature)
        @test r ≈ [i,-i+x[2]/1e6] rtol=1e-11 atol=1e-25
        @test Matrix(j) ≈ [tangent -tangent;-tangent tangent+1e-6] rtol=1e-11 atol=1e-25
        q,c=storage_jacobian!(ws,cc,x;temperature)
        @test q ≈ [point.charge,-point.charge] rtol=1e-11 atol=1e-25
        cap=point.derivatives.voltage.charge
        @test Matrix(c) ≈ [cap -cap;-cap cap] rtol=1e-11 atol=1e-25
    end
end
