using Amber
using Documenter

DocMeta.setdocmeta!(Amber, :DocTestSetup, :(using Amber); recursive=true)

makedocs(
    sitename="Amber.jl",
    modules=[Amber],
    format=Documenter.HTML(prettyurls=get(ENV,"CI","false")=="true",collapselevel=1),
    clean=true,
    doctest=true,
    checkdocs=:exports,
    warnonly=Symbol[],
    pages=[
        "Home"=>"index.md",
        "Getting started"=>[
            "Installation"=>"getting-started/installation.md",
            "Your first circuit"=>"getting-started/first-circuit.md",
            "Reading results"=>"getting-started/reading-results.md",
        ],
        "Manual"=>[
            "Circuit construction"=>"manual/circuit-construction.md",
            "Hierarchy"=>"manual/hierarchy.md",
            "Units"=>"manual/units.md",
            "Devices and models"=>"manual/devices-and-models.md",
            "Operating point"=>"manual/operating-point.md",
            "Transient analysis"=>"manual/transient.md",
            "Small-signal AC"=>"manual/small-signal.md",
            "Noise analysis"=>"manual/noise.md",
            "Results and observables"=>"manual/observables-and-results.md",
            "Diagnostics"=>"manual/diagnostics.md",
            "Sweeps"=>"manual/sweeps.md",
            "Monte Carlo"=>"manual/monte-carlo.md",
            "Persistence"=>"manual/persistence.md",
        ],
        "Tutorials"=>[
            "Diode rectifier"=>"tutorials/diode-rectifier.md",
            "Common-emitter amplifier"=>"tutorials/common-emitter.md",
            "Sample and hold"=>"tutorials/sample-and-hold.md",
            "Buck converter"=>"tutorials/buck-converter.md",
            "Hierarchical active filter"=>"tutorials/hierarchical-filter.md",
            "Precision bridge"=>"tutorials/precision-bridge.md",
        ],
        "How Amber works"=>[
            "Sign conventions"=>"explanation/sign-conventions.md",
            "Generalized MNA"=>"explanation/generalized-mna.md",
            "Compilation"=>"explanation/compilation.md",
            "Nonlinear solving"=>"explanation/nonlinear-solving.md",
            "Transient integration"=>"explanation/transient-integration.md",
            "AC and noise"=>"explanation/ac-and-noise.md",
            "Physical models"=>"explanation/physical-models.md",
            "Reproducibility"=>"explanation/reproducibility.md",
            "Verification"=>"explanation/verification.md",
            "Current limitations"=>"limitations.md",
        ],
        "API reference"=>[
            "Circuits"=>"reference/circuits.md",
            "Devices"=>"reference/devices.md",
            "Analyses"=>"reference/analyses.md",
            "Results"=>"reference/results.md",
            "Monte Carlo"=>"reference/monte-carlo.md",
            "Diagnostics"=>"reference/diagnostics.md",
            "Serialization"=>"reference/serialization.md",
        ],
        "Development"=>[
            "Architecture"=>"development/architecture.md",
            "Device contract"=>"development/device-contract.md",
            "Testing"=>"development/testing.md",
        ],
    ],
)
