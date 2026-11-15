@testset "operating point" begin
    op = operating_point(LowPass()); @test op.stats[:converged]
    bjt = operating_point(BiasedNPN()); @test bjt.stats[:converged]
    @test region(bjt, :Q1) in (ForwardActive, Saturation)
    @circuit DCVersusWaveform() begin
        gnd = ground(); output = node()
        V1 = voltage_source(output, gnd; dc = 2V, waveform = Step(low = 7V, high = 9V, at = 1s))
    end
    @test voltage(operating_point(DCVersusWaveform()), :output)[1] ≈ 2V
end

@testset "regenerative latch pseudo-transient fallback" begin
    example_module = Module(:RegenerativeLatchExample)
    Base.include(
        example_module, normpath(
            joinpath(
                @__DIR__, "..", "..", "examples",
                "16_regenerative_latch", "circuit.jl"
            )
        )
    )
    result = operating_point(getfield(example_module, :RegenerativeLatch)())
    @test result.stats[:converged]
    @test result.stats[:strategy] === :pseudo_transient
    @test result.stats[:fallback_trigger] === 5
    @test voltage(result, :q)[1] ≈ -0.343075557V atol = 1.0e-7V
    @test voltage(result, :qb)[1] ≈ 0.343075557V atol = 1.0e-7V
end


@testset "temperature-aware operating point" begin
    cold = operating_point(BiasedNPN(); temperature = 250.0)
    hot = operating_point(BiasedNPN(); temperature = 350.0)
    @test cold.stats[:converged]&&hot.stats[:converged]
    @test voltage(cold, :base)[1] != voltage(hot, :base)[1]
end

@testset "typed solver options" begin
    options = SolverOptions(
        reltol = 1.0e-8, max_newton_iterations = 80,
        linear_solver = SuiteSparseLU(ordering = :natural, pivot_tolerance = 0.05)
    )
    result = simulate(BiasedNPN(), OperatingPoint(solver = options, temperature = 310.0))
    @test result.stats[:converged]
    @test result.analysis.solver === options
    @test result.stats[:temperature] == 310.0
    @test_throws AnalysisValidationError operating_point(LowPass(); solver = SolverOptions(reltol = 0.0))
    @test_throws AnalysisValidationError operating_point(
        LowPass(); solver = SolverOptions(
            linear_solver = SuiteSparseLU(ordering = :unsupported)
        )
    )
end

@testset "pathological nonlinear and high-impedance convergence" begin
    example_module = Module(:PathologicalConvergenceExample)
    Base.include(
        example_module, normpath(
            joinpath(
                @__DIR__, "..", "..", "examples",
                "15_pathological_convergence", "circuit.jl"
            )
        )
    )
    result = operating_point(getfield(example_module, :PathologicalConvergence)())
    @test result.stats[:converged]
    @test voltage(result, :diode_bias)[1] ≈ 1.071197308V atol = 1.0e-7V
    @test voltage(result, :divider_midpoint)[1] ≈ 50V atol = 1.0e-8V

    adaptive = operating_point(getfield(example_module, :PathologicalConvergence)(); maxiters = 8)
    @test adaptive.stats[:converged]
    @test adaptive.stats[:rejected_continuation_steps] > 0
    @test voltage(adaptive, :diode_bias)[1] ≈ voltage(result, :diode_bias)[1] atol = 1.0e-7V
end

@testset "failed operating point residual uses analysis temperature" begin
    @circuit ReverseTemperatureFailure() begin
        gnd = ground(); output = node()
        I1 = current_source(output, gnd; dc = 1.5mA)
        R = resistor(output, gnd; value = 1e12)
        D = diode(output, gnd; model = JunctionDiode(saturation_current = 1mA))
    end
    result = operating_point(ReverseTemperatureFailure(); temperature = 350.0,
        maxiters = 4, continuation_maxdepth = 0)
    @test !result.stats[:converged]
    z = result.values[:, 1]
    hot = Amber.residual(result.compiled, z, zero(z), 0.0; mode = :dc, temperature = 350.0)
    cold = Amber.residual(result.compiled, z, zero(z), 0.0; mode = :dc, temperature = 300.0)
    expected = maximum(abs, hot)
    @test result.stats[:dominant_residual].norm ≈ expected
    @test !isapprox(maximum(abs, cold), expected; rtol = 1e-3)
end

@testset "CMOS chain singular intermediate continuation recovery" begin
    b = CircuitBuilder(:LongCMOSChain)
    g = ground!(b,:gnd); supply=node!(b,:supply); input=node!(b,:input)
    outputs=node_array!(b,:out,1:100)
    add!(b,voltage_source(supply,g;dc=5.0);name=:VDD)
    add!(b,voltage_source(input,g;dc=0.0);name=:Input)
    nm=Level1MOSFET(transconductance=.002,channel_length_modulation=.03)
    pm=Level1MOSFET(transconductance=.001,channel_length_modulation=.03)
    for i in 1:100
        gate=i==1 ? input : outputs[i-1]
        add!(b,nmos(outputs[i],gate,g,g;model=nm);name=(:N,i))
        add!(b,pmos(outputs[i],gate,supply,supply;model=pm);name=(:P,i))
        add!(b,capacitor(outputs[i],g;value=1e-11);name=(:C,i))
    end
    cc=compile(finish(b))
    result=operating_point(cc;solver=SolverOptions(reltol=1e-6,current_abstol=1e-12,voltage_abstol=1e-9))
    @test result.stats[:converged]
    @test result.values[3:102,1] ≈ [isodd(i) ? 5.0 : 0.0 for i in 1:100] atol=1e-8
    @test maximum(abs.(Amber.residual(cc,result.values[:,1],zeros(cc.n),0.0;mode=:dc)))<1e-10

    # A genuinely floating ideal source must still fail; recovery must never
    # turn an unsolved DC system into a reported success.
    floating=CircuitBuilder(:FloatingDCSource)
    ground!(floating,:gnd);p=node!(floating,:p);n=node!(floating,:n)
    add!(floating,voltage_source(p,n;dc=1.0);name=:V)
    @test_throws Amber.CircuitValidationError operating_point(finish(floating))
end
