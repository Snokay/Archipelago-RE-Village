from dataclasses import dataclass
from Options import (Toggle, DefaultOnToggle, Range, Choice, PerGameCommonOptions, DeathLink)

from .lang import LANG

# Options (refaites le 2026-10-08, demande du joueur : noms plus sobres, plus aucune option qui
# dépend d'une autre ; boutique, objets clés et chasse fusionnés en une option chacun). Retirées :
# trésors vendus et munitions (jamais faites) ; pièges : remis quand ils seront codés.
# Deux langues (lang.py) : mêmes clés d'options et mêmes numéros de choix ; les choix acceptent les
# mots des deux langues (alias), un YAML fait avec la version FR marche avec la version EN.
# Ce que reçoit le client (slot_data) ne dépend pas de la langue : voir __init__.fill_slot_data.
FR = LANG == "fr"


def text(fr, en):
    return fr if FR else en


class DukeShop(Choice):
    __doc__ = text(
        """Articles de la boutique du Duc qui deviennent des checks. On les achète au prix normal et
        on reçoit à la place l'objet Archipelago annoncé.
        normale : boutique d'origine, aucun check.
        articles_uniques : formules, améliorations d'armes, V61 Custom et SYG-12.
        articles_et_valises : les mêmes, plus les agrandissements de mallette.
        Les consommables et les rachats d'armes ne sont jamais touchés.""",
        """Duke's shop items that become checks. You buy them at their normal price and get the
        announced Archipelago item instead.
        vanilla: original shop, no checks.
        unique_items: recipes, weapon upgrades, V61 Custom and SYG-12.
        unique_items_and_cases: the same, plus the case size upgrades.
        Consumables and weapon buybacks are never changed.""")
    display_name = text("Boutique du Duc", "Duke's Shop")
    if FR:
        option_normale = 0
        option_articles_uniques = 1
        option_articles_et_valises = 2
        alias_vanilla = 0
        alias_unique_items = 1
        alias_unique_items_and_cases = 2
    else:
        option_vanilla = 0
        option_unique_items = 1
        option_unique_items_and_cases = 2
        alias_normale = 0
        alias_articles_uniques = 1
        alias_articles_et_valises = 2
    default = 2


class KeyItems(Choice):
    __doc__ = text(
        """Objets clés (clés, moules, boules d'énigme...). Quand ils sont mélangés, un objet clé est
        toujours placé avant l'endroit où il sert : la partie reste faisable.
        a_leur_place : chaque objet clé reste à sa place d'origine.
        dans_leur_zone : mélangés dans ta partie, chacun dans la zone où il sert (Village, château,
        maison Beneviento, réservoir, usine) ou chez le Duc, sur un article bon marché vendu bien
        avant l'endroit où il sert. Aucun autre joueur ne peut te bloquer.
        zone_ou_multiworld : comme dans_leur_zone, mais environ la moitié part chez les autres
        joueurs du multiworld.
        Restent toujours à leur place : couteau, pistolet de départ, masques et Trophée de chasse
        du château, Clé de Dimitrescu, objets de la maison Beneviento, Manivelle du réservoir,
        Calice des géants, cartes et photos.""",
        """Key items (keys, molds, puzzle balls...). When they are shuffled, a key item is always
        placed before the place where it is used: the game stays beatable.
        vanilla: every key item stays at its original place.
        own_zone: shuffled in your game, each one in the area where it is used (Village, castle,
        House Beneviento, reservoir, factory) or at the Duke's, on a cheap article sold well before
        the place where it is used. No other player can block you.
        zone_or_multiworld: like own_zone, but about half of them go to the other players of the
        multiworld.
        Always at their original place: knife, starting pistol, the castle's masks and Hunting
        Trophy, Dimitrescu's Key, House Beneviento items, the reservoir's Crank, Giant's Chalice,
        maps and photos.""")
    display_name = text("Objets clés", "Key Items")
    if FR:
        option_a_leur_place = 0
        option_dans_leur_zone = 1
        option_zone_ou_multiworld = 2
        alias_vanilla = 0
        alias_own_zone = 1
        alias_zone_or_multiworld = 2
    else:
        option_vanilla = 0
        option_own_zone = 1
        option_zone_or_multiworld = 2
        alias_a_leur_place = 0
        alias_dans_leur_zone = 1
        alias_zone_ou_multiworld = 2
    default = 0


