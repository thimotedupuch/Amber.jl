@testset "analysis metrics" begin
    result=transient(LowPass(),0s=>1ms;saveat=10μs)
    ripple=peak_to_peak(voltage(:vout),window=500μs=>1ms)
    @test ripple(result)>=0
    @test overshoot(result,:vout)>=0
    @test propagation_delay(result;input=:vin,output=:vout)>0
    periodic_module=Module(:PeriodicMetricsTest)
    Core.eval(periodic_module,:(using Amber))
    periodic_result=transient(LowPass(),0s=>1ms;saveat=10μs)
    comparison=compare(small_signal(LowPass(),10Hz=>1kHz;points=10),small_signal(LowPass(R=20kΩ),10Hz=>1kHz;points=10);observable=voltage(:vout))
    @test length(comparison.error)==10
end
