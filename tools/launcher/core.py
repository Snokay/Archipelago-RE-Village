"""
Cœur du launcher (sans fenêtre) : recherche des dossiers, installation / désinstallation du mod,
état de l'installation, connexion mémorisée pour le client en jeu, lancement du jeu, rapport de
bug. Repris de tools/installer/installer.py (2026-10-08), qu'il remplace.

Fichiers du mod lus dans le dossier "files" posé à côté du launcher (voir tools/make_release.py) :
  files/game/...                       -> dossier du jeu (scripts Lua, DLL, fichiers visuels)
  files/game/<PATCH_PAK>               -> pak de patch, renuméroté au premier numéro libre
  files/REFramework/dinput8.dll        -> installé seulement si REFramework est absent
  files/apworld/fr|en/residentevilvillage.apworld -> <Archipelago>/custom_worlds/ (langue choisie)
  files/version.json                   -> {"version": "..."} (version du mod)
  files/options.json                   -> options de l'apworld (écran « Mes options »)
La liste des fichiers posés est gardée dans reframework/data/re_village_ap_client/
install_manifest.json (avec la version), pour la mise à jour et la désinstallation.
"""

import ctypes
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import winreg
import zipfile
from pathlib import Path

GAME_FOLDER = "Resident Evil Village BIOHAZARD VILLAGE"
STEAM_APP_ID = 1196590
PATCH_PAK = "re_chunk_000.pak.patch_014.pak"  # nom dans files/game (numéro réel choisi à l'installation)
DATA_DIR = "reframework/data/re_village_ap_client"
MANIFEST = DATA_DIR + "/install_manifest.json"
CONNECTION = DATA_DIR + "/connection.json"
APWORLD = "residentevilvillage.apworld"
# Langue de l'apworld installé (2026-10-08 : versions FR et EN, mêmes numéros ; noms des objets et
# des checks dans la langue choisie). Réglée par le launcher (écran Installation).
# Fichiers d'anciennes versions du mod à retirer du jeu.
OBSOLETE = ["reframework/autorun/AP_REF/core.lua"]


def base_dir():
    return Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).parent