class Hunting(Range):
    __doc__ = text(
        """Chasse : ramasser de la viande d'animal (Viande, Volaille, Poisson) devient un check.
        Pourcentage de ce que demandent les 6 plats du Duc (100 % = 14 Poissons, 12 Volailles et
        12 Viandes ; le jeu en garantit au moins autant), plus 1 check par viande rare. 0 = pas de
        checks de chasse. Ces checks ne contiennent jamais d'objet indispensable.""",
        """Hunting: picking up animal meat (Meat, Poultry, Fish) becomes a check. Percentage of what
        the Duke's 6 dishes need (100% = 14 Fish, 12 Poultry and 12 Meat; the game guarantees at
        least that many), plus 1 check per rare meat. 0 = no hunting checks. These checks never
        hold a required item.""")
    display_name = text("Chasse (%)", "Hunting (%)")
    range_start = 0
    range_end = 100
    default = 100


class BossRewards(DefaultOnToggle):
    __doc__ = text(
        """Le trésor lâché par certains boss devient un check : les 3 sœurs du château, le lycan au
        marteau, le gardien de la tombe et un boss de l'usine. (Les trésors des 4 Seigneurs sont
        toujours des checks.)""",
        """The treasure dropped by some bosses becomes a check: the 3 castle sisters, the hammer
        lycan, the tomb guardian and a factory boss. (The 4 Lords' treasures are always checks.)""")
    display_name = text("Récompenses de boss", "Boss Rewards")


class MissableChecks(Choice):
    __doc__ = text(
        """Zones qu'on ne peut plus revisiter une fois quittées (château Dimitrescu, ses cachots,
        passage souterrain...).
        exclues : ces zones ne contiennent que des objets sans importance.
        envoi_auto : en quittant la zone pour de bon, ses checks restants sont envoyés tout seuls.
        cent_pourcent : impossible de quitter la zone tant qu'il y reste des checks (un mur
        invisible bloque la sortie et liste ce qui manque).""",
        """Areas you can never come back to once you leave them (Castle Dimitrescu, its dungeon,
        the underground passage...).
        excluded: these areas only hold unimportant items.
        auto_send: when you leave the area for good, its remaining checks are sent automatically.
        hundred_percent: you cannot leave the area while it still has checks (an invisible wall
        blocks the exit and lists what is missing).""")
    display_name = text("Zones sans retour", "Point of No Return Areas")
    if FR:
        option_exclues = 0
        option_envoi_auto = 1
        option_cent_pourcent = 2
        alias_zone_exclue = 0
        alias_excluded = 0
        alias_auto_send = 1
        alias_hundred_percent = 2
    else:
        option_excluded = 0
        option_auto_send = 1
        option_hundred_percent = 2
        alias_exclues = 0
        alias_zone_exclue = 0
        alias_envoi_auto = 1
        alias_cent_pourcent = 2
    default = 1


class Difficulty(Choice):
    __doc__ = text(
        """Difficulté dans laquelle la partie doit être jouée. Dans une autre difficulté, aucun check
        ne compte (le mod prévient en jeu). au_choix : pas de contrainte.""",
        """Difficulty the game must be played on. On another difficulty, no check counts (the mod
        warns you in game). any: no restriction.""")
    display_name = text("Difficulté", "Difficulty")
    if FR:
        option_au_choix = 0
        option_facile = 1
        option_standard = 2
        option_hardcore = 3
        option_village_des_ombres = 4
        alias_any = 0
        alias_casual = 1
        alias_village_of_shadows = 4
    else:
        option_any = 0
        option_casual = 1
        option_standard = 2
        option_hardcore = 3
        option_village_of_shadows = 4
        alias_au_choix = 0
        alias_facile = 1
        alias_village_des_ombres = 4
    default = 0


