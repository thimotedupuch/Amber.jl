using Amber, Test, LinearAlgebra

@testset "trapezoidal integration and restart" begin
    @circuit DecayForExtensions() begin
        gnd = ground(); out = node()
        R = resistor(out, gnd; value = 1.0)
        C = capacitor(out, gnd; value = 1.0)
    end
    circuit = DecayForExtensions()
    coarse = transient(circuit, 0.0 => 1.0; initial = [1.0], max_step = 0.1, method = :trapezoidal)
    fine = transient(circuit, 0.0 => 1.0; initial = [1.0], max_step = 0.05, method = :trapezoidal)
    @test coarse.stats[:converged] && fine.stats[:converged]
    @test abs(fine.values[1,end] - exp(-1)) < abs(coarse.values[1,end] - exp(-1)) / 3
    @test length(coarse.stats[:accepted_step_sizes]) == length(coarse.axis) - 1
    @test sum(coarse.stats[:accepted_step_sizes]) ≈ 1.0
    adaptive = transient(circuit, 0.0 => 1.0; initial = [1.0], method = :trapezoidal, adaptive = true)
    @test adaptive.stats[:converged]
    @test adaptive.values[1,end] ≈ exp(-1) rtol=1e-3
    sparse = transient(circuit, 0.0 => 1.0; initial = [1.0], max_step = 0.01, saveat = 0.1, method = :trapezoidal)
    @test length(sparse.axis) == 11
    @test sparse.values[1,end] ≈ exp(-1) rtol=1e-4
    @test haskey(sparse.stats, :integration_orders)
    recorded = Tuple{Float64,Float64}[]
    streamed = transient(circuit, 0.0 => 1.0; initial = [1.0], max_step = 0.01, saveat = 0.5,
        recorder = (t, state) -> push!(recorded, (t, state[1])))
    @test length(streamed.axis) == 3
    @test length(recorded) == length(streamed.stats[:accepted_step_sizes]) + 1
    @test last(recorded) == (last(streamed.axis), streamed.values[1,end])
    mktemp() do path, io
        close(io)
        save_checkpoint(path, fine)
        resumed = resume_transient(circuit, path, 2.0; max_step = 0.01)
        @test resumed.stats[:converged]
        @test resumed.values[:,1] == fine.values[:,end]
        @test resumed.values[1,end] ≈ exp(-2) rtol=0.003
        @test resumed.stats[:checkpoint_restart] == :first_order
        @test_throws ArgumentError resume_transient(with_parameters(compile(circuit), "R.value" => 2.0), path, 2.0)
    end
end

@testset "distributed RLGC characterization" begin
    line = DistributedLine(inductance = 250e-9, capacitance = 100e-12, length = 2.0)
    @test line_abcd(line, 0.0) == Matrix{ComplexF64}(I, 2, 2)
    f = 10e6; theta = 2pi * f * 2sqrt(250e-9 * 100e-12)
    matrix = line_abcd(line, f)
    @test matrix ≈ [cos(theta) im*50sin(theta); im*sin(theta)/50 cos(theta)]
    @test det(matrix) ≈ 1
    lossy = DistributedLine(resistance = 3.0, inductance = 250e-9, capacitance = 100e-12, length = 2.0)
    @test line_abcd(lossy, 0.0) == ComplexF64[1 6; 0 1]
    @test_throws ArgumentError line_abcd(line, -1.0)
    @test_throws ArgumentError DistributedLine(inductance = -1, capacitance = 1, length = 1)
end
