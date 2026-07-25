@testset "descriptor and control analysis" begin
    model=linearize(LowPass();inputs=:V1,outputs=voltage(:vout))
    response=frequency_response(model,[10Hz,1kHz,100kHz])
    @test size(response.values)==(1,1,3)
    @test abs(response.values[1,1,1])>.99
    @test dcgain(model)[1]≈1
    finite_poles=poles(model)
    @test any(value->isapprox(value,-10_000;rtol=1e-6),finite_poles)
    @test isstable(model)
    @test any(isinf,poles(model;include_infinite=true))

    time=step_response(model,0s=>1ms;saveat=10μs)
    @test time.values[1,1,end]>.99
    @test rise_time(time)>0
    @test settling_time(time)>0
    @test abs(steady_state_error(time))<1e-3
    @test length(root_locus(model,0.:1.:2.))==3
end
