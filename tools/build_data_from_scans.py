"""
Construit les données de l'apworld et du client (version 2 : jeu complet).

Sources (toutes relevées en jeu, voir docs/README.md) :
  - docs/reference/scans/*.json                 scans manuels
  - docs/reference/placements_all_*.json        scan automatique cumulé
  - docs/reference/pickups_log_*.jsonl          ramassages (placements jamais scannés)
  - docs/reference/item_catalog_fr.json         noms / catégories des objets
  - docs/reference/shop_duc_complet_fin_*.json  boutique du Duc (tous onglets, fin de partie)
  - docs/reference/plats_du_duc.json            plats du Duc

Sorties :
  - apworld/residentevilvillage/data/{locations,items,regions,region_connections}.json
  - client/reframework/data/re_village_ap_client/{locations,items}.json

Usage : python tools/build_data_from_scans.py
"""

import glob
import json
import re
import statistics
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "docs" / "reference"
APWORLD_DATA = ROOT / "apworld" / "residentevilvillage" / "data"
CLIENT_DATA = ROOT / "client" / "reframework" / "data" / "re_village_ap_client"

# Chemin de dossier -> zone (doit correspondre à la table ZONES du client).
ZONES = [
    ("Chapter2_1/st10", "Village"),
    ("Chapter2_6/st10", "Village"),
    ("c02_ChapterBridge", "Village"),
    ("Chapter2_2/st03", "Chateau Dimitrescu"),
    ("Chapter2_3/st04", "Maison Beneviento"),
    ("Chapter2_4/st05", "Reservoir"),
    ("Chapter2_5/st06", "Usine Heisenberg"),
    ("Chapter2_7/st15", "Usine Heisenberg"),
    ("Chapter3_1/st17", "Chris"),
    ("Chapter3_2/st17", "Fin du jeu"),
]

# Zones impossibles à revisiter après leur boss (confirmé en jeu), et leur chapitre
# (SceneTransitionManager.get_CurrentChapter) : quand le jeu quitte ce chapitre, la zone est
# finie (utilisé par le client pour l'envoi automatique).
MISSABLE_CHAPTERS = {"Chateau Dimitrescu": "Chapter2_2", "Maison Beneviento": "Chapter2_3"}

# Endroits perdus pour de bon à un moment de l'histoire, sans signal détecté par le client
# (pas de changement de chapitre) : leurs locations sont toujours EXCLUES (objets sans
# importance uniquement), pour qu'un check raté ne bloque jamais personne.
#   - Maison de Luiza (2026-09-26) : inaccessible après l'attaque des lycans.
#   - Passage souterrain (2026-09-26) : impossible d'y revenir une fois sorti (signalé par le
#     joueur). Salle "Passage souterrain" (room_hash 1576963686).
#   - Cachots du château (2026-09-29, signalé par le joueur) : sous-sol où Lady Dimitrescu coupe
#     la main, seule zone du château où l'on ne revient jamais. Salles "Château Dimitrescu - -2"
#     (room_hash 255978793) et 1092266347 (room_cache.json).
MISSABLE_SPOTS = {
    "58621acc-ef06-0739-3862-d7ab20f3fa3f": "Maison de Luiza",  # Cartouches de fusil #008
    "135787de-0e66-0c60-1840-e00a000db5d7": "Maison de Luiza",  # Plante #001
    "7859a809-8848-0a36-1334-0dfca58625b8": "Maison de Luiza",  # Sac de Lei #007
    "7fcce40d-6afe-07f7-2116-4ac2c42f2f3c": "Passage souterrain",  # Sac de Lei #002
    "42051e40-eca7-09d4-2f13-d76cb5a98b38": "Passage souterrain",  # Munitions pour pistolet #001
    "01da0e4c-8f1b-0579-1a3c-2ddaa009f8d8": "Cachots du château",  # Sac de Lei #004 [S08]
    "7891c166-8ba8-0f92-014b-d45b537c3059": "Cachots du château",  # Poudre noire #002 [S08]
    "bf57b5f6-4e31-0697-3968-fb9e876ab346": "Cachots du château",  # Fluide chimique #001 [S08]
    "a0ac348d-51ce-036b-2a65-7988878a5936": "Maison du départ",  # Remède de premiers soins #004 [S00]
}
# Checks impossibles à faire en jeu, envoyés tout seuls par le client dès la connexion
# (2026-10-07, choix du joueur : « pas de mur pour 1 petit check »). Remède de premiers soins
# #004 [S00] : emplacement du chapitre 2_6 dans la maison du départ (où l'on prend le couteau),
# fermée au 2e passage ; seulement visible au 1er passage (chapitre 2_1) où ce n'est pas un check.
AUTO_SEND_GUIDS = {"a0ac348d-51ce-036b-2a65-7988878a5936"}
# Envoyés tout seuls quand le jeu QUITTE ce chapitre, quel que soit le mode des zones ratables
# (2026-10-08, choix du joueur : pas de mur pour la maison de Luiza, trop de problèmes).
# Passage souterrain (2026-10-08) : sa porte se referme derrière le joueur et, juste après, le
# jeu est déjà au Chapter2_2 (relevé) -> envoi en quittant le Chapter2_1, pas de mur (un mur
# mal placé après la porte enfermait le joueur).
AUTO_SEND_AFTER = {"Maison de Luiza": "Chapter2_1", "Village (1er passage)": "Chapter2_1",
                   "Passage souterrain": "Chapter2_1"}
