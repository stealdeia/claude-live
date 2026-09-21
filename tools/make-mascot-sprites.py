#!/usr/bin/env python3
"""Disegna gli sprite sheet delle mascotte incluse.

Perché uno script e non dei PNG nel repo: i disegni sono ricostruibili e
modificabili una riga alla volta — un'orecchia più bassa, un colore più scuro,
una posa in più — e il formato che produce è *esattamente* quello che l'app
accetta anche da una cartella scelta dall'utente.

## Com'è fatto

Ogni personaggio disegna delle **pose**, non dei fotogrammi: `Pose` dice cosa sta
succedendo (è sollevato di tre pixel, ha gli occhi chiusi, ha due puntini di
pensiero sopra la testa) e ogni personaggio sa come si disegna *lui* in quella
posa. Le scene — le sei animazioni — sono quindi scritte una volta sola e valgono
per tutti: aggiungere un personaggio vuol dire scrivere una funzione che lo
disegna, non ridisegnare ventidue fotogrammi.

Niente dipendenze: il PNG lo scrive `zlib`, che è nella libreria standard.

Uso:  python3 tools/make-mascot-sprites.py
"""

import json
import os
import struct
import zlib

# I personaggi si disegnano su una griglia di 48×48 **unità**, e ogni unità vale
# quattro pixel veri. Le due cose sono separate apposta:
#
#   * le unità sono la scala a cui si pensa il disegno — un occhio è largo 3, le
#     orecchie stanno a ±9 dal centro — e restano quelle di sempre, quindi il
#     codice di disegno non cambia quando si alza la risoluzione;
#   * i pixel sono la finezza con cui quelle forme vengono rasterizzate, ed è
#     lì che si vede la differenza: una curva calcolata ogni quarto di unità ha
#     la scaletta quattro volte più piccola di una calcolata a ogni unità.
#
# Il primo tentativo era 32×32 a un pixel per unità: «una macchia con due
# occhi». Poi 48×48 a due: si capiva il cane, ma i quadretti si vedevano tutti.
# Adesso il foglio esce a 192 px per fotogramma e la mascotte ne misura 96 sullo
# schermo: su un Mac Retina è **un pixel del disegno per un pixel dello
# schermo**, che è il massimo che abbia senso — oltre, si butterebbe via roba.
CELL = 48                     # unità di disegno per lato
UNIT = 4                      # pixel per unità
CELL_PX = CELL * UNIT         # 192 px di lato
FRAME = CELL_PX               # una cella del foglio
POINT_SIZE = 96               # quanto misura sullo schermo, in punti
COLUMNS = 8

TRANSPARENT = (0, 0, 0, 0)
ZZZ = (206, 214, 236, 255)


# --------------------------------------------------------------------------
# Tela

def blank():
    return [[TRANSPARENT] * CELL_PX for _ in range(CELL_PX)]


def dot(g, px, py, color):
    """Un pixel vero. Le funzioni qui sotto ragionano in unità e passano da qui."""
    if 0 <= px < CELL_PX and 0 <= py < CELL_PX:
        g[py][px] = color


def put(g, x, y, color):
    """Un quadretto di un'unità: gli accenti — una narice, un riflesso."""
    for py in range(int(y * UNIT), int(y * UNIT) + UNIT):
        for px in range(int(x * UNIT), int(x * UNIT) + UNIT):
            dot(g, px, py, color)


def rect(g, x0, y0, w, h, color):
    for py in range(int(y0 * UNIT), int((y0 + h) * UNIT)):
        for px in range(int(x0 * UNIT), int((x0 + w) * UNIT)):
            dot(g, px, py, color)


def ellipse(g, cx, cy, rx, ry, color):
    """Un'ellisse rasterizzata al pixel, non all'unità.

    È qui che si guadagna la finezza: il bordo viene deciso quattro volte per
    unità invece di una, quindi le curve smettono di essere una scala.
    """
    fcx, fcy = (cx + 0.5) * UNIT, (cy + 0.5) * UNIT
    frx, fry = max(rx * UNIT, 0.5), max(ry * UNIT, 0.5)
    for py in range(int(fcy - fry) - 1, int(fcy + fry) + UNIT + 1):
        for px in range(int(fcx - frx) - 1, int(fcx + frx) + UNIT + 1):
            dx = (px + 0.5 - fcx) / frx
            dy = (py + 0.5 - fcy) / fry
            if dx * dx + dy * dy <= 1.0:
                dot(g, px, py, color)


