Base.@kwdef struct PeriodicSteadyState <: AbstractAnalysis
    period::Float64
    saveat::Float64
    max_step::Union{Nothing, Float64} = nothing
    method::Symbol = :bdf2
    event_mode::Union{Nothing, Symbol} = nothing
    temperature::Float64 = 300.0
    autonomous::Bool = false
    phase_index::Union{Nothing, Int} = nothing
    monodromy_method::Symbol = :variational
    initial::Union{Nothing, Symbol, Vector{Float64}} = nothing
    maxiters::Int = 12
    newton_damping::Float64 = 1.0
    fd_step::Float64 = sqrt(eps(Float64))
    solver::SolverOptions = SolverOptions(current_abstol = 1.0e-9, voltage_abstol = 1.0e-9, state_abstol = 1.0e-9, max_newton_iterations = 120)
end

struct PSSResult
    orbit::SimulationResult
    period::Float64
    residual_norm::Float64
    iterations::Int
    monodromy::Matrix{Float64}
    floquet_multipliers::Vector{ComplexF64}
    autonomous::Bool
    phase_index::Union{Nothing, Int}
    stats::Dict{Symbol, Any}
end

floquet_multipliers(result::PSSResult) = result.floquet_multipliers

function _pss_cycle(cc, start, period, state; saveat, max_step, method, event_mode, temperature, reltol = nothing, abstol = nothing, maxiters = nothing, solver = SolverOptions())
    result = transient(cc, start => (start + period); initial = state, saveat, max_step, method, event_mode, temperature, reltol, abstol, maxiters, solver, adaptive = false)
    return _require_converged(result, "PSS shooting trajectory")
end

function _period_map_jacobian(cc, start, period, state, endpoint; saveat, max_step, method, event_mode, temperature, reltol, abstol, maxiters, fd_step, solver = SolverOptions())
    count = length(state); jacobian = zeros(Float64, count, count)
    for index in eachindex(state)
        delta = fd_step * max(abs(state[index]), 1.0); perturbed = copy(state); perturbed[index] += delta
        cycle = _pss_cycle(cc, start, period, perturbed; saveat, max_step, method, event_mode, temperature, reltol, abstol, maxiters, solver)
        jacobian[:, index] = (cycle.values[:, end] - endpoint) / delta
    end
    return jacobian
end

function _variational_monodromy(cc, cycle; method, temperature)
    count = cc.n
    tangent_previous = Matrix{Float64}(I, count, count)
    tangent_older = copy(tangent_previous)
    workspace = SimulationWorkspace(cc)
    _, initial_c = _static_dynamic_jacobians!(workspace, cc, cycle.values[:, 1], cycle.axis[1]; temperature)
    cprevious = copy(initial_c); colder = copy(cprevious)
    for step in 2:length(cycle.axis)
        h = cycle.axis[step] - cycle.axis[step - 1]
        use_bdf2 = method === :bdf2&&step > 2
        if use_bdf2
            previous_h = cycle.axis[step - 1] - cycle.axis[step - 2]
            ratio = h / previous_h
            α = (1 + 2ratio) / ((1 + ratio) * h)
            history_tangent = (
                ((1 + ratio) / h) .* (cprevious * tangent_previous) .-
                    (ratio^2 / ((1 + ratio) * h)) .* (colder * tangent_older)
            ) ./ α
        else
            α = inv(h)
            history_tangent = cprevious * tangent_previous
        end
        point = cycle.values[:, step]
        g, dynamic = _static_dynamic_jacobians!(workspace, cc, point, cycle.axis[step]; temperature)
        combined = g + α * dynamic
        tangent = _solve_linear(
            combined, α .* history_tangent,
            "PSS variational system is singular at time $(cycle.axis[step])"
        )
        colder = cprevious; cprevious = copy(dynamic)
        tangent_older = tangent_previous
        tangent_previous = Matrix(tangent)
    end
    return tangent_previous
