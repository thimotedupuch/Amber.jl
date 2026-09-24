using Amber

"""Classic space-clamped Hodgkin--Huxley membrane; voltage is in V and gates in V/V."""
@circuit HodgkinHuxley(; stimulus = 10.0) begin
    gnd = ground()
    membrane = node(); m_gate = node(); h_gate = node(); n_gate = node()

    # One farad makes KCL read directly as dx/dt = f(x). Since 1 mV/ms = 1 V/s,
    # the standard 1952 equations need no time conversion for membrane voltage.
    Cm = capacitor(membrane, gnd; value = 1.0)
    Cmg = capacitor(m_gate, gnd; value = 1.0)
    Chg = capacitor(h_gate, gnd; value = 1.0)
    Cng = capacitor(n_gate, gnd; value = 1.0)
    for state in (membrane, m_gate, h_gate, n_gate)
        resistor(state, gnd; value = 1.0e15)
    end

    vtrap(x, y) = abs(x / y) < 1.0e-6 ? y * (1 - x / (2y)) : x / expm1(x / y)
    rates(v) = begin
        vm = 1.0e3v
        (
            0.1vtrap(25 - vm, 10), 4exp(-vm / 18), 0.07exp(-vm / 20),
            inv(exp((30 - vm) / 10) + 1), 0.01vtrap(10 - vm, 10), 0.125exp(-vm / 80),
        )
    end
    dynamics(x, _) = begin
        v, m, h, n = x; am, bm, ah, bh, an, bn = rates(v)
        ina = 120m^3 * h * (1.0e3v - 115); ik = 36n^4 * (1.0e3v + 12); il = 0.3 * (1.0e3v - 10.613)
        (
            (stimulus - ina - ik - il), 1.0e3 * (am * (1 - m) - bm * m),
            1.0e3 * (ah * (1 - h) - bh * h), 1.0e3 * (an * (1 - n) - bn * n),
        )
    end
    function jacobian_row(row, x, t)
        epsilon = 1.0e-6; base = dynamics(x, t)[row]
        ntuple(
            j -> begin
                shifted = Base.setindex(x, x[j] + epsilon, j)
                (dynamics(shifted, t)[row] - base) / epsilon
            end, 4
        )
    end
    controls = ((membrane, gnd), (m_gate, gnd), (h_gate, gnd), (n_gate, gnd))
    behavioral_current_source(
        controls, membrane, gnd;
        current = (x, t) -> -dynamics(x, t)[1], gradient = (x, t) -> .-jacobian_row(1, x, t)
    )
    behavioral_current_source(
        controls, m_gate, gnd;
        current = (x, t) -> -dynamics(x, t)[2], gradient = (x, t) -> .-jacobian_row(2, x, t)
    )
    behavioral_current_source(
        controls, h_gate, gnd;
        current = (x, t) -> -dynamics(x, t)[3], gradient = (x, t) -> .-jacobian_row(3, x, t)
    )
    behavioral_current_source(
        controls, n_gate, gnd;
        current = (x, t) -> -dynamics(x, t)[4], gradient = (x, t) -> .-jacobian_row(4, x, t)
    )
    initial_voltage(Cm, -65mV); initial_voltage(Cmg, 0.053)
    initial_voltage(Chg, 0.596); initial_voltage(Cng, 0.318)
    observe(membrane); observe(m_gate); observe(h_gate); observe(n_gate)
end

hh_result = transient(HodgkinHuxley(), 0s => 20ms; max_step = 20μs)
