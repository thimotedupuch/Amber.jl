# Compilation and topology reuse

`compile` separates structural work from numerical values. Amber streams the retained hierarchy into typed device batches, assigns node, branch, and state unknowns, constructs the sparse Jacobian pattern, and fingerprints topology. The resulting `CompiledCircuit` retains the immutable `CircuitDesign`, `CompiledTopology`, and `ParameterStore`; it does not contain a flattened circuit or dynamically generated path symbols.

Repeated analysis can reuse ordering and sparse symbolic information. Recompiling a compiled circuit after parameter-only changes can reuse topology when the structural fingerprint is unchanged. Adding a node, changing connectivity, or replacing a device with one requiring different states invalidates that reuse.

`UnknownLayout` and `EquationLayout` classify every matrix row and column for scaling, diagnostics, and future partition interfaces. Numerical updates made with `with_parameters` share the topology and untouched batches. Compilation is not native-code generation and does not make invalid circuits valid; it makes equation structure explicit and reusable.
