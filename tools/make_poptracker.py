"""
Construit le pack PopTracker de RE Village Archipelago (2026-10-12, demande du développeur).

Usage : python tools/make_poptracker.py
Sortie : build/poptracker/RE_Village_AP/ et build/poptracker/RE_Village_AP_<version>.zip
(à mettre dans le dossier packs de PopTracker, https://github.com/black-sliver/PopTracker).

Tout vient des données de l'apworld (apworld/residentevilvillage/data) :
  - numéros Archipelago : objets = BASE_ID + rang dans items.json, checks = BASE_ID + 10^9 + rang
    dans locations.json (comme Data.py) ;
  - logique = celle de l'apworld (set_rules) : un check de rang N demande les objets clés qui servent
    à un rang <= N (key_use), plus requires_keys ; plats du Duc : toutes les viandes mélangées ;
  - checks visibles selon les options de la partie (slot_data lu à la connexion) ;
  - cartes : vues du dessus GÉNÉRÉES à partir des positions des checks (pas d'images du jeu) ; un
    point par salle (texte entre crochets du nom du check).
Variantes : « fr » et « en » (noms des checks et des objets dans la langue de l'apworld).
"""

import json
import math
import re
import shutil
import unicodedata
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "apworld" / "residentevilvillage" / "data"
OUT = ROOT / "build" / "poptracker" / "RE_Village_AP"
BASE_ID = 3908000000
LOC_BASE = BASE_ID + 1000000000

# Copie de l'apworld (__init__.py) : objets clés jamais mélangés, besoins des plats en viande.
VANILLA_KEY_ITEMS = {"Masque du chagrin", "Masque du plaisir", "Masque de la joie", "Masque de la colère",
                     "Trophée de chasse", "Clé de Dimitrescu"}
HUNT_RECIPE_NEEDS = {"Poisson": 14, "Volaille": 12, "Viande": 12}
# Options par défaut de l'apworld (Options.py), utilisées tant que le tracker n'est pas connecté.
DEFAULTS = {"key_items": 0, "duke_shop": 2, "hunting": 100, "boss_rewards": 1}

GOLD, BG, BG2, GREY = (214, 175, 92), (18, 16, 20), (34, 30, 36), (120, 110, 100)
FONT = "C:/Windows/Fonts/arialbd.ttf"
MAP_W = 1400
CLUSTER_M = 12
MISC_ZONE = "Duc, chasse et boss"
REGION_EN = {"Village": "Village", "Chateau Dimitrescu": "Castle Dimitrescu", "Maison Beneviento": "House Beneviento",
             "Reservoir": "Reservoir", "Usine Heisenberg": "Heisenberg's Factory", "Chris": "Chris",
             "Fin du jeu": "Ending", MISC_ZONE: "Duke, hunting and bosses"}


MISC_EN = {"Duc - articles": "Duke - items", "Duc - plats": "Duke - dishes", "Boss": "Bosses", "Autres": "Other",
           "Chasse - Viande": "Hunting - Meat", "Chasse - Volaille": "Hunting - Poultry", "Chasse - Poisson": "Hunting - Fish",
           "Chasse - Viande de qualité": "Hunting - Quality Meat", "Chasse - Poisson raffiné": "Hunting - Fine Fish",
           "Chasse - Gibier juteux": "Hunting - Juicy Game"}


def font(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def slug(text):
    t = unicodedata.normalize("NFKD", text.lower()).encode("ascii", "ignore").decode()
    t = re.sub(r"[^a-z0-9]+", "_", t)
    return t.strip("_") or "x"


def clean(text):
    return text.replace("/", "-")


def icon(path, label, color=GOLD):
    """Icône d'objet générée : initiales sur fond sombre, bord doré."""
    img = Image.new("RGBA", (64, 64), BG + (255,))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((1, 1, 62, 62), 8, outline=color, width=3)
    words = [w for w in re.split(r"[\s()'\-]+", label) if w and w.lower() not in ("de", "du", "la", "le", "des", "à", "en", "d", "l", "of", "the")]
    short = "".join(w[0] for w in words[:3]).upper() or label[:2].upper()
    f = font(24 if len(short) <= 2 else 19)
    w = d.textlength(short, font=f)
    d.text(((64 - w) / 2, 18), short, fill=color, font=f)
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)


def chest(path, opened):
    img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((3, 7, 28, 27), 4, fill=(60, 55, 50, 255) if opened else (150, 105, 40, 255),
                        outline=GREY if opened else GOLD, width=2)
    d.line((3, 15, 28, 15), fill=GREY if opened else GOLD, width=2)
    img.save(path)


