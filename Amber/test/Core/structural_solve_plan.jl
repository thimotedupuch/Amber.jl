using Test, Amber, SparseArrays, LinearAlgebra, Random
function matrix_structural_plan(matrix)
    n=size(matrix,1); rows=[Int[] for _ in 1:n]
    for column in 1:n, row in 1:n
        iszero(matrix[row,column]) || push!(rows[row],column)
    end
    e,u=Amber._structural_matching(rows,n)
    analysis=StructuralAnalysis(:dc,sparse(.!iszero.(matrix)),e,u,
        findall(iszero,e),findall(iszero,u),Amber._equation_blocks(rows,u))
    return Amber._structural_solve_plan(analysis)
end
@testset "executable structural solve ordering" begin
    rng=MersenneTwister(214)
    # Independent row/column permutations exercise matched unknown reconstruction.
    for n in (1,7,25)
        original=tril(randn(rng,n,n)); original[diagind(original)].+=5
        rowperm=randperm(rng,n); colperm=randperm(rng,n)
        matrix=sparse(original[rowperm,colperm]); rhs=randn(rng,n)
        plan=matrix_structural_plan(matrix)
        saved=copy(matrix); savedrhs=copy(rhs)
        result=structural_solve(plan,matrix,rhs;fallback=:error)
        @test result.solution ≈ matrix \ rhs rtol=1e-12
        @test result.stats.strategy == (n == 1 ? :single_block : :structural_blocks)
        @test result.stats.blocks == n
        @test result.stats.backward_error < 1e-14
        @test matrix == saved && rhs == savedrhs
    end
    # A coupled diagonal block plus a downstream singleton.
    matrix=sparse([3.0 1 0; 1 2 0; 2 4 5])
    result=structural_solve(matrix_structural_plan(matrix),matrix,[1,2,3])
    @test result.solution ≈ matrix \ [1,2,3]
    @test result.stats.largest_block == 2
    @test result.stats.blocks == 2
    complexmatrix=complex.(matrix)+im*spdiagm(fill(0.1,3))
    @test structural_solve(matrix_structural_plan(matrix),complexmatrix,ComplexF64[1,2,3]).solution ≈ complexmatrix \ [1,2,3]
end
@testset "structural plan numerical compatibility and failures" begin
    matrix=sparse([0.0 1;1 0]); plan=matrix_structural_plan(matrix)
    # Regularization diagonals can couple previously independent matched blocks.
    changed=matrix+0.1I
    result=structural_solve(plan,changed,[1.0,2])
    @test result.solution ≈ changed \ [1.0,2]
    @test result.stats.fallback_reason == :incompatible_matrix
    @test result.stats.violation !== nothing
    @test_throws ArgumentError structural_solve(plan,changed,[1.0,2];fallback=:error)
    @test_throws DimensionMismatch structural_solve(plan,ones(3,3),ones(3))
    @test_throws ArgumentError structural_solve(plan,matrix,[NaN,1.0])
    @test_throws ArgumentError structural_solve(plan,matrix,[1.0,2];fallback=:unknown)
    @test_throws AnalysisValidationError structural_solve(plan,matrix,[1.0,2];linear_solver=SuiteSparseLU(ordering=:invalid))
    @test_throws ArgumentError matrix_structural_plan(zeros(2,2))
    singular=sparse([1.0 1;1 1]); singularplan=matrix_structural_plan(singular)
    @test_throws SingularException structural_solve(singularplan,singular,[1.0,2];fallback=:error)
    @test_throws SingularException structural_solve(singularplan,singular,[1.0,2])
