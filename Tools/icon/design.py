#!/usr/bin/env python3
"""The app icon artwork used by make.py.

The layered icon and flat website mark share the same geometry. Each icon layer
has its own vertical gradient; the flat SVG paints the same stops directly.
The lanes are clipped to the panel before its spur is added. The spur follows
the bar's curve and extends 17 units above and below it, keeping the pale bar
visible where it crosses the light outer margin.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import icon_geometry  # noqa: E402
import lib  # noqa: E402
import icon_canvas  # noqa: E402
from icon_geometry import (BAND_X1, CY, END, H, HS, M, YA, YB, band_in, into, kof,  # noqa: E402
                   squircle_panel)
from lib import sh_group  # noqa: E402
from icon_canvas import clipped, fullbleed, sh_squircle, sheen, wrap_flat, wrap_layer  # noqa: E402

# How far the spur is proud of the bar, above and below, in the panel's own
# units, and where its band ends. The end point is the bar's own and must stay
# the bar's own: see the docstring.
SPUR_UP = 17.0
SPUR_DOWN = 17.0
SPUR_X1 = BAND_X1

# The grade, as a fraction of each colour's own value. Up at the piece's top,
# down at its bottom.
UP = 0.14
DOWN = 0.11


# ----------------------------------------------------------- colour, twice
#
# Every stop has to be sayable as an icon.json fill and as an SVG gradient, and
# both come from lib.shade, so the two outputs cannot drift by getting a number
# slightly wrong in one of them.
def tone(colour, t):
    """The palette colour nudged toward white (t > 0) or black (t < 0).

    NOT a palette change. Every gradient here is centred on the colour it
    grades, so a piece's average tone is the entry it started as.
    """
    return lib.shade(colour, t)


def key(colour, t=0.0, a=1.0):
    """One stop of an icon.json fill: `srgb:r,g,b,a`, components 0 to 1.

    The part before the colon names the space. Anything the document does not
    recognise compiles to a nil CGColor and actool dies inside CoreFoundation
    without saying why, so this encoding is not a preference.
    """
    r, g, b = lib._hex(tone(colour, t))
    return "srgb:%.4f,%.4f,%.4f,%.3f" % (r / 255.0, g / 255.0, b / 255.0, a)


def fill(colour, up, down, y0=None, y1=None, a=1.0, b=None):
    """A layer's fill key: a two stop vertical gradient, lighter at the top.

    y0 and y1 are canvas coordinates, converted here to the 0 to 1 the document
    wants. Left out, the ramp runs the whole canvas, which is the document's
    default. Given a piece's own top and bottom it is confined to that piece,
    and that is the whole of `02-piece`.
    """
    g = {"linear-gradient": [key(colour, up, a),
                             key(colour, -down, b if b is not None else a)]}
    if y0 is not None:
        g["orientation"] = {"start": {"x": 0.5, "y": y0 / 1024.0},
                            "stop": {"x": 0.5, "y": y1 / 1024.0}}
    return g


def paint(colour, up, down, y0, y1, a=1.0, b=None):
    """The same gradient as an SVG paint, for the flat `.icns`.

    userSpaceOnUse and canvas coordinates, so the same two numbers describe the
    ramp in both outputs.
    """
    fid = "vg%d" % len(lib._defs)
    lib._defs.append(
        '<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="512" y1="%.1f" '
        'x2="512" y2="%.1f"><stop offset="0" stop-color="%s" stop-opacity="%.3f"/>'
        '<stop offset="1" stop-color="%s" stop-opacity="%.3f"/></linearGradient>'
        % (fid, y0, y1, tone(colour, up), a, tone(colour, -down),
           b if b is not None else a))
    return "url(#%s)" % fid


# --------------------------------------------------------------- the shapes
def shapes(small=False, m=M):
    """`tongue` in pieces, with the spur stated rather than assumed.

    `plain` and `panel` are two different windows on purpose. `panel` is what
    is PAINTED Deep, plain plus the spur. `plain` is what the lanes are CUT to,
    and keeping them apart is the whole of the leaving edge correction.
    """
    h = HS if small else H
    barh = h * 1.04
    plain = squircle_panel(m)
    # Symmetric today, so the shift is zero. It is written out because the two
    # sides are separate numbers and an asymmetric spur has to move the band's
    # centre line rather than only its height.
    shift = (SPUR_DOWN - SPUR_UP) / 2.0
    spur = band_in(CY - 40 + shift, END + shift, barh + SPUR_UP + SPUR_DOWN, m,
                   x1=SPUR_X1)
    panel = sh_group(plain, spur)
    a = band_in(YA, END - h * 1.02, h * 0.92, m)
    b = band_in(YB + 26, END + h * 1.02, h * 0.92, m)
    c = band_in(CY - 40, END, barh, m)
    return dict(h=h, m=m, plain=plain, spur=spur, panel=panel, a=a, b=b, c=c,
                tile=sh_squircle(), bar=lib.sh_clip(c, panel))


# ------------------------------------------------------- where a piece lives
#
# A ramp confined to a piece needs that piece's top and bottom on the canvas,
# and a number typed in here by hand would go stale the first time the margin
# moved. Every band is a cubic whose control points sit at its own two end
# heights, so the curve never leaves the strip between them and the extent is
# exact rather than sampled.
def extent(y0, y1, h, m=M):
    half = h / 2.0
    return into(min(y0, y1) - half, m), into(max(y0, y1) + half, m)


def where(small=False, m=M):
    """Top and bottom, on the canvas, of every piece that carries a ramp."""
    h = HS if small else H
    lanes = (extent(YA, END - h * 1.02, h * 0.92, m),
             extent(YB + 26, END + h * 1.02, h * 0.92, m))
    return dict(
        ground=(0.0, 1024.0),
        panel=(m, 1024.0 - m),
        bar=extent(CY - 40, END, h * 1.04, m),
        # A lane is cut at the panel, so what is lit is the part inside it.
        a=(max(m, lanes[0][0]), min(1024.0 - m, lanes[0][1])),
        b=(max(m, lanes[1][0]), min(1024.0 - m, lanes[1][1])))


# ------------------------------------------------------------- the document
GROUNDKEYS = {}
BLEEDKEYS = icon_geometry.BLEEDKEYS
PANELKEYS = icon_geometry.PANELKEYS
MARKKEYS = icon_geometry.MARKKEYS


def groups(small=False):
    """The four groups, back to front, each a list of layers.

    A layer is a dict the way icon.json wants one: a silhouette and a fill.
    Bleed carries two because it carries two colours.
    """
    sp, w = shapes(small), where(small)
    p = sp["plain"]
    return [
        ("Mark", [{"name": "Mark", "body": sp["bar"]("#000"),
                   "fill": fill("shallow", UP, DOWN, *w["bar"])}], MARKKEYS),
        ("Bleed", [{"name": "Current",
                    "body": clipped(sp["b"](sheen("current")), p),
                    "fill": fill("current", UP, DOWN, *w["b"])},
                   {"name": "Spatie",
                    "body": clipped(sp["a"](sheen("spatie")), p),
                    "fill": fill("spatie", UP, DOWN, *w["a"])}], BLEEDKEYS),
        ("Panel", [{"name": "Panel", "body": sp["panel"]("#000"),
                    "fill": fill("deep", UP, DOWN, *w["panel"])}], PANELKEYS),
        ("Ground", [{"name": "Ground", "body": fullbleed("#000"),
                     "fill": fill("foam", UP, DOWN, *w["ground"])}], GROUNDKEYS),
    ]


# ------------------------------------------------------------- the flat body
def body(small=False):
    """icon_geometry.figure's own composite for `tongue`, graded, with the contact
    shadows the flat file needs and the layered one must not have.

    The order is the order it is painted in: ground, the panel seated on the
    margin, the panel, the lanes cut at the plain panel, the bar seated on each
    lane and on the panel, the bar. The layered icon omits these contact shadows because the system supplies them.

    TWO THINGS icon_geometry.figure DRAWS HERE AND THIS DOES NOT, and both are the same
    argument. `outside(side(c), p)` lays a Current thickness under the bar
    wherever the bar is on the margin without one, and
    `outside(contact(c, tile), p)` drops the bar's own shadow onto the Foam.
    Neither has a job left. The spur is what the bar lies in now, so the face
    on the margin already has a step against the ground, and the panel's own
    seat shadow already seats the spur. Drawn anyway, the side puts about 14
    canvas units of Current below the spur, which is the dark the trim was
    asked to take away, only on the other side.
    """
    sp, w = shapes(small), where(small)
    S = icon_canvas.S
    p, plain, c = sp["panel"], sp["plain"], sp["bar"]
    lanes = (sp["a"](paint("spatie", UP, DOWN, *w["a"]))
             + sp["b"](paint("current", UP, DOWN, *w["b"])))
    return "".join([
        fullbleed(paint("foam", UP, DOWN, *w["ground"])),
        icon_canvas.contact(p, sp["tile"], d=(0, 16 * S), blur=20 * S, alpha=0.22),
        p(paint("deep", UP, DOWN, *w["panel"])),
        clipped(lanes, plain),
        icon_canvas.contact(c, sp["a"], d=(0, 26 * S), blur=13 * S, alpha=0.34),
        icon_canvas.contact(c, sp["b"], d=(0, -26 * S), blur=13 * S, alpha=0.34),
        icon_canvas.contact(c, p, d=(0, 26 * S), blur=15 * S, alpha=0.30),
        c(paint("shallow", UP, DOWN, *w["bar"])),
    ])


def render(small=False):
    """The groups and the full bleed composite.

    The app ships a layered icon, so this returns only its groups and the flat
    composite used for the website.

    The two halves are built against separate def tables on purpose. Every
    wrapper embeds the whole of `lib.defs()`, so building the flat body first
    would put its gradients into every layer file as dead weight.
    """
    lib.SMALL = small
    lib.reset()
    gs = [(name, [dict(l, body=wrap_layer(l["body"])) for l in layers], keys)
          for name, layers, keys in groups(small)]
    lib.reset()
    b = body(small)
    return gs, wrap_flat(b)
