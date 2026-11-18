using Amber, Test, SparseArrays
@testset "typed numerical workspaces and shared symbolic plans" begin
    cc=identity_circuit()
    plan=compiled_solve_plan(cc)
    a=SimulationWorkspace(plan);b=SimulationWorkspace(cc;plan)
    @test a.plan === b.plan
    @test a.jacobian.colptr !== b.jacobian.colptr
    @test a.variable_scales !== b.variable_scales
    @test a.residual !== b.residual
    @test fieldtype(typeof(a),:factorization) !== Any
    @test fieldtype(typeof(a),:factorization_key) !== Any
    x=zeros(cc.n)
    result=Amber._newton(cc,x,x,0.,0.;workspace=a,mode=:dc)
    @test result[3]
    @test a.factorization isa SparseArrays.UMFPACK.UmfpackLU
    @test b.factorization === nothing
    count=a.numeric_factorizations
    updated=with_parameters(cc,"Supply.dc"=>2.)
    @test Amber._newton(updated,x,x,0.,0.;workspace=a,mode=:dc)[3]
    @test a.numeric_factorizations==count
    policy=SuiteSparseLU(ordering=:natural,pivot_tolerance=0.5)
    @test Amber._newton(cc,x,x,0.,0.;workspace=a,mode=:dc,linear_solver=policy)[3]
    @test a.factorization.control[SparseArrays.UMFPACK.JL_UMFPACK_PIVOT_TOLERANCE] == 0.5
    custom=SimulationWorkspace(compiled_solve_plan(cc;linear_solver=policy))
    @test Amber._newton(cc,x,x,0.,0.;workspace=custom,mode=:dc)[3]
    @test custom.factorization_key.solver==policy
    @test a.factorization_key.solver==policy
    @test a.numeric_factorizations==count+1
    @test_throws ArgumentError SimulationWorkspace(identity_circuit();plan)
    blocks=compiled_solve_plan(cc;structural=true)
    @test blocks.structural isa StructuralSolvePlan
    @test Amber._newton(cc,x,x,0.,0.;workspace=SimulationWorkspace(blocks),mode=:dc)[3]
end
