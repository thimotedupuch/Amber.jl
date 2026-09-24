using LinearAlgebra
using Statistics

relative_error(actual, expected) = norm(actual - expected) / max(norm(expected), eps(Float64))
observed_order(coarse, fine) = log2(coarse / fine)

function final_error(result, signal, reference)
    return abs(voltage(result, signal)[end] - reference(last(result.axis)))
end
