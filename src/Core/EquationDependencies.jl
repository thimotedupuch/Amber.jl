# Dependency information for the experimental constitutive IR. Independent from
# DeviceDependencies: that existing cache contract must not be weakened implicitly.
const _EQUATION_DEPENDENCY_KINDS = (:topology, :parameter, :temperature, :time, :state, :mode)
struct EquationDependencies{N}
    inputs::NTuple{N,Symbol}
    mask::UInt8
end
function _equation_dependencies(expression::ConstitutiveExpr, roles::NamedTuple)
    inputs = _equation_inputs(expression)
    mask = UInt8(0)
    for name in inputs
        hasproperty(roles,name) || throw(ArgumentError("missing dependency role for $name"))
        role = getproperty(roles,name)
        index = findfirst(==(role),_EQUATION_DEPENDENCY_KINDS)
        index === nothing && throw(ArgumentError("unsupported dependency role $role for $name"))
        mask |= UInt8(1) << (index-1)
    end
    return EquationDependencies(inputs,mask)
end
function _depends_on(dependencies::EquationDependencies, kind::Symbol)
    index = findfirst(==(kind),_EQUATION_DEPENDENCY_KINDS)
    index === nothing && throw(ArgumentError("unsupported dependency kind $kind"))
    return !iszero(dependencies.mask & (UInt8(1) << (index-1)))
end
# Coarse scheduling hint only: the complete input set remains authoritative.
# In particular an expression involving both mode and time must be invalidated
# for changes to either input; the stage alone must never be used as a cache key.
function _equation_stage(dependencies::EquationDependencies)
    _depends_on(dependencies,:state) && return :iteration
    _depends_on(dependencies,:mode) && return :mode
    _depends_on(dependencies,:time) && return :time
    (_depends_on(dependencies,:parameter) || _depends_on(dependencies,:temperature)) && return :configuration
    _depends_on(dependencies,:topology) && return :topology
    return :constant
end
function _constitutive_dependencies(kernel::ConstitutiveKernel, roles::NamedTuple)
    return (; current=_equation_dependencies(kernel.law.current,roles),
        charge=_equation_dependencies(kernel.law.charge,roles),
        derivatives=map(d -> (;current=_equation_dependencies(d.current,roles),
            charge=_equation_dependencies(d.charge,roles)),kernel.derivatives))
end
"""Whether a compiled expression must be recomputed for changed input names.

Uses exact input names, retaining predicates in piecewise expressions. Numerical
caches are not yet connected to this experimental analysis.
"""
_equation_invalidated(dependencies::EquationDependencies, changed) = any(name -> name in dependencies.inputs,changed)