def rounded(g, cx, cy, rx, ry, color, cut=2):
    fcx, fcy = (cx + 0.5) * UNIT, (cy + 0.5) * UNIT
    frx, fry, fcut = rx * UNIT, ry * UNIT, cut * UNIT
    for py in range(int(fcy - fry), int(fcy + fry) + UNIT):
        for px in range(int(fcx - frx), int(fcx + frx) + UNIT):
            if abs(px + 0.5 - fcx) > frx - fcut and abs(py + 0.5 - fcy) > fry - fcut:
                continue
            dot(g, px, py, color)


def outline_ellipse(g, cx, cy, rx, ry, fill, line):
    ellipse(g, cx, cy, rx + 1, ry + 1, line)
    ellipse(g, cx, cy, rx, ry, fill)


def outline_rounded(g, cx, cy, rx, ry, fill, line, cut=2):
    rounded(g, cx, cy, rx + 1, ry + 1, line, cut + 1)
    rounded(g, cx, cy, rx, ry, fill, cut)


# --------------------------------------------------------------------------
# Le pose

class Pose:
    """Cosa sta facendo il personaggio in questo fotogramma.

    Deliberatamente descrittiva e non geometrica: dice «ha gli occhi spalancati»
    e non «le pupille sono due pixel più in alto», perché dove stiano gli occhi
    lo sa il personaggio, non la scena.
    """

    def __init__(self, lift=0, squash=0, stretch=0, eyes="open", arms="down",
                 think=None, zzz=None, mouth="smile", sway=0, ears=0):
        self.lift = lift          # sollevato (negativo = più in alto)
        self.squash = squash      # schiacciato a terra
        self.stretch = stretch    # allungato (mentre penzola)
        self.eyes = eyes          # open | blink | closed | wide | up
        self.arms = arms          # down | up | wave
        self.think = think        # None, oppure 0..3 puntini accesi
        self.zzz = zzz            # None, oppure 0..3 grandezza della zeta
        self.mouth = mouth        # smile | open | flat | tongue
        self.sway = sway          # inclinazione del corpo, in pixel
        self.ears = ears          # orecchie/antenna piegate


# Le sei animazioni, in pose. L'ordine è quello delle celle nel foglio.
#
# «Al lavoro» è volutamente quasi immobile: sta pensando, e pensare non si vede
# — si capisce dai puntini e dallo sguardo che va in su. Prima sbracciava e
# rimbalzava, e sembrava che stesse festeggiando: la festa deve restare la
# reazione a un fatto, se no non si distingue più niente.
SCENES = [
    ("idle", [
        Pose(),
        Pose(lift=-1),
        Pose(),
        Pose(eyes="blink"),
    ]),
    ("working", [
        Pose(eyes="up", think=0, mouth="flat"),
        Pose(eyes="up", think=1, mouth="flat"),
        Pose(eyes="up", think=2, mouth="flat"),
        Pose(eyes="up", think=3, mouth="flat", lift=-1),
    ]),
    ("notify", [
        Pose(squash=2, eyes="wide", mouth="open", arms="up"),
        Pose(lift=-3, eyes="wide", mouth="open", arms="up", ears=-1),
        Pose(lift=-5, eyes="wide", mouth="open", arms="wave", ears=-2),
        Pose(lift=-4, eyes="wide", mouth="open", arms="up", ears=-1),
        Pose(lift=-2, eyes="wide", mouth="open", arms="wave"),
        Pose(squash=1, eyes="open", mouth="smile", arms="up"),
    ]),
    ("dragging", [
        Pose(stretch=3, eyes="wide", arms="up", mouth="open", sway=-1, ears=-2),
        Pose(stretch=3, eyes="wide", arms="up", mouth="open", sway=1, ears=-1),
    ]),
    ("dropped", [
        Pose(squash=4, eyes="blink", mouth="flat"),
        Pose(squash=1, eyes="open", mouth="smile"),
    ]),
    ("sleeping", [
        Pose(squash=1, eyes="closed", mouth="flat", zzz=0),
        Pose(squash=1, eyes="closed", mouth="flat", zzz=1),
        Pose(squash=2, eyes="closed", mouth="flat", zzz=2),
        Pose(squash=1, eyes="closed", mouth="flat", zzz=3),
    ]),
]


