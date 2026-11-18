using Amber, Test, LinearAlgebra
function dae_rc(;waveform=nothing)
    b=CircuitBuilder(:DAERC); g=ground!(b); input=node!(b,:input); output=node!(b,:output)
    source=waveform === nothing ? voltage_source(input,g;dc=1.0) : voltage_source(input,g;waveform)
    add!(b,source;name=:Supply); add!(b,resistor(input,output;value=1.0);name=:R)
    add!(b,capacitor(output,g;value=1.0);name=:C)
    return compile(finish(b))
end
@testset "storage incidence versus descriptor rank" begin
    b=CircuitBuilder(:CoupledStorage); g=ground!(b); p=node!(b,:p); n=node!(b,:n)
    add!(b,resistor(p,g;value=1.0);name=:Rp); add!(b,resistor(n,g;value=2.0);name=:Rn)
    add!(b,capacitor(p,n;value=1.0);name=:C)
    cc=compile(finish(b)); sparse_info=dae_structure(cc)
    @test sparse_info.structural_storage_rank == 2
    @test sparse_info.numerical_storage_rank === nothing
    info=dae_structure(cc;numerical=true)
    @test info.numerical_storage_rank == 1
    @test info.classification === :linear_index_one_candidate
    condition=consistent_initial_conditions(cc,[2.0,0.0])
    @test condition.state ≈ [2/3,-4/3]
    @test condition.derivative ≈ [-2/9,4/9]
    @test condition.stats.componentwise_error < 1e-9
    @test_throws ArgumentError dae_structure(cc;numerical=true,dense_limit=1)
    @test_throws ArgumentError dae_structure(cc;rank_rtol=0)
end
@testset "consistent index-one initialization and transient integration" begin
    cc=dae_rc(); guess=[17.0,0.4,10.0]; saved=copy(guess)
    condition=consistent_initial_conditions(cc,guess)
    @test condition.state ≈ [1.0,0.4,-0.6]
    @test condition.derivative ≈ [0.0,0.6,0.6] atol=1e-12
    @test guess == saved
    @test condition.stats.classification === :linear_index_one_candidate
    ws=SimulationWorkspace(cc)
    @test norm(residual!(ws,cc,condition.state,condition.derivative,0.0),Inf) < 1e-12
    tr=transient(cc,0.0=>0.1;initial=condition,max_step=0.001)
    @test tr.stats[:converged]
    @test tr.values[:,1] == condition.state
    @test tr.values[2,end] ≈ 1-0.6exp(-0.1) rtol=1e-5
    @test_throws AnalysisValidationError transient(cc,0.1=>0.2;initial=condition)
    @test_throws AnalysisValidationError transient(cc,0.0=>0.1;initial=condition,temperature=310.0)
    changed=with_parameters(cc,"R.value"=>2.0)
    @test_throws AnalysisValidationError transient(changed,0.0=>0.1;initial=condition)
    condition.state[1]+=0.1
    @test_throws AnalysisValidationError transient(cc,0.0=>0.1;initial=condition)
end
@testset "time-varying algebraic constraints" begin
    cc=dae_rc(;waveform=Sine(amplitude=1.0,frequency=0.5)); time=0.25
    condition=consistent_initial_conditions(cc,zeros(cc.n);time)
    @test condition.state[1] ≈ sin(pi*time)
    @test condition.state[2] ≈ 0.0 atol=1e-12
    @test condition.derivative[1] ≈ pi*cos(pi*time)
    @test condition.derivative[2] ≈ sin(pi*time)
    @test_throws DimensionMismatch consistent_initial_conditions(cc,zeros(cc.n);forcing_derivative=[1.0])
    corner=dae_rc(;waveform=Step(at=0.0))
    @test_throws AnalysisValidationError consistent_initial_conditions(corner,zeros(corner.n))
    @test consistent_initial_conditions(corner,zeros(corner.n);forcing_derivative=zeros(corner.n)).state[1] ≈ 1.0
end
@testset "unsupported constraints are not silently initialized" begin
    b=CircuitBuilder(:HigherIndex); g=ground!(b); n=node!(b,:n)
    add!(b,voltage_source(n,g;dc=1.0);name=:Supply)
    add!(b,capacitor(n,g;value=1.0);name=:C)
    cc=compile(finish(b))
    @test dae_structure(cc;numerical=true).classification === :requires_constraint_analysis
    @test_throws AnalysisValidationError consistent_initial_conditions(cc,[0.0,0.0])
    b=CircuitBuilder(:NonlinearDAE); g=ground!(b); n=node!(b,:n)
    add!(b,resistor(n,g;value=1.0);name=:R); add!(b,diode(n,g);name=:D)
    @test_throws AnalysisValidationError consistent_initial_conditions(finish(b),[0.0])
    @test_throws DimensionMismatch consistent_initial_conditions(dae_rc(),[0.0])
end
@testset "rank ambiguity cannot erase a small storage mode" begin
    b=CircuitBuilder(:SmallStorage); g=ground!(b); p=node!(b,:p); n=node!(b,:n)
    add!(b,resistor(p,g;value=1.0);name=:Rp); add!(b,resistor(n,g;value=1.0);name=:Rn)
    add!(b,capacitor(p,n;value=1.0);name=:Coupling)
    add!(b,capacitor(p,g;value=1e-12);name=:Cp); add!(b,capacitor(n,g;value=1e-12);name=:Cn)
    cc=compile(finish(b))
    @test dae_structure(cc;numerical=true).classification === :rank_ambiguous
    @test_throws AnalysisValidationError consistent_initial_conditions(cc,[1.0,1.0])
    condition=consistent_initial_conditions(cc,[1.0,1.0];rank_rtol=1e-14,tolerance=1e-3)
    @test condition.state ≈ [1.0,1.0] rtol=1e-12
    @test condition.stats.storage_rank == 2
end
@testset "DAE condition in analysis descriptors" begin
    cc=dae_rc(); condition=consistent_initial_conditions(cc,[0.0,0.4,0.0])
    result=simulate(cc,Transient(0.0=>0.01;initial=condition,max_step=0.001))
    @test result.stats[:converged]
    @test result.analysis.initial == condition.state
    @test result.analysis.initial !== condition.state
    @test haskey(result.stats,:initialization)
end
@testset "stochastic transient initialization metadata" begin
    cc=dae_rc(); condition=consistent_initial_conditions(cc,[0.0,0.4,0.0])
    result=transient_noise(cc,0.0=>0.002;timestep=0.001,initial=condition,seed=17)
    @test result.stats[:converged]
    @test result.values[:,1] == condition.state
    @test result.analysis.initial == condition.state
    @test haskey(result.stats,:initialization)
end
