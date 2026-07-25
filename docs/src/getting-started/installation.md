# Installation

Amber supports Julia 1.10 and later. Until Amber is registered, install it
from a local checkout:

```julia
using Pkg
Pkg.activate("/path/to/Amber.jl")
Pkg.instantiate()
using Amber
```

Run the complete package and mathematical verification suite with:

```julia
using Pkg
Pkg.test()
```

Amber uses SI internally. Expressions such as `10kΩ`, `4.7μF`, and `20MHz`
are numeric SI values, not dimension-carrying quantities. See [Units](@ref)
for the consequences of that design.

When a canonical repository is published, `Pkg.add(url="…")` can install it
directly. This guide avoids embedding a provisional URL.
