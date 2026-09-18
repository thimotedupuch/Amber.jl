abstract type AbstractAnalysis end

"""Policy interface for sparse linear solvers used by Newton iterations."""
abstract type AbstractLinearSolver end

"""SuiteSparse UMFPACK LU policy with reusable symbolic analysis."""
Base.@kwdef struct SuiteSparseLU <: AbstractLinearSolver
    ordering::Symbol = :amd
    pivot_tolerance::Float64 = 0.1
end

"""
    SolverOptions(; reltol=1e-7, voltage_abstol=1e-9, current_abstol=1e-12,
        state_abstol=1e-10, max_newton_iterations=60,
        line_search_minimum=1/256, continuation_maxdepth=10,
        linear_solver=SuiteSparseLU())

Configure nonlinear convergence, damping, and DC continuation. Absolute voltage
and current tolerances are in V and A; internal-state tolerances use each state's
units. Relative tolerance is dimensionless. These settings govern Newton solves,
not adaptive transient truncation error; use [`IntegrationOptions`](@ref) for
that. Increasing iteration limits does not repair invalid circuit topology.

```julia
solver = SolverOptions(reltol=1e-8, voltage_abstol=1nV)
op = operating_point(circuit; solver)
```

Pass options directly to an analysis function or store them in an analysis
descriptor, e.g. `OperatingPoint(; solver)`. Direct `reltol`, `abstol`, and
`maxiters` keywords override corresponding fields where supported. A scalar
`abstol` overrides voltage/current/state absolute tolerances together; use this
type when you need different absolute scales.
"""
Base.@kwdef struct SolverOptions
    reltol::Float64 = 1e-7
    voltage_abstol::Float64 = 1e-9
    current_abstol::Float64 = 1e-12
    state_abstol::Float64 = 1e-10
    max_newton_iterations::Int = 60
    line_search_minimum::Float64 = 1 / 256
    continuation_maxdepth::Int = 10
    linear_solver::AbstractLinearSolver = SuiteSparseLU()
end

function _validate_solver_options(options::SolverOptions)
    isfinite(options.reltol) && options.reltol > 0 ||
        throw(AnalysisValidationError("solver reltol must be finite and positive"))
    for (name, value) in (("voltage_abstol", options.voltage_abstol),
            ("current_abstol", options.current_abstol), ("state_abstol", options.state_abstol))
        isfinite(value) && value > 0 ||
            throw(AnalysisValidationError("solver $name must be finite and positive"))
    end
    options.max_newton_iterations > 0 ||
        throw(AnalysisValidationError("max_newton_iterations must be positive"))
    isfinite(options.line_search_minimum) && 0 < options.line_search_minimum <= 1 ||
        throw(AnalysisValidationError("line_search_minimum must lie in (0, 1]"))
    options.continuation_maxdepth >= 0 ||
        throw(AnalysisValidationError("continuation_maxdepth must be non-negative"))
    if options.linear_solver isa SuiteSparseLU
        options.linear_solver.ordering in (:amd, :natural) ||
            throw(AnalysisValidationError("SuiteSparseLU ordering must be :amd or :natural"))
        isfinite(options.linear_solver.pivot_tolerance) &&
            0 <= options.linear_solver.pivot_tolerance <= 1 ||
            throw(AnalysisValidationError("SuiteSparseLU pivot_tolerance must lie in [0, 1]"))
    end
    options
end

function _solver_values(options::SolverOptions; reltol=nothing, abstol=nothing,
        maxiters=nothing, continuation_maxdepth=nothing)
    _validate_solver_options(options)
    resolved_reltol = something(reltol, options.reltol)
    resolved_abstol = something(abstol, options.current_abstol)
    resolved_maxiters = something(maxiters, options.max_newton_iterations)
    resolved_maxiters > 0 || throw(AnalysisValidationError("maxiters must be positive"))
    resolved_depth = something(continuation_maxdepth, options.continuation_maxdepth)
    isfinite(resolved_reltol) && resolved_reltol > 0 ||
        throw(AnalysisValidationError("reltol must be finite and positive"))
    isfinite(resolved_abstol) && resolved_abstol > 0 ||
        throw(AnalysisValidationError("abstol must be finite and positive"))
    resolved_depth >= 0 ||
        throw(AnalysisValidationError("continuation_maxdepth must be non-negative"))
    resolved_reltol, resolved_abstol, resolved_maxiters, resolved_depth
