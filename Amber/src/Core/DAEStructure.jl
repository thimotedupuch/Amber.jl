"""Storage incidence and optional local numerical descriptor analysis.

Numerical coordinates satisfy x = y ./ column_divisors. `classification` is a
local rank test, not a proof of a nonlinear DAE's differentiation index. Dense
numerical analysis is explicitly size-bounded; structural inspection stays sparse.
"""
struct DAEStructure
    storage_incidence::SparseMatrixCSC{Bool,Int}
    structural_storage_rank::Int
    algebraic_rows::Vector{Int}
    storage_columns::Vector{Int}
    numerical_storage_rank::Union{Nothing,Int}
    storage_singular_values::Vector{Float64}
    rank_roundoff_floor::Float64
    classification::Symbol
    row_divisors::Vector{Float64}
    column_divisors::Vector{Float64}
    left_dynamic::Matrix{Float64}
    left_algebraic::Matrix{Float64}
    right_dynamic::Matrix{Float64}
    scaled_static::Matrix{Float64}
    scaled_storage::Matrix{Float64}
end
function _dae_row_scale(matrix)
    divisors=[maximum(abs,view(matrix,row,:);init=0.0) for row in axes(matrix,1)]
    replace!(divisors,0.0=>1.0)
    return matrix ./ divisors, divisors
end
function _dae_rank(matrix,rtol)
    isempty(matrix) && return 0
    scaled,_=_dae_row_scale(matrix)
    columns=[maximum(abs,view(scaled,:,column);init=0.0) for column in axes(scaled,2)]
    replace!(columns,0.0=>1.0)
    values=svdvals(scaled ./ transpose(columns))
    isempty(values) && return 0
    return count(value -> value > rtol*maximum(values),values)
end
"""
    dae_structure(circuit; state=nothing, numerical=false, dense_limit=512, rank_rtol=1e-10)

Inspect q_x storage incidence separately from f_x. Optional equilibrated SVD
analysis identifies independent storage coordinates and tests the algebraic
constraint Jacobian. Nonlinear numerical results are local to the supplied state.
"""
function dae_structure(circuit;state=nothing,numerical=false,dense_limit=512,
        rank_rtol=1e-10,temperature=300.0)
    isfinite(rank_rtol) && 0 < rank_rtol < 1 || throw(ArgumentError("rank tolerance must lie in (0,1)"))
    dense_limit isa Integer && dense_limit >= 0 || throw(ArgumentError("dense_limit must be nonnegative"))
    cc=compile(circuit); point=state === nothing ? zeros(cc.n) : Float64.(state)
    length(point) == cc.n || throw(DimensionMismatch("DAE state must match circuit"))
    all(isfinite,point) || throw(ArgumentError("finite DAE state required"))
    temperature=Float64(_si_value(temperature,Unitful.K))
    isfinite(temperature) && temperature > 0 || throw(ArgumentError("positive finite temperature required"))
    g,e=_static_dynamic_jacobians(cc,point;temperature)
    all(isfinite,g.nzval) && all(isfinite,e.nzval) || throw(AnalysisValidationError("nonfinite descriptor coefficients"))
    # Actual coefficients are used; zero padding in the common CSC pattern is
    # never interpreted as storage incidence.
    incidence=map(!iszero,e); dropzeros!(incidence)
    rows=[Int[] for _ in 1:cc.n]
    for col in 1:cc.n, slot in nzrange(incidence,col)
        push!(rows[incidence.rowval[slot]],col)
    end
    matched,_=_structural_matching(rows,cc.n)
    algebraic=findall(isempty,rows)
    columns=[col for col in 1:cc.n if !isempty(nzrange(incidence,col))]
    if !numerical
        return DAEStructure(incidence,count(!iszero,matched),algebraic,columns,nothing,Float64[],0.0,
            :structural_only,Float64[],Float64[],zeros(0,0),zeros(0,0),zeros(0,0),zeros(0,0),zeros(0,0))
    end
    cc.n <= dense_limit || throw(ArgumentError("numerical DAE analysis exceeds dense_limit; use sparse structural inspection"))
    eh,row_divisors=_dae_row_scale(Matrix(e))
    column_divisors=[maximum(abs,view(eh,:,col);init=0.0) for col in 1:cc.n]
    replace!(column_divisors,0.0=>1.0)
    eh ./= transpose(column_divisors)
    gh=(Matrix(g) ./ row_divisors) ./ transpose(column_divisors)
    all(isfinite,eh) && all(isfinite,gh) || throw(AnalysisValidationError("descriptor scaling overflowed"))
    decomposition=svd(eh;full=true)
    rank=isempty(decomposition.S) ? 0 : count(s -> s > rank_rtol*maximum(decomposition.S),decomposition.S)
    left_dynamic=decomposition.U[:,1:rank]; left_algebraic=decomposition.U[:,rank+1:end]
    right_dynamic=decomposition.V[:,1:rank]
    constraints=vcat(transpose(right_dynamic),transpose(left_algebraic)*gh)
    largest=maximum(decomposition.S;init=0.0)
    roundoff=8max(cc.n,1)*eps(Float64)*largest
    ambiguous=any(s -> roundoff < s <= rank_rtol*largest,decomposition.S)
    # Retaining modes beneath the numerical roundoff floor is also unsafe.
    rank_rtol*largest < roundoff && (ambiguous=true)
    classification=ambiguous ? :rank_ambiguous : _dae_rank(constraints,rank_rtol) == cc.n ?
        (rank == cc.n ? :ode : rank == 0 ? :algebraic : :linear_index_one_candidate) : :requires_constraint_analysis
    return DAEStructure(incidence,count(!iszero,matched),algebraic,columns,rank,copy(decomposition.S),roundoff,
        classification,row_divisors,column_divisors,left_dynamic,left_algebraic,right_dynamic,gh,eh)
