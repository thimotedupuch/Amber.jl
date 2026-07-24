# Galerie de circuits de référence pour Amber.jl

Les exemples officiels d’Amber.jl ne devraient pas seulement enseigner l’électronique. Chacun devrait exercer une propriété importante du moteur :

| Circuit                  | Capacité démontrée                                  |
| ------------------------ | --------------------------------------------------- |
| Filtre RC réaliste       | Composants non idéaux, AC et transitoire            |
| Redresseur à diode       | Non-linéarité, charge de jonction, convergence      |
| Amplificateur à BJT      | Point de fonctionnement, petits signaux, bruit      |
| Paire différentielle     | Appairage, mismatch, Monte-Carlo                    |
| Oscillateur de Wien      | Dynamique autonome, saturation, amorçage            |
| Échantillonneur-bloqueur | Commutation, événements, injection de charge        |
| Ligne RLGC générée       | Génération programmatique, grandes matrices creuses |
| Circuit incorrect        | Diagnostics topologiques explicites                 |

---

# 1. Filtre RC réaliste

Le filtre RC est élémentaire, mais devient rapidement révélateur lorsque la résistance et le condensateur possèdent des modèles physiques.

```julia
using Amber

@circuit PracticalLowPass(;
    R = 10kΩ,
    C = 10nF,
) begin
    gnd  = ground()
    vin  = node()
    vout = node()

    Vin = voltage_source(
        vin,
        gnd;
        dc = 0V,
        ac = 1V,
        waveform = Step(
            low = 0V,
            high = 1V,
            at = 100μs,
            rise = 10ns,
        ),
    )

    R1 = resistor(
        vin,
        vout;
        value = R,
        material = ThinFilm(
            tc1 = 15e-6 / K,
            voltage_coefficient = 0.05e-6 / V,
            excess_noise = true,
        ),
        package = SMD0603(
            series_inductance = 0.6nH,
            parallel_capacitance = 40fF,
        ),
    )

    C1 = capacitor(
        vout,
        gnd;
        value = C,
        dielectric = C0G(
            loss_tangent = 1e-4,
        ),
        package = SMD0603(
            esr = 30mΩ,
            esl = 500pH,
        ),
    )

    observe(
        voltage(vout),
        current(R1),
        power(R1),
        current(C1),
    )
end
```

Le même modèle sert aux différentes analyses :

```julia
filter = PracticalLowPass()

op = operating_point(filter)

ac = small_signal(
    filter,
    10Hz => 1GHz;
    points = 500,
    scale = :log,
)

tran = transient(
    filter,
    0s => 2ms;
    reltol = 1e-7,
    saveat = 1μs,
)
```

On peut comparer immédiatement le circuit réel au circuit idéal :

```julia
ideal = PracticalLowPass(
    R = IdealResistor(10kΩ),
    C = IdealCapacitor(10nF),
)

comparison = compare(
    small_signal(ideal, 10Hz => 1GHz),
    ac;
    observable = voltage(:vout),
)
```

Cet exemple démontre que la non-idéalité n’est pas obtenue en ajoutant manuellement une collection de composants parasites. Elle appartient au modèle du composant.

---

# 2. Redresseur à diode avec condensateur de filtrage

Ce circuit teste simultanément :

* le point de fonctionnement ;
* les exponentielles fortement non linéaires ;
* la charge de jonction ;
* la conduction discontinue ;
* le démarrage transitoire ;
* la variation importante des constantes de temps.

```julia
@circuit HalfWaveRectifier(;
    frequency = 50Hz,
    amplitude = 10V,
    load = 1kΩ,
    smoothing = 470μF,
) begin
    gnd  = ground()
    vin  = node()
    vout = node()

    Vac = voltage_source(
        vin,
        gnd;
        waveform = Sine(
            amplitude = amplitude,
            frequency = frequency,
        ),
    )

    D1 = diode(
        vin,
        vout;
        model = JunctionDiode(
            saturation_current = 2nA,
            ideality = 1.7,
            series_resistance = 120mΩ,
            junction_capacitance = 15pF,
            junction_potential = 700mV,
            grading_coefficient = 0.45,
            transit_time = 2μs,
        ),
    )

    C1 = capacitor(
        vout,
        gnd;
        value = smoothing,
        esr = 180mΩ,
        leakage_resistance = 500kΩ,
        dielectric_absorption = DebyeBranches(
            time_constants = [20ms, 200ms, 2s],
            fractions = [0.015, 0.006, 0.002],
        ),
    )

    Rload = resistor(vout, gnd; value = load)

    observe(
        voltage(vin),
        voltage(vout),
        current(D1),
        charge(D1),
        power(D1),
    )
end
```

