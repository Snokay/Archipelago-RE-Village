# RE Village Archipelago — alpha 0.9.0

*(English below)*

Mod [Archipelago](https://archipelago.gg) pour **Resident Evil Village** (Steam, PC) : les objets du jeu
sont mélangés avec ceux des autres joueurs d'un multiworld. Ce que tu ramasses peut appartenir à un
autre jeu, et tes objets peuvent tomber chez les autres.

> **Alpha** : le mod est jouable du début à la fin, mais attends-toi à des bugs. Signale-les (voir
> plus bas), c'est le but de cette version.

## Ce que contient le mod

- **Environ 500 checks** : objets posés dans le monde, articles uniques et valises du Duc, plats du
  Duc, chasse (viandes), récompenses de boss, et en option les objets clés.
- Les objets Archipelago au sol prennent le **logo AP** ou le modèle de l'objet, avec leur nom
  (« [AP] … »). Les achats chez le Duc affichent ce qu'ils donnent.
- **Objets clés** mélangés (au choix : à leur place, dans leur zone, ou zone et multiworld), toujours
  placés avant l'endroit où ils servent. La Clé ailée est progressive.
- **Zones sans retour** (château, cachots…) : checks exclus, envoyés automatiquement, ou mode 100 %
  (un mur invisible t'empêche de partir tant qu'il reste des checks).
- **Pièges** (en option) : Faillite, Screamer, Armes bloquées, Dégâts, Chargeur vidé.
- **DeathLink**, objectifs (fin du jeu, les 4 Seigneurs, ou un Seigneur seul), difficulté imposée.
- **Menu en jeu** (touche **Inser**) : liste des checks par zone et par salle, marqueurs « [AP] »
  au-dessus des checks, hints, journal des messages, aide en cas de bug, couleurs, connexion.
- Deux versions de l'apworld : **français** et **anglais** (noms des objets et des checks). Les YAML
  marchent avec les deux.

## Installation

Télécharge la dernière version dans **Releases**.

### Avec le launcher (conseillé)

1. Décompresse `RE_Village_Archipelago_0.9.0_launcher.zip` où tu veux.
2. Lance `RE_Village_AP_Launcher.exe`, onglet **Installation** : il trouve le jeu et Archipelago tout
   seul. Choisis la langue de l'apworld puis **Installer / mettre à jour** (jeu fermé). REFramework est
   installé s'il manque.
3. Onglet **Jouer** : entre l'adresse de la room, ton nom de slot et le mot de passe. C'est enregistré
   dans le jeu : ensuite, lancer le jeu suffit, il se connecte tout seul.

Le launcher sert aussi à préparer ton YAML (**Mes options**) et à héberger une partie (**Héberger**).

### À la main

Décompresse `RE_Village_Archipelago_0.9.0_manuel.zip` et suis `LISEZMOI - README.txt`. Pour te
connecter : touche **Inser** en jeu > fenêtre **RE Village Archipelago** > onglet **Connexion**.

## Jouer

- **Pré-requis** : Resident Evil Village sur Steam (PC), [Archipelago 0.6](https://github.com/ArchipelagoMW/Archipelago/releases)
  pour générer ou héberger.
- Commence une **nouvelle partie** dans la difficulté demandée par ton YAML (le mod prévient si ce
  n'est pas la bonne : aucun check ne compte dans une autre difficulté).
- Le DLC (Shadows of Rose, Mercenaires) n'est pas pris en charge.

## Un bug ?

1. Dans le menu en jeu, onglet **Aide** : redonner les objets reçus, réparer la mallette, valider un
   check bloqué tout près de toi.
2. Sinon : launcher > **Rapport de bug** (crée un zip des journaux sur ton Bureau) et envoie-le avec
   une description de ce qui s'est passé (issue GitHub ou Discord).

## Crédits

Mod par **Snokayy**. Basé sur [REFramework](https://github.com/praydog/REFramework) et
[lua-apclientpp](https://github.com/black-sliver/lua-apclientpp). Inspiré du client Archipelago de
Resident Evil 7 et du launcher Archipelago de Resident Evil 4. Resident Evil Village © Capcom ; ce
projet n'est pas affilié à Capcom.

---

# RE Village Archipelago — alpha 0.9.0 (English)

[Archipelago](https://archipelago.gg) mod for **Resident Evil Village** (Steam, PC): the game's items
are shuffled with the other players of a multiworld.

> **Alpha**: playable from start to finish, but expect bugs. Please report them (see below).

## Features

- **About 500 checks**: items placed in the world, the Duke's unique items and case upgrades, the
  Duke's dishes, hunting (meat), boss rewards, and optionally key items.
- Archipelago items in the world use the **AP logo** or the item's model, with their name
  ("[AP] …"); the Duke's shop shows what each purchase gives.
- **Key items** can be shuffled (vanilla, own zone, or zone and multiworld), always placed before the
  place where they are used. The Winged Key is progressive.
- **Point of no return areas** (castle, dungeon…): excluded, sent automatically, or 100% mode (an
  invisible wall keeps you in while checks remain).
- **Traps** (optional): Bankruptcy, Screamer, Jammed Weapons, Damage, Empty Magazine.
- **DeathLink**, goals (game ending, the 4 Lords, or one Lord), required difficulty.
- **In-game menu** (**Insert** key): checks per area and room, "[AP]" markers above checks, hints,
  message log, help buttons, colours, connection.
- Two apworld versions: **French** and **English** (item and check names). YAML files work with both.

## Install

Download the latest version from **Releases**.

- **Launcher (recommended)**: unzip `RE_Village_Archipelago_0.9.0_launcher.zip`, run
  `RE_Village_AP_Launcher.exe`, **Setup** tab > pick the apworld language > **Install / update**
  (game closed). Then **Play** tab: room address, slot name, password. They are saved into the game:
  afterwards just start the game, it connects by itself.
- **Manual**: unzip `RE_Village_Archipelago_0.9.0_manuel.zip` and follow `LISEZMOI - README.txt`. To
  connect: **Insert** key in game > **RE Village Archipelago** window > **Connection** tab.

Requirements: Resident Evil Village on Steam (PC); [Archipelago 0.6](https://github.com/ArchipelagoMW/Archipelago/releases)
to generate or host. Start a **new game** on the difficulty required by your YAML. DLC is not supported.

## Found a bug?

In-game menu, **Help** tab: give back received items, repair the case, send a stuck check near you.
Otherwise: launcher > **Bug report** (zips the logs on your Desktop) and send it with a description
(GitHub issue or Discord).

## Credits

Mod by **Snokayy**. Built on [REFramework](https://github.com/praydog/REFramework) and
[lua-apclientpp](https://github.com/black-sliver/lua-apclientpp). Inspired by the Resident Evil 7
Archipelago client and the Resident Evil 4 Archipelago launcher. Resident Evil Village © Capcom; this
project is not affiliated with Capcom.
