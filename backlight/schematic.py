"""Генератор schematic.svg — схемы подсветки козырька (RP2040-Zero).

Схему правим здесь, а не в SVG. Пересобрать (из этой папки):
    python3 -m venv /tmp/sd && /tmp/sd/bin/pip install schemdraw==0.19
    /tmp/sd/bin/python schematic.py
"""

import schemdraw
import schemdraw.elements as elm

TOP, BOT = 15.0, 0.0  # шина +5 В и GND
FS = 11


def ic(pins, size, label, at):
    """Микросхема/модуль. Пины слева и справа schemdraw кладёт снизу вверх,
    поэтому здесь они перечислены сверху вниз и разворачиваются."""
    ordered = [p for p in pins if p[1] in ("top", "bottom")]
    for side in ("left", "right"):
        ordered += [p for p in pins if p[1] == side][::-1]
    return (
        elm.Ic(pins=[elm.IcPin(name=n, side=s, anchorname=a) for n, s, a in ordered],
               size=size, pinspacing=1.2)
        .right()  # иначе Ic наследует направление предыдущего элемента и поворачивается
        .label(label, fontsize=FS)
        .at(at)
    )


def note(d, xy, text, halign="left", valign="center"):
    d += elm.Label().at(xy).label(text, fontsize=9, halign=halign, valign=valign)


