using Amber

"""Lumped Thiele--Small driver feeding a lossy acoustic transmission-line ladder."""
function LoudspeakerWaveguide(;sections=12)
    c=CircuitBuilder(:LoudspeakerWaveguide); gnd=ground!(c,:gnd)
    drive=node!(c,:drive); cone=node!(c,:cone)
    ducts=[node!(c,Symbol(:duct_,i)) for i in 1:sections]
    add!(c,voltage_source(drive,gnd;waveform=Sine(amplitude=1V,frequency=100Hz));name=:source)
    # Mobility analogy: cone voltage is velocity, current is force.
    add!(c,resistor(drive,cone;value=6.2);name=:voice_coil_loss)
    add!(c,inductor(cone,gnd;value=0.018);name=:moving_mass)
    add!(c,capacitor(cone,gnd;value=1/850);name=:suspension_compliance)
    previous=cone
    for i in 1:sections
        add!(c,inductor(previous,ducts[i];value=2.5e-4);name=Symbol(:air_mass_,i))
        add!(c,capacitor(ducts[i],gnd;value=1.2e-5);name=Symbol(:air_compliance_,i))
        add!(c,resistor(ducts[i],gnd;value=80.0);name=Symbol(:wall_loss_,i))
        previous=ducts[i]
    end
    add!(c,resistor(previous,gnd;value=35.0);name=:radiation_load)
    observe!(c,voltage(cone);name=:cone_velocity)
    observe!(c,voltage(previous);name=:mouth_pressure)
    finish(c)
end

speaker_result=transient(LoudspeakerWaveguide(),0s=>50ms;max_step=10μs)

