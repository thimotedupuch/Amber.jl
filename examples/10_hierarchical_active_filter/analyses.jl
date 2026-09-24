include("circuit.jl")

filter = HierarchicalActiveFilter()
bias = operating_point(filter)
response = small_signal(filter, 10Hz => 1MHz; source = :Source, points = 400)
step_response = transient(filter, 0s => 1ms; saveat = 1μs)
gain = transfer(response; input = voltage(:input), output = voltage(:output))
