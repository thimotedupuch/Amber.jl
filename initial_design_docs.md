Proposition d’architecture pour un simulateur électronique analogique natif Julia

Nom de travail : Amber.jl.

1. Positionnement

Le projet ne devrait pas être présenté comme « un autre SPICE écrit en Julia », mais comme :

Un environnement de modélisation et de simulation de circuits analogiques, programmatique, hiérarchique, typé et orienté équations, spécialisé pour l’électronique.

Les différences fondamentales avec SPICE seraient les suivantes :

le circuit est un objet Julia, et non une netlist textuelle ;
les composants sont des modèles composables, et non des lignes interprétées par un moteur externe ;
l’ensemble de la chaîne — élaboration, analyse structurelle, assemblage, résolution et post-traitement — est écrit en Julia ;
les modèles peuvent exprimer courants, charges, flux, états internes, bruit, température locale et événements ;
la topologie et les paramètres sont séparés, afin de compiler une fois puis d’exécuter rapidement des balayages, optimisations et Monte-Carlo ;
aucun moteur C opaque n’est requis ;
ModelingToolkit, SciML et les bibliothèques graphiques peuvent être proposés comme extensions, sans appartenir au cœur.

Il faut toutefois conserver une distinction importante :

Rejeter l’interface et l’architecture historique de SPICE ne signifie pas rejeter les formulations mathématiques efficaces utilisées en simulation de circuits.

Les lois de Kirchhoff, les systèmes algébro-différentiels et une forme généralisée de Modified Nodal Analysis restent des outils mathématiques appropriés. Ils doivent être utilisés comme backend interne, pas exposés comme modèle mental principal à l’utilisateur.

2. Principes directeurs
2.1 Le circuit est du Julia

Le circuit doit être un objet inspectable, transformable et paramétrable :

filter = LowPass(
    R = 12kΩ,
    C = 100nF,
    capacitor_model = C0G(),
)

result = transient(filter, 0s => 10ms)

Il doit être possible de :

créer des circuits avec des boucles et des fonctions ;
générer automatiquement des réseaux répétitifs ;
partager des sous-circuits comme des fonctions Julia ;
modifier des paramètres sans reconstruire toute la topologie ;
intégrer une simulation dans un algorithme d’optimisation ;
effectuer des tests unitaires sur un circuit ;
sérialiser sa définition et ses paramètres ;
inspecter sa structure avant simulation.
2.2 La macro est une commodité, pas une fondation

Une macro @circuit peut simplifier la syntaxe et capturer les noms des variables, mais l’API fondamentale doit fonctionner sans macro.

Cela évite :

une sémantique cachée difficile à déboguer ;
une dépendance excessive à la métaprogrammation ;
l’impossibilité de générer des circuits dynamiquement ;
des erreurs difficiles à relier au code utilisateur.
2.3 Spécialisation électronique, pas multiphysique généraliste

Le cœur doit comprendre explicitement :

les potentiels électriques ;
les courants ;
les charges ;
les flux magnétiques ;
les sources ;
les bruits ;
les états internes ;
les connexions électriques ;
les analyses DC, transitoires, AC et de bruit.

Une extension thermique concentrée peut être prévue, mais le cœur ne doit pas devenir un framework universel de modélisation physique.

2.4 Dépendances minimales

Le noyau devrait dépendre principalement des bibliothèques standard Julia :

LinearAlgebra
SparseArrays
SuiteSparse
Random
SHA
éventuellement TOML

Les intégrations suivantes doivent être optionnelles :

Unitful ;
SciML ;
ForwardDiff ;
Makie ou Plots ;
Graphviz ;
Tables ;
Arrow ou JLD2.
3. Modèle mathématique
3.1 Ports électriques acausaux

Chaque terminal électrique possède :

une variable d’effort : le potentiel (v) ;
une variable de flux : le courant (i), orienté vers le composant.

Une connexion entre plusieurs terminaux impose :

[
v_1 = v_2 = \ldots = v_n
]

et :

[
\sum_{k=1}^{n} i_k = 0
]

L’utilisateur manipule donc des ports et des connexions, non des lignes de netlist.

3.2 Équations constitutives des composants

Un composant peut contribuer plusieurs catégories de relations.

