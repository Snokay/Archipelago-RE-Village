"""
Remplace le logo de l'écran titre de RE Village par celui du mod (2026-10-07, image du joueur).

Usage : python tools/re_engine/make_title_logo.py [LOGO.png] [--apercu] [--couleur=jeu|or|rouge]
  (jeu par défaut : couleur du « resident evil » officiel)
  (par défaut Assets/titre/logo_re_village_archipelago.png ; --apercu n'écrit que les images
   d'aperçu dans tools/re_engine/extrait/titre/)

Relevés du 2026-10-07 :
  - gui/prefab/guititle.pfb.17 -> GUI/ui1000/gui/ui1000.gui (éléments t_logo, c_logo, title...) ;
  - ui1000_00_iam.tex.30 : 1024 x 512, format 99 (BC7 sRGB), 1 mip ;
  - ui1000_00.uvs.7 : 14 cases de 32 octets à partir de 0x68 ; gauche, haut, droite, bas (0 à 1)
    aux octets 8 à 23. Contenu (pixels) :
      0 (0,0)-(500,150)     VILLAGE métal (grand)     1 et 11 vides
      2 (0,150)-(440,240)   VILLAGE métal             3 (440,150)-(880,240) VILLAGE blanc (flash)
      4 / 5 biohazard métal / blanc (Japon)           6 / 7 resident evil métal / blanc
      8 VIII     9 « LLAGE » (animation)    10 traînées blanches    12, 13 trait et son ombre
Le logo du joueur a deux lignes : « RE Village » -> cases de VILLAGE, « Archipelago By
Snokayy » -> cases de resident evil ET de biohazard (selon la région du jeu). VIII et LLAGE
(morceaux de l'ancien mot) sont vidés. Versions blanches = mêmes lettres en blanc (flash de
l'animation). Écrit NON compressé (format 29, RGBA8 sRGB), comme make_ap_icon.py.
Sortie : client/natives/stm/gui/ui1000/tex/ui1000_00_iam.tex.30 (mis dans le pak par install.py).
"""

import os
import struct
import sys
from collections import deque

import numpy as np
import texture2ddecoder
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import pak_extract  # noqa: E402

# Toujours repartir de la texture du jeu, pas de celle déjà remplacée dans notre pak (comme
# make_ap_sound.py).
MOD_PAK = "re_chunk_000.pak.patch_014.pak"
_pak_files = pak_extract.pak_files
pak_extract.pak_files = lambda *a, **k: [p for p in _pak_files(*a, **k) if not p.endswith(MOD_PAK)]

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEX_PATH = "natives/stm/gui/ui1000/tex/ui1000_00_iam.tex.30"
UVS_PATH = "natives/stm/gui/ui1000/tex/ui1000_00.uvs.7"
WORK = os.path.join(ROOT, "tools", "re_engine", "extrait")
PREVIEW = os.path.join(WORK, "titre")
OUT = os.path.join(ROOT, "client", TEX_PATH.replace("/", os.sep))
DEFAULT_LOGO = os.path.join(ROOT, "Assets", "titre", "logo_re_village_archipelago.png")
FORMAT_RGBA8_SRGB = 29

# Choix du joueur (2026-10-07, 2e version) : logo officiel gardé (VILLAGE, VIII, LLAGE, animation) ;
# seul « resident evil » (et « biohazard », version japonaise) devient « Archipelago By Snokayy »,
# dans la couleur du « resident evil » d'origine. La ligne « RE Village » de l'image n'est plus
# utilisée (TITLE_CELLS vide).
TITLE_CELLS = {}
SUBTITLE_CELLS = {4: "metal", 5: "white", 6: "metal", 7: "white"}
EMPTY_CELLS = ()
GAME_COLOR_CELL = 6  # « resident evil » métal d'origine : sa couleur moyenne teinte le sous-titre


def cell_rect(uvs, index, width, height):
    left, top, right, bottom = struct.unpack_from("<ffff", uvs, 0x68 + index * 32 + 8)
    return (round(left * width), round(top * height), round(right * width), round(bottom * height))


def split_lines(logo):
    """Deux lignes du logo : zones de pixels reliés (la boucle du g de « Village » descend dans
    la 2e ligne, pas de coupe droite possible). Une zone qui commence dans le 1er tiers du dessin
    est à la 1re ligne."""
    alpha = np.array(logo)[:, :, 3]
    mask = alpha > 8
    h, w = mask.shape
    ys = np.nonzero(mask.any(axis=1))[0]
    limit = ys[0] + (ys[-1] - ys[0]) * 0.55
    top_line = np.zeros((h, w), bool)
    seen = np.zeros((h, w), bool)
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]:
            continue
        seen[y0, x0] = True
        queue, pixels = deque([(y0, x0)]), []
        while queue:
            y, x = queue.popleft()
            pixels.append((y, x))
            for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True
                    queue.append((yy, xx))
        if y0 < limit:  # y0 = plus haut pixel de la zone (parcours ligne par ligne)
            for y, x in pixels:
                top_line[y, x] = True
    rgba = np.array(logo)
    rgba[~mask, 3] = 0  # pixels presque invisibles : agrandissaient le cadre (sous-titre minuscule)
    first, second = rgba.copy(), rgba.copy()
    first[~top_line, 3] = 0
    second[top_line, 3] = 0
    images = [Image.fromarray(first), Image.fromarray(second)]
    return [im.crop(im.getbbox()) for im in images]