end

function _dae_waveform_derivative(w::Sine,time)
    return 2pi*w.frequency*w.amplitude*cos(2pi*w.frequency*time+w.phase)
end
function _dae_waveform_derivative(w::Step,time)
    (time == w.at || w.rise > 0 && time == w.at+w.rise) &&
        throw(AnalysisValidationError("initialization at a waveform corner requires an explicit forcing_derivative"))
    return w.rise > 0 && w.at < time < w.at+w.rise ? (w.high-w.low)/w.rise : 0.0
end
function _dae_waveform_derivative(w::Pulse,time)
    time < w.delay && return 0.0
    phase=mod(time-w.delay,inv(w.frequency)); on=w.duty_cycle/w.frequency
    phase in (0.0,w.rise,on,on+w.fall) &&
        throw(AnalysisValidationError("initialization at a waveform corner requires an explicit forcing_derivative"))
    return phase < w.rise && w.rise > 0 ? (w.high-w.low)/w.rise :
        on < phase < on+w.fall && w.fall > 0 ? (w.low-w.high)/w.fall : 0.0
end
_dae_waveform_derivative(w,time)=throw(AnalysisValidationError("provide forcing_derivative for this waveform"))
function _dae_forcing_derivative(cc,time)
    derivative=zeros(cc.n)
    for batch in cc.parameters.batches
        _has_forcing(batch) || continue
        for device in eachindex(batch.parameters)
            w=get(batch.parameters[device],:waveform,nothing)
            w === nothing && continue
            value=_dae_waveform_derivative(w,time)
            if _batch_kind(batch) === :voltage_source
                derivative[Int(batch.branch_unknowns[device])]-=value
            else
                _workspace_add!(derivative,batch.terminals[1][device],value)
                _workspace_add!(derivative,batch.terminals[2][device],-value)
            end
        end
    end
    return derivative
end
function _dae_condition_digest(state,derivative,forcing_derivative)
    io=IOBuffer(); _fingerprint_value!(io,(state,derivative,forcing_derivative))
    return _parameter_digest(io)
end
struct DAEInitialCondition <: AbstractInitialCondition
    state::Vector{Float64}
    derivative::Vector{Float64}
    forcing_derivative::Vector{Float64}
    circuit_fingerprint::String
    temperature::Float64
    time::Float64
    fingerprint::UInt128
    stats::NamedTuple
end
function _dae_linear_solve(matrix,rhs,context,tolerance)
    scaled,divisors=_dae_row_scale(matrix)
    result=try
        scaled \ (rhs ./ divisors)
    catch error
        error isa LinearAlgebra.SingularException || rethrow()
        throw(AnalysisValidationError("$context requires constraint analysis; no consistent index-one solve available"))
    end
    err=_linear_componentwise_error(sparse(matrix),result,rhs)
    all(isfinite,result) && isfinite(err) && err <= tolerance ||
        throw(AnalysisValidationError("$context failed componentwise residual check"))
    return result
