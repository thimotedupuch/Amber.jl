include("circuit.jl")

rectifier=HalfWaveRectifier()
result=transient(rectifier,0s=>500ms;reltol=1e-6,max_step=100μs)
println(report(result)) # full saved record, including startup stresses
settled_window=460ms=>500ms
println(report(result;window=settled_window))
println((window_s=settled_window,
    output_ripple_Vpp=peak_to_peak(voltage(:vout);window=settled_window)(result)))
