@testset "small signal" begin
    result=small_signal(LowPass(),10Hz=>1MHz;points=20)
    @test abs(voltage(result,:vout)[1])>.9; @test length(frequencies(result))==20
    @circuit BiasedAC() begin
        gnd=ground(); supply=node(); input=node(); output=node()
        VDD=voltage_source(supply,gnd;dc=12V)
        Vin=voltage_source(input,gnd;dc=2V,ac=1V)
        R1=resistor(input,output;value=1kΩ); R2=resistor(output,gnd;value=1kΩ)
    end
    biased=small_signal(BiasedAC(),1kHz=>1kHz;source=:Vin)
    @test voltage(biased,:output)[1]≈.5V
    @test voltage(biased,:supply)[1]≈0V
end
