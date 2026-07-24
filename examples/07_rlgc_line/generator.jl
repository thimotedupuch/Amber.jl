using Amber

function RLGCLine(;length=1m,sections=100,resistance_per_length=50mΩ/m,inductance_per_length=250nH/m,conductance_per_length=1μS/m,capacitance_per_length=100pF/m,source_resistance=50Ω,load_resistance=50Ω)
    c=Circuit(:RLGCLine); gnd=ground!(c,:gnd); x=[node!(c,Symbol(:x,k)) for k in 0:sections]; dx=length/sections
    add!(c,voltage_source(x[1],gnd;waveform=Step(low=0V,high=1V,at=1ns,rise=100ps),series_resistance=source_resistance);name=:Vin)
    for k in 1:sections
        middle=node!(c,Symbol(:middle,k))
        add!(c,resistor(x[k],middle;value=resistance_per_length*dx);name=Symbol(:R,k))
        add!(c,inductor(middle,x[k+1];value=inductance_per_length*dx);name=Symbol(:L,k))
        add!(c,conductance(x[k+1],gnd;value=conductance_per_length*dx);name=Symbol(:G,k))
        add!(c,capacitor(x[k+1],gnd;value=capacitance_per_length*dx);name=Symbol(:C,k))
    end
    add!(c,resistor(x[end],gnd;value=load_resistance);name=:Rload)
    observe!(c,voltage(x[1]);name=:input); observe!(c,voltage(x[end]);name=:output); c
end
