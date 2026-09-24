@testset "structural diagnostics" begin
    @circuit Bad() begin
        gnd = ground(); n = node(); V1 = voltage_source(n, gnd; dc = 5V); V2 = voltage_source(n, gnd; dc = 3V)
    end
    @test any(d -> d.severity == :error, check(Bad()))
    @circuit FloatingIsland() begin
        g = ground(); a = node(); b = node(); reference = resistor(g, g; value = 1kΩ); C1 = capacitor(a, b; value = 10nF)
    end
    c = FloatingIsland()
    @test any(d -> occursin("no finite DC path", d.message), check(c))
    @test any(d -> occursin("a", d.message)&&occursin("b", d.message), check(c))
    @circuit BadLoop() begin
        gnd = ground(); a = node(); b = node(); V1 = voltage_source(a, gnd; dc = 1V)
        V2 = voltage_source(b, a; dc = 1V); V3 = voltage_source(b, gnd; dc = 3V)
    end
    @test any(d -> occursin("inconsistent loop", d.message), check(BadLoop()))
    @circuit IdealInductorLoop() begin
        gnd = ground(); a = node(); b = node()
        L1 = inductor(gnd, a; value = 1mH); L2 = inductor(a, b; value = 1mH); L3 = inductor(b, gnd; value = 1mH)
    end
    @test any(d -> occursin("ideal voltage-constraint loop", d.message), check(IdealInductorLoop()))
    bad_explanation = explain(Bad())
    @test occursin("Structural check", bad_explanation)
    @test occursin("Conflicting ideal voltage constraints", bad_explanation)
    @test occursin("ready to compile", explain(LowPass()))

    converged = transient(LowPass(), 0s => 20μs; saveat = 10μs)
    @test occursin("converged", explain_failure(converged))
    failed_stats = copy(converged.stats)
    failed_stats[:converged] = false
    failed_stats[:failed_steps] = [2]
    failed_stats[:failed_residuals] = [(row = 1, norm = 1.25)]
    failed = SimulationResult(converged.compiled, converged.analysis, converged.axis, converged.values, failed_stats)
    failure_explanation = explain_failure(failed)
    @test occursin("did not converge", failure_explanation)
    @test occursin("dominated the residual", failure_explanation)
    @test occursin("KCL at net vin", failure_explanation)

    validation_error = CircuitValidationError(check(c))
    @test occursin("no finite DC path", explain_failure(validation_error))
    @test startswith(explain_failure(validation_error), "Circuit validation failed:")

    result = operating_point(LowPass())
    lookup_error = try
        voltage(result, :vuot)
    catch error
        error
    end
    @test lookup_error isa CircuitLookupError
    @test occursin("Unknown net `vuot`", sprint(showerror, lookup_error))
    @test occursin("Did you mean `vout`?", sprint(showerror, lookup_error))
end
