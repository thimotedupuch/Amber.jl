using Amber

@circuit ContradictorySources() begin
    gnd = ground(); n1 = node(); V1 = voltage_source(n1, gnd; dc = 5V); V2 = voltage_source(n1, gnd; dc = 3V)
end

@circuit FloatingInput() begin
    a = node(); b = node(); C1 = capacitor(a, b; value = 10nF)
end