# --------------------------------------------------------------------------
# Pezzi in comune

def draw_eyes(g, cx, cy, spacing, style, palette, radius=4):
    """Gli occhi, uguali per tutti nella meccanica e diversi nel posto."""
    white = palette["eye"]
    pupil = palette["pupil"]
    line = palette["line"]

    for side in (-1, 1):
        ex = cx + side * spacing
        if style in ("closed", "blink"):
            # Palpebra: una linea curva, non un trattino dritto.
            rect(g, ex - radius + 1, cy, 2 * radius - 2, 1, line)
            put(g, ex - radius, cy - 1, line)
            put(g, ex + radius - 1, cy - 1, line)
            continue

        r = radius + 1 if style == "wide" else radius
        outline_ellipse(g, ex, cy, r, r, white, line)
        dy = -2 if style == "up" else 0
        dx = side * (-1 if style == "wide" else 0)
        ellipse(g, ex + dx, cy + dy, 2, 2, pupil)
        # Il punto di luce: è quello che rende uno sguardo vivo invece che
        # dipinto.
        put(g, ex + dx - 1, cy + dy - 1, white)


def ear(g, base_cx, base_y, half_w, height, tilt, c):
    """Un'orecchia a pipistrello, rasterizzata al pixel.

    Disegnata per righe di pixel e non per righe di unità: a unità intere il
    profilo diventava una scala di gradini da quattro pixel, ed era la cosa più
    grossolana rimasta addosso al personaggio. Il profilo è una radice — stretta
    in cima, che si allarga in fretta e poi rallenta — cioè la forma di
    un'orecchia vera, e la punta pende in fuori.
    """
    top = base_y - height
    for py in range(int(top * UNIT), int(base_y * UNIT)):
        t = (py / UNIT - top) / max(height, 0.001)
        if t < 0:
            continue
        fw = max(half_w * (t ** 0.55), 0.35) * UNIT
        fcx = (base_cx + tilt * (1 - t) + 0.5) * UNIT
        for px in range(int(fcx - fw) - 1, int(fcx + fw) + 2):
            d = abs(px + 0.5 - fcx)
            if d > fw:
                continue
            if d > fw - 0.8 * UNIT:
                dot(g, px, py, c["line"])
            elif d < fw * 0.5 and 0.25 < t < 0.92:
                dot(g, px, py, c["ear_in"])
            else:
                dot(g, px, py, c["body"])


def draw_mouth(g, cx, cy, style, palette):
    line = palette["line"]
    if style == "open":
        outline_ellipse(g, cx, cy + 1, 3, 2, palette.get("mouth", line), line)
    elif style == "flat":
        rect(g, cx - 3, cy, 6, 1, line)
    else:  # smile
        rect(g, cx - 3, cy, 6, 1, line)
        put(g, cx - 4, cy - 1, line)
        put(g, cx + 3, cy - 1, line)


def draw_think(g, x0, y0, lit, palette):
    """I puntini del pensiero: tre, in diagonale verso l'alto, che si accendono
    uno alla volta.

    Sono l'unica cosa che si muove mentre lavora, ed è apposta: il personaggio
    resta fermo e si capisce lo stesso che sta pensando.

    In diagonale e di lato, non sopra la testa: sopra la testa ci sono le
    orecchie del bulldog e l'antenna degli altri due, e al primo tentativo il
    terzo puntino finiva fuori dalla cella — cioè tagliato a metà.
    """
    if lit is None:
        return
    accent = palette["accent"]
    line = palette["line"]
    spots = [(x0, y0, 1), (x0 + 5, y0 - 4, 2), (x0 + 9, y0 - 9, 2)]
    for i, (x, y, r) in enumerate(spots):
        if i < lit:
            outline_ellipse(g, x, y, r, r, accent, line)
        else:
            # Spento ma presente: senza il posto vuoto i puntini
            # «salterebbero» invece di accendersi.
            put(g, x, y, line)


def draw_zzz(g, x, y, size, ):
    """Le zeta del sonno, sempre più grandi e sempre più su."""
    if size is None:
        return
    w = 3 + size
    yy = y - size * 2
    rect(g, x, yy, w, 1, ZZZ)
    rect(g, x, yy + w - 1, w, 1, ZZZ)
    for i in range(w):
        put(g, x + w - 1 - i, yy + i, ZZZ)


