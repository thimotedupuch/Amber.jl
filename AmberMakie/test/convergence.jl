@testset "convergence diagnostic history" begin
    fake = (stats=Dict(:converged=>false, :residual_history=>[
        (residual_norm=1.0, update_norm=2.0, damping=0.5, source_scale=0.1, gmin=1e-3),
        (residual_norm=0.0, update_norm=0.0, damping=0.0, source_scale=1.0, gmin=0.0)]),)
    view = convergenceview(fake)
    @test view.residuals == [1.0,0.0]
    @test !view.converged
    handle = convergenceplot(Makie.Figure()[1,1], fake)
    @test handle.view.history == fake.stats[:residual_history]
    @test hasproperty(handle.axes, :damping)
    empty_handle = convergenceplot(Makie.Figure()[1,1], (stats=Dict{Symbol,Any}(),))
    @test isempty(empty_handle.view.history)
end