def resource(name):
    """Fichier embarqué dans l'exe (logo, icône) ; en développement : Assets/ du projet."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / name
    return Path(__file__).resolve().parent / "assets" / name


FILES = base_dir() / "files"
SETTINGS_DIR = Path(os.environ.get("APPDATA", str(Path.home()))) / "RE Village Archipelago"
SETTINGS_FILE = SETTINGS_DIR / "settings.json"
LOG_FILE = SETTINGS_DIR / "launcher.log"


def is_french():
    try:
        return ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF == 0x0C
    except Exception:
        return False


FR = is_french()
APWORLD_LANG = "fr" if FR else "en"  # voir APWORLD plus haut


def tr(fr, en):
    return fr if FR else en


def log_line(msg):
    try:
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


# --- Réglages du launcher ---------------------------------------------------------------------

def load_settings():
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(settings):
    SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps(settings, indent=1, ensure_ascii=False), encoding="utf-8")


def bundled_version():
    try:
        return json.loads((FILES / "version.json").read_text(encoding="utf-8"))["version"]
    except (OSError, ValueError, KeyError):
        return "dev"


# --- Recherche des dossiers -------------------------------------------------------------------

def reg_value(root, key, name):
    try:
        with winreg.OpenKey(root, key) as k:
            return winreg.QueryValueEx(k, name)[0]
    except OSError:
        return None


def find_game_dir():
    steam = reg_value(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath")
    libraries = []
    if steam:
        libraries.append(Path(steam))
        vdf = Path(steam) / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            for path in re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(encoding="utf-8", errors="replace")):
                libraries.append(Path(path.replace("\\\\", "\\")))
    for lib in libraries:
        candidate = lib / "steamapps" / "common" / GAME_FOLDER
        if (candidate / "re8.exe").exists():
            return candidate
    return None


def find_archipelago_dir():
    for root in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for view in (0, winreg.KEY_WOW64_32KEY):
            try:
                base = winreg.OpenKey(root, r"Software\Microsoft\Windows\CurrentVersion\Uninstall", 0,
                                      winreg.KEY_READ | view)
            except OSError:
                continue
            with base:
                for i in range(winreg.QueryInfoKey(base)[0]):
                    try:
                        with winreg.OpenKey(base, winreg.EnumKey(base, i)) as k:
                            name = winreg.QueryValueEx(k, "DisplayName")[0]
                            if str(name).startswith("Archipelago"):
                                location = Path(winreg.QueryValueEx(k, "InstallLocation")[0])
                                if (location / "ArchipelagoLauncher.exe").exists():
                                    return location
                    except OSError:
                        continue
    for candidate in (Path(r"C:\ProgramData\Archipelago"), Path(r"C:\Archipelago"), Path(r"D:\Archipelago")):
        if (candidate / "ArchipelagoLauncher.exe").exists():
            return candidate
    return None


def game_running():
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq re8.exe", "/NH"], capture_output=True,
                             text=True, creationflags=0x08000000).stdout
        return "re8.exe" in out.lower()
    except OSError:
        return False


# --- Pak de patch -----------------------------------------------------------------------------

def murmur3(data, seed=0xFFFFFFFF):
    c1, c2, h, n = 0xCC9E2D51, 0x1B873593, seed, len(data)
    for i in range(0, n - n % 4, 4):
        k = int.from_bytes(data[i:i + 4], "little")
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF
    tail = data[n - n % 4:]
    k = 0
    for i, b in enumerate(tail):
        k |= b << (8 * i)
    if tail:
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= n
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF
    h ^= h >> 16
    return h


def path_hash(path):
    return (murmur3(path.lower().encode("utf-16-le")), murmur3(path.upper().encode("utf-16-le")))


def is_our_pak(path):
    """Notre pak contient la texture du modèle Archipelago (hash du chemin dans sa table)."""
    marker = "natives/stm/character/it/it99/000/it99_000_archipelagologo_model0000_a_albm.tex.30"
    try:
        with path.open("rb") as f:
            head = f.read(16)
            magic, _, _, _, count, _ = struct.unpack_from("<4sBBHII", head, 0)
            if magic != b"KPKA":
                return False
            toc = f.read(48 * count)
        lower, upper = path_hash(marker)
        for i in range(count):
            lo, up = struct.unpack_from("<II", toc, 48 * i)
            if lo == lower and up == upper:
                return True
    except Exception:
        pass
    return False


def choose_pak_name(game_dir):
    """Le jeu charge re_chunk_000.pak.patch_001, 002... jusqu'au premier absent : notre pak prend
    la place d'un ancien pak du mod, sinon le premier numéro libre."""
    n = 1
    while True:
        name = f"re_chunk_000.pak.patch_{n:03d}.pak"
        path = game_dir / name
        if not path.exists() or is_our_pak(path):
            return name
        n += 1


# --- État de l'installation -------------------------------------------------------------------

