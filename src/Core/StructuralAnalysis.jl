"""Equation incidence, maximum matching, and dependency-ordered equation blocks.

`equation_to_unknown` and `unknown_to_equation` use zero for unmatched entries.
`blocks` contains equation indices, with prerequisites preceding dependants.
A full structural rank is necessary, but does not establish numerical rank.
"""
struct StructuralAnalysis
    mode::Symbol
    incidence::SparseMatrixCSC{Bool, Int}
    equation_to_unknown::Vector{Int}
    unknown_to_equation::Vector{Int}
    unmatched_equations::Vector{Int}
    unmatched_unknowns::Vector{Int}
    blocks::Vector{Vector{Int}}
end

# Iterative augmenting paths avoid recursion proportional to circuit size.
function _structural_matching(rows, n)
    equation_to_unknown = zeros(Int, n); unknown_to_equation = zeros(Int, n)
    seen = zeros(Int, n); parent = zeros(Int, n); queue = Int[]
    for start in 1:n
        empty!(queue); push!(queue, start)
        head = 1; endpoint = 0
        while head <= length(queue) && endpoint == 0
            row = queue[head]; head += 1
            for column in rows[row]
                seen[column] == start && continue
                seen[column] = start; parent[column] = row
                if unknown_to_equation[column] == 0
                    endpoint = column; break
                end
                push!(queue, unknown_to_equation[column])
            end
        end
        while endpoint != 0
            row = parent[endpoint]
            previous = equation_to_unknown[row]
            equation_to_unknown[row] = endpoint; unknown_to_equation[endpoint] = row
            endpoint = previous
        end
    end
    return equation_to_unknown, unknown_to_equation
end

function _equation_blocks(rows, unknown_to_equation)
    n = length(rows); graph = [Int[] for _ in 1:n]; reverse_graph = [Int[] for _ in 1:n]
    for row in 1:n, column in rows[row]
        dependency = unknown_to_equation[column]
        (dependency == 0 || dependency == row) && continue
        push!(graph[dependency], row); push!(reverse_graph[row], dependency)
    end
    # Iterative Kosaraju traversal, with edges from prerequisites to dependants.
    visited = falses(n); finish = Int[]; stack = Tuple{Int, Int}[]
    for start in 1:n
        visited[start] && continue
        visited[start] = true; push!(stack, (start, 1))
        while !isempty(stack)
            node, next = stack[end]
            if next > length(graph[node])
                pop!(stack); push!(finish, node)
            else
                stack[end] = (node, next + 1); neighbor = graph[node][next]
                visited[neighbor] && continue
                visited[neighbor] = true; push!(stack, (neighbor, 1))
            end
        end
    end
    fill!(visited, false); pending = Int[]; blocks = Vector{Int}[]
    for start in Iterators.reverse(finish)
        visited[start] && continue
        block = Int[]; push!(pending, start); visited[start] = true
        while !isempty(pending)
            node = pop!(pending); push!(block, node)
            for neighbor in reverse_graph[node]
                visited[neighbor] && continue
                visited[neighbor] = true; push!(pending, neighbor)
            end
        end
        push!(blocks, sort!(block))
    end
    return blocks
end

# Nonlinear incidence is a conservative union of the device's possible states.
# Exclude padded behavioral controls and known absent conduction/storage rows.
function _nonlinear_dependency(kind, parameters, row, column, mode)
    if kind in (:behavioral_current_source, :behavioral_voltage_source)
        return column <= 2 || column > 10 || column <= 2 + 2parameters.control_count
    elseif kind === :switch
        return column <= 2 || parameters.model isa SmoothSwitch
    elseif kind in (:nmos, :pmos)
        model = parameters.model
        if model isa ChargeBasedMOSFET
            mode === :time && return true
            row == 2 && return false # insulated gate
            return row != 4 || model.junction_saturation_current_density != 0 &&
                (model.drain_area != 0 || model.source_area != 0)
        end
        mode === :time && return true
        return row in (1, 3)
    end
    return true
end

"""
    structural_analysis(circuit; mode=:dc) -> StructuralAnalysis

Inspect equation/unknown matching and strongly connected equation blocks.
`mode=:time` includes storage dependencies. Linear incidence uses the actual
constant coefficients; nonlinear incidence conservatively includes possible
branches, independent of the current operating point. Regularization diagonals
are excluded. A complete matching does not rule out algebraic cancellation or
numerical singularity. This inspection does not transform equations or perform
DAE index reduction.
"""
function structural_analysis(circuit; mode = :dc)
    mode in (:dc, :time) || throw(ArgumentError("structural analysis mode must be :dc or :time"))
    cc = compile(circuit); n = cc.n
    g = SparseMatrixCSC{Float64, Int}(cc.topology.pattern); c = copy(g)
    zero_state = zeros(n)
    buffers = (; residual = zeros(n), jacobian = g, storage = zeros(n), storage_jacobian = c)
    _constant_batches!(buffers, cc.parameters.batches, zero_state)
    rows = [Int[] for _ in 1:n]
    for column in 1:n, pointer in nzrange(g, column)
        (!iszero(g.nzval[pointer]) || mode === :time && !iszero(c.nzval[pointer])) &&
            push!(rows[g.rowval[pointer]], column)
    end
    for batch in cc.parameters.batches
        _linear_batch(batch) && continue
        kind = _batch_kind(batch)
        for device in eachindex(batch.parameters)
            terminals = ntuple(i -> batch.terminals[i][device], length(batch.terminals))
            branch = batch.branch_unknowns[device]; states = batch.state_unknowns[device]
            control = batch.control_unknowns[device]
            for (local_row, local_column) in _DEVICE_STAMP_PLANS[kind].positions
                _nonlinear_dependency(kind, batch.parameters[device], local_row, local_column, mode) || continue
                row = _stamp_unknown(local_row, terminals, branch, states, control)
                column = _stamp_unknown(local_column, terminals, branch, states, control)
                (row == 0 || column == 0) || push!(rows[row], column)
            end
        end
    end
    foreach(row -> sort!(unique!(row)), rows)
    equation_to_unknown, unknown_to_equation = _structural_matching(rows, n)
    row_indices = Int[]; column_indices = Int[]
    for row in 1:n, column in rows[row]
        push!(row_indices, row); push!(column_indices, column)
    end
    incidence = sparse(row_indices, column_indices, fill(true, length(row_indices)), n, n)
    return StructuralAnalysis(
        mode, incidence, equation_to_unknown, unknown_to_equation,
        findall(iszero, equation_to_unknown), findall(iszero, unknown_to_equation),
        _equation_blocks(rows, unknown_to_equation)
    )
end
