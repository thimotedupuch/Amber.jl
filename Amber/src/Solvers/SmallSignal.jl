function _small_signal_frequencies(specification; points, scale)
    if specification isa Pair
        specification = _si_value(first(specification), Unitful.Hz) => _si_value(last(specification), Unitful.Hz)
        _validate_frequency_range(specification, points, scale)
        first(specification) == last(specification)&&return [Float64(first(specification))]
        return scale === :log ? collect(10 .^ range(log10(first(specification)), log10(last(specification)), length = points)) : collect(range(first(specification), last(specification), length = points))
    end
    return _validate_frequency_grid(specification)
end

# The compiler keeps a bias-independent union pattern. Slots that are exactly
# zero in both derivatives cannot contribute at any frequency in this sweep.
# Compact them together so symbolic LU does not process inactive device edges.
function _small_signal_compact_jacobians(Jz, Jd)
    keep = map((z, d) -> !iszero(z) || !iszero(d), Jz.nzval, Jd.nzval)
    all(keep) && return Jz, Jd
    colptr = Vector{Int}(undef, size(Jz, 2) + 1)
    colptr[1] = 1
    for col in 1:size(Jz, 2)
        colptr[col + 1] = colptr[col] + count(view(keep, nzrange(Jz, col)))
    end
    rows = Jz.rowval[keep]
    return SparseMatrixCSC(size(Jz)..., colptr, rows, Jz.nzval[keep]),
        SparseMatrixCSC(size(Jd)..., copy(colptr), copy(rows), Jd.nzval[keep])
end

# A connected path in the union sparsity pattern admits a symmetric
# permutation to tridiagonal form, even for nonsymmetric numerical values.
function _small_signal_path(system)
    n = size(system, 1)
    neighbors = [Int[] for _ in 1:n]
    for col in 1:n, slot in nzrange(system, col)
        row = system.rowval[slot]
        row == col && continue
        col in neighbors[row] || push!(neighbors[row], col)
        row in neighbors[col] || push!(neighbors[col], row)
        (length(neighbors[row]) > 2 || length(neighbors[col]) > 2) && return nothing
    end
    n == 1 && return [1]
    start = findfirst(v -> length(v) == 1, neighbors)
    start === nothing && return nothing
    order = Int[]; previous = 0; current = start
    while current != 0
        push!(order, current)
        next = 0
        for neighbor in neighbors[current]
            neighbor == previous || (next = neighbor)
        end
        previous, current = current, next
    end
    return length(order) == n ? order : nothing
end

function _small_signal_path_sweep!(vals, fs, system, Jz, Jd, b, order)
    n = length(order); inverse = invperm(order)
    matrix = Tridiagonal(zeros(ComplexF64, n-1), zeros(ComplexF64, n), zeros(ComplexF64, n-1))
    rhs = b[order]; solution = similar(rhs)
    for (j, f) in enumerate(fs)
        fill!(matrix.dl, 0); fill!(matrix.d, 0); fill!(matrix.du, 0)
        for col in 1:n, slot in nzrange(system, col)
            row = system.rowval[slot]
            i, k = inverse[row], inverse[col]
            value = Jz.nzval[slot] + im * 2π * f * Jd.nzval[slot]
            if i == k
                matrix.d[i] = value
            elseif i == k + 1
                matrix.dl[k] = value
            else
                matrix.du[i] = value
            end
        end
        try
            # Pivoted LU handles zero diagonal entries from ideal sources.
            factors = lu!(matrix)
            ldiv!(solution, factors, rhs)
        catch error
            error isa LinearAlgebra.SingularException || rethrow()
            throw(LinearSolveError("small-signal matrix is singular at $(f) Hz"))
        end
        for i in 1:n
            vals[order[i], j] = solution[i]
        end
    end
    return vals
end

