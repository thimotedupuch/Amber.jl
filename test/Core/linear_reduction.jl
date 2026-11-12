using Test, Amber, SparseArrays, LinearAlgebra, Random
@testset "affine elimination and reconstruction" begin
    # Independent row/column permutations exercise original equation identities.
    rng=MersenneTwister(593)
    for n in (1,7,20)
        matrix=spdiagm(-1=>fill(-0.3,n-1),0=>fill(2.0,n))
        matrix=matrix[randperm(rng,n),randperm(rng,n)]
        saved=copy(matrix); plan=reduce_linear_system(matrix)
        @test size(plan.reduced,1) < n
        @test plan.introduced_entries == 0
        for _ in 1:3
            rhs=randn(rng,n); before=copy(rhs)
            result=solve_reduced(plan,rhs;fallback=:error)
            @test result.solution ≈ matrix \ rhs rtol=1e-12
            @test result.stats.backward_error < 1e-14
            reduced_rhs=reduction_rhs(plan,rhs)
            retained=isempty(plan.unknowns) ? Float64[] : plan.reduced \ reduced_rhs
            @test reconstruct_solution(plan,retained,rhs) ≈ result.solution
            @test rhs == before && matrix == saved
        end
        # A snapshot remains independent of a caller's mutable source matrix.
        matrix.nzval .*= 2
        @test plan.original == saved
    end
    matrix=sparse([1.0 2 0;3 0 4;0 5 6])
    bounded=reduce_linear_system(matrix;max_fill=0,max_eliminations=1)
    filled=reduce_linear_system(matrix;max_fill=1,max_eliminations=1)
    @test length(bounded.eliminations) == 0
    @test length(filled.eliminations) == 1
    @test filled.introduced_entries == 1
    @test solve_reduced(filled,[1,2,3]).solution ≈ matrix \ [1,2,3]
    no_reduction=reduce_linear_system(matrix;max_eliminations=0)
    @test solve_reduced(no_reduction,[1,2,3]).solution ≈ matrix \ [1,2,3]
    complexmatrix=complex.(matrix)+im*spdiagm(fill(0.1,3))
    @test solve_reduced(reduce_linear_system(complexmatrix),ComplexF64[1,2,3]).solution ≈ complexmatrix \ [1,2,3]
end
@testset "linear reduction errors and safeguards" begin
    @test_throws DimensionMismatch reduce_linear_system(ones(2,3))
    @test_throws ArgumentError reduce_linear_system([NaN;;])
    @test_throws ArgumentError reduce_linear_system(ones(2,2);max_fill=-1)
    @test_throws ArgumentError reduce_linear_system(ones(2,2);max_eliminations=-1)
    @test_throws ArgumentError reduce_linear_system(ones(2,2);pivot_tolerance=0)
    plan=reduce_linear_system(sparse([1.0 2;0 3]))
    @test_throws DimensionMismatch reduction_rhs(plan,ones(3))
    @test_throws ArgumentError solve_reduced(plan,[NaN,1.0])
    @test_throws ArgumentError solve_reduced(plan,ones(2);fallback=:invalid)
    @test_throws DimensionMismatch reconstruct_solution(plan,ones(3),ones(2))
    singular=reduce_linear_system(sparse([1.0 1;1 1]))
    @test_throws SingularException solve_reduced(singular,[1.0,2])
    # Reject an elimination that would introduce nonfinite matrix coefficients.
    large=sparse([1e308 1e308;1e308 -1e308])
    guarded=reduce_linear_system(large;pivot_tolerance=1e-320,max_eliminations=1)
    @test all(isfinite,guarded.reduced.nzval)
    @test guarded.stopped_reason === :nonfinite_update
    @test guarded.reduced == large
end
@testset "linear circuit observable reconstruction" begin
    b=CircuitBuilder(:ReducedDivider)
    g=ground!(b); input=node!(b,:input); output=node!(b,:output)
    add!(b,voltage_source(input,g;dc=3.0);name=:Supply)
    add!(b,resistor(input,output;value=1000);name=:Top)
    add!(b,resistor(output,g;value=2000);name=:Bottom)
    cc=compile(finish(b))
    for current_cc in (cc,with_parameters(cc,"Top.value"=>2000))
        original=operating_point(current_cc); reduced=reduced_operating_point(current_cc)
        @test reduced.stats[:converged]
        @test report(reduced)[:statistics][:converged]
        @test reduced.values ≈ original.values rtol=1e-10
        @test voltage(reduced,:output) ≈ voltage(original,:output)
        @test current(reduced,:Supply) ≈ current(original,:Supply)
        @test power(reduced,:Top) ≈ power(original,:Top)
        @test reduced.stats[:reduction].eliminated > 0
    end
    nonlinear=CircuitBuilder(:NotAffine)
    g=ground!(nonlinear); n=node!(nonlinear,:n)
    add!(nonlinear,resistor(n,g;value=1e3);name=:R)
    add!(nonlinear,diode(n,g);name=:D)
    @test_throws ArgumentError reduced_operating_point(finish(nonlinear))
