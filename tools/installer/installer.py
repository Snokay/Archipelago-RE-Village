"""
Installateur du mod Archipelago de Resident Evil Village (sur le modèle du RE4R-AP-Wizard).

Construit en .exe par tools/make_release.py (PyInstaller). Il lit ses fichiers dans le dossier
"files" posé à côté de lui :
  files/game/...                       -> dossier du jeu (scripts Lua, DLL, fichiers visuels)
  files/game/<PATCH_PAK>               -> pak de patch, renuméroté au premier numéro libre
  files/REFramework/dinput8.dll        -> installé seulement si REFramework est absent
  files/residentevilvillage.apworld    -> <Archipelago>/custom_worlds/
La liste des fichiers posés est gardée dans reframework/data/re_village_ap_client/
install_manifest.json, pour la désinstallation.
"""

import ctypes
import json
import os
import re
import shutil
import sys
import threading
import tkinter as tk
import winreg
from pathlib import Path
from tkinter import filedialog, ttk

GAME_FOLDER = "Resident Evil Village BIOHAZARD VILLAGE"
PATCH_PAK = "re_chunk_000.pak.patch_014.pak"  # nom dans files/game (numéro réel choisi à l'installation)
MANIFEST = "reframework/data/re_village_ap_client/install_manifest.json"
# Données du joueur (connexion, état de la partie) : jamais supprimées par la désinstallation.
KEEP_PREFIX = "reframework/data/re_village_ap_client/"
MOD_DATA_FILES = {"items.json", "locations.json", "install_manifest.json"}  # ceux-là viennent du mod


def base_dir():
    return Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).parent


FILES = base_dir() / "files"


def is_french():
    try:
        return ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF == 0x0C
    except Exception:
        return False


FR = is_french()


def tr(fr, en):
    return fr if FR else en


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


# --- Installation -----------------------------------------------------------------------------

def is_our_pak(path):
    """Notre pak contient la texture du modèle Archipelago (hash du chemin dans sa table)."""
    marker = "natives/stm/character/it/it99/000/it99_000_archipelagologo_model0000_a_albm.tex.30"
    try:
        import struct
        data = path.read_bytes()
        magic, _, _, _, count, _ = struct.unpack_from("<4sBBHII", data, 0)
        if magic != b"KPKA":
            return False
        lower, upper = path_hash(marker)
        for i in range(count):
            lo, up = struct.unpack_from("<II", data, 16 + 48 * i)
            if lo == lower and up == upper:
                return True
    except Exception:
        pass
    return False


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
    old = game_dir / MANIFEST
    had_reframework = old.exists() and "dinput8.dll" in json.loads(old.read_text(encoding="utf-8")).get("files", [])
    uninstall(game_dir, None, lambda _msg: None, quiet=True)  # repart propre (ancienne version)
    placed = ["dinput8.dll"] if had_reframework else []
    if not (game_dir / "dinput8.dll").exists():
        shutil.copy2(FILES / "REFramework" / "dinput8.dll", game_dir / "dinput8.dll")
        placed.append("dinput8.dll")
        log(tr("REFramework installé (dinput8.dll)", "REFramework installed (dinput8.dll)"))
    else:
        log(tr("REFramework déjà présent : gardé", "REFramework already present: kept"))
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
                                  "File locked: close the game and run the installer again"))
        placed.append(target_rel)
    log(tr(f"{len(placed)} fichiers copiés (pak : {pak_name})", f"{len(placed)} files copied (pak: {pak_name})"))
    enable_loose_files(game_dir, log)
    manifest = game_dir / MANIFEST
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"files": placed}, indent=1), encoding="utf-8")
    if ap_dir:
        target = ap_dir / "custom_worlds" / "residentevilvillage.apworld"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(FILES / "residentevilvillage.apworld", target)
        log(tr(f"apworld installé : {target}", f"apworld installed: {target}"))
    log(tr("Installation terminée. Lance le jeu : la fenêtre REFramework (touche Inser) contient "
           "« RE Village Archipelago » pour se connecter.",
           "Done. Start the game: the REFramework window (Insert key) has "
           "\"RE Village Archipelago\" to connect."))


