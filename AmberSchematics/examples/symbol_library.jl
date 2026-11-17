using Amber, AmberSchematics

@circuit SymbolLibrary() begin
    a = node(); b = node(); c = node(); d = node(); e = ground()
    R = resistor(a, b; value = 1000)
    R_IEC = resistor(a, b; value = 1000)
    R_var = resistor(a, b; value = 1000)
    G = conductance(a, b; value = 0.001)
    C = capacitor(a, b; value = 1e-6)
    C_pol = capacitor(a, b; value = 1e-6)
    C_var = capacitor(a, b; value = 1e-6)
    L = inductor(a, b; value = 1e-3)
    D = diode(a, b)
    DZ = zener(a, b)
    DS = schottky(a, b)
    DL = led(a, b)
    DP = diode(a, b)
    V = voltage_source(a, b)
    I = current_source(a, b)
    E = voltage_controlled_voltage_source(a, b, c, d)
    F = current_controlled_current_source(V, c, d)
    H = current_controlled_voltage_source(V, c, d)
    GM = transconductance(a, b, c, d)
    S = analog_switch(a, b, c, d)
    Q = npn(a, b, c; model = GummelPoonBJT(base_resistance = 0))
    MN = nmos(a, b, c, d)
    MP = pmos(a, b, c, d)
    U = opamp(a, b, c, d, e)
    MN_tied = nmos(a, b, c, c)
    MP_tied = pmos(a, b, c, c)
    MN_logic = nmos(a, b, c, c)
    MP_logic = pmos(a, b, c, c)
    Vac = voltage_source(a, b; waveform = Sine(amplitude = 1, frequency = 50))
end

symbols = Dict(:R_IEC => :iec_resistor, :R_var => :variable_resistor,
    :C_pol => :polarized_capacitor, :C_var => :variable_capacitor,
    :DZ => :zener, :DS => :schottky, :DL => :led, :DP => :photodiode,
    :MN_tied => :mos_body_tied, :MP_tied => :mos_body_tied,
    :MN_logic => :mos_logic, :MP_logic => :mos_logic, :Vac => :sine_source)
labels = Dict(:R => "Resistor (US)", :R_IEC => "Resistor (IEC)",
    :R_var => "Variable resistor", :G => "Conductance",
    :C => "Capacitor", :C_pol => "Polarized capacitor", :C_var => "Variable capacitor",
    :L => "Inductor", :D => "Diode", :DZ => "Zener", :DS => "Schottky",
    :DL => "LED", :DP => "Photodiode", :V => "Voltage source", :I => "Current source",
    :E => "VCVS", :F => "CCCS", :H => "CCVS", :GM => "VCCS",
    :S => "Voltage-controlled switch", :Q => "NPN",
    :MN => "NMOS", :MP => "PMOS", :U => "Op-amp", :Vac => "Sine voltage source",
    :MN_tied => "NMOS (body tied)", :MP_tied => "PMOS (body tied)",
    :MN_logic => "NMOS (logic)", :MP_logic => "PMOS (logic)")

design = SymbolLibrary()
placements = Dict(row.path => Placement(3.8column, -3.1row_index)
    for (index, row) in enumerate(devices(design))
    for (row_index, column) in (divrem(index - 1, 4),))
drawing = schematic(design; placements, symbols, labels)
save_schematic(isempty(ARGS) ? "symbol-library.svg" : only(ARGS), drawing)