Courant conducteur :

[
i = g(v, x, p, t)
]

Charge :

[
q = q(v, x, p, t)
]

Le courant capacitif correspondant est obtenu par :

[
i_q = \frac{dq}{dt}
]

Flux magnétique :

[
\phi = \phi(i, x, p, t)
]

États internes :

[
f(x, \dot{x}, v, i, p, t) = 0
]

Cette représentation est particulièrement importante pour les composants non linéaires. Un condensateur réaliste ne doit pas être représenté uniquement par (i=C,dv/dt), mais éventuellement par une charge (q(v)), ce qui donne :

[
i = \frac{dq(v)}{dt}
]

Cette formulation facilite les modèles conservatifs en charge et les capacités dépendantes de la tension.

3.3 Système global

Après élaboration, le circuit est transformé en un système algébro-différentiel :

[
F(z,\dot{z},p,t)=0
]

où (z) contient :

les tensions nodales ;
certains courants de branche ;
les états internes des composants ;
éventuellement des températures concentrées.

Le compilateur doit essayer de produire un système d’indice 1 pour les circuits usuels.

Les topologies idéales problématiques doivent être diagnostiquées explicitement :

nœud flottant ;
boucle de sources de tension idéales ;
coupure constituée uniquement de sources de courant ;
état dynamique non contraint ;
conflit de références ;
sous-circuit sans masse ;
système surcontraint ;
système structurellement singulier.

Le comportement attendu n’est pas seulement « Newton n’a pas convergé », mais une explication topologique exploitable.

4. Syntaxe utilisateur
4.1 Exemple principal
using Amber

@circuit LowPass(; R = 10kΩ, C = 100nF) begin
    gnd  = ground()
    vin  = node()
    vout = node()

    V1 = voltage_source(
        vin,
        gnd;
        dc = 0V,
        ac = 1V,
        waveform = Sine(amplitude = 1V, frequency = 1kHz),
    )

    R1 = resistor(
        vin,
        vout;
        value = R,
        material = ThinFilm(
            temperature_coefficient = 15e-6 / K,
            voltage_coefficient = 0.05e-6 / V,
            excess_noise = true,
        ),
        package = SMD0603(),
    )

    C1 = capacitor(
        vout,
        gnd;
        value = C,
        dielectric = C0G(),
        package = SMD0603(),
    )

    observe(vout)
end

La macro peut déduire automatiquement les noms :vin, :vout, :R1 et :C1 à partir des variables Julia.

Le même circuit doit pouvoir être construit sans macro :

function LowPass(; R = 10kΩ, C = 100nF)
    circuit(:LowPass) do c
        gnd  = ground!(c, :gnd)
        vin  = node!(c, :vin)
        vout = node!(c, :vout)

        add!(c, voltage_source(vin, gnd; dc = 0V, ac = 1V))
        add!(c, resistor(vin, vout; value = R))
        add!(c, capacitor(vout, gnd; value = C))

        return c
    end
end
4.2 Analyses
circuit = LowPass(R = 12kΩ)

op = operating_point(circuit)

tran = transient(
    circuit,
    0s => 10ms;
    reltol = 1e-6,
    abstol = 1e-9,
    saveat = 1μs,
)

ac = small_signal(
    circuit,
    10Hz => 10MHz;
    points = 300,
    scale = :log,
)

vout = voltage(tran, :vout)
4.3 Paramétrage et balayages
compiled = compile(LowPass())

result = sweep(
    compiled,
    Symbol("R1.value") => range(1kΩ, 100kΩ, length = 100);
    analysis = OperatingPoint(),
)

La modification d’une valeur ne doit pas entraîner une nouvelle analyse structurelle ni une recompilation complète.

4.4 Hiérarchie

Un sous-circuit doit être une fonction ou un composant Julia :

@circuit DifferentialInput(p, n, out; gain = 100.0) begin
    internal = node()

    transconductance(p, n, internal, gnd; gm = gain)
    resistor(internal, out; value = 10kΩ)
end

Les chemins hiérarchiques doivent être préservés :

trace(result, "frontend.input_stage.Q1.collector_current")
5. Deux niveaux de définition des composants

