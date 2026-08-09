using Amber

"""Normalized resistively and capacitively shunted Josephson junction (RCSJ)."""
@circuit JosephsonJunction(; bias=1.15, damping=0.25) begin
    gnd=ground(); phase=node(); phase_velocity=node()
    Cphase=capacitor(phase,gnd;value=1.0); Cvelocity=capacitor(phase_velocity,gnd;value=1.0)
    resistor(phase,gnd;value=1e15); resistor(phase_velocity,gnd;value=1e15)
    controls=((phase,gnd),(phase_velocity,gnd))
    # phi' = omega; omega' = i_b - sin(phi) - damping*omega. A smooth bias
    # turn-on gives the transient initializer the zero-bias equilibrium.
    applied_bias(t)=bias*(1-exp(-t/0.25))
    behavioral_current_source(controls,phase,gnd;current=(x,t)->-x[2],
        gradient=(x,t)->(0.,-1.,0.,0.))
    behavioral_current_source(controls,phase_velocity,gnd;
        current=(x,t)->sin(x[1])+damping*x[2]-applied_bias(t),
        gradient=(x,t)->(cos(x[1]),damping,0.,0.))
    initial_voltage(Cphase,0.0); initial_voltage(Cvelocity,0.0)
    observe(phase); observe(phase_velocity)
end


josephson_result=transient(JosephsonJunction(),0s=>40s;max_step=2ms)
# Multiply normalized time and phase velocity by the junction's plasma-frequency
# scales to recover seconds and volts for a particular Ic, C, and junction technology.
