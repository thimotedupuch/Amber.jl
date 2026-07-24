include("circuit.jl")

oscillator=WienOscillator()
result=transient(oscillator,0s=>20ms;initialization=:consistent,reltol=1e-7,max_step=500ns)
metrics=periodic_metrics(result;signal=voltage(:output),window=15ms=>20ms)
