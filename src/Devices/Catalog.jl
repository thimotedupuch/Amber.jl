# Catalogue devices lower to the existing MNA primitives at construction time.
_positive(name, x) = (isfinite(x) && x > 0) ? x : throw(ArgumentError("$name must be finite and positive"))
_nonnegative(name, x) = (isfinite(x) && x >= 0) ? x : throw(ArgumentError("$name must be finite and nonnegative"))

"""Zener diode, anode first; `breakdown_voltage` is a positive reverse voltage."""
function zener(a, b; breakdown_voltage = 5.1, breakdown_current = 1.0e-3, kw...)
    return diode(
        a, b; model = JunctionDiode(;
            breakdown_voltage = _positive(:breakdown_voltage, breakdown_voltage),
            breakdown_current = _positive(:breakdown_current, breakdown_current), kw...
        )
    )
end
"""Schottky diode with illustrative defaults; override junction parameters for a real part."""
schottky(a, b; kw...) = diode(a, b; model = JunctionDiode(; merge((saturation_current = 1.0e-8, ideality = 1.05), NamedTuple(kw))...))
"""Electrical LED junction (no optical output), with illustrative defaults."""
led(a, b; kw...) = diode(a, b; model = JunctionDiode(; merge((saturation_current = 1.0e-20, ideality = 2.0), NamedTuple(kw))...))

"""Photodiode with constant photocurrent from cathode to anode, in amperes."""
function photodiode(a, b; photocurrent = 0.0, model = JunctionDiode())
    return _component(:photodiode, a, b; photocurrent = _nonnegative(:photocurrent, photocurrent), model)
end
"""Single-junction solar cell with photocurrent and finite shunt resistance."""
function solar_cell(a, b; photocurrent = 1.0, shunt_resistance = 1.0e6, model = JunctionDiode())
    return _component(
        :solar_cell, a, b; photocurrent = _nonnegative(:photocurrent, photocurrent),
        shunt_resistance = _positive(:shunt_resistance, shunt_resistance), model
    )
end

# Callable structs, rather than closures, preserve circuit serialization.
struct CatalogLaw
    kind::Symbol
    parameters::Tuple
end
CatalogLaw(; kind, parameters) = CatalogLaw(kind, parameters)
struct CatalogGradient
    law::CatalogLaw
end
CatalogGradient(; law) = CatalogGradient(law)
(l::CatalogLaw)(v, t) = first(_catalog_value_gradient(l, v))
(g::CatalogGradient)(v, t) = last(_catalog_value_gradient(g.law, v))
function _catalog_value_gradient(l::CatalogLaw, v)
    p = l.parameters; x = v[1]
    if l.kind === :multiplier
        return p[1] * x * v[2] + p[2], (p[1] * v[2], p[1] * x, 0.0, 0.0)
    elseif l.kind === :limiter || l.kind === :comparator
        low, high, gain, offset = p
        mid = (high + low) / 2; span = (high - low) / 2
        y = tanh(gain * (x - offset) / span)
        return mid + span * y, (gain * (1 - y * y), 0.0, 0.0, 0.0)
    elseif l.kind === :vcr
        rmin, rmax, threshold, width = p
        y = tanh((v[2] - threshold) / width)
        r = rmin + (rmax - rmin) * (1 - y) / 2
        dr = -(rmax - rmin) * (1 - y * y) / (2width)
        return x / r, (1 / r, -x * dr / r^2, 0.0, 0.0)
    elseif l.kind === :varistor
        vref, iref, exponent = p
        z = abs(x) / vref
        return iref * sign(x) * z^exponent, (iref * exponent / vref * z^(exponent - 1), 0.0, 0.0, 0.0)
    elseif l.kind === :jfet
        idss, vp, lambda, polarity = p
        # Controls are Vds and Vgs. Swap source/drain in reverse operation.
        d = polarity * x; g = polarity * v[2]; reverse = d < 0
        u = abs(d); gate = reverse ? g - d : g
        over = gate - vp
        over <= 0 && return 0.0, (0.0, 0.0, 0.0, 0.0)
        beta = 2idss / vp^2
        base = u < over ? beta * (over * u - u^2 / 2) : beta * over^2 / 2
        du = (u < over ? beta * (over - u) : 0.0) * (1 + lambda * u) + lambda * base
        dg = beta * min(u, over) * (1 + lambda * u)
        return polarity * (reverse ? -1 : 1) * base * (1 + lambda * u),
            (reverse ? du + dg : du, reverse ? -dg : dg, 0.0, 0.0)
    end
    error("unknown catalogue law $(l.kind)")
