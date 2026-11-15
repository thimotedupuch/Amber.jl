using SparseArrays

@testset "small signal" begin
    result = small_signal(LowPass(), 10Hz => 1MHz; points = 20)
    @test abs(voltage(result, :vout)[1]) > 0.9V; @test length(frequencies(result)) == 20
    @circuit BiasedAC() begin
        gnd = ground(); supply = node(); input = node(); output = node()
        VDD = voltage_source(supply, gnd; dc = 12V)
        Vin = voltage_source(input, gnd; dc = 2V, ac = 1V)
        R1 = resistor(input, output; value = 1kΩ); R2 = resistor(output, gnd; value = 1kΩ)
    end
    biased = small_signal(BiasedAC(), 1kHz => 1kHz; source = :Vin)
    @test voltage(biased, :output)[1] ≈ 0.5V
    @test voltage(biased, :supply)[1] ≈ 0V
end

@testset "explicit frequency grids and response metrics" begin
    grid = [10Hz, 100Hz, 1kHz, 10kHz]
    result = small_signal(LowPass(), grid; source = :V1)
    @test frequencies(result) == grid
    @test result.analysis.frequencies == ustrip.(uconvert.(Hz, grid))
    @test length(db20(voltage(result, :vout) ./ V)) == length(grid)
    @test phase(ComplexF64[-1 - im, -1 + im]; unwrap = true)[2] < phase(ComplexF64[-1 - im, -1 + im]; unwrap = true)[1]
    @test all(isfinite, group_delay(grid, voltage(result, :vout)))
    @test_throws AnalysisValidationError small_signal(LowPass(), [1kHz, 100Hz])

    @circuit ComplexACSource() begin
        gnd = ground(); input = node()
        V1 = voltage_source(input, gnd; ac = 1 + 1im)
    end
    serialized = deserialize_circuit(serialize_circuit(ComplexACSource()))
    @test Amber.ac_excitation(compile(serialized))[end] == 1 + 1im
end

@testset "single canonical small-signal API" begin
    analysis = SmallSignal(10Hz => 1kHz; points = 3, source = :V1)
    @test analysis.frequencies ≈ [10, 100, 1000]
    @test !hasproperty(analysis, :points)
    @test !hasproperty(analysis, :scale)

    @circuit MultipleACSources() begin
        gnd = ground(); first = node(); second = node()
        V1 = voltage_source(first, gnd; ac = 1V)
        V2 = voltage_source(second, gnd; ac = 1V)
        R1 = resistor(first, gnd; value = 1kΩ)
        R2 = resistor(second, gnd; value = 1kΩ)
    end
    @test_throws ArgumentError small_signal(MultipleACSources(), [1kHz])
    @test small_signal(MultipleACSources(), [1kHz]; source = :V1).stats[:converged]
end


@testset "small-signal bias convergence" begin
    @test_throws AnalysisValidationError small_signal(LowPass(), 10Hz => 1kHz; maxiters = 0)
    biased = with_parameters(compile(LowPass()), "V1.dc" => 1.0)
    @test_throws ConvergenceError small_signal(biased, 10Hz => 1kHz; maxiters = 1)
end

@testset "frequency interval validation" begin
    @test_throws Amber.AnalysisValidationError SmallSignal(-1.0 => 10.0; scale = :linear)
    @test_throws Amber.AnalysisValidationError Amber._small_signal_frequencies(-1.0 => 10.0; points = 10, scale = :linear)
    @test_throws Amber.AnalysisValidationError SmallSignal(1.0 => 10.0; points = 1)
    @test_throws Amber.AnalysisValidationError SmallSignal(1.0 => 10.0; points = 2.5)
    @test SmallSignal(0.0 => 0.0; points = 1, scale = :linear).frequencies == [0.0]
    @test SmallSignal(0.0 => 10.0; points = 3, scale = :linear).frequencies == [0.0, 5.0, 10.0]
end

