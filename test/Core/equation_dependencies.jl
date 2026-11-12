using Test, Amber
@testset "expression dependency stages and invalidation" begin
    v=Amber.EquationInput{:voltage}(); t=Amber.EquationInput{:temperature}()
    resistance=Amber.EquationInput{:resistance}()
    # A temperature-dependent linear device has a configuration-dependent
    # Jacobian even though its residual depends on state.
    law=Amber.ConstitutiveLaw(v/(resistance*(1+0.01*(t-300))),Amber.EquationLiteral(0))
    kernel=Amber._constitutive_kernel(law,(:voltage,))
    roles=(;voltage=:state,temperature=:temperature,resistance=:parameter)
    plan=Amber._constitutive_dependencies(kernel,roles)
    @test Amber._equation_stage(plan.current) == :iteration
    @test Amber._equation_stage(plan.derivatives.voltage.current) == :configuration
    @test Amber._equation_stage(plan.charge) == :constant
    @test Amber._depends_on(plan.derivatives.voltage.current,:temperature)
    @test !Amber._depends_on(plan.derivatives.voltage.current,:state)
    @test Amber._equation_invalidated(plan.derivatives.voltage.current,(:temperature,))
    @test Amber._equation_invalidated(plan.derivatives.voltage.current,(:resistance,))
    @test !Amber._equation_invalidated(plan.derivatives.voltage.current,(:voltage,))
    @test !Amber._equation_invalidated(plan.current,())
    @test_throws ArgumentError Amber._constitutive_dependencies(kernel,(;voltage=:state))
    @test_throws ArgumentError Amber._equation_dependencies(v,(;voltage=:invalid))
    @test_throws ArgumentError Amber._depends_on(plan.current,:invalid)
    for (role,stage) in ((:topology,:topology),(:parameter,:configuration),(:temperature,:configuration),(:time,:time),(:mode,:mode),(:state,:iteration))
        @test Amber._equation_stage(Amber._equation_dependencies(v,(;voltage=role))) == stage
    end
    # Branch predicates are dependencies even if each branch is constant.
    piece=Amber._equation_positive(v,Amber.EquationLiteral(1),Amber.EquationLiteral(0))
    @test Amber._equation_stage(Amber._equation_dependencies(piece,roles)) == :iteration
    # A mode transition must invalidate an expression that also depends on time.
    mode=Amber.EquationInput{:mode}(); time=Amber.EquationInput{:time}()
    d=Amber._equation_dependencies(mode*time,(;mode=:mode,time=:time))
    @test Amber._equation_stage(d) == :mode
    @test Amber._equation_invalidated(d,(:mode,))
    @test Amber._equation_invalidated(d,(:time,))
end
