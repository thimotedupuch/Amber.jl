using Amber

"""
A regenerative latch biased just beyond its saddle-node trip point.

The two 1 mS shunts are opposed by 1.001 mS cross-coupled transconductors.
Antiparallel diode clamps create the stable latched states.  A 236.908 nA
differential bias places the disappearing local root close enough to singular
that ordinary Newton/source stepping follows the wrong branch.
"""
@circuit RegenerativeLatch(; bias_current = 236.908021074324nA) begin
    gnd = ground()
    q = node()
    qb = node()

    Rq = resistor(q, gnd; value = 1kΩ)
    Rqb = resistor(qb, gnd; value = 1kΩ)
    Gq = transconductance(qb, gnd, q, gnd; gm = 1.001mS)
    Gqb = transconductance(q, gnd, qb, gnd; gm = 1.001mS)

    clamp = JunctionDiode(saturation_current = 1.0e-12, ideality = 1.0)
    Dqp = diode(q, gnd; model = clamp)
    Dqn = diode(gnd, q; model = clamp)
    Dqbp = diode(qb, gnd; model = clamp)
    Dqbn = diode(gnd, qb; model = clamp)

    BiasQ = current_source(gnd, q; dc = -bias_current)
    BiasQb = current_source(qb, gnd; dc = -bias_current)
    observe(q, qb)
end
