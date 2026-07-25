include("circuit.jl")

oscillator=WienOscillator()
result=transient(oscillator,0s=>20ms;reltol=1e-7,max_step=500ns)
metrics=harmonic_analysis(result;signal=voltage(:output),interval=15ms=>20ms)