# --------------------------------------------------------------------------
# I personaggi

def paint_bolla(p, c):
    """Una bollicina con l'antenna: la più semplice delle tre, di proposito."""
    g = blank()
    cy = 30 + p.lift + p.squash
    rx = 16 + p.squash - p.stretch
    ry = 15 - p.squash + p.stretch
    sway = p.sway

    # Antenna, dietro al corpo così la pallina sembra attaccata alla testa.
    top = cy - ry - 5
    lean = p.ears + sway
    rect(g, 24 + sway, top + 3, 2, 5, c["line"])
    outline_ellipse(g, 24 + lean, top, 3, 3, c["accent"], c["line"])

    # Piedini, sotto al corpo.
    for side in (-1, 1):
        fx = 24 + side * 7 + sway
        outline_rounded(g, fx, cy + ry - 1, 4, 2, c["dark"], c["line"], cut=1)

    # Braccine.
    for side in (-1, 1):
        ax = 24 + side * (rx + 1) + sway
        ay = cy - 6 if p.arms in ("up", "wave") else cy + 2
        if p.arms == "wave" and side == 1:
            ay -= 3
        outline_rounded(g, ax, ay, 2, 4, c["body"], c["line"], cut=1)

    outline_ellipse(g, 24 + sway, cy, rx, ry, c["body"], c["line"])
    # Volume: ombra in basso, luce in alto a sinistra.
    ellipse(g, 24 + sway, cy + ry - 4, rx - 4, 3, c["dark"])
    ellipse(g, 24 + sway - rx + 6, cy - ry + 6, 3, 4, c["shine"])
    ellipse(g, 24 + sway - rx + 8, cy - ry + 4, 1, 1, c["shine"])

    face = cy - 3
    draw_eyes(g, 24 + sway, face, 7, p.eyes, c)
    if p.eyes not in ("closed", "blink"):
        for side in (-1, 1):
            ellipse(g, 24 + sway + side * 12, face + 5, 2, 1, c["blush"])
    draw_mouth(g, 24 + sway, face + 7, p.mouth, c)

    draw_think(g, 24 + rx - 3, cy - ry + 1, p.think, c)
    draw_zzz(g, 33, cy - ry - 2, p.zzz)
    return g


def paint_chip(p, c):
    """Un robottino squadrato: testa, corpo, e un pannellino che si accende."""
    g = blank()
    cy = 30 + p.lift + p.squash
    sway = p.sway

    # Testa e corpo insieme devono stare nella cella anche nel fotogramma in
    # cui salta più in alto: al primo tentativo i piedi finivano fuori, e un
    # personaggio tagliato in basso sembra sprofondato nella scrivania.
    head_h = 9 - p.squash + p.stretch
    head_cy = cy - 12 + p.squash
    body_h = 7 - p.squash + p.stretch // 2
    body_cy = head_cy + head_h + body_h - 1

    # Antenna.
    lean = p.ears + sway
    rect(g, 24 + sway, head_cy - head_h - 4, 2, 5, c["line"])
    outline_rounded(g, 24 + lean, head_cy - head_h - 6, 2, 2, c["accent"], c["line"], cut=1)

    # Gambe e piedi.
    for side in (-1, 1):
        fx = 24 + side * 6 + sway
        rect(g, fx - 1, body_cy + body_h, 3, 2, c["line"])
        outline_rounded(g, fx, body_cy + body_h + 3, 4, 2, c["dark"], c["line"], cut=1)

    # Braccia.
    for side in (-1, 1):
        ax = 24 + side * 13 + sway
        ay = body_cy - 6 if p.arms in ("up", "wave") else body_cy
        if p.arms == "wave" and side == -1:
            ay -= 3
        outline_rounded(g, ax, ay, 2, 4, c["body"], c["line"], cut=1)

    # Corpo, con il pannello.
    outline_rounded(g, 24 + sway, body_cy, 11, body_h, c["body"], c["line"])
    rounded(g, 24 + sway, body_cy, 7, max(body_h - 3, 2), c["dark"], cut=1)
    for i in range(3):
        lit = p.think is not None and i < p.think
        color = c["accent"] if lit else c["line"]
        rect(g, 20 + sway + i * 4, body_cy - 1, 2, 2, color)

    # Testa, con la visiera scura in cui stanno gli occhi.
    outline_rounded(g, 24 + sway, head_cy, 14, head_h, c["body"], c["line"])
    rounded(g, 24 + sway, head_cy - 1, 11, max(head_h - 3, 3), c["visor"], cut=2)
    # Due bulloni ai lati, che danno la scala di tutto il resto.
    for side in (-1, 1):
        ellipse(g, 24 + sway + side * 13, head_cy + 3, 1, 1, c["dark"])

    draw_eyes(g, 24 + sway, head_cy - 1, 6, p.eyes, c, radius=3)
    # Sotto la visiera, non dentro: una riga scura su fondo scuro non si vede.
    draw_mouth(g, 24 + sway, head_cy + head_h - 2, p.mouth, c)

    draw_think(g, 36, head_cy - head_h + 2, p.think, c)
    draw_zzz(g, 34, head_cy - head_h - 3, p.zzz)
    return g