Simulation du démarrage :

```julia
rectifier = HalfWaveRectifier()

result = transient(
    rectifier,
    0s => 500ms;
    initial = :discharged,
    reltol = 1e-6,
    max_step = 100μs,
)
```

Balayage de la capacité sans recompilation topologique :

```julia
compiled = compile(rectifier)

ripple = sweep(
    compiled,
    Symbol("C1.value") => [47μF, 100μF, 220μF, 470μF, 1mF];
    analysis = Transient(0s => 500ms),
    metric = peak_to_peak(voltage(:vout), window = 400ms => 500ms),
)
```

Rapport de validité des modèles :

```julia
validity_report(result)
```

Sortie possible :

```text
D1:
  Maximum forward current: 2.83 A
  Maximum reverse voltage: 9.72 V
  Model validity: satisfied

C1:
  Maximum ripple current: 612 mA RMS
  Rated ripple current: unspecified
  Warning: thermal validity cannot be evaluated
```

---

# 3. Amplificateur à émetteur commun

Cet exemple montre qu’un circuit unique peut servir au calcul :

* du point de polarisation ;
* du gain ;
* des impédances d’entrée et de sortie ;
* du bruit ;
* de la distorsion transitoire ;
* des sensibilités paramétriques.

```julia
@circuit CommonEmitterAmplifier(;
    VCC = 12V,
    RC = 4.7kΩ,
    RE = 1kΩ,
) begin
    gnd  = ground()
    vcc  = node()
    src  = node()
    drive = node()
    base = node()
    emit = node()
    coll = node()
    out  = node()

    Supply = voltage_source(vcc, gnd; dc = VCC)

    Input = voltage_source(
        src,
        gnd;
        dc = 0V,
        ac = 1V,
        waveform = Sine(
            amplitude = 10mV,
            frequency = 1kHz,
        ),
    )

    Rsource = resistor(src, drive; value = 600Ω)
    Cin = capacitor(drive, base; value = 10μF)

    Rbias1 = resistor(vcc, base; value = 82kΩ)
    Rbias2 = resistor(base, gnd; value = 18kΩ)

    Rcollector = resistor(vcc, coll; value = RC)
    Remitter   = resistor(emit, gnd; value = RE)
    Cemit      = capacitor(emit, gnd; value = 100μF)

    Q1 = npn(
        coll,
        base,
        emit;
        model = GummelPoonBJT(
            saturation_current = 8fA,
            forward_beta = 180,
            early_voltage = 80V,
            base_resistance = 25Ω,
            cbe_zero_bias = 20pF,
            cbc_zero_bias = 4pF,
            transit_time = 300ps,
            flicker_noise = true,
        ),
    )

    Cout = capacitor(coll, out; value = 10μF)
    Rload = resistor(out, gnd; value = 10kΩ)

    observe(
        voltage(base),
        voltage(emit),
        voltage(coll),
        voltage(out),
        current(Q1, :collector),
        current(Q1, :base),
        power(Q1),
    )
end
```

Point de fonctionnement :

```julia
amplifier = CommonEmitterAmplifier()

op = operating_point(amplifier)

report(op)
```

Sortie possible :

```text
Operating point

Q1:
  VBE = 0.654 V
  VCE = 5.82 V
  IC  = 1.16 mA
  IB  = 6.9 µA
  gm  = 44.8 mS
  β   = 168
  Region: forward active
```

Analyse petits signaux :

```julia
ac = small_signal(
    amplifier,
    10Hz => 100MHz;
    source = :Input,
    points = 600,
)

gain = transfer(
    ac;
    input = voltage(:src),
    output = voltage(:out),
)
```

Analyse de bruit :

```julia
noise_result = noise(
    amplifier,
    10Hz => 1MHz;
    output = voltage(:out),
    referred_to = :Input,
)
```

Sensibilité du gain :

