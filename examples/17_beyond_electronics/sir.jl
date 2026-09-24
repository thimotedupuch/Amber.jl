using Amber

"""Normalized SIR epidemic dynamics (one simulation second represents one day)."""
@circuit SIREpidemic(; beta = 0.32, gamma = 0.1, susceptible0 = 0.999, infected0 = 0.001) begin
    gnd = ground(); susceptible = node(); infected = node(); recovered = node()
    Cs = capacitor(susceptible, gnd; value = 1.0)
    Ci = capacitor(infected, gnd; value = 1.0)
    Cr = capacitor(recovered, gnd; value = 1.0)
    for state in (susceptible, infected, recovered)
        resistor(state, gnd; value = 1.0e15)
    end
    rhs(x, t) = (-beta * x[1] * x[2], beta * x[1] * x[2] - gamma * x[2], gamma * x[2], 0.0)
    gradients = (
        (-beta * infected0, -beta * susceptible0, 0.0, 0.0),
        (beta * infected0, beta * susceptible0 - gamma, 0.0, 0.0), (0.0, gamma, 0.0, 0.0),
    )
    controls = ((susceptible, gnd), (infected, gnd), (recovered, gnd))
    behavioral_current_source(
        controls, susceptible, gnd; current = (x, t) -> -rhs(x, t)[1],
        gradient = (x, t) -> (beta * x[2], beta * x[1], 0.0, 0.0)
    )
    behavioral_current_source(
        controls, infected, gnd; current = (x, t) -> -rhs(x, t)[2],
        gradient = (x, t) -> (-beta * x[2], gamma - beta * x[1], 0.0, 0.0)
    )
    behavioral_current_source(
        controls, recovered, gnd; current = (x, t) -> -rhs(x, t)[3],
        gradient = (x, t) -> (0.0, -gamma, 0.0, 0.0)
    )
    initial_voltage(Cs, susceptible0); initial_voltage(Ci, infected0)
    initial_voltage(Cr, 1 - susceptible0 - infected0)
    observe(susceptible); observe(infected); observe(recovered)
end

sir_result = transient(SIREpidemic(), 0s => 160s; max_step = 0.1s)
