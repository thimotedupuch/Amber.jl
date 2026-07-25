@testset "verification: KCL and power conservation" begin
    @circuit PowerBalance() begin
        gnd=ground(); supply=node(); middle=node()
        V1=voltage_source(supply,gnd;dc=10V)
        R1=resistor(supply,middle;value=1kΩ); R2=resistor(middle,gnd;value=1kΩ)
    end
    circuit=PowerBalance(); result=operating_point(circuit); compiled=result.compiled; point=result.values[:,1]
    @test norm(Amber.residual(compiled,point,zero(point),0.;mode=:dc),Inf)<1e-12
    total_power=sum(power(result,name)[1] for name in (:V1,:R1,:R2))
    @test abs(total_power)<1e-12

    @circuit ReactiveBalance() begin
        gnd=ground(); input=node(); output=node()
        V1=voltage_source(input,gnd;waveform=Sine(amplitude=1V,frequency=2kHz))
        R1=resistor(input,output;value=1kΩ); C1=capacitor(output,gnd;value=100nF)
    end
    transient_result=transient(ReactiveBalance(),0s=>1ms;initial=:discharged,saveat=1μs,method=:bdf2)
    stored=charge(transient_result,:C1)
    @test all(isfinite,stored)
    mismatch=abs.(current(transient_result,:R1).-current(transient_result,:C1))
    @test maximum(mismatch[3:end-2])<5μA
end
