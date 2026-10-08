# Setup guide — RE Village Archipelago

*[Version française plus bas](#guide-dinstallation--re-village-archipelago)*

## Requirements

- **Resident Evil Village** on Steam (PC). DLC is not used.
- To **generate** or **host**: [Archipelago 0.6](https://github.com/ArchipelagoMW/Archipelago/releases). Not
  needed to just play in someone else's game.
- The latest mod version from **[Releases](../../releases)**: the `_launcher.zip` (recommended) or the
  `_manuel.zip` (manual install).


**Xbox Game Pass / Microsoft Store**: not tested yet. The launcher finds the game in `XboxGames`, but
start the game yourself from the Xbox app ("Play" only saves the connection). If the Insert menu does
not show up in game, REFramework does not work on your version: please report it.

## 1. Install the mod

**Launcher (recommended)**: unzip (keep the `files` folder next to the exe), **close the game**, run
`RE_Village_AP_Launcher.exe`, **Setup** tab: game and Archipelago folders are found automatically; pick
the **apworld language** (item and check names: Français or English; YAML files work with both), then
**Install / update**. Everything should turn green.

**Manual**: close the game, unzip; if `dinput8.dll` is not next to `re8.exe`, copy
`REFramework\dinput8.dll` there and start the game once; copy the **content** of the `jeu` folder into
the game folder (merge folders); set `LooseFileLoader_Enabled=true` in `re2_fw_config.txt`; to host,
copy `residentevilvillage.apworld` (`apworld_EN` or `apworld_FR`) into Archipelago's `custom_worlds`.

## 2. Make your YAML (before generation)

Launcher > **My options** tab: pick your settings, enter your slot name, "Save YAML…", send it to the
host. Or use Archipelago's Options Creator.

## 3. Connect and play

- **Launcher** > **Play** tab: room address (e.g. `archipelago.gg:38281`, just the port, or the room
  page link), slot name, password. Saved into the game as you type; "Play" checks the connection and
  starts the game. Afterwards, **just start the game**: it reconnects by itself.
- **Without the launcher**: in game, **Insert** key > **RE Village Archipelago** window >
  **Connection** tab > "Connect".

Start a **new game** on the difficulty required by your YAML (on another difficulty, no check counts;
the mod warns you).

## 4. In-game menu (Insert key)

Checks (per area and room), Guidance ("[AP]" markers: distance, detail), Hints (buy hints, hinted
checks in pink), Message log (commands like `!hint`), Help (give back received items, repair the case,
send a stuck check, bug report), Customize (colours), Connection. Top right: area, room, room checks,
connection status.

## 5. Host a game

Launcher > **Host** tab: install Archipelago and the apworld, put the YAML files in `Players`,
**Generate**, then upload the `AP_….zip` (`output` folder) to
[archipelago.gg/uploads](https://archipelago.gg/uploads) or start a local server.

## 6. Troubleshooting

- **Missing received items**: in-game menu > Help > "Give back all received items".
- **Weird case** (overlapping items, quantity 0): Help > "Repair the case".
- **Item you cannot pick up / check not sent**: Help > "Stuck check" (within 10 m).
- **Not connected**: check the address (a sleeping archipelago.gg room wakes up when its page is
  opened); launcher > Play > "Test connection".
- **Report a bug**: in-game menu > Help > "Create a bug report", then launcher > "Bug report" (zip on
  your Desktop). Without the launcher, send the game's `reframework\data\re_village_ap_client` folder
  (zipped). Open an [issue](../../issues) with the zip and what happened.

---

# Guide d'installation — RE Village Archipelago

## Ce qu'il te faut

- **Resident Evil Village** sur Steam (PC). Le DLC n'est pas utilisé.
- Pour **générer** ou **héberger** une partie : [Archipelago 0.6](https://github.com/ArchipelagoMW/Archipelago/releases).
  Pour seulement jouer dans la partie de quelqu'un d'autre, pas besoin.
- La dernière version du mod, page **[Releases](../../releases)** :
  - `RE_Village_Archipelago_<version>_launcher.zip` : avec le launcher (conseillé) ;
  - `RE_Village_Archipelago_<version>_manuel.zip` : installation à la main.


**Xbox Game Pass / Microsoft Store** : pas encore testé. Le launcher trouve le jeu dans `XboxGames`,
mais lance le jeu toi-même depuis l'application Xbox (« Jouer » ne fait que noter la connexion). Si le
menu Inser n'apparaît pas en jeu, REFramework ne marche pas sur ta version : signale-le.

## 1. Installer le mod

### Avec le launcher (conseillé)

1. Décompresse le zip du launcher où tu veux (garde le dossier `files` à côté de l'exe).
2. **Ferme le jeu**, puis lance `RE_Village_AP_Launcher.exe`.
3. Onglet **Installation** : le dossier du jeu et celui d'Archipelago sont trouvés tout seuls (sinon,
   « Parcourir »).
4. Choisis la **langue de l'apworld** (noms des objets et des checks dans Archipelago : Français ou
   English ; les YAML marchent avec les deux).
5. **Installer / mettre à jour**. Tout doit passer au vert : jeu, REFramework (installé s'il manque),
   mod, fichiers « loose », apworld.

### À la main

1. **Ferme le jeu.** Décompresse le zip manuel.
2. REFramework : si `dinput8.dll` n'est pas à côté de `re8.exe`, copie `REFramework\dinput8.dll` dans
   le dossier du jeu, lance le jeu une fois puis ferme-le.
3. Copie le **contenu** du dossier `jeu` dans le dossier du jeu (Steam : clic droit sur le jeu > Gérer
   > Parcourir les fichiers locaux), en fusionnant les dossiers.
4. Dans `re2_fw_config.txt` (dossier du jeu), mets `LooseFileLoader_Enabled=true`.
5. Pour héberger : copie `residentevilvillage.apworld` (dossier `apworld_FR` ou `apworld_EN`) dans
   `custom_worlds` de ton Archipelago.

## 2. Préparer ton YAML (avant la génération)

Chaque joueur envoie un fichier YAML à l'hôte **avant** la génération.

- **Launcher** > onglet **Mes options** : choisis tes réglages, entre ton nom de slot, puis
  « Enregistrer le YAML… ». Envoie ce fichier à l'hôte.
- Ou avec l'Options Creator d'Archipelago (apworld installé).

Les options principales : objectif, difficulté imposée, zones sans retour (exclues / envoi automatique
/ mode 100 %), objets clés, boutique du Duc, récompenses de boss, chasse, pièges, DeathLink.

## 3. Se connecter et jouer

- **Launcher** > onglet **Jouer** : adresse de la room (ex. `archipelago.gg:38281`, le port seul, ou
  le lien de la page de la room), ton nom de slot, le mot de passe s'il y en a un. C'est enregistré
  dans le jeu dès que tu tapes ; « Jouer » vérifie la connexion et lance le jeu. Ensuite, **lancer le
  jeu suffit** : il se reconnecte tout seul à cette session.
- **Sans launcher** : en jeu, touche **Inser** > fenêtre **RE Village Archipelago** > onglet
  **Connexion**, puis « Se connecter ». C'est gardé pour les prochains lancements.

Commence une **nouvelle partie** dans la difficulté demandée par ton YAML. Dans une autre difficulté,
le mod te prévient et aucun check ne compte.

## 4. Le menu en jeu (touche Inser)

| Onglet | Contenu |
|---|---|
| Checks | Checks faits / restants par zone et par salle |
| Guidage | Marqueurs « [AP] » au-dessus des checks : distance, détail |
| Hints | Points de hint, acheter un hint, hints de la partie (checks hintés en rose) |
| Journal | Messages Archipelago, commandes (`!hint`, `!release`…) |
| Aide | Redonner les objets reçus, réparer la mallette, valider un check bloqué, rapport de bug |
| Personnaliser | Couleurs de la fenêtre |
| Connexion | Adresse, slot, mot de passe |

En haut à droite : zone, salle, checks de la salle, état de la connexion.

## 5. Héberger une partie

Launcher > onglet **Héberger** (guide pas à pas) : installer Archipelago et l'apworld, mettre les YAML
dans `Players`, **Générer**, puis envoyer le `AP_….zip` (dossier `output`) sur
[archipelago.gg/uploads](https://archipelago.gg/uploads) ou lancer un serveur local.

## 6. Problèmes courants

- **Objets reçus manquants** (plantage, vieille sauvegarde) : menu en jeu > Aide > « Redonner tous les
  objets reçus ».
- **Mallette bizarre** (objets superposés, quantité 0) : Aide > « Réparer la mallette ».
- **Objet impossible à ramasser / check qui ne part pas** : Aide > « Check bloqué » (moins de 10 m).
- **Pas connecté** : vérifie l'adresse (une room archipelago.gg endormie se réveille en ouvrant sa
  page) ; launcher > Jouer > « Tester la connexion ».
- **Signaler un bug** : menu en jeu > Aide > « Créer un rapport de bug », puis launcher > « Rapport de
  bug » (zip sur ton Bureau). Sans launcher : envoie le dossier `reframework\data\re_village_ap_client`
  du jeu (zippé). Ouvre une [issue](../../issues) avec le zip et ce qui s'est passé.

## Désinstaller

Launcher > Installation > **Désinstaller** (tes sauvegardes et ta connexion sont gardées). À la main :
voir `LISEZMOI - README.txt` du zip manuel.
