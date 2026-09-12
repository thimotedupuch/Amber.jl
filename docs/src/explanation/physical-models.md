# Physical model scope

Amber's compact models balance expressive circuit experiments against understandable equations.

The diode combines Shockley current with optional breakdown, series resistance, depletion capacitance, and transit charge. The NPN model captures forward/reverse transport, Early effect, base resistance, and junction charge, but it is not a complete foundry Gummel–Poon implementation. `Level1MOSFET` uses symmetric Shichman--Hodges channel equations for NMOS and PMOS devices, including body effect and channel-length modulation. Its gate capacitances are fixed linear capacitances rather than bias-dependent charges. The behavioral op amp captures dominant linear and rail effects; declared slew/current-limit parameters are not yet fully enforced. Switch models approximate resistance transitions, feedthrough, and limited event charge injection.

Parameter names resembling datasheet quantities do not guarantee datasheet-wide validity. Temperature dependence is partial and self-heating is absent. Explicit power-law, channel, gate, shot, and thermal-noise parameters apply to Amber's compact equations; they are not foundry model-card parameters. The Level1MOSFET model omits subthreshold conduction, body diodes, junction charge, mobility degradation, velocity saturation, and short-channel effects; use BSIM-class tooling for foundry or advanced-node work. Use validity reports and compare against hand calculations inside the regime each model represents.

`ChargeBasedMOSFET` is an alternative native long-channel model with continuous
inversion, explicit geometry, Ward–Dutton terminal charges, optional body
junctions and simple temperature laws. It uses constant slope-factor bulk
coupling and omits intrinsic depletion/accumulation charge and short-channel
physics. It is not a full EKV implementation. See [Charge-based MOSFET](@ref)
for the equations, parameter units and numerical integration contract.
