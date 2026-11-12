"""One affine equation and its RHS substitution, in original solver identities."""
struct AffineElimination{T}
    equation::Int
    unknown::Int
    pivot::T
    columns::Vector{Int}
    coefficients::Vector{T}
    affected_equations::Vector{Int}
    multipliers::Vector{T}
end
"""A numerical linear-operator snapshot with reversible affine elimination.

Rebuild after changing the matrix; repeated right-hand sides may reuse this
snapshot. Source/reduced matrices and reconstruction records must not be mutated.
No nonlinear, charge, noise, or descriptor-system transformation is implied.
"""
struct LinearReduction{T}
    original::SparseMatrixCSC{T,Int}
    reduced::SparseMatrixCSC{T,Int}
    equations::Vector{Int}
    unknowns::Vector{Int}
    eliminations::Vector{AffineElimination{T}}
    introduced_entries::Int
    stopped_reason::Symbol
end

"""
    reduce_linear_system(matrix; max_fill=0, max_eliminations=size(matrix,1), pivot_tolerance=1e-12)

Eliminate singleton/two-term affine equations using row-relative pivot screening
and a per-step bound on newly introduced structural entries. Returns a reusable
operator snapshot and reconstruction program. Fill counts conservatively count
new positions before numerical cancellation. Equal-cost choices are deterministic.
This initial implementation uses sparse row dictionaries during construction.
"""
function reduce_linear_system(matrix::AbstractMatrix;max_fill=0,
        max_eliminations=size(matrix,1),pivot_tolerance=1e-12)
    n=size(matrix,1)
    size(matrix,2) == n || throw(DimensionMismatch("linear reduction requires a square matrix"))
    max_fill isa Integer && max_fill >= 0 || throw(ArgumentError("max_fill must be a nonnegative integer"))
    max_eliminations isa Integer && max_eliminations >= 0 || throw(ArgumentError("max_eliminations must be a nonnegative integer"))
    isfinite(pivot_tolerance) && 0 < pivot_tolerance <= 1 || throw(ArgumentError("pivot tolerance must be in (0,1]"))
    T=promote_type(eltype(matrix),Float64)
    T in (Float64,ComplexF64) || throw(ArgumentError("linear reduction supports Float64/ComplexF64 operators"))
    original=SparseMatrixCSC{T,Int}(sparse(matrix)); original=copy(original)
    all(isfinite,original.nzval) || throw(ArgumentError("finite matrix required"))
    rows=[Dict{Int,T}() for _ in 1:n]
    for col in 1:n, slot in nzrange(original,col)
        value=original.nzval[slot]
        iszero(value) || (rows[original.rowval[slot]][col]=value)
    end
    column_rows=[Set{Int}() for _ in 1:n]
    for row in 1:n, col in keys(rows[row])
        push!(column_rows[col],row)
    end
    active_rows=trues(n); active_columns=trues(n)
    steps=AffineElimination{T}[]; introduced=0; reason=:limit
    while length(steps) < min(max_eliminations,n)
        choice=nothing; best=(typemax(Int),typemax(Int),Inf,typemax(Int),typemax(Int))
        for row in 1:n
            active_rows[row] || continue
            degree=length(rows[row]); 1 <= degree <= 2 || continue
            scale=maximum(abs,values(rows[row]))
            isfinite(scale) || continue
            for col in sort!(collect(keys(rows[row])))
                abs(rows[row][col])/scale >= pivot_tolerance || continue
                others=sort!([k for k in column_rows[col] if k != row])
                fill=sum(count(j -> j != col && !haskey(rows[k],j),keys(rows[row])) for k in others;init=0)
                fill <= max_fill || continue
                cost=(fill,degree,-abs(rows[row][col])/scale,row,col)
                if cost < best
                    best=cost; choice=(row,col,others,fill)
                end
            end
        end
        if choice === nothing
            reason=any(active_rows) ? :no_admissible_pivot : :complete
            break
        end
        row,col,others,fill=choice; pivot=rows[row][col]
        columns=sort!([j for j in keys(rows[row]) if j != col])
        coefficients=T[rows[row][j] for j in columns]
        multipliers=T[rows[k][col]/pivot for k in others]
        updated=[copy(rows[k]) for k in others]
        good=all(isfinite,multipliers)
        for (index,k) in enumerate(others)
            delete!(updated[index],col)
            for (j,coefficient) in zip(columns,coefficients)
                value=get(updated[index],j,zero(T))-multipliers[index]*coefficient
                good &= isfinite(value)
                iszero(value) ? delete!(updated[index],j) : (updated[index][j]=value)
            end
        end
        if !good
            reason=:nonfinite_update; break
        end
        push!(steps,AffineElimination(row,col,pivot,columns,coefficients,others,multipliers))
        for (k,updated_row) in zip(others,updated)
            for j in keys(rows[k])
                delete!(column_rows[j],k)
            end
            for j in keys(updated_row)
                push!(column_rows[j],k)
            end
            rows[k]=updated_row
        end
        for j in keys(rows[row])
            delete!(column_rows[j],row)
        end
        active_rows[row]=false; active_columns[col]=false; empty!(rows[row]); introduced+=fill
    end
    equations=findall(active_rows); unknowns=findall(active_columns)
    isempty(equations) && (reason=:complete)
    column_mapping=zeros(Int,n); column_mapping[unknowns]=eachindex(unknowns)
    ri=Int[]; ci=Int[]; vals=T[]
    for (i,row) in enumerate(equations), (col,value) in rows[row]
        push!(ri,i); push!(ci,column_mapping[col]); push!(vals,value)
    end
    reduced=sparse(ri,ci,vals,length(equations),length(unknowns))
    return LinearReduction(original,reduced,equations,unknowns,steps,introduced,reason)