end
function _catalog_source(kind, controls, a, b, parameters; voltage = false)
    law = CatalogLaw(kind, parameters)
    return voltage ? behavioral_voltage_source(controls, a, b; voltage = law, gradient = CatalogGradient(law)) :
        behavioral_current_source(controls, a, b; current = law, gradient = CatalogGradient(law))
end
"""Four-quadrant multiplier: V(out)=gain*V(xp,xn)*V(yp,yn)+offset; ideal output."""
function analog_multiplier(xp, xn, yp, yn, a, b; gain = 1.0, offset = 0.0)
    all(isfinite, (gain, offset))||throw(ArgumentError("gain and offset must be finite"))
    return _catalog_source(:multiplier, ((xp, xn), (yp, yn)), a, b, (gain, offset); voltage = true)
end
"""Smooth voltage limiter: midpoint + halfspan*tanh(gain*(Vin-offset)/halfspan)."""
function voltage_limiter(cp, cn, a, b; low = -1.0, high = 1.0, gain = 1.0, offset = 0.0)
    all(isfinite, (low, high, gain, offset))&&high > low||throw(ArgumentError("finite parameters and high > low required"))
    return _catalog_source(:limiter, ((cp, cn),), a, b, (low, high, gain, offset); voltage = true)
end
"""Memoryless smooth comparator with fixed output levels; no delay or hysteresis."""
comparator(cp, cn, a, b; low = 0.0, high = 5.0, gain = 1.0e4, offset = 0.0) = voltage_limiter(cp, cn, a, b; low, high, gain, offset)
"""Smooth voltage-controlled resistor; positive control lowers resistance toward `rmin`."""
function voltage_controlled_resistor(a, b, cp, cn; rmin = 1.0, rmax = 1.0e6, threshold = 0.0, transition = 1.0)
    _positive(:rmin, rmin); _positive(:rmax, rmax); _positive(:transition, transition)
    rmax >= rmin&&isfinite(threshold)||throw(ArgumentError("rmax >= rmin and finite threshold required"))
    return _catalog_source(:vcr, ((a, b), (cp, cn)), a, b, (rmin, rmax, threshold, transition))
end
"""Symmetric power-law varistor: I=iref*sign(V)*abs(V/vref)^exponent. No capacitance or noise."""
function varistor(a, b; vref = 100.0, iref = 1.0e-3, exponent = 10.0)
    _positive(:vref, vref); _positive(:iref, iref)
    isfinite(exponent)&&exponent > 1||throw(ArgumentError("exponent must exceed one"))
    return _catalog_source(:varistor, ((a, b),), a, b, (vref, iref, exponent))
end
"""NTC beta-law resistor at fixed temperature in kelvin; no self-heating."""
function thermistor(a, b; rnom = 1.0e4, beta = 3950.0, temperature = 300.0, nominal_temperature = 298.15)
    foreach(pair -> _positive(pair...), ((:rnom, rnom), (:beta, beta), (:temperature, temperature), (:nominal_temperature, nominal_temperature)))
    resistance = rnom * exp(beta * (1 / temperature - 1 / nominal_temperature))
    return resistor(a, b; value = _positive(:resistance, resistance))
end
"""N-channel square-law JFET, drain/gate/source; negative pinch-off voltage, no gate junction or noise."""
function njfet(d, g, s; idss = 1.0e-3, pinch_off = -2.0, channel_length_modulation = 0.0)
    return _jfet(d, g, s, idss, pinch_off, channel_length_modulation, 1.0)
end
"""P-channel square-law JFET; use the same negative normalized pinch-off as `njfet`."""
function pjfet(d, g, s; idss = 1.0e-3, pinch_off = -2.0, channel_length_modulation = 0.0)
    return _jfet(d, g, s, idss, pinch_off, channel_length_modulation, -1.0)
end
function _jfet(d, g, s, idss, vp, lambda, polarity)
    _positive(:idss, idss); _positive(:negative_pinch_off, -vp); _nonnegative(:channel_length_modulation, lambda)
    return _catalog_source(:jfet, ((d, s), (g, s)), d, s, (idss, vp, lambda, polarity))
end
"""Three-terminal potentiometer (top, wiper, bottom); position is fraction measured from bottom."""
function potentiometer(top, wiper, bottom; resistance = 1.0e4, position = 0.5)
    _positive(:resistance, resistance)
    0 < position < 1||throw(ArgumentError("position must be strictly between zero and one"))
    return _component(:potentiometer, top, wiper, bottom; resistance, position)
end
"""Ideal lossless transformer; V(primary)=ratio*V(secondary), positive terminals dotted."""
function ideal_transformer(pp, pn, sp, sn; ratio = 1.0)
    return _component(:ideal_transformer, pp, pn, sp, sn; ratio = _positive(:ratio, ratio))