# ... et plus tôt, dès qu'un repère est ramassé (2026-10-08, demande du joueur) : maison de Luiza
# -> le Morceau de relief (démon), dans la boîte au tournevis juste après la maison : son check
# fait, ou l'objet lui-même ramassé (ItemID) s'il n'est pas mélangé.
AUTO_SEND_WHEN = {"Maison de Luiza": {"location": "Morceau de relief (démon) #009", "item_id": 1132688171}}

# Objets JAMAIS mélangés (anti-blocage), par nom interne du placement.
#   - couteau et pistolet de départ : premier combat du jeu ;
#   - Manivelle (réservoir) : fuite pendant la poursuite de Moreau ;
#   - Calice des géants et les 4 bocaux de Rose : cœur de l'histoire.
NEVER_RANDOMIZE = {
    "Knife", "HandGunFirst", "HalfFishCrank", "VillageHolyGrail",
    "WitchBodyDonation_Head", "SpiritBodyDonation_Leg", "HalfFishBodyDonation_Arm",
    "GeekBodyDonation_Body",
}

# Catégories du catalogue -> type d'item AP
CATEGORY_TYPES = {
    "Munitions": "Ammo", "Explosif": "Ammo", "Objet de soin": "Recovery",
    "Trésor": "Treasure", "Élément de modification": "Upgrade", "Autre": "Other",
    "Fusil": "Weapon", "Arme de poing": "Weapon", "Fusil sniper": "Weapon",
    "Lance-grenades": "Weapon", "Arme de mêlée": "Weapon", "Magnum": "Weapon",
    "Fusil d'assaut": "Weapon", "Arme unique": "Weapon", "Ingrédient": "Other",
    "": "Craft",
}
# Viandes de chasse (nom, ItemID, rare) et nombre maximal de checks par viande (voir plus bas).
HUNT_MEATS = [("Viande", 3069621231, False), ("Volaille", 3556586016, False), ("Poisson", 471813919, False),
              ("Viande de qualité", 3577251366, True), ("Poisson raffiné", 3524738970, True),
              ("Gibier juteux", 2615454163, True)]
HUNT_MAX_COMMON, HUNT_MAX_RARE = 30, 5
EXCLUDED_CATEGORIES = {"Objet clé"}  # objets clés : traités à part (voir « Objets clés » plus bas)

