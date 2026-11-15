"""Hand-authored schematics of the README tour and electrical examples.

Run from any directory with `pixi run schematics`. Labels follow README net names.
"""
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import schemdraw
import schemdraw.elements as e

OUT = Path(__file__).resolve().parent

def drawing():
    return schemdraw.Drawing(show=False, fontsize=11)

def save(d, name):
    for extension in ('svg', 'png'):
        d.save(OUT / f'{name}.{extension}', dpi=160)

# Tour: source, series resistor, shunt capacitor.
d = drawing()
d += e.SourceV().at((0, 0)).up().label('Source\n1 V DC / AC\n0–1 V step')
d += e.Resistor().right().label('R1  10 kΩ')
d += e.Dot().label('vout', loc='right')
d += e.Capacitor().down().label('C1  10 nF')
d += e.Line().left()
d += e.Ground()
save(d, 'low_pass')

# Quarter bridge; both midpoint labels denote the differential measurement.
d = drawing()
d += e.SourceV().at((0, 0)).up().length(6).label('Supply  5 V')
d += e.Line().right().length(3)
d += e.Dot().label('excitation')
d += e.Resistor().down().label('Gauge  350.35 Ω')
d += e.Dot().label('sense', loc='left')
d += e.Resistor().down().label('R2  350 Ω')
d += e.Line().left().length(3)
d += e.Ground()
d += e.Line().at((3, 6)).right().length(4)
d += e.Resistor().down().label('R3  350 Ω')
d += e.Dot().label('reference', loc='right')
d += e.Resistor().down().label('R4  350 Ω')
d += e.Line().to((3, 0))
save(d, 'strain_bridge')

# Half-wave rectifier: ESR shown explicitly because README specifies it.
d = drawing()
d += e.SourceSin().at((0, 0)).up().label('Source\n10 V peak, 50 Hz')
d += e.Diode().right().label('D1')
d += e.Dot().label('output')
d += e.Line().right().length(3)
d += e.Resistor().down().label('Load  1 kΩ')
d += e.Line().left().length(6)
d += e.Ground()
d += e.Capacitor().at((3, 3)).down().length(1.8).label('C1  470 µF')
d += e.Resistor().down().to((3, 0)).label('ESR  180 mΩ')
save(d, 'rectifier')

# Follower with explicit feedback and supply annotations.
d = drawing()
op = d.add(e.Opamp().at((3, 2)))
d += e.Line().at(op.in2).left().length(1.5).label('input', loc='top')
p = d.here
d += e.SourceV().down().reverse().length(2.5).label('Source\n1 V DC / AC')
d += e.Ground()
d += e.Line().at(op.out).right().length(2).label('output', loc='top')
out = d.here
d += e.Resistor().down().label('Load  10 kΩ', loc='bottom')
d += e.Ground()
d += e.Line().at(out).up().length(2)
d += e.Line().left().tox(op.in1)
d += e.Line().to(op.in1)
d += e.Line().at(op.vd).up().length(.7)
d += e.Label().at((op.vd.x + 1.4, op.vd.y + .45)).label('vdd: +5 V (VDD)')
d += e.Line().at(op.vs).down().length(.7)
d += e.Label().at((op.vs.x + 1.4, op.vs.y - .8)).label('vss: −5 V (VSS)')
save(d, 'follower')

# CMOS pair; conventional symbols, explicit bulk ties in the caption.
d = drawing()
p = d.add(e.PFet().reverse().at((3, 5)).label('PullUp', loc='right'))
n = d.add(e.NFet().reverse().at((3, 1)).label('PullDown', loc='right', ofst=.3))
d += e.Line().at(p.drain).to(n.drain)
d += e.Line().at(p.source).up().length(1).label('supply: 5 V (VDD)', loc='top')
d += e.Line().at(n.source).down().length(1)
d += e.Ground()
d += e.Line().at(p.gate).left().length(1)
g = d.here
d += e.Line().to((g.x, n.gate.y))
d += e.Line().to(n.gate)
d += e.Line().at(g).left().length(2).label('input')
d += e.SourceV().down().reverse().label('Input  0–5 V')
d += e.Ground()
mid = ((p.drain.x+n.drain.x)/2, (p.drain.y+n.drain.y)/2)
d += e.Dot().at(mid)
d += e.Line().right().length(3).label('output', loc='top', ofst=.25)
d += e.Capacitor().down().label('Load  20 pF')
d += e.Ground()
save(d, 'cmos_inverter')
print(f'Wrote five schematics (SVG and PNG) to {OUT}')
