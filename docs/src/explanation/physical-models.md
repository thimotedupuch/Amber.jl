# Physical model scope

Amber's compact models balance expressive circuit experiments against understandable equations.

The diode combines Shockley current with optional breakdown, series resistance, depletion capacitance, and transit charge. The NPN model captures forward/reverse transport, Early effect, base resistance, and junction charge, but it is not a complete foundry Gummel–Poon implementation. `Level1MOSFET` uses symmetric Shichman--Hodges channel equations for NMOS and PMOS devices, including body effect and channel-length modulation. Its gate capacitances are fixed linear capacitances rather than bias-dependent charges. The behavioral op amp captures dominant linear and rail effects; declared slew/current-limit parameters are not yet fully enforced. Switch models approximate resistance transitions, feedthrough, and limited event charge injection.

Parameter names resembling datasheet quantities do not guarantee datasheet-wide validity. Temperature dependence is partial, self-heating is absent, and flicker noise is not implemented. The MOSFET model omits subthreshold conduction, body diodes, junction charge, mobility degradation, velocity saturation, and short-channel effects; use BSIM-class tooling for foundry or advanced-node work. Use validity reports and compare against hand calculations inside the regime each model represents.