class Goal(Choice):
    __doc__ = text(
        """Condition de victoire.
        fin_du_jeu : battre Mère Miranda.
        les_4_seigneurs : battre Dimitrescu, Beneviento, Moreau et Heisenberg.
        dimitrescu / beneviento / moreau / heisenberg : battre ce Seigneur.""",
        """Victory condition.
        game_ending: defeat Mother Miranda.
        four_lords: defeat Dimitrescu, Beneviento, Moreau and Heisenberg.
        dimitrescu / beneviento / moreau / heisenberg: defeat this Lord.""")
    display_name = text("Objectif", "Goal")
    if FR:
        option_fin_du_jeu = 1
        option_les_4_seigneurs = 2
        alias_game_ending = 1
        alias_four_lords = 2
        alias_tous_les_seigneurs = 2
    else:
        option_game_ending = 1
        option_four_lords = 2
        alias_fin_du_jeu = 1
        alias_les_4_seigneurs = 2
        alias_tous_les_seigneurs = 2
    option_dimitrescu = 3
    option_beneviento = 4
    option_moreau = 5
    option_heisenberg = 6
    default = 1


class TrapCount(Range):
    __doc__ = text(
        """Pièges : nombre d'objets de remplissage (munitions, ressources, trésors, Lei) remplacés par
        des pièges, envoyés par les autres joueurs ou trouvés chez toi. 0 = pas de pièges, 20 au
        maximum. Les objets importants ne sont jamais remplacés. Les pièges à utiliser se règlent avec
        les poids ci-dessous.""",
        """Traps: number of filler items (ammo, resources, treasures, Lei) replaced by traps, sent by the
        other players or found in your world. 0 = no traps, 20 at most. Important items are never
        replaced. Which traps are used is set by the weights below.""")
    display_name = text("Pièges (nombre)", "Traps (count)")
    range_start = 0
    range_end = 20  # 2026-10-08, demande du joueur : 20 pièges au plus (un % allait jusqu'à ~440)
    default = 0


class TrapWeight(Range):
    range_start = 0
    range_end = 10
    default = 5


class TrapBankruptWeight(TrapWeight):
    __doc__ = text("Poids du piège Faillite : la banque a besoin d'argent, tu perds 1000 Lei.",
                   "Weight of the Bankruptcy trap: the bank needs money, you lose 1000 Lei.")
    display_name = text("Piège : Faillite (poids)", "Trap: Bankruptcy (weight)")


class TrapScreamerWeight(TrapWeight):
    __doc__ = text("Poids du piège Screamer : le cri de Bela et un flash rouge. Juste pour la peur.",
                   "Weight of the Screamer trap: Bela's scream and a red flash. Just for the scare.")
    display_name = text("Piège : Screamer (poids)", "Trap: Screamer (weight)")


class TrapJamWeight(TrapWeight):
    __doc__ = text("Poids du piège Armes bloquées : impossible de sortir une arme pendant 15 secondes (les soins restent possibles).",
                   "Weight of the Jammed Weapons trap: no weapon for 15 seconds (healing still works).")
    display_name = text("Piège : Armes bloquées (poids)", "Trap: Jammed Weapons (weight)")


class TrapDamageWeight(TrapWeight):
    __doc__ = text("Poids du piège Dégâts : tu perds 30 % de ta vie actuelle. Jamais mortel.",
                   "Weight of the Damage trap: you lose 30% of your current health. Never lethal.")
    display_name = text("Piège : Dégâts (poids)", "Trap: Damage (weight)")


class TrapEmptyMagWeight(TrapWeight):
    __doc__ = text("Poids du piège Chargeur vidé : l'arme en main perd les balles chargées, il faut recharger.",
                   "Weight of the Empty Magazine trap: the weapon in hand loses its loaded rounds, you must reload.")
    display_name = text("Piège : Chargeur vidé (poids)", "Trap: Empty Magazine (weight)")


@dataclass
class REVillageOptions(PerGameCommonOptions):
    goal: Goal
    difficulty: Difficulty
    missable_checks: MissableChecks
    key_items: KeyItems
    duke_shop: DukeShop
    boss_rewards: BossRewards
    hunting: Hunting
    trap_count: TrapCount
    trap_bankrupt_weight: TrapBankruptWeight
    trap_screamer_weight: TrapScreamerWeight
    trap_jam_weight: TrapJamWeight
    trap_damage_weight: TrapDamageWeight
    trap_empty_mag_weight: TrapEmptyMagWeight
    death_link: DeathLink