end
@testset "reduction RHS promotion and overflow fallback" begin
    matrix=sparse([2.0 1;0 3]); plan=reduce_linear_system(matrix)
    rhs=ComplexF64[1+2im,3-im]
    @test solve_reduced(plan,rhs).solution ≈ matrix \ rhs
    @test eltype(reduction_rhs(plan,rhs)) == ComplexF64
    @test solve_reduced(reduce_linear_system(matrix;max_eliminations=0),rhs).solution ≈ matrix \ rhs
    @test reconstruct_solution(plan,ComplexF64[],rhs) ≈ matrix \ rhs
    large=sparse([1e200 1e200;0.0 1e200]); rhs=[1e308,-1e308]
    # A partially reduced system used to pass an infinite RHS to LU.
    for limit in (1,2)
        reduction=reduce_linear_system(large;max_eliminations=limit)
        solved=solve_reduced(reduction,rhs)
        @test solved.solution ≈ [2e108,-1e108]
        @test solved.stats.fallback_reason === :rhs_overflow
        @test solved.stats.backward_error < 1e-14
        @test_throws LinearSolveError solve_reduced(reduction,rhs;fallback=:error)
        @test_throws LinearSolveError reduction_rhs(reduction,rhs)
    end
end
@testset "weak equation accuracy after reconstruction" begin
    matrix=sparse([1e-12 1.0;1e-20 1e-20]); rhs=[1.0,2e-20]
    inaccurate=[0.999866855977416,0.9999999999990001]
    @test Amber._structural_backward_error(matrix,inaccurate,rhs) < 1e-20
    @test Amber._linear_componentwise_error(matrix,inaccurate,rhs) > 1e-5
    plan=reduce_linear_system(matrix)
    @test first(plan.eliminations).unknown == 2
    result=solve_reduced(plan,rhs)
    @test result.solution ≈ matrix \ rhs rtol=1e-12
    @test result.stats.converged
    @test result.stats.componentwise_error < 1e-12
    # Reproduce the earlier valid but unstable elimination order explicitly.
    step=Amber.AffineElimination(1,1,1e-12,[2],[1.0],[2],[1e-8])
    unstable=LinearReduction(copy(matrix),sparse([1e-20-1e-8;;]),[2],[2],[step],0,:limit)
    recovered=solve_reduced(unstable,rhs)
    @test recovered.stats.fallback_reason === :numerical_error
    @test recovered.solution ≈ matrix \ rhs rtol=1e-12
    @test_throws LinearSolveError solve_reduced(unstable,rhs;fallback=:error)
    # A mathematically nonzero underflowed product must not look exact.
    @test Amber._linear_componentwise_error(sparse([1e-200;;]),[1e-200],[0.0]) ≈ 1.0
end
@testset "integer RHS with overflow-scale matrix norms" begin
    matrix=sparse([1e308 1e308;0.0 1e308])
    result=solve_reduced(reduce_linear_system(matrix),[1,-1])
    @test result.solution ≈ [2e-308,-1e-308]
    @test result.stats.converged
end
@testset "composed fill-producing substitutions" begin
    rng=MersenneTwister(901)
    for n in (5,9)
        matrix=spdiagm(-1=>fill(-0.2,n-1),0=>fill(3.0,n)); matrix[1,n]=-0.1
        matrix=matrix[randperm(rng,n),randperm(rng,n)]
        plan=reduce_linear_system(matrix;max_fill=1)
        rhs=randn(rng,n); result=solve_reduced(plan,rhs;fallback=:error)
        @test length(plan.eliminations) == n
        @test plan.introduced_entries > 1
        @test result.solution ≈ matrix \ rhs rtol=1e-12
        @test result.stats.converged
        @test result.stats.componentwise_error < 1e-12
    end
end