def whiten(image):
    """Version blanche (flash) : lettres blanches, ombre sombre retirée."""
    rgba = np.array(image).astype(np.float32)
    luma = rgba[:, :, :3].mean(axis=2)
    out = np.zeros_like(rgba)
    out[:, :, :3] = 255
    out[:, :, 3] = rgba[:, :, 3] * np.clip((luma - 40) / 60, 0, 1)
    return Image.fromarray(out.astype(np.uint8))


# Couleur du sous-titre (2026-10-07, demande du joueur : le distinguer de « RE Village ») :
# lumière du métal teintée. None = métal d'origine.
SUBTITLE_TINTS = {"or": (255, 196, 90), "rouge": (220, 40, 30)}


def tint(image, color, gain=1.35):
    rgba = np.array(image).astype(np.float32)
    luma = rgba[:, :, :3].mean(axis=2, keepdims=True) / 255
    rgba[:, :, :3] = np.clip(luma * gain * np.array(color, np.float32), 0, 255)
    return Image.fromarray(rgba.astype(np.uint8))


def match_color(image, reference):
    """Teinte et luminosité moyennes des lettres de `reference` (case du jeu) appliquées à
    `image` : même couleur que le texte officiel."""
    ref = np.array(reference).astype(np.float32)
    src = np.array(image).astype(np.float32)
    ref_on, src_on = ref[:, :, 3] > 128, src[:, :, 3] > 128
    ref_mean = ref[ref_on][:, :3].mean(axis=0)
    src_luma = src[src_on][:, :3].mean() / 255
    return tint(image, ref_mean / max(ref_mean.max(), 1) * 255, gain=ref_mean.max() / 255 / src_luma)


def fit(image, w, h, margin=0.94):
    image = image.copy()
    image.thumbnail((int(w * margin), int(h * margin)), Image.LANCZOS)
    cell = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cell.alpha_composite(image, ((w - image.width) // 2, (h - image.height) // 2))
    return cell


def main(logo_path, preview_only, color=None):
    pak_extract.extract([TEX_PATH, UVS_PATH], WORK)
    tex = open(os.path.join(WORK, TEX_PATH.replace("/", os.sep)), "rb").read()
    uvs = open(os.path.join(WORK, UVS_PATH.replace("/", os.sep)), "rb").read()
    width, height = struct.unpack_from("<HH", tex, 8)
    fmt = struct.unpack_from("<I", tex, 16)[0]
    offset, _, size = struct.unpack_from("<QII", tex, 0x28)
    if fmt not in (98, 99):
        raise ValueError(f"format {fmt} inattendu (BC7 attendu)")
    atlas = Image.frombytes("RGBA", (width, height),
                            texture2ddecoder.decode_bc7(tex[offset:offset + size], width, height), "raw", "BGRA")

    title, subtitle = split_lines(Image.open(logo_path).convert("RGBA"))
    if color == "jeu":
        subtitle_metal = match_color(subtitle, atlas.crop(cell_rect(uvs, GAME_COLOR_CELL, width, height)))
    else:
        subtitle_metal = tint(subtitle, SUBTITLE_TINTS[color]) if color else subtitle
    versions = {"metal": (title, subtitle_metal),
                "white": (whiten(title), whiten(subtitle))}
    clear = lambda rect: atlas.paste(Image.new("RGBA", (rect[2] - rect[0], rect[3] - rect[1])), rect[:2])
    for cells, line in ((TITLE_CELLS, 0), (SUBTITLE_CELLS, 1)):
        for cell, kind in cells.items():
            x0, y0, x1, y1 = cell_rect(uvs, cell, width, height)
            clear((x0, y0, x1, y1))
            atlas.alpha_composite(fit(versions[kind][line], x1 - x0, y1 - y0), (x0, y0))
    for cell in EMPTY_CELLS:
        clear(cell_rect(uvs, cell, width, height))

    os.makedirs(PREVIEW, exist_ok=True)
    back = Image.new("RGBA", atlas.size, (40, 40, 40, 255))
    back.alpha_composite(atlas)
    back.save(os.path.join(PREVIEW, "planche.png"))
    # Aperçu de l'écran titre (disposition approximative : titre puis sous-titre)
    x0, y0, x1, y1 = cell_rect(uvs, 2, width, height)
    sx0, sy0, sx1, sy1 = cell_rect(uvs, 6, width, height)
    screen = Image.new("RGBA", (x1 - x0 + 40, (y1 - y0) + (sy1 - sy0) + 30), (12, 12, 12, 255))
    screen.alpha_composite(atlas.crop((x0, y0, x1, y1)), (20, 10))
    screen.alpha_composite(atlas.crop((sx0, sy0, sx1, sy1)), (20, 10 + y1 - y0))
    screen.resize((screen.width * 2, screen.height * 2), Image.LANCZOS).save(os.path.join(PREVIEW, "apercu_titre.png"))
    print(f"aperçus : {PREVIEW}")
    if preview_only:
        return

    data = atlas.tobytes("raw", "RGBA")
    header = bytearray(tex[:offset])
    struct.pack_into("<I", header, 16, FORMAT_RGBA8_SRGB)
    struct.pack_into("<QII", header, 0x28, offset, width * 4, len(data))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(header + data)
    print(f"écrit : {OUT} ({len(header) + len(data)} octets)")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    color = next((a[len("--couleur="):] for a in sys.argv if a.startswith("--couleur=")), "jeu")
    main(args[0] if args else DEFAULT_LOGO, "--apercu" in sys.argv, color)
