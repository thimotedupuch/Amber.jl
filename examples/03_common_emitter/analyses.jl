include("circuit.jl")

amplifier = CommonEmitterAmplifier()
op = operating_point(amplifier)
ac = small_signal(amplifier, 10Hz => 100MHz; source = :Input, points = 600)
gain = transfer(ac; input = voltage(:src), output = voltage(:out))
