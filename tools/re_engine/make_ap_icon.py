"""
Fabrique la planche d'icônes d'objets de RE Village avec le logo Archipelago dans une case.

Usage : python tools/re_engine/make_ap_icon.py LOGO.png [cases]
  (cases "19,20" par défaut : 19 = le premier "?" de ui0100, icône donnée au porteur par le mod ;
   20 = icône d'origine du porteur, encore utilisée par la ligne d'objet affichée à l'écran,
   2026-09-27, qui montrait un flacon)

Sortie : client/natives/stm/gui/ui0100/tex/ui0100_iam.tex.30, à poser dans le dossier du jeu
(REFramework charge les fichiers "loose" du dossier natives). Supprimer le fichier = retour au
jeu d'origine.

Relevés du 2026-09-26 :
  - gui/prefab/guiitemicondata.user.2 -> planches GUI/ui0100/tex/ui0100 à ui0103 (.uvs) ;
  - ui0100_iam.tex.30 : 2048 x 2048, format 99 (BC7 sRGB), 1 mip, données à l'octet 56 ;
  - ui0100.uvs.7 : 491 cases de 32 octets à partir de 0x98 ; gauche, haut, droite, bas
    (0 à 1) aux octets 8 à 23, numéro de texture à 24.
La planche modifiée est écrite NON compressée (format 29, R8G8B8A8 sRGB) pour éviter un
encodeur BC7 : 16 Mo au lieu de 4 Mo.
"""

import os
import struct
import sys

import texture2ddecoder
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import pak_extract  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEX_PATH = "natives/stm/gui/ui0100/tex/ui0100_iam.tex.30"
UVS_PATH = "natives/stm/gui/ui0100/tex/ui0100.uvs.7"
WORK = os.path.join(ROOT, "tools", "re_engine", "extrait")
OUT = os.path.join(ROOT, "client", TEX_PATH.replace("/", os.sep))
FORMAT_RGBA8_SRGB = 29


def cell_rect(uvs, index, width, height):
    left, top, right, bottom, tex = struct.unpack_from("<ffffI", uvs, 0x98 + index * 32 + 8)
    if tex != 0:
        raise ValueError(f"case {index} : texture {tex}, pas ui0100")
    return (round(left * width), round(top * height), round(right * width), round(bottom * height))


def main(logo_path, cells=(19, 20)):
    pak_extract.extract([TEX_PATH, UVS_PATH], WORK)
    tex = open(os.path.join(WORK, TEX_PATH.replace("/", os.sep)), "rb").read()
    uvs = open(os.path.join(WORK, UVS_PATH.replace("/", os.sep)), "rb").read()
    width, height = struct.unpack_from("<HH", tex, 8)
    fmt = struct.unpack_from("<I", tex, 16)[0]
    offset, _, size = struct.unpack_from("<QII", tex, 0x28)
    if fmt in (98, 99):
        pixels = texture2ddecoder.decode_bc7(tex[offset:offset + size], width, height)
        atlas = Image.frombytes("RGBA", (width, height), pixels, "raw", "BGRA")
    elif fmt in (28, 29):
        # Planche déjà modifiée par ce script (notre pak de patch passe avant les paks du jeu).
        atlas = Image.frombytes("RGBA", (width, height), tex[offset:offset + width * height * 4], "raw", "RGBA")
    else:
        raise ValueError(f"format {fmt} inattendu (BC7 ou RGBA8 attendu)")

    for cell in cells:
        x0, y0, x1, y1 = cell_rect(uvs, cell, width, height)
        w, h = x1 - x0, y1 - y0
        logo = Image.open(logo_path).convert("RGBA")
        logo.thumbnail((int(w * 0.92), int(h * 0.92)), Image.LANCZOS)
        cell_img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        cell_img.alpha_composite(logo, ((w - logo.width) // 2, (h - logo.height) // 2))
        atlas.paste(cell_img, (x0, y0))
        print(f"logo collé dans la case {cell} : ({x0}, {y0}) - ({x1}, {y1})")

    data = atlas.tobytes("raw", "RGBA")
    header = bytearray(tex[:offset])
    struct.pack_into("<I", header, 16, FORMAT_RGBA8_SRGB)
    struct.pack_into("<QII", header, 0x28, offset, width * 4, len(data))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(header + data)
    atlas.crop((x0 - 2 * w, y0, x1, y1 + 8)).resize((w * 9, h * 3)).save(os.path.join(WORK, "apercu_case.png"))
    print(f"écrit : {OUT} ({len(header) + len(data)} octets)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1], tuple(int(c) for c in sys.argv[2].split(",")) if len(sys.argv) > 2 else (19, 20))
