include("circuit.jl")

G = [2.0 1.0 0.5; 0.5 1.5 2.0] .* μS
vin = [0.2, 0.5, 0.8] .* V
feedback_resistance = 100kΩ
crossbar = ConductanceCrossbar(; conductances = G, inputs = vin, feedback_resistance)
result = operating_point(crossbar)
simulated = [voltage(result, Symbol(:output_, row))[1] for row in axes(G, 1)]
expected = -feedback_resistance .* (G * vin)