# --- Objets clés (option randomize_key_items, 2026-09-30) ---
# Logique = ORDRE RÉEL d'une partie complète (docs/reference/pickups_log_20260926.jsonl, partie
# faite d'une traite le 2026-09-26) : un check ramassé au rang N ne demande que les objets clés
# ramassés avant le rang N. Trop prudent parfois, mais jamais bloquant (l'ordre d'origine est
# toujours une solution). Check absent du journal : rang = dernier ramassage de son chapitre.
VANILLA_LOG = "pickups_log_20260926.jsonl"
# Objets clés mélangés : seulement ceux ramassés dans cette partie (un placement jamais ramassé
# peut être du contenu coupé, jamais atteignable). Restent à leur place : cartes (le jeu les
# enregistre au ramassage), photos de chasse et carte au trésor (quêtes du Duc), objets du
# 1er passage au Village (voir KEY_FORBIDDEN_CHAPTERS), NEVER_RANDOMIZE.
KEY_VANILLA_PATTERNS = ("Map", "TreasurePicture")
# Chapitres dont les placements disparaissent une fois quittés (scan du Village 2_6 : aucun
# placement Chapter2_1 chargé) : aucun objet clé ne doit y être placé (il serait perdu).
KEY_FORBIDDEN_CHAPTERS = ("Chapter2_1",)
# Objets clés absents de la partie de référence mais à mélanger quand même (2026-10-07, demande du
# joueur) : Morceau de plaque (tombe du centre du Village, l'autre morceau est déjà sur la tombe).
# Rang = fin de son chapitre ; ajoutés EN FIN de données (ID existants inchangés).
KEY_EXTRA = ("VillageTombStonePlate",)
# Boules des labyrinthes à bille absentes de la partie de référence (2026-10-10, joueur : « la boule
# soleil et lune devant moi, pas en check ») : Boule (soleil et lune) (Village, après la maison
# Beneviento) et, à l'usine, Moule (boule) puis Boule (cheval de fer) coulée avec ce moule. Une
# boule n'ouvre qu'un labyrinthe dont la récompense n'est pas un check (KEY_USE hors d'atteinte).
# Groupe à part, TOUT à la fin (emplacements après ceux du 1er passage, objets après les pièges) :
# aucun numéro existant ne bouge.
KEY_EXTRA_BALLS = ("SpiritBallPuzzleBall", "GeekMoldGeekBallPuzzleBall", "GeekGeekBallPuzzleBall")
# Objets clés du 1er passage au Village (Chapter2_1), mélangés eux aussi (2026-10-08, demande du
# joueur ; le couteau reste à sa place, NEVER_RANDOMIZE). Leurs emplacements n'existent qu'au 1er
# passage (absents des relevés suivants) : jamais d'objet important dessus (missable_spot ->
# EXCLUDED) et envoyés tout seuls en quittant le Chapter2_1 (missable_chapter). Ajoutés EN FIN
# de données (ID existants inchangés).
# Choix du joueur : seulement les deux Morceaux de relief (vierge : église, rang 2 ; démon : boîte
# ouverte au tournevis après la maison de Luiza, rang 30), posés ensemble à la porte ensuite. Le
# Coupe-boulon (ruines de la maison du tout début) et la Clé du pick-up (véhicule de la maison
# de Luiza) restent à leur place.
FIRST_PASS_KEYS = ("VillageReliefSword", "VillageReliefEye")
# Locations qui demandent un objet clé précis en plus de la logique par rang (GUID -> noms).
# Trésor de la tombe du Village (vérifié en jeu le 2026-10-07 : [AP] à la place du Calice).
LOCATION_REQUIRES_KEYS = {
    "af436ade-6c4c-099c-3a12-829036bf901c": ["Morceau de plaque"],  # Calice de Berengario #018
    "e3d4bbec-5d19-035c-216c-f63b7244988e": ["Moule (boule)"],      # Boule (cheval de fer) #008, coulée
}
# Clés ailées (une par niveau) : un seul item « progressif », le client donne le niveau suivant.
CROW_KEYS = ["VillageCrowKey", "VillageCrowKeyLv2", "VillageCrowKey_Lv3", "VillageCrowKey_Lv4"]
CROW_KEY_LEVELS = [808039580, 185799830, 360286557, 847933194]
CROW_KEY_NAME = "Clé ailée (progressive)"
# Rang où chaque objet clé SERT pour la première fois (2026-09-30, d'après le joueur) : une
# location de rang >= ce rang le demande ; l'objet peut être placé sur toute location de rang
# inférieur. Sans entrée : prudent, rang de ramassage + 0,5 (il sert juste après). Rangs du
# journal de référence (pickups_log_20260926.jsonl, voir le README).
KEY_USE = {
    # Château. Bague : la porte s'ouvre au ramassage ; l'œil qu'on en retire ouvre ensuite la porte
    # vers la 1re sœur et le vin (avant le secteur S02, rang 46 ; rangs 40-44 = S00/S01).
    # Morceaux de relief du 1er passage : servent ensemble à la porte, après le relief démon (rang
    # 30) -> placés sur un emplacement ramassé avant (dit par le joueur, 2026-10-08).
    "VillageReliefSword": 31, "VillageReliefEye": 31,
    "WitchJeweledRing": 45,
    "WitchBottleWine": 81,          # énigme du vin (salle à manger) -> Clé de la cour
    "WitchCourtyardKey": 83,        # cour (secteur S03)
    "WitchKey": 111,                # porte de sa chambre -> sous-sol (scripté)
    "WitchBrassJewel": 125,         # piano de l'opéra -> Clé en fer forgé (rang 125)
    "WitchStuffedPlate": 138,       # vissé à la place du masque : 2e porte de la salle de la sœur
    # 4 masques : porte des masques, à la fin du château (secteur S12, rang 172).
    "WitchMouringDeathMask": 171, "WitchPleasureDeathMask": 171,
    "WitchDelightDeathMask": 171, "WitchFuryDeathMask": 171,
    # Morceau de plaque : n'ouvre que la tombe à trésor, qui n'est pas un check -> ne sert à aucune
    # location (rang hors d'atteinte), placé n'importe où.
    "VillageTombStonePlate": 10 ** 6,
    # Boules des labyrinthes (KEY_EXTRA_BALLS) : récompenses hors checks. Le moule sert à couler la
    # Boule (cheval de fer) : son emplacement le demande (LOCATION_REQUIRES_KEYS).
    "SpiritBallPuzzleBall": 10 ** 6, "GeekMoldGeekBallPuzzleBall": 10 ** 6, "GeekGeekBallPuzzleBall": 10 ** 6,
}
# Drops de boss (option boss_drops_as_checks, 2026-09-30, idée du joueur) : certains boss meurent
# dans une scène scriptée, on ne voit pas leur mort ; leur trésor lâché, si. Le N-ième ramassage de
# ce trésor (drop d'ennemi) = le N-ième check de la liste. Rangs = journal de référence.
# (ItemID du trésor, zone, [(rang, boss), ...]). Chris exclu (inventaire à part).
BOSS_DROPS = [
    (2078728602, "Chateau Dimitrescu", [(56, "1re sœur"), (136, "2e sœur"), (156, "3e sœur")]),  # Buste cristallisé
    (3176129225, "Village", [(399, "lycan au marteau")]),                                        # Grand marteau cristallisé
    (3720758584, "Village", [(414, "boss")]),                                                    # Bête ancienne cristallisée
    (1650702965, "Usine Heisenberg", [(519, "boss")]),                                           # Cœur mécanique complexe
]
# Drops de boss hors partie de référence (ajoutés EN FIN de données, ID existants inchangés) :
# (ItemID, zone, boss, position relevée en jeu, rayon de reconnaissance en m, rang, objets clés).
# Le boss lâche son trésor là où il meurt (dans son arène, dit par le joueur) : rayon large, sans
# risque quand le trésor n'est lâché que par ce boss.
# Gardien de la tombe du Village (em1062, 2026-10-07) : apparaît à l'ouverture de la tombe, donc
# derrière le Morceau de plaque (choix du joueur) ; rang = fin du Chapter2_6.
BOSS_DROPS_EXTRA = [
    (1863717, "Village", "gardien de la tombe", [-203.56, -34.51, 51.37], 60, 415.5, ["Morceau de plaque"]),  # Grande hache cristallisée
]
CHAPTER_RE = re.compile(r"(Chapter\d_\d|c02_ChapterBridge)")

