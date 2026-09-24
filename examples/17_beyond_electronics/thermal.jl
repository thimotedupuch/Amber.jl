using Amber

"""A temperature-dependent heater coupled to two thermal RC masses (1 V = 1 K)."""
@circuit ElectroThermalHeater(;
    supply = 12V, resistance_ambient = 12.0,
    temperature_coefficient = 0.0039, ambient = 293.15
) begin
    gnd = ground(); electrical = node(); heater_temperature = node(); case_temperature = node()
    voltage_source(electrical, gnd; dc = supply)
    # Temperature nodes store rise above ambient. A and F map to W and J/K.
    capacitor(heater_temperature, gnd; value = 8.0)
    capacitor(case_temperature, gnd; value = 40.0)
    resistor(heater_temperature, case_temperature; value = 2.0)
    resistor(case_temperature, gnd; value = 5.0)
    resistance(theta) = resistance_ambient * (1 + temperature_coefficient * theta)
    behavioral_current_source(
        ((electrical, gnd), (heater_temperature, gnd)), electrical, gnd;
        current = (x, t) -> x[1] / resistance(x[2]),
        gradient = (x, t) -> (
            inv(resistance(x[2])),
            -x[1] * resistance_ambient * temperature_coefficient / resistance(x[2])^2, 0.0, 0.0,
        )
    )
    behavioral_current_source(
        ((electrical, gnd), (heater_temperature, gnd)), heater_temperature, gnd;
        current = (x, t) -> -x[1]^2 / resistance(x[2]),
        gradient = (x, t) -> (
            -2x[1] / resistance(x[2]),
            x[1]^2 * resistance_ambient * temperature_coefficient / resistance(x[2])^2, 0.0, 0.0,
        )
    )
    observe(heater_temperature); observe(case_temperature)
end

thermal_result = transient(ElectroThermalHeater(), 0s => 300s; max_step = 0.25s)
heater_kelvin = 293.15 .+ voltage(thermal_result, :heater_temperature)
