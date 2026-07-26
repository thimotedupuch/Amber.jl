include("circuit.jl")

amplifier=CommonEmitterAmplifier()
noise_result=noise(amplifier,10Hz=>1MHz;output=voltage(:out),input=:Input,points=300)
