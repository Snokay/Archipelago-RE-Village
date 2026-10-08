"""
APWorld pour Resident Evil Village.

Architecture calquée sur les worlds RE2R / RE7 (github.com/FuzzyGamesOn/RE2R_AP_World,
github.com/ElGrenier/RE7_AP_World) : régions, connexions, items et locations sont décrits en
JSON dans data/, chargés une fois par Data.load_data(), puis assemblés ici.

Les fichiers de data/ sont GÉNÉRÉS par tools/build_data_from_scans.py à partir des scans
faits en jeu (docs/reference/scans/) : ne pas les éditer à la main.

Version 1 : Village uniquement. Chaque location est un placement d'objet du jeu (identifié
par son GUID), et le pool d'items est formé des objets d'origine de ces locations.

Objets clés (option key_items, 2026-09-30) : leurs placements deviennent des locations
et ils sont mélangés. Logique = ordre d'une vraie partie (champ "order" des locations, rang de
ramassage) : une location de rang N demande les objets clés ramassés avant le rang N.
"""

import typing
from typing import Dict, Any

from BaseClasses import ItemClassification, Item, Location, LocationProgressType, Region
from worlds.AutoWorld import World
from ..generic.Rules import set_rule, add_item_rule

from .Data import Data, T
from .Exceptions import REVillageOptionError
from .Options import REVillageOptions
from .lang import LANG


Data.load_data()


class REVillageLocation(Location):
    game: str = "Resident Evil Village"

    @staticmethod
    def stack_names(*names):
        return " - ".join(names)

    @staticmethod
    def stack_names_not_victory(*names):
        if names[-1] == "Victory":
            return "Victory"
        return REVillageLocation.stack_names(*names)