```julia
sensitivities = sensitivity(
    amplifier;
    metric = magnitude(
        transfer(:Input => voltage(:out)),
        at = 1kHz,
    ),
    parameters = [
        Symbol("Rcollector.value"),
        Symbol("Remitter.value"),
        Symbol("Q1.forward_beta"),
        Symbol("Q1.early_voltage"),
    ],
)
```

La linéarisation AC est dérivée du même résidu que le transitoire. Aucun modèle AC parallèle du transistor n’est nécessaire.

---

# 4. Paire différentielle et mismatch

La paire différentielle est particulièrement adaptée pour montrer que les variations globales de fabrication et le mismatch local sont deux phénomènes différents.

```julia
@circuit DifferentialPair(;
    tail_current = 1mA,
    collector_resistance = 5.6kΩ,
) begin
    gnd  = ground()
    vdd  = node()
    vss  = node()
    inp  = node()
    inn  = node()
    tail = node()
    outp = node()
    outn = node()

    VDD = voltage_source(vdd, gnd; dc = 5V)
    VSS = voltage_source(gnd, vss; dc = 5V)

    Vplus = voltage_source(
        inp,
        gnd;
        dc = 1.2V,
        ac = 0.5V,
    )

    Vminus = voltage_source(
        inn,
        gnd;
        dc = 1.2V,
        ac = -0.5V,
    )

    Itail = current_source(tail, vss; dc = tail_current)

    RC1 = resistor(vdd, outp; value = collector_resistance)
    RC2 = resistor(vdd, outn; value = collector_resistance)

    pair = matched_group(
        :input_pair;
        sigma_vbe = 300μV,
        sigma_log_beta = 0.03,
        correlation = 0.2,
    )

    Q1 = npn(
        outp,
        inp,
        tail;
        model = GummelPoonBJT(),
        match = pair,
    )

    Q2 = npn(
        outn,
        inn,
        tail;
        model = GummelPoonBJT(),
        match = pair,
    )

    observe(
        voltage(outp),
        voltage(outn),
        voltage(outp, outn),
        current(Q1, :collector),
        current(Q2, :collector),
    )
end
```

Analyse différentielle :

```julia
pair = DifferentialPair()

ac = small_signal(
    pair,
    1Hz => 100MHz;
    excitation = Differential(:Vplus, :Vminus),
)
```

Monte-Carlo reproductible :

```julia
mc = monte_carlo(
    pair;
    samples = 2_000,
    seed = 0xA8B3_2026,
    analysis = OperatingPoint(),
    metrics = [
        differential_output_offset(:outp, :outn),
        input_referred_offset(:inp, :inn),
        common_mode_output(:outp, :outn),
    ],
)
```

Variations globales et locales peuvent être déclarées séparément :

```julia
process = ProcessVariation(
    temperature = Gaussian(25°C, 3°C),
    resistor_scale = Gaussian(1.0, 0.01),
    transistor_is_scale = LogNormal(0.0, 0.04),
)

mc = monte_carlo(
    pair;
    process = process,
    samples = 2_000,
    seed = 42,
)
```

La notion de `matched_group` est importante. Deux transistors proches partagent certaines variations de procédé, tout en possédant un mismatch local indépendant ou partiellement corrélé.

---

# 5. Oscillateur de Wien

L’oscillateur est un test plus sévère qu’une réponse forcée. Le système doit trouver sa trajectoire sans excitation périodique externe.

Il met en jeu :

* l’absence de point de fonctionnement stable utile ;
* l’amorçage par une perturbation ;
* la croissance exponentielle initiale ;
* la saturation ;
* la stabilisation non linéaire de l’amplitude ;
* le slew rate de l’amplificateur.

