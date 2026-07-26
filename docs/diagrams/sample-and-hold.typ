#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 8pt)

#zap.circuit({
  import zap: *
  vsource("input", (0, 0), (0, 3), current: "sin", label: $V_"in"$)
  switch("sample", "input.out", (3, 3), label: $S_1 ("clock")$, closed: false)
  node("hold", (3, 3), label: $V_"hold"$)
  capacitor("ch", (3, 3), (3, 0), label: $C_"hold"$)
  // Zap's `plus` and `minus` anchors are ±0.45 from the symbol origin.
  // Offset the origin so the non-inverting input lands on the hold net.
  opamp("buffer", (6, 3.45), label: "buffer")
  wire((3, 3), "buffer.plus")
  wire(
    "buffer.out",
    (8, 3.45),
    (8, 4.8),
    (4.8, 4.8),
    (4.8, 3.9),
    "buffer.minus",
  )
  estub((8, 3.45), label: $V_"out"$)
  wire((0, 0), (3, 0))
  ground("gnd", (1.5, 0))
})