Une seule API ne conviendra pas simultanément aux électroniciens et aux auteurs de modèles avancés.

5.1 API physique simplifiée

Elle doit couvrir la majorité des modèles de composants.

Exemple conceptuel d’une diode :

@device JunctionDiode(p, n;
    Is = 1e-12A,
    ideality = 1.2,
    Cj0 = 2pF,
    Vj = 0.7V,
    m = 0.5,
) begin
    v = voltage(p, n)

    current(p, n,
        Is * expm1(v / (ideality * thermal_voltage()))
    )

    charge(p, n,
        junction_charge(v; Cj0, Vj, m)
    )

    noise(p, n,
        ShotNoise(2 * elementary_charge * abs(current(p, n)))
    )
end

Les primitives de cette API pourraient être :

current(p, n, expression)
charge(p, n, expression)
branch_current(p, n)
flux(branch, expression)
state(name; initial=...)
residual(expression)
noise(...)
event(...)
observe(...)

Elles sont plus contraintes qu’un langage symbolique généraliste, mais beaucoup plus simples à compiler et à valider.

5.2 API kernel avancée

Les modèles très spécialisés peuvent implémenter directement un contrat bas niveau :

abstract type AbstractDeviceKernel end

terminal_schema(::Type{MyDevice}) = (:p, :n)
state_schema(::MyDevice) = (...)
equation_schema(::MyDevice) = (...)

residual!(r, local, local_dot, terminals, parameters, t, device)
jacobian!(Jz, Jdz, local, local_dot, terminals, parameters, t, device)
noise_model!(S, operating_point, parameters, device)
observables!(output, local, terminals, parameters, device)

Les modèles intégrés doivent fournir des Jacobiennes analytiques.

Pour les modèles utilisateurs, le projet peut inclure une petite implémentation interne de nombres duaux, limitée aux systèmes locaux. Cela évite de différencier l’intégralité du solveur et préserve naturellement la structure creuse.

6. Architecture interne

La chaîne de compilation recommandée est la suivante :

Julia DSL
   ↓
Circuit hiérarchique
   ↓
CircuitIR
   ↓
Élaboration et validation
   ↓
EquationGraph
   ↓
Analyse structurelle
   ↓
CompiledCircuit
   ↓
Résidu et Jacobiennes creuses
   ↓
Solveurs
   ↓
SimulationResult
6.1 CircuitIR

Le premier IR doit conserver :

la hiérarchie ;
les noms ;
les ports ;
les paramètres ;
les modèles de composants ;
les métadonnées ;
les informations de placement éventuelles ;
les observables demandées.

Il ne doit pas encore contenir d’indices numériques de solveur.

6.2 EquationGraph

Après élaboration, le circuit est transformé en graphe d’équations :

ensembles de ports connectés ;
potentiels nodaux ;
courants de branches nécessaires ;
états internes ;
contributions de courant ;
contributions de charge ;
équations algébriques ;
événements ;
sources de bruit.

Ce graphe est le niveau auquel sont effectuées les analyses structurelles.

6.3 CompiledCircuit

Le circuit compilé contient :

l’ordre des inconnues ;
la structure CSC des Jacobiennes ;
les indices d’écriture de chaque composant ;
les groupes de composants par type de modèle ;
les vecteurs de paramètres ;
les valeurs initiales ;
les métadonnées de diagnostic ;
une empreinte de topologie.

La topologie doit être immuable après compilation. Les valeurs de paramètres restent modifiables.

6.4 Regroupement des composants

Il faut éviter de produire une fonction Julia gigantesque contenant une instruction spécialisée pour chaque composant. Cela provoquerait :

des temps de compilation excessifs ;
une consommation mémoire élevée ;
des invalidations ;
une mauvaise montée en taille.

La meilleure stratégie est de regrouper les instances par type de modèle :

DeviceBatch{LinearResistor}
DeviceBatch{ThinFilmResistor}
DeviceBatch{JunctionDiode}
DeviceBatch{C0GCapacitor}

Chaque batch utilise une organisation de données de type structure-of-arrays :

struct ResistorBatch{T}
    resistance::Vector{T}
    tc1::Vector{T}
    tc2::Vector{T}
    p_index::Vector{Int}
    n_index::Vector{Int}
    residual_slots::Vector{Int}
    jacobian_slots::Vector{Int}
