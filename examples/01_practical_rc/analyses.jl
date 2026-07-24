include("circuit.jl")

filter=PracticalLowPass()
op=operating_point(filter)
ac=small_signal(filter,10Hz=>1GHz;points=500,scale=:log)
tran=transient(filter,0s=>2ms;reltol=1e-7,saveat=1μs)