end
@testset "circuit solve plan and parameter updates" begin
    builder=CircuitBuilder(:Feedforward)
    g=ground!(builder); input=node!(builder,:input); output=node!(builder,:output)
    add!(builder,voltage_source(input,g;dc=1);name=:Supply)
    add!(builder,resistor(output,g;value=1000);name=:Load)
    add!(builder,transconductance(input,g,output,g;gm=1e-3);name=:Gain)
    cc=compile(finish(builder)); plan=structural_solve_plan(cc)
    for current in (cc,with_parameters(cc,"Load.value"=>2000))
        ws=SimulationWorkspace(current); x=zeros(current.n)
        r,j=residual_jacobian!(ws,current,x,x,0.0,0.0;mode=:dc)
        result=structural_solve(plan,j,-r;fallback=:error)
        @test result.solution ≈ j \ -r
        @test result.stats.blocks > 1
        @test result.stats.backward_error < 1e-14
    end
    @test structural_solve_plan(cc;mode=:time).mode == :time
end

@testset "structural solve numerical safeguard" begin
    rng=MersenneTwister(719)
    exercised=false
    for _ in 1:10
        matrix=sparse(tril(randn(rng,6,6))+4I); rhs=randn(rng,6)
        plan=matrix_structural_plan(matrix)
        result=structural_solve(plan,matrix,rhs;backward_tolerance=0.0)
        if result.stats.fallback_reason === :numerical_error
            @test result.stats.strategy == :global
            @test result.solution ≈ matrix \ rhs
            @test_throws LinearSolveError structural_solve(plan,matrix,rhs;fallback=:error,backward_tolerance=0.0)
            exercised=true; break
        end
    end
    @test exercised
    matrix=sparse([1.0 0;2 3]); plan=matrix_structural_plan(matrix)
    result=structural_solve(plan,matrix,[1.0,2])
    @test result.stats.scalar_solves == 2
    @test result.stats.factorizations == 0
    @test_throws ArgumentError structural_solve(plan,matrix,[1.0,2];backward_tolerance=NaN)
end
@testset "operating point with opt-in structural linear solves" begin
    function make_design(;nonlinear=false)
        b=CircuitBuilder(:PlannedBias)
        g=ground!(b); input=node!(b,:input); output=node!(b,:output)
        add!(b,voltage_source(input,g;dc=0.8);name=:Supply)
        add!(b,resistor(output,g;value=1000);name=:Load)
        add!(b,transconductance(input,g,output,g;gm=-1e-3);name=:Gain)
        nonlinear && add!(b,diode(output,g);name=:Diode)
        add!(b,capacitor(output,input;value=1e-9);name=:Coupling)
        return compile(finish(b))
    end
    for nonlinear in (false,true)
        cc=make_design(;nonlinear); plan=structural_solve_plan(cc)
        reference=operating_point(cc)
        planned=operating_point(cc;linear_plan=plan)
        @test reference.stats[:converged] && planned.stats[:converged]
        @test planned.values ≈ reference.values rtol=1e-7 atol=1e-10
        @test !isempty(planned.stats[:linear_solve_history])
        @test all(h -> h.backward_error < 1e-10, planned.stats[:linear_solve_history])
        # Validate the storage-inclusive solve plan on a transient Jacobian too.
        ws=SimulationWorkspace(cc); x=vec(reference.values)
        _,j=residual_jacobian!(ws,cc,x,x,0.0,1e6)
        rhs=collect(1.0:cc.n)
        timeplan=structural_solve_plan(cc;mode=:time)
        @test structural_solve(timeplan,j,rhs;fallback=:error).solution ≈ j \ rhs
    end
end
@testset "overflow-safe structural backward error" begin
    matrix=sparse([1e200 1e200;0.0 1e200]); rhs=[1e308,-1e308]
    plan=matrix_structural_plan(matrix)
    result=structural_solve(plan,matrix,rhs)
    @test result.solution ≈ [2e108,-1e108]
    @test result.stats.fallback_reason === :numerical_error
    @test isfinite(result.stats.backward_error)
    @test result.stats.backward_error < 1e-14
    @test Amber._structural_backward_error(matrix,[0.0,0.0],rhs) == 1.0
    # Zero RHS and a solution far outside the nullspace have error one, even
    # when the unnormalized matrix product overflows.
    @test Amber._structural_backward_error(sparse([1e200 0;0 1e200]),[1e200,0.0],zeros(2)) ≈ 1.0
end
