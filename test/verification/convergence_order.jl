@testset "verification: transient convergence order" begin
    @circuit ConvergenceRC() begin
        gnd=ground(); input=node(); output=node()
        V1=voltage_source(input,gnd;waveform=Step(low=0V,high=1V,at=0s))
        R1=resistor(input,output;value=1kΩ); C1=capacitor(output,gnd;value=100nF)
    end
    reference(t)=1-exp(-t/100μs); stop=500μs
    steps=(20μs,10μs,5μs)
    first_order=[final_error(transient(ConvergenceRC(),0s=>stop;initial=:discharged,saveat=step,method=:bdf1),:output,reference) for step in steps]
    second_order=[final_error(transient(ConvergenceRC(),0s=>stop;initial=:discharged,saveat=step,method=:bdf2),:output,reference) for step in steps]
    @test observed_order(first_order[2],first_order[3])>0.8
    @test observed_order(second_order[2],second_order[3])>1.7
    @test second_order[end]<first_order[end]
end

