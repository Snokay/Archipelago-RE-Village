"""
Fabrique le modèle 3D Archipelago de RE Village à partir d'un FBX et de sa texture de couleur.

Usage : python tools/re_engine/make_ap_model.py MODELE.fbx TEXTURE.png [MATERIAU]
  (MATERIAU : nom d'un matériau du .mdf2 du flacon donneur, Cap_Mat par défaut ; tout le modèle
   l'utilise)

Étapes (2026-09-26) :
  1. extrait du pak le .mesh, le .mdf2 et les textures du flacon (ri1020,
     it04_000_AntisepticSolution_Medium), qui sert de donneur ;
  2. Blender portable (tools/blender, addon RE Mesh Editor) convertit le FBX en .mesh RE8, à la
     taille du flacon (tools/re_engine/blender_make_ap_mesh.py) ;
  3. écrit les textures (ALBM = la texture fournie) en BC7/BC1 comme celles du flacon
     (tools/re_engine/tex_writer.py) ;
  4. copie le .mdf2 du donneur en remplaçant les chemins des textures par ceux du modèle
     Archipelago, de MÊME LONGUEUR (rien ne se décale dans le fichier).
Sortie dans client/natives/stm/... (installée par tools/install.py, en loose ET dans le pak de
patch). Le porteur Archipelago garde le prefab du Remède (ri1020) : le client remplace à la volée
le maillage et le matériau de l'objet affiché dans la boutique (shop_ui.update_preview). Un prefab
à part (ri9990) faisait échouer la création de l'objet (2026-09-26) : abandonné.
"""

import os
import struct
import subprocess
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import pak_extract  # noqa: E402
import tex_writer  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(ROOT, "tools", "re_engine", "extrait")
CLIENT = os.path.join(ROOT, "client")
BLENDER = os.path.join(ROOT, "tools", "blender", "blender-4.3.2-windows-x64", "blender.exe")

DONOR_DIR = "natives/stm/character/it/it04/000/"
DONOR_STEM = "it04_000_antisepticsolution_medium"
DONOR_REF = "Character/It/it04/000/it04_000_AntisepticSolution_Medium"   # chemins internes
AP_DIR = "natives/stm/character/it/it99/000/"
AP_STEM = "it99_000_archipelagologo_model0000"
AP_REF = "Character/It/it99/000/it99_000_ArchipelagoLogo_Model0000"      # même longueur
MESH_EXT, MDF_EXT, TEX_EXT = ".mesh.2101050001", ".mdf2.19", ".tex.30"
TEXTURES = ("_a_albm", "_a_nrmr", "_a_atos")        # fichiers (minuscules)
TEXTURE_REFS = ("_A_ALBM", "_A_NRMR", "_A_ATOS")    # chemins internes


def local(path, base):
    return os.path.join(base, path.replace("/", os.sep))


def replace_refs(data, pairs):
    for old, new in pairs:
        assert len(old) == len(new), (old, new)
        data = data.replace(old.encode("utf-16-le"), new.encode("utf-16-le"))
    return data


def main(fbx, texture_png, material="Cap_Mat"):
    assert len(DONOR_REF) == len(AP_REF)
    donor_files = [DONOR_DIR + DONOR_STEM + MESH_EXT, DONOR_DIR + DONOR_STEM + MDF_EXT]
    donor_files += [DONOR_DIR + DONOR_STEM + t + TEX_EXT for t in TEXTURES]
    pak_extract.extract(donor_files, WORK)

    # 1. Maillage.
    out_mesh = local(AP_DIR + AP_STEM + MESH_EXT, CLIENT)
    os.makedirs(os.path.dirname(out_mesh), exist_ok=True)
    subprocess.run([BLENDER, "--background", "--python",
                    os.path.join(os.path.dirname(__file__), "blender_make_ap_mesh.py"), "--",
                    fbx, local(DONOR_DIR + DONOR_STEM + MESH_EXT, WORK), out_mesh, material], check=True)
    if not os.path.exists(out_mesh):
        sys.exit("export du .mesh raté (voir la sortie de Blender)")

    # 2. Textures : couleur fournie (alpha = métal, 10 comme le flacon : à 0, l'encodeur BC7
    #    mettait la couleur à noir) ; relief plat ; opaque, sans translucidité, occlusion blanche.
    #    Test en jeu du 2026-09-26 : non compressées, le matériau affichait le damier "texture
    #    manquante". On reproduit donc exactement les textures du flacon (tex_writer.write_bc_tex) :
    #    version de base (512, 7 mips) ET version streaming (2048, 9 mips), BC7 / BC1, leurs en-têtes.
    color = Image.open(texture_png).convert("RGBA")
    color.putalpha(10)
    images = {"_a_albm": color,
              "_a_nrmr": Image.new("RGBA", color.size, (128, 128, 255, 200)),
              "_a_atos": Image.new("RGBA", color.size, (255, 0, 255, 255))}
    for sub in ("", "streaming/"):
        donor_dir = DONOR_DIR.replace("natives/stm/", "natives/stm/" + sub)
        ap_dir = AP_DIR.replace("natives/stm/", "natives/stm/" + sub)
        pak_extract.extract([donor_dir + DONOR_STEM + t + TEX_EXT for t in TEXTURES], WORK)
        for suffix, image in images.items():
            template = open(local(donor_dir + DONOR_STEM + suffix + TEX_EXT, WORK), "rb").read()
            out = local(ap_dir + AP_STEM + suffix + TEX_EXT, CLIENT)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            print(f"texture {sub or 'base'} {suffix} : {tex_writer.write_bc_tex(out, image, template)}")

    # 3. Matériau : chemins de textures remplacés.
    refs = [(DONOR_REF + t + ".tex", AP_REF + t + ".tex") for t in TEXTURE_REFS]
    mdf = open(local(DONOR_DIR + DONOR_STEM + MDF_EXT, WORK), "rb").read()
    out_mdf = local(AP_DIR + AP_STEM + MDF_EXT, CLIENT)
    mdf = bytearray(replace_refs(mdf, refs))
    # (Le maillage greffé garde les 7 morceaux du flacon dans l'ordre : le .mdf2 garde aussi le sien.)
    with open(out_mdf, "wb") as f:
        f.write(bytes(mdf))
    print(f"matériau -> {out_mdf}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "Cap_Mat")