class ResidentEvilVillage(World):
    """
    Un mod Archipelago pour Resident Evil Village : Ethan Winters explore un village
    d'Europe de l'Est, affronte les quatre Seigneurs de Mère Miranda, et envoie/reçoit
    des items avec le reste du multiworld au lieu de progresser seul.
    """
    game: str = "Resident Evil Village"

    data_version = 1
    apworld_release_version = "0.9.2"  # alpha publique (2026-10-08) ; X.Y.Z exigé par Archipelago 0.7

    item_name_to_id = {
        item['name']: item['id']
        for item in Data.item_table
        if item['id'] is not None
    }
    item_name_to_item = {item['name']: item for item in Data.item_table}

    location_name_to_id = {
        REVillageLocation.stack_names_not_victory(loc['region'], loc['name']): loc['id']
        for loc in Data.location_table
        if loc['id'] is not None
    }
    location_name_to_location = {
        REVillageLocation.stack_names_not_victory(loc['region'], loc['name']): loc
        for loc in Data.location_table
    }

    item_name_groups = {
        key: set(values) for key, values in Data.item_name_groups.items()
    }

    options_dataclass = REVillageOptions
    options: REVillageOptions

    def _has_items(self, state, item_names):
        return state.has_all(set(item_names), self.player)

    def create_regions(self):
        regions = [
            Region(region['name'], self.player, self.multiworld)
            for region in Data.region_table
        ]
        # Toujours une région "Menu" comme point de départ, comme dans les autres worlds AP.
        regions.append(Region("Menu", self.player, self.multiworld))

        active = self._active_locations()
        for region in regions:
            region.locations = [
                REVillageLocation(
                    self.player,
                    REVillageLocation.stack_names_not_victory(region.name, loc['name']),
                    loc['id'],
                    region,
                )
                for loc in active
                if loc['region'] == region.name
            ]

            for location in region.locations:
                location_data = self.location_name_to_location.get(location.name)

                if location_data and 'force_item' in location_data:
                    location.place_locked_item(self.create_item(location_data['force_item']))

                # Chasse : faisable à des moments très différents selon l'animal -> jamais d'objet
                # de progression dessus (objets « bonus » seulement).
                if location_data and location_data.get('kind') == 'hunt':
                    location.progress_type = LocationProgressType.EXCLUDED

                # Endroit perdu pour de bon sans signal détectable (ex. maison de Luiza) :
                # toujours exclu, un check raté n'y bloque jamais personne.
                if location_data and location_data.get('missable_spot'):
                    location.progress_type = LocationProgressType.EXCLUDED

                # Zone qu'on ne peut plus revisiter après son boss (voir option missable_checks).
                # Les objets clés de la zone sont sur le chemin obligatoire : jamais exclus.
                if location_data and location_data.get('missable') \
                        and not location_data.get('key_item_location') \
                        and self.options.missable_checks.value == 0:  # exclues
                    location.progress_type = LocationProgressType.EXCLUDED

            self.multiworld.regions.append(region)

        for connection in Data.region_connections_table:
            region_from = self.multiworld.get_region(connection['from'], self.player)
            region_to = self.multiworld.get_region(connection['to'], self.player)
            entrance = region_from.connect(region_to)

            if 'condition' in connection and 'items' in connection['condition']:
                set_rule(
                    entrance,
                    lambda state, cond=connection: self._has_items(state, cond['condition']['items'])
                )

        self.multiworld.completion_condition[self.player] = \
            lambda state: self._has_items(state, ['Victory'])

    # Objets clés jamais mélangés (2026-10-06, choix du joueur) : masques et Trophée de chasse du
    # château restent à leur place d'origine (deux Masques du plaisir affichés, bugs de
    # présentation). Leurs emplacements ne sont pas des locations ; le jeu les gère normalement.
    # Clé de la cour : reste mélangée (2026-10-07, choix du joueur). Reçue du multiworld sans poser
    # le vin, la vidange (salle des statues) ne se lançait jamais : le client bloque l'entrée de
    # cette salle tant que l'énigme du vin n'est pas faite (mur « vin à poser »).
    # Clé de Dimitrescu (2026-10-07, choix du joueur) : on la trouve DANS ses appartements, qu'on
    # ne peut quitter qu'avec elle ; mélangée, le joueur entré sans elle restait enfermé (et
    # l'emplacement n'a même pas fait apparaître d'objet). Gardée à sa place.
    VANILLA_KEY_ITEMS = {T(name) for name in (
        "Masque du chagrin", "Masque du plaisir", "Masque de la joie", "Masque de la colère",
        "Trophée de chasse", "Clé de Dimitrescu",
    )}

    @staticmethod
    def _no_key_items(data):
        """Location qui ne reçoit jamais un de mes objets clés. Sacs de Lei (2026-10-06, choix du
        joueur) : objet clé reçu mais sans présentation plein écran (le jeu traite l'emplacement
        comme de l'argent), voir docs/README.md."""
        return bool(data.get('no_key_items')) or data.get('original_item') == T("Sac de Lei")

    # Viandes communes demandées par les 6 recettes du Duc (dit par le joueur, 2026-10-07) : nombre
    # de checks de chasse à 100 %.
    HUNT_RECIPE_NEEDS = {T("Poisson"): 14, T("Volaille"): 12, T("Viande"): 12}

    # Pièges (nom français, option de poids)
    TRAP_OPTIONS = [("Piège : Faillite", "trap_bankrupt_weight"), ("Piège : Screamer", "trap_screamer_weight"),
                    ("Piège : Armes bloquées", "trap_jam_weight"), ("Piège : Dégâts", "trap_damage_weight"),
                    ("Piège : Chargeur vidé", "trap_empty_mag_weight")]

    def _active_locations(self):
        """Locations actives selon les options (boutique, agrandissements d'inventaire, objets clés)."""
        result = []
        for loc in Data.location_table:
            if loc.get('key_item_location'):
                if not self._keys_shuffled():
                    continue
                if loc.get('original_item') in self.VANILLA_KEY_ITEMS:
                    continue
                # énigmes de la maison Beneviento : jamais mélangées (option retirée le 2026-10-07)
                if loc.get('beneviento'):
                    continue
            if loc.get('kind') == 'bossdrop' and not self.options.boss_rewards:
                continue
            # Checks de chasse (2026-10-07) : les N premiers de chaque viande (option hunting, en %
            # de ce que demandent les plats ; 0 = pas de chasse).
            if loc.get('kind') == 'hunt':
                if self.options.hunting.value == 0:
                    continue
                # rares : 1 check chacune (recettes du Duc : 1 de chaque, 2026-10-07)
                limit = 1 if loc.get('hunt_rare') else max(1, round(
                    self.HUNT_RECIPE_NEEDS.get(loc.get('original_item'), 12) * self.options.hunting.value / 100))
                if loc.get('hunt_index', 0) > limit:
                    continue
            if loc.get('kind') == 'shop':
                if self.options.duke_shop.value == 0:  # normale
                    continue
                if loc.get('inventory_expansion') and self.options.duke_shop.value != 2:  # sans les valises
                    continue
            result.append(loc)
        return result

    # --- Objets clés ---

    def _key_items(self):
        """Items clés mélangés dans cette partie : nom -> fiche items.json."""
        if not self._keys_shuffled():
            return {}
        names = {loc['original_item'] for loc in self._active_locations() if loc.get('key_item_location')}
        return {name: self.item_name_to_item[name] for name in names}

    @staticmethod
    def _key_uses(item):
        """Rangs où l'objet clé sert (un par exemplaire). Une location de rang >= ce rang le
        demande ; il peut être placé sur une location de rang inférieur (champ key_use, données)."""
        if item.get('progressive'):
            return sorted(item.get('key_uses') or [o + 0.5 for o in item['key_orders']])
        return [item.get('key_use', item['key_order'] + 0.5)]

    def _key_requirements(self, order):
        """Objets clés (nom, nombre) nécessaires pour une location de rang `order`."""
        needed = []
        for name, item in self._key_items().items():
            count = sum(1 for use in self._key_uses(item) if use <= order)
            if count:
                needed.append((name, count))
        return needed

    def generate_early(self):
        # "dans_leur_zone" : les objets clés restent dans cette partie (voir set_rules pour la zone).
        if self.options.key_items.value == 1:
            self.options.local_items.value |= set(self._key_items())

    def set_rules(self):
        key_items = self._key_items()
        if not key_items:
            return
        in_zone = self._keys_in_zone()
        player = self.player
        for location in self.multiworld.get_locations(player):
            data = self.location_name_to_location.get(location.name, {})
            order = data.get('order')
            if location.name == "Victory":
                order = float('inf')
            needed = self._key_requirements(order) if order is not None else []
            # Objets clés demandés en plus du rang (2026-10-07) : trésor de la tombe du Village
            # (Calice de Berengario #018) derrière le Morceau de plaque, qui ne sert qu'à ça.
            have = {name for name, _ in needed}
            needed += [(name, 1) for name in data.get('requires_keys', ()) if name in key_items and name not in have]
            if needed:
                set_rule(location, lambda state, needed=needed: all(
                    state.has(name, player, count) for name, count in needed))
            # Où un objet clé de cette partie ne peut PAS aller : boutique et plats (dispo selon
            # l'avancement, pas modélisé), 1er passage au Village (placements disparus ensuite),
            # et hors de sa zone avec "dans_leur_zone".
            forbid_all = data.get('kind') in ('shop', 'recipe', 'bossdrop') or self._no_key_items(data)
            region = data.get('region')
            add_item_rule(location, lambda item, forbid_all=forbid_all, region=region: not (
                item.player == player and item.name in key_items and (
                    forbid_all or (in_zone and key_items[item.name].get('key_zone') != region))))

    def create_items(self):
        # Une copie de l'objet d'origine par location active (hors Victory).
        # Passage Chris (décision du joueur) : les objets propres à Chris (son équipement) sont
        # mélangés UNIQUEMENT entre les locations de Chris, pour qu'il garde de quoi finir.
        active = [loc for loc in self._active_locations() if 'force_item' not in loc]
        chris_locations = [loc for loc in active if loc.get('chris')]
        chris_items = [loc['original_item'] for loc in chris_locations]
        self.random.shuffle(chris_items)
        for loc, item_name in zip(chris_locations, chris_items):
            name = REVillageLocation.stack_names(loc['region'], loc['name'])
            self.multiworld.get_location(name, self.player).place_locked_item(self.create_item(item_name))

        # "dans_leur_zone" : les objets clés sont placés à part (pre_fill), pas par le remplissage
        # général, qui échouait souvent faute de place (château avec zone_exclue, maison
        # Beneviento : très peu d'endroits possibles, 2026-09-30).
        # "zone_ou_autres_jeux" en multiworld (2026-09-30, demande du joueur) : chaque objet clé a
        # 1 chance sur 2 d'aller dans le remplissage général, où il ne peut aller que dans sa zone
        # chez nous (set_rules) ou chez un autre joueur. Énigmes Beneviento aussi (si leur option est
        # active ; décision du joueur, 2026-09-30).
        key_items = self._key_items() if self._keys_in_zone() else {}
        other_players = len(self.multiworld.player_ids) > 1
        hybrid = self.options.key_items.value == 2  # zone_ou_multiworld
        self.zone_key_items, pool = [], []
        for loc in active:
            if loc.get('chris'):
                continue
            name = loc['original_item']
            if name in key_items and not (hybrid and other_players and self.random.random() < 0.5):
                self.zone_key_items.append(name)
            else:
                pool.append(self.create_item(name))
        # Pièges (2026-10-08) : trap_count objets de remplissage (20 au plus, demande du joueur) tirés
        # au hasard et remplacés, piège tiré selon les poids des options.
        weights = [(T(name), getattr(self.options, option).value) for name, option in self.TRAP_OPTIONS]
        weights = [(name, w) for name, w in weights if w > 0]
        fillers = [i for i, item in enumerate(pool) if item.classification == ItemClassification.filler]
        count = min(self.options.trap_count.value, len(fillers)) if weights else 0
        for i in self.random.sample(fillers, count):
            trap = self.random.choices([n for n, _ in weights], [w for _, w in weights])[0]
            pool[i] = self.create_item(trap)
        self.multiworld.itempool += pool

    def _keys_shuffled(self):
        """Option key_items : 0 = à leur place, 1 = dans leur zone, 2 = zone ou multiworld.
        Le choix « partout » a été retiré (2026-10-08, demande du joueur : blocages vus en test)."""
        return self.options.key_items.value != 0

    def _keys_in_zone(self):
        return self._keys_shuffled()

    def pre_fill(self):
        """Objets clés gardés dans leur zone : chacun sur une location libre de sa zone, de rang
        inférieur à celui où il sert (key_use), par échéance croissante.
        Toujours possible tant que l'ordre d'origine est valide : pour le k-ième objet, il reste
        au moins (places de rang <= échéance) - (k - 1) places, ce que l'ordre d'origine garantit."""
        names = getattr(self, 'zone_key_items', [])
        if not names:
            return
        todo = []
        seen = {}
        for name in names:
            item = self.item_name_to_item[name]
            n = seen.get(name, 0)
            seen[name] = n + 1
            todo.append((self._key_uses(item)[n], name))
        todo.sort()
        free = []
        for location in self.multiworld.get_locations(self.player):
            data = self.location_name_to_location.get(location.name, {})
            if location.item is None and data.get('kind') == 'world' and data.get('order') is not None \
                    and not self._no_key_items(data) and location.progress_type != LocationProgressType.EXCLUDED:
                free.append((location, data))
        for deadline, name in todo:
            zone = self.item_name_to_item[name]['key_zone']
            candidates = [(loc, d) for loc, d in free if d['region'] == zone and d['order'] < deadline]
            if not candidates:
                raise REVillageOptionError(f"Resident Evil Village : aucune place pour l'objet clé {name}")
            # Tirage penché vers les places tardives (racine carrée) : sinon les objets clés se
            # tassaient au début de la zone, commune à toutes les échéances (joueur, 2026-09-30).
            candidates.sort(key=lambda c: c[1]['order'])
            chosen = candidates[int(len(candidates) * self.random.random() ** 0.5)]
            free.remove(chosen)
            chosen[0].place_locked_item(self.create_item(name))

    def create_item(self, item_name: str) -> Item:
        item = self.item_name_to_item[item_name]

        if item.get('type') in ('Event', 'Key'):
            classification = ItemClassification.progression
        elif item.get('progression'):
            classification = ItemClassification.progression
        elif item.get('type') == 'Trap':
            classification = ItemClassification.trap
        elif item.get('type') in ('Weapon', 'Upgrade'):
            classification = ItemClassification.useful
        else:
            classification = ItemClassification.filler

        return Item(item['name'], classification, item['id'], player=self.player)

    def get_filler_item_name(self) -> str:
        return T("Sac de Lei")

    # slot_data : valeurs fixes, quelle que soit la langue de l'apworld (le client compare ces mots).
    SLOT_DIFFICULTY = ["au_choix", "casual", "standard", "hardcore", "village_des_ombres"]
    SLOT_GOAL = {1: "fin_du_jeu", 2: "tous_les_seigneurs", 3: "dimitrescu", 4: "beneviento", 5: "moreau",
                 6: "heisenberg"}
    SLOT_MISSABLE = ["zone_exclue", "envoi_auto", "cent_pourcent"]

    def fill_slot_data(self) -> Dict[str, Any]:
        return {
            "apworld_version": self.apworld_release_version,
            "language": LANG,
            "difficulty": self.SLOT_DIFFICULTY[self.options.difficulty.value],
            "death_link": bool(self.options.death_link.value),
            "goal": self.SLOT_GOAL[self.options.goal.value],
            "missable_checks": self.SLOT_MISSABLE[self.options.missable_checks.value],
            "key_items": self.options.key_items.value,
            "duke_shop": self.options.duke_shop.value,
            "boss_rewards": bool(self.options.boss_rewards.value),
            "hunting": self.options.hunting.value,
        }
