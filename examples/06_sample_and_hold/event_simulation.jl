include("circuit.jl")

sampler=SampleAndHold()
result=transient(sampler,0s=>1ms;event_mode=:exact,max_step=50ns)
errors=sampling_metrics(result;input=voltage(:vin),held=voltage(:hold),clock=voltage(:clk))
