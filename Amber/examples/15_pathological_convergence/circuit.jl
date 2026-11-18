using Amber

"""
A deliberately hostile but physical DC problem.

The low-leakage diode operates above 40 thermal voltages, while the 1 TΩ
divider carries only 50 pA.  Those two regimes catch both premature
exponential clamping and false convergence based only on absolute KCL
residuals.
"""
@circuit PathologicalConvergence() begin
    gnd = ground()
    supply = node()
    diode_bias = node()
    divider_midpoint = node()

    Supply = voltage_source(supply, gnd; dc = 100V)
    Limit = resistor(supply, diode_bias; value = 10kΩ)
    LowLeakage = diode(
        diode_bias, gnd;
        model = JunctionDiode(saturation_current = 1.0e-20, ideality = 1.0)
    )

    DividerHigh = resistor(supply, divider_midpoint; value = 1TΩ)
    DividerLow = resistor(divider_midpoint, gnd; value = 1TΩ)

    observe(diode_bias, divider_midpoint)
end
