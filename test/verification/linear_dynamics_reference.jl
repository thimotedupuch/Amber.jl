@testset "verification: RC, RL, and RLC references" begin
    @circuit RCReference(; R = 1kΩ, C = 100nF) begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; ac = 1V, waveform = Step(low = 0V, high = 1V, at = 0s))
        R1 = resistor(input, output; value = R); C1 = capacitor(output, gnd; value = C)
    end
    τ = 1kΩ * 100nF
    rc = transient(RCReference(), 0s => 5τ; initial = :discharged, saveat = τ / 40, method = :bdf2)
    exact_rc(t) = 1 - exp(-t / τ)
    @test maximum(abs.(voltage(rc, :output) .- exact_rc.(rc.axis))) < 2.0e-3
    ac = small_signal(RCReference(), 10Hz => 100kHz; points = 41, source = :V1)
    expected_ac = 1 ./ (1 .+ im * 2π .* ac.axis .* τ)
    @test relative_error(voltage(ac, :output), expected_ac) < 1.0e-11

    @circuit RLReference(; R = 20Ω, L = 2mH) begin
        gnd = ground(); input = node(); middle = node()
        V1 = voltage_source(input, gnd; waveform = Step(low = 0V, high = 2V, at = 0s))
        R1 = resistor(input, middle; value = R); L1 = inductor(middle, gnd; value = L)
    end
    τrl = 2mH / 20Ω
    rl = transient(RLReference(), 0s => 5τrl; initial = :discharged, saveat = τrl / 40, method = :bdf2)
    expected_current = 2V / 20Ω .* (1 .- exp.(-rl.axis ./ τrl))
    @test maximum(abs.(current(rl, :L1) .- expected_current)) < 200μA

    @circuit RLCReference(; R = 10Ω, L = 1mH, C = 10μF) begin
        gnd = ground(); input = node(); middle = node(); output = node()
        V1 = voltage_source(input, gnd; waveform = Step(low = 0V, high = 1V, at = 0s))
        R1 = resistor(input, middle; value = R); L1 = inductor(middle, output; value = L)
        C1 = capacitor(output, gnd; value = C)
    end
    α = 10Ω / (2 * 1mH); ω0 = inv(sqrt(1mH * 10μF)); ωd = sqrt(ω0^2 - α^2)
    rlc = transient(RLCReference(), 0s => 2ms; initial = :discharged, saveat = 2μs, method = :bdf2)
    exact_rlc(t) = 1 - exp(-α * t) * (cos(ωd * t) + α / ωd * sin(ωd * t))
    @test maximum(abs.(voltage(rlc, :output) .- exact_rlc.(rlc.axis))) < 6.0e-3
end