def paint_bulldog(p, c):
    """Un bulldog francese grigio scuro.

    Quello che lo rende riconoscibile, in ordine di importanza: le **orecchie a
    pipistrello** — grandi, dritte, ovali, alte quasi quanto la testa — il muso
    schiacciato con le guance che sporgono ai lati e il nasone nero largo, e le
    pieghe sulla fronte. Il collare è il quarto indizio: da solo non farebbe un
    cane, ma insieme agli altri toglie ogni dubbio.

    Il primo tentativo aveva orecchie piccole e appuntite e il corpo nascosto
    dietro la testa: sembrava un topo grigio.
    """
    g = blank()
    base = 33 + p.lift + p.squash
    sway = p.sway

    # Testa più larga che alta: è la proporzione che distingue un bulldog da un
    # coniglio, insieme alla forma delle orecchie.
    head_cy = base - 8 - p.squash // 2
    head_rx = 14
    head_ry = 10 - p.squash // 2 + p.stretch // 2

    body_cy = base + 5 - p.squash
    body_rx = 12 + p.squash - p.stretch // 2
    body_ry = 7 - p.squash // 2 + p.stretch

    # --- dietro a tutto: codino e zampe
    rect(g, 24 + sway + body_rx - 1, body_cy - 2, 4, 3, c["line"])
    rect(g, 24 + sway + body_rx - 1, body_cy - 2, 3, 2, c["dark"])

    for side in (-1, 1):
        fx = 24 + side * 7 + sway
        outline_rounded(g, fx, body_cy + body_ry, 5, 2, c["body"], c["line"], cut=1)
        # Le dita: due tacche chiare sulla zampa.
        put(g, fx - 1, body_cy + body_ry + 1, c["dark"])
        put(g, fx + 1, body_cy + body_ry + 1, c["dark"])

    # --- corpo tozzo, con la pettorina chiara
    outline_ellipse(g, 24 + sway, body_cy, body_rx, body_ry, c["body"], c["line"])
    ellipse(g, 24 + sway, body_cy + 2, 5, body_ry - 2, c["chest"])

    # Zampe anteriori in aria quando festeggia.
    if p.arms in ("up", "wave"):
        for side in (-1, 1):
            ax = 24 + side * (body_rx - 1) + sway
            ay = body_cy - 6 if (p.arms == "wave" and side == 1) else body_cy - 4
            outline_rounded(g, ax, ay, 2, 4, c["body"], c["line"], cut=1)

    # --- orecchie a pipistrello, prima della testa così la base ci sparisce dentro
    #
    # Larghe alla base, arrotondate in cima e inclinate in fuori. Al primo
    # tentativo erano l'esatto contrario — larghe sopra e a punta sotto — e
    # sembravano due alette appoggiate sulla testa invece che due orecchie che
    # ci nascono.
    for side in (-1, 1):
        ear(
            g,
            base_cx=24 + sway + side * 9,
            base_y=head_cy - 4,
            half_w=5.4,
            height=13,
            tilt=side * 1.6 + p.ears * side,
            c=c,
        )

    # --- testa
    outline_ellipse(g, 24 + sway, head_cy, head_rx, head_ry, c["body"], c["line"])
    # Fronte più chiara e riga verticale in mezzo: il muso di un Frenchie è
    # diviso così.
    ellipse(g, 24 + sway, head_cy - 5, 9, 3, c["light"])
    rect(g, 24 + sway + 0.25, head_cy - 8, 0.5, 5, c["dark"])
    # Le pieghe sopra gli occhi.
    for side in (-1, 1):
        rect(g, 24 + sway + side * 7 - 1.5, head_cy - 5, 3, 0.5, c["dark"])
        rect(g, 24 + sway + side * 6 - 1.5, head_cy - 6.75, 3, 0.5, c["dark"])

    # Occhi più piccoli che negli altri due: due tondi bianchi grandi su un
    # muso scuro sono la faccia di un cartone, non di un cane.
    draw_eyes(g, 24 + sway, head_cy - 1, 8, p.eyes, c, radius=3)

    # --- muso: le guance che sporgono ai lati, il muso in mezzo
    # Il muso occupa quasi tutta la metà bassa della faccia: schiacciato, sì, ma
    # grande. Piccolo com'era prima si perdeva dietro al naso.
    # Il muso: schiacciato e largo, ma **grigio chiaro e non bianco**. Bianco
    # com'era prima faceva un panda — la faccia era metà scura e metà chiarissima,
    # e l'occhio legge quella divisione prima di qualunque altra cosa.
    muzzle_cy = head_cy + 4
    for side in (-1, 1):
        outline_ellipse(g, 24 + sway + side * 6, muzzle_cy + 1, 6, 4, c["muzzle"], c["line"])
    ellipse(g, 24 + sway, muzzle_cy, 8, 4, c["muzzle"])
    ellipse(g, 24 + sway, muzzle_cy + 2, 6, 2, c["muzzle_shade"])

    # Nasone nero, largo e schiacciato, con narici e solco: è il pezzo che dice
    # «bulldog» più di ogni altro dopo le orecchie, quindi è grande.
    outline_ellipse(g, 24 + sway, muzzle_cy - 2, 4, 2, c["nose"], c["line"])
    put(g, 24 + sway - 2, muzzle_cy - 2, c["dark"])
    put(g, 24 + sway + 2, muzzle_cy - 2, c["dark"])
    rect(g, 24 + sway, muzzle_cy + 1, 1, 2, c["line"])

    # Bocca: a riposo le due pieghe all'ingiù, aperta la lingua di fuori.
    if p.mouth == "open":
        outline_ellipse(g, 24 + sway, muzzle_cy + 3, 3, 2, c["mouth"], c["line"])
        rect(g, 24 + sway - 1, muzzle_cy + 4, 3, 1, c["tongue"])
    else:
        for side in (-1, 1):
            put(g, 24 + sway + side * 2, muzzle_cy + 3, c["line"])
            put(g, 24 + sway + side * 3, muzzle_cy + 2, c["line"])
        # I due dentini che spuntano: il morso storto è la firma della razza, e
        # costa due pixel.
        if p.eyes != "closed":
            put(g, 24 + sway - 1, muzzle_cy + 4, c["chest"])
            put(g, 24 + sway + 1, muzzle_cy + 4, c["chest"])

    # --- collare, sotto la testa e davanti al corpo
    collar_y = head_cy + head_ry + 1
    rect(g, 24 + sway - 8, collar_y, 17, 3, c["collar"])
    rect(g, 24 + sway - 8, collar_y, 17, 1, c["collar_dark"])
    outline_ellipse(g, 24 + sway, collar_y + 3, 2, 2, c["accent"], c["line"])

    draw_think(g, 37, head_cy - 6, p.think, c)
    draw_zzz(g, 36, head_cy - head_ry - 8, p.zzz)
    return g


