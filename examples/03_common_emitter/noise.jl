include("circuit.jl")

amplifier=CommonEmitterAmplifier()
noise_result=noise(amplifier,10Hz=>1MHz;output=voltage(:out),referred_to=:Input,points=300)
