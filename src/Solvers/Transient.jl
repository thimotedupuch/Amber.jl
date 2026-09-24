function _apply_initial_conditions!(z, cc)
    # Solve voltage differences as connected constraint graphs. Anchored
    # components retain ground; free components retain their mean voltage.
    edges = [Tuple{Int, Float64}[] for _ in 0:cc.n]
    function constraint(a, b, value)
        isfinite(value)||throw(AnalysisValidationError("initial voltages must be finite"))
        push!(edges[b + 1], (a, value))
        return push!(edges[a + 1], (b, -value))
    end
    has_initial = false
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:capacitor}}||continue
        for device in eachindex(batch.parameters)
            p = batch.parameters[device]
            hasproperty(p, :initial_voltage)||continue
            has_initial = true
            constraint(Int(batch.terminals[1][device]), Int(batch.terminals[2][device]), Float64(p.initial_voltage))
        end
    end
    has_initial||return z
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:voltage_source}}||continue
        for device in eachindex(batch.parameters)
            p = batch.parameters[device]
            iszero(get(p, :series_resistance, 0.0))||continue
            constraint(Int(batch.terminals[1][device]), Int(batch.terminals[2][device]), Float64(get(p, :dc, 0.0)))
        end
    end
    visited = falses(cc.n + 1); offsets = zeros(cc.n + 1)
    for root in 0:cc.n
        visited[root + 1]&&continue
        component = Int[root]; visited[root + 1] = true
        for node in component
            for (neighbor, delta) in edges[node + 1]
                expected = offsets[node + 1] + delta
                if visited[neighbor + 1]
                    isapprox(offsets[neighbor + 1], expected; atol = 1.0e-12, rtol = 1.0e-10)||
                        throw(AnalysisValidationError("inconsistent capacitor initial voltages or ideal source constraints"))
                else
                    offsets[neighbor + 1] = expected; visited[neighbor + 1] = true; push!(component, neighbor)
                end
            end
        end
        shift = root == 0 ? 0.0 : sum(z[node] - offsets[node + 1] for node in component) / length(component)
        for node in component
            node == 0||(z[node] = offsets[node + 1] + shift)
        end
    end
    return z
end

function transient(c, p::Pair; overrides = nothing, kw...)
    cc = compile(c); updates = _override_pairs(overrides)
    updated = isempty(updates) ? cc : with_parameters(cc, (String(first(update)) => last(update) for update in updates)...)
    return _transient(updated, p; overrides, kw...)
end
function _waveform_events(cc, t0, t1)
    events = Float64[]
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch || continue
        kind = _batch_kind(batch)
        kind in (:voltage_source, :current_source)||continue
        for parameters in batch.parameters
            waveform = get(parameters, :waveform, nothing)
            if waveform isa Step
                push!(events, waveform.at); waveform.rise > 0&&push!(events, waveform.at + waveform.rise)
            elseif waveform isa Pulse
                period = inv(waveform.frequency); first_cycle = max(0, floor(Int, (t0 - waveform.delay) / period) - 1); last_cycle = ceil(Int, (t1 - waveform.delay) / period) + 1
                for cycle in first_cycle:last_cycle
                    start = waveform.delay + cycle * period
                    append!(events, (start, start + waveform.rise, start + waveform.duty_cycle * period, start + waveform.duty_cycle * period + waveform.fall))
                end
            end
        end
    end
    # Retain a corner at the stop, including roundoff-equivalent timestamps.
    # It must restart BDF just like an interior corner; excluding an exactly
    # equal endpoint otherwise changes the final integration order by an ulp.
    tolerance = 32eps(max(abs(t0), abs(t1)))
    filter!(time -> t0 < time <= t1 + tolerance, events)
    return min.(events, t1)
end

function _merge_time_grid(times, nominal_step; preferred = Set{Float64}())
    sorted = sort!(Float64.(times)); merged = Float64[]; tolerance = max(eps(maximum(abs, sorted)) * 16, nominal_step * 1.0e-10)
    for time in sorted
        if isempty(merged)||time - last(merged) > tolerance
            push!(merged, time)
        elseif time in preferred
            # Preserve requested output timestamps when a waveform corner or
            # integration boundary differs from them by only roundoff.
            merged[end] = time
        end
    end
    return merged
end