CHARACTERS = [
    {
        "id": "bolla", "name": "Bolla", "paint": paint_bolla,
        "palette": {
            "line": (30, 30, 46, 255),
            "body": (92, 200, 190, 255),
            "dark": (52, 150, 148, 255),
            "shine": (206, 248, 244, 255),
            "accent": (250, 196, 92, 255),
            "blush": (246, 138, 122, 255),
            "mouth": (196, 96, 108, 255),
            "eye": (252, 252, 254, 255),
            "pupil": (28, 24, 40, 255),
        },
    },
    {
        "id": "chip", "name": "Chip", "paint": paint_chip,
        "palette": {
            "line": (26, 26, 44, 255),
            "body": (142, 152, 238, 255),
            "dark": (92, 100, 190, 255),
            "visor": (48, 52, 104, 255),
            "shine": (212, 218, 255, 255),
            "accent": (118, 232, 196, 255),
            "blush": (142, 152, 238, 255),
            "mouth": (36, 38, 72, 255),
            "eye": (216, 250, 244, 255),
            "pupil": (24, 26, 48, 255),
        },
    },
    {
        "id": "gigi", "name": "Gigi", "paint": paint_bulldog,
        "palette": {
            "line": (24, 24, 30, 255),
            "body": (86, 90, 98, 255),      # grigio scuro
            "dark": (58, 62, 70, 255),
            "light": (110, 114, 124, 255),
            "chest": (206, 204, 200, 255),  # muso e pettorina chiari
            "ear_in": (156, 122, 122, 255),
            "muzzle": (152, 150, 148, 255),
            "muzzle_shade": (126, 124, 124, 255),
            "collar": (178, 58, 62, 255),
            "collar_dark": (128, 38, 44, 255),
            "nose": (34, 32, 38, 255),
            "shine": (228, 226, 222, 255),
            "accent": (246, 200, 120, 255),
            "blush": (196, 140, 134, 255),
            "mouth": (120, 60, 66, 255),
            "tongue": (226, 126, 138, 255),
            "eye": (250, 250, 250, 255),
            "pupil": (22, 20, 26, 255),
        },
    },
]


