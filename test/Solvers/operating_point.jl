@testset "operating point" begin
    op=operating_point(LowPass()); @test op.stats[:converged]
    bjt=operating_point(BiasedNPN()); @test bjt.stats[:converged]
    @test region(bjt,:Q1) in (ForwardActive,Saturation)
    @circuit DCVersusWaveform() begin
        gnd=ground(); output=node()
        V1=voltage_source(output,gnd;dc=2V,waveform=Step(low=7V,high=9V,at=1s))
    end
    @test voltage(operating_point(DCVersusWaveform()),:output)[1]≈2V
end

@testset "regenerative latch pseudo-transient fallback" begin
    example_module=Module(:RegenerativeLatchExample)
    Base.include(example_module,normpath(joinpath(@__DIR__,"..","..","examples",
        "16_regenerative_latch","circuit.jl")))
    result=operating_point(getfield(example_module,:RegenerativeLatch)())
    @test result.stats[:converged]
    @test result.stats[:strategy]===:pseudo_transient
    @test result.stats[:fallback_trigger]===5
    @test voltage(result,:q)[1]≈-0.343075557 atol=1e-7
    @test voltage(result,:qb)[1]≈0.343075557 atol=1e-7
end


@testset "temperature-aware operating point" begin
    cold=operating_point(BiasedNPN();temperature=250.)
    hot=operating_point(BiasedNPN();temperature=350.)
    @test cold.stats[:converged]&&hot.stats[:converged]
    @test voltage(cold,:base)[1]!=voltage(hot,:base)[1]
end

@testset "typed solver options" begin
    options=SolverOptions(reltol=1e-8,max_newton_iterations=80,
        linear_solver=SuiteSparseLU(ordering=:natural,pivot_tolerance=0.05))
    result=simulate(BiasedNPN(),OperatingPoint(solver=options,temperature=310.))
    @test result.stats[:converged]
    @test result.analysis.solver===options
    @test result.stats[:temperature]==310.
    @test_throws AnalysisValidationError operating_point(LowPass();solver=SolverOptions(reltol=0.))
    @test_throws AnalysisValidationError operating_point(LowPass();solver=SolverOptions(
        linear_solver=SuiteSparseLU(ordering=:unsupported)))
end

@testset "pathological nonlinear and high-impedance convergence" begin
    example_module=Module(:PathologicalConvergenceExample)
    Base.include(example_module,normpath(joinpath(@__DIR__,"..","..","examples",
        "15_pathological_convergence","circuit.jl")))
    result=operating_point(getfield(example_module,:PathologicalConvergence)())
    @test result.stats[:converged]
    @test voltage(result,:diode_bias)[1]≈1.071197308 atol=1e-7
    @test voltage(result,:divider_midpoint)[1]≈50V atol=1e-8

    adaptive=operating_point(getfield(example_module,:PathologicalConvergence)();maxiters=8)
    @test adaptive.stats[:converged]
    @test adaptive.stats[:rejected_continuation_steps]>0
    @test voltage(adaptive,:diode_bias)[1]≈voltage(result,:diode_bias)[1] atol=1e-7
end
