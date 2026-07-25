@testset "verification: thermal-noise reference" begin
    resistance=7.5kΩ; temperature=333.
    @circuit ResistorNoise() begin
        gnd=ground(); output=node(); R1=resistor(output,gnd;value=resistance)
    end
    result=noise(ResistorNoise(),1kHz=>1kHz;output=voltage(:output),points=1,temperature)
    expected=sqrt(4*1.380649e-23*temperature*resistance)
    @test output_noise_density(result)[1]≈expected rtol=2e-12
end

