include("circuit.jl")

pair = DifferentialPair()
ac = small_signal(pair, 1Hz => 100MHz; excitation = Differential(:Vplus, :Vminus))