end

function _pss_monodromy(
        cc, cycle, state; method = :variational, transient_method = :bdf2,
        start = 0.0, period, saveat, max_step, event_mode, temperature, reltol, abstol, fd_step, solver = SolverOptions()
    )
    return if method === :variational
        _variational_monodromy(cc, cycle; method = transient_method, temperature)
    elseif method === :finite_difference
        _period_map_jacobian(
            cc, start, period, state, cycle.values[:, end];
            saveat, max_step, method = transient_method, event_mode, temperature,
            abstol = nothing, reltol = nothing, maxiters = nothing, fd_step, solver
        )
    else
        throw(
            AnalysisValidationError(
                "PSS monodromy method must be :variational or :finite_difference"
            )
        )
    end
end

function periodic_steady_state(
        c; period, saveat = Float64(period) / 200, max_step = nothing, method = :bdf2, event_mode = nothing,
        temperature = 300.0, initial = nothing, reltol = nothing, abstol = nothing, maxiters = 12,
        newton_damping = 1.0, fd_step = sqrt(eps(Float64)), monodromy_method = :variational,
        autonomous = false, phase_index = nothing,
        solver = SolverOptions(current_abstol = 1.0e-9, voltage_abstol = 1.0e-9, state_abstol = 1.0e-9, max_newton_iterations = 120)
    )
    solver = _effective_solver(solver; reltol, abstol)
    reltol, abstol, _, _ = _solver_values(solver)
    period = Float64(period); period > 0&&isfinite(period)||throw(AnalysisValidationError("PSS period must be finite and positive"))
    saveat = Float64(saveat); saveat > 0||throw(AnalysisValidationError("PSS saveat must be positive"))
    maxiters > 0||throw(AnalysisValidationError("PSS maxiters must be positive")); 0 < newton_damping <= 1||throw(AnalysisValidationError("PSS Newton damping must lie in (0, 1]"))
    cc = compile(c); state = _initial_transient_state(cc, initial; temperature, solver)
    autonomous = Bool(autonomous)
    autonomous&&method !== :bdf1&&throw(
        AnalysisValidationError(
            "autonomous PSS requires method=:bdf1 so the discrete adjoint and phase condition share a one-step map"
        )
    )
    autonomous&&event_mode !== nothing&&throw(
        AnalysisValidationError(
            "autonomous PSS does not support prescribed event timing"
        )
    )
    cycle = nothing; monodromy = zeros(cc.n, cc.n); residual_norm = Inf
    effective_monodromy_method = event_mode === :exact&&monodromy_method === :variational ?
        :finite_difference : monodromy_method
    phase_reference = nothing
    iteration_count = 0; converged = false
    for iteration in 1:maxiters
        iteration_count = iteration
        cycle = _pss_cycle(cc, 0.0, period, state; saveat, max_step, method, event_mode, temperature, solver)
        endpoint = cycle.values[:, end]; residual = endpoint - state; residual_norm = norm(residual, Inf)
        if autonomous&&phase_index === nothing
            slopes = abs.(
                (cycle.values[:, 2] - cycle.values[:, 1]) ./
                    (cycle.axis[2] - cycle.axis[1])
            )
            phase_index = argmax(slopes)
            phase_reference = state[phase_index]
        elseif autonomous&&phase_reference === nothing
            1 <= phase_index <= cc.n||throw(
                AnalysisValidationError(
                    "autonomous PSS phase index is outside the state vector"
                )
            )
            phase_reference = state[phase_index]
        end
        scale = max(norm(state, Inf), norm(endpoint, Inf), 1.0)
        phase_residual = autonomous ? state[phase_index] - phase_reference : 0.0
        if residual_norm <= abstol + reltol * scale&&abs(phase_residual) <= abstol + reltol * scale
            monodromy = _pss_monodromy(
                cc, cycle, state; method = effective_monodromy_method,
                transient_method = method, period, saveat, max_step, event_mode, temperature,
                reltol, abstol, fd_step, solver
            )
            converged = true; break
        end
        monodromy = _pss_monodromy(
            cc, cycle, state; method = effective_monodromy_method,
            transient_method = method, period, saveat, max_step, event_mode, temperature,
            reltol, abstol, fd_step, solver
        )
        if autonomous
            period_step = fd_step * max(abs(period), saveat, eps(Float64))
            shifted = _pss_cycle(
                cc, 0.0, period + period_step, state; saveat,
                max_step, method, event_mode, temperature, solver
            )
            period_derivative = (shifted.values[:, end] - endpoint) / period_step
            phase_row = zeros(Float64, cc.n); phase_row[phase_index] = 1.0
            augmented = [monodromy - I period_derivative;transpose(phase_row) 0.0]
            correction = _solve_linear(
                augmented, -vcat(residual, phase_residual),
                "autonomous PSS shooting Jacobian is singular"
            )
            state .+= newton_damping .* correction[1:cc.n]
            period += newton_damping * correction[end]
            period > 0||throw(
                ConvergenceError(
                    "autonomous PSS produced a non-positive period", Dict{Symbol, Any}()
                )
            )
        else
            correction = _solve_linear(
                monodromy - I, -residual,
                "PSS shooting Jacobian is singular"
            )
            state .+= newton_damping .* correction
        end
    end
    if !converged
        cycle = _pss_cycle(cc, 0.0, period, state; saveat, max_step, method, event_mode, temperature, solver)
        residual_norm = norm(cycle.values[:, end] - state, Inf)
        monodromy = _pss_monodromy(
            cc, cycle, state; method = effective_monodromy_method,
            transient_method = method, period, saveat, max_step, event_mode, temperature, reltol, abstol, fd_step, solver
        )
    end
    multipliers = ComplexF64.(eigvals(monodromy)); warnings = converged ? String[] : ["PSS shooting did not converge"]
    effective_monodromy_method !== monodromy_method&&push!(
        warnings,
        "exact switching events use finite-difference monodromy because variational saltation matrices are not available"
    )
    if autonomous&&converged
        neutral_distance = minimum(abs.(multipliers .- 1))
        neutral_distance > 1.0e-3&&push!(
            warnings,
            "autonomous PSS has no well-isolated neutral Floquet multiplier"
        )
    end
    stats = _finalize_stats!(
        Dict{Symbol, Any}(
            :converged => converged,
            :iterations => iteration_count, :residual_norm => residual_norm,
            :temperature => Float64(temperature), :autonomous => autonomous,
            :monodromy_method => effective_monodromy_method, :warnings => warnings
        ); partial = true
    )
    return PSSResult(
        cycle, period, residual_norm, iteration_count, monodromy, multipliers,
        autonomous, phase_index, stats
    )
end

provenance(result::PSSResult) = Dict(
    :amber_version => v"0.1.0", :topology_fingerprint => result.orbit.compiled.fingerprint,
    :analysis => "PeriodicSteadyState", :statistics => copy(result.stats), :unit_system => :SI, :warnings => copy(result.stats[:warnings])
)
report(result::PSSResult) = Dict(:analysis => "PeriodicSteadyState", :period => result.period, :statistics => copy(result.stats), :floquet_multipliers => result.floquet_multipliers)

simulate(c, analysis::PeriodicSteadyState) = periodic_steady_state(
    c;
    period = analysis.period, saveat = analysis.saveat, max_step = analysis.max_step,
    method = analysis.method, event_mode = analysis.event_mode,
    temperature = analysis.temperature, autonomous = analysis.autonomous,
    phase_index = analysis.phase_index, monodromy_method = analysis.monodromy_method,
    initial = analysis.initial, maxiters = analysis.maxiters, newton_damping = analysis.newton_damping,
    fd_step = analysis.fd_step, solver = analysis.solver
)