end

Un kernel est compilé par type de modèle, puis appliqué à toutes ses instances.

Cela donne un compromis entre :

typage statique ;
temps de compilation ;
vectorisation ;
parallélisme ;
taille du circuit.
6.5 Assemblage creux

La structure des matrices est calculée une fois.

Pendant les itérations :

les vecteurs de résidus sont réutilisés ;
seules les valeurs non nulles des Jacobiennes sont mises à jour ;
aucune allocation n’est autorisée dans les kernels intégrés ;
les factorisations symboliques sont réutilisées lorsque possible.
7. Solveurs
7.1 Point de fonctionnement

Le solveur DC doit résoudre :

[
F(z,0,p,t_0)=0
]

Algorithmes nécessaires :

Newton amorti ;
recherche linéaire ;
région de confiance en secours ;
limitation des variations de tension ;
continuation homotopique ;
source stepping ;
pseudo-transient continuation ;
régularisation contrôlée des systèmes presque singuliers.

Le rapport de convergence doit indiquer :

les équations dominantes ;
les composants ayant les plus grands résidus ;
les variables en divergence ;
les limites de modèles dépassées ;
les éventuelles régularisations appliquées.
7.2 Transitoire

Pour une première version, le choix recommandé est :

BDF d’ordre 1 ;
BDF d’ordre 2 ;
pas adaptatif ;
Newton à chaque pas ;
contrôle séparé des erreurs algébriques et dynamiques.

Les circuits analogiques sont souvent raides. Une méthode explicite générale ne doit pas constituer le backend principal.

Une intégration SciML peut ensuite permettre :

transient(circuit; backend = SciMLBackend(...))

mais le simulateur doit conserver un backend natif minimal.

7.3 Analyse AC

À partir du point de fonctionnement, le système est linéarisé :

[
\left(
J_z + j\omega J_{\dot{z}}
\right)\delta z = b
]

Cette analyse doit utiliser les mêmes modèles que le transitoire. Il ne faut pas maintenir une seconde implémentation manuelle de chaque composant pour l’AC.

7.4 Bruit

Les sources de bruit locales sont assemblées en une matrice spectrale. La propagation est ensuite calculée à travers le système linéarisé.

Les modèles initiaux peuvent inclure :

bruit thermique ;
bruit de grenaille ;
bruit (1/f) ;
bruit excédentaire de résistances ;
corrélations entre sources, lorsque le modèle le requiert.
7.5 Analyses ultérieures

À prévoir après stabilisation du cœur :

sensibilités directes ;
sensibilités adjointes ;
Monte-Carlo ;
mismatch ;
corners ;
periodic steady state ;
harmonic balance ;
analyse de stabilité en boucle ;
optimisation de paramètres ;
estimation de paramètres à partir de mesures.
8. Bibliothèque de composants réalistes

La bibliothèque doit séparer trois concepts.

Valeur d’instance

Exemples :

résistance nominale ;
capacité nominale ;
dimensions ;
tolérance ;
température initiale.
Modèle physique ou technologique

Exemples :

couche mince ;
couche épaisse ;
C0G ;
X7R ;
électrolytique ;
diode Schottky ;
BJT ;
MOSFET.
Boîtier

Exemples :

0402 ;
0603 ;
axial ;
TO-220 ;
SOT-23.

Ainsi :

R1 = resistor(
    a,
    b;
    value = 10kΩ,
    tolerance = 0.1percent,
    material = ThinFilm(
        tc1 = 15e-6 / K,
        voltage_coefficient = 0.05e-6 / V,
    ),
    package = SMD0603(
        series_inductance = 0.6nH,
        parallel_capacitance = 0.05pF,
    ),
)
8.1 Résistances

Un modèle pratique peut inclure :

coefficient de température linéaire et quadratique ;
coefficient de tension ;
bruit thermique ;
bruit excédentaire ;
inductance série ;
capacité parallèle ;
auto-échauffement concentré ;
tolérance et dérive.
8.2 Condensateurs

Un modèle pratique peut inclure :