end
"""
    consistent_initial_conditions(circuit, guess; time=0, temperature=300, ...)

For linear device contracts, preserve independent storage coordinates of `guess`
and solve algebraic constraints, then determine a consistent derivative using
both original equations and differentiated algebraic constraints. Higher-index,
rank-ambiguous, and nonlinear systems are rejected. Dense analysis is size bounded.
`forcing_derivative` is d(f(0,t))/dt in original equation order (numeric SI).
"""
function consistent_initial_conditions(circuit,guess::AbstractVector;time=0.0,temperature=300.0,
        rank_rtol=1e-10,tolerance=1e-9,dense_limit=512,forcing_derivative=nothing)
    cc=compile(circuit)
    _all_linear(cc.parameters.batches) || throw(AnalysisValidationError("consistent initialization currently requires linear device contracts"))
    isfinite(tolerance) && 0 < tolerance < 1 || throw(ArgumentError("initialization tolerance must lie in (0,1)"))
    time=Float64(_si_value(time,Unitful.s)); temperature=Float64(_si_value(temperature,Unitful.K))
    isfinite(time) || throw(ArgumentError("finite initialization time required"))
    info=dae_structure(cc;state=guess,numerical=true,dense_limit,rank_rtol,temperature)
    info.classification in (:requires_constraint_analysis,:rank_ambiguous) &&
        throw(AnalysisValidationError("descriptor constraints are higher-index or rank-ambiguous; consistent initialization would require constraint differentiation"))
    workspace=SimulationWorkspace(cc); zero_state=zeros(cc.n)
    forcing=copy(residual!(workspace,cc,zero_state,zero_state,time;temperature))
    derivative=forcing_derivative === nothing ? _dae_forcing_derivative(cc,time) : Float64.(forcing_derivative)
    length(derivative) == cc.n || throw(DimensionMismatch("forcing derivative size"))
    all(isfinite,derivative) || throw(ArgumentError("finite forcing derivative required"))
    bh=forcing ./ info.row_divisors; bdh=derivative ./ info.row_divisors
    vd=transpose(info.right_dynamic); la=transpose(info.left_algebraic); ld=transpose(info.left_dynamic)
    constraints=la*info.scaled_static
    preserved=vd*(Float64.(guess).*info.column_divisors)
    state_matrix=vcat(vd,constraints)
    y=_dae_linear_solve(state_matrix,vcat(preserved,-la*bh),"state initialization",tolerance)
    velocity_matrix=vcat(ld*info.scaled_storage,constraints)
    yh_dot=_dae_linear_solve(velocity_matrix,
        vcat(-ld*(info.scaled_static*y+bh),-la*bdh),"derivative initialization",tolerance)
    state=y ./ info.column_divisors; velocity=yh_dot ./ info.column_divisors
    g,e=_static_dynamic_jacobians(cc,state;temperature)
    residual_error=_linear_componentwise_error(hcat(g,e),vcat(state,velocity),-forcing)
    isfinite(residual_error) && residual_error <= tolerance ||
        throw(AnalysisValidationError("initialized derivative violates original DAE equations"))
    stats=(;classification=info.classification,storage_rank=info.numerical_storage_rank,
        structural_storage_rank=info.structural_storage_rank,componentwise_error=residual_error,
        tolerance,rank_rtol)
    return DAEInitialCondition(state,velocity,derivative,cc.fingerprint,temperature,time,
        _dae_condition_digest(state,velocity,derivative),stats)
end
function _validated_dae_initial_state(cc,condition::DAEInitialCondition,time,temperature)
    condition.circuit_fingerprint == cc.fingerprint || throw(AnalysisValidationError("DAE initial condition belongs to different circuit parameters"))
    condition.time == time && condition.temperature == temperature ||
        throw(AnalysisValidationError("DAE initial condition time/temperature mismatch"))
    condition.fingerprint == _dae_condition_digest(condition.state,condition.derivative,condition.forcing_derivative) ||
        throw(AnalysisValidationError("DAE initial condition was mutated; recompute consistent initialization"))
    return copy(condition.state)
end