end
function _reduction_rhs(plan::LinearReduction{T},rhs::AbstractVector) where T
    length(rhs) == size(plan.original,1) || throw(DimensionMismatch("RHS must match original matrix"))
    R=promote_type(T,eltype(rhs))
    R in (Float64,ComplexF64) || throw(ArgumentError("RHS must promote to Float64/ComplexF64"))
    work=Vector{R}(rhs)
    all(isfinite,work) || throw(ArgumentError("finite RHS required"))
    eliminated=R[]
    for step in plan.eliminations
        value=work[step.equation]; push!(eliminated,value)
        for (row,multiplier) in zip(step.affected_equations,step.multipliers)
            work[row]-=multiplier*value
        end
    end
    return (;rhs=work[plan.equations],eliminated)
end
"""Transform an original RHS into retained-equation order without modifying it."""
function reduction_rhs(plan::LinearReduction,rhs::AbstractVector)
    transformed=_reduction_rhs(plan,rhs)
    all(isfinite,transformed.rhs) && all(isfinite,transformed.eliminated) ||
        throw(LinearSolveError("affine RHS substitution overflowed"))
    return transformed.rhs
end
function _reconstruct_solution(plan::LinearReduction{T},retained,eliminated) where T
    length(retained) == length(plan.unknowns) || throw(DimensionMismatch("retained solution size"))
    R=promote_type(T,eltype(retained),eltype(eliminated))
    solution=zeros(R,size(plan.original,2)); solution[plan.unknowns]=retained
    for index in reverse(eachindex(plan.eliminations))
        step=plan.eliminations[index]; value=eliminated[index]
        for (col,coefficient) in zip(step.columns,step.coefficients)
            value-=coefficient*solution[col]
        end
        solution[step.unknown]=value/step.pivot
    end
    return solution
end
"""Reconstruct all original unknowns, including eliminated branch currents/states."""
function reconstruct_solution(plan::LinearReduction,retained::AbstractVector,rhs::AbstractVector)
    transformed=_reduction_rhs(plan,rhs)
    all(isfinite,transformed.rhs) && all(isfinite,transformed.eliminated) ||
        throw(LinearSolveError("affine RHS substitution overflowed"))
    solution=_reconstruct_solution(plan,retained,transformed.eliminated)
    all(isfinite,solution) || throw(LinearSolveError("affine reconstruction overflowed"))
    return solution
end

# Componentwise backward error, scaled per equation by binary exponents. This
# preserves weak rows and avoids overflow/underflow in individual A_ij*x_j terms.
function _linear_componentwise_error(matrix,solution,rhs)
    all(isfinite,solution) || return Inf
    n=length(rhs); exponents=fill(typemin(Int),n)
    for row in 1:n
        magnitude=abs(float(rhs[row])); isfinite(magnitude) || return Inf
        iszero(magnitude) || (exponents[row]=last(frexp(magnitude)))
    end
    for col in axes(matrix,2), slot in nzrange(matrix,col)
        a=abs(matrix.nzval[slot]); x=abs(solution[col])
        isfinite(a) && isfinite(x) || return Inf
        (iszero(a) || iszero(x)) && continue
        row=matrix.rowval[slot]
        exponents[row]=max(exponents[row],last(frexp(a))+last(frexp(x)))
    end
    T=promote_type(eltype(matrix),eltype(solution),eltype(rhs),Float64)
    residual=zeros(T,n); bounds=zeros(Float64,n)
    for row in 1:n
        magnitude=abs(float(rhs[row])); iszero(magnitude) && continue
        mantissa,exponent=frexp(magnitude)
        weight=ldexp(mantissa,exponent-exponents[row])
        residual[row]=-weight*(rhs[row]/magnitude); bounds[row]=weight
    end
    for col in axes(matrix,2), slot in nzrange(matrix,col)
        value=matrix.nzval[slot]; a=abs(value); x=abs(solution[col])
        (iszero(a) || iszero(x)) && continue
        row=matrix.rowval[slot]; am,ae=frexp(a); xm,xe=frexp(x)
        weight=ldexp(am*xm,ae+xe-exponents[row])
        residual[row]+=weight*((value/a)*(solution[col]/x))
        bounds[row]+=weight
    end
    return maximum((iszero(bounds[i]) ? abs(residual[i]) : abs(residual[i])/bounds[i] for i in 1:n);init=0.0)
