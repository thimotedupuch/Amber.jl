@testset "verification: analytic residual Jacobians" begin
    @circuit NonlinearJacobianReference() begin
        gnd = ground(); supply = node(); base = node(); collector = node(); emitter = node(); control = node(); switched = node()
        VDD = voltage_source(supply, gnd; dc = 5V)
        Vbase = voltage_source(base, gnd; dc = 0.62V)
        Vcontrol = voltage_source(control, gnd; dc = 0.7V)
        RC = resistor(supply, collector; value = 2kΩ); RE = resistor(emitter, gnd; value = 200Ω)
        Q1 = npn(collector, base, emitter; model = GummelPoonBJT(forward_beta = 90.0, reverse_beta = 2.0, cbe_zero_bias = 5pF, cbc_zero_bias = 2pF))
        D1 = diode(collector, gnd; model = JunctionDiode(saturation_current = 3nA, junction_capacitance = 10pF, transit_time = 2ns))
        S1 = analog_switch(supply, switched, control, gnd; model = SmoothSwitch(threshold = 0.5V, transition = 0.1V, ron = 10Ω, roff = 1MΩ))
        RS = resistor(switched, gnd; value = 1kΩ)
    end
    compiled = compile(NonlinearJacobianReference()); point = operating_point(compiled).values[:, 1]
    previous = point .- range(1.0e-5, 5.0e-5; length = compiled.n); α = 1234.0; temperature = 315.0
    _, analytic = Amber.residual_jacobian(compiled, point, previous, 0.2, α; temperature)
    numerical = Amber._jacobian(z -> Amber.residual(compiled, z, α .* (z .- previous), 0.2; temperature), point)
    @test relative_error(Matrix(analytic), numerical) < 2.0e-5
end