function _initial_transient_state(cc, initial; temperature = 300.0, workspace = nothing, solver = SolverOptions())
    if initial === :discharged
        z = zeros(cc.n)
    elseif initial isa AbstractVector
        length(initial) == cc.n||throw(DimensionMismatch("initial state does not match the compiled circuit"))
        all(isfinite, initial)||throw(AnalysisValidationError("initial state must be finite"))
        return Float64.(initial)
    elseif initial === nothing
        result = _require_converged(operating_point(cc; temperature, workspace, solver), "transient operating point")
        z = copy(result.values[:, 1])
    else
        throw(AnalysisValidationError("initial must be nothing, :discharged, or a state vector"))
    end
    return _apply_initial_conditions!(z, cc)
end

function _switch_crossings(cc, before, after)
    crossings = Tuple{Any, Int, Bool}[]
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:switch}}||continue
        for device in eachindex(batch.parameters)
            model = batch.parameters[device].model
            model isa SmoothSwitch&&iszero(model.charge_injection)&&continue
            p, n = batch.terminals[3][device], batch.terminals[4][device]
            old = _workspace_value(before, p) - _workspace_value(before, n) >= model.threshold
            new = _workspace_value(after, p) - _workspace_value(after, n) >= model.threshold
            old == new||push!(crossings, (batch, device, old&&!new))
        end
    end
    return crossings
end

function _event_charge(cc, crossings)
    charge = zeros(cc.n)
    for (batch, device, falling) in crossings
        falling||continue
        # Positive injection enters the held terminal from electrical ground.
        held = Int(batch.terminals[2][device])
        held == 0||(charge[held] += batch.parameters[device].model.charge_injection)
    end
    return charge
end

function _integration_indices(cc)
    indices = findall(!=(BranchCurrentUnknown), cc.topology.layout.kinds)
    for batch in cc.parameters.batches
        batch isa PrimitiveBatch{Val{:inductor}}||continue
        append!(indices, Int.(batch.branch_unknowns))
    end
    return indices
end

function _error_norm(high, low, previous, cc, options::IntegrationOptions, indices)
    error = 0.0
    for index in indices
        kind = cc.topology.layout.kinds[index]
        absolute = kind === BranchCurrentUnknown ? options.current_abstol :
            kind === DeviceStateUnknown ? options.state_abstol : options.voltage_abstol
        scale = absolute + options.reltol * max(abs(high[index]), abs(previous[index]))
        error = max(error, abs(high[index] - low[index]) / scale)
    end
    return error
end

