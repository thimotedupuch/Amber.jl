# Compilation and topology reuse

`compile` separates structural work from numerical values. Amber assigns node, branch, and state indices; computes a sparse Jacobian pattern; and fingerprints topology. The resulting `CompiledCircuit` owns a frozen circuit copy and a `CompiledTopology`.

Repeated analysis can reuse ordering and sparse symbolic information. Recompiling a compiled circuit after parameter-only changes can reuse topology when the structural fingerprint is unchanged. Adding a node, changing connectivity, or replacing a device with one requiring different states invalidates that reuse.

Freezing is important for reproducibility: mutating the original `Circuit` after compilation cannot silently change an existing compiled object. Compilation is not native-code generation and does not make invalid circuits valid; it makes equation structure explicit and reusable.

