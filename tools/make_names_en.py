"""
Construit apworld/residentevilvillage/data/names_en.json : nom anglais de chaque objet, région et
check de l'apworld (version EN, 2026-10-08).

Source des noms officiels : docs/reference/names_fr_en.json, relevé en jeu (outil de dev « Relever
les noms FR / EN » : objets par ItemID, salles, plats du Duc). Nos propres mots (régions de
l'apworld, « Chasse », « Duc », descriptions des boss...) sont traduits ici.

Noms des checks : même construction qu'en français, partie par partie :
  monde    <objet> #005 [S01] / [<salle>] (<hash>)   -> objet et salle traduits
  chasse   Chasse - <viande> #3                       -> Hunting - <meat> #3
  boutique Duc - <objet> / Duc - Valise 2             -> Duke - <item> / Duke - Extra Baggage 2
  plat     Duc - Plat : <plat>                        -> Duke - Dish: <dish>
  boss     Boss - <objet> (<qui>)                     -> Boss - <item> (<who>)
Échoue si un nom n'a pas de traduction ou si deux checks ont le même nom anglais.

Usage : python tools/make_names_en.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "apworld" / "residentevilvillage" / "data"
DUMP = ROOT / "docs" / "reference" / "names_fr_en.json"

REGIONS = {
    "Village": "Village", "Chateau Dimitrescu": "Castle Dimitrescu", "Maison Beneviento": "House Beneviento",
    "Reservoir": "Reservoir", "Usine Heisenberg": "Heisenberg's Factory", "Chris": "Chris",
    "Fin du jeu": "Endgame", "Boutique du Duc": "Duke's Shop", "Menu": "Menu",
}
# Objets dont le nom du jeu ne suffit pas (nom inventé par nous, ou nom du jeu avec un paramètre).
ITEMS = {"Victory": "Victory", "Sac de Lei": "Lei Bag", "Piège : Faillite": "Trap: Bankruptcy",
         "Piège : Screamer": "Trap: Screamer", "Piège : Armes bloquées": "Trap: Jammed Weapons",
         "Piège : Dégâts": "Trap: Damage", "Piège : Chargeur vidé": "Trap: Empty Magazine"}
BOSS_WHO = {"1re sœur": "1st sister", "2e sœur": "2nd sister", "3e sœur": "3rd sister", "boss": "boss",
            "lycan au marteau": "hammer lycan", "gardien de la tombe": "tomb guardian"}


def build():
    dump = json.loads(DUMP.read_text(encoding="utf-8"))
    items = json.loads((DATA / "items.json").read_text(encoding="utf-8"))
    locations = json.loads((DATA / "locations.json").read_text(encoding="utf-8"))
    rooms = {r["fr"]: r["en"] for r in dump["rooms"]}
    dishes = {r["fr"]: r["en"] for r in dump["recipes"]}
    game_names = {e["fr"]: e["en"] for e in dump["items"].values() if e.get("en")}
    errors = []

    item_en = {}
    for item in items:
        fr = item["name"]
        if fr in ITEMS:
            item_en[fr] = ITEMS[fr]
            continue
        entry = dump["items"].get(str(item.get("game_item_id")))
        if not entry or not entry.get("en"):
            errors.append(f"objet sans nom anglais : {fr}")
            continue
        en = entry["en"]
        # suffixes ajoutés par nous au nom du jeu : (1) / (2) pour les exemplaires, (progressive)
        suffix = fr[len(entry["fr"]):] if fr.startswith(entry["fr"]) else ""
        suffix = suffix.replace("(progressive)", "(Progressive)")
        item_en[fr] = en + suffix

    def room(label):
        if re.fullmatch(r"S\d+", label):
            return label
        if label not in rooms:
            errors.append(f"salle sans nom anglais : {label}")
        return rooms.get(label, label)

    location_en = {}
    for loc in locations:
        fr, kind = loc["name"], loc.get("kind")
        en = None
        if fr == "Victory":
            en = "Victory"
        elif kind == "hunt":
            m = re.fullmatch(r"Chasse - (.+?) (#\d+)", fr)
            en = f"Hunting - {item_en.get(m.group(1), m.group(1))} {m.group(2)}" if m else None
        elif kind == "recipe":
            m = re.fullmatch(r"Duc - Plat : (.+)", fr)
            en = f"Duke - Dish: {dishes[m.group(1)]}" if m and m.group(1) in dishes else None
        elif kind == "shop":
            m = re.fullmatch(r"Duc - Valise (\d+)", fr)
            if m:
                en = f"Duke - {item_en['Valise']} {m.group(1)}"
            elif fr.startswith("Duc - ") and fr[6:] in item_en:
                en = "Duke - " + item_en[fr[6:]]
        elif kind == "bossdrop":
            m = re.fullmatch(r"Boss - (.+) \(([^)]+)\)", fr)
            if m and m.group(1) in item_en and m.group(2) in BOSS_WHO:
                en = f"Boss - {item_en[m.group(1)]} ({BOSS_WHO[m.group(2)]})"
        else:
            original = loc.get("original_item", "")
            prefix = None
            if fr.startswith(original) and original in item_en:
                prefix = (original, item_en[original])
            else:
                # nom du jeu de l'objet posé là (ex. « Clé à quatre ailes » pour la Clé ailée
                # progressive) : le plus long nom du relevé par lequel commence le check
                for name_fr, name_en in game_names.items():
                    if fr.startswith(name_fr + " ") and (prefix is None or len(name_fr) > len(prefix[0])):
                        prefix = (name_fr, name_en)
            if prefix:
                rest = fr[len(prefix[0]):]
                rest = re.sub(r"\[([^\]]+)\]", lambda m: "[" + room(m.group(1)) + "]", rest)
                en = prefix[1] + rest
        if en is None:
            errors.append(f"check sans nom anglais : {fr}")
            continue
        location_en[fr] = en

    full = {}
    for loc in locations:
        if loc["name"] in location_en:
            key = "Victory" if loc["name"] == "Victory" else REGIONS[loc["region"]] + " - " + location_en[loc["name"]]
            if key in full:
                errors.append(f"nom anglais en double : {key} ({full[key]} / {loc['name']})")
            full[key] = loc["name"]
    if len(set(item_en.values())) != len(item_en):
        seen = {}
        for fr, en in item_en.items():
            if en in seen:
                errors.append(f"objet anglais en double : {en} ({seen[en]} / {fr})")
            seen[en] = fr
    if errors:
        sys.exit("\n".join(errors))
    out = {"regions": REGIONS, "items": item_en, "locations": location_en}
    (DATA / "names_en.json").write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"names_en.json : {len(item_en)} objets, {len(location_en)} checks, {len(REGIONS)} régions")


if __name__ == "__main__":
    build()
