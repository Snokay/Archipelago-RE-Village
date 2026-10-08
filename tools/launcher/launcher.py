"""
Launcher du mod Archipelago de Resident Evil Village (2026-10-08, sur le modèle du launcher de
RE4R : « RE4R AP Wizard »). Un seul .exe construit par tools/make_release.py (PyInstaller).

Écrans :
  Accueil       : Jouer / Préparer mes options / Héberger, et l'état de l'installation.
  Installation  : dossier du jeu et d'Archipelago, état (badges), installer / mettre à jour /
                  désinstaller (le mod et l'apworld).
  Jouer         : adresse de la room, slot, mot de passe -> test de connexion (apnet.check), puis
                  connection.json (connexion automatique du client en jeu) et lancement par Steam.
  Mes options   : formulaire des options de l'apworld -> YAML à envoyer à l'hôte.
  Héberger      : guide (YAML des joueurs, génération, room archipelago.gg ou serveur local).
Bas de fenêtre : ouvrir les journaux, rapport de bug (zip sur le Bureau).

Mode console (tests) : launcher.py --install DOSSIER_JEU [DOSSIER_AP] / --uninstall ...
"""

import ctypes
import json
import sys
import threading
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import apnet
import core
from core import tr

# --- Thème ------------------------------------------------------------------------------------

BG = "#111215"
PANEL = "#1a1c21"
CARD = "#22252b"
CARD_HOVER = "#2b2f36"
BORDER = "#363a42"
FIELD = "#0d0e10"
TEXT = "#ece6da"
MUTED = "#a09a8e"
ACCENT = "#c8a86a"
ACCENT_HOVER = "#d9bc82"
ON_ACCENT = "#17130b"
LEVEL_COLORS = {"ok": "#5fb37a", "warn": "#d9a441", "bad": "#d0605a"}
SERIF = "Georgia"
SANS = "Segoe UI"

class Button(tk.Label):
    """Bouton plat avec survol (tk.Button ignore les couleurs de fond sur certains thèmes)."""

    def __init__(self, parent, text, command, primary=False, small=False, **kw):
        self.bg = ACCENT if primary else CARD
        self.hover = ACCENT_HOVER if primary else CARD_HOVER
        super().__init__(parent, text=text, bg=self.bg, fg=ON_ACCENT if primary else TEXT, cursor="hand2",
                         font=(SANS, 9 if small else 10, "bold" if primary else "normal"),
                         padx=10 if small else 18, pady=4 if small else 8,
                         highlightthickness=1, highlightbackground=ACCENT if primary else BORDER, **kw)
        self.command, self.enabled = command, True
        self.bind("<Enter>", lambda _e: self.enabled and self.configure(bg=self.hover))
        self.bind("<Leave>", lambda _e: self.configure(bg=self.bg))
        self.bind("<Button-1>", lambda _e: self.enabled and self.command())

    def set_enabled(self, enabled):
        self.enabled = enabled
        self.configure(fg=(ON_ACCENT if self.bg == ACCENT else TEXT) if enabled else MUTED,
                       cursor="hand2" if enabled else "arrow")


def label(parent, text, size=10, color=TEXT, bold=False, serif=False, wrap=0, bg=None, **kw):
    return tk.Label(parent, text=text, fg=color, bg=bg or parent["bg"], justify="left", anchor="w",
                    font=(SERIF if serif else SANS, size, "bold" if bold else "normal"), wraplength=wrap, **kw)


def entry(parent, var, width=60, show=None):
    return tk.Entry(parent, textvariable=var, width=width, show=show, bg=FIELD, fg=TEXT, insertbackground=TEXT,
                    relief="flat", font=(SANS, 10), highlightthickness=1, highlightbackground=BORDER,
                    highlightcolor=ACCENT)


def badge(parent, level, text):
    color = LEVEL_COLORS[level]
    word = {"ok": tr("OK", "OK"), "warn": tr("Attention", "Warning"), "bad": tr("Manquant", "Missing")}[level]
    return tk.Label(parent, text=word, fg=color, bg=PANEL, font=(SANS, 9, "bold"), padx=8, pady=1,
                    highlightthickness=1, highlightbackground=color)


class Segmented(tk.Frame):
    """Choix exclusif en boutons collés (comme la difficulté du launcher RE4)."""

    def __init__(self, parent, values, labels, current, on_change):
        super().__init__(parent, bg=BORDER, padx=1, pady=1)
        self.items, self.value, self.on_change, self.enabled = {}, current, on_change, True
        for i, (value, text) in enumerate(zip(values, labels)):
            item = tk.Label(self, text=text, font=(SANS, 9), padx=12, pady=5, cursor="hand2")
            item.grid(row=0, column=i, padx=(0 if i == 0 else 1, 0))
            item.bind("<Button-1>", lambda _e, v=value: self.enabled and self.set(v, notify=True))
            self.items[value] = item
        self.paint()

    def set(self, value, notify=False):
        self.value = value
        self.paint()
        if notify:
            self.on_change(value)

    def set_enabled(self, enabled):
        self.enabled = enabled
        self.paint()

    def paint(self):
        for value, item in self.items.items():
            selected = value == self.value
            if not self.enabled:
                item.configure(bg=PANEL, fg=MUTED if not selected else TEXT)
            else:
                item.configure(bg=ACCENT if selected else CARD, fg=ON_ACCENT if selected else TEXT)