ESR ;
ESL ;
fuite ;
absorption diélectrique ;
dépendance à la tension ;
dépendance à la température ;
pertes fréquentielles ;
distribution de tolérance.

L’absorption diélectrique peut être modélisée par un petit réseau interne généré automatiquement.

8.3 Inductances

Un modèle pratique peut inclure :

résistance de bobinage ;
pertes de cœur ;
saturation ;
capacité inter-spires ;
dépendance à la température ;
hystérésis dans un modèle avancé.
8.4 Semi-conducteurs

La première version ne doit pas viser immédiatement la couverture complète des modèles industriels modernes.

Ordre raisonnable :

diode à jonction conservatrice en charge ;
diode Schottky ;
BJT de type Ebers-Moll amélioré ;
modèle BJT plus complet ;
MOSFET pédagogique mais physiquement cohérent ;
import ou réimplémentation de modèles compacts plus avancés selon leurs licences.

Les modèles doivent préciser leur domaine de validité. Une simulation ne devrait pas utiliser silencieusement un modèle hors domaine.

8.5 Amplificateurs opérationnels

Les modèles d’amplificateurs opérationnels devraient être des modèles comportementaux ouverts, composés de blocs physiques :

gain DC ;
pôles ;
zéros ;
slew rate ;
courant de polarisation ;
tension d’offset ;
bruit ;
saturation ;
limites de mode commun ;
limites de courant de sortie ;
récupération de saturation ;
rails d’alimentation.

Cela produit des modèles auditables, contrairement à des sous-circuits opaques.

9. Gestion des unités

Les unités sont utiles pour détecter les erreurs, mais elles ne doivent pas contaminer le solveur numérique.

Architecture recommandée :

valeurs sans unité autorisées, interprétées en SI ;
petits types de quantité intégrés pour les unités électriques usuelles ;
conversion en nombres SI lors de l’élaboration ;
vérification dimensionnelle à la construction ;
extension Unitful optionnelle.

Le solveur ne doit manipuler que des nombres normalisés.

La normalisation numérique est distincte des unités. Le compilateur peut produire des facteurs d’échelle pour éviter qu’un système mélange directement des ordres de grandeur tels que (10^{-12}) et (10^6).

10. Schémas et visualisation

Un schéma conventionnel de qualité humaine ne peut pas être déduit de manière fiable d’une simple topologie.

Il ne faut donc pas promettre une génération automatique parfaite.

Le projet peut cependant fournir trois niveaux de visualisation.

Niveau 1 : rapport structurel
describe(circuit)

Exemple de contenu :

Circuit: LowPass
Nodes: 3
Components: 3
Dynamic states: 1
Algebraic unknowns: 3

vin:
  V1.p
  R1.p

vout:
  R1.n
  C1.p

gnd:
  V1.n
  C1.n
Niveau 2 : graphe topologique automatique
render(circuit; format = :svg, layout = :automatic)

Ce graphe est utile pour vérifier :

les connexions ;
les sous-circuits ;
les nœuds flottants ;
la hiérarchie.

Il ne doit pas être vendu comme un véritable schéma électronique de publication.

Niveau 3 : métadonnées de placement optionnelles
@layout LowPass begin
    place(V1, at = (0, 0))
    place(R1, right_of = V1)
    place(C1, below = :vout)
end

Ces informations sont ignorées par le solveur.

Le schéma reste une vue dérivée. Il ne devient jamais la source de vérité.

11. Diagnostics et explicabilité

La qualité des diagnostics est probablement un avantage concurrentiel plus important que quelques pourcents de performance.

Fonctions recommandées :

check(circuit)
explain(circuit)
explain_failure(result)
validity_report(circuit, result)

Le système doit pouvoir signaler :

« le nœud frontend.bias est flottant » ;
« V1 et V2 imposent des tensions incompatibles » ;
« le modèle de C4 est utilisé au-delà de sa tension nominale » ;
« l’itération est dominée par la jonction base-émetteur de Q7 » ;
« l’inductance idéale L2 forme une boucle sans résistance » ;
« l’échelle numérique de la variable I(L3) est mal conditionnée » ;
« l’état thermique de R8 n’a aucun chemin de dissipation ».

Chaque composant doit exposer ses observables internes :

available_observables(R1)

