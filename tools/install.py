"""
Installe le client dans le jeu et l'apworld dans Archipelago.

Usage : python tools/install.py [--game-dir DOSSIER_DU_JEU] [--archipelago-dir DOSSIER_AP] [--lang fr|en]

- Copie client/* dans le dossier du jeu (lua-apclientpp.dll à côté de re8.exe, reframework/
  fusionné avec celui du jeu). REFramework doit déjà être installé (dinput8.dll).
- Empaquette apworld/residentevilvillage/ en residentevilvillage.apworld dans
  <Archipelago>/custom_worlds/.
"""

import argparse
import os
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GAME_DIR = Path(r"D:\Steam\steamapps\common\Resident Evil Village BIOHAZARD VILLAGE")
DEFAULT_AP_DIR = Path(r"D:\Archipelago")


def check_lua():
    """Refuse d'installer un script Lua qui ne compile pas (tools/check_lua.py)."""
    import subprocess
    result = subprocess.run([sys.executable, str(ROOT / "tools" / "check_lua.py")])
    if result.returncode != 0:
        sys.exit("Installation annulée : erreur Lua (voir ci-dessus).")


def install_client(game_dir):
    if not (game_dir / "re8.exe").exists():
        sys.exit(f"re8.exe introuvable dans {game_dir}")
    if not (game_dir / "dinput8.dll").exists():
        print("ATTENTION : REFramework ne semble pas installé (dinput8.dll absent).")
    client = ROOT / "client"
    for src in client.rglob("*"):
        if src.is_file() and "bridge" not in src.parts:
            dst = game_dir / src.relative_to(client)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists() and dst.read_bytes() == src.read_bytes():
                continue  # identique (et la DLL est verrouillée tant que le jeu tourne)
            try:
                shutil.copy2(src, dst)
                print(f"  {src.relative_to(client)}")
            except PermissionError:
                print(f"  ATTENTION : {src.relative_to(client)} verrouillé : ferme le jeu et relance l'installation")
    # Fichiers d'anciennes versions à supprimer du jeu.
    for obsolete in ["reframework/autorun/AP_REF/core.lua"]:
        path = game_dir / obsolete
        if path.exists():
            path.unlink()
            print(f"  supprimé : {obsolete}")
    enable_loose_files(game_dir)
    install_patch_pak(game_dir)
    # Outils de développement du menu REFramework (cachés dans les versions distribuées).
    dev = game_dir / "reframework" / "data" / "re_village_ap_client" / "dev.json"
    dev.parent.mkdir(parents=True, exist_ok=True)
    dev.write_text("{}", encoding="utf-8")
    print(f"Client installé dans {game_dir}")


PATCH_PAK = "re_chunk_000.pak.patch_014.pak"  # le jeu a ses propres patches 001 à 013


def install_patch_pak(game_dir):
    """Fichiers visuels (modèle, textures, icônes) aussi empaquetés dans un pak de patch : les
    textures des matériaux 3D ne sont pas servies en "loose" par le REFramework de RE8 (damier
    "texture manquante", 2026-09-26). N'écrase jamais un patch_014 qui ne serait pas le nôtre."""
    sys.path.insert(0, str(ROOT / "tools" / "re_engine"))
    import pak_build
    import pak_extract
    marker = "natives/stm/character/it/it99/000/it99_000_archipelagologo_model0000_a_albm.tex.30"
    target = game_dir / PATCH_PAK
    if target.exists() and pak_extract.path_hash(marker) not in pak_extract.read_toc(str(target)):
        print(f"ATTENTION : {PATCH_PAK} existe déjà et n'est pas celui du mod : pas installé")
        return
    built = ROOT / "build" / PATCH_PAK
    built.parent.mkdir(exist_ok=True)
    pak_build.build(str(built), str(ROOT / "client"))
    try:
        shutil.copy2(built, target)
        print(f"  {PATCH_PAK} installé")
    except PermissionError:
        print(f"  ATTENTION : {PATCH_PAK} verrouillé : ferme le jeu et relance l'installation")


def enable_loose_files(game_dir):
    """Icône Archipelago (client/natives/...) : REFramework doit charger les fichiers "loose".
    À faire jeu fermé, sinon REFramework réécrit sa configuration en quittant."""
    config = game_dir / "re2_fw_config.txt"
    if not config.exists():
        print("ATTENTION : re2_fw_config.txt absent : lance le jeu une fois avec REFramework, puis réinstalle")
        return
    text = config.read_text(encoding="utf-8", errors="replace")
    if "LooseFileLoader_Enabled=true" in text:
        return
    if "LooseFileLoader_Enabled=false" in text:
        text = text.replace("LooseFileLoader_Enabled=false", "LooseFileLoader_Enabled=true")
    else:
        text = text.rstrip("\n") + "\nLooseFileLoader_Enabled=true\n"
    config.write_text(text, encoding="utf-8")
    print("  chargeur de fichiers loose de REFramework activé (re2_fw_config.txt)")


def install_apworld(ap_dir, lang="fr"):
    target = ap_dir / "custom_worlds" / "residentevilvillage.apworld"
    install_apworld_to(target, lang)
    print(f"apworld installé : {target}")


def install_apworld_to(target, lang="fr"):
    """apworld dans la langue voulue (2026-10-08) : lang.py réécrit dans le paquet ; pour "en",
    data/names_en.json est d'abord refait (tools/make_names_en.py)."""
    if lang not in ("fr", "en"):
        sys.exit(f"langue inconnue : {lang}")
    if lang == "en":
        sys.path.insert(0, str(ROOT / "tools"))
        import make_names_en
        make_names_en.build()
    target.parent.mkdir(parents=True, exist_ok=True)
    src_root = ROOT / "apworld"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, dirs, files in os.walk(src_root / "residentevilvillage"):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for f in files:
                path = Path(folder) / f
                if f == "lang.py" and Path(folder).name == "residentevilvillage":
                    z.writestr(str(path.relative_to(src_root).as_posix()),
                               f'# Langue de cet apworld (écrite par tools/install.py)\nLANG = "{lang}"\n')
                    continue
                z.write(path, path.relative_to(src_root))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-dir", type=Path, default=DEFAULT_GAME_DIR)
    parser.add_argument("--archipelago-dir", type=Path, default=DEFAULT_AP_DIR)
    parser.add_argument("--lang", choices=["fr", "en"], default="fr", help="langue de l'apworld installé")
    args = parser.parse_args()
    check_lua()
    install_client(args.game_dir)
    install_apworld(args.archipelago_dir, args.lang)


if __name__ == "__main__":
    main()
