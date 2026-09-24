@testset "direct storage matrices retain small dynamics" begin
    @circuit StorageRC(; r = 1.0, c = 1.0e-17) begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; ac = 1.0)
        R1 = resistor(input, output; value = r)
        C1 = capacitor(output, gnd; value = c)
    end
    for (r, c) in ((1.0, 1.0e-17), (1.0e3, 1.0e-15), (1.0e6, 1.0e-12))
        circuit = StorageRC(; r, c); frequency = inv(2π * r * c)
        ac = small_signal(circuit, [frequency]; source = :V1)
        @test voltage(ac, :output)[1] ≈ 0.5 - 0.5im rtol = 1.0e-12
        model = linearize(circuit; inputs = :V1, outputs = voltage(:output))
        @test frequency_response(model, [frequency]).values[1, 1, 1] ≈ 0.5 - 0.5im rtol = 1.0e-12
        nr = noise(circuit, [frequency]; output = voltage(:output))
        @test noise_psd(nr)[1] ≈ 4 * 1.380649e-23 * 300 * r / 2 rtol = 1.0e-12
    end
end

@testset "nonlinear charge and continuous derivatives agree" begin
    model = JunctionDiode(
        saturation_current = 1.0e-30, junction_capacitance = 1.0e-9,
        junction_potential = 0.7, grading_coefficient = 0.5, transit_time = 1.0e-9
    )
    @circuit StorageDiode() begin
        gnd = ground(); x = node()
        D = diode(x, gnd; model)
    end
    cc = compile(StorageDiode()); workspace = SimulationWorkspace(cc)
    for v in (-0.1, 0.3, 0.7, 1.5, 3.0)
        point = [v]; previous = [v - 0.2]; alpha = 1.0e6; epsilon = 1.0e-6
        _, analytic = Amber.residual_jacobian(cc, point, previous, 0.0, alpha)
        residual(z) = Amber.residual(cc, z, alpha .* (z .- previous), 0.0)
        numerical = (residual(point .+ epsilon) - residual(point .- epsilon)) / (2epsilon)
        @test analytic[1, 1] ≈ numerical[1] rtol = 1.0e-7
        dq = (charge(model, v + epsilon) - charge(model, v - epsilon)) / (2epsilon)
        @test dq ≈ differential_capacitance(model, v) rtol = 1.0e-7
        q, c = storage_jacobian!(workspace, cc, point)
        @test q[1] ≈ charge(model, v)
        @test c[1, 1] ≈ dq rtol = 1.0e-7
    end
end

@testset "BDF integrates nonlinear stored charge" begin
    model = JunctionDiode(saturation_current = 1.0e-30, junction_capacitance = 1.0e-9)
    @circuit ChargeInjection() begin
        gnd = ground(); x = node()
        I1 = current_source(gnd, x; dc = 1.0e-6)
        D = diode(x, gnd; model)
    end
    q0 = charge(model, 0.1)
    for method in (:bdf1, :bdf2), adaptive in (false, true)
        result = transient(
            ChargeInjection(), 0.0 => 1.0e-4; initial = [0.1], max_step = 3.0e-5,
            method, adaptive, reltol = 1.0e-10, abstol = 1.0e-15
        )
        @test result.stats[:converged]
        charges = charge.(Ref(model), voltage(result, :x))
        @test charges ≈ q0 .+ 1.0e-6 .* result.axis rtol = 1.0e-8 atol = 1.0e-19
        if !adaptive
            @test current(result, :D)[2:end] ≈ fill(1.0e-6, length(result.axis) - 1) rtol = 1.0e-8
        end
    end
end

