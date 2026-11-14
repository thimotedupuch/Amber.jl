"""Reusable symbolic metadata; numerical workspaces own all mutable solve buffers."""
struct CompiledSolvePlan{S<:AbstractLinearSolver,P}
    topology::HierarchicalCompiledTopology
    n::Int
    colptr::Vector{Int}
    rowval::Vector{Int}
    variable_scales::Vector{Float64}
    solver::S
    structural::P
end
function compiled_solve_plan(cc::CompiledCircuit;linear_solver=SuiteSparseLU(),structural=false,mode=:dc)
    scales=ones(cc.n)
    for (i,kind) in enumerate(cc.topology.layout.kinds)
        kind === BranchCurrentUnknown && (scales[i]=1e-3)
    end
    blocks=structural ? structural_solve_plan(cc;mode) : nothing
    CompiledSolvePlan(cc.topology,cc.n,copy(cc.topology.pattern.colptr),
        copy(cc.topology.pattern.rowval),scales,linear_solver,blocks)
end
struct FactorizationKey
    topology::HierarchicalCompiledTopology
    coefficients::MatrixCacheIdentity
    alpha::Float64
    mode::Symbol
    gmin::Float64
    solver::AbstractLinearSolver
end