Par exemple :

courant ;
puissance dissipée ;
température ;
résistance instantanée ;
tension interne ;
contributions de bruit ;
état de saturation.
12. Reproductibilité

Chaque résultat doit contenir une provenance complète :

version du simulateur ;
empreinte de la topologie ;
versions des model packs ;
paramètres ;
unités ;
options de solveur ;
tolérances ;
graine aléatoire ;
régularisations ;
avertissements ;
statistiques de convergence.
provenance(result)

La sérialisation doit enregistrer une représentation stable du circuit, pas seulement un objet Julia arbitraire dépendant de la session.

13. Organisation du logiciel

Pour commencer, un monorepo avec plusieurs modules est préférable à une constellation prématurée de paquets.

Amber.jl
├── Core
│   ├── Ports
│   ├── Units
│   ├── CircuitIR
│   ├── EquationGraph
│   └── Compilation
├── Devices
│   ├── Ideal
│   ├── Passive
│   ├── Semiconductor
│   └── Behavioral
├── Solvers
│   ├── Nonlinear
│   ├── OperatingPoint
│   ├── Transient
│   ├── SmallSignal
│   └── Noise
├── Analysis
│   ├── Sweeps
│   ├── MonteCarlo
│   └── Sensitivity
├── Results
├── Diagnostics
└── Extensions
    ├── UnitfulExt
    ├── SciMLExt
    ├── MakieExt
    ├── GraphvizExt
    └── TablesExt

Lorsque les interfaces sont stabilisées, la bibliothèque de modèles peut être séparée :

AmberCore.jl
AmberDevices.jl
AmberModelPacks.jl
AmberViz.jl
14. Interfaces internes à stabiliser en priorité

Les premières RFC du projet devraient porter sur cinq contrats.

RFC 1 — Sémantique des ports
orientation du courant ;
référence de potentiel ;
connexions ;
ports optionnels ;
ports vectoriels.
RFC 2 — Modèle de composant
courants ;
charges ;
flux ;
états ;
bruit ;
événements ;
observables ;
validité.
RFC 3 — CircuitIR
hiérarchie ;
identifiants stables ;
paramètres ;
métadonnées ;
sérialisation.
RFC 4 — CompiledCircuit
indices ;
structure creuse ;
batches ;
paramètres modifiables ;
invalidation de compilation.
RFC 5 — Contrat du solveur
calcul de résidu ;
Jacobiennes ;
initialisation ;
événements ;
statistiques ;
diagnostics.

Tant que ces contrats ne sont pas stables, il est inutile d’accumuler de nombreux modèles.

15. MVP recommandé

Le premier produit réellement utilisable devrait contenir :

Langage
Circuit, Node, Ground ;
composants à deux et plusieurs ports ;
hiérarchie ;
paramètres ;
observables ;
macro @circuit ;
API builder sans macro.
Modèles
résistance idéale et pratique ;
condensateur idéal et pratique ;
inductance idéale et pratique ;
sources indépendantes ;
sources contrôlées ;
commutateur lissé ;
diode à jonction ;
BJT simple ;
modèle comportemental d’amplificateur opérationnel.
Analyses
vérification structurelle ;
point de fonctionnement ;
transitoire BDF1/BDF2 ;
AC petits signaux ;
balayages de paramètres.
Infrastructure
Jacobiennes creuses ;
modèles analytiques intégrés ;
résultats reproductibles ;
rapport de convergence ;
export tabulaire ;
graphe topologique SVG optionnel.

Ne devraient pas appartenir au MVP :

compatibilité complète SPICE ;
import automatique de modèles propriétaires ;
GUI d’édition ;
routage de schémas ;
harmonic balance ;
modèle MOSFET industriel complet ;
simulation électromagnétique distribuée ;
solveur multiphysique général.
16. Validation scientifique

Chaque modèle doit être livré avec :

équations documentées ;
conventions de signes ;
unités ;
domaine de validité ;
tests analytiques ;
tests de conservation ;
tests de dérivées ;
tests de bruit ;
courbes de référence ;
exemples de mauvais usage.

Le projet devrait disposer de quatre niveaux de tests.

Tests analytiques

Exemples :

