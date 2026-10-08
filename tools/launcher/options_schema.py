"""
Options de l'apworld pour l'écran « Mes options » du launcher, dans les deux langues.

Options.py est exécuté avec de fausses classes d'Archipelago (pas besoin d'Archipelago installé) :
une fois avec LANG = "fr", une fois avec LANG = "en". make_release.py écrit le résultat dans
files/options.json ({"fr": [...], "en": [...]}) ; en développement, le launcher appelle build().
"""

import inspect
import json
import re
import sys
import types
from dataclasses import dataclass
from pathlib import Path

OPTIONS_PY = Path(__file__).resolve().parents[2] / "apworld" / "residentevilvillage" / "Options.py"

# Libellés des choix (avec accents ; sinon : clé avec des espaces).
CHOICE_LABELS = {
    "fr": {"normale": "Normale", "articles_uniques": "Articles uniques", "articles_et_valises": "Articles et valises",
           "a_leur_place": "À leur place", "dans_leur_zone": "Dans leur zone", "zone_ou_multiworld": "Zone ou multiworld",
           "exclues": "Exclues", "envoi_auto": "Envoi automatique", "cent_pourcent": "Mode 100 %",
           "au_choix": "Au choix", "facile": "Facile", "village_des_ombres": "Village des ombres",
           "fin_du_jeu": "Fin du jeu", "les_4_seigneurs": "Les 4 Seigneurs"},
    "en": {"unique_items_and_cases": "Unique items and cases", "own_zone": "Own zone",
           "zone_or_multiworld": "Zone or multiworld", "auto_send": "Auto send", "hundred_percent": "100% mode",
           "village_of_shadows": "Village of Shadows", "game_ending": "Game ending", "four_lords": "Four Lords"},
}
DEATHLINK_DOC = {"fr": "Quand tu meurs, les autres joueurs avec DeathLink meurent aussi, et inversement.",
                 "en": "When you die, everyone else with DeathLink dies too, and the other way round."}


def _stub_module():
    """Faux module Options d'Archipelago : juste ce qu'utilise notre Options.py."""
    m = types.ModuleType("Options")

    class Option:
        default = 0

    class Toggle(Option):
        default = 0

    class DefaultOnToggle(Toggle):
        default = 1

    class Range(Option):
        range_start, range_end = 0, 1

    class Choice(Option):
        pass

    class DeathLink(Toggle):
        display_name = "DeathLink"

    class PerGameCommonOptions:
        pass

    for cls in (Toggle, DefaultOnToggle, Range, Choice, DeathLink, PerGameCommonOptions):
        setattr(m, cls.__name__, cls)
    return m


def _reflow(doc):
    """Docstring -> paragraphes ; une ligne « choix : ... » commence une ligne."""
    out = []
    for line in inspect.cleandoc(doc or "").splitlines():
        line = line.strip()
        if not line:
            continue
        if out and not re.match(r"^[\w/ ]+ ?: ", line):
            out[-1] += " " + line
        else:
            out.append(line)
    return "\n".join(out)


def build_lang(lang, path=OPTIONS_PY):
    stub = _stub_module()
    source = Path(path).read_text(encoding="utf-8").replace("from .lang import LANG", f"LANG = {lang!r}")
    saved = sys.modules.get("Options")
    sys.modules["Options"] = stub
    try:
        namespace = {"__name__": "re_village_options_" + lang}
        exec(compile(source, str(path), "exec"), namespace)
    finally:
        if saved is None:
            sys.modules.pop("Options", None)
        else:
            sys.modules["Options"] = saved
    labels = CHOICE_LABELS.get(lang, {})
    options = []
    for key, cls in namespace["REVillageOptions"].__annotations__.items():
        if issubclass(cls, stub.DeathLink):
            options.append({"key": key, "kind": "toggle", "display": "DeathLink", "default": 0, "doc": DEATHLINK_DOC[lang]})
            continue
        option = {"key": key, "display": getattr(cls, "display_name", key), "doc": _reflow(cls.__doc__),
                  "default": cls.default}
        if issubclass(cls, stub.Toggle):
            option["kind"] = "toggle"
        elif issubclass(cls, stub.Range):
            option.update(kind="range", min=cls.range_start, max=cls.range_end)
        else:
            choices = sorted(((v, k[len("option_"):]) for k, v in vars(cls).items() if k.startswith("option_")))
            option.update(kind="choice", choices=[name for _, name in choices],
                          labels=[labels.get(name, name.replace("_", " ").capitalize()) for _, name in choices])
            option["default"] = dict(choices)[cls.default]
        options.append(option)
    return options


def build():
    return {"fr": build_lang("fr"), "en": build_lang("en")}


if __name__ == "__main__":
    out = build()
    if len(sys.argv) > 1:
        Path(sys.argv[1]).write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    else:
        print(json.dumps(out, indent=1, ensure_ascii=False))
