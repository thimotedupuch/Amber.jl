using Amber

function RLGCLine(;length=1m,sections=100,resistance_per_length=50mΩ/m,inductance_per_length=250nH/m,conductance_per_length=1μS/m,capacitance_per_length=100pF/m,source_resistance=50Ω,load_resistance=50Ω)
    c=CircuitBuilder(:RLGCLine); gnd=ground!(c,:gnd); x=node_array!(c,:x,0:sections); dx=length/sections
    add!(c,voltage_source(x[0],gnd;waveform=Step(low=0V,high=1V,at=1ns,rise=100ps),series_resistance=source_resistance);name=:Vin)
    for k in 1:sections
        middle=node!(c,(:middle,k))
        add!(c,resistor(x[k-1],middle;value=resistance_per_length*dx);name=(:R,k))
        add!(c,inductor(middle,x[k];value=inductance_per_length*dx);name=(:L,k))
        add!(c,conductance(x[k],gnd;value=conductance_per_length*dx);name=(:G,k))
        add!(c,capacitor(x[k],gnd;value=capacitance_per_length*dx);name=(:C,k))
    end
    add!(c,resistor(x[sections],gnd;value=load_resistance);name=:Rload)
    observe!(c,voltage(x[0]);name=:input); observe!(c,voltage(x[sections]);name=:output); finish(c)
end
