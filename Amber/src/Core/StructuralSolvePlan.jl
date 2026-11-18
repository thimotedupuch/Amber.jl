"""Dependency-ordered equation/unknown permutations for an opt-in block solve.

The plan retains original solver identities; returned solutions use original
unknown order. Numerical matrices are checked for block-triangular compatibility
on every execution, including entries introduced by regularization or parameter
changes. This plan does not eliminate equations or change Newton iteration.
"""
struct StructuralSolvePlan
    mode::Symbol
    equation_permutation::Vector{Int}
    unknown_permutation::Vector{Int}
    block_ranges::Vector{UnitRange{Int}}
    equation_blocks::Vector{Int}
    unknown_blocks::Vector{Int}
end
function _structural_solve_plan(analysis::StructuralAnalysis)
    isempty(analysis.unmatched_equations) && isempty(analysis.unmatched_unknowns) ||
        throw(ArgumentError("cannot build a solve plan for structurally unmatched equations or unknowns"))
    n=size(analysis.incidence,1)
    equations=reduce(vcat,analysis.blocks;init=Int[])
    sort(equations) == collect(1:n) || throw(ArgumentError("structural blocks must partition equations"))
    unknowns=analysis.equation_to_unknown[equations]
    sort(unknowns) == collect(1:n) || throw(ArgumentError("structural matching must be a permutation"))
    ranges=UnitRange{Int}[]; equation_blocks=zeros(Int,n); unknown_blocks=zeros(Int,n)
    offset=0
    for (block,rows) in enumerate(analysis.blocks)
        range=(offset+1):(offset+length(rows)); push!(ranges,range)
        for position in range
            equation_blocks[equations[position]]=block
            unknown_blocks[unknowns[position]]=block
        end
        offset+=length(rows)
    end
    return StructuralSolvePlan(analysis.mode,equations,unknowns,ranges,equation_blocks,unknown_blocks)
end
"""
    structural_solve_plan(circuit; mode=:dc)

Compile the existing structural matching and SCC analysis into a block ordering.
Time-domain plans include storage incidence. Plans remain usable after numerical
parameter updates only when the actual matrix passes execution-time checks.
"""
structural_solve_plan(circuit;mode=:dc) = _structural_solve_plan(structural_analysis(circuit;mode))

function _structural_matrix_violation(plan, matrix)
    for column in axes(matrix,2), slot in nzrange(matrix,column)
        iszero(matrix.nzval[slot]) && continue
        row=matrix.rowval[slot]
        if plan.unknown_blocks[column] > plan.equation_blocks[row]
            return (;row,column)
        end
    end
    return nothing
end
function _structural_backward_error(matrix, solution, rhs)
    xnorm=norm(solution,Inf); bnorm=norm(rhs,Inf)
    isfinite(xnorm) || return Inf
    numerator=norm(matrix*solution-rhs,Inf)
    denominator=opnorm(matrix,Inf)*xnorm+bnorm
    if isfinite(numerator) && isfinite(denominator)
        return iszero(denominator) ? numerator : numerator/denominator
    end
    # Extreme finite inputs may overflow A*x or ||A||*||x|| even when the
    # answer and normwise backward error are representable. Normalize both
    # operands and align binary exponents without forming that product.
    anorm=maximum(abs,matrix.nzval;init=0.0)
    isfinite(anorm) && isfinite(bnorm) || return Inf
    iszero(anorm) && return iszero(bnorm) ? 0.0 : 1.0
    iszero(xnorm) && return iszero(bnorm) ? 0.0 : 1.0
    am,ae=frexp(anorm); xm,xe=frexp(xnorm); bm,be=frexp(bnorm)
    exponent=iszero(bnorm) ? ae+xe : max(ae+xe,be)
    axweight=ldexp(am*xm,ae+xe-exponent)
    bweight=iszero(bnorm) ? 0.0 : ldexp(bm,be-exponent)
    normalized=matrix/anorm
    residual=axweight .* (normalized*(solution/xnorm))
    iszero(bnorm) || (residual .-= bweight .* (rhs/bnorm))
    return norm(residual,Inf)/(axweight*opnorm(normalized,Inf)+bweight)
