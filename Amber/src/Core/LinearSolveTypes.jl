"""Policy interface for sparse linear solvers used by Newton iterations."""
abstract type AbstractLinearSolver end

"""SuiteSparse UMFPACK LU policy with reusable symbolic analysis."""
Base.@kwdef struct SuiteSparseLU <: AbstractLinearSolver
    ordering::Symbol = :amd
    pivot_tolerance::Float64 = 0.1
    function SuiteSparseLU(
            ordering, pivot_tolerance
        )
        return new(
            _analysis_parameter(:ordering, ordering),
            _analysis_parameter(:pivot_tolerance, pivot_tolerance)
        )
    end
end