function small_signal(c, p::Union{Pair, AbstractVector}; points = p isa AbstractVector ? length(p) : 100, scale = :log, source = nothing, temperature = 300.0, solver = nothing, kw...)
    automatic_solver = solver === nothing
    solver = automatic_solver ? SolverOptions() : solver
    temperature = _si_value(temperature, Unitful.K)
    isfinite(temperature)&&temperature > 0||throw(AnalysisValidationError("temperature must be finite and positive"))
    cc = compile(c); operating_point_result = _require_converged(operating_point(cc; temperature, solver, kw...), "small-signal operating point"); op = operating_point_result.values[:, 1]
    fs = _small_signal_frequencies(p; points, scale)
    warnings = String[]
    active = String[]
    source_kinds = Dict{String, Symbol}()
    source_amplitudes = Dict{String, Any}()
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch||continue; kind = _batch_kind(batch)
        kind in (:voltage_source, :current_source)||continue
        for device in eachindex(batch.parameters)
            instance_name, device_name = _locator_device_name(cc.design, batch.locators[device])
            path = isempty(instance_name) ? device_name : string(instance_name, '.', device_name)
            source_kinds[path] = kind; source_amplitudes[path] = get(batch.parameters[device], :ac, 0.0)
            iszero(source_amplitudes[path])||push!(active, path)
        end
    end
    if source === nothing&&length(active) > 1
        throw(ArgumentError("multiple AC sources are active ($(join(active, ", "))); select source=... explicitly"))
    elseif source !== nothing
        path = String(source); haskey(source_kinds, path)||throw(ArgumentError("unknown small-signal source $(source)"))
        iszero(source_amplitudes[path])&&push!(warnings, "selected source $(source) has zero AC excitation")
    elseif isempty(active)
        push!(warnings, "the circuit has no nonzero AC excitation")
    end
    vals = zeros(ComplexF64, cc.n, length(fs)); Jz, Jd = _static_dynamic_jacobians(cc, op; mode = :dc, temperature); b = ac_excitation(cc; source)
    Jz, Jd = _small_signal_compact_jacobians(Jz, Jd)
    # Both derivatives share the reduced union pattern: retain any slot that
    # is nonzero in either derivative. Frequency changes values only, so the
    # symbolic analysis remains reusable across the complete sweep.
    system = SparseMatrixCSC{ComplexF64, Int}(
        cc.n, cc.n, copy(Jz.colptr), copy(Jz.rowval),
        zeros(ComplexF64, length(Jz.nzval))
    )
    path = automatic_solver ? _small_signal_path(system) : nothing
    if path !== nothing
        _small_signal_path_sweep!(vals, fs, system, Jz, Jd, b, path)
    else
        factorization = nothing
        for (j, f) in enumerate(fs)
            @. system.nzval = Jz.nzval + im * 2π * f * Jd.nzval
            try
                factorization = factorization === nothing ? _new_factorization(system, solver.linear_solver) :
                    lu!(factorization, system; reuse_symbolic = true)
                ldiv!(view(vals, :, j), factorization, b)
            catch error
                error isa LinearAlgebra.SingularException || rethrow()
                throw(LinearSolveError("small-signal matrix is singular at $(f) Hz"))
            end
        end
    end
    analysis = SmallSignal(fs; source, temperature = Float64(temperature), solver = operating_point_result.analysis.solver)
    stats = _finalize_stats!(Dict{Symbol, Any}(:converged => true, :temperature => Float64(temperature), :warnings => warnings, :source => source, :active_sources => active, :operating_point => copy(op)))
    stats[:linear_backend] = path === nothing ? :suitesparse : :tridiagonal
    stats[:symbolic_factorizations] = isempty(fs) ? 0 : 1
    stats[:numeric_factorizations] = length(fs)
    return SimulationResult(cc, analysis, Float64.(fs), vals, stats)
end

simulate(c, a::SmallSignal) = small_signal(c, a.frequencies; source = a.source, temperature = a.temperature, solver = a.solver)
run(c, analyses::AbstractVector{<:AbstractAnalysis}) = map(a -> simulate(c, a), analyses)