def read_manifest(game_dir):
    try:
        return json.loads((game_dir / MANIFEST).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def status(game_dir, ap_dir):
    """Liste de (clé, niveau, texte) : niveau = "ok", "warn" ou "bad"."""
    rows = []
    game_ok = bool(game_dir) and (game_dir / "re8.exe").exists()
    rows.append(("game", "ok" if game_ok else "bad",
                 tr("re8.exe trouvé", "re8.exe found") if game_ok else
                 tr("re8.exe introuvable : choisis le dossier du jeu", "re8.exe not found: pick the game folder")))
    if not game_ok:
        return rows
    rows.append(("reframework", "ok" if (game_dir / "dinput8.dll").exists() else "warn",
                 tr("Présent (dinput8.dll)", "Present (dinput8.dll)") if (game_dir / "dinput8.dll").exists() else
                 tr("Absent : installé avec le mod", "Missing: installed with the mod")))
    manifest = read_manifest(game_dir)
    current = bundled_version()
    if manifest is None:
        rows.append(("mod", "bad", tr("Pas installé", "Not installed")))
    else:
        installed = manifest.get("version", "?")
        missing = [f for f in manifest.get("files", []) if not (game_dir / f).exists()]
        if missing:
            rows.append(("mod", "bad", tr(f"Installé ({installed}) mais {len(missing)} fichier(s) manquant(s) : réinstalle",
                                          f"Installed ({installed}) but {len(missing)} file(s) missing: reinstall")))
        elif installed != current:
            rows.append(("mod", "warn", tr(f"Version {installed} installée, {current} disponible : mets à jour",
                                           f"Version {installed} installed, {current} available: update")))
        else:
            rows.append(("mod", "ok", tr(f"Version {installed}", f"Version {installed}")))
    config = game_dir / "re2_fw_config.txt"
    loose = config.exists() and "LooseFileLoader_Enabled=true" in config.read_text(encoding="utf-8", errors="replace")
    rows.append(("loose", "ok" if loose else "warn",
                 tr("Activé", "Enabled") if loose else tr("Sera activé à l'installation", "Enabled by the install")))
    if ap_dir and (ap_dir / "ArchipelagoLauncher.exe").exists():
        world = ap_dir / "custom_worlds" / APWORLD
        lang = apworld_lang(world)
        rows.append(("apworld", "ok" if world.exists() else "warn",
                     tr(f"Installé dans Archipelago ({lang.upper()})", f"Installed in Archipelago ({lang.upper()})")
                     if world.exists() else
                     tr("Pas installé (utile seulement pour héberger / générer)",
                        "Not installed (only needed to host / generate)")))
    else:
        rows.append(("apworld", "warn", tr("Archipelago non trouvé (utile seulement pour héberger / générer)",
                                           "Archipelago not found (only needed to host / generate)")))
    return rows


# --- Installation -----------------------------------------------------------------------------

def enable_loose_files(game_dir, log):
    config = game_dir / "re2_fw_config.txt"
    text = config.read_text(encoding="utf-8", errors="replace") if config.exists() else ""
    if "LooseFileLoader_Enabled=true" in text:
        return
    if "LooseFileLoader_Enabled=false" in text:
        text = text.replace("LooseFileLoader_Enabled=false", "LooseFileLoader_Enabled=true")
    else:
        text = text.rstrip("\n") + ("\n" if text else "") + "LooseFileLoader_Enabled=true\n"
    config.write_text(text, encoding="utf-8")
    log(tr("Chargeur de fichiers « loose » de REFramework activé", "REFramework loose file loader enabled"))


def install(game_dir, ap_dir, log):
    if not (game_dir / "re8.exe").exists():
        raise RuntimeError(tr(f"re8.exe introuvable dans {game_dir}", f"re8.exe not found in {game_dir}"))
    if game_running():
        raise RuntimeError(tr("Le jeu est lancé : ferme-le avant d'installer", "The game is running: close it first"))
    old = read_manifest(game_dir)
    had_reframework = bool(old) and "dinput8.dll" in old.get("files", [])
    uninstall(game_dir, None, lambda _msg: None, quiet=True)  # repart propre (ancienne version)
    placed = ["dinput8.dll"] if had_reframework else []
    if not (game_dir / "dinput8.dll").exists():
        shutil.copy2(FILES / "REFramework" / "dinput8.dll", game_dir / "dinput8.dll")
        placed.append("dinput8.dll")
        log(tr("REFramework installé (dinput8.dll)", "REFramework installed (dinput8.dll)"))
    else:
        log(tr("REFramework déjà présent : gardé", "REFramework already present: kept"))
    for rel in OBSOLETE:
        if (game_dir / rel).exists():
            (game_dir / rel).unlink()
    src_root = FILES / "game"
    pak_name = choose_pak_name(game_dir)
    for src in sorted(src_root.rglob("*")):
        if not src.is_file():
            continue
        rel = src.relative_to(src_root).as_posix()
        target_rel = pak_name if rel == PATCH_PAK else rel
        dst = game_dir / target_rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copy2(src, dst)
        except PermissionError:
            raise RuntimeError(tr("Fichier verrouillé : ferme le jeu et relance l'installation",
                                  "File locked: close the game and run the install again"))
        placed.append(target_rel)
    log(tr(f"{len(placed)} fichiers copiés (pak : {pak_name})", f"{len(placed)} files copied (pak: {pak_name})"))
    enable_loose_files(game_dir, log)
    manifest = game_dir / MANIFEST
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"version": bundled_version(), "files": placed}, indent=1), encoding="utf-8")
    if ap_dir:
        install_apworld(ap_dir, log)
    log(tr("Installation terminée.", "Install complete."))


def apworld_lang(path):
    """Langue d'un .apworld (lang.py dans le paquet) ; "fr" pour un ancien apworld sans lang.py."""
    try:
        with zipfile.ZipFile(path) as z:
            text = z.read("residentevilvillage/lang.py").decode("utf-8")
        return "en" if 'LANG = "en"' in text else "fr"
    except (OSError, KeyError, zipfile.BadZipFile):
        return "fr"