```julia
@circuit WienOscillator(;
    frequency = 10kHz,
) begin
    gnd    = ground()
    vdd    = node()
    vss    = node()
    output = node()
    noninv = node()
    inv    = node()
    series = node()
    gain_n = node()

    VDD = voltage_source(vdd, gnd; dc = 12V)
    VSS = voltage_source(gnd, vss; dc = 12V)

    Rw = 10kΩ
    Cw = 1 / (2π * Rw * frequency)

    Cseries = capacitor(output, series; value = Cw)
    Rseries = resistor(series, noninv; value = Rw)

    Rparallel = resistor(noninv, gnd; value = Rw)
    Cparallel = capacitor(noninv, gnd; value = Cw)

    Rg = resistor(inv, gnd; value = 10kΩ)

    Rf1 = resistor(output, gain_n; value = 12kΩ)
    Rf2 = resistor(gain_n, inv; value = 10kΩ)

    D1 = diode(output, gain_n; model = JunctionDiode())
    D2 = diode(gain_n, output; model = JunctionDiode())

    A1 = opamp(
        noninv,
        inv,
        output,
        vdd,
        vss;
        model = BehavioralOpAmp(
            dc_gain = 120dB,
            gain_bandwidth = 10MHz,
            slew_rate = 5V / μs,
            output_resistance = 20Ω,
            output_current_limit = 25mA,
            input_offset = 100μV,
            input_voltage_noise = 8nV / sqrt(Hz),
            saturation_recovery = 2μs,
        ),
    )

    initial_voltage(Cparallel, 1μV)

    observe(
        voltage(output),
        voltage(noninv),
        voltage(inv),
        current(D1),
        state(A1, :dominant_pole),
    )
end
```

Simulation :

```julia
oscillator = WienOscillator()

result = transient(
    oscillator,
    0s => 20ms;
    initialization = :consistent,
    reltol = 1e-7,
    max_step = 500ns,
)
```

Analyse du régime établi :

```julia
metrics = periodic_metrics(
    result;
    signal = voltage(:output),
    window = 15ms => 20ms,
)

metrics.frequency
metrics.amplitude
metrics.thd
```

Ce circuit constitue un excellent test de non-régression. Une variation apparemment bénigne du solveur peut changer :

* le temps d’amorçage ;
* l’amplitude finale ;
* la fréquence ;
* la distorsion ;
* le nombre d’itérations de Newton.

---

# 6. Échantillonneur-bloqueur non idéal

Ce circuit démontre les événements et les modèles hybrides sans introduire un simulateur logique complet.

```julia
@circuit SampleAndHold(;
    sampling_frequency = 100kHz,
    hold_capacitance = 1nF,
) begin
    gnd  = ground()
    vdd  = node()
    vss  = node()
    vin  = node()
    clk  = node()
    hold = node()
    out  = node()

    VDD = voltage_source(vdd, gnd; dc = 5V)
    VSS = voltage_source(gnd, vss; dc = 5V)

    Input = voltage_source(
        vin,
        gnd;
        waveform = Sine(
            amplitude = 1V,
            frequency = 7.3kHz,
        ),
    )

    Clock = voltage_source(
        clk,
        gnd;
        waveform = Pulse(
            low = 0V,
            high = 5V,
            frequency = sampling_frequency,
            duty_cycle = 0.15,
            rise = 2ns,
            fall = 2ns,
        ),
    )

    S1 = analog_switch(
        vin,
        hold,
        clk,
        gnd;
        model = VoltageControlledSwitch(
            threshold = 2.5V,
            ron = 15Ω,
            roff = 10TΩ,
            charge_injection = 300fC,
            clock_feedthrough = 20fF,
        ),
    )

    Chold = capacitor(
        hold,
        gnd;
        value = hold_capacitance,
        leakage_resistance = 1GΩ,
        dielectric_absorption = DebyeBranches(
            time_constants = [100μs, 2ms],
            fractions = [0.003, 0.001],
        ),
    )

    Buffer = opamp(
        hold,
        out,
        out,
        vdd,
        vss;
        model = BehavioralOpAmp(
            dc_gain = 100dB,
            gain_bandwidth = 20MHz,
            input_bias_current = 5pA,
            input_capacitance = 2pF,
            slew_rate = 10V / μs,
        ),
    )

    observe(
        voltage(vin),
        voltage(clk),
        voltage(hold),
        voltage(out),
        current(S1),
    )
end
```

Simulation avec localisation exacte des commutations :

```julia
sampler = SampleAndHold()

result = transient(
    sampler,
    0s => 1ms;
    event_mode = :exact,
    max_step = 50ns,
)
```

Mesures automatiques :

```julia
errors = sampling_metrics(
    result;
    input = voltage(:vin),
    held = voltage(:hold),
    clock = voltage(:clk),
)

errors.acquisition_time
errors.hold_droop
errors.aperture_error
errors.charge_injection_step
```

Amber doit permettre deux stratégies pour les commutateurs :