@testset "nonlinear storage period-map derivative" begin
    @circuit MovingCapacitance() begin
        gnd = ground(); x = node()
        R = resistor(x, gnd; value = 1.0e3)
        D = diode(x, gnd; model = JunctionDiode(saturation_current = 1.0e-30, junction_capacitance = 1.0e-6))
        I1 = current_source(gnd, x; waveform = Sine(offset = 3.0e-4, amplitude = 1.0e-4, frequency = 1.0e3))
    end
    cc = compile(MovingCapacitance()); start = [0.1]
    for method in (:bdf1, :bdf2)
        options = (;
            saveat = 9.0e-5, max_step = 9.0e-5, method, event_mode = nothing,
            temperature = 300.0, reltol = 1.0e-11, abstol = 1.0e-15, maxiters = 100,
        )
        orbit = Amber._pss_cycle(cc, 0.0, 1.0e-3, start; options...)
        tangent = Amber._variational_monodromy(cc, orbit; method, temperature = 300.0)
        epsilon = 1.0e-5
        plus = Amber._pss_cycle(cc, 0.0, 1.0e-3, start .+ epsilon; options...)
        minus = Amber._pss_cycle(cc, 0.0, 1.0e-3, start .- epsilon; options...)
        numerical = (plus.values[:, end] - minus.values[:, end]) / (2epsilon)
        @test tangent[:, 1] ≈ numerical rtol = 2.0e-6
        @test 0.1 < tangent[1, 1] < 0.9 # avoid a vacuous comparison after complete decay
    end
end

@testset "periodic charge derivative uses output harmonic" begin
    count = 32; period = 0.1; offset = 3.0; harmonics = -1:1
    # C(t)=2+cos(Ωt), G=3. Fourier coefficients C_±1=1/2.
    capacitances = [reshape([2 + cos(2π * k / count)], 1, 1) for k in 0:(count - 1)]
    conductances = [fill(3.0, 1, 1) for _ in 1:count]
    lifted = Amber._lifted_periodic_system(conductances, capacitances, harmonics, offset, period)
    for (row, k) in enumerate(harmonics),(column, l) in enumerate(harmonics)
        c = k == l ? 2.0 : abs(k - l) == 1 ? 0.5 : 0.0
        expected = (k == l ? 3.0 : 0.0) + im * 2π * (offset + k / period) * c
        @test lifted[row, column] ≈ expected atol = 1.0e-12
    end
end