end
"""Full-wave diode bridge with terminals (AC1, AC2, positive DC, negative DC)."""
bridge_rectifier(ac1, ac2, p, n; model = JunctionDiode()) = _component(:bridge_rectifier, ac1, ac2, p, n; model)
"""Quartz equivalent: series motional RLC in parallel with static capacitance (SI units)."""
function crystal(a, b; motional_resistance = 10.0, motional_inductance = 0.01, motional_capacitance = 1.0e-12, shunt_capacitance = 5.0e-12)
    foreach(
        pair -> _positive(pair...), (
            (:motional_resistance, motional_resistance), (:motional_inductance, motional_inductance),
            (:motional_capacitance, motional_capacitance), (:shunt_capacitance, shunt_capacitance),
        )
    )
    return _component(:crystal, a, b; motional_resistance, motional_inductance, motional_capacitance, shunt_capacitance)
end
"""Lumped RLGC line (input, output, reference); R,L,G,C are TOTAL line values, split into pi sections."""
function transmission_line(input, output, reference; resistance = 1.0, inductance = 1.0e-6, conductance = 0.0, capacitance = 1.0e-10, sections = 10)
    _nonnegative(:resistance, resistance); _positive(:inductance, inductance)
    _nonnegative(:conductance, conductance); _positive(:capacitance, capacitance)
    sections isa Integer&&1 <= sections <= 10000||throw(ArgumentError("sections must be an integer in 1:10000"))
    return _component(:transmission_line, input, output, reference; resistance, inductance, conductance, capacitance, sections)
end

const _CATALOG_COMPOSITES = (:photodiode, :solar_cell, :potentiometer, :ideal_transformer, :bridge_rectifier, :crystal, :transmission_line)
function _add_catalog!(builder, component, name)
    k = _draft_kind(component); q = component.terminals; p = component.parameters
    add(part, suffix) = add!(builder, part; name = isempty(suffix) ? name : _hidden_name(name, suffix))
    hidden(suffix) = node!(builder, _hidden_name(name, suffix))
    if k in (:photodiode, :solar_cell)
        terminal = q[1]; model = p.model
        if model.series_resistance > 0
            terminal = hidden("__junction")
            add(resistor(q[1], terminal; value = model.series_resistance), "series_resistance")
            model = with_model_parameter(model, :series_resistance, 0.0)
        end
        main = add(diode(terminal, q[2]; model), "")
        add(current_source(q[2], terminal; dc = p.photocurrent), "photocurrent")
        k === :solar_cell&&add(resistor(terminal, q[2]; value = p.shunt_resistance), "shunt")
    elseif k === :potentiometer
        main = add(resistor(q[1], q[2]; value = p.resistance * (1 - p.position)), "")
        add(resistor(q[2], q[3]; value = p.resistance * p.position), "bottom")
    elseif k === :ideal_transformer
        main = add(voltage_controlled_voltage_source(q[3], q[4], q[1], q[2]; gain = p.ratio), "")
        add(current_controlled_current_source(main, q[3], q[4]; gain = -p.ratio), "secondary")
    elseif k === :bridge_rectifier
        main = add(diode(q[1], q[3]; model = p.model), "")
        add(diode(q[2], q[3]; model = p.model), "ac2_positive")
        add(diode(q[4], q[1]; model = p.model), "negative_ac1")
        add(diode(q[4], q[2]; model = p.model), "negative_ac2")
    elseif k === :crystal
        rnode = hidden("__r"); lnode = hidden("__l")
        main = add(capacitor(q...; value = p.shunt_capacitance), "")
        add(resistor(q[1], rnode; value = p.motional_resistance), "motional_r")
        add(inductor(rnode, lnode; value = p.motional_inductance), "motional_l")
        add(capacitor(lnode, q[2]; value = p.motional_capacitance), "motional_c")
    elseif k === :transmission_line
        previous = q[1]; main = nothing
        for i in 1:p.sections
            next = i == p.sections ? q[2] : hidden("__section$i")
            handle = add(
                inductor(
                    previous, next; value = p.inductance / p.sections,
                    winding_resistance = p.resistance / p.sections
                ), i == 1 ? "" : "section$(i)_l"
            )
            i == 1&&(main = handle)
            for (terminal, side) in ((previous, "in"), (next, "out"))
                add(capacitor(terminal, q[3]; value = p.capacitance / (2p.sections)), "section$(i)_$(side)_c")
                p.conductance > 0&&add(conductance(terminal, q[3]; value = p.conductance / (2p.sections)), "section$(i)_$(side)_g")
            end
            previous = next
        end
    end
    return main
end

_SERIALIZABLE_STRUCTS["CatalogLaw"] = CatalogLaw
_SERIALIZABLE_STRUCTS["CatalogGradient"] = CatalogGradient
