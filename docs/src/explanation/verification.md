# Verification strategy

Amber's `test/verification` directory checks circuits with closed-form or textbook results. These tests cover divider laws, Thévenin/Norton equivalence, RC/RL time constants, RLC resonance, AC filters, noise identities, diode bias, conservation, and numerical refinement.

This provides strong evidence that assembly and analyses agree with known mathematics across independent mechanisms. It is especially valuable because the expected values are transparent and reviewable.

It does not prove correctness for every topology or parameter regime. Shared mistakes can survive a hand-derived oracle, compact models may be incomplete, and difficult nonlinear/event behavior needs adversarial testing. The verification ladder is therefore:

1. analytic identities and limiting cases;
2. conservation and invariants;
3. time-step, tolerance, and frequency-grid refinement;
4. regression tests for discovered failures;
5. selective independent comparison when the cost is justified.