end
"""
    structural_solve(plan, matrix, rhs; fallback=:global, linear_solver=SuiteSparseLU())

Execute a dependency-ordered block linear solve. Returns `(solution, stats)`;
solutions retain original unknown order. `fallback=:error` rejects matrices
whose nonzero entries violate the plan and propagates singular block failures.
The default falls back to a global solve for either condition. Global numerical
singularity still propagates. The plan and inputs are never modified.

This experimental executor extracts sparse blocks on each call. It does not
cache symbolic/numeric factorizations and is not enabled in production solvers.
Backward-error checks can also trigger fallback; diagnostics describe the final
solution. Scalar blocks use direct division; coupled blocks use the chosen
linear solver. The tolerance controls fallback, not nonlinear convergence.
"""
function structural_solve(plan::StructuralSolvePlan,matrix::AbstractMatrix,rhs::AbstractVector;
        fallback=:global,linear_solver=SuiteSparseLU(),backward_tolerance=1e-10)
    fallback in (:global,:error) || throw(ArgumentError("fallback must be :global or :error"))
    _validate_solver_options(SolverOptions(;linear_solver))
    isfinite(backward_tolerance) && backward_tolerance >= 0 || throw(ArgumentError("backward tolerance must be finite and nonnegative"))
    n=length(plan.equation_permutation)
    size(matrix) == (n,n) && length(rhs) == n || throw(DimensionMismatch("matrix and RHS must match structural plan"))
    a=sparse(matrix)
    all(isfinite,a.nzval) && all(isfinite,rhs) || throw(ArgumentError("finite matrix and RHS required"))
    violation=_structural_matrix_violation(plan,a)
    reason=nothing; factorizations=0; scalar_solves=0
    if violation !== nothing
        fallback === :error && throw(ArgumentError("matrix entry ($(violation.row), $(violation.column)) violates structural block ordering"))
        reason=:incompatible_matrix
    end
    solution=zeros(promote_type(eltype(a),eltype(rhs),Float64),n)
    single_block=length(plan.block_ranges) == 1
    if reason === nothing && single_block
        factor=_new_factorization(a,linear_solver); factorizations+=1
        solution .= factor \ rhs
    end
    if reason === nothing && !single_block
        permuted=a[plan.equation_permutation,plan.unknown_permutation]
        residual=Vector{eltype(solution)}(rhs[plan.equation_permutation])
        ordered=similar(solution)
        try
            for range in plan.block_ranges
                if length(range) == 1
                    index=first(range); pivot=permuted[index,index]
                    iszero(pivot) && throw(LinearAlgebra.SingularException(index))
                    ordered[index]=residual[index]/pivot; scalar_solves+=1
                else
                    diagonal=permuted[range,range]
                    factor=_new_factorization(diagonal,linear_solver); factorizations+=1
                    ordered[range]=factor \ residual[range]
                end
                # Propagate this block's solution only to downstream equations.
                for column in range, slot in nzrange(permuted,column)
                    row=permuted.rowval[slot]
                    row > last(range) || continue
                    residual[row]-=permuted.nzval[slot]*ordered[column]
                end
            end
            solution[plan.unknown_permutation]=ordered
        catch error
            error isa LinearAlgebra.SingularException || rethrow()
            fallback === :error && rethrow()
            reason=:singular_block
        end
    end
    if reason === nothing
        error=_structural_backward_error(a,solution,rhs)
        if !all(isfinite,solution) || !isfinite(error) || error > backward_tolerance
            fallback === :error && throw(LinearSolveError("structural solve failed numerical backward-error check"))
            reason=:numerical_error
        end
    end
    if reason !== nothing
        factor=_new_factorization(a,linear_solver); factorizations+=1
        solution .= factor \ rhs
        all(isfinite,solution) || throw(LinearSolveError("global fallback produced a nonfinite solution"))
    end
    final_error=_structural_backward_error(a,solution,rhs)
    isfinite(final_error) || throw(LinearSolveError("linear solve backward error could not be assessed"))
    stats=(;strategy=reason === nothing ? (single_block ? :single_block : :structural_blocks) : :global,
        fallback_reason=reason,violation,blocks=length(plan.block_ranges),
        largest_block=maximum(length,plan.block_ranges;init=0),factorizations,scalar_solves,
        backward_error=final_error)
    return (;solution,stats)
end
