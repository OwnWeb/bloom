#!/usr/bin/env python3
"""Generate the app icon and menu bar mark from the current artwork.

Run `python3 Tools/icon/make.py` from the repository root. The script writes
`Resources/Bloom.icon` for macOS 26 and `Resources/BloomMenuBar.pdf`.
The layered icon lets macOS supply its own lighting; the flat artwork is kept
for the website mark. The menu bar mark is redrawn for its smaller size.
"""

import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(ROOT, "Resources")

sys.path.insert(0, HERE)
import design  # noqa: E402
import menubar  # noqa: E402

def layered():
    """The four groups the system composites, back to front: the Foam ground,
    the Deep panel with its spur, the two arriving lanes cut at the plain
    panel, and the bar. Written with the app's own contact shadows left out,
    because the system seats the layers itself.

    A GROUP IS NOT A LAYER. Bleed holds two, one per lane, because each carries
    its own gradient and one fill key cannot say Spatie and Current at once.
    Anything that walks this list has to walk the layers inside a group rather
    than assume one each.

    The Assets directory is emptied first. A layer that stops being drawn would
    otherwise stay on disk and go on being compiled into the catalogue.
    """
    built, _ = design.render()
    bundle = os.path.join(RESOURCES, "Bloom.icon")
    assets = os.path.join(bundle, "Assets")
    shutil.rmtree(assets, ignore_errors=True)
    os.makedirs(assets)

    groups = []
    for _, layers, keys in built:
        group = {"layers": []}
        for layer in layers:
            asset = layer["name"].lower() + ".svg"
            with open(os.path.join(assets, asset), "w") as f:
                f.write(layer["body"])
            item = {"image-name": asset, "name": layer["name"]}
            # A layer's fill REPLACES the artwork's own colours, so the SVG
            # under it is a silhouette. Anything the document cannot parse
            # compiles to a nil CGColor and actool dies inside CoreFoundation
            # without saying which layer it was.
            for k in ("fill", "opacity", "blend-mode", "specular"):
                if k in layer:
                    item[k] = layer[k]
            group["layers"].append(item)
        group.update(keys)
        groups.append(group)

    with open(os.path.join(bundle, "icon.json"), "w") as f:
        json.dump({"fill": "automatic", "groups": groups}, f, indent=1)
    return bundle


if __name__ == "__main__":
    print("==>", layered())
    print("==>", menubar.asset())
