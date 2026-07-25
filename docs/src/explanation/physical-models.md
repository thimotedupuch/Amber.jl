# Physical model scope

Amber's compact models balance expressive circuit experiments against understandable equations.

The diode combines Shockley current with optional breakdown, series resistance, depletion capacitance, and transit charge. The NPN model captures forward/reverse transport, Early effect, base resistance, and junction charge, but it is not a complete foundry Gummel–Poon implementation. The behavioral op amp captures dominant linear and rail effects; declared slew/current-limit parameters are not yet fully enforced. Switch models approximate resistance transitions, feedthrough, and limited event charge injection.

Parameter names resembling datasheet quantities do not guarantee datasheet-wide validity. Temperature dependence is partial, self-heating is absent, flicker noise is not implemented, and MOSFET/CMOS compact models are future work. Use validity reports and compare against hand calculations inside the regime each model represents.

