using Statistics

@testset "Monte Carlo" begin
    variations=Dict(Symbol("R1.value")=>Gaussian(10kΩ,500Ω))
    metric=result->voltage(result,:vout)[1]
    first_run=monte_carlo(LowPass();samples=24,seed=42,variations,metric)
    second_run=monte_carlo(LowPass();samples=24,seed=42,variations,metric)
    @test first_run isa MonteCarloResult
    @test first_run.seeds==second_run.seeds
    @test sample_parameters(first_run)==sample_parameters(second_run)
    @test sample_values(first_run)==sample_values(second_run)
    @test all(first_run.converged)
    @test length(successful(first_run))==24
    @test isfinite(mean(first_run))
    @test isfinite(std(first_run))
    @test isfinite(quantile(first_run,.9))
    @test yield_rate(first_run,value->value>=0)==1
    @test 0<=yield_confidence_interval(first_run,value->value>=0).first<=yield_confidence_interval(first_run,value->value>=0).second<=1
    @test failure_rate(first_run)==0
    @test report(first_run)[:successful_samples]==24
    @test provenance(first_run)[:monte_carlo][:seed]==42
    @test confidence_interval(first_run).first<=mean(first_run)<=confidence_interval(first_run).second
    @test replay_sample(first_run,LowPass(),3;metric)==sample_values(first_run)[3]
    process=ProcessVariation(Dict(Symbol("R1.value")=>Gaussian(10kΩ,100Ω)))
    process_run=monte_carlo(LowPass();samples=4,seed=9,process,metric,parallel=true)
    @test all(process_run.converged)
    @test eltype(process_run.values)<:Union{Nothing,Float64}
    serialized=serialize_monte_carlo(process_run); restored=deserialize_monte_carlo(serialized)
    @test sample_values(restored)==sample_values(process_run)
    @test sample_parameters(restored)==sample_parameters(process_run)
    @test restored.seeds==process_run.seeds
    obsolete=replace(serialized,"schema_version = 2"=>"schema_version = 1";count=1)
    @test_throws CircuitSerializationError deserialize_monte_carlo(obsolete)
    correlated=CorrelatedVariation([Symbol("R1.value"),Symbol("C1.value")],[10kΩ,10nF],[100.0^2 0.;0. (1nF)^2])
    correlated_run=monte_carlo(LowPass();samples=4,seed=11,correlated,metric)
    @test all(correlated_run.converged)
    @test_throws ArgumentError monte_carlo(LowPass();samples=1,variations=Dict(Symbol("missing.value")=>Gaussian(1,1)),metric)

    @circuit ToleranceLowPass() begin
        gnd=ground(); vin=node(); vout=node()
        V1=voltage_source(vin,gnd;dc=1V)
        R1=resistor(vin,vout;value=10kΩ,tolerance=.1)
        C1=capacitor(vout,gnd;value=10nF)
    end
    tolerance_circuit=ToleranceLowPass()
    tolerance_run=monte_carlo(tolerance_circuit;samples=12,seed=7,metric)
    resistance_draws=[draw[Symbol("R1.value")] for draw in sample_parameters(tolerance_run)]
    @test all(9kΩ .<= resistance_draws .<= 11kΩ)
    @test length(unique(resistance_draws))>1

    failed=monte_carlo(LowPass();samples=3,seed=1,
        variations=Dict(Symbol("R1.value")=>Gaussian(0,0)),metric)
    @test count(!,failed.converged)==3
    @test length(failed.failures)==3
    @test failure_rate(failed)==1
end

@testset "matched-group Monte Carlo" begin
    module_ = Module(:MonteCarloDifferentialPair)
    Base.include(module_,normpath(joinpath(@__DIR__,"..","..","examples","04_differential_pair","circuit.jl")))
    circuit=getfield(module_,:DifferentialPair)()
    result=monte_carlo(circuit;samples=8,seed=123,metric=simulation->voltage(simulation,:outp)[1]-voltage(simulation,:outn)[1])
    @test all(result.converged)
    @test all(draw->all(haskey(draw,path) for path in (Symbol("Q1.saturation_current"),Symbol("Q2.saturation_current"),Symbol("Q1.forward_beta"),Symbol("Q2.forward_beta"))),sample_parameters(result))
    @test length(unique(sample_values(result)))>1
end
