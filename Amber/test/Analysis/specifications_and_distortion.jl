using Test, Amber
@testset "named measurement specifications" begin
    spec = Amber.MeasurementSpec(:voltage, identity; lower=1V, upper=2V)
    @test Amber.assess(spec, 1V).status == :pass
    @test Amber.assess(spec, 3V).status == :fail
    @test Amber.assess(spec, NaN*V).status == :unresolved
    @test Amber.assess(spec, 1s).status == :unresolved
    @test Amber.assess(Amber.MeasurementSpec(:missing, _ -> missing), nothing).status == :unresolved
    @test_throws ArgumentError Amber.assess([spec,spec], 1V)
end
@testset "quasi-static weak nonlinear products" begin
    x = collect(range(-1,1; length=31)) .* V
    y = (2 .+ 3 .* (x ./ V) .+ 4 .* (x ./ V).^2 .+ 5 .* (x ./ V).^3) .* A
    model = Amber.quasistatic_distortion(x,y; bias=0V)
    h = Amber.distortion_harmonics(model, 0.1V)
    @test h.second ≈ 0.02A
    @test h.third ≈ 0.00125A
    @test h.fundamental ≈ 0.30375A
    @test model.relative_fit_error < 1e-12
    im = Amber.distortion_intermodulation(model, 0.1V)
    @test im.im2 ≈ 0.04A
    @test im.im3 ≈ 0.00375A
    @test_throws ArgumentError Amber.distortion_intermodulation(model, 0.6V)
end
@testset "distortion domain and linear limit" begin
    x = collect(range(-0.1, 0.1; length=11))
    model = Amber.quasistatic_distortion(x, 2 .* x; bias=0.0)
    h = Amber.distortion_harmonics(model, 0.01)
    @test h.thd < 1e-12
    @test h.fundamental ≈ 0.02
    @test_throws ArgumentError Amber.quasistatic_distortion(reverse(x), x; bias=0.0)
    @test_throws ArgumentError Amber.quasistatic_distortion(x,x; bias=0.2)
    @test_throws ArgumentError Amber.distortion_harmonics(model, 0.0)
end
@testset "distortion versus direct Fourier projection" begin
    x = collect(range(-0.5,0.5; length=21))
    f(x) = 0.7 + 2x - 3x^2 + 4x^3
    model = Amber.quasistatic_distortion(x, f.(x); bias=0.0)
    a = 0.03
    theta = (0:4095) .* (2pi/4096)
    y = f.(a .* cos.(theta))
    amplitudes = [2sum(y .* cos.(k .* theta))/length(theta) for k in 1:3]
    h = Amber.distortion_harmonics(model,a)
    @test [h.fundamental,h.second,h.third] ≈ amplitudes atol=1e-14
    # Nondegenerate integer tone indices avoid overlapping products.
    ymix = f.(a .* (cos.(7 .* theta) .+ cos.(19 .* theta)))
    im = Amber.distortion_intermodulation(model,a)
    @test im.im2 ≈ 2sum(ymix .* cos.(12 .* theta))/length(theta) atol=1e-14
    @test im.im3 ≈ 2sum(ymix .* cos.(5 .* theta))/length(theta) atol=1e-14
end