```julia
model = SmoothSwitch(...)
```

pour les optimisations et les problèmes différentiables, ou :

```julia
model = EventSwitch(...)
```

pour une commutation plus exacte et plus rapide.

---

# 7. Ligne de transmission RLGC générée programmatiquement

C’est probablement l’un des exemples les plus convaincants pour justifier une description programmatique.

Une ligne distribuée est approchée par (N) cellules RLGC. Le code est pratiquement identique pour 5, 50 ou 5 000 sections.

```julia
function RLGCLine(;
    length = 1m,
    sections = 100,
    resistance_per_length = 50mΩ / m,
    inductance_per_length = 250nH / m,
    conductance_per_length = 1μS / m,
    capacitance_per_length = 100pF / m,
    source_resistance = 50Ω,
    load_resistance = 50Ω,
)
    c = Circuit(:RLGCLine)

    gnd = ground!(c, :gnd)

    x = [
        node!(c, Symbol(:x, k))
        for k in 0:sections
    ]

    dx = length / sections

    add!(
        c,
        voltage_source(
            x[1],
            gnd;
            waveform = Step(
                low = 0V,
                high = 1V,
                at = 1ns,
                rise = 100ps,
            ),
            series_resistance = source_resistance,
        );
        name = :Vin,
    )

    for k in 1:sections
        middle = node!(c, Symbol(:middle, k))

        add!(
            c,
            resistor(
                x[k],
                middle;
                value = resistance_per_length * dx,
            );
            name = Symbol(:R, k),
        )

        add!(
            c,
            inductor(
                middle,
                x[k + 1];
                value = inductance_per_length * dx,
            );
            name = Symbol(:L, k),
        )

        add!(
            c,
            conductance(
                x[k + 1],
                gnd;
                value = conductance_per_length * dx,
            );
            name = Symbol(:G, k),
        )

        add!(
            c,
            capacitor(
                x[k + 1],
                gnd;
                value = capacitance_per_length * dx,
            );
            name = Symbol(:C, k),
        )
    end

    add!(
        c,
        resistor(
            x[end],
            gnd;
            value = load_resistance,
        );
        name = :Rload,
    )

    observe!(c, voltage(x[1]); name = :input)
    observe!(c, voltage(x[end]); name = :output)

    return c
end
```

Utilisation :

```julia
line = RLGCLine(
    length = 2m,
    sections = 200,
)

compiled = compile(line)

result = transient(
    compiled,
    0s => 50ns;
    reltol = 1e-6,
    max_step = 20ps,
)
```

Étude de convergence spatiale :

```julia
convergence = map([10, 20, 50, 100, 200, 500]) do sections
    line = RLGCLine(
        length = 2m,
        sections = sections,
    )

    result = transient(
        line,
        0s => 50ns;
        max_step = 20ps,
    )

    (
        sections = sections,
        delay = propagation_delay(
            result;
            input = :input,
            output = :output,
        ),
        overshoot = overshoot(result, :output),
    )
end
```

Cet exemple exerce directement :

* la génération de topologies avec des boucles Julia ordinaires ;
* les noms de composants générés ;
* l’assemblage de grandes matrices creuses ;
* le batching des résistances, inductances et capacités ;
* la réutilisation des factorisations symboliques ;
* la conservation de la hiérarchie et des observables.

Une netlist peut évidemment représenter le même circuit, mais elle ne constitue pas un moyen naturel de le construire, de le transformer ou d’effectuer une étude de convergence.

---

# 8. Génération d’un réseau arbitraire

La génération programmatique ne doit pas être limitée à des structures linéaires.

Cet exemple construit un réseau de résistances à partir d’une liste d’arêtes.

```julia
function resistor_network(
    graph;
    resistance = 1kΩ,
)
    c = Circuit(:ResistorNetwork)

    gnd = ground!(c, :gnd)

    nodes = Dict(
        vertex => node!(c, Symbol(:n, vertex))
        for vertex in vertices(graph)
    )

    for (index, edge) in enumerate(edges(graph))
        a = nodes[source(edge)]
        b = nodes[target(edge)]

        add!(
            c,
            resistor(a, b; value = resistance);
            name = Symbol(:R, index),
        )
    end

    add!(
        c,
        voltage_source(
            nodes[first(vertices(graph))],
            gnd;
            dc = 1V,
        );
        name = :Excitation,
    )

    add!(
        c,
        resistor(
            nodes[last(vertices(graph))],
            gnd;
            value = 1kΩ,
        );
        name = :Load,
    )

    return c
end
```