# Boutique : catégories vendues une seule fois (checks) et armes vendues uniquement par le Duc.
SHOP_CHECK_CATEGORIES = {"Autre", "Élément de modification"}
SHOP_ONLY_WEAPONS = {"V61 Custom", "SYG-12"}
SHOP_EXCLUDED_NAMES = {"Accessoire d'arme Mr. Everywhere"}  # bonus DLC
MONEY_NAME = "Sac de Lei"
MONEY_ITEM_ID = 3196868754


def zone_of(folder):
    for pattern, name in ZONES:
        if pattern in (folder or ""):
            return name
    return None


def internal_name(obj):
    return re.sub(r"^SpawnInfo_|_\d+$", "", obj)


def load_placements():
    placements = {}
    for f in sorted(glob.glob(str(REF / "scans" / "*.json"))):
        for p in json.loads(Path(f).read_text(encoding="utf-8")).get("placements", []):
            if p.get("guid"):
                placements.setdefault(p["guid"], p)
    for f in sorted(glob.glob(str(REF / "placements_all_*.json"))):
        for guid, p in json.loads(Path(f).read_text(encoding="utf-8")).items():
            if isinstance(p, dict):
                placements.setdefault(guid, p)
    for f in sorted(glob.glob(str(REF / "pickups_log_*.jsonl"))):
        for line in Path(f).read_text(encoding="utf-8").splitlines():
            p = json.loads(line)
            if p.get("guid") and p.get("item_object") and p["guid"] not in placements:
                p = dict(p)
                p["item_id"] = p.get("item_id") or p.get("picked_item_id")
                placements[p["guid"]] = p
    return placements


def chapter_of(folder):
    m = CHAPTER_RE.search(folder or "")
    return m.group(1) if m else None


def load_vanilla_order():
    """GUID -> rang du 1er ramassage dans la partie de référence, et dernier rang par chapitre."""
    order, chapter_end = {}, {}
    for i, line in enumerate((REF / VANILLA_LOG).read_text(encoding="utf-8").splitlines()):
        p = json.loads(line)
        ch = chapter_of(p.get("folder_path") or (p.get("pool_object") or {}).get("folder_path"))
        if ch:
            chapter_end[ch] = i
        if p.get("guid") and p["guid"] not in order:
            order[p["guid"]] = i
    return order, chapter_end