def uninstall(game_dir, ap_dir, log, quiet=False):
    manifest = game_dir / MANIFEST
    if not manifest.exists():
        if not quiet:
            log(tr("Le mod n'est pas installé ici (pas de manifeste)", "The mod is not installed here (no manifest)"))
        return
    files = json.loads(manifest.read_text(encoding="utf-8")).get("files", [])
    removed = 0
    for rel in files:
        if quiet and rel == "dinput8.dll":
            continue  # mise à jour : REFramework reste
        if rel.startswith(KEEP_PREFIX) and rel[len(KEEP_PREFIX):] not in MOD_DATA_FILES:
            continue
        path = game_dir / rel
        if path.exists():
            path.unlink()
            removed += 1
    manifest.unlink()
    if ap_dir:
        world = ap_dir / "custom_worlds" / "residentevilvillage.apworld"
        if world.exists():
            world.unlink()
            log(tr("apworld supprimé", "apworld removed"))
    if not quiet:
        log(tr(f"Désinstallé : {removed} fichiers supprimés (sauvegardes et connexion gardées)",
               f"Uninstalled: {removed} files removed (saves and connection kept)"))


# --- Fenêtre ----------------------------------------------------------------------------------

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("RE Village Archipelago")
        self.resizable(False, False)
        frame = ttk.Frame(self, padding=12)
        frame.grid()
        self.game = tk.StringVar(value=str(find_game_dir() or ""))
        self.ap = tk.StringVar(value=str(find_archipelago_dir() or ""))
        self.with_ap = tk.BooleanVar(value=bool(self.ap.get()))
        ttk.Label(frame, text=tr("Dossier du jeu (re8.exe) :", "Game folder (re8.exe):")).grid(row=0, column=0, sticky="w")
        ttk.Entry(frame, textvariable=self.game, width=70).grid(row=1, column=0)
        ttk.Button(frame, text="...", width=4, command=lambda: self.browse(self.game)).grid(row=1, column=1)
        ttk.Checkbutton(frame, variable=self.with_ap,
                        text=tr("Installer l'apworld dans Archipelago :", "Install the apworld into Archipelago:")
                        ).grid(row=2, column=0, sticky="w", pady=(10, 0))
        ttk.Entry(frame, textvariable=self.ap, width=70).grid(row=3, column=0)
        ttk.Button(frame, text="...", width=4, command=lambda: self.browse(self.ap)).grid(row=3, column=1)
        buttons = ttk.Frame(frame)
        buttons.grid(row=4, column=0, columnspan=2, pady=10)
        ttk.Button(buttons, text=tr("Installer / mettre à jour", "Install / update"),
                   command=lambda: self.run(install)).grid(row=0, column=0, padx=5)
        ttk.Button(buttons, text=tr("Désinstaller", "Uninstall"),
                   command=lambda: self.run(uninstall)).grid(row=0, column=1, padx=5)
        self.text = tk.Text(frame, width=80, height=12, state="disabled")
        self.text.grid(row=5, column=0, columnspan=2)
        if not self.game.get():
            self.log(tr("Jeu non trouvé automatiquement : choisis son dossier.",
                        "Game not found automatically: pick its folder."))

    def browse(self, var):
        folder = filedialog.askdirectory(initialdir=var.get() or None)
        if folder:
            var.set(folder)

    def log(self, msg):
        def write():
            self.text.configure(state="normal")
            self.text.insert("end", msg + "\n")
            self.text.see("end")
            self.text.configure(state="disabled")
        self.after(0, write)

    def run(self, action):
        game = Path(self.game.get())
        ap = Path(self.ap.get()) if self.with_ap.get() and self.ap.get() else None

        def work():
            try:
                action(game, ap, self.log)
            except Exception as e:
                self.log(tr("ERREUR : ", "ERROR: ") + str(e))
        threading.Thread(target=work, daemon=True).start()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("--install", "--uninstall"):
        # Mode console (tests) : installer.py --install DOSSIER_JEU [DOSSIER_AP]
        game = Path(sys.argv[2])
        ap = Path(sys.argv[3]) if len(sys.argv) > 3 else None
        (install if sys.argv[1] == "--install" else uninstall)(game, ap, print)
    else:
        App().mainloop()