Le graphe peut provenir :

* d’un algorithme de génération ;
* d’une structure cristalline ;
* d’un maillage ;
* d’un modèle de réseau de capteurs ;
* d’une matrice de connexions ;
* d’un problème d’optimisation topologique.

Le circuit demeure un objet Amber inspectable :

```julia
network = resistor_network(my_graph)

describe(network)
check(network)

render(
    network;
    format = :svg,
    layout = :topological,
)
```

---

# 9. Diagnostic d’un circuit incorrect

Une bonne bibliothèque ne doit pas seulement simuler les circuits corrects. Elle doit expliquer les circuits incorrects.

```julia
@circuit ContradictorySources() begin
    gnd = ground()
    n1  = node()

    V1 = voltage_source(n1, gnd; dc = 5V)
    V2 = voltage_source(n1, gnd; dc = 3V)
end
```

Vérification :

```julia
check(ContradictorySources())
```

Sortie attendue :

```text
Circuit is structurally inconsistent.

Conflicting ideal voltage constraints were found:

  V1 imposes voltage(n1, gnd) = 5 V
  V2 imposes voltage(n1, gnd) = 3 V

The constraints concern the same pair of electrical nodes and
cannot be simultaneously satisfied.

Possible resolutions:
  - remove one source;
  - introduce a finite source resistance;
  - replace one source with a controlled source;
  - verify that V1 and V2 were not connected accidentally.
```

Autre exemple : nœud flottant.

```julia
@circuit FloatingInput() begin
    a = node()
    b = node()

    C1 = capacitor(a, b; value = 10nF)
end
```

```julia
check(FloatingInput())
```

```text
Circuit has no electrical reference.

The connected component containing nodes `a` and `b`
has no ground or finite DC path to a referenced potential.

At DC, capacitor C1 is an open circuit.
The absolute potentials of `a` and `b` are undetermined.
```

Ce diagnostic nécessite une connaissance du domaine électronique. Un solveur DAE généraliste ne peut généralement produire qu’un message de singularité matricielle.

---

# 10. Composition hiérarchique

Les circuits précédents doivent pouvoir être utilisés comme des composants.

```julia
@circuit MeasurementChain() begin
    gnd   = ground()
    input = node()
    filt  = node()
    amp   = node()
    out   = node()

    Sensor = voltage_source(
        input,
        gnd;
        waveform = Sine(
            amplitude = 2mV,
            frequency = 200Hz,
        ),
        series_resistance = 10kΩ,
    )

    Filter = PracticalLowPass(
        input,
        filt;
        R = 4.7kΩ,
        C = 100nF,
    )

    Amplifier = CommonEmitterAmplifier(
        input = filt,
        output = amp,
    )

    Sampler = SampleAndHold(
        input = amp,
        output = out,
        sampling_frequency = 10kHz,
    )

    observe(
        voltage(input),
        voltage(filt),
        voltage(amp),
        voltage(out),
    )
end
```

Les chemins hiérarchiques restent disponibles :

```julia
result = transient(
    MeasurementChain(),
    0s => 100ms,
)

voltage(result, "Filter.vout")
current(result, "Amplifier.Q1.collector")
voltage(result, "Sampler.hold")
```

Les sous-circuits ne devraient pas être aplatis trop tôt. L’aplatissement numérique peut intervenir lors de la compilation, mais les métadonnées hiérarchiques doivent être conservées.

---

# 11. Séparation entre circuit et expérience

Une propriété importante d’Amber devrait être la séparation entre :

* la définition du circuit ;
* le scénario d’excitation ;
* l’analyse ;
* les mesures demandées.

Un même circuit peut être soumis à plusieurs expériences :

```julia
amplifier = CommonEmitterAmplifier()
compiled = compile(amplifier)

experiments = [
    OperatingPoint(),

    SmallSignal(
        frequencies = 10Hz => 100MHz,
        source = :Input,
    ),

    Transient(
        interval = 0s => 10ms,
        overrides = Dict(
            Symbol("Input.waveform") => Sine(
                amplitude = 10mV,
                frequency = 1kHz,
            ),
        ),
    ),

    Transient(
        interval = 0s => 100μs,
        overrides = Dict(
            Symbol("Input.waveform") => Step(
                low = 0V,
                high = 200mV,
                at = 10μs,
            ),
        ),
    ),
]

results = run(compiled, experiments)
```