with schemdraw.Drawing(file="schematic.svg", show=False) as d:
    d.config(fontsize=FS, unit=2.5, lw=1.2)

    # ---- J1: гнездо USB-C на платке ----
    j1 = ic([("V", "top", "V"), ("G", "bottom", "G")], (2.4, 5), "J1\nUSB-C\nгнездо", (0, 5))
    d += j1
    d += elm.Line().at(j1.V).toy(TOP)
    d += elm.Line().at(j1.G).toy(BOT)
    note(d, (j1.G[0] + 0.3, 2.6), "CC 5,1 кОм на платке;\nD+/D− не подключать")

    # ---- C1, C2 у входа ----
    for x, polar, text in ((5.5, True, "C1\n100 мкФ 16 В\nlow-ESR"), (8.5, False, "C2\n0,1 мкФ\nкерамика")):
        d += elm.Dot().at((x, TOP))
        d += elm.Capacitor(polar=polar).at((x, TOP)).down().toy(BOT).label(text, loc="bottom", ofst=0.2)
        d += elm.Dot().at((x, BOT))
    d += elm.Ground().at((7, BOT))
    note(d, (5.2, TOP - 2.2), "не 1000 мкФ: бросок тока\nуводит USB-C зарядник в защиту", halign="right")

    # ---- J2: кабель Kindle ----
    j2 = ic([("VBUS", "top", "VBUS"), ("GND", "bottom", "GND"), ("D+", "right", "DP"), ("D−", "right", "DM")],
            (3.6, 5), "J2\nKindle 4\nmicro-USB\n(отрезанный\nкабель)", (11.5, 5))
    d += j2
    for a, y in (("VBUS", TOP), ("GND", BOT)):
        p = getattr(j2, a)
        d += elm.Dot().at((p[0], y))
        d += elm.Line().at(p).toy(y)
    bx = j2.DP[0] + 0.8
    d += elm.Line().at(j2.DP).tox(bx)
    d += elm.Line().at((bx, j2.DP[1])).toy(j2.DM[1])
    d += elm.Line().at((bx, j2.DM[1])).tox(j2.DM[0])
    note(d, (bx + 0.3, (j2.DP[1] + j2.DM[1]) / 2), "соединить\nи заизолировать")

    # ---- U2: энкодер, U1: RP2040-Zero ----
    # Пины энкодера GND / + / SW / DT / CLK совпадают по порядку с пинами Zero
    # GND / 3V3 / GP29 / GP28 / GP27 — прямой шлейф.
    u2 = ic([("+", "right", "VCC"), ("SW", "right", "SW"), ("DT", "right", "DT"), ("CLK", "right", "CLK"),
             ("GND", "bottom", "GND")], (3, 6), "U2\nэнкодер\nKY-040", (20.5, 4))
    d += u2
    u1 = ic([("5V", "top", "V5"), ("GND", "bottom", "GND"), ("3V3", "left", "V33"), ("GP29", "left", "GP29"),
             ("GP28", "left", "GP28"), ("GP27", "left", "GP27"), ("GP14", "right", "GP14")],
            (5.4, 6), "U1\nRP2040-Zero", (28, 4))
    d += u1
    for a, b in (("VCC", "V33"), ("SW", "GP29"), ("DT", "GP28"), ("CLK", "GP27")):
        d += elm.Line().at(getattr(u2, a)).to(getattr(u1, b))
    for u in (u2, u1):
        d += elm.Dot().at((u.GND[0], BOT))
        d += elm.Line().at(u.GND).toy(BOT)
    note(d, (u2.VCC[0] + 0.3, 12.6),
         "энкодер — шлейфом 5 жил в пины Zero\nGND, 3V3, GP29, GP28, GP27 подряд;\n"
         "+ энкодера — от 3V3, не от 5 В;\nCLK, DT — по 10 нФ на GND (опц.)")

    # D1: шина → пин 5V. Мак по USB-C платы питает только плату, не шину.
    d += elm.Dot().at((u1.V5[0], TOP))
    d += elm.Schottky().at((u1.V5[0], TOP)).down().toy(u1.V5[1]).label("D1\n1N5819", loc="bottom", ofst=0.2)

    # ---- Q1: ключ по минусу ----
    rx = u1.GP14[0] + 0.8
    gx = rx + 4.0           # узел затвора: R1 слева, R2 вниз
    qx = gx + 2.6           # исток/сток Q1 и первая нить
    LAST_X = qx + 8
    d += elm.Dot().at((qx, BOT))
    d += elm.Line().at((qx, BOT)).up().length(1.2)
    q1 = elm.NFet().right().reverse().anchor("source").at((qx, 1.2))
    d += q1
    note(d, (qx + 0.5, 2.0), "Q1\nAO3400A\n(N-канал)")
    gate_y = q1.gate[1]
    d += elm.Line().at(u1.GP14).tox(rx)
    d += elm.Line().at((rx, u1.GP14[1])).toy(gate_y)
    d += elm.Resistor().at((rx, gate_y)).right().length(3.0).label("R1 100 Ом", loc="top")
    d += elm.Line().tox(gx)
    d += elm.Dot().at((gx, gate_y))
    d += elm.Resistor().at((gx, gate_y)).down().toy(BOT).label("R2\n10 кОм", loc="bottom", ofst=0.2)
    d += elm.Dot().at((gx, BOT))
    d += elm.Line().at((gx, gate_y)).tox(q1.gate[0])

    # ---- Нити: шина → R → нить → LAMP− (в козырьке) → сток Q1 ----
    lamp_y = 7.4
    xs = [qx, qx + 4, LAST_X]
    for i, lx in enumerate(xs):
        if lx != xs[-1]:
            d += elm.Dot().at((lx, TOP))
            d += elm.Dot().at((lx, lamp_y))
        d += elm.Resistor().at((lx, TOP)).down().length(3.2).label(
            f"R{i + 3}\n6,8 Ом\n2 Вт", loc="bottom", ofst=0.15)
        d += elm.Line().down().length(0.8)
        d += elm.LED().down().length(2.4).label(f"LED{i + 1}", loc="bottom", ofst=0.15)
        d += elm.Line().toy(lamp_y)
    d += elm.Line().at((xs[0], lamp_y)).tox(xs[-1])
    d += elm.Line().at((qx, lamp_y)).toy(q1.drain[1])
    note(d, (qx - 0.3, lamp_y - 1.6), "LAMP−", halign="right")

    # Козырёк — пунктиром; R3–R5 остаются на плате в базе.
    hx0, hx1, hy0, hy1 = xs[0] - 1.6, xs[-1] + 2.4, lamp_y - 0.8, TOP - 3.6
    for a, b in (((hx0, hy0), (hx1, hy0)), ((hx1, hy0), (hx1, hy1)), ((hx1, hy1), (hx0, hy1)), ((hx0, hy1), (hx0, hy0))):
        d += elm.Line().at(a).to(b).linestyle("--")
    note(d, (hx1, hy0 - 0.4), "козырёк: к плате 4 провода\n(3 нити после резисторов + LAMP−)",
         halign="right", valign="top")

    # ---- Шины ----
    d += elm.Line().at((0, TOP)).tox(LAST_X)
    d += elm.Line().at((0, BOT)).tox(LAST_X + 2.5)
    d += elm.Label().at((0, TOP + 0.6)).label("+5 В", halign="left")
    d += elm.Label().at((0, BOT - 0.8)).label("GND", halign="left")

    note(d, (LAST_X + 2.5, BOT - 1.0), "COB-нити 2700K, 3 В, 0,3 А — каждая со своим резистором",
         halign="right")