constante de temps RC ;
réponse RLC ;
gain petits signaux ;
puissance moyenne ;
bruit thermique.
Tests structurels

Génération de topologies aléatoires afin de vérifier :

détection des nœuds flottants ;
singularités ;
conservation des courants ;
stabilité de l’indexation ;
reproductibilité de la compilation.
Tests croisés

Comparer certains résultats à plusieurs simulateurs existants ne transforme pas le projet en wrapper SPICE. Cela fournit une référence indépendante.

Tests expérimentaux

Pour les modèles réalistes, la validation finale doit se faire sur des mesures :

réseaux passifs ;
diodes ;
transistors ;
amplificateurs ;
comportements thermiques simples.

Les jeux de données doivent être versionnés séparément des modèles.

17. Gouvernance des modèles

La bibliothèque de modèles sera probablement plus difficile à maintenir que le solveur.

Chaque contribution de modèle devrait fournir :

une référence technique ;
une licence compatible ;
les équations ;
les paramètres ;
les plages de validité ;
les tests ;
des courbes de validation ;
une note sur les limites connues.

Les modèles ne doivent pas être modifiés silencieusement. Leur version mathématique doit être traçable.

Une nomenclature telle que celle-ci peut être utilisée :

JunctionDiode@1
JunctionDiode@2
ThinFilmResistor@1
BehavioralOpAmp@3
18. Décisions architecturales recommandées
Sujet	Décision
Abstraction utilisateur	Ports et composants Julia
Formalisme interne	DAE électrique et MNA généralisée
Symbolique généraliste	Absent du cœur
ModelingToolkit	Extension optionnelle
Solveur principal	Natif Julia
SciML	Backend optionnel
Jacobiennes	Analytiques pour les modèles intégrés
Modèles utilisateur	Différentiation locale ou Jacobienne personnalisée
Stockage des composants	Batches par type
Matrices	Creuses, structure préallouée
GUI	Hors périmètre
Schéma	Vue topologique dérivée
Unités	Vérifiées puis supprimées avant résolution
Hiérarchie	Préservée dans les métadonnées
Paramètres	Modifiables sans recompilation topologique
Multiphysique	Extensions limitées, pas objectif central
19. Principal compromis

Le projet ne doit pas essayer d’être simultanément :

un langage de modélisation général ;
un remplacement compatible de SPICE ;
un éditeur de schémas ;
un moteur de simulation multiphysique ;
une bibliothèque de tous les composants existants ;
un environnement d’optimisation ;
un outil temps réel.

Le cœur défend une idée plus étroite :

Une description Julia simple produit un système électrique rigoureux, inspectable, compilé et simulé par une chaîne entièrement ouverte.

Cette limitation est une force. Elle permet d’éviter le principal problème de ModelingToolkit dans ce contexte : l’utilisateur ne devrait pas avoir à comprendre et orchestrer lui-même l’expansion symbolique, la simplification structurelle, l’index reduction, la construction du problème et le choix d’un solveur.

Dans l’usage normal, ceci doit suffire :

result = simulate(circuit, Transient(0s => 10ms))

Les étapes intermédiaires doivent rester accessibles pour les experts, mais ne doivent pas être obligatoires.

20. Recommandation finale

Je recommande de construire un compilateur électronique spécialisé, et non une surcouche de ModelingToolkit.

L’architecture centrale serait :

une DSL Julia minimale ;
un modèle acausal fondé sur les ports ;
des primitives électroniques spécialisées — courant, charge, flux, état et bruit ;
un IR hiérarchique ;
une analyse structurelle propre au domaine ;
une MNA généralisée comme backend ;
des kernels de composants regroupés par type ;
des résidus et Jacobiennes creuses préallouées ;
des solveurs natifs Julia ;
des extensions optionnelles pour SciML, Unitful et la visualisation.

Le premier objectif technique ne devrait pas être la performance maximale ni le nombre de composants disponibles. Il devrait être la stabilisation d’un contrat de modélisation permettant d’écrire un composant réaliste de manière concise, testable et sans dépendre d’un système symbolique généraliste.

Si ce contrat est réussi, les solveurs, les modèles, les outils d’analyse et les interfaces graphiques éventuelles pourront évoluer indépendamment.