end

"""Solve the reduced operator and reconstruct original-order unknowns.

Global fallback protects singular reduced pivots or unacceptable reconstruction
backward error. A changed matrix requires a new plan; only RHS reuse is supported.
"""
function solve_reduced(plan::LinearReduction,rhs::AbstractVector;fallback=:global,
        linear_solver=SuiteSparseLU(),backward_tolerance=1e-10)
    fallback in (:global,:error) || throw(ArgumentError("fallback must be :global or :error"))
    _validate_solver_options(SolverOptions(;linear_solver))
    isfinite(backward_tolerance) && backward_tolerance >= 0 || throw(ArgumentError("backward tolerance must be finite and nonnegative"))
    transformed=_reduction_rhs(plan,rhs); reason=nothing; factorizations=0
    numeric_rhs=eltype(rhs) === eltype(transformed.rhs) ? rhs : Vector{eltype(transformed.rhs)}(rhs)
    solution=zeros(eltype(transformed.rhs),size(plan.original,1))
    if !all(isfinite,transformed.rhs) || !all(isfinite,transformed.eliminated)
        fallback === :error && throw(LinearSolveError("affine RHS substitution overflowed"))
        reason=:rhs_overflow
    end
    if reason === nothing
      try
        retained=isempty(plan.unknowns) ? eltype(solution)[] : begin
            factorizations+=1
            _new_factorization(plan.reduced,linear_solver) \ transformed.rhs
        end
        solution=_reconstruct_solution(plan,retained,transformed.eliminated)
        error=_structural_backward_error(plan.original,solution,numeric_rhs)
        componentwise=_linear_componentwise_error(plan.original,solution,numeric_rhs)
        if !isfinite(error) || !isfinite(componentwise) || max(error,componentwise) > backward_tolerance
            fallback === :error && throw(LinearSolveError("affine reconstruction failed backward-error check"))
            reason=:numerical_error
        end
    catch error
        error isa LinearAlgebra.SingularException || rethrow()
        fallback === :error && rethrow()
        reason=:singular_reduced_system
      end
    end
    if reason !== nothing
        factorizations+=1
        solution=_new_factorization(plan.original,linear_solver) \ numeric_rhs
    end
    error=_structural_backward_error(plan.original,solution,numeric_rhs)
    componentwise=_linear_componentwise_error(plan.original,solution,numeric_rhs)
    all(isfinite,solution) && isfinite(error) && isfinite(componentwise) || throw(LinearSolveError("reduced solve produced an unassessable solution"))
    return (;solution,stats=(;strategy=reason === nothing ? :affine_reduction : :global,
        fallback_reason=reason,eliminated=length(plan.eliminations),retained=length(plan.unknowns),
        introduced_entries=plan.introduced_entries,stopped_reason=plan.stopped_reason,
        factorizations,backward_error=error,componentwise_error=componentwise,
        converged=max(error,componentwise) <= backward_tolerance))
end

"""
    reduced_operating_point(circuit; temperature=300.0, max_fill=0, max_eliminations=typemax(Int))

Experimental direct DC solve for circuits whose compiled device contracts are
linear. Reconstructs all solver unknowns into a normal `SimulationResult`, so
voltage/current/power accessors retain their original identities. Nonlinear
circuits are rejected. This does not transform transient, AC, or noise equations.
"""
function reduced_operating_point(circuit;temperature=300.0,max_fill=0,
        max_eliminations=typemax(Int),pivot_tolerance=1e-12,
        linear_solver=SuiteSparseLU(),backward_tolerance=1e-10,fallback=:global)
    cc=compile(circuit)
    _all_linear(cc.parameters.batches) || throw(ArgumentError("reduced operating point requires linear device contracts"))
    temperature=Float64(_si_value(temperature,Unitful.K))
    isfinite(temperature) && temperature > 0 || throw(AnalysisValidationError("temperature must be finite and positive"))
    workspace=SimulationWorkspace(cc); x=zeros(cc.n)
    residual,jacobian=residual_jacobian!(workspace,cc,x,x,0.0,0.0;mode=:dc,temperature)
    plan=reduce_linear_system(jacobian;max_fill,max_eliminations,pivot_tolerance)
    solved=solve_reduced(plan,-residual;linear_solver,backward_tolerance,fallback)
    stats=Dict{Symbol,Any}(:converged=>solved.stats.converged,
        :iterations=>1,:strategy=>:linear_reduction,:reduction=>solved.stats,
        :temperature=>temperature,:warnings=>String[])
    solved.stats.converged || push!(stats[:warnings],"linear solution did not meet normwise/componentwise residual tolerances")
    _finalize_stats!(stats)
    return SimulationResult(cc,OperatingPoint(;temperature,solver=SolverOptions(;linear_solver)),
        [0.0],reshape(solved.solution,:,1),stats)
end