end

function _effective_solver(options::SolverOptions;reltol=nothing,abstol=nothing,
        maxiters=nothing,continuation_maxdepth=nothing)
    r,a,m,d=_solver_values(options;reltol,abstol,maxiters,continuation_maxdepth)
    SolverOptions(reltol=r,current_abstol=a,
        voltage_abstol=something(abstol,options.voltage_abstol),
        state_abstol=something(abstol,options.state_abstol),
        max_newton_iterations=m,continuation_maxdepth=d,
        line_search_minimum=options.line_search_minimum,linear_solver=options.linear_solver)
end

"""
    IntegrationOptions(; reltol=1e-4, voltage_abstol=1e-7,
        current_abstol=1e-10, state_abstol=1e-9, max_steps=100_000, min_step=0.0)

Control local error in adaptive transient integration, independently of nonlinear
[`SolverOptions`](@ref). Absolute tolerances use V, A, or internal-state units;
relative tolerance is dimensionless. These tolerances do not make fixed stepping
adaptive: request `adaptive=true` when also specifying `max_step` or `saveat`.

```julia
integration = IntegrationOptions(reltol=1e-5, voltage_abstol=10nV)
tr = transient(circuit, 0s => 1ms; adaptive=true, saveat=10μs, integration)
```

`max_steps` limits attempted steps, including rejected attempts, in either
stepping mode. `min_step` is in seconds; zero allows the numerical minimum.
Exhausting a limit may return a partial result; inspect `tr.stats[:converged]`
or use `failure_policy=:throw`. Refine steps/tolerances against an independent
estimate rather than treating Newton convergence as an accuracy guarantee.
"""
Base.@kwdef struct IntegrationOptions
    reltol::Float64=1e-4
    voltage_abstol::Float64=1e-7
    current_abstol::Float64=1e-10
    state_abstol::Float64=1e-9
    max_steps::Int=100_000
    min_step::Float64=0.
end

function _validate_integration(options::IntegrationOptions)
    for field in (:reltol,:voltage_abstol,:current_abstol,:state_abstol)
        value=getfield(options,field)
        isfinite(value)&&value>0||throw(AnalysisValidationError("integration $field must be finite and positive"))
    end
    options.max_steps>0||throw(AnalysisValidationError("integration max_steps must be positive"))
    isfinite(options.min_step)&&options.min_step>=0||throw(AnalysisValidationError("integration min_step must be finite and non-negative"))
    options
end

Base.@kwdef struct OperatingPoint <: AbstractAnalysis
    solver::SolverOptions = SolverOptions()
    temperature::Float64 = 300.0
end

Base.@kwdef struct TransientNoise <: AbstractAnalysis
    interval::Pair{Float64,Float64}
    timestep::Float64
    saveat::Float64
    seed::UInt64
    temperature::Float64=300.
    low_frequency_cutoff::Float64
    event_mode::Union{Nothing,Symbol}=nothing
    initial::Union{Nothing,Symbol,Vector{Float64}}=nothing
    solver::SolverOptions=SolverOptions(reltol=1e-6,current_abstol=1e-9,voltage_abstol=1e-9,state_abstol=1e-9,max_newton_iterations=120)
end

Base.@kwdef struct Transient <: AbstractAnalysis
    interval::Pair{Float64,Float64}
    saveat::Union{Nothing,Float64}=nothing
    max_step::Union{Nothing,Float64}=nothing
    method::Symbol=:bdf2
    adaptive::Union{Nothing,Bool}=nothing
    temperature::Float64=300.
    overrides::Any=nothing
    solver::SolverOptions=SolverOptions()
    initial::Union{Nothing,Symbol,Vector{Float64}}=nothing
    event_mode::Union{Nothing,Symbol}=nothing
    integration::IntegrationOptions=IntegrationOptions()
    failure_policy::Symbol=:return_partial
