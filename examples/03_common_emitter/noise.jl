include("circuit.jl")

amplifier=CommonEmitterAmplifier()
noise_result=noise(amplifier,10Hz=>1MHz;output=voltage(:out),input=:Input,points=300)

println(report(noise_result))
band=20Hz=>20kHz
println((band_Hz=band,output_noise_Vrms=integrated_noise(noise_result,band),
    input_noise_Vrms=integrated_noise(noise_result,band;referred=:input)))