def main():
    catalog = json.loads((REF / "item_catalog_fr.json").read_text(encoding="utf-8"))

    def raw_name(item_id):
        name = catalog.get(str(item_id), {}).get("name") or f"Objet {item_id}"
        return MONEY_NAME if "{0}" in name else name

    def category(item_id):
        return catalog.get(str(item_id), {}).get("category") or ""

    # Noms provisoires (ItemID) ; les noms lisibles sont posés à la fin, en ne distinguant que
    # les objets UTILISÉS qui partagent un même nom (ex. munitions d'Ethan et de Chris).
    def item_name(item_id):
        return MONEY_NAME if raw_name(item_id) == MONEY_NAME else f"@{int(item_id)}"

    locations, items, stacks = [], {}, {}

    def add_item(item_id, stack):
        name = item_name(item_id)
        if name not in items:
            cat = category(item_id)
            items[name] = {"name": name, "type": "Money" if name == MONEY_NAME else CATEGORY_TYPES.get(cat, "Other"),
                           "game_item_id": MONEY_ITEM_ID if name == MONEY_NAME else int(item_id), "category": cat,
                           # Description du jeu, affichée par le client chez le Duc (2026-09-26).
                           "description": catalog.get(str(item_id), {}).get("info") or ""}
        stacks.setdefault(name, []).append(stack or 1)
        return name

    vanilla_order, chapter_end = load_vanilla_order()

    def order_of(guid, folder):
        if guid in vanilla_order:
            return vanilla_order[guid]
        return chapter_end.get(chapter_of(folder), max(chapter_end.values())) + 0.5

    key_placements = []

    # --- Objets posés dans le monde ---
    for guid, p in load_placements().items():
        obj = p.get("item_object", "")
        item_id = p.get("item_id")
        if not item_id or obj.startswith("ItemSpawnInfo"):
            continue  # drops d'ennemis, d'animaux, caisses aléatoires
        zone = zone_of(p.get("folder_path"))
        if zone and category(item_id) in EXCLUDED_CATEGORIES and internal_name(obj) not in NEVER_RANDOMIZE:
            key_placements.append((guid, p, zone))
        if not zone or internal_name(obj) in NEVER_RANDOMIZE or category(item_id) in EXCLUDED_CATEGORIES:
            continue
        original = add_item(item_id, p.get("stack"))
        number = re.search(r"_(\d+)$", obj)
        sector = re.search(r"Separetor_(\d+)$", p.get("folder_path") or "")
        where = p.get("room") or (f"S{sector.group(1)}" if sector else "")
        name = original + (f" #{number.group(1)}" if number else "") + (f" [{where}]" if where else "")
        loc = {"name": name, "region": zone, "kind": "world", "original_item": original, "guid": guid,
               "item_object": obj, "folder_path": p.get("folder_path"), "item_position": p.get("item_position")}
        if p.get("room_hash"):
            loc["room_hash"] = p["room_hash"]
        if zone in MISSABLE_CHAPTERS:
            loc["missable"] = True
            loc["missable_chapter"] = MISSABLE_CHAPTERS[zone]
        if guid in MISSABLE_SPOTS:
            loc["missable_spot"] = MISSABLE_SPOTS[guid]
        if guid in AUTO_SEND_GUIDS:
            loc["auto_send"] = True
        if loc.get("missable_spot") in AUTO_SEND_AFTER:
            loc["auto_send_after"] = AUTO_SEND_AFTER[loc["missable_spot"]]
        if loc.get("missable_spot") in AUTO_SEND_WHEN:
            loc["auto_send_when"] = AUTO_SEND_WHEN[loc["missable_spot"]]
        if zone == "Chris":
            loc["chris"] = True
        loc["order"] = order_of(guid, p.get("folder_path"))
        if chapter_of(p.get("folder_path")) in KEY_FORBIDDEN_CHAPTERS:
            loc["no_key_items"] = True
        # Meubles à crocheter (2026-09-30 : Sanguis Virginis dans la commode de l'Ange en bois #004
        # [S11], joueur sans Crochet = bloqué). Pas repérables dans les relevés ; ce qu'on y trouve
        # est presque toujours un trésor : aucun objet clé sur un emplacement de trésor.
        if CATEGORY_TYPES.get(category(item_id)) == "Treasure":
            loc["no_key_items"] = True
        locations.append(loc)

    # --- Boutique du Duc ---
    # Rang d'arrivée de chaque article (2026-10-10, softlock d'un joueur : la logique croyait la
    # boutique ouverte dès le départ) : 1er relevé où l'article apparaît, au rang de la partie de
    # référence où ce relevé est sûr d'être atteint. 1re rencontre du Duc juste avant le château
    # (après le Morceau de relief (démon), rang 31) ; après le château : compté seulement après la
    # cinématique du Duc (Cric + Volant + Clé à quatre ailes, rang 230.5), moment exact inconnu.
    shop_stage_files = [("shop_duc_chateau_*.json", 37.9), ("shop_duc_complet_village2_*.json", 231),
                        ("shop_duc_complet_reservoir_*.json", 332), ("shop_duc_complet_apres_forteresse_*.json", 416),
                        ("shop_duc_complet_usine_*.json", 522.9), ("shop_duc_complet_fin_*.json", 545.9)]
    shop_stages = []
    for pattern, stage_order in shop_stage_files:
        snap = json.loads(sorted(REF.glob(pattern))[-1].read_text(encoding="utf-8"))
        if "units" in snap:  # relevé du château : autre format
            snap = {str(u["item_id"]): u for u in snap["units"].values() if isinstance(u, dict)}
        shop_stages.append(({k: max(1, u.get("stock", 1)) for k, u in snap.items()}, stage_order))
    shop = json.loads(sorted(REF.glob("shop_duc_complet_fin_*.json"))[-1].read_text(encoding="utf-8"))
    for iid, unit in shop.items():
        name = raw_name(iid)
        if name in SHOP_EXCLUDED_NAMES:
            continue
        if category(iid) not in SHOP_CHECK_CATEGORIES and name not in SHOP_ONLY_WEAPONS:
            continue
        original = add_item(iid, 1)
        stock = max(1, unit.get("stock", 1))
        for n in range(stock):
            locations.append({"name": f"Duc - {original}" + (f" {n + 1}" if stock > 1 else ""),
                              "region": "Boutique du Duc", "kind": "shop", "original_item": original,
                              "shop_item_id": int(iid), "price": unit.get("price", 0), "shop_index": n,
                              "inventory_expansion": name == "Valise",
                              # n-ième exemplaire (Valises) : 1er relevé où le stock le contient
                              "order": next(o for stocks, o in shop_stages if stocks.get(str(iid), 0) > n)})

    # --- Plats du Duc (bonus vanilla conservé ; un sac de Lei dans le pool) ---
    recipes = json.loads((REF / "plats_du_duc.json").read_text(encoding="utf-8"))
    for rid, r in recipes.items():
        locations.append({"name": f"Duc - Plat : {r.get('title') or rid}", "region": "Boutique du Duc",
                          "kind": "recipe", "recipe_id": int(rid), "original_item": MONEY_NAME,
                          "order": 231})  # plats : après la cinématique du Duc (rang 230.5)
    if MONEY_NAME not in items:
        items[MONEY_NAME] = {"name": MONEY_NAME, "type": "Money", "game_item_id": MONEY_ITEM_ID, "category": ""}

    # Noms lisibles des items
    used_ids_by_name = {}
    for key, item in items.items():
        if key != MONEY_NAME:
            used_ids_by_name.setdefault(raw_name(item["game_item_id"]), []).append(item["game_item_id"])
    rename = {}
    for key, item in items.items():
        if key == MONEY_NAME:
            continue
        base = raw_name(item["game_item_id"])
        if len(used_ids_by_name[base]) > 1:
            rank = sorted(used_ids_by_name[base]).index(item["game_item_id"]) + 1
            base = f"{base} ({'Chris' if key in {l['original_item'] for l in locations if l.get('chris')} else rank})"
        rename[key] = base
    items = {rename.get(k, k): {**v, "name": rename.get(k, k)} for k, v in items.items()}
    stacks = {rename.get(k, k): v for k, v in stacks.items()}
    for loc in locations:
        old = loc["original_item"]
        loc["original_item"] = rename.get(old, old)
        loc["name"] = loc["name"].replace(old, loc["original_item"], 1)

    counts = Counter(loc["name"] for loc in locations)
    for loc in locations:
        if counts[loc["name"]] > 1:
            loc["name"] += f" ({(loc.get('guid') or str(loc.get('shop_index')))[:8]})"

    for name, item in items.items():
        item["quantity"] = int(statistics.median(stacks.get(name, [1])))
    items[MONEY_NAME]["quantity"] = 500  # un sac du Village contient 500 Lei

    # Items propres à Chris : placés uniquement sur les locations de Chris (voir __init__.py).
    chris_items = {loc["original_item"] for loc in locations if loc.get("chris")}
    other_items = {loc["original_item"] for loc in locations if not loc.get("chris")}
    for name in chris_items - other_items:
        items[name]["chris_only"] = True

    item_list = sorted(items.values(), key=lambda i: i["name"]) + [{"name": "Victory", "type": "Event"}]
    locations.append({"name": "Victory", "region": "Fin du jeu", "force_item": "Victory"})

    # --- Objets clés : ajoutés APRÈS Victory, pour que les ID des items et des locations
    # existants ne bougent pas (2026-09-30) ---
    key_items, key_locations, crow_orders = {}, [], []
    extra_key_items, extra_key_locations = {}, []
    first_key_items, first_key_locations = {}, []
    ball_key_items, ball_key_locations = {}, []
    for guid, p, zone in sorted(key_placements, key=lambda t: vanilla_order.get(t[0], 1e9)):
        obj = internal_name(p.get("item_object", ""))
        first_pass = obj in FIRST_PASS_KEYS and chapter_of(p.get("folder_path")) == "Chapter2_1"
        ball = guid not in vanilla_order and obj in KEY_EXTRA_BALLS
        extra = (guid not in vanilla_order and obj in KEY_EXTRA) or first_pass or ball
        if (guid not in vanilla_order and not extra) or any(k in obj for k in KEY_VANILLA_PATTERNS):
            continue
        if chapter_of(p.get("folder_path")) in KEY_FORBIDDEN_CHAPTERS and not first_pass:
            continue
        order = order_of(guid, p.get("folder_path"))
        if first_pass:
            key_items, key_locations, saved = first_key_items, first_key_locations, (key_items, key_locations)
        elif ball:
            key_items, key_locations, saved = ball_key_items, ball_key_locations, (key_items, key_locations)
        elif extra:
            key_items, key_locations, saved = extra_key_items, extra_key_locations, (key_items, key_locations)
        # Énigmes de la maison Beneviento : option à part. La clé ailée de la maison n'en est pas
        # une (clé progressive, toujours mélangée avec les objets clés).
        beneviento = zone == "Maison Beneviento" and obj not in CROW_KEYS
        if obj in CROW_KEYS:
            name = CROW_KEY_NAME
            crow_orders.append(order)
        else:
            name = raw_name(p["item_id"])
            if name in key_items or name in items:
                name = f"{name} ({obj})"
            key_items[name] = {"name": name, "type": "Key", "game_item_id": int(p["item_id"]),
                               "category": "Objet clé", "quantity": 1, "key_item": True,
                               "key_order": order, "key_use": KEY_USE.get(obj, order + 0.5),
                               "key_zone": zone, "internal": obj,
                               "description": catalog.get(str(p["item_id"]), {}).get("info") or ""}
            if beneviento:
                key_items[name]["beneviento"] = True
        number = re.search(r"_(\d+)$", p.get("item_object", ""))
        sector = re.search(r"Separetor_(\d+)$", p.get("folder_path") or "")
        where = p.get("room") or (f"S{sector.group(1)}" if sector else "")
        loc_name = raw_name(p["item_id"]) + (f" #{number.group(1)}" if number else "") + (f" [{where}]" if where else "")
        loc = {"name": loc_name, "region": zone, "kind": "world", "key_item_location": True,
               "original_item": name, "guid": guid, "item_object": p.get("item_object"),
               "folder_path": p.get("folder_path"), "item_position": p.get("item_position"), "order": order}
        if p.get("room_hash"):
            loc["room_hash"] = p["room_hash"]
        if beneviento:
            loc["beneviento"] = True
        if zone in MISSABLE_CHAPTERS:
            loc["missable"] = True
            loc["missable_chapter"] = MISSABLE_CHAPTERS[zone]
        if first_pass:
            loc["missable_spot"] = "Village (1er passage)"
            loc["missable_chapter"] = "Chapter2_1"
            loc["auto_send_after"] = AUTO_SEND_AFTER["Village (1er passage)"]
            loc["no_key_items"] = True
        key_locations.append(loc)
        if extra:
            key_items, key_locations = saved
    if crow_orders:
        key_items[CROW_KEY_NAME] = {
            "name": CROW_KEY_NAME, "type": "Key", "progressive": True, "key_item": True, "quantity": 1,
            "category": "Objet clé", "key_zone": "Village", "key_orders": sorted(crow_orders),
            "key_uses": [o + 0.5 for o in sorted(crow_orders)],
            # N-ième exemplaire reçu = niveau N (Clé ailée, à quatre ailes, fœtus à quatre ailes,
            # fœtus à six ailes). game_item_id = 1er niveau.
            "levels": CROW_KEY_LEVELS, "game_item_id": CROW_KEY_LEVELS[0],
            "description": "Chaque exemplaire reçu donne le niveau suivant de la clé ailée.",
        }
    taken = {loc["name"] for loc in locations}
    for loc in key_locations:
        if loc["name"] in taken:
            loc["name"] += f" ({loc['guid'][:8]})"
        taken.add(loc["name"])
    item_list += sorted(key_items.values(), key=lambda i: i["name"])
    locations += key_locations

    # --- Drops de boss (ajoutés à la fin : ID existants inchangés) ---
    boss_items = {}
    # Position de chaque drop dans la partie de référence : le client rattache un drop ramassé à la
    # position la plus proche (2026-10-01 : 1re sœur retuée après rechargement comptée « 2e sœur »).
    ref_lines = (REF / VANILLA_LOG).read_text(encoding="utf-8").splitlines()
    for item_id, zone, drops in BOSS_DROPS:
        name = raw_name(item_id)
        if name not in items and name not in boss_items:
            boss_items[name] = {"name": name, "type": CATEGORY_TYPES.get(category(item_id), "Other"),
                                "game_item_id": item_id, "category": category(item_id), "quantity": 1,
                                "description": catalog.get(str(item_id), {}).get("info") or ""}
        for n, (rank, boss) in enumerate(drops, start=1):
            loc = {"name": f"Boss - {name} ({boss})", "region": zone, "kind": "bossdrop",
                   "original_item": name, "drop_item_id": item_id, "drop_index": n, "order": rank,
                   "no_key_items": True,
                   "drop_position": json.loads(ref_lines[rank]).get("item_position")}
            if zone in MISSABLE_CHAPTERS:
                loc["missable"] = True
                loc["missable_chapter"] = MISSABLE_CHAPTERS[zone]
            locations.append(loc)
    item_list += sorted(boss_items.values(), key=lambda i: i["name"])

    # --- Checks de chasse (2026-10-07, choix du joueur) : ramasser une viande. Checks AU COMPTE
    # (« Chasse - Viande #3 » = 3e Viande ramassée), pas par animal. Toutes les locations
    # possibles sont écrites (HUNT_MAX) ; l'option hunting_* de l'apworld choisit combien sont
    # actives. Jamais d'objet de progression dessus (no_key_items + exclues côté apworld).
    have = {i["name"] for i in item_list}
    for name, item_id, rare in HUNT_MEATS:
        if name not in have:
            item_list.append({"name": name, "type": CATEGORY_TYPES.get(category(item_id), "Other"),
                              "game_item_id": item_id, "category": category(item_id), "quantity": 1,
                              "description": catalog.get(str(item_id), {}).get("info") or ""})
        for n in range(1, (HUNT_MAX_RARE if rare else HUNT_MAX_COMMON) + 1):
            locations.append({"name": f"Chasse - {name} #{n}", "region": "Village", "kind": "hunt",
                              "original_item": name, "hunt_item_id": item_id, "hunt_index": n,
                              "hunt_rare": rare, "no_key_items": True})

    # --- Objets clés hors partie de référence (KEY_EXTRA, 2026-10-07) : à la fin, ID inchangés ---
    for loc in extra_key_locations:
        if loc["name"] in taken:
            loc["name"] += f" ({loc['guid'][:8]})"
        taken.add(loc["name"])
    have = {i["name"] for i in item_list}
    item_list += sorted((i for i in extra_key_items.values() if i["name"] not in have), key=lambda i: i["name"])
    locations += extra_key_locations
    have = {i["name"] for i in item_list}
    for item_id, zone, boss, position, radius, rank, keys in BOSS_DROPS_EXTRA:
        name = raw_name(item_id)
        if name not in have:
            item_list.append({"name": name, "type": CATEGORY_TYPES.get(category(item_id), "Other"),
                              "game_item_id": item_id, "category": category(item_id), "quantity": 1,
                              "description": catalog.get(str(item_id), {}).get("info") or ""})
            have.add(name)
        loc = {"name": f"Boss - {name} ({boss})", "region": zone, "kind": "bossdrop",
               "original_item": name, "drop_item_id": item_id, "drop_index": 1, "order": rank,
               "no_key_items": True, "drop_position": position, "drop_radius": radius, "requires_keys": keys}
        if zone in MISSABLE_CHAPTERS:
            loc["missable"] = True
            loc["missable_chapter"] = MISSABLE_CHAPTERS[zone]
        locations.append(loc)

    # --- Objets clés du 1er passage (2026-10-08) : tout à la fin, ID existants inchangés ---
    for loc in first_key_locations:
        if loc["name"] in taken:
            loc["name"] += f" ({loc['guid'][:8]})"
        taken.add(loc["name"])
    have = {i["name"] for i in item_list}
    item_list += sorted((i for i in first_key_items.values() if i["name"] not in have), key=lambda i: i["name"])
    locations += first_key_locations

    # --- Boules des labyrinthes (KEY_EXTRA_BALLS, 2026-10-10) : emplacements tout à la fin ---
    for loc in ball_key_locations:
        if loc["name"] in taken:
            loc["name"] += f" ({loc['guid'][:8]})"
        taken.add(loc["name"])
    locations += ball_key_locations

    for loc in locations:
        if loc.get("guid") in LOCATION_REQUIRES_KEYS:
            loc["requires_keys"] = LOCATION_REQUIRES_KEYS[loc["guid"]]
            loc["no_key_items"] = True  # sinon l'objet demandé pourrait y être placé (pre_fill)

    region_names = ["Village", "Chateau Dimitrescu", "Maison Beneviento", "Reservoir", "Usine Heisenberg",
                    "Chris", "Fin du jeu", "Boutique du Duc"]
    regions = [{"name": r} for r in region_names]
    connections = [{"from": "Menu", "to": "Village"}] + [{"from": "Village", "to": r} for r in region_names[1:]]

    # Pièges (2026-10-08, idées du joueur) : à la toute fin, pour ne décaler aucun numéro. Effets
    # dans le client (shop_ui.traps), remplacement d'objets de remplissage dans l'apworld.
    item_list += [{"name": name, "type": "Trap", "trap": key, "quantity": 1} for name, key in (
        ("Piège : Faillite", "bankrupt"), ("Piège : Screamer", "screamer"), ("Piège : Armes bloquées", "jam"),
        ("Piège : Dégâts", "damage"), ("Piège : Chargeur vidé", "empty_mag"))]
    # Boules des labyrinthes : objets après les pièges (numéros existants inchangés)
    have = {i["name"] for i in item_list}
    item_list += sorted((i for i in ball_key_items.values() if i["name"] not in have), key=lambda i: i["name"])

    def dump(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    dump(APWORLD_DATA / "locations.json", locations)
    dump(APWORLD_DATA / "items.json", item_list)
    dump(APWORLD_DATA / "regions.json", regions)
    dump(APWORLD_DATA / "region_connections.json", connections)
    dump(CLIENT_DATA / "locations.json", locations)
    dump(CLIENT_DATA / "items.json", item_list)

    by_kind = Counter(loc.get("kind", "event") for loc in locations)
    print(f"{len(locations) - 1} locations {dict(by_kind)}, {len(item_list) - 1} items"
          f" (dont {len(key_locations)} objets clés, {len(key_items)} items clés)")
    for region, n in Counter(loc["region"] for loc in locations if loc.get("kind")).most_common():
        print(f"  {region}: {n}")


if __name__ == "__main__":
    main()