class Scrollable(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=PANEL)
        self.canvas = tk.Canvas(self, bg=PANEL, highlightthickness=0, bd=0)
        bar = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview, style="Dark.Vertical.TScrollbar")
        self.inner = tk.Frame(self.canvas, bg=PANEL)
        self.inner.bind("<Configure>", lambda _e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        window = self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.canvas.bind("<Configure>", lambda e: self.canvas.itemconfigure(window, width=e.width))
        self.canvas.configure(yscrollcommand=bar.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        bar.pack(side="right", fill="y")
        self.bind_all("<MouseWheel>", self._wheel, add="+")

    def _wheel(self, event):
        try:
            if self.winfo_exists() and str(event.widget).startswith(str(self)):
                self.canvas.yview_scroll(int(-event.delta / 120), "units")
        except tk.TclError:
            pass  # page déjà fermée


def read_yaml(text):
    """YAML de joueur Archipelago (sans dépendance) : renvoie (nom, {option: valeur}). Une option
    pondérée (plusieurs valeurs avec un poids) prend la valeur au plus gros poids."""
    name, options, section, current, weights, option_indent, found = None, {}, False, None, {}, 0, False

    def clean(value):
        value = value.split(" #")[0].strip()
        return value[1:-1] if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"" else value

    def flush():
        if current and weights:
            options[current] = max(weights, key=lambda k: weights[k])

    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        key, _, value = raw.strip().partition(":")
        key, value = clean(key), clean(value)
        if indent == 0:
            flush()
            current, weights = None, {}
            section = key == apnet.GAME
            found = found or section
            if key == "name":
                name = value
            continue
        if not section:
            continue
        if current is None or indent <= option_indent:
            flush()
            current, weights, option_indent = key, {}, indent
            if value != "":
                options[key] = value
                current = None
        else:
            try:
                weights[key] = float(value)
            except ValueError:
                pass
    flush()
    if not found:
        raise ValueError(tr("ce YAML n'est pas pour Resident Evil Village", "this YAML is not for Resident Evil Village"))
    return name, options


# --- Fenêtre ----------------------------------------------------------------------------------

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("RE Village Archipelago")
        self.configure(bg=BG)
        self.geometry("1080x780")
        self.minsize(900, 640)
        try:
            self.iconbitmap(str(core.resource("icon.ico")))
        except tk.TclError:
            pass
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("Dark.Vertical.TScrollbar", background=CARD, troughcolor=PANEL, bordercolor=PANEL,
                        arrowcolor=MUTED, lightcolor=CARD, darkcolor=CARD)
        self.settings = core.load_settings()
        self.game = tk.StringVar(value=self.settings.get("game_dir") or str(core.find_game_dir() or ""))
        self.ap = tk.StringVar(value=self.settings.get("ap_dir") or str(core.find_archipelago_dir() or ""))
        self.status_text = tk.StringVar(value=tr("Prêt.", "Ready."))
        self.busy = False
        self.autosave_job = None
        core.APWORLD_LANG = self.settings.get("apworld_lang", core.APWORLD_LANG)
        core.log_line(f"launcher {core.bundled_version()} démarré")

        header = tk.Frame(self, bg=BG)
        header.pack(fill="x", padx=24, pady=(14, 0))
        try:
            self.logo = tk.PhotoImage(file=str(core.resource("logo.png")))
            self.logo = self.logo.subsample(2, 2)
            tk.Label(header, image=self.logo, bg=BG).pack(side="left")
        except tk.TclError:
            label(header, "RE Village Archipelago", 22, serif=True).pack(side="left")
        label(header, f"v{core.bundled_version()}", 9, MUTED).pack(side="right", anchor="s", pady=(0, 6))

        nav = tk.Frame(self, bg=BG)
        nav.pack(fill="x", padx=24, pady=(10, 0))
        self.tabs = {}
        for key, text in (("home", tr("Accueil", "Home")), ("install", tr("Installation", "Setup")),
                          ("play", tr("Jouer", "Play")), ("options", tr("Mes options (YAML)", "My options (YAML)")),
                          ("host", tr("Héberger", "Host"))):
            tab = tk.Label(nav, text=text, bg=BG, fg=MUTED, font=(SANS, 11), padx=14, pady=6, cursor="hand2")
            tab.pack(side="left")
            tab.bind("<Button-1>", lambda _e, k=key: self.show(k))
            self.tabs[key] = tab
        tk.Frame(self, bg=BORDER, height=1).pack(fill="x", padx=24)

        footer = tk.Frame(self, bg=BG)
        footer.pack(side="bottom", fill="x", padx=24, pady=(0, 12))
        tk.Label(footer, textvariable=self.status_text, bg=BG, fg=MUTED, font=(SANS, 9), anchor="w"
                 ).pack(side="left", fill="x", expand=True)
        Button(footer, tr("Rapport de bug", "Bug report"), self.bug_report, small=True).pack(side="right")
        Button(footer, tr("Ouvrir les journaux", "Open logs"), self.open_logs, small=True).pack(side="right", padx=6)

        self.body = tk.Frame(self, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.body.pack(fill="both", expand=True, padx=24, pady=14)

        self.pages = {"home": self.page_home, "install": self.page_install, "play": self.page_play,
                      "options": self.page_options, "host": self.page_host}
        self.current = None
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.show("home" if self.mod_ready() else "install")

    # --- Outils ---

    def game_dir(self):
        return Path(self.game.get()) if self.game.get() else None

    def ap_dir(self):
        path = Path(self.ap.get()) if self.ap.get() else None
        return path if path and (path / "ArchipelagoLauncher.exe").exists() else None

    def mod_ready(self):
        game = self.game_dir()
        rows = core.status(game, self.ap_dir()) if game else []
        return any(k == "mod" and lvl == "ok" for k, lvl, _t in rows)

    def save(self):
        self.settings["game_dir"], self.settings["ap_dir"] = self.game.get(), self.ap.get()
        core.save_settings(self.settings)

    def set_status(self, text):
        core.log_line(text)
        self.after(0, lambda: self.status_text.set(text))

    def run_bg(self, work, done=None):
        """Travail long hors du fil de la fenêtre ; done(résultat) rappelé dans la fenêtre."""
        if self.busy:
            return
        self.busy = True

        def thread():
            try:
                result = work()
            except Exception as e:
                result = e
            self.after(0, lambda: (setattr(self, "busy", False), done and done(result)))
        threading.Thread(target=thread, daemon=True).start()

    def show(self, key):
        self.current = key
        for k, tab in self.tabs.items():
            tab.configure(fg=ACCENT if k == key else MUTED, font=(SANS, 11, "bold" if k == key else "normal"))
        for child in self.body.winfo_children():
            child.destroy()
        self.pages[key]()

    def page_title(self, parent, title, subtitle):
        label(parent, title, 24, serif=True).pack(anchor="w")
        label(parent, subtitle, 10, MUTED, wrap=960).pack(anchor="w", pady=(4, 16))

    def browse(self, var):
        folder = filedialog.askdirectory(initialdir=var.get() or None)
        if folder:
            var.set(folder)
            self.save()
            self.show(self.current)

    # --- Accueil ---

    def page_home(self):
        page = tk.Frame(self.body, bg=PANEL, padx=32, pady=26)
        page.pack(fill="both", expand=True)
        if not self.mod_ready():
            banner = tk.Frame(page, bg="#3a2c14", padx=16, pady=12, highlightthickness=1,
                              highlightbackground=LEVEL_COLORS["warn"])
            banner.pack(fill="x", pady=(0, 18))
            label(banner, tr("Le mod n'est pas installé ou pas à jour.", "The mod is not installed or out of date."),
                  11, bold=True).pack(side="left")
            Button(banner, tr("Aller à l'installation", "Go to setup"), lambda: self.show("install"),
                   small=True).pack(side="right")
        label(page, tr("Que veux-tu faire ?", "What would you like to do?"), 22, serif=True).pack(anchor="w")
        cards = tk.Frame(page, bg=PANEL)
        cards.pack(fill="x", pady=16)
        for i, (key, title, text) in enumerate((
                ("play", tr("Jouer", "Play"),
                 tr("La room existe déjà : entre son adresse et ton nom de slot, le jeu se lance et se connecte tout seul.",
                    "The room already exists: enter its address and your slot name, the game starts and connects by itself.")),
                ("options", tr("Préparer mes options", "Prepare my options"),
                 tr("Avant la génération : choisis tes réglages et crée le fichier YAML à envoyer à l'hôte.",
                    "Before generation: pick your settings and create the YAML file to send to the host.")),
                ("host", tr("Héberger une partie", "Host a game"),
                 tr("Rassemble les YAML de tout le monde, génère le multiworld et partage la room.",
                    "Collect everyone's YAML, generate the multiworld and share the room.")))):
            card = tk.Frame(cards, bg=CARD, padx=20, pady=18, cursor="hand2", highlightthickness=1,
                            highlightbackground=BORDER)
            # Taille donnée par le contenu (colonnes égales, même hauteur par la ligne) : une taille
            # imposée (width/height + grid_propagate, alors que le contenu est en pack) faisait
            # alterner la carte entre deux hauteurs à chaque changement de couleur -> clignotement.
            card.grid(row=0, column=i, padx=(0, 14), sticky="nsew")
            cards.columnconfigure(i, weight=1, uniform="card")
            widgets = [card, label(card, title, 15, serif=True, bold=True), label(card, text, 10, MUTED, wrap=260)]
            widgets[1].pack(anchor="w")
            widgets[2].pack(anchor="w", pady=(8, 0))
            # Survol décidé par la position de la souris dans la carte : passer du fond de la carte
            # à un de ses textes donnait « sortie » puis « entrée » -> clignotement (2026-10-08).
            def hover(_e, card=card, ws=widgets):
                x, y = card.winfo_pointerxy()
                inside = card.winfo_rootx() <= x < card.winfo_rootx() + card.winfo_width() and \
                    card.winfo_rooty() <= y < card.winfo_rooty() + card.winfo_height()
                color = CARD_HOVER if inside else CARD
                if card["bg"] != color:
                    for w in ws:
                        w.configure(bg=color)
            for w in widgets:
                w.bind("<Button-1>", lambda _e, k=key: self.show(k))
                w.bind("<Enter>", hover)
                w.bind("<Leave>", hover)
        conn = core.read_connection(self.game_dir()) if self.game_dir() else {}
        if conn.get("slot"):
            label(page, tr(f"Dernière partie : {conn['slot']} sur {conn.get('host', '?')}",
                           f"Last game: {conn['slot']} on {conn.get('host', '?')}"), 10, MUTED).pack(anchor="w", pady=(8, 0))

    # --- Installation ---

    def page_install(self):
        page = tk.Frame(self.body, bg=PANEL, padx=32, pady=26)
        page.pack(fill="both", expand=True)
        self.page_title(page, tr("Installation", "Setup"),
                        tr("Le jeu, REFramework (le chargeur de scripts), le mod et l'apworld sont vérifiés ici. "
                           "Tout en vert : prêt à jouer. Le jeu doit être fermé pour installer.",
                           "The game, REFramework (the script loader), the mod and the apworld are checked here. "
                           "All green: ready to play. The game must be closed to install."))
        form = tk.Frame(page, bg=PANEL)
        form.pack(fill="x")
        for row, (text, var) in enumerate(((tr("Dossier du jeu", "Game folder"), self.game),
                                           (tr("Dossier d'Archipelago", "Archipelago folder"), self.ap))):
            label(form, text, 10).grid(row=row, column=0, sticky="w", pady=5, padx=(0, 16))
            entry(form, var, 80).grid(row=row, column=1, sticky="we", ipady=4)
            Button(form, tr("Parcourir", "Browse"), lambda v=var: self.browse(v), small=True
                   ).grid(row=row, column=2, padx=(8, 0))
        form.columnconfigure(1, weight=1)

        lang_row = tk.Frame(page, bg=PANEL)
        lang_row.pack(fill="x", pady=(12, 0))
        label(lang_row, tr("Langue de l'apworld", "apworld language"), 10).pack(side="left", padx=(0, 16))
        Segmented(lang_row, ["fr", "en"], ["Français", "English"], core.APWORLD_LANG, self.set_apworld_lang
                  ).pack(side="left")
        label(lang_row, tr("Noms des objets et des checks dans Archipelago (le YAML marche avec les deux).",
                           "Item and check names in Archipelago (YAML files work with both)."), 9, MUTED
              ).pack(side="left", padx=12)

        table = tk.Frame(page, bg=PANEL)
        table.pack(fill="x", pady=18)
        names = {"game": tr("Jeu", "Game"), "reframework": "REFramework", "mod": tr("Mod Archipelago", "Archipelago mod"),
                 "loose": tr("Fichiers « loose »", "Loose files"), "apworld": "apworld"}
        for row, (key, level, text) in enumerate(core.status(self.game_dir(), self.ap_dir())):
            label(table, names[key], 10).grid(row=row, column=0, sticky="w", pady=4, padx=(0, 24))
            badge(table, level, text).grid(row=row, column=1, sticky="w")
            label(table, text, 10, MUTED).grid(row=row, column=2, sticky="w", padx=14)

        buttons = tk.Frame(page, bg=PANEL)
        buttons.pack(fill="x")
        install = Button(buttons, tr("Installer / mettre à jour", "Install / update"), lambda: self.do_install(core.install),
                         primary=True)
        install.pack(side="left")
        Button(buttons, tr("Désinstaller", "Uninstall"), lambda: self.do_install(core.uninstall)).pack(side="left", padx=10)
        if not core.FILES.exists():
            install.set_enabled(False)
            label(buttons, tr("(dossier « files » absent : lance le launcher depuis le zip de la version)",
                              "(\"files\" folder missing: run the launcher from the release zip)"), 9, MUTED
                  ).pack(side="left", padx=10)
        self.install_log = tk.Text(page, height=8, bg=FIELD, fg=MUTED, relief="flat", font=("Consolas", 9),
                                   highlightthickness=1, highlightbackground=BORDER, state="disabled")
        self.install_log.pack(fill="both", expand=True, pady=(16, 0))

    def set_apworld_lang(self, lang):
        core.APWORLD_LANG = self.settings["apworld_lang"] = lang
        self.save()

    def log_install(self, msg):
        core.log_line(msg)

        def write():
            if self.current == "install" and self.install_log.winfo_exists():
                self.install_log.configure(state="normal")
                self.install_log.insert("end", msg + "\n")
                self.install_log.see("end")
                self.install_log.configure(state="disabled")
        self.after(0, write)

    def do_install(self, action):
        game = self.game_dir()
        if not game:
            self.log_install(tr("Choisis d'abord le dossier du jeu.", "Pick the game folder first."))
            return
        self.save()
        self.set_status(tr("Travail en cours…", "Working…"))

        def done(result):
            if isinstance(result, Exception):
                self.log_install(tr("ERREUR : ", "ERROR: ") + str(result))
                self.set_status(tr("Échec : voir le journal.", "Failed: see the log."))
            else:
                self.set_status(tr("Terminé.", "Done."))
                lines = self.install_log.get("1.0", "end")
                self.show("install")
                self.log_install(lines.strip())
        self.run_bg(lambda: action(game, self.ap_dir(), self.log_install), done)

    # --- Jouer ---

    def page_play(self):
        page = tk.Frame(self.body, bg=PANEL, padx=32, pady=26)
        page.pack(fill="both", expand=True)
        self.page_title(page, tr("Jouer", "Play"),
                        tr("Ton hôte te donne ces informations. Elles sont enregistrées dans le jeu dès que tu les "
                           "modifies : ensuite, lancer le jeu suffit, il se reconnecte tout seul à cette session.",
                           "Your host gives you these details. They are saved into the game as soon as you change "
                           "them: afterwards, just start the game, it reconnects to this session by itself."))
        conn = core.read_connection(self.game_dir()) if self.game_dir() else {}
        self.addr = tk.StringVar(value=self.settings.get("address") or conn.get("host", ""))
        self.slot = tk.StringVar(value=conn.get("slot") or self.settings.get("yaml", {}).get("name", ""))
        self.password = tk.StringVar(value=conn.get("password", ""))
        self.autosave_job = None
        for var in (self.addr, self.slot, self.password):
            var.trace_add("write", lambda *_a: self.schedule_autosave())
        form = tk.Frame(page, bg=PANEL)
        form.pack(fill="x")
        rows = ((tr("Adresse de la room", "Room address"), self.addr, None,
                 tr("Par exemple archipelago.gg:38281, le port seul, localhost:38281, ou le lien de la page de la room "
                    "(https://archipelago.gg/room/…) : la page réveille une room endormie.",
                    "For example archipelago.gg:38281, just the port, localhost:38281, or the room page link "
                    "(https://archipelago.gg/room/…): opening it wakes a sleeping room.")),
                (tr("Nom du slot", "Slot name"), self.slot, None,
                 tr("Exactement le nom de ton YAML (majuscules comprises).", "Exactly the name in your YAML (case matters).")),
                (tr("Mot de passe (facultatif)", "Password (optional)"), self.password, "•", ""))
        for i, (text, var, show, hint) in enumerate(rows):
            label(form, text, 10).grid(row=2 * i, column=0, sticky="w", padx=(0, 16), pady=(8, 0))
            entry(form, var, 70, show).grid(row=2 * i, column=1, sticky="we", ipady=4, pady=(8, 0))
            if hint:
                label(form, hint, 9, MUTED, wrap=720).grid(row=2 * i + 1, column=1, sticky="w")
        form.columnconfigure(1, weight=1)
        buttons = tk.Frame(page, bg=PANEL)
        buttons.pack(fill="x", pady=20)
        Button(buttons, tr("Jouer", "Play"), lambda: self.do_play(launch=True), primary=True).pack(side="left")
        Button(buttons, tr("Tester la connexion", "Test connection"), lambda: self.do_play(launch=False)
               ).pack(side="left", padx=10)
        self.play_msg = label(page, "", 11, wrap=960)
        self.play_msg.pack(anchor="w")
        self.saved_msg = label(page, "", 10, MUTED, wrap=960)
        self.saved_msg.pack(anchor="w", pady=(10, 0))
        if conn.get("slot"):
            off = not conn.get("auto")
            self.saved_msg.configure(text=tr(f"Enregistré dans le jeu : {conn['slot']} sur {conn.get('host', '?')}"
                                             + (" (connexion auto coupée en jeu : modifie un champ pour la remettre)"
                                                if off else ""),
                                             f"Saved in the game: {conn['slot']} on {conn.get('host', '?')}"
                                             + (" (auto connect turned off in game: change a field to turn it back on)"
                                                if off else "")))

    def schedule_autosave(self):
        if self.autosave_job:
            self.after_cancel(self.autosave_job)
        self.autosave_job = self.after(700, self.autosave)

    def autosave(self):
        """Adresse / slot / mot de passe écrits dans connection.json à chaque modification (connexion
        automatique au prochain lancement du jeu, sans repasser par le launcher). Adresse sans
        protocole : ws:// en local, sinon wss:// (archipelago.gg) ; « Tester » / « Jouer » la
        remplacent par l'adresse vérifiée. Lien de page de room : l'adresse y est lue en arrière-plan."""
        self.autosave_job = None
        game = self.game_dir()
        address, slot, password = self.addr.get().strip(), self.slot.get().strip(), self.password.get()
        if not game or not (game / "re8.exe").exists() or not address or not slot:
            return
        self.settings["address"] = address
        self.save()

        def write(uri):
            core.write_connection(game, uri, slot, password)
            core.log_line(f"connexion enregistrée : {slot} sur {uri}")
            if self.current == "play" and self.saved_msg.winfo_exists():
                self.saved_msg.configure(text=tr(f"✔ Enregistré dans le jeu : {slot} sur {uri}. Lance juste le jeu, "
                                                 "il se connecte tout seul.",
                                                 f"✔ Saved in the game: {slot} on {uri}. Just start the game, "
                                                 "it connects by itself."), fg=LEVEL_COLORS["ok"])
        uri = apnet.guess_uri(address)
        if uri:
            write(uri)
            return

        def resolve():
            try:
                found = apnet.guess_uri(apnet.resolve_room_page(address))
            except Exception:
                found = None
            if found:
                self.after(0, lambda: write(found))
        threading.Thread(target=resolve, daemon=True).start()

    def play_message(self, text, level):
        if self.current == "play" and self.play_msg.winfo_exists():
            self.play_msg.configure(text=text, fg=LEVEL_COLORS[level])

    def do_play(self, launch):
        game = self.game_dir()
        address, slot, password = self.addr.get().strip(), self.slot.get().strip(), self.password.get()
        if not address or not slot:
            self.play_message(tr("Entre l'adresse et le nom du slot.", "Enter the address and the slot name."), "bad")
            return
        if launch and not self.mod_ready():
            self.play_message(tr("Le mod n'est pas installé ou pas à jour : passe d'abord par Installation.",
                                 "The mod is not installed or out of date: go to Setup first."), "bad")
            return
        self.settings["address"] = address
        self.save()
        self.play_message(tr("Connexion à la room…", "Connecting to the room…"), "warn")

        def done(result):
            if isinstance(result, Exception):
                self.play_message(tr("Adresse illisible : ", "Unreadable address: ") + str(result), "bad")
                return
            core.log_line(f"test connexion {address} {slot}: {result}")
            if not result["ok"]:
                messages = {
                    "InvalidSlot": tr(f"La room répond, mais aucun slot ne s'appelle « {slot} ».",
                                      f"The room answers, but no slot is called \"{slot}\"."),
                    "InvalidPassword": tr("Mot de passe refusé.", "Wrong password."),
                    "unreachable": tr("La room ne répond pas. Vérifie l'adresse ; une room archipelago.gg endormie se "
                                      "réveille en ouvrant sa page (colle son lien ici).",
                                      "The room does not answer. Check the address; a sleeping archipelago.gg room "
                                      "wakes up when its page is opened (paste its link here)."),
                }
                self.play_message(messages.get(result["error"], tr("Refusé : ", "Refused: ") + result["error"]), "bad")
                return
            if not result["game_ok"]:
                self.play_message(tr(f"Le slot « {slot} » joue à {result['game']}, pas à Resident Evil Village.",
                                     f"Slot \"{slot}\" plays {result['game']}, not Resident Evil Village."), "bad")
                return
            if not launch:
                self.play_message(tr(f"Connexion OK ({result['uri']}).", f"Connection OK ({result['uri']})."), "ok")
                return
            core.write_connection(game, result["uri"], slot, password)
            if core.game_running():
                self.play_message(tr("Connexion notée. Le jeu est déjà lancé : dans REFramework (touche Inser), "
                                     "« Reset scripts » pour la prendre en compte.",
                                     "Connection saved. The game is already running: in REFramework (Insert key), "
                                     "\"Reset scripts\" to use it."), "ok")
                return
            if not core.launch_game(game):
                self.play_message(tr("Connexion notée. Ton jeu n'est pas la version Steam : lance-le toi-même (application "
                                     "Xbox / Microsoft Store), le mod se connectera tout seul.",
                                     "Connection saved. Your game is not the Steam version: start it yourself (Xbox app / "
                                     "Microsoft Store), the mod connects by itself."), "ok")
                self.set_status(tr(f"Connexion notée : {slot} sur {result['uri']}", f"Connection saved: {slot} on {result['uri']}"))
                return
            self.play_message(tr("Connexion notée, lancement du jeu par Steam… Le mod se connecte tout seul.",
                                 "Connection saved, starting the game through Steam… The mod connects by itself."), "ok")
            self.set_status(tr(f"Jeu lancé : {slot} sur {result['uri']}", f"Game started: {slot} on {result['uri']}"))
        self.run_bg(lambda: apnet.check(address, slot, password), done)

    # --- Mes options ---

    def load_schemas(self):
        """Options de l'apworld dans les deux langues : {"fr": [...], "en": [...]}."""
        if (core.FILES / "options.json").exists():
            return json.loads((core.FILES / "options.json").read_text(encoding="utf-8"))
        import options_schema
        return options_schema.build()

    def page_options(self):
        scroll = Scrollable(self.body)
        scroll.pack(fill="both", expand=True)
        page = tk.Frame(scroll.inner, bg=PANEL, padx=32, pady=26)
        page.pack(fill="both", expand=True)
        self.page_title(page, tr("Mes options", "My options"),
                        tr("Archipelago appelle ces réglages un YAML : un petit fichier texte qui décrit ta partie. Chaque "
                           "joueur envoie le sien à l'hôte AVANT la génération ; une fois la room créée, il ne sert plus.",
                           "Archipelago calls these settings a YAML: a small text file describing your game. Every player "
                           "sends theirs to the host BEFORE generation; once the room exists, it is no longer used."))
        saved = self.settings.get("yaml", {})
        self.yaml_name = tk.StringVar(value=saved.get("name", ""))
        top = tk.Frame(page, bg=PANEL)
        top.pack(fill="x")
        label(top, tr("Nom du slot", "Slot name"), 11, bold=True).grid(row=0, column=0, sticky="w", padx=(0, 16))
        entry(top, self.yaml_name, 30).grid(row=0, column=1, sticky="w", ipady=4)
        label(top, tr("16 caractères maximum, majuscules comprises : c'est le nom à taper pour jouer.",
                      "16 characters max, case matters: it is the name you will type to play."), 9, MUTED
              ).grid(row=1, column=1, sticky="w")

        schemas = self.load_schemas()
        self.schema = schemas["fr" if core.FR else "en"]
        self.other_schema = {o["key"]: o for o in schemas["en" if core.FR else "fr"]}
        self.values = {}
        self.controls = {}
        for option in self.schema:
            key = option["key"]
            value = saved.get("options", {}).get(key, option["default"])
            card = tk.Frame(page, bg=CARD, padx=18, pady=14, highlightthickness=1, highlightbackground=BORDER)
            card.pack(fill="x", pady=(14, 0))
            label(card, option["display"], 12, bold=True, bg=CARD).pack(anchor="w")
            label(card, option["doc"], 9, MUTED, wrap=900, bg=CARD).pack(anchor="w", pady=(4, 10))
            if option["kind"] == "toggle":
                control = Segmented(card, [1, 0], [tr("Activé", "On"), tr("Désactivé", "Off")], int(bool(value)),
                                    lambda v, k=key: self.set_option(k, v))
            elif option["kind"] == "choice":
                value = self.choice_value(option, value)
                control = Segmented(card, option["choices"], option["labels"], value,
                                    lambda v, k=key: self.set_option(k, v))
            else:
                row = tk.Frame(card, bg=CARD)
                unit = " %" if "%" in option["display"] else ""  # poids des pièges : nombre simple
                shown = label(row, f"{int(value)}{unit}", 11, ACCENT, bold=True, bg=CARD, width=6)

                def moved(v, k=key, shown=shown, unit=unit):
                    shown.configure(text=f"{int(float(v))}{unit}")
                    self.set_option(k, int(float(v)))
                control = tk.Scale(row, from_=option["min"], to=option["max"], orient="horizontal", length=420,
                                   showvalue=0, bg=ACCENT, troughcolor=FIELD, highlightthickness=0, bd=0,
                                   activebackground=ACCENT_HOVER, sliderrelief="flat", sliderlength=18, width=14,
                                   command=moved)
                control.set(int(value))
                control.pack(side="left")
                shown.pack(side="left", padx=12)
                row.pack(anchor="w")
            if option["kind"] != "range":
                control.pack(anchor="w")
            self.values[key] = value
            self.controls[key] = control
        self.refresh_requires()

        buttons = tk.Frame(page, bg=PANEL)
        buttons.pack(fill="x", pady=(20, 4))
        Button(buttons, tr("Enregistrer le YAML…", "Save YAML…"), self.save_yaml, primary=True).pack(side="left")
        Button(buttons, tr("Copier", "Copy"), self.copy_yaml).pack(side="left", padx=10)
        Button(buttons, tr("Importer un YAML…", "Import a YAML…"), self.import_yaml).pack(side="left", padx=(0, 10))
        if self.ap_dir():
            Button(buttons, tr("Mettre dans Archipelago/Players (je suis l'hôte)", "Put in Archipelago/Players (I host)"),
                   self.yaml_to_players).pack(side="left")
        self.yaml_msg = label(page, "", 10)
        self.yaml_msg.pack(anchor="w", pady=(6, 0))

    def choice_value(self, option, value):
        """Choix dans la langue du launcher ; un mot de l'autre langue (même rang) est accepté."""
        if value in option["choices"]:
            return value
        other = self.other_schema.get(option["key"], {}).get("choices", [])
        if value in other and other.index(value) < len(option["choices"]):
            return option["choices"][other.index(value)]
        return option["default"]

    def set_option(self, key, value):
        self.values[key] = value
        self.refresh_requires()
        self.settings.setdefault("yaml", {})["options"] = dict(self.values)
        self.save()

    def import_yaml(self):
        """Recharge un YAML déjà fait dans le formulaire ; son nom de slot est aussi enregistré dans
        le jeu (connection.json) si une adresse y est déjà notée."""
        path = filedialog.askopenfilename(filetypes=[("YAML", "*.yaml *.yml"), ("*", "*.*")])
        if not path:
            return
        try:
            name, options = read_yaml(Path(path).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as e:
            self.yaml_msg.configure(text=tr("YAML illisible : ", "Unreadable YAML: ") + str(e), fg=LEVEL_COLORS["bad"])
            return
        known = {o["key"]: o for o in self.schema}
        values = dict(self.values)
        for key, value in options.items():
            option = known.get(key)
            if not option:
                continue
            if option["kind"] == "toggle":
                values[key] = 1 if str(value).lower() in ("true", "1", "on", "yes") else 0
            elif option["kind"] == "choice":
                values[key] = self.choice_value(option, str(value))
            elif option["kind"] == "range" and str(value).lstrip("-").isdigit():
                values[key] = max(option["min"], min(option["max"], int(value)))
        self.settings["yaml"] = {"name": name or self.yaml_name.get().strip(), "options": values}
        self.save()
        game = self.game_dir()
        conn = core.read_connection(game) if game else {}
        in_game = bool(name and conn.get("host"))
        if in_game:
            core.write_connection(game, conn["host"], name, conn.get("password", ""))
        self.show("options")
        self.yaml_msg.configure(text=tr(f"Importé : {Path(path).name}", f"Imported: {Path(path).name}")
                                + (tr(f" — slot « {name} » enregistré dans le jeu.", f" — slot \"{name}\" saved in the game.")
                                   if in_game else ""), fg=LEVEL_COLORS["ok"])

    def refresh_requires(self):
        for option in self.schema:
            parent = option.get("requires")
            if parent:
                on = bool(self.values.get(parent))
                control = self.controls[option["key"]]
                if isinstance(control, Segmented):
                    control.set_enabled(on)
                else:
                    control.configure(state="normal" if on else "disabled")

    def yaml_text(self):
        name = self.yaml_name.get().strip()
        if not name:
            raise ValueError(tr("Entre un nom de slot.", "Enter a slot name."))
        if len(name) > 16:
            raise ValueError(tr("Nom de slot trop long (16 caractères maximum).", "Slot name too long (16 characters max)."))
        self.settings["yaml"] = {"name": name, "options": dict(self.values)}
        self.save()
        lines = [f"name: {json.dumps(name, ensure_ascii=False)}", f"game: {apnet.GAME}", "", f"{apnet.GAME}:"]
        for option in self.schema:
            value = self.values[option["key"]]
            if option["kind"] == "toggle":
                value = "true" if value else "false"
            lines.append(f"  {option['key']}: {value}")
        return "\n".join(lines) + "\n"

    def yaml_result(self, func):
        try:
            text = self.yaml_text()
        except ValueError as e:
            self.yaml_msg.configure(text=str(e), fg=LEVEL_COLORS["bad"])
            return
        message = func(text)
        if message:
            self.yaml_msg.configure(text=message, fg=LEVEL_COLORS["ok"])

    def save_yaml(self):
        def write(text):
            path = filedialog.asksaveasfilename(defaultextension=".yaml", initialfile=f"{self.yaml_name.get().strip()}.yaml",
                                                filetypes=[("YAML", "*.yaml")])
            if not path:
                return None
            Path(path).write_text(text, encoding="utf-8")
            return tr(f"Enregistré : {path} — envoie ce fichier à l'hôte.", f"Saved: {path} — send this file to the host.")
        self.yaml_result(write)

    def copy_yaml(self):
        def copy(text):
            self.clipboard_clear()
            self.clipboard_append(text)
            return tr("Copié dans le presse-papiers.", "Copied to the clipboard.")
        self.yaml_result(copy)

    def yaml_to_players(self):
        def put(text):
            path = self.ap_dir() / "Players" / f"{self.yaml_name.get().strip()}.yaml"
            path.parent.mkdir(exist_ok=True)
            path.write_text(text, encoding="utf-8")
            return tr(f"Enregistré : {path}", f"Saved: {path}")
        self.yaml_result(put)

    # --- Héberger ---

    def page_host(self):
        scroll = Scrollable(self.body)
        scroll.pack(fill="both", expand=True)
        page = tk.Frame(scroll.inner, bg=PANEL, padx=32, pady=26)
        page.pack(fill="both", expand=True)
        self.page_title(page, tr("Héberger une partie", "Host a game"),
                        tr("La génération se fait avec Archipelago installé sur ton PC. Suis les étapes dans l'ordre.",
                           "Generation happens with Archipelago installed on your PC. Follow the steps in order."))
        ap = self.ap_dir()
        world_ok = bool(ap) and (ap / "custom_worlds" / core.APWORLD).exists()

        def step(number, title, text, actions=(), done=None):
            card = tk.Frame(page, bg=CARD, padx=18, pady=14, highlightthickness=1, highlightbackground=BORDER)
            card.pack(fill="x", pady=(0, 12))
            head = tk.Frame(card, bg=CARD)
            head.pack(fill="x")
            tk.Label(head, text=str(number), bg=ACCENT, fg=ON_ACCENT, font=(SANS, 10, "bold"), width=3).pack(side="left")
            label(head, title, 12, bold=True, bg=CARD).pack(side="left", padx=10)
            if done is not None:
                level = "ok" if done else "warn"
                tk.Label(head, text="✔" if done else "…", fg=LEVEL_COLORS[level], bg=CARD, font=(SANS, 12, "bold")
                         ).pack(side="right")
            label(card, text, 9, MUTED, wrap=900, bg=CARD).pack(anchor="w", pady=(6, 8))
            row = tk.Frame(card, bg=CARD)
            row.pack(anchor="w")
            for text_, command, enabled in actions:
                b = Button(row, text_, command, small=True)
                b.set_enabled(enabled)
                b.pack(side="left", padx=(0, 8))

        step(1, tr("Installer Archipelago", "Install Archipelago"),
             tr("Archipelago (le programme officiel) génère et héberge les parties. Indique son dossier dans "
                "Installation s'il n'est pas trouvé tout seul.",
                "Archipelago (the official program) generates and hosts games. Set its folder in Setup if it "
                "is not found automatically."),
             [(tr("Page de téléchargement", "Download page"),
               lambda: webbrowser.open("https://github.com/ArchipelagoMW/Archipelago/releases"), True),
              (tr("Installation", "Setup"), lambda: self.show("install"), True)], done=bool(ap))
        step(2, tr("Installer l'apworld", "Install the apworld"),
             tr("Le fichier qui apprend Resident Evil Village à Archipelago. Le bouton « Installer / mettre à jour » "
                "de l'écran Installation le pose dans custom_worlds. Envoie aussi ce fichier aux autres hôtes "
                "éventuels.", "The file that teaches Archipelago about Resident Evil Village. The \"Install / update\" "
                "button of the Setup screen puts it in custom_worlds."),
             [(tr("Installer l'apworld", "Install the apworld"), self.host_apworld, bool(ap) and core.FILES.exists()),
              (tr("Ouvrir custom_worlds", "Open custom_worlds"),
               lambda: core.open_path(ap / "custom_worlds"), bool(ap) and (ap / "custom_worlds").exists())],
             done=world_ok)
        step(3, tr("Rassembler les YAML", "Collect the YAMLs"),
             tr("Un fichier par joueur (les joueurs de Village le créent dans « Mes options »), à mettre dans le "
                "dossier Players d'Archipelago. Retire les YAML des anciennes parties.",
                "One file per player (Village players create it in \"My options\"), to put in Archipelago's "
                "Players folder. Remove the YAMLs of old games."),
             [(tr("Ouvrir Players", "Open Players"), lambda: self.open_ap_folder("Players"), bool(ap)),
              (tr("Mon YAML", "My YAML"), lambda: self.show("options"), True)])
        step(4, tr("Générer", "Generate"),
             tr("Lance la génération (une fenêtre noire s'ouvre). Le résultat est un fichier AP_....zip dans le "
                "dossier output.", "Starts generation (a console window opens). The result is an AP_....zip "
                "file in the output folder."),
             [(tr("Générer", "Generate"), lambda: self.run_ap("ArchipelagoGenerate.exe"), bool(ap)),
              (tr("Ouvrir output", "Open output"), lambda: self.open_ap_folder("output"), bool(ap))])
        step(5, tr("Héberger la room", "Host the room"),
             tr("Le plus simple : envoie le zip sur archipelago.gg (page « Upload »), puis partage le lien de la room. "
                "Sinon, serveur sur ton PC : les joueurs se connectent à ton adresse IP (port 38281 à ouvrir).",
                "Easiest: upload the zip to archipelago.gg (\"Upload\" page), then share the room link. Otherwise, "
                "server on your PC: players connect to your IP address (port 38281 must be open)."),
             [(tr("archipelago.gg/uploads", "archipelago.gg/uploads"),
               lambda: webbrowser.open("https://archipelago.gg/uploads"), True),
              (tr("Serveur local (dernier zip)", "Local server (latest zip)"), self.local_server, bool(ap))])
        self.host_msg = label(page, "", 10)
        self.host_msg.pack(anchor="w")

    def open_ap_folder(self, name):
        path = self.ap_dir() / name
        path.mkdir(exist_ok=True)
        core.open_path(path)

    def run_ap(self, exe, *args):
        import subprocess
        subprocess.Popen([str(self.ap_dir() / exe), *args], cwd=str(self.ap_dir()))

    def host_apworld(self):
        try:
            core.install_apworld(self.ap_dir(), core.log_line)
        except OSError as e:
            self.host_msg.configure(text=str(e), fg=LEVEL_COLORS["bad"])
            return
        self.show("host")

    def local_server(self):
        zips = sorted((self.ap_dir() / "output").glob("AP_*.zip"), key=lambda p: p.stat().st_mtime)
        if not zips:
            self.host_msg.configure(text=tr("Aucun AP_....zip dans output : génère d'abord.",
                                            "No AP_....zip in output: generate first."), fg=LEVEL_COLORS["bad"])
            return
        self.run_ap("ArchipelagoServer.exe", "--port", "38281", str(zips[-1]))
        self.host_msg.configure(text=tr(f"Serveur lancé sur le port 38281 avec {zips[-1].name}.",
                                        f"Server started on port 38281 with {zips[-1].name}."), fg=LEVEL_COLORS["ok"])

    def on_close(self):
        """Fermeture sans session enregistrée dans le jeu (2026-10-08, demande du joueur) : le jeu
        lancé ensuite ne serait connecté à rien. Proposé de rester sur l'onglet Jouer."""
        if self.current == "play" and self.autosave_job:
            self.after_cancel(self.autosave_job)
            self.autosave()  # dernière modification pas encore écrite
        game = self.game_dir()
        if game and self.mod_ready():
            conn = core.read_connection(game)
            if not (conn.get("host") and conn.get("slot") and conn.get("auto")):
                quit_anyway = messagebox.askyesno(
                    tr("Aucune session Archipelago", "No Archipelago session"),
                    tr("Tu n'as pas entré les informations de ton multiworld (onglet « Jouer »).\n\n"
                       "Si tu lances le jeu, il ne sera connecté à aucune session Archipelago : tu joueras "
                       "normalement, sans objets mélangés ni checks.\n\nQuitter quand même ?",
                       "You have not entered your multiworld details (\"Play\" tab).\n\n"
                       "If you start the game, it will not be connected to any Archipelago session: you will "
                       "play normally, with no shuffled items and no checks.\n\nQuit anyway?"),
                    icon="warning", parent=self)
                if not quit_anyway:
                    self.show("play")
                    return
        self.destroy()

    # --- Bas de fenêtre ---

    def open_logs(self):
        game = self.game_dir()
        path = game / core.DATA_DIR if game and (game / core.DATA_DIR).exists() else core.SETTINGS_DIR
        path.mkdir(parents=True, exist_ok=True)
        core.open_path(path)

    def bug_report(self):
        try:
            path = core.bug_report(self.game_dir())
        except OSError as e:
            self.set_status(tr("Rapport impossible : ", "Report failed: ") + str(e))
            return
        self.set_status(tr(f"Rapport créé : {path} (à envoyer au développeur)", f"Report created: {path} (send it to the developer)"))
        core.open_path(path.parent)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("--install", "--uninstall"):
        game = Path(sys.argv[2])
        ap = Path(sys.argv[3]) if len(sys.argv) > 3 else None
        (core.install if sys.argv[1] == "--install" else core.uninstall)(game, ap, print)
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass
    App().mainloop()


if __name__ == "__main__":
    main()
