"""
Construit la version à distribuer (deux zips à mettre dans la release GitHub) :
  build/release/RE_Village_Archipelago_<version>_launcher.zip  (launcher + fichiers du mod)
  build/release/RE_Village_Archipelago_<version>_manuel.zip    (installation à la main, sans launcher)

Usage : python tools/make_release.py [--game-dir DOSSIER_DU_JEU]

Contenu du zip (voir tools/launcher/core.py) :
  RE_Village_AP_Launcher.exe             launcher (PyInstaller, une seule fenêtre) : installation,
                                         jouer, options YAML, héberger
  files/game/...                         client/ sans le bridge (scripts, DLL, fichiers visuels)
  files/game/re_chunk_000.pak.patch_014.pak   pak de patch (renuméroté à l'installation)
  files/REFramework/dinput8.dll          REFramework pris dans le jeu (version testée avec le mod)
  files/apworld/fr|en/residentevilvillage.apworld
  files/version.json, files/options.json version du mod, options de l'apworld (écran « Mes options »)
Nécessite : pip install pyinstaller
"""

import argparse
import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools" / "re_engine"))
sys.path.insert(0, str(ROOT / "tools" / "launcher"))
import install  # noqa: E402
import options_schema  # noqa: E402
import pak_build  # noqa: E402

PATCH_PAK = "re_chunk_000.pak.patch_014.pak"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-dir", type=Path, default=install.DEFAULT_GAME_DIR)
    args = parser.parse_args()
    install.check_lua()
    # Version du mod et de la release : fichier VERSION (peut avoir 4 chiffres, ex. 0.9.1.1) ; l'apworld
    # garde son world_version X.Y.Z (archipelago.json), qui ne change que si l'apworld change.
    version_file = ROOT / "VERSION"
    version = version_file.read_text(encoding="utf-8").strip() if version_file.exists() else         json.loads((ROOT / "apworld" / "residentevilvillage" / "archipelago.json").read_text())["world_version"]
    name = f"RE_Village_Archipelago_{version}"
    out = ROOT / "build" / "release" / name
    if out.exists():
        shutil.rmtree(out)
    game = out / "files" / "game"
    for src in (ROOT / "client").rglob("*"):
        if src.is_file() and "bridge" not in src.parts:
            dst = game / src.relative_to(ROOT / "client")
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    pak_build.build(str(game / PATCH_PAK), str(ROOT / "client"))
    reframework = args.game_dir / "dinput8.dll"
    if not reframework.exists():
        sys.exit(f"REFramework (dinput8.dll) introuvable dans {args.game_dir}")
    (out / "files" / "REFramework").mkdir(parents=True)
    shutil.copy2(reframework, out / "files" / "REFramework" / "dinput8.dll")
    for lang in ("fr", "en"):  # deux apworlds (2026-10-08), même code, noms dans la langue
        install.install_apworld_to(out / "files" / "apworld" / lang / "residentevilvillage.apworld", lang)
    (out / "files" / "version.json").write_text(json.dumps({"version": version}), encoding="utf-8")
    (out / "files" / "options.json").write_text(json.dumps(options_schema.build(), indent=1, ensure_ascii=False),
                                                encoding="utf-8")

    work = ROOT / "build" / "pyinstaller"
    launcher = ROOT / "tools" / "launcher"
    assets = launcher / "assets"
    subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--onefile", "--windowed",
                    "--name", "RE_Village_AP_Launcher", "--icon", str(assets / "icon.ico"),
                    "--add-data", f"{assets / 'logo.png'};.", "--add-data", f"{assets / 'icon.ico'};.",
                    "--paths", str(launcher), "--distpath", str(out), "--workpath", str(work),
                    "--specpath", str(work), str(launcher / "launcher.py")], check=True)
    archive = out.parent / f"{name}_launcher.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(out.rglob("*")):
            if path.is_file():
                z.write(path, Path(name) / path.relative_to(out))
    print(f"Version prête (launcher) : {archive} ({archive.stat().st_size // 1024} Ko)")

    # Installation manuelle (2026-10-08, demande du joueur) : mêmes fichiers, sans launcher.
    #   jeu/...                 à copier dans le dossier du jeu (pak déjà nommé patch_014)
    #   REFramework/dinput8.dll si REFramework n'est pas déjà installé
    #   residentevilvillage.apworld, LISEZMOI.txt / README.txt
    manual_name = f"{name}_manuel"
    manual = out.parent / f"{manual_name}.zip"
    readme = (ROOT / "tools" / "launcher" / "LISEZMOI_manuel.txt").read_text(encoding="utf-8").replace("{version}", version)
    with zipfile.ZipFile(manual, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(game.rglob("*")):
            if path.is_file():
                z.write(path, Path(manual_name) / "jeu" / path.relative_to(game))
        z.write(out / "files" / "REFramework" / "dinput8.dll", Path(manual_name) / "REFramework" / "dinput8.dll")
        for lang in ("fr", "en"):
            z.write(out / "files" / "apworld" / lang / "residentevilvillage.apworld",
                    Path(manual_name) / f"apworld_{lang.upper()}" / "residentevilvillage.apworld")
        z.writestr(f"{manual_name}/LISEZMOI - README.txt", readme)
    print(f"Version prête (manuelle) : {manual} ({manual.stat().st_size // 1024} Ko)")


if __name__ == "__main__":
    main()
