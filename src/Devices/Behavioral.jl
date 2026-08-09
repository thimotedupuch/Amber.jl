opamp(p,n,o,vp,vn;model=BehavioralOpAmp(),kw...)=_component(:opamp,p,n,o,vp,vn;model,kw...)
analog_switch(a,b,cp,cn;model=VoltageControlledSwitch(),kw...)=_component(:switch,a,b,cp,cn;model,kw...)

"""A nonlinear current source controlled by as many as four differential voltages.

`current(v, t)` returns the current flowing from `output_p` to `output_n`, where
`v` is a four-tuple of control voltages. `gradient(v, t)` must return the four
partial derivatives of that current. Unused controls may be omitted and are
internally tied to the output reference node.

This primitive is intended for compact constitutive laws and system-dynamics
experiments. Supplying the analytic gradient keeps Amber's Newton matrix
consistent with the residual.
"""
function behavioral_current_source(controls::Tuple, output_p, output_n; current, gradient, kw...)
    length(controls) <= 4 || throw(ArgumentError("behavioral_current_source supports at most four differential controls"))
    all(control -> control isa Tuple && length(control) == 2, controls) ||
        throw(ArgumentError("controls must be `(positive, negative)` node pairs"))
    padded = ntuple(index -> index <= length(controls) ? controls[index] : (output_n, output_n), 4)
    terminals = (output_p, output_n, Iterators.flatten(padded)...)
    _component(:behavioral_current_source, terminals...; current, gradient, control_count=length(controls), kw...)
end

"""A nonlinear voltage source controlled by as many as four differential voltages.

`voltage(v, t)` returns the voltage imposed from `output_p` to `output_n`, where
`v` is a four-tuple of control voltages. `gradient(v, t)` must return the four
partial derivatives of that voltage. Unused controls may be omitted and are
internally tied to the output reference node.

The source introduces an ideal branch-current unknown and an explicit nonlinear
voltage constraint. Use a series resistor externally when finite output
impedance is required.
"""
function behavioral_voltage_source(controls::Tuple, output_p, output_n; voltage, gradient, kw...)
    length(controls) <= 4 || throw(ArgumentError("behavioral_voltage_source supports at most four differential controls"))
    all(control -> control isa Tuple && length(control) == 2, controls) ||
        throw(ArgumentError("controls must be `(positive, negative)` node pairs"))
    padded = ntuple(index -> index <= length(controls) ? controls[index] : (output_n, output_n), 4)
    terminals = (output_p, output_n, Iterators.flatten(padded)...)
    _component(:behavioral_voltage_source, terminals...; voltage, gradient, control_count=length(controls), kw...)
end