@testset "automatic path AC factorization" begin
    b = CircuitBuilder(:ACPath)
    g = ground!(b, :gnd); nodes = node_array!(b, :x, 0:12)
    add!(b, voltage_source(nodes[0],g;ac=1.0);name=:Source)
    for i in 1:12
        add!(b,resistor(nodes[i-1],nodes[i];value=1000.0);name=(:R,i))
        add!(b,capacitor(nodes[i],g;value=1e-9);name=(:C,i))
    end
    cc=compile(finish(b)); fs=[0.0,10.0,100.0,1e4,1e6]
    automatic=small_signal(cc,fs)
    @test automatic.stats[:linear_backend] === :tridiagonal
    for ordering in (:amd,:natural)
        explicit=small_signal(cc,fs;solver=SolverOptions(linear_solver=SuiteSparseLU(;ordering)))
        @test explicit.stats[:linear_backend] === :suitesparse
        @test automatic.values ≈ explicit.values rtol=1e-10 atol=1e-12
    end
    @test simulate(cc,SmallSignal(fs)).stats[:linear_backend] === :tridiagonal
    @test simulate(cc,SmallSignal(fs;solver=SolverOptions())).stats[:linear_backend] === :suitesparse

    # Reject cycles and disconnected patterns; retain the general sparse backend.
    @test Amber._small_signal_path(sparse([1.0 1 1;1 1 1;1 1 1])) === nothing
    @test Amber._small_signal_path(sparse([1.0 0;0 1])) === nothing
    # A zero leading diagonal needs pivoting, and repeated factors must reset fill.
    J=SparseArrays.sparse([0.0 1 0;1 2 1;0 1 3]); D=copy(J); fill!(D.nzval,0); D[2,2]=1; D[3,3]=2
    # Use a shared union pattern as the compiler does.
    pattern=J+D; system=ComplexF64.(pattern); rhs=ComplexF64[1,2,3]
    vals=zeros(ComplexF64,3,3); frequencies=[0.0,1.0,100.0]
    Amber._small_signal_path_sweep!(vals,frequencies,system,J,D,rhs,[1,2,3])
    for (j,f) in enumerate(frequencies)
        @test vals[:,j] ≈ (J+im*2π*f*D)\rhs
    end
    singular=copy(system); fill!(singular.nzval,0)
    @test_throws Amber.LinearSolveError Amber._small_signal_path_sweep!(
        zeros(ComplexF64,3,1),[1.0],system,singular,singular,rhs,[1,2,3])
    # Test a nonsymmetric matrix whose path is not in original index order.
    permutation=[2,3,1]; nonsymmetric=sparse([2.0 3 0;1 4 5;0 2 6])[permutation,permutation]
    dynamic=copy(nonsymmetric); fill!(dynamic.nzval,0)
    path=Amber._small_signal_path(nonsymmetric)
    solution=zeros(ComplexF64,3,1)
    Amber._small_signal_path_sweep!(solution, [0.0], nonsymmetric,nonsymmetric,dynamic,rhs,path)
    @test solution[:,1] ≈ nonsymmetric\rhs

end

@testset "bias-exact AC sparsity" begin
    # Retain dynamic-only edges and tiny nonzero derivatives; preserve singular
    # dimensions rather than dropping empty rows or columns.
    z = sparse(ones(3,3)); d = copy(z)
    z.nzval .= vec([1.0 0 1e-200; 0 2 0; 0 0 0])
    d.nzval .= vec([0.0 0.5 0; 0 0 0; 0 0 0])
    cz, cd = Amber._small_signal_compact_jacobians(z,d)
    @test size(cz) == size(cd) == (3,3)
    @test nnz(cz) == nnz(cd) == 4
    @test cz[1,3] == 1e-200
    for f in (0.0,1.0,1e10)
        @test Matrix(cz + im*2π*f*cd) == Matrix(z + im*2π*f*d)
    end
    @test z.nzval == vec([1.0 0 1e-200; 0 2 0; 0 0 0])

    b = CircuitBuilder(:BiasedCMOSAC)
    g = ground!(b,:gnd); supply = node!(b,:supply); input = node!(b,:input)
    outputs = node_array!(b,:output,1:3)
    add!(b,voltage_source(supply,g;dc=5.0);name=:VDD)
    add!(b,voltage_source(input,g;dc=2.5,ac=1.0);name=:Input)
    for i in 1:3
        add!(b,nmos(outputs[i],input,g,g;model=Level1MOSFET(transconductance=.002,channel_length_modulation=.03));name=(:N,i))
        add!(b,pmos(outputs[i],input,supply,supply;model=Level1MOSFET(transconductance=.001,channel_length_modulation=.03));name=(:P,i))
        add!(b,capacitor(outputs[i],g;value=1e-11);name=(:C,i))
    end
    cc = compile(finish(b)); op = operating_point(cc).values[:,1]
    z,d = Amber._static_dynamic_jacobians(cc,op;mode=:dc,temperature=300.0)
    rhs = Amber.ac_excitation(cc)
    grid = [0.0,1e3,1e8]
    reference = hcat([(z+im*2π*f*d)\rhs for f in grid]...)
    for ordering in (:amd,:natural)
        result = small_signal(cc,grid;solver=SolverOptions(linear_solver=SuiteSparseLU(;ordering)))
        @test result.stats[:linear_backend] === :suitesparse
        @test result.values ≈ reference rtol=1e-11 atol=1e-12
    end
end