end
Transient(p::Pair;kw...)=Transient(interval=Float64(first(p))=>Float64(last(p));kw...)

function _validate_transient(interval;saveat=nothing,max_step=nothing,method=:bdf2,event_mode=nothing,reltol=1e-6,abstol=1e-9,maxiters=120)
    t0,t1=Float64(first(interval)),Float64(last(interval))
    isfinite(t0)&&isfinite(t1)&&t1>t0||throw(AnalysisValidationError("transient interval must be finite and increasing"))
    saveat===nothing||(isfinite(saveat)&&saveat>0)||throw(AnalysisValidationError("saveat must be finite and positive"))
    max_step===nothing||(isfinite(max_step)&&max_step>0)||throw(AnalysisValidationError("max_step must be finite and positive"))
    method in (:bdf1,:bdf2)||throw(AnalysisValidationError("method must be :bdf1 or :bdf2"))
    event_mode in (nothing,:exact)||throw(AnalysisValidationError("event_mode must be nothing or :exact"))
    isfinite(reltol)&&reltol>0||throw(AnalysisValidationError("reltol must be finite and positive"))
    isfinite(abstol)&&abstol>0||throw(AnalysisValidationError("abstol must be finite and positive"))
    maxiters>0||throw(AnalysisValidationError("maxiters must be positive"))
end

function _validate_frequency_range(range,points,scale)
    low,high=Float64(first(range)),Float64(last(range))
    isfinite(low)&&isfinite(high)&&high>=low||throw(AnalysisValidationError("frequency range must be finite and increasing"))
    scale in (:log,:linear)||throw(AnalysisValidationError("frequency scale must be :log or :linear"))
    scale===:log&&low<=0&&throw(AnalysisValidationError("logarithmic frequencies must be positive"))
    points>=1||throw(AnalysisValidationError("frequency point count must be positive"))
end

function _validate_frequency_grid(frequencies::AbstractVector)
    isempty(frequencies)&&throw(AnalysisValidationError("frequency grid must not be empty"))
    fs=Float64.(frequencies)
    all(isfinite,fs)||throw(AnalysisValidationError("frequencies must be finite"))
    all(>=(0),fs)||throw(AnalysisValidationError("frequencies must be non-negative"))
    all(diff(fs).>0)||throw(AnalysisValidationError("frequency grid must be strictly increasing"))
    fs
end

Base.@kwdef struct SmallSignal <: AbstractAnalysis
    frequencies::Vector{Float64}
    source::Union{Nothing,Symbol,String}=nothing
    temperature::Float64=300.
    solver::SolverOptions=SolverOptions()
end
SmallSignal(frequencies::AbstractVector;kw...)=SmallSignal(frequencies=_validate_frequency_grid(frequencies);kw...)
function SmallSignal(range::Pair;points=100,scale=:log,kw...)
    _validate_frequency_range(range,points,scale)
    frequencies=first(range)==last(range) ? [Float64(first(range))] : scale===:log ? collect(10 .^ Base.range(log10(first(range)),log10(last(range)),length=points)) : collect(Base.range(first(range),last(range),length=points))
    SmallSignal(frequencies;kw...)
end

function _override_pairs(overrides)
    overrides===nothing&&return Pair{Symbol,Any}[]
    overrides isa NamedTuple&&return [Symbol(key)=>value for (key,value) in pairs(overrides)]
    overrides isa AbstractDict&&return [Symbol(key)=>value for (key,value) in pairs(overrides)]
    overrides isa Pair&&return [Symbol(first(overrides))=>last(overrides)]
    [Symbol(first(item))=>last(item) for item in overrides]
end

for type in (SuiteSparseLU,SolverOptions,IntegrationOptions)
    _SERIALIZABLE_STRUCTS[String(nameof(type))]=type
end
