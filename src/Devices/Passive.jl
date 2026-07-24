resistor(a,b;value=1.,kw...)=_component(:resistor,a,b;value=value isa IdealResistor ? value.value : value,kw...)
capacitor(a,b;value=1.,kw...)=_component(:capacitor,a,b;value=value isa IdealCapacitor ? value.value : value,kw...)
inductor(a,b;value=1.,kw...)=_component(:inductor,a,b;value,kw...)
conductance(a,b;value=1.,kw...)=_component(:conductance,a,b;value,kw...)
