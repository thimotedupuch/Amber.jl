include("generator.jl")

line = RLGCLine(length = 2m, sections = 200)
compiled = compile(line)
result = transient(compiled, 0s => 50ns; reltol = 1.0e-6, max_step = 20ps)
delay = propagation_delay(result; input = :x0, output = :x200)
output_overshoot = overshoot(result, :x200)
