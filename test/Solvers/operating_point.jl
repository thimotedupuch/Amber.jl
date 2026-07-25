@testset "operating point" begin
    op=operating_point(LowPass()); @test op.stats[:converged]
    bjt=operating_point(BiasedNPN()); @test bjt.stats[:converged]
    @test region(bjt,:Q1) in (ForwardActive,Saturation)
    @circuit DCVersusWaveform() begin
        gnd=ground(); output=node()
        V1=voltage_source(output,gnd;dc=2V,waveform=Step(low=7V,high=9V,at=1s))
    end
    @test voltage(operating_point(DCVersusWaveform()),:output)[1]≈2V
end


@testset "temperature-aware operating point" begin
    cold=operating_point(BiasedNPN();temperature=250.)
    hot=operating_point(BiasedNPN();temperature=350.)
    @test cold.stats[:converged]&&hot.stats[:converged]
    @test voltage(cold,:base)[1]!=voltage(hot,:base)[1]
end