def install_apworld(ap_dir, log):
    target = ap_dir / "custom_worlds" / APWORLD
    target.parent.mkdir(parents=True, exist_ok=True)
    source = FILES / "apworld" / APWORLD_LANG / APWORLD
    shutil.copy2(source if source.exists() else FILES / APWORLD, target)
    log(tr(f"apworld installé : {target}", f"apworld installed: {target}"))


def uninstall(game_dir, ap_dir, log, quiet=False):
    """Retire les fichiers posés par le mod (liste du manifeste). Les données du joueur
    (connexion, état des parties, journaux) ne sont jamais dans le manifeste : gardées."""
    manifest = read_manifest(game_dir)
    if manifest is None:
        if not quiet:
            log(tr("Le mod n'est pas installé ici", "The mod is not installed here"))
        return
    if not quiet and game_running():
        raise RuntimeError(tr("Le jeu est lancé : ferme-le avant de désinstaller", "The game is running: close it first"))
    removed = 0
    for rel in manifest.get("files", []):
        if quiet and rel == "dinput8.dll":
            continue  # mise à jour : REFramework reste
        path = game_dir / rel
        if path.exists():
            path.unlink()
            removed += 1
    (game_dir / MANIFEST).unlink()
    if ap_dir:
        world = ap_dir / "custom_worlds" / APWORLD
        if world.exists():
            world.unlink()
            log(tr("apworld supprimé", "apworld removed"))
    if not quiet:
        log(tr(f"Désinstallé : {removed} fichiers supprimés (sauvegardes et connexion gardées)",
               f"Uninstalled: {removed} files removed (saves and connection kept)"))


# --- Connexion du client en jeu et lancement --------------------------------------------------

def read_connection(game_dir):
    try:
        return json.loads((game_dir / CONNECTION).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {}


def write_connection(game_dir, host, slot, password):
    """auto = vrai : le client en jeu se connecte tout seul au démarrage."""
    path = game_dir / CONNECTION
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"host": host, "slot": slot, "password": password, "auto": True}, indent=4),
                    encoding="utf-8")


def launch_game():
    os.startfile(f"steam://rungameid/{STEAM_APP_ID}")


def open_path(path):
    os.startfile(str(path))


# --- Rapport de bug ---------------------------------------------------------------------------

REPORT_FILES = ["debug_log.txt", "debug_log_old.txt", "progress.jsonl", "pickups_log.jsonl", "room_cache.json",
                "install_manifest.json", "no_return_captures.jsonl", "bug_report.json", "hud_prefs.json"]


def bug_report(game_dir):
    """Zip des journaux sur le Bureau ; mot de passe retiré de la connexion."""
    desktop = Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Desktop"
    if not desktop.exists():
        desktop = SETTINGS_DIR
    target = desktop / time.strftime("RE_Village_AP_rapport_%Y%m%d_%H%M%S.zip")
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("launcher_version.txt", bundled_version())
        if LOG_FILE.exists():
            z.write(LOG_FILE, "launcher.log")
        settings = load_settings()
        if settings:
            z.writestr("launcher_settings.json", json.dumps(settings, indent=1, ensure_ascii=False))
        if game_dir and game_dir.exists():
            data = game_dir / DATA_DIR
            for name in REPORT_FILES:
                if (data / name).exists():
                    z.write(data / name, "client/" + name)
            for state in data.glob("state_*.json"):
                z.write(state, "client/" + state.name)
            conn = read_connection(game_dir)
            if conn:
                conn["password"] = "***" if conn.get("password") else ""
                z.writestr("client/connection.json", json.dumps(conn, indent=1))
            for name in ("re2_framework_log.txt", "reframework_revision.txt", "re2_fw_config.txt"):
                if (game_dir / name).exists():
                    z.write(game_dir / name, name)
            # autres mods installés (conflits possibles) : scripts REFramework et paks de patch
            autorun = game_dir / "reframework" / "autorun"
            listing = ["scripts REFramework :"]
            if autorun.exists():
                listing += ["  " + p.relative_to(autorun).as_posix() for p in sorted(autorun.rglob("*")) if p.is_file()]
            listing.append("paks :")
            listing += ["  %s (%d octets)" % (p.name, p.stat().st_size) for p in sorted(game_dir.glob("re_chunk_000.pak*"))]
            z.writestr("autres_mods.txt", "\n".join(listing))
            dump = game_dir / "reframework_crash.dmp"
            if dump.exists() and time.time() - dump.stat().st_mtime < 3 * 86400 and dump.stat().st_size < 64 << 20:
                z.write(dump, dump.name)
    return target
