import json
import os
import pkgutil

from .lang import LANG

# Pattern repris du world Resident Evil 2 Remake existant sur cette install Archipelago
# (D:\Archipelago\custom_worlds\residentevil2remake.apworld), lui-même inspiré du world
# Minecraft. Simplifié ici : RE Village n'a pas de split personnage/scénario comme RE2R,
# donc un seul jeu de données est chargé (pas de boucle load_data(character, scenario)).

def load_data_file(*args) -> dict:
    data_directory = "data"
    fname = os.path.join(data_directory, *args)

    try:
        filedata = json.loads(pkgutil.get_data(__name__, fname).decode())
    except Exception:
        filedata = []

    return filedata


# Version EN (2026-10-08) : data/names_en.json (tools/make_names_en.py, noms officiels relevés en
# jeu) donne le nom anglais de chaque objet, région et check. Les données restent en français ; la
# traduction est faite au chargement, quand l'apworld est construit avec LANG = "en". Les numéros
# ne changent pas (rang dans les fichiers).
NAMES_EN = None


def names_en():
    global NAMES_EN
    if NAMES_EN is None:
        NAMES_EN = load_data_file('names_en.json') if LANG == "en" else {}
        if not isinstance(NAMES_EN, dict):
            NAMES_EN = {}
    return NAMES_EN


def T(name):
    """Nom d'objet dans la langue de l'apworld (le nom français sert de clé)."""
    return names_en().get('items', {}).get(name, name) if name else name


def R(name):
    """Nom de région dans la langue de l'apworld."""
    return names_en().get('regions', {}).get(name, name) if name else name


def L(name):
    """Nom de check (sans la région) dans la langue de l'apworld."""
    return names_en().get('locations', {}).get(name, name) if name else name


class Data:
    item_table = []
    location_table = []
    region_table = []
    region_connections_table = []

    item_name_groups = {}

    _loaded = False

    # Base d'ID choisie arbitrairement dans la plage haute recommandée pour les worlds
    # custom, pour limiter le risque de collision avec d'autres jeux dans un multiworld.
    # TODO : vérifier qu'aucun autre apworld installé (cf. D:\Archipelago\custom_worlds
    # et D:\Archipelago\lib\worlds) n'utilise déjà une plage qui chevauche celle-ci.
    BASE_ID = 3908000000

    @staticmethod
    def load_data():
        if Data._loaded:
            return

        Data._loaded = True

        # --- Régions ---
        Data.region_table = [{**r, 'name': R(r['name'])} for r in load_data_file('regions.json')]

        # --- Connexions entre régions ---
        Data.region_connections_table = []
        for c in load_data_file('region_connections.json'):
            c = {**c, 'from': R(c['from']), 'to': R(c['to'])}
            if 'condition' in c and 'items' in c['condition']:
                c['condition'] = {**c['condition'], 'items': [T(i) for i in c['condition']['items']]}
            Data.region_connections_table.append(c)

        # --- Items ---
        new_item_table = load_data_file('items.json')
        Data.item_table = [
            {**item, 'name': T(item['name']), 'key_zone': R(item.get('key_zone')),
             'id': (Data.BASE_ID + key) if item.get('type') != 'Event' else None}
            for key, item in enumerate(new_item_table)
        ]

        for item in Data.item_table:
            for group_name in item.get('groups', []):
                Data.item_name_groups.setdefault(group_name, []).append(item['name'])

        # --- Locations ---
        # Une location avec 'force_item' (ex: Victory) est une location "événement" :
        # elle n'est pas envoyée sur le réseau AP, donc son id doit rester None,
        # convention standard Archipelago pour ce genre de location.
        new_location_table = load_data_file('locations.json')
        location_start = Data.BASE_ID + 1000000000
        Data.location_table = []
        for key, loc in enumerate(new_location_table):
            loc = {**loc, 'name': L(loc['name']), 'region': R(loc['region']),
                   'original_item': T(loc.get('original_item')),
                   'id': None if 'force_item' in loc else location_start + key}
            if 'force_item' in loc:
                loc['force_item'] = T(loc['force_item'])
            if 'requires_keys' in loc:
                loc['requires_keys'] = [T(k) for k in loc['requires_keys']]
            Data.location_table.append(loc)