def main():
    items = json.loads((DATA / "items.json").read_text(encoding="utf-8"))
    locations = json.loads((DATA / "locations.json").read_text(encoding="utf-8"))
    names_en = json.loads((DATA / "names_en.json").read_text(encoding="utf-8"))
    version = json.loads((DATA.parent / "archipelago.json").read_text(encoding="utf-8"))["world_version"]
    en = lambda name: names_en.get(name, name)

    # contenu vidé, dossier gardé (il peut être le dossier courant d'un terminal ou ouvert ailleurs)
    OUT.mkdir(parents=True, exist_ok=True)
    for p in OUT.iterdir():
        shutil.rmtree(p) if p.is_dir() else p.unlink()
    (OUT / "images").mkdir(parents=True)
    chest(OUT / "images" / "chest_closed.png", False)
    chest(OUT / "images" / "chest_opened.png", True)

    # --- Objets suivis : objets clés, viandes, Crochet illimité, Valise ; options (cachées) ---
    item_by_name = {it["name"]: it for it in items}
    item_id = {it["name"]: BASE_ID + i for i, it in enumerate(items) if it.get("type") != "Event"}
    key_locs = [l for l in locations if l.get("key_item_location")]
    shuffled_keys = sorted({l["original_item"] for l in key_locs
                            if l["original_item"] not in VANILLA_KEY_ITEMS and not l.get("beneviento")})
    meats = ["Viande", "Volaille", "Poisson", "Viande de qualité", "Poisson raffiné", "Gibier juteux"]
    code = {name: "k_" + slug(name) for name in shuffled_keys}
    code.update({name: "m_" + slug(name) for name in meats})
    code["Crochet illimité"] = "lockpick"
    code["Valise"] = "valise"

    def item_defs(lang):
        tr = (lambda n: n) if lang == "fr" else en
        out = []
        for name in shuffled_keys + meats + ["Crochet illimité", "Valise"]:
            it = item_by_name[name]
            img = f"images/items/{code[name]}.png"
            icon(OUT / img, name, GOLD if name in shuffled_keys else (150, 200, 150))
            if it.get("progressive"):
                out.append({"name": tr(name), "type": "consumable", "img": img, "codes": code[name],
                            "max_quantity": len(it.get("levels", [])) or 4})
            elif name in meats or name == "Valise":
                out.append({"name": tr(name), "type": "consumable", "img": img, "codes": code[name],
                            "max_quantity": 99 if name in meats else 3})
            else:
                out.append({"name": tr(name), "type": "toggle", "img": img, "codes": code[name]})
        icon(OUT / "images/items/opt.png", "Opt", GREY)
        for opt, value in DEFAULTS.items():
            out.append({"name": "option " + opt, "type": "consumable", "img": "images/items/opt.png",
                        "codes": "opt_" + opt, "min_quantity": 0, "max_quantity": 1000, "initial_quantity": value})
        return out

    # --- Logique (comme set_rules de l'apworld, objets clés mélangés) ---
    def key_uses(it):
        if it.get("progressive"):
            return sorted(it.get("key_uses") or [o + 0.5 for o in it["key_orders"]])
        return [it.get("key_use", it["key_order"] + 0.5)]

    def requirements(loc):
        order = loc.get("order")
        needed = {}
        if order is not None:
            for name in shuffled_keys:
                n = sum(1 for u in key_uses(item_by_name[name]) if u <= order)
                if n:
                    needed[name] = n
        for name in loc.get("requires_keys", ()):
            if name in code:
                needed.setdefault(name, 1)
        return ",".join(f"{code[n]}:{c}" if c > 1 else code[n] for n, c in sorted(needed.items()))

    # --- Checks rangés par zone puis par salle ---
    groups = {}
    for i, loc in enumerate(locations):
        if "force_item" in loc:
            continue
        kind = loc.get("kind", "world")
        if loc.get("key_item_location") and (loc["original_item"] in VANILLA_KEY_ITEMS or loc.get("beneviento")):
            continue  # jamais mélangés : pas des checks
        if kind in ("shop", "recipe", "hunt", "bossdrop") or not loc.get("item_position"):
            zone = MISC_ZONE
            room = {"shop": "Duc - articles", "recipe": "Duc - plats", "bossdrop": "Boss"}.get(kind)
            if kind == "hunt":
                room = "Chasse - " + loc["original_item"]
            room = room or "Autres"
        else:
            zone = loc["region"]
            m = re.search(r"\[([^\]]+)\]", loc["name"])
            room = m.group(1) if m else zone
        groups.setdefault(zone, {}).setdefault(room, []).append((i, loc))

    # Une salle étalée (secteur S08 : lac, puits...) donnait un point loin de tous ses checks :
    # découpée en groupes de checks à moins de CLUSTER_M mètres (vue du dessus), « S08 (2) »...
    for zone, rooms in groups.items():
        if zone == MISC_ZONE:
            continue
        split = {}
        for room, entries in rooms.items():
            clusters = []
            for e in entries:
                p = e[1]["item_position"]
                best = None
                for c in clusters:
                    cx = sum(q[1]["item_position"][0] for q in c) / len(c)
                    cz = sum(q[1]["item_position"][2] for q in c) / len(c)
                    if math.hypot(p[0] - cx, p[2] - cz) < CLUSTER_M:
                        best = c
                        break
                if best is None:
                    clusters.append([e])
                else:
                    best.append(e)
            for k, c in enumerate(clusters):
                split[room if len(clusters) == 1 else f"{room} ({k + 1})"] = c
        groups[zone] = split

    def visibility(loc):
        kind = loc.get("kind")
        if loc.get("key_item_location"):
            return "$keys_shuffled"
        if kind == "shop":
            return "$shop_valises" if loc.get("inventory_expansion") else "$shop_items"
        if kind == "bossdrop":
            return "$boss_rewards"
        if kind == "hunt":
            return f"$hunt_active|{loc['original_item']}|{loc.get('hunt_index', 1)}|{1 if loc.get('hunt_rare') else 0}"
        return None

    # --- Cartes générées (vue du dessus, x / z des checks) ---
    maps, map_points = [], {}
    for zone, rooms in groups.items():
        if zone == MISC_ZONE:
            names = sorted(rooms)
            cols = 3
            w, h = MAP_W, 160 + 140 * math.ceil(len(names) / cols)
            img = Image.new("RGB", (w, h), BG)
            d = ImageDraw.Draw(img)
            d.text((30, 25), zone, fill=GOLD, font=font(40))
            for k, room in enumerate(names):
                x, y = 60 + (k % cols) * (w // cols), 140 + (k // cols) * 140
                d.rounded_rectangle((x - 20, y - 20, x + w // cols - 80, y + 70), 10, fill=BG2, outline=GREY, width=2)
                d.text((x + 40, y + 8), room, fill=(230, 220, 200), font=font(26))
                map_points[(zone, room)] = (x + 10, y + 25)
        else:
            pts = [loc["item_position"] for room in rooms.values() for _, loc in room]
            xs, zs = [p[0] for p in pts], [p[2] for p in pts]
            minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
            span = max(maxx - minx, maxz - minz, 1)
            scale = (MAP_W - 200) / span
            w = int((maxx - minx) * scale) + 200
            h = int((maxz - minz) * scale) + 260
            img = Image.new("RGB", (w, h), BG)
            d = ImageDraw.Draw(img)
            d.text((30, 25), zone, fill=GOLD, font=font(40))
            d.text((30, 75), "Vue du dessus générée à partir des positions des checks / generated top-down view",
                   fill=GREY, font=font(18))
            proj = lambda p: (100 + (p[0] - minx) * scale, 160 + (maxz - p[2]) * scale)
            for room, entries in rooms.items():
                rp = [proj(loc["item_position"]) for _, loc in entries]
                for x, y in rp:
                    d.ellipse((x - 3, y - 3, x + 3, y + 3), fill=(70, 62, 55))
                cx, cy = sum(p[0] for p in rp) / len(rp), sum(p[1] for p in rp) / len(rp)
                map_points[(zone, room)] = (int(cx), int(cy))
                # (pas d'étiquette : PopTracker montre le nom du point au survol)
        name = "map_" + slug(zone)
        img.save(OUT / "images" / f"{name}.png")
        maps.append({"name": name, "location_size": 22, "location_border_thickness": 2,
                     "img": f"images/{name}.png", "zone": zone})

    # --- Fichiers par langue ---
    for lang in ("fr", "en"):
        tr = (lambda n: n) if lang == "fr" else (lambda n: MISC_EN.get(n) or en(n))
        zone_name = (lambda z: z) if lang == "fr" else (lambda z: REGION_EN.get(z, z))
        vdir = OUT / lang
        locs_json, id_map = [], {}
        for zone, rooms in groups.items():
            mapname = "map_" + slug(zone)
            for room, entries in sorted(rooms.items()):
                loc_name = clean(f"{zone_name(zone)} - {tr(room) if zone == MISC_ZONE else room}")
                sections = []
                for i, loc in entries:
                    sec = {"name": clean(tr(loc["name"])), "item_count": 1}
                    req = requirements(loc)
                    rules = ["$keys_vanilla", req] if req else []
                    if loc.get("kind") == "recipe":
                        rules = [r + ",$meats" for r in rules] or ["$meats"]
                    if rules:
                        sec["access_rules"] = rules
                    vis = visibility(loc)
                    if vis:
                        sec["visibility_rules"] = [vis]
                    sections.append(sec)
                    id_map[LOC_BASE + i] = f"@{loc_name}/{sec['name']}"
                x, y = map_points[(zone, room)]
                locs_json.append({"name": loc_name, "chest_unopened_img": "images/chest_closed.png",
                                  "chest_opened_img": "images/chest_opened.png",
                                  "map_locations": [{"map": mapname, "x": x, "y": y}], "sections": sections})
        (vdir / "locations").mkdir(parents=True)
        (vdir / "items").mkdir(parents=True)
        (vdir / "scripts").mkdir(parents=True)
        (vdir / "locations" / "locations.json").write_text(json.dumps(locs_json, ensure_ascii=False, indent=1), encoding="utf-8")
        (vdir / "items" / "items.json").write_text(json.dumps(item_defs(lang), ensure_ascii=False, indent=1), encoding="utf-8")
        lines = ["-- généré par tools/make_poptracker.py", "LOCATION_MAPPING = {"]
        lines += [f"  [{lid}] = {json.dumps(path, ensure_ascii=False)}," for lid, path in sorted(id_map.items())]
        lines.append("}")
        (vdir / "scripts" / "ids.lua").write_text("\n".join(lines) + "\n", encoding="utf-8")

    # objets suivis : numéro AP -> code (communs aux deux langues)
    lines = ["-- généré par tools/make_poptracker.py", "ITEM_MAPPING = {"]
    for name, c in code.items():
        if name in item_id:
            lines.append(f"  [{item_id[name]}] = {json.dumps(c)},")
    lines.append("}")
    lines.append("MEAT_CODES = {" + ", ".join(f"[{json.dumps(m, ensure_ascii=False)}] = {json.dumps(code[m])}" for m in meats) + "}")
    lines.append("HUNT_NEEDS = {" + ", ".join(f"[{json.dumps(m, ensure_ascii=False)}] = {n}" for m, n in HUNT_RECIPE_NEEDS.items()) + "}")
    (OUT / "scripts").mkdir()
    (OUT / "scripts" / "items_map.lua").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (OUT / "scripts" / "logic.lua").write_text(LOGIC_LUA, encoding="utf-8")
    (OUT / "scripts" / "autotracking.lua").write_text(AUTOTRACKING_LUA, encoding="utf-8")
    (OUT / "scripts" / "init.lua").write_text(INIT_LUA, encoding="utf-8")

    (OUT / "maps").mkdir()
    (OUT / "maps" / "maps.json").write_text(json.dumps([{k: v for k, v in m.items() if k != "zone"} for m in maps],
                                                      ensure_ascii=False, indent=1), encoding="utf-8")
    # --- Disposition : objets à gauche, cartes en onglets à droite ---
    keys_rows = [[code[n] for n in shuffled_keys[i:i + 6]] for i in range(0, len(shuffled_keys), 6)]
    other_row = [code[m] for m in meats] + ["lockpick", "valise"]
    tabs = [{"title": m["zone"], "content": {"type": "map", "maps": [m["name"]]}} for m in maps]
    layout = {
        "tracker_default": {"type": "container", "background": "#121014", "content": {
            "type": "dock", "dropshadow": True, "content": [
                {"type": "dock", "dock": "left", "v_alignment": "stretch", "content": [
                    {"type": "group", "header": "Objets clés / Key items", "dock": "top",
                     "content": {"type": "itemgrid", "item_margin": "2,2", "rows": keys_rows}},
                    {"type": "group", "header": "Viandes, Crochet, Valise", "dock": "top",
                     "content": {"type": "itemgrid", "item_margin": "2,2", "rows": [other_row[:6], other_row[6:]]}}]},
                {"type": "tabbed", "tabs": tabs}]}},
        "tracker_broadcast": {"type": "itemgrid", "item_margin": "2,2", "rows": keys_rows + [other_row]},
    }
    (OUT / "layouts").mkdir()
    (OUT / "layouts" / "tracker.json").write_text(json.dumps(layout, ensure_ascii=False, indent=1), encoding="utf-8")

    manifest = {
        "name": "Resident Evil Village Archipelago", "game_name": "Resident Evil Village",
        "package_uid": "re_village_archipelago_snokayy", "package_version": version, "platform": "pc",
        "author": "Snokayy", "min_poptracker_version": "0.25.6", "target_poptracker_version": "0.35.4",
        "variants": {"fr": {"display_name": "Français", "flags": ["ap"]},
                     "en": {"display_name": "English", "flags": ["ap"]}},
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")

    target = OUT.parent / f"RE_Village_AP_poptracker_{version}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(OUT.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(OUT).as_posix())
    n_checks = sum(len(e) for r in groups.values() for e in r.values())
    print(f"pack {version} : {n_checks} checks, {len(maps)} cartes, {len(code)} objets suivis -> {target}")


INIT_LUA = """-- RE Village Archipelago : pack généré par tools/make_poptracker.py
ScriptHost:LoadScript("scripts/items_map.lua")
ScriptHost:LoadScript("scripts/logic.lua")
Tracker:AddItems("items/items.json")
Tracker:AddMaps("maps/maps.json")
ScriptHost:LoadScript("scripts/ids.lua")
Tracker:AddLocations("locations/locations.json")
Tracker:AddLayouts("layouts/tracker.json")
if Archipelago then
    ScriptHost:LoadScript("scripts/autotracking.lua")
end
"""

LOGIC_LUA = """-- Règles (mêmes options que l'apworld, lues dans slot_data à la connexion)
local function opt(name)
    local o = Tracker:FindObjectForCode("opt_" .. name)
    return o and o.AcquiredCount or 0
end
function keys_vanilla() return opt("key_items") == 0 end
function keys_shuffled() return opt("key_items") ~= 0 end
function shop_items() return opt("duke_shop") >= 1 end
function shop_valises() return opt("duke_shop") == 2 end
function boss_rewards() return opt("boss_rewards") ~= 0 end
-- checks de chasse actifs : les N premiers de chaque viande (rares : 1)
local function hunt_limit(meat, rare)
    local pct = opt("hunting")
    if pct == 0 then return 0 end
    if rare then return 1 end
    -- arrondi de Python (round : 10,5 -> 10, 11,5 -> 12), comme l'apworld
    local x = (HUNT_NEEDS[meat] or 12) * pct / 100
    local f = math.floor(x)
    local r = (x - f == 0.5) and (f % 2 == 0 and f or f + 1) or math.floor(x + 0.5)
    return math.max(1, r)
end
function hunt_active(meat, index, rare)
    return tonumber(index) <= hunt_limit(meat, rare == "1")
end
-- plats du Duc : toutes les viandes mises dans le pool par la chasse
function meats()
    if opt("hunting") == 0 then return true end
    for meat, c in pairs(MEAT_CODES) do
        local rare = meat ~= "Viande" and meat ~= "Volaille" and meat ~= "Poisson"
        if Tracker:ProviderCountForCode(c) < hunt_limit(meat, rare) then return false end
    end
    return true
end
"""

AUTOTRACKING_LUA = """-- Suivi automatique Archipelago
local function reset()
    for _, c in pairs(ITEM_MAPPING) do
        local o = Tracker:FindObjectForCode(c)
        if o then
            if o.Type == "consumable" then o.AcquiredCount = 0 else o.Active = false end
        end
    end
    for _, path in pairs(LOCATION_MAPPING) do
        local s = Tracker:FindObjectForCode(path)
        if s then s.AvailableChestCount = s.ChestCount end
    end
end

local function set_opt(name, value)
    local o = Tracker:FindObjectForCode("opt_" .. name)
    if o and value ~= nil then
        if type(value) == "boolean" then value = value and 1 or 0 end
        o.AcquiredCount = tonumber(value) or 0
    end
end

function on_clear(slot_data)
    Tracker.BulkUpdate = true
    pcall(reset)
    if slot_data then
        set_opt("key_items", slot_data.key_items)
        set_opt("duke_shop", slot_data.duke_shop)
        set_opt("hunting", slot_data.hunting)
        set_opt("boss_rewards", slot_data.boss_rewards)
    end
    Tracker.BulkUpdate = false
end

function on_item(index, item_id, item_name, player)
    local c = ITEM_MAPPING[item_id]
    if not c then return end
    local o = Tracker:FindObjectForCode(c)
    if not o then return end
    if o.Type == "consumable" then o.AcquiredCount = o.AcquiredCount + 1 else o.Active = true end
end

function on_location(location_id, location_name)
    local path = LOCATION_MAPPING[location_id]
    if not path then return end
    local s = Tracker:FindObjectForCode(path)
    if s then s.AvailableChestCount = 0 end
end

Archipelago:AddClearHandler("clear", on_clear)
Archipelago:AddItemHandler("item", on_item)
Archipelago:AddLocationHandler("location", on_location)
"""

if __name__ == "__main__":
    main()