# --------------------------------------------------------------------------
# Scrittura

def write_png(path, width, height, rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(v for pixel in row for v in pixel) for row in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# Quanto va veloce ogni animazione. «Al lavoro» è lenta: sta pensando, e il
# pensiero non ha bisogno di dodici fotogrammi al secondo per farsi capire.
FPS = {
    "idle": {"fps": 5, "loop": True},
    "working": {"fps": 3, "loop": True},
    "notify": {"fps": 12, "loop": False, "next": "idle"},
    "dragging": {"fps": 6, "loop": True},
    "dropped": {"fps": 10, "loop": False, "next": "idle"},
    "sleeping": {"fps": 2, "loop": True},
}


def build(character):
    palette = character["palette"]
    paint = character["paint"]

    frames = [paint(pose, palette) for _, poses in SCENES for pose in poses]
    rows_of_cells = (len(frames) + COLUMNS - 1) // COLUMNS
    width = COLUMNS * FRAME
    height = rows_of_cells * FRAME

    canvas = [[TRANSPARENT] * width for _ in range(height)]
    for index, grid in enumerate(frames):
        ox = (index % COLUMNS) * FRAME
        oy = (index // COLUMNS) * FRAME
        for y in range(CELL_PX):
            row = grid[y]
            for x in range(CELL_PX):
                color = row[x]
                if color[3] == 0:
                    continue
                canvas[oy + y][ox + x] = color

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    folder = os.path.join(here, "Resources", "Mascots", character["id"])
    os.makedirs(folder, exist_ok=True)
    write_png(os.path.join(folder, "sprites.png"), width, height, canvas)

    # Il manifest è generato insieme ai disegni perché gli indici dipendono
    # dall'ordine in cui il foglio è stato riempito: scriverli a mano è il modo
    # più semplice di farli scivolare di uno.
    states, start = {}, 0
    for name, poses in SCENES:
        end = start + len(poses) - 1
        states[name] = {"frames": f"{start}-{end}", **FPS[name]}
        start = end + 1

    manifest = {
        "schema": 1,
        "id": character["id"],
        "name": character["name"],
        "author": "Claude Live",
        # In **punti**, non in pixel: il foglio è più fitto di così, e dichiarare
        # le colonne è ciò che permette all'app di capirlo. Vedi
        # `MascotSprites.sliceSheet`.
        "frameWidth": POINT_SIZE,
        "frameHeight": POINT_SIZE,
        "fps": 6,
        "sheet": "sprites.png",
        "columns": COLUMNS,
        "states": states,
    }
    with open(os.path.join(folder, "mascot.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(
        f"{character['name']}: {len(frames)} frame in {width}×{height} px "
        f"({POINT_SIZE}pt l'uno) → {folder}"
    )


def main():
    for character in CHARACTERS:
        build(character)


if __name__ == "__main__":
    main()