function _transient(
        c, p::Pair; saveat = nothing, max_step = nothing, method = :bdf2, adaptive = nothing,
        reltol = nothing, abstol = nothing, maxiters = nothing, initial = nothing, event_mode = nothing,
        temperature = 300.0, solver = SolverOptions(), integration = IntegrationOptions(),
        failure_policy = :return_partial, overrides = nothing
    )
    solver = _effective_solver(solver; reltol, abstol, maxiters)
    reltol, abstol, maxiters, _ = _solver_values(solver)
    _validate_transient(p; saveat, max_step, method, event_mode, reltol, abstol, maxiters)
    _validate_integration(integration)
    failure_policy in (:throw, :return_partial)||throw(AnalysisValidationError("failure_policy must be :throw or :return_partial"))
    isfinite(temperature)&&temperature > 0||throw(AnalysisValidationError("temperature must be finite and positive"))
    cc = compile(c); workspace = SimulationWorkspace(cc)
    integration_indices = _integration_indices(cc)
    t0, t1 = Float64(first(p)), Float64(last(p)); span = t1 - t0
    use_adaptive = adaptive === nothing ? saveat === nothing&&max_step === nothing : Bool(adaptive)
    maximum_step = something(max_step, saveat, use_adaptive ? span / 10 : span / 1000)
    saveat === nothing||(maximum_step = min(maximum_step, saveat))
    dt = use_adaptive ? min(maximum_step, span / 100) : maximum_step
    minimum_step = max(integration.min_step, eps(max(abs(t0), abs(t1))) * 32)
    waveform_events = event_mode === :exact ? _waveform_events(cc, t0, t1) : Float64[]
    output_targets = saveat === nothing ? Set{Float64}() : Set(vcat(t0, collect((t0 + saveat):saveat:t1), t1))
    grid = use_adaptive ? Float64[t1] : vcat(collect((t0 + dt):dt:t1), t1)
    saveat === nothing||append!(grid, filter(>(t0), collect(output_targets)))
    # The requested stop must win over a roundoff-equivalent grid point even
    # without saveat. Otherwise the loop takes an extra, near-zero final step.
    append!(grid, waveform_events)
    grid = _merge_time_grid(grid, dt; preferred = union(output_targets, Set([t1])))
    boundary_index = 1
    z = _initial_transient_state(cc, initial; temperature, workspace, solver)
    times = Float64[t0]; states = [copy(z)]; orders = Int[0]
    save_sparse = saveat !== nothing
    saved_states = [copy(z)]; saved_indices = Int[1]
    total_iterations = 0; rejected = 0; attempts = 0; restart = true
    failed_steps = Int[]; failed_residuals = Any[]; event_times = Float64[]
    failure_reason = nothing
    function step(previous, time, h, qhistory; guess = previous, alpha = inv(h))
        return _newton(
            cc, guess, previous, time, alpha; storage_history = qhistory,
            reltol, abstol, maxiters, temperature, workspace,
            voltage_abstol = solver.voltage_abstol, state_abstol = solver.state_abstol,
            line_search_minimum = solver.line_search_minimum, linear_solver = solver.linear_solver
        )
    end
    while last(times) < t1
        attempts += 1
        if attempts > integration.max_steps
            failure_reason = "transient exceeded integration max_steps"; push!(failed_steps, length(times) + 1); break
        end
        time = last(times)
        while boundary_index <= length(grid)&&grid[boundary_index] <= time
            boundary_index += 1
        end
        boundary = boundary_index <= length(grid) ? grid[boundary_index] : t1
        # Fixed steps use the precomputed grid directly. Repeated addition
        # can land a few ulps before a boundary and create a spurious tiny
        # step, followed by an unstable BDF step-size ratio.
        endpoint = use_adaptive ? min(time + dt, boundary, t1) : boundary
        boundary - endpoint <= 32eps(max(abs(time), abs(boundary)))&&(endpoint = boundary)
        h = endpoint - time
        h > 0||begin
            failure_reason = "transient cannot advance time"; push!(failed_steps, length(times) + 1); break
        end
        previous = z; qprevious = _storage(cc, previous; temperature, workspace)
        crossings = Tuple{Any, Int, Bool}[]; full = nothing; full_good = true
        # Bracket the first state-controlled threshold crossing on the actual
        # backward-Euler trajectory. Prescribed waveform corners also bound h.
        if event_mode === :exact
            full, it, full_good = step(previous, endpoint, h, qprevious); total_iterations += it
            crossings = full_good ? _switch_crossings(cc, previous, full) : crossings
            if !isempty(crossings)
                left = time; right = endpoint; right_state = full
                event_tolerance = max(minimum_step, h * 1.0e-9)
                for _ in 1:48
                    right - left <= event_tolerance&&break
                    middle = (left + right) / 2
                    trial, it, good = step(previous, middle, middle - time, qprevious); total_iterations += it
                    if !good
                        full_good = false; break
                    elseif isempty(_switch_crossings(cc, previous, trial))
                        left = middle
                    else
                        right = middle; right_state = trial
                    end
                end
                endpoint = right; h = endpoint - time; full = right_state
                crossings = _switch_crossings(cc, previous, full)
            end
        end
        at_corner = any(t -> abs(endpoint - t) <= max(32eps(max(abs(endpoint), abs(t))), dt * 1.0e-10), waveform_events)
        event = !isempty(crossings)||at_corner
        use_bdf2 = method === :bdf2&&length(states) >= 2&&!restart&&!event
        alpha = inv(h); qhistory = qprevious; order = 1
        if use_bdf2
            ratio = h / (times[end] - times[end - 1]); alpha = (1 + 2ratio) / ((1 + ratio) * h)
            qhistory = _bdf_storage_history(cc, previous, states[end - 1], ratio, h, alpha; temperature, workspace)
            order = 2
        end
        if full === nothing||use_bdf2
            candidate, it, good = step(previous, endpoint, h, qhistory; alpha); total_iterations += it
        else
            candidate = full; good = full_good
        end
        good &= full_good
        error = 0.0
        if use_adaptive&&good
            if use_bdf2
                if full === nothing
                    full, it, full_good = step(previous, endpoint, h, qprevious); total_iterations += it
                end
                error = _error_norm(candidate, full, previous, cc, integration, integration_indices); good &= full_good
            else
                half, it, half_good = step(previous, time + h / 2, h / 2, qprevious); total_iterations += it
                qhalf = _storage(cc, half; temperature, workspace)
                refined, it, refined_good = step(half, endpoint, h / 2, qhalf); total_iterations += it
                error = _error_norm(refined, candidate, previous, cc, integration, integration_indices)
                good &= half_good&&refined_good
                # At an event keep the bracketed one-step trajectory so that
                # root location, switching state, and injection agree.
                if !event
                    candidate = refined; qhistory = qhalf; alpha = 2 / h
                end
            end
        end
        if !good||!isfinite(error)||error > 1
            rejected += 1
            if use_adaptive&&h > minimum_step
                dt = max(minimum_step, h * 0.5); continue
            end
            push!(failed_steps, length(times) + 1)
            r, _ = _step_residual_jacobian!(workspace, cc, candidate, qhistory, endpoint, alpha; temperature)
            push!(failed_residuals, (row = isempty(r) ? 0 : argmax(abs.(r)), norm = norm(r, Inf)))
            failure_reason = "transient step failed convergence or integration tolerances"; break
        end
        if !isempty(crossings)
            injected = _event_charge(cc, crossings)
            if any(!iszero, injected)
                # Stamp charge in equation space. The complete storage matrix
                # distributes it across coupled capacitors and nonlinear devices.
                candidate, it, good = step(previous, endpoint, h, qprevious + injected; guess = candidate)
                total_iterations += it
                if !good
                    failure_reason = "switch charge injection did not converge"; push!(failed_steps, length(times) + 1); break
                end
            end
        end
        event&&push!(event_times, endpoint)
        z = candidate; push!(times, endpoint); push!(states, copy(z)); push!(orders, order)
        if save_sparse
            if endpoint in output_targets
                push!(saved_states, copy(z)); push!(saved_indices, length(times))
            end
            # BDF only needs two accepted states; unsaved internal steps must
            # not accumulate full circuit vectors over a long run with sparse output.
            length(states) > 2&&popfirst!(states)
        end
        restart = event
        if use_adaptive
            factor = error == 0 ? 2.0 : clamp(0.9 * error^(-0.5), 0.25, 2.0)
            dt = min(maximum_step, max(minimum_step, h * factor))
        end
    end
    analysis = Transient(
        t0 => t1; saveat, max_step, method, adaptive = use_adaptive, temperature,
        solver, initial = initial isa AbstractVector ? Float64.(initial) : initial, event_mode, integration, failure_policy, overrides
    )
    stats = Dict{Symbol, Any}(
        :converged => failure_reason === nothing, :iterations => total_iterations,
        :failed_steps => failed_steps, :failed_residuals => failed_residuals, :bdf_orders => orders,
        :event_times => event_times, :rejected_steps => rejected, :temperature => Float64(temperature),
        :warnings => failure_reason === nothing ? String[] : [failure_reason]
    )
    if use_adaptive || (save_sparse && length(saved_indices) != length(times))
        # Saved samples need not share the integration stencil, and BE step
        # doubling also contains an unsaved midpoint. Trace derivatives must
        # therefore use the saved time axis rather than a fictitious BDF grid.
        stats[:integration_orders] = pop!(stats, :bdf_orders)
    end
    _finalize_stats!(stats; partial = true)
    failure_reason === nothing||failure_policy !== :throw||throw(ConvergenceError(failure_reason, stats))
    if save_sparse
        if last(saved_indices) != length(times)
            push!(saved_indices, length(times)); push!(saved_states, copy(z))
        end
        times = times[saved_indices]; values = hcat(saved_states...)
    else
        values = hcat(states...)
    end
    return SimulationResult(cc, analysis, times, values, stats)
end

simulate(c, a::Transient) = transient(
    c, a.interval; saveat = a.saveat, max_step = a.max_step,
    method = a.method, adaptive = a.adaptive, temperature = a.temperature, overrides = a.overrides,
    solver = a.solver, initial = a.initial, event_mode = a.event_mode, integration = a.integration,
    failure_policy = a.failure_policy
)