@testset "oscillator adjoint maps equation forcing through storage" begin
    # Normal-form oscillator with nonidentity storage. The resistors provide
    # fixed white noise; their deterministic currents are compensated below.
    @circuit AdjointOscillator(; storage_scale = 1.0) begin
        gnd = ground(); x = node(); y = node(); z = node()
        Follower = voltage_controlled_voltage_source(x, gnd, z, gnd; gain = 2.0)
        Cx = capacitor(x, gnd; value = 2storage_scale)
        Cy = capacitor(y, gnd; value = 5storage_scale)
        Rx = resistor(x, gnd; value = 1.0)
        Ry = resistor(y, gnd; value = 1.0)
        Ix = behavioral_current_source(
            ((x, gnd), (y, gnd)), x, gnd;
            current = (v, t) -> 2storage_scale * ((v[1]^2 + v[2]^2 - 1) * v[1] + v[2]) - v[1],
            gradient = (v, t) -> (
                2storage_scale * (3v[1]^2 + v[2]^2 - 1) - 1,
                2storage_scale * (2v[1] * v[2] + 1), 0.0, 0.0,
            )
        )
        Iy = behavioral_current_source(
            ((x, gnd), (y, gnd)), y, gnd;
            current = (v, t) -> 5storage_scale * ((v[1]^2 + v[2]^2 - 1) * v[2] - v[1]) - v[2],
            gradient = (v, t) -> (
                5storage_scale * (2v[1] * v[2] - 1),
                5storage_scale * (v[1]^2 + 3v[2]^2 - 1) - 1, 0.0, 0.0,
            )
        )
    end
    projections = Vector{Vector{Float64}}(); sensitivities = Matrix{Float64}[]
    phase_spectra = Vector{Vector{Float64}}()
    for scale in (1.0, 7.0)
        cc = compile(AdjointOscillator(storage_scale = scale))
        count = 256; angle = 2π / count; h = sin(angle); period = count * h
        radius = sqrt(1 + (cos(angle) - 1) / h)
        times = collect(0:count) .* h
        # Exact orbit of backward Euler, derived analytically (not a solver fit).
        values = radius .* vcat(
            transpose(cos.(collect(0:count) .* angle)),
            transpose(sin.(collect(0:count) .* angle))
        )
        values = vcat(values, 2 .* values[1:1, :], zeros(1, count + 1))
        ws = SimulationWorkspace(cc)
        for k in 2:length(times)
            qprevious = Amber._storage(cc, values[:, k - 1])
            residual, _ = Amber._step_residual_jacobian!(ws, cc, values[:, k], qprevious, times[k], inv(h))
            @test norm(residual, Inf) < 1.0e-10
        end
        orbit = SimulationResult(
            cc, Transient(0.0 => period; method = :bdf1, saveat = h),
            times, values, Dict{Symbol, Any}(:converged => true, :temperature => 300.0)
        )
        monodromy = Amber._variational_monodromy(cc, orbit; method = :bdf1, temperature = 300.0)
        pss = PSSResult(
            orbit, period, 0.0, 1, monodromy, ComplexF64.(eigvals(monodromy)),
            true, 2, Dict{Symbol, Any}(:converged => true, :temperature => 300.0)
        )
        sampled_times, sampled_values = Amber._periodic_orbit_samples(pss)
        sensitivity, neutral = Amber._phase_sensitivity(pss, sampled_times, sampled_values, 300.0)
        @test abs(neutral - 1) < 1.0e-10
        sources, projection = Amber._phase_projection_spectrum(
            pss, sampled_times,
            sampled_values, sensitivity, 300.0, [0.01, 0.02]
        )
        push!(sensitivities, sensitivity)
        push!(projections, vec(sum(projection; dims = 1)))
        expected = 4 * 1.380649e-23 * 300 / (2radius^2) * (inv(2scale)^2 + inv(5scale)^2)
        @test projections[end] ≈ fill(expected, 2) rtol = 0.03
        result = phase_noise(pss, [0.01, 0.02]; output = voltage(:x), sidebands = -1:1)
        push!(phase_spectra, noise_psd(result))
        @test phase_spectra[end][1] / phase_spectra[end][2] ≈ 4 rtol = 1.0e-12
    end
    @test sensitivities[2] ≈ sensitivities[1] ./ 7 rtol = 1.0e-10
    @test projections[2] ≈ projections[1] ./ 49 rtol = 1.0e-10
    @test phase_spectra[2] ≈ phase_spectra[1] ./ 49 rtol = 1.0e-10
end

@testset "MOS terminal currents follow discrete charge balance" begin
    @circuit StorageMOS() begin
        gnd = ground(); gate = node(); drain = node()
        VG = voltage_source(gate, gnd; dc = 1.0, waveform = Sine(offset = 1.0, amplitude = 0.2, frequency = 1.0e6))
        VD = voltage_source(drain, gnd; dc = 0.3)
        M = nmos(drain, gate, gnd, gnd; model = ChargeBasedMOSFET(width = 8.0e-6, length = 2.0e-6))
    end
    for method in (:bdf1, :bdf2)
        result = transient(StorageMOS(), 0.0 => 1.0e-6; max_step = 7.0e-8, method, reltol = 1.0e-10, abstol = 1.0e-15)
        @test result.stats[:converged]
        @test current(result, :VG)[2:end] ≈ -current(result, :M, :gate)[2:end] rtol = 1.0e-8 atol = 1.0e-15
        @test current(result, :VD)[2:end] ≈ -current(result, :M, :drain)[2:end] rtol = 1.0e-8 atol = 1.0e-15
    end
end