La topologie est compilée une fois. Les sources et paramètres changent sans reconstruire le système.

---

# 12. Tests unitaires sur les circuits

Puisque les circuits sont des objets Julia, ils doivent pouvoir faire l’objet de tests ordinaires.

```julia
using Test
using Amber

@testset "Common-emitter amplifier" begin
    circuit = CommonEmitterAmplifier()
    op = operating_point(circuit)

    @test 0.55V < voltage(op, :base, :emit) < 0.75V
    @test region(op, :Q1) == ForwardActive
    @test current(op, :Q1, :collector) > 0A

    ac = small_signal(
        circuit,
        1kHz => 1kHz;
        source = :Input,
    )

    gain = transfer(
        ac;
        input = voltage(:src),
        output = voltage(:out),
    )

    @test magnitude(gain[1]) > 10
    @test phase(gain[1]) ≈ -180° atol = 15°
end
```

Un modèle de composant peut lui aussi être testé isolément :

```julia
@testset "Junction diode charge conservation" begin
    model = JunctionDiode()

    for voltage in range(-2V, 800mV, length = 1_000)
        q = charge(model, voltage)
        c = differential_capacitance(model, voltage)

        @test derivative(v -> charge(model, v), voltage) ≈ c
    end
end
```

---

# 13. Organisation recommandée des exemples

```text
examples/
├── 01_practical_rc/
│   ├── circuit.jl
│   ├── ac_analysis.jl
│   └── transient_analysis.jl
├── 02_diode_rectifier/
│   ├── circuit.jl
│   ├── startup.jl
│   └── capacitance_sweep.jl
├── 03_common_emitter/
│   ├── circuit.jl
│   ├── operating_point.jl
│   ├── small_signal.jl
│   └── noise.jl
├── 04_differential_pair/
│   ├── circuit.jl
│   ├── mismatch.jl
│   └── monte_carlo.jl
├── 05_wien_oscillator/
│   ├── circuit.jl
│   ├── startup.jl
│   └── periodic_metrics.jl
├── 06_sample_and_hold/
│   ├── circuit.jl
│   ├── event_simulation.jl
│   └── sampling_errors.jl
├── 07_rlgc_line/
│   ├── generator.jl
│   ├── step_response.jl
│   └── convergence.jl
└── 08_diagnostics/
    ├── floating_nodes.jl
    ├── voltage_source_loops.jl
    └── invalid_models.jl
```

Chaque exemple devrait comprendre :

* une description physique ;
* le code du circuit ;
* les équations principales ;
* les résultats attendus ;
* les propriétés du moteur exercées ;
* au moins un test automatique ;
* un fichier de référence versionné.

---

# 14. Exemple emblématique pour la page d’accueil

L’exemple présenté en premier dans le README doit rester court.

```julia
using Amber

@circuit LowPass(; R = 10kΩ, C = 10nF) begin
    gnd  = ground()
    vin  = node()
    vout = node()

    source(vin, gnd; ac = 1V)
    resistor(vin, vout; value = R)
    capacitor(vout, gnd; value = C)

    observe(vout)
end

result = small_signal(
    LowPass(),
    10Hz => 1MHz,
)

bode(result, :vout)
```

Puis une seconde version peut révéler la profondeur du logiciel :

```julia
@circuit RealLowPass(; R = 10kΩ, C = 10nF) begin
    gnd  = ground()
    vin  = node()
    vout = node()

    source(vin, gnd; ac = 1V)

    resistor(
        vin,
        vout;
        value = R,
        material = ThinFilm(tc1 = 15e-6 / K),
        package = SMD0603(),
    )

    capacitor(
        vout,
        gnd;
        value = C,
        dielectric = C0G(),
        package = SMD0603(),
    )

    observe(vout)
end
```

Le message est alors immédiatement compréhensible :

> Amber.jl permet de commencer avec un circuit académique simple, puis d’augmenter progressivement le réalisme sans changer de langage, de représentation ni de moteur.
