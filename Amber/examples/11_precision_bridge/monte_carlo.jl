include("circuit.jl")
using LinearAlgebra

# Zero applied strain isolates bridge/amplifier offset from the useful signal.
bridge = PrecisionBridge(strain = 0.0)
bridge_covariance = fill((0.2Ω)^2 * 0.8, 4, 4) + Diagonal(fill((0.2Ω)^2 * 0.2, 4))
bridge_variation = CorrelatedVariation(
    Symbol.("Rbridge" .* string.(1:4) .* ".value"), fill(1kΩ, 4), bridge_covariance
)
offsets = monte_carlo(
    bridge; samples = 1_000, seed = 0xA8B3_2026,
    correlated = bridge_variation, parallel = true,
    metric = result -> voltage(result, :output)[1]
)
offset_yield = yield_rate(offsets, offset -> abs(offset) < 10mV)
offset_interval = yield_confidence_interval(offsets, offset -> abs(offset) < 10mV)
