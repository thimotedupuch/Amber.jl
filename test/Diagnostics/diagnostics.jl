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

@testset "high impedance control nodes remain floating" begin
    @circuit FloatingSwitchControl() begin
        gnd = ground(); output = node(); control = node()
        R = resistor(output, gnd; value = 1kΩ)
        S = analog_switch(output, gnd, control, gnd)
    end
    diagnostics = check(FloatingSwitchControl())
    @test any(d -> d.severity === :error && occursin("control", d.message) && occursin("DC path", d.message), diagnostics)
end

@testset "MOS bulk junction DC connectivity" begin
    @circuit BulkJunctionPath() begin
        gnd = ground(); drain = node(); bulk = node()
        VD = voltage_source(drain, gnd; dc = 1V)
        M = nmos(drain, gnd, gnd, bulk; model = ChargeBasedMOSFET(drain_area = 1e-12))
    end
    @test !any(d -> occursin("no finite DC path", d.message), check(BulkJunctionPath()))
end

@testset "MOS and behavioral high impedance controls" begin
    @circuit FloatingMOSGate() begin
        gnd = ground(); output = node(); control = node()
        R = resistor(output, gnd; value = 1kΩ)
        M = nmos(output, control, gnd, gnd)
    end
    @circuit FloatingBehavioralControl() begin
        gnd = ground(); output = node(); control = node()
        R = resistor(output, gnd; value = 1kΩ)
        B = behavioral_voltage_source(((control, gnd),), output, gnd;
            voltage = (v, t) -> v[1], gradient = (v, t) -> (1.0, 0.0, 0.0, 0.0))
    end
    for circuit in (FloatingMOSGate(), FloatingBehavioralControl())
        @test any(d -> d.severity === :error && occursin("control", d.message) && occursin("DC path", d.message), check(circuit))
    end
end

@testset "self controlled transconductance DC path" begin
    @circuit TransconductanceShunt() begin
        gnd = ground(); output = node()
        I1 = current_source(output, gnd; dc = 1mA)
        G1 = transconductance(output, gnd, output, gnd; gm = 1mA / V)
    end
    @test !any(d -> d.severity === :error, check(TransconductanceShunt()))
    @test only(voltage(operating_point(TransconductanceShunt()), :output)) ≈ -1V
end

@testset "controlled current feedback anchors DC voltages" begin
    @circuit CrossedTransconductances() begin
        gnd = ground(); a = node(); b = node()
        I1 = current_source(a, gnd; dc = 1mA)
        I2 = current_source(b, gnd; dc = 2mA)
        G1 = transconductance(b, gnd, a, gnd; gm = 1mA / V)
        G2 = transconductance(a, gnd, b, gnd; gm = 1mA / V)
    end
    @test !any(d -> d.severity === :error, check(CrossedTransconductances()))
    point = operating_point(CrossedTransconductances())
    @test only(voltage(point, :a)) ≈ -2V
    @test only(voltage(point, :b)) ≈ -1V
end

@testset "controlled current output can remain floating" begin
    @circuit FloatingControlledOutput() begin
        gnd = ground(); output = node()
        I1 = current_source(output, gnd; dc = 1mA)
        G1 = transconductance(gnd, gnd, output, gnd; gm = 1mA / V)
    end
    @test any(d -> d.severity === :error && occursin("DC path", d.message), check(FloatingControlledOutput()))
end
