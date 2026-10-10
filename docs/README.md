# Mod Archipelago — Resident Evil Village

Contexte complet et justification du choix de ce jeu : voir `prompt-mods-archipelago (1).md`
à la racine du dossier `Archipelago`.

## Statut (2026-09-25) : version 1 jouable, Village uniquement — VALIDÉE EN JEU

- **48 checks** = les objets posés dans le Village (scan du chapitre 2_1).
  - Exclus : objets clés, armes du dossier KeyItem, drops d'ennemis.
  - Chaque check est identifié par le GUID de son placement `app.Spawn.ItemSpawnInfo`.
- **Pool d'items** = les objets d'origine de ces checks (munitions, matériaux, herbes, trésors,
  Lei, lance-grenades, mine).
- **Objectif** : faire les 48 checks. Le client envoie alors le statut GOAL.
- **Client** (`client/`) : même arborescence que le dossier du jeu.
  - `lua-apclientpp.dll` est repris du client RE7 (licence MIT, voir
    `client/THIRD_PARTY_NOTICES.txt`). Il est utilisé via notre module
    `re_village_ap/net.lua` (voir la section sur la vraie cause des freezes).
  - **`client/bridge/ap_bridge.py` est obsolète.**
  - Le client : détecte le check → retire l'objet d'origine (`Inventory.reduceItem`) → envoie
    le check.
  - Il donne les items reçus (`createAndAddItem` / `addMoney`).
  - Il garde les checks faits hors connexion et les renvoie à la reconnexion.
  - Il affiche un compteur « X / 48 checks » et des messages en haut à gauche.
- **Outils** :
  - `tools/build_data_from_scans.py` : scans → données de l'apworld et du client.
  - `tools/install.py` : copie le client dans le jeu et l'apworld dans `D:\Archipelago`.
- **Pas encore testé en jeu** :
  - retrait de l'objet d'origine (surtout armes et Sac de Lei) ;
  - quantités reçues (quantités d'origine du scan, par ex. 25 munitions pistolet ?) ;
  - compteur de checks après reconnexion.
- **Limite connue** : recharger une sauvegarde plus ancienne ne redonne pas les items reçus
  entre-temps.
- **Premier test en conditions réelles (2026-09-25, serveur local, slot "Ethan")** :
  - la connexion marche ;
  - 5 checks envoyés et reçus par le serveur ;
  - les 5 items ont été donnés en jeu (dont un Sac de Lei).
  - Bug : compteur bloqué à 0/48, car le callback `location_checked` de lua-apclientpp ne se
    déclenche pas après nos propres checks. Corrigé en lisant `APClient.checked_locations`
    (à confirmer).
  - Le retrait de l'objet d'origine n'a pas encore été vérifié visuellement.
  - Crash à la reconnexion : l'affichage parcourait `checked_ids` avec `pairs()` pendant que le
    callback réseau le modifiait ("invalid key to 'next'"). L'erreur interrompait la fenêtre
    imgui entre `begin_window` et `end_window`. Corrigé : compteur tenu à part, contenu de la
    fenêtre protégé par `pcall`. On a aussi appris que `location_checked` EST appelé à la
    connexion, avec les checks déjà connus du serveur.
  - 2e crash (connexion depuis le menu principal, crash ~20 s plus tard, sans erreur Lua) :
    coïncide avec la lecture de `APClient.checked_locations` chaque seconde une fois en jeu.
    Cette lecture est supprimée : le compteur se fie au callback `location_checked`, appelé
    à la connexion, et aux checks envoyés localement.
  - 3e crash (en ramassant un objet) : le script retirait `get_stackSize()` de l'objet
    ramassé, qui valait en fait la pile TOTALE (3 poudres au lieu d'1), et il le faisait
    pendant l'animation de ramassage. Corrigé :
    - photo des quantités à chaque frame ;
    - retrait de la seule différence, 2 s après le ramassage, une fois revenu « en jeu ».
  - Le mod n'agit plus qu'une fois en partie : `GUIManager.get_isEnableInGameFlow` + inventaire
    actif, stable depuis 3 s. On peut se connecter depuis le menu principal. L'affichage
    (autre fil d'exécution) ne fait plus aucun appel au jeu.
  - Le 3e « crash » était en fait un **freeze** (jeu figé, à tuer au gestionnaire des tâches),
    en reprenant un objet déjà validé.
    - Sans le mod, pas de freeze.
    - Le journal de diagnostic (`debug_log.txt`, écrit avant chaque étape) s'arrête sur
      « envoi du check » : l'appel réseau fait depuis le hook de ramassage ne revenait jamais.
    - Corrigé : le hook ne fait que noter la location, et l'envoi se fait dans la boucle
      principale.
    - Un check déjà validé n'est plus renvoyé.
  - Lua vérifié désormais par `tools/check_lua.py` (vrai Lua via lupa). luaparser avait laissé
    passer une chaîne cassée.
- **VRAIE CAUSE de tous les freezes/crashs (prouvée hors jeu le 2026-09-25)** :
  - REFramework embarque **Lua 5.4.3** et `lua-apclientpp.dll` sa propre copie, **Lua 5.4.7**.
    Les mêmes DLL statiques sont utilisées par RE2R (5.4.7) et RE4R (5.4.8).
  - Les rappels du module réseau sont exécutés par le Lua de la DLL. Une table à clés
    numériques remplie dans un rappel est illisible côté REFramework (`t[id] == nil`,
    `invalid key to 'next'`), et relire une table après l'avoir passée à la DLL peut boucler
    à l'infini.
  - Reproduit avec un `lua543.exe` compilé via `python -m ziglang cc` (sources lua-5.4.3), qui
    charge la DLL.
  - REFramework n'exporte pas son Lua, donc une DLL « dynamique » est impossible.
  - **Correctif** : nouveau module `client/reframework/autorun/re_village_ap/net.lua` qui
    remplace AP_REF.
    - Les rappels ne déposent que du texte dans une boîte aux lettres à clés texte.
    - Chaque envoi à la DLL passe une table neuve.
    - Nouvelle fenêtre de connexion dans le menu REFramework (« RE Village Archipelago »).
  - Tests hors jeu : `tools/test_net_offline.lua` et `tools/test_client_offline.lua`
    (données : `python tools/make_test_data.py`). Tous deux passent sous Lua 5.4.3, avec la
    vraie DLL et un vrai serveur.
- **Validé en jeu (2026-09-25, 19h53)** :
  - connexion depuis le menu ;
  - reprise d'un check déjà validé sans freeze ;
  - nouveaux checks envoyés et items reçus ;
  - objets d'origine retirés (Liquide chimique : retrait 1 sur 1).
  - Dernier bug corrigé : un item reçu pendant les 2 s d'attente d'un retrait du même objet
    était compté dans la différence et retiré aussi (Poudre #012 : 2 retirées au lieu d'1).
    Les items reçus attendent maintenant la fin des retraits.
  - Sac de Lei : bien détecté comme check. Le jeu ajoute directement 500 Lei, qui n'étaient
    pas retirés. Corrigé : l'argent est photographié comme les objets, puis la différence est
    retirée via `Inventory.setMoney`, à tester en jeu. Un sac de Lei reçu donne 500 Lei.

## Historique

## Mise à jour (2026-09-13) : premières vraies classes du jeu identifiées

Le dump SDK de REFramework a planté (comportement normal), mais son log de session a révélé
**18 707 noms de classes réelles** du jeu. Voir `docs/findings_dump.md` pour la liste commentée
(ramassage d'objets, argent, boutique du Duke — nommée "CPShop" en interne —, trésors, défaite de
boss, puzzle du piano confirmé, soin). La liste brute complète est dans
`docs/reference/app_types_from_crash_log_2026-09-13.txt`. `client/re_village_ap_client.lua` a été
mis à jour avec ces candidats à la place des TODO génériques.

## Mise à jour (2026-09-25) : modèle RE7 + scanner + piste de don d'items

- Pas d'apworld Village existant en ligne, mais **Resident Evil 7 a un Archipelago complet sur
  le même moteur** : [RE7_AP_Client](https://github.com/ElGrenier/RE7_AP_Client) /
  [RE7_AP_World](https://github.com/ElGrenier/RE7_AP_World), clonés dans `reference_re7/`.
  À retenir :
  - Chaque location y est identifiée par `item_object` (nom du GameObject) + `parent_object` +
    `folder_path` (chemin de scène) + `item_position` si besoin. On reprend ce format.
  - La connexion au serveur passe par `lua-apclientpp.dll` + `AP_REF/core.lua` directement
    dans REFramework : ça peut **remplacer notre `ap_bridge.py`**.
  - Ils déposent les items reçus dans la malle ; Village n'en a pas, donc on ne peut pas copier.
- Trouvé dans `il2cpp_dump.json` :
  - `app.InteractBase.ItemObjectID` (UInt32) : probablement un ID unique par objet posé, donc
    la clé de location idéale. **À confirmer** en comparant deux ramassages du même type d'objet.
  - `app.InventoryManager.createAndAddItem(itemID, stackCount, includeID, includeStackCount)`
    (singleton) : pour donner un item à partir de l'ItemID numérique déjà connu.
  - `app.Inventory.addMoney(Int32)`, via `InventoryManager.get_activeInventory()` : pour les Lei.
- `client/re_village_ap_client.lua` :
  - le hook de ramassage journalise maintenant l'identité complète dans
    `reframework/data/re_village_ap_client/pickups_log.jsonl` ;
  - nouveau menu **"RE Village Archipelago"** dans l'UI REFramework (touche Inser), avec :
    - **Scanner la zone**, qui liste tous les points de ramassage chargés dans `scan_<date>.json`
      sans rien ramasser ;
    - deux boutons de test : donner un ItemID, et +1000 Lei.
  - Rien de tout ça n'est encore testé en jeu.
- **Premier test en jeu (2026-09-25)** :
  - +1000 Lei marche.
  - `createAndAddItem`(pistolet) renvoie nil sans rien donner. Une méthode B est ajoutée
    (`createItemCore` + `Inventory.addItem`), testée désormais sur un matériau de craft.
  - Le scan des `app.InteractItemGet` a trouvé 178 points, mais ce sont des objets **recyclés**
    (dossiers `st10_ItemSet_Pool/...`, 147 vides) : ils ne peuvent pas servir de clé de location.
  - `ItemObjectID` n'a pas pu être lu.
  - La vraie clé est le placement **`app.Spawn.ItemSpawnInfo`** : `MyGUID` unique,
    `IsCompleted`, `spawnItemId`, et `SpawnInstance` = l'objet recyclé qu'il occupe.
    Le scanner et le hook de ramassage utilisent maintenant ce GUID.
- **Don d'objet confirmé en jeu (2026-09-25)** : la poudre (3461208890) augmente bien.
  Testées séparément, les deux méthodes marchent (40 → 41, puis 41 → 42). **On retient
  la méthode 1 : `InventoryManager.createAndAddItem(itemID, quantité, 0, 0)`.**
- **Scan des placements validé (2026-09-25, Village, Chapter2_1)** : 73 placements, 21 déjà
  ramassés, **73 GUID tous distincts**. Les noms des placements (`SpawnInfo_HandGun_Bullet_001`)
  donnent le nom interne de chaque objet : voir la table complète dans
  `reference/known_item_ids.md`. Scan brut : `reference/scans/`.
- **Hook de ramassage → GUID (2026-09-25)** :
  - 1er essai raté : la comparaison `==` entre objets Lua ne marche pas.
  - La position suffit pourtant à retrouver le placement : 0 m d'écart pour une ferraille,
    1,3 m pour une spinelle.
  - Correctif : comparaison par adresse mémoire, et en secours le placement le plus proche
    (moins de 5 m) avec le même ItemID.
  - Retesté : **ça marche**. Relief de l'épée trouvé à 0 m, spinelle à 3,2 m. La
    comparaison par adresse ne marche jamais, c'est toujours la position qui trouve.
  - **Toutes les briques techniques sont validées en jeu** : détecter un check (GUID) et
    donner un item.

## Château et boutique du Duc (2026-09-25)

- **Château** : un seul scan devant le château a relevé **149 placements** de `Chapter2_2`,
  dont tous les objets clés, trésors, fusil de précision et ressources. Le jeu semble charger
  la liste complète d'une zone d'un coup. À confirmer par un 2e scan à l'intérieur.
  Fichier : `reference/scans/chateau_chapitre2_2_scan_20260925.json`.
- **Boutique du Duc (recherche)** : l'écran d'achat est `app.GUIShopBuy`.
  - Sa liste `buyUnits` contient des `app.GUIShopBuy.BuyUnit` (itemID, price, stackSize,
    stockCount).
  - Méthodes : `collectBuyUnits`, `buyItem(needCheck)`, `decideBuyItem(itemCore)`,
    `buyUnitItem(count, price)`.
  - Textes affichés : `itemNameText` / `itemDescriptionText` (via.gui.Text).
  - Plan, sur le modèle de RE4R :
    - ajouter des BuyUnit « Archipelago » après `collectBuyUnits` ;
    - à l'achat, bloquer l'objet et envoyer le check ;
    - réécrire le nom affiché grâce à LocationScouts.
  - Outils ajoutés : bouton « Relever la boutique » (`shop_<date>.json`) et journal des
    achats dans `debug_log.txt`.
  - Relevé fait (château, 21 articles) : `reference/shop_duc_chateau_20260925.json`.
    - Un achat passe par `buyItem`, puis `decideBuyItem(itemCore)`.
    - `buyTargetUnit` vaut nil au moment de ces appels.
  - **Règles de conception décidées avec le joueur (2026-09-25)** :
    1. Consommables à stock illimité (munitions, soins…) : non touchés.
    2. Chaque article unique (plans, améliorations, armes vendues une seule fois…) est un
       **check** : le 1er achat envoie l'item AP au lieu de l'objet du Duc.
    3. Les armes vendues par le Duc deviennent des items AP, obtenues en jeu et plus
       achetables directement.
    4. Les articles de rachat des armes déjà possédées restent 100 % vanilla. Par exemple
       pistolet 16 000, fusil à pompe 24 000, couteau 0. Une arme reçue via AP puis revendue
       doit rester rachetable normalement.
    5. Une fois le check d'un article fait, l'article est masqué, SAUF si l'objet a déjà été
       reçu via AP : il redevient alors vanilla (rachat après revente).
    6. Infos du joueur :
       - les articles uniques déjà achetés (plan des mines, agrandissement du sac)
         disparaissent de la liste ;
       - plusieurs armes de la liste sont des armes custom (DLC ou récompenses de fin de
         quête) : à exclure des checks.
       - confirmé : pistolet (16 000) et fusil à pompe (24 000) sont des **rachats** d'armes
         que le joueur a revendues. Le Duc propose de racheter toute arme revendue.
  - L'enregistreur de noms par curseur ne marchait pas (compteur bloqué à 0). Remplacé par le
    bouton « Catalogue des objets » : toutes les fiches `app.ItemSpecification`, avec
    `Basic.NameMessageID` traduit par `via.gui.message.get(guid)` → `item_catalog.json`.
    **Marche** : 298 objets, dont 281 nommés, dans `reference/item_catalog_fr.json`.
  - Classement de la boutique du château (relevé du 2026-09-25) :
    - **checks (7)** : Formules (cartouches de fusil 3000, munitions sniper 4000, mines 3500,
      munitions fusil d'assaut 10000), Valise 30000, Chargeur grande capacité LEMI 9000,
      Détente sensible M1897 8000 ;
    - vanilla : consommables (remède, munitions), rachats (LEMI, M1897, couteau) ;
    - exclus : armes custom/DLC (WCX, Handcannon PZ, Pistolet lance-roquettes, Samurai Edge,
      USM-AI, Dragoon, Karambit, Mr. Everywhere).
    - Le Duc ajoute des articles au fil des chapitres (`ChangeShopAssortmentAction`) : il
      faudra relever sa boutique dans chaque zone.
  - **Relevé complet après le château** (tous les onglets cumulés dans `shop_all.json`, car la
    liste `buyUnits` ne contient que l'onglet ouvert) : 28 articles, dans
    `reference/shop_duc_complet_village2_20260925.json`.
    - **12 checks** :
      - Valise ×2 (stock 2) ;
      - Formules : cartouches, sniper, bombes tuyaux, fusil d'assaut, mines ;
      - Chargeur LEMI, Détente M1897, Lunette F2, Appui-joue F2.
      - Le Fusil F2 (40 000) n'en fait pas partie : voir la correction plus bas.
    - Vanilla :
      - consommables (remède, munitions, bombe tuyau, mine) ;
      - rachats (LEMI, M1897, couteau).
    - Exclus : armes custom/DLC.
    - Un article déjà acheté reste dans la liste interne, trié en dernier (Formule : Mines) et
      masqué à l'écran.
  - **Relevé après le réservoir** (35 articles, `reference/shop_duc_complet_reservoir_20260925.json`).
    7 nouveaux articles :
    - checks : Formules (grenades aveuglantes, grenades explosives), Compensateur de recul
      LEMI, Crosse améliorée W870 TAC, Poignée ergonomique M1911 ;
    - M1911 (50 000) : rachat (voir la correction ci-dessous) ;
    - rachat : W870 TAC (68 000), trouvé dans le Village puis revendu par le joueur.
  - **Règle confirmée** :
    - les armes trouvées dans le monde (LEMI, M1897, W870 TAC, GM 79…) ne sont JAMAIS des
      checks de boutique : le Duc ne les propose qu'en rachat ;
    - Correction (joueur) : le **M1911** est posé dans le Village, dans le placard de la
      Manivelle de cric (`SpawnInfo_HandGun_G17_001`, `Separetor_18`). Il est présent dans
      `pickups_log.jsonl` mais absent des scans, car ramassé avant le scan automatique. C'est
      donc une arme du monde, et un rachat chez le Duc.
    - Jusqu'au réservoir, aucune arme n'était vendue uniquement par le Duc. À l'usine
      apparaissent le V61 Custom et le SYG-12, qui le sont (voir ci-dessous).
    - Correction : le **Fusil F2** est posé dans le château (`SpawnInfo_SniperRifle_013`,
      ramassé par le joueur). Son entrée chez le Duc (40 000) est une arme du monde
      (rachat, ou rattrapage si on l'a ratée). Ce n'est pas un check de boutique : le check
      est son emplacement au château.
  - Total connu : environ 17 checks de boutique (formules, améliorations, valises).
  - **Relevé à l'usine** (44 articles, `reference/shop_duc_complet_usine_20260926.json`) :
    - checks : **V61 Custom** (120 000) et **SYG-12** (180 000), absents de tous les scans et
      ramassages, donc vendus uniquement par le Duc ; Crosse V61, Viseur SYG-12, Gros barillet
      Wolfsbane ;
    - rachats : GM 79 et M1851 Wolfsbane, trouvés dans le monde.
    - Total : environ 24 checks de boutique.
  - À faire : `build_data_from_scans.py` doit aussi lire `pickups_log.jsonl`, où certains
    placements ne sont connus que par leur ramassage.
  - Outils suivants :
    - « EXPERIENCE : article de test » : ajoute « 1 poudre pour 1 Lei » via un post-hook de
      `collectBuyUnits`. **Testé le 2026-09-25 : ça marche.** L'article s'affiche et
      s'achète, et `decideBuyItem` reçoit un itemCore avec l'ItemID de l'article (3461208890).
      C'est donc là qu'on identifiera un achat « Archipelago ».
      - `collectBuyUnits` est rappelé très souvent (reconstruction de la liste) : l'article
        doit être réinséré à chaque fois, et masqué une fois acheté.

## Corrections de méthode (2026-09-25, soir)

- **Un scan par zone NE suffit PAS dans le Village.** Ses secteurs (`..._Separetor_NN`) ne se
  chargent qu'à l'approche du joueur : 4 objets ramassés (bombe tuyau, munitions, 2 grenades,
  secteur `Separetor_12`) n'étaient dans aucun scan. Ça marchait pour le château, chargé d'un
  coup.
  - Remède : **scan automatique** toutes les 10 s en jeu, cumulé par GUID dans
    `placements_all.json`.
  - Surveiller un éventuel à-coup toutes les 10 s.
- **Coffres au trésor : placements NORMAUX** (confirmé par le joueur, 2026-09-25) :
  - le coffre des ruines de la maison de Luiza contenait le **Collier de Luiza**
    (`SpawnInfo_VillageElenaNecklaceFallByAttack_005`, placement normal, catégorie objet clé) ;
  - l'Aile cristallisée ramassée au même endroit était le butin d'un **monstre volant**
    (`EmDrop`), donc un vrai drop d'ennemi ;
  - même constat à la maison du luthier : trésor « Hræsvelg d'acier »
    (`SpawnInfo_Treasure_IronEagleStatue_006`), placement normal ;
  - donc : les coffres seront des checks comme le reste, et les `EmDrop` / `RandomDrop`
    (ennemis, animaux, caisses aléatoires) restent exclus.
- **Exclusion par nom « Village* »** : à remplacer par la catégorie du catalogue
  (`item_catalog_fr.json` : « Objet clé », « Trésor »…), plus fiable.

## Zones ratables (décision du 2026-09-25)

Certaines zones ne sont plus accessibles après leur boss (château Dimitrescu, et
probablement maison Beneviento et usine). Leurs checks manqués seraient perdus, y compris
les items des autres joueurs.

- **Option yaml `missable_checks`** (dans `Options.py`, transmise au client via slot_data) :
  - `zone_exclue` : les locations marquées `"missable": true` sont EXCLUDED, donc ne
    reçoivent que du filler. **Déjà câblé** dans `__init__.py`.
  - `envoi_auto` (par défaut) : le client envoie les checks restants de la zone quand elle
    est quittée pour de bon. **À faire côté client** : détecter la sortie définitive (changement
    de chapitre ?).
  - `cent_pourcent` : impossible de quitter la zone tant qu'il reste des checks. **À étudier** :
    bloquer l'interaction qui lance le boss ou la sortie, avec un message.
- À faire : marquer `"missable": true` par zone dans `tools/build_data_from_scans.py`, et
  afficher un compteur « X checks restants » par zone.
- Zones ratables confirmées en jeu :
  - **Maison Beneviento** (`Chapter2_3/st04`) : impossible d'y rentrer après le boss
    (2026-09-25). Contenu : 13 objets d'énigme + Angie (trésor).
  - **Château Dimitrescu** (`Chapter2_2/st03`) : confirmé ratable, inaccessible après le boss.
    Contrairement à la maison, beaucoup d'objets facultatifs : au dernier scan dans le château,
    ~30 placements (hors drops) n'étaient pas ramassés (9 trésors, 1 pièce d'arme, munitions,
    ~13 sacs de Lei). C'est le cas d'usage type d'`envoi_auto` et du compteur par zone.
  - La maison Beneviento ne contient que des objets obligatoires pour l'histoire : aucun risque
    tant que ses énigmes ne sont pas mélangées.
  - **Réservoir de Moreau** (`Chapter2_4/st05`) : **NON ratable**. On peut y revenir après le
    boss, notamment pour un trésor (indiqué par le joueur).
- Piste de détection de la sortie définitive : la zone n'est plus chargée ET un chapitre
  suivant l'est (ex. `Chapter2_3` absent et `Chapter2_6`+ présent après le boss).
- **Piste 4 (idée du joueur)** : téléportation aux machines à écrire déjà utilisées, via un
  menu. Le client RE7 le fait déjà (`reference_re7/.../Typewriters.lua`). Incertain dans
  Village pour les zones d'un chapitre terminé : scène non chargée, état incohérent. « À tes
  risques et périls ».

## Armes-checks et arme en main (2026-09-25)

- Problème (signalé par le joueur) : au ramassage d'une arme, le jeu la met en main pour
  l'animation. Retirée de l'inventaire, elle restait tenue jusqu'au changement d'arme.
- `app.EquipController` n'est pas un composant de scène : `findComponents` ne le trouve pas.
  C'est un agent rangé dans `CharacterCore`. On le capture via un hook sur
  `isGunEquip` / `isMeleeEquip` / `currentPlayerWeaponId`, en gardant celui qui a le plus de
  `ManagedWeapons` (13 pour Ethan).
- `EquipController.equipWeapon(itemID, findEquipParamNameByID(itemID))` change bien l'arme
  **dans les données** (ex. `ri3022` pour le couteau), mais **sans l'animation** : arme rangée
  sans rien sortir, puis deux armes en main. **Ne pas utiliser.**
- Solution retenue : bloquer (SKIP_ORIGINAL) `app.PlayerMovement.requestUseGetWeapon(item)`,
  qui met en main l'arme ramassée, quand cette arme vient d'être détectée comme check (< 3 s).
  L'ordre des appels (ramassage puis mise en main) est à vérifier : chaque appel est noté
  dans `debug_log.txt`.
- **Test en jeu du 2026-09-26 (M1897, nouvelle partie)** : `requestUseGetWeapon` n'est **jamais**
  appelé, et l'arme-check se retrouvait en main, avec l'animation, puis retirée 2 s après.
  Le ramassage appelle `PlayerOrder.notifyPickUpWeapon(WeaponCore)`, puis
  `PlayerOrder.requestUseItem(ItemCore, for_event, restore_request) -> Boolean`.
  Correctif : `requestUseItem` est bloqué (SKIP_ORIGINAL, renvoie false) pour une arme-check
  ramassée il y a moins de 3 s. Même chose sur `PlayerOrderPl2001` (Chris). Les changements
  d'arme normaux passent (vérifié hors jeu). **À vérifier en jeu.**
- Autres pistes vues dans le dump : `PlayerOrder.requestUseSavedEquipWeapon()`,
  `IPlayerWeaponChangeTPS.requestEquipWeapon(weapon, isOwnerTaskStart)`.

## Suivi par zone (idée du joueur, 2026-09-25)

- La zone est reconnue au chemin de dossier des placements. Table `ZONES` dans le client :
  - `Chapter2_1/st10`, `Chapter2_6/st10` et `c02_ChapterBridge` → Village ;
  - `Chapter2_2/st03` → Chateau Dimitrescu ;
  - `Chapter2_3/st04` → Maison Beneviento.
  - `Chapter2_4/st05` → Reservoir (Moreau). 55 placements dont 5 trésors, sans salles nommées
    (extérieur). Relevé en entier par le scan automatique avant le scan manuel.
- La zone actuelle est la zone majoritaire parmi les placements chargés, recalculée par le scan
  automatique toutes les 10 s.
- Affichage à l'écran : « Zone X : a / b checks ». Le menu donne le détail par zone.
- **Les noms de zone doivent rester identiques aux régions de l'apworld.** Compléter `ZONES`
  à chaque nouvelle zone scannée.
- **Suivi par salle** (idée du joueur) :
  - `ItemSpawnInfo.MapRoomNames[0].MapRoomNameHash` → `MapManager.findRoomData(hash)` →
    `RoomUnit.RoomNameGUID` → texte, par exemple « Maison Beneviento - Atelier » ;
  - salle actuelle : `MapManager.get_currentRoomUnit()` (NameHash, RoomNameGUID).
  - **Validé sur la maison Beneviento** : 10 objets sur 14 ont une salle nommée, 2 ont une salle
    « -1 » (sans nom), 2 n'ont pas de salle.
  - Les scans enregistrent `room_hash` et `room`. À propager dans `locations.json` pour le
    compteur « Salle X : a / b checks ».

## Options yaml des objets clés (2026-09-25)

Déclarées dans `Options.py` et transmises au client via slot_data, mais **pas encore
appliquées** : les objets clés restent vanilla tant que la progression n'est pas modélisée.
- `randomize_key_items` (non par défaut).
- `randomize_beneviento_puzzles` (non par défaut, ne compte que si la précédente est activée).
  Demande du joueur : dans la maison Beneviento, on n'a plus d'armes et les énigmes
  s'enchaînent. Attendre un objet d'un autre joueur y bloquerait la partie.
- **Règle à prévoir : objets clés d'une zone qu'on ne peut plus revisiter** (demande du joueur,
  2026-09-27, exemple : la Bille du château, qui sert à une énigme donnant un trésor). Placés
  dans leur zone ou avant, sinon on ne peut plus les utiliser : check de l'énigme envoyé à
  vide par l'envoi auto (frustrant), ou blocage si l'objet ouvre la suite (clé, masque).
  Partie seule : toujours dans la zone. Multiworld : même règle par défaut, option pour
  l'assouplir (le joueur peut hinter). Écrire aussi les règles « check -> objet requis »
  (trésor de la bille -> Bille).

## Objets jamais mélangés (anti-blocage)

Liste `NEVER_RANDOMIZE` dans `tools/build_data_from_scans.py`. Ces objets restent vanilla même
avec `randomize_key_items` :
- couteau et pistolet de départ (premier combat) ;
- **Manivelle** du réservoir (`HalfFishCrank`, ItemID 1142718375) : sert à s'échapper pendant
  la poursuite de Moreau. Sans elle, le joueur meurt en boucle (signalé par le joueur).
- **Calice des géants** (`VillageHolyGrail`) et les **4 bocaux de Rose**
  (`WitchBodyDonation_Head`, `SpiritBodyDonation_Leg`, `HalfFishBodyDonation_Arm`,
  `GeekBodyDonation_Body`) : cœur de l'histoire (signalé par le joueur).
- Les énigmes de la maison Beneviento ont leur propre option.
- Objets de quête facultative (ex. **Collier de Luiza**, catégorie « Objet clé » ; il sert à
  une mission selon le joueur) : mélangeables quand `randomize_key_items` sera actif. Au pire
  la mission attend l'objet, sans bloquer l'histoire.
  - Précision du joueur : on **examine** le collier dans l'inventaire pour en sortir un
    **cristal** (le vrai trésor). Un objet obtenu par examen ne passe pas par le hook de
    ramassage : pas détecté aujourd'hui. Piste après la V1 : checks « objet obtenu par examen ».

## Options boutique et difficulté (demandes du joueur, 2026-09-26)

- `randomize_duke_shop` : les articles uniques du Duc deviennent des checks (consommables et
  rachats jamais touchés). À implémenter côté client.
- `randomize_shop_inventory_expansions` (oui par défaut, ne compte que si la précédente est
  active) : les Valises sont aussi des checks.
- `difficulty` : `au_choix`, `casual`, `standard`, `hardcore` ou `village_des_ombres`.
  - Si la partie n'est pas dans cette difficulté, les checks sont **ignorés** et un
    avertissement s'affiche. **Déjà câblé** dans le client.
  - Lecture : `app.GameRecordManager.getDifficulty(false)`.
  - `getDifficulty` renvoie un identifiant haché. La table est lue dans
    `app.GameOptionManager.get_userdatas()` → `Difficulties` (Difficulty, MessageGUID).
    Relevé le 2026-09-26 :
    - Facile (casual) = 2081395632 ;
    - Standard = 1948795948 ;
    - Hardcore = 4054003385 ;
    - Village des ombres = 3214231311.
- Usine de Heisenberg : `Chapter2_5/st06`, 141 placements (16 trésors), salles par étage.
  Scan : `reference/scans/usine_heisenberg_chapitre2_5_scan_20260926.json`.

## Passage avec Chris (2026-09-26)

- `Chapter3_1/st17` : 49 placements, uniquement de l'équipement de Chris (23 munitions,
  11 explosifs, 5 soins), aucun trésor ni objet clé.
- Chris a **son propre inventaire**. **Décision (avec le joueur)** : le passage Chris est
  presque la fin du jeu (juste avant le combat contre Miranda), donc :
  - ses 49 placements **sont des checks** ;
  - leur contenu (munitions et soins de Chris) est mélangé **uniquement entre les
    emplacements de Chris** (items « locaux »), pour que Chris garde l'équipement dont il a
    besoin ;
  - les items destinés à Ethan reçus pendant le passage Chris sont mis en attente, et donnés
    quand Ethan reprend la main. L'inventaire actif se lit via
    `InventoryManager.getActiveInventoryName()`.

## Idées de checks pour plus tard

- **Animaux** (optionnel selon le joueur) (poissons, cochons, poulets…) : en nombre limité par zone et sans réapparition.
  Leur butin sort d'emplacements de drop (`ItemSpawnInfo_EmDrop_ForBridge_*`, « Poisson » vu le
  2026-09-25), donc exclus aujourd'hui. Piste : un check par animal tué.
- **Plats du Duc (PRIORITAIRE, demandé par le joueur)** : bonus permanents (santé,
  défense, vitesse…) cuisinés à partir d'ingrédients de chasse. **Un check par plat.**
  - `app.RecipeManager` (singleton) : `completed(recipeID)`, `isCompleted(recipeID)`,
    `findData(recipeID)`.
  - `userdatas` → `RecipeManagerUserData.Unit` (RecipeID, MaterialUnits, Reward).
  - Sauvegarde : `SaveData.Unit` (IsCheckIt, IsCompleted).
  - Écran de cuisine : `app.GUIShopRecipe`.
  - Plan : hook de `completed` → check.
  - **Relevé fait (2026-09-25)** : 6 plats, dans `reference/plats_du_duc.json`.
    - Poisson aux herbes, Mititei aux trois saveurs, Tochitura de pui (vie) ;
    - Pilaf complet, Ciorba de porc (dégâts en garde) ;
    - Sarmale de peste (vitesse).
    - Chaque plat a ses ingrédients (ItemID + `Value` = quantité), un texte de récompense et un
      montant `Money`.
    - `checkIt(recipeID)` est appelé quand on consulte un plat.
    - **Confirmé en jeu** (Poisson aux herbes, 4293784029) : `delived(recipeID, index, count)`
      pour chaque ingrédient donné, puis `completed(recipeID)` quand le plat est cuisiné.
      **Le check se déclenchera sur `completed`.**
  - Idée : faire aussi des bonus permanents des items AP.

## Objectif (goal) et feuille de route après la V1 (demandes du joueur, 2026-09-25)

- **Option yaml `goal`** (déclarée, transmise en slot_data) :
  - valeurs : `tous_les_checks` (seul fonctionnel pour l'instant), `fin_du_jeu`,
    `tous_les_seigneurs`, `dimitrescu`, `beneviento`, `moreau`, `heisenberg` ;
  - détection des boss en cours : `EnemyManager.registerDeadEnemy` est journalisé dans
    `kills.jsonl` et `debug_log.txt` (nom interne emXXXX) pour identifier chaque boss au
    prochain combat. Le dump contient aussi des classes « BossBattle » par ennemi
    (`Em1060…Castle_BossBattle`…).
  - **Identifiants de boss confirmés** (nom du GameObject au `registerDeadEnemy`) :
    - Moreau : **`em1302`** (réservoir, `Chapter2_4/.../em1302Pool`, 2026-09-25 23:29).
    - Boss de la forteresse (Urias, lycan au marteau) : **`em1060`** (`Chapter2_6/.../em1060Pool`,
      2026-09-25 23:57). Le dump a `Em1060…c02_6_Castle_BossBattle` et
      `…c03_1_Armor_BossBattle` : il reviendra sans doute en version blindée.
    - `em1240` : lycans de base (tués juste avant).
    - Mini-boss loup-garou de la maison brûlée (après la forteresse) : **`em1281`**
      (`Chapter2_6/.../em1281Pool`, 2026-09-26 00:01). Il était accompagné de `em1251`.
    - Mini-boss cyborg à hélice de l'usine (Sturm) : **`em1040`** (`Chapter2_5/.../em1040Pool`,
      2026-09-26 00:39), confirmé par la classe `Em1040ThinkStateSet_st06_BossBattle`
      (`st06` = usine).
    - `em1030` / `em1031` : soldats de l'usine.
    - Urias Strajer (version évoluée qui garde le Mégamycète, partie Chris) : **`em1061`**
      (`Chapter3_1/.../em1061Pool`, 2026-09-26 00:55), cohérent avec
      `Em1060…c03_1_Armor_BossBattle`.
    - **Heisenberg : PAS de `registerDeadEnemy`** (combat scripté du char, 2026-09-26 ~00:46).
      Dimitrescu et Beneviento sont probablement dans le même cas. Détection alternative :
      - ramassage du **trophée** du boss : « Cerveau d'Heisenberg » (trésor, ItemID
        3784538847, dans l'arène `Chapter2_7/st15`, 6 placements) ; pour Dimitrescu
        « Dimitrescu cristallisée », pour Beneviento Angie ;
      - progression : hooks `LevelFlowManager.setCompleteChapterFlag` / `setChapterStart` et
        suivi de `SceneTransitionManager.get_CurrentChapter()`, journalisés dans
        `progress.jsonl` depuis 00:47 (à analyser au prochain boss).
    - **Miranda / fin du jeu (confirmé le 2026-09-26 01:05)** : pas de `registerDeadEnemy`.
      Mais `GUIManager.get_isEnableEndingFlow()` passe à **true** pendant la fin, alors que
      `SceneTransitionManager.get_CurrentChapter()` = `Chapter3_2`, puis le chapitre devient ""
      (écran de résultats). **Règle de l'objectif `fin_du_jeu` : EndingFlow true en
      Chapter3_2.**
    - `get_CurrentChapter()` renvoie le nom du chapitre (texte). Il servira aussi à détecter la
      sortie définitive des zones ratables (envoi automatique).
  - Idée après la V1 : un check « boss vaincu » pour les mini-boss facultatifs.
    - Dimitrescu, Beneviento, Heisenberg, boss final : à relever (Dimitrescu et Beneviento
      ont été battus avant l'ajout du journal).
- **Après la V1** :
  - **colis (mallette pleine)** : première version faite le 2026-09-26 (objet refusé mis de
    côté, redonné toutes les 10 s dès qu'il y a de la place, liste dans le menu). À choisir
    plus tard : le récupérer chez le Duc (article à 0 Lei) ou via un menu avec un bouton
    « Récupérer » ;
  - **option de yaml « % de difficulté du randomizer »** (demandée le 2026-09-26), comme
    dans d'autres apworlds. Le joueur donnera le vrai nom de l'option à reprendre ;
  - checks dans les **mini-jeux** du jeu ;
  - **DLC « Shadows of Rose »** : pour les 100 %, finir la partie Ethan PUIS la partie Rose ;
  - **mode Mercenaires** : objectif combiné, par exemple « fin du jeu ET score Mercenaires ≥
    N (ex. 100 000) ». Le goal n'est envoyé que si les deux conditions sont remplies, dans
    n'importe quel ordre.

## V2 CONSTRUITE (2026-09-26, à tester en jeu sur une nouvelle partie)

- **455 locations** : 424 objets posés (Village 151, Usine 107, Château 93, Chris 39,
  Réservoir 27, Fin du jeu 6, Maison Beneviento 1), 25 articles de boutique, 6 plats.
- Exclus : drops, objets clés, `NEVER_RANDOMIZE`. Items de Chris mélangés entre ses propres
  locations.
- Client : checks de boutique (achat bloqué, prix retiré, articles faits masqués sauf si reçus),
  checks de plats, objectifs (boss par trophée / `em1302`, fin du jeu par EndingFlow), envoi
  automatique des zones ratables au changement de chapitre, items d'Ethan en attente pendant
  Chris.
- **Tests hors jeu** (`tools/test_net_offline.lua`, `tools/test_client_offline.lua`) : ils
  tournent contre un **serveur de TEST sur le port 38283** (`seeds/test_offline/`), jamais sur
  le serveur de la partie (38281) ni sur celui des tests en jeu du joueur (38282). Le 2026-09-26,
  des tests avaient envoyé 2 checks dans la seed du joueur (seed régénérée), puis un test lancé
  sur 38282 a atteint l'objectif pendant un test en jeu du joueur (tous les items reçus).
  Validé hors jeu : plat → check → item reçu ; achat → 3 500 Lei retirés → check ; sortie du
  château → 93 checks envoyés automatiquement ; fin du jeu → objectif atteint.
- Exemple de configuration : `docs/exemple_config.yaml`.

### Test en jeu du goal (2026-09-26, save avant Miranda, serveur de test 38282)

- Fin du jeu détectée (EndingFlow en Chapter3_2), objectif envoyé, le serveur indique la partie
  comme terminée : **OK**.
- **Crash** 4 s après : au goal, le serveur fait un release, et environ 450 items ont été donnés
  dans la même frame pendant la cinématique de fin (c0000005 dans re8.exe).
  Correctif : les items sont donnés un par un, espacés de 0,25 s (`ITEM_GIVE_INTERVAL`), et
  rien n'est donné pendant EndingFlow. Vérifié hors jeu (`test_client_offline.lua` teste les
  deux cas) et **en jeu le 2026-09-26** : 455 items reçus au release, gardés en attente
  pendant la fin, aucun crash.
- **2 FPS** pendant le combat contre Miranda. Deux coûts identifiés :
  - à chaque frame, l'inventaire était parcouru une fois par ItemID suivi (~86 fois). Il est
    maintenant parcouru une seule fois par frame ;
  - le **scan automatique** (toutes les 10 s, tous les ItemSpawnInfo de la scène, avec écriture
    de `placements_all.json`) est **retiré**. Il servait à relever les placements pour la V2.
    La zone affichée, et l'attente des items d'Ethan pendant Chris, viennent maintenant du
    chapitre (`CHAPTER_ZONES`). Le scan manuel « Scanner la zone » reste dans le menu.
  Pas encore revérifié en jeu.
- **Maison de Luiza ratable** (2026-09-26, nouvelle partie) : inaccessible après l'attaque
  des lycans. Le joueur a raté la Plante #001, et le client n'a vu aucun signal à ce moment
  (pas de changement de chapitre, pas d'étape d'histoire journalisée).
  - Correctif : `MISSABLE_SPOTS` dans `build_data_from_scans.py` marque ses 3 locations
    (`missable_spot`), et l'apworld les met toujours en **EXCLUDED** : objets sans importance
    uniquement, donc un oubli ne bloque personne (vérifié sur 6 seeds). Le check reste
    perdu, sauf envoi manuel.
  - Envoi manuel d'un check raté : `tools/send_location.lua` (lancé depuis `client/`).
    Utilisé pour la Plante #001.
  - À faire : trouver le signal de l'attaque pour envoyer ces checks automatiquement.
- **Passage souterrain ratable** (signalé le 2026-09-26) : ses 2 checks (Sac de Lei #002,
  Munitions pour pistolet #001, secteur S09) sont ajoutés à `MISSABLE_SPOTS`.
- **Boutique du Duc, testée en jeu le 2026-09-26** (serveur de test 38282) :
  - **MÉTHODE FINALE (validée en jeu le 2026-09-26, Valise, Formule et amélioration)** : pour
    un article-check, le hook de `buyItem` **saute l'achat du jeu** (SKIP_ORIGINAL, renvoie
    true). Le mod débite le prix affiché (`shop_unit_price`) et envoie le check, et la liste est
    reconstruite (`collectBuyUnits`, `sortBuyItem`, `setupScrollGrid`, `setupScrollList`).
    Rien n'est donné : ni objet, ni recette, ni agrandissement. Sans assez de Lei, le jeu
    refuse normalement. L'article est marqué acheté dès le clic (`shop_bought_keys`). Les
    notes ci-dessous (achat puis retrait, remise du niveau de mallette, retrait de la recette)
    décrivent les essais précédents. Ce code reste en secours dans `decideBuyItem`.
  - **Valise-checks** : prix de progression 10 000 / 30 000 / 50 000 d'après le nombre de
    Valise-checks faites, et au plus 1 proposée au château (Chapter2_1/2_2), 2 ensuite, 3 dès
    l'usine (`adjust_valise_unit`). Toutes faites : comportement normal du jeu.
  - **Formule** : la recette débloquée n'est ni dans `craftStateUnits` (marqueurs « nouveau »),
    ni seulement dans les objets ou l'historique : la retirer partout la laissait en
    Confection. D'où la méthode finale.
  - **Achat-check** : l'objet acheté est ajouté dès `buyItem`, et le prix est débité par le jeu
    après `decideBuyItem`. Bloquer `decideBuyItem` (SKIP_ORIGINAL, ancienne méthode) n'empêchait
    ni l'un ni l'autre : objets en double, et prix payé deux fois (le mod le retirait aussi).
    Nouvelle méthode : l'achat se fait normalement, puis l'objet est retiré 2 s après, comme un
    ramassage. La quantité « avant » vient du relevé de la frame précédant le clic. Le mod ne
    retire que la part du prix que le jeu n'a pas débitée. **Validé en jeu** (1 → 2 → 1,
    8 000 Lei débités une fois).
  - **Article-check déjà possédé** (reçu par un check, ex. Détente sensible) : le jeu le refusait
    (`canBuyItem` = NoCan) ou le masquait. Hook `canBuyItem` → Can (si assez de Lei) et
    `isSoldOutByUnit` → false. S'il est absent de la liste et déjà reçu par Archipelago, il est
    remis en vente (`add_ap_shop_units`). Validé en jeu.
  - **Nom « [AP] <objet reçu> »** : l'objet de chaque location de boutique est demandé au
    serveur à la connexion (`LocationScouts`, `net.location_scouts`), avec « (joueur) » s'il va
    à un autre joueur. Réécrit par la boucle du jeu tant que la boutique est ouverte
    (`update_shop_label`). Validé en jeu.
  - **Colis à 0 Lei** : chaque objet du colis est proposé à 0 Lei, nommé « [Colis AP] … ». Le
    rachat du jeu (ex. M1897 à 24 000, proposé parce que l'arme a été ramassée dans le monde)
    reste en vente. L'acheter retire aussi l'objet du colis.
  - **Freeze** : un hook sur `onLateUpdate`, puis sur `scrollGrid/ListSelectionChanged`, faisait
    figer le jeu (au Reset scripts, puis au démarrage). Ces hooks sont désactivés
    (`SHOP_HOOK_RENAME = false`). Cause exacte inconnue.
  - Logo Archipelago à la place de l'icône : pas fait (V3, visuels).
  - **Prix** : il change avec l'avancement (Valise à 10 000 au château, 50 000 dans les
    données de fin de partie). Le mod ne débite donc QUE si le jeu n'a rien débité, au prix
    affiché (`shop_unit_price`), jamais en dessous de 0. Avant ce correctif, il avait retiré
    40 000 de trop (argent à −8 290).
  - **Formule reçue** par Archipelago (`createAndAddItem`) : elle est bien apprise (recette des
    mines, validé en jeu).
  - **Valise reçue** : `createAndAddItem` puis `addExtendLevel` seul agrandissaient la grille,
    mais laissaient des objets superposés. Au vrai achat, le jeu appelle `setExtendLevel` puis
    `addExtendLevel`, qui renumérotent les cases (9 → 11 colonnes). Pour un don, une partie
    des objets revenait ensuite à son ancienne case, sans doute par `lastSlotNo`. Correctif :
    `addExtendLevel`, puis `lastSlotNo` et `centeringSafeSlotNo` alignés sur la nouvelle case.
    **Validé en jeu.** La réussite ne dépend que d'`addExtendLevel`, pour ne jamais réessayer
    un agrandissement déjà fait.
  - (Résolu par la méthode finale ci-dessus : une Formule ou une Valise achetée comme check ne
    donne plus la recette ni l'agrandissement.)
- **Rechargement de sauvegarde (à corriger en priorité)** : les objets reçus depuis la dernière
  sauvegarde sont perdus. Le jeu revient en arrière, mais `last_applied_index` non. Idée :
  noter l'index à chaque sauvegarde du jeu, et redonner ce qui suit au chargement.
- **Options du yaml remises à jour (2026-09-26)**, contrôlées avec le générateur de modèles
  d'Archipelago (`Players/Templates/Resident Evil Village.yaml`) :
  - actives : boutique du Duc (activée par défaut), Valises, difficulté, objectif
    (`fin_du_jeu` par défaut, validé en jeu ; seigneurs non testés), zones ratables
    (`zone_exclue` / `envoi_auto`) ;
  - marquées « (pas encore actif) », avec une valeur par défaut sans effet : trésors vendus,
    munitions, pièges (0 %), objets clés, énigmes Beneviento ;
  - retirés : le lien de mort (DeathLinkMixin, pas géré par le client) et le choix
    `cent_pourcent` (les checks d'une zone quittée auraient été perdus sans prévenir).
  - Copie de l'apworld à tester : `residentevilvillage.apworld` à la racine du projet.
- **Visuels Archipelago dans la boutique (validé en jeu le 2026-09-26)** :
  - Objets de CE jeu : l'article-check est affiché sous l'objet qu'il donne (modèle, icône, nom
    « [AP] … », catégorie et description écrites par le mod depuis items.json).
  - Objets d'un AUTRE jeu : affichés sous le **porteur Archipelago**, `Item_VillageProto_000`
    (3155046651), un prototype inutilisé.
    - **Icône** : logo collé dans la case 19 (inutilisée) de la planche
      `gui/ui0100/tex/ui0100_iam.tex` (`tools/re_engine/make_ap_icon.py`). Au chargement, le mod
      fait passer l'`IconPatternNo` du porteur de 20 à 19.
    - **Modèle 3D** : le porteur reçoit le prefab d'inventaire du Remède (ri1020), la seule façon
      pour que `createItemCore` accepte l'objet : un nom de ressource inventé (« ri9990 ») fait
      lever une exception. Ensuite, le mod remplace **à la volée** le maillage et le matériau de
      l'objet affiché (`ri1020_DetailSearch`, via `setMesh` / `set_Material`), et les remet
      d'origine pour un vrai Remède (`shop_ui.update_preview`).
    - Fabrication du modèle : `python tools/re_engine/make_ap_model.py Assets/boul505000e.fbx
      Assets/Untitled.png`. Blender 4.3.2 portable et l'addon RE Mesh Editor sont dans
      `tools/blender/` (non versionné). Le modèle est **greffé sur le maillage du flacon** : on
      garde les 7 morceaux, leur squelette (os `_00`), leurs 2 jeux d'UV et l'ordre des
      matériaux ; le bouchon (Cap_Mat) reçoit la géométrie, les autres morceaux sont réduits à
      un point. Il est centré sur le milieu réel du flacon (z = 0,063), avec une taille de 0,08.
      Les textures sont en BC7 / BC1 avec les en-têtes du flacon, en version de base (512, 7 mips)
      et streaming (2048, 9 mips), alpha à 10 (à 0, l'encodeur BC7 mettait la couleur à noir).
    - Leçons des essais : maillage construit de zéro = damier (même avec le matériau d'origine) ;
      la scène Blender par défaut contient un cube 2 x 2 x 2 qui faussait taille et centre ; la
      boutique repositionne l'objet affiché à chaque image (décalage de position inutile), mais
      l'échelle, elle, tient.
  - **Chargement des fichiers** : le chargeur « loose » de REFramework est activé
    (`LooseFileLoader_Enabled=true`, fait par install.py). Les textures des matériaux 3D sont
    aussi dans un pak de patch, **`re_chunk_000.pak.patch_014.pak`** (`tools/re_engine/pak_build.py`,
    le jeu a ses propres patches 001 à 013). install.py le construit et le copie, et n'écrase
    jamais un patch_014 qui ne serait pas le nôtre.
  - Outils : `tools/re_engine/pak_extract.py` (extraction des .pak, liste `RE8_STM_Release.list`
    d'Ekey/REE.PAK.Tool), `tex_writer.py` (écriture de .tex non compressés ou BC).
  - Reste : un modèle pour les objets de ce jeu qui n'en ont pas dans la boutique (Poudre noire :
    aperçu vide) ; les fichiers ri9990 (prefabs) produits par make_ap_model.py ne servent plus.
- Lancement : REFramework bloque parfois au démarrage (écran noir, blocage pendant
  « Suspending » dans `re2_framework_log.txt`), avant que le mod soit chargé. Il faut relancer
  le jeu.

## Derniers ajouts (2026-09-27, à vérifier en jeu)

- **Nettoyage** : le prefab « ri9990 » (abandonné, il cassait la création de l'objet porteur)
  n'est plus généré (`tools/re_engine/make_ap_model.py`), fichiers supprimés.
- **Objets de ce jeu sans modèle de boutique** (Poudre noire, matériaux…) : l'article est
  affiché sous le porteur Archipelago (icône + modèle AP), mais garde son nom, sa catégorie et
  sa description (`apply_shop_swaps` : `findPrefab` nil → porteur, `shop_ui.ap_model_units`).
- **Rechargement de sauvegarde** (objets reçus depuis la dernière sauvegarde perdus) : hooks
  `app.SaveLoadManager.StartSave/StartLoad` (numéro d'emplacement) et
  `app.InventoryManager.GetSaveSection/WriteBackSaveData`. À chaque sauvegarde, l'état
  (`state.saves[emplacement]` = index du dernier objet donné + colis ; `state.checkpoint` pour
  la reprise après la mort) est noté ; quand la mallette est remise depuis une sauvegarde, les
  objets reçus après sont redonnés (historique des objets du serveur : `save_sync.history`).
  Journal : lignes « sauvegarde (emplacement N) » et « chargement (emplacement N) ».
- **Salles** (vignes du château) : une salle relue après le ramassage de son seul check
  était notée « vue » pour toujours avec 0 check (« pas de checks dans cette salle »).
  Désormais : notée vue seulement si la lecture trouve quelque chose (5 essais max), et chaque
  check ramassé est rattaché à la salle où l'on est. Les vignes sont dans le chapitre du
  château (Chapter2_2/st03) : leurs checks sont ratables, donc envoyés tout seuls à la fin du
  château (option `envoi_auto`, par défaut) ou exclus (`zone_exclue`).
- **DeathLink** : option standard `death_link` (apworld, slot_data). Client : tag DeathLink
  (`ConnectUpdate`), réception par `set_bounced_handler` (boîte aux lettres, événement
  « death »), envoi par `Bounce` au début du game over (`app.GameOverManager.get_isRunning`
  passe à vrai), mort reçue = `app.GameOverManager.requestGameOver()` dès qu'on est en jeu. Le
  game over ainsi provoqué n'est pas renvoyé (15 s). Bouton de test dans les outils de dev.
- **Oubli de sauvegarde** : couvert par le point « Rechargement de sauvegarde » ci-dessus (au
  lancement du jeu, le chargement est noté puis comparé une fois connecté). Limite : une
  sauvegarde faite AVANT cette version n'a pas d'état noté, rien n'est redonné pour elle.
- **Vrais modèles dans la boutique** : la boutique ne précharge que les modèles des objets
  vendus d'origine (prefab DetailSearch ; liste des 291 riNNNN qui en ont un + leur maillage :
  `shop_models.json`, `tools/re_engine/make_shop_models.py`). Un objet de ce jeu sans modèle
  (matériaux, Sac de Lei) garde son objet (icône, nom) et, le temps que la boutique est ouverte,
  son entrée de prefab pointe vers celle du porteur (Remède) ; le maillage de
  ri1020_DetailSearch est alors remplacé par son modèle au sol (`shop_ui.REAL_MODELS`) ou, à
  défaut, le modèle AP. Remis à la fermeture (`shop_ui.restore_prefabs`). Le journal liste les
  objets sans modèle connu (« objets sans modèle connu »).
- **Objets au sol** (`shop_ui.world`) : toutes les locations sont scoutées à la connexion.
  Pour chaque check à faire, les maillages de `ItemSpawnInfo.get_spawnInstance`,
  `InteractItemGet.ItemSetGameObject` et `MeshRotationGameObject` sont remplacés : modèle AP
  (autre jeu) ou vrai modèle de l'objet (présentation DetailSearch de son riNNNN, ou modèle au
  sol). Validé en jeu (plante des vignes). Le texte d'invite devient « [AP] objet » juste après
  `GUIInteractIcon.setInfo`, seulement si l'objet visé (`InteractItemGet.IsHighLightNow`) est
  un check (la distance faisait aussi changer machine à écrire, notes, Duc…). L'icône sous le
  nom (ItemCore de l'objet, celui qui entre dans la mallette) est cachée (`DispItemIcon`) ;
  journal « icône cachée » avec les deux ItemCore pour voir si l'un sert seulement à l'affichage.
- **Objets au sol, corrections du 2026-09-27 (validées en jeu)** :
  - invite « E Prendre » laissée d'origine (demande du joueur) ; « [AP] objet » et la bonne
    icône sont sur la ligne d'objet à l'écran (`GUIItemLineInfo.setItemID` : l'ItemCore du
    PARAMÈTRE d'affichage est remplacé par un objet créé pour l'occasion, vrai objet ou
    porteur AP ; l'objet ramassé n'est pas touché). La ligne reste liée à son check jusqu'au
    prochain setItemID. Tous les checks ont « [AP] », même s'ils donnent l'objet d'origine.
  - pots à objet aléatoire (`ItemSpawnInfoRandomDrop_NNN`) : pas des checks, laissés vanilla.
  - objets recyclés par le jeu (pool) : modèle, matériau, échelle et parties d'origine gardés
    et remis dès que l'objet ne sert plus à son check (`shop_ui.world.restore_unused`).
  - échelle rendue uniforme (logo AP « compressé »), matériau vérifié en continu.
  - parties du maillage : l'objet hôte (ex. Sac de Lei) n'affiche que certaines parties de son
    maillage (`getPartsEnable`) ; toutes sont réactivées sur le nouveau modèle (boîte de
    munitions « placeholder », Valise invisible). Valise = `sm80_058_Rucksack` (relevé boutique).
  - bouton « DIAG : modèles au sol » (outils de dev) : compare nos objets aux objets du jeu.
- **Valise reçue (2026-09-27, validé en jeu)** : objets superposés après l'agrandissement ;
  en plus de l'alignement des « dernières cases », l'affichage de la mallette est reconstruit
  (`GUIInventory.setupItemExtend`), comme le fait le jeu à l'achat.
- **Objets au sol, méthode 2 (2026-09-27)** : au lieu de greffer notre maillage sur le
  squelette de l'objet d'origine (Vivianite invisible sur un flacon sans os `_00`), le mod crée
  son propre objet (`via.GameObject.create` + `via.render.Mesh`), rattaché à l'os `_00` de
  l'objet d'origine (décalé de la position de son propre `_00`), et cache les maillages
  d'origine (`set_DrawDefault(false)`). Retiré (`destroy`) et objet d'origine réaffiché quand
  l'objet ne sert plus au check, et à « Reset scripts » (`re.on_script_reset`). Méthode 1 en
  secours. Vivianite validée ; orientation par l'os `_00` à vérifier.
- **Logo AP « en œufs »** : le modèle FBX lui-même (vérifié : boules rondes dans le fichier, dans
  le jeu la déformation se voit aussi en boutique en le faisant tourner, curseurs « Rotation
  X/Y/Z (boutique) » dans les outils de dev). Le joueur fournit un modèle corrigé ; le refaire
  avec `python tools/re_engine/make_ap_model.py Assets/<modele>.fbx Assets/<texture>.png`.
  **2026-09-29** : nouveau modèle refait (`Assets/boul505000e.fbx`, même texture
  `Untitled.png`), converti et installé (pak patch_014 compris). À vérifier en jeu : forme
  ronde en boutique (faire tourner) et au sol.
  **2026-10-03** : nouvelle version du joueur (même nom de fichier `Assets/boul505000e.fbx`, même
  texture) : maillage IDENTIQUE à celui du 29/09 (même géométrie dans le FBX). Le bon modèle
  corrigé est `Assets/ssnokayyyyy.fbx` (18h21), converti (maillage différent, vérifié par
  empreinte) et installé (pak patch_014 compris). **VALIDÉ en jeu** (2026-10-03).
  Seed de test `seeds/test_chateau` (seed 1005, serveur 38282) : Verre carmin #004 et Bague avec
  un œil écarlate #008 (début du château) donnent des objets de ChecksFinder. `test_cles3` gardée
  de côté (relancer son zip sur 38282 pour la reprendre).
- **Icône AP de la ligne d'objet (validée en jeu)** : avec le porteur, la ligne montrait le
  Remède (elle suit son prefab, ri1020, posé pour le modèle 3D de la boutique). La ligne utilise
  un second prototype inutilisé sans prefab, `Item_VillageProto_001` (2236906984,
  `shop_ui.LINE_CARRIER_ID`), à qui le mod donne l'icône AP (asset 0, case 19). Le logo est
  aussi dans la case 20 de ui0100 (`make_ap_icon.py`, cases 19,20).
- **Pose des objets AP au sol** : notre objet copie à chaque image la pose de l'os `_00` de
  l'objet d'origine (`shop_ui.world.follow_joint`), moins la position de son propre `_00`.
  Validé en jeu (2026-09-27).
- **Pièces d'arme au sol (2026-09-27 soir, validé en jeu pour la Crosse du V61)** : pas de
  fichier à part, la pièce est une partie du maillage de son arme ; l'examen dans l'inventaire
  (`riNNNN_DetailSearch`) n'allume que cette partie (Crosse V61 = partie 5 de
  `it02_002_Handgun_03`, ri7008). `shop_ui.PART_MODELS` (gid -> mesh, mdf, parts),
  `shop_ui.apply_parts`. Pièces pas encore relevées : mallette à pièce d'arme
  (`sm82_005_CustomPartsCase`). Relevé : copier `tools/dump_mesh_parts.lua` dans
  `reframework/autorun`, examiner la pièce, « Reset scripts », lire `mesh_parts_dump.txt`.
- **Checks faits, objet revenu avec une sauvegarde (2026-09-27 soir, validé en jeu)** : l'objet
  reste habillé, nom « [AP] … (déjà obtenu) » ; le ramasser ne donne rien (objet d'origine
  retiré, pas de renvoi). Modèle d'origine remis dès le ramassage (`save_sync.picked_locs`,
  vidé au chargement d'une sauvegarde).
- **Reste** : parties des 16 autres pièces d'arme à relever (examen de chaque pièce).
- **Test boutique** : option « TEST : logo AP à la place des vrais modèles dans la boutique ».
- **Crash à la connexion (2026-09-27)** : l'historique des objets d'une partie était redonné
  dans une autre après changement de serveur sans relancer le jeu. Historique et file vidés à
  chaque connexion ; un emplacement de sauvegarde sans état noté ne redonne plus rien ;
  distribution ralentie (1,2 s) quand plus de 10 objets attendent.
- **Test DeathLink** : seed `seeds/test_deathlink` (Ethan + Joueur2 ChecksFinder) sur 38282,
  faux joueur `tools/deathlink_test.py listen|kill` (fichier `build/deathlink_kill`). Mort
  reçue validée en jeu (game over, pas renvoyée). Mort envoyée validée en jeu le 2026-09-27
  soir (un seul envoi, reçue par Joueur2).
- **Message DeathLink « tué par … » (2026-09-27 soir)** : hooks sur
  ``PlayerDamageResponser`1<PlayerReferenceContainerFPS|TPS>`` : `calcDamage(damageInfo)` à
  chaque coup (debug_log « coup reçu », seulement quand l'attaquant change), `doDie(record)` à
  la mort (« mort d'Ethan »). Auteur = `DamageInfo.get_AttackOwner` (emXXXX), attaque =
  `AttackUserData` (ex. sœur em1261 `AttackNeckCut`, nuée `BugSlipAttacker`). Message
  « X was killed by <nom> in Resident Evil Village. » si l'auteur est dans
  `death_link.KILLERS`, sinon message générique et « auteur inconnu » au journal. À nommer
  (le joueur les donne en jouant) : em1250 (château), em1251, em1270 (volant), em1280 (grand
  saut), et laquelle des sœurs est em1261 / em1262.
  Confirmé ensuite : em1000 = Lady Dimitrescu (griffes `NailAttack_L`, 400) ; em1250 = monstres
  du sous-sol du château (faucille `ri3053_Shotel`, morsure `CommonBite`), nom à confirmer.
- **Pièces d'arme, toutes (2026-09-27 soir)** : parties lues dans la fiche du jeu,
  `ItemSpecification.findItemSpec(id).Attachment.OnPartsNos` (`shop_ui.part_model`, journal
  « pièce d'arme <id> : maillage …, parties … »), plus de table écrite à la main.
- **Icône AP sur la Plante de la boutique après « Reset scripts » (corrigé)** : l'entrée du
  porteur existait déjà, `setup_model` sortait sans retenir `shop_ui.model_holder`, donc
  `override_prefab` échouait et l'article passait sous le porteur.
- **Arme d'origine remplacée, mallette pleine (2026-09-27 soir, validé en jeu : F2 #013 -> Plante)** : Fusil F2 #013 ->
  Plante, « sac trop petit pour l'arme » : le jeu vérifie la place pour
  `InteractItemGet.ItemCore` avant le ramassage. `shop_ui.world.swap_pickup` remplace cet objet
  par un objet d'une case (vrai objet s'il est de ce jeu et pas une arme, sinon porteur AP),
  remis d'origine avec le modèle (`restore_pickup`) ; ramassé puis retiré comme un objet
  d'origine, l'objet AP arrive par le serveur.
  **Étendu à tous les objets au sol (2026-09-27, 22h30, validé en jeu le 2026-09-29)** : même blocage vu
  sur des munitions, mallette pleine. Tout check au sol (sauf sac de Lei et trésor) est désormais
  ramassé comme **1 Fragment de cristal** (`shop_ui.world.PICKUP_ID`, trésor : pas de case),
  retiré comme un objet d'origine. Aussi pour les checks dont l'objet AP est le même que l'objet
  d'origine (modèle « keep », `shop_ui.world.kept`). 1er essai en 1 Lei abandonné : le jeu
  affiche alors l'argent reçu au lieu de la ligne d'objet (plus aucun « [AP] »).
  La ligne d'objet montre l'objet posé à l'origine, pas celui du ramassage : `entry_for_item`
  reconnaît l'objet d'origine prévu, l'objet posé avant remplacement (`e.pickup.core`) et
  l'objet de remplacement (`e.pickup.gid`). Avant ce correctif, plus aucun « [AP] » ni icône.
- **Ligne « [AP] » des conteneurs (2026-09-27, 22h45, validé en jeu le 2026-09-29 pour la mallette)** : mallette à pièce d'arme
  ouverte, modèle changé mais ligne d'origine (l'objet posé, LEMI (1), n'est pas l'objet
  prévu, LEMI (2)). Cause (journal de 22h43) : **le jeu pose un autre objet à l'ouverture de la
  mallette ou à la casse d'une caisse** (LEMI (1) ; Lei pour « Munitions pour pistolet #012
  [S02] »), par-dessus notre objet de ramassage. `shop_ui.world.sync_pickup` (à chaque passage)
  prend ce nouvel objet comme objet d'origine et le remplace à nouveau s'il prend une case (pas
  pour Lei / trésor) ; `entry_for_item` compare aussi l'objet posé actuel ; Lei ramassés sur un
  check = retirés comme un sac de Lei. Une ligne sans check reconnu relance le relevé des
  placements (journal « ligne d'objet … sans check reconnu »).
  Test de 22h47 : `sync_pickup` n'a rien vu, le cache `SpawnedInteractItemGetCache` ne change
  pas. Le vrai objet est ailleurs : `ItemSpawnInfo.get_spawnItemId` (déjà utilisé par
  `find_spawn_info_for`, qui retrouvait la caisse #012 en Lei) et l'InteractItemGet de
  l'instance (`shop_ui.world.instance_get`). Ligne, remplacement pour le ramassage et
  reconnaissance au ramassage utilisent maintenant les deux (à valider en jeu).
- **Envoi auto à la sortie du château : validé en jeu (2026-09-27 20:58, vraie seed)** :
  `Chapter2_2 -> Chapter2_6`, 50 checks envoyés, les 93 checks du château validés côté serveur
  (lu dans l'.apsave). Les `pending_checks` du mod ne se vident qu'à la reconnexion (sans effet).
- **Objets superposés après la Valise + colis (2026-09-27, à valider)** : la Valise reçue à la
  sortie a laissé des objets superposés, et le colis ajoutait des armes par-dessus.
  `inventory_repair.run` (toutes les 5 s en jeu et avant chaque don du colis) : objet
  `Inventory.isOverlap` sorti de la grille puis reposé via `getBlankSlotNo`, sinon retiré et
  remis en tête du colis ; affichage reconstruit (`setupItemExtend`).
- **Idée : checks de chasse (option)** : animaux tués (`kills.jsonl`, ex. poisson) et viande
  ramassée (`pickups_log.jsonl`) ; relevé commencé le 2026-09-27.
- **Installateur** (modèle RE4R-AP-Wizard) : `python tools/make_release.py` produit
  `build/release/RE_Village_Archipelago_<version>.zip` = `Installer.exe` (tkinter +
  PyInstaller, FR/EN selon Windows) + `files/`. L'installateur trouve le jeu (Steam,
  libraryfolders.vdf) et Archipelago (registre), pose REFramework (dinput8.dll testé) s'il
  manque, copie le client, active les fichiers loose, met le pak de patch au premier numéro
  libre (ou à la place de l'ancien pak du mod), copie l'apworld dans `custom_worlds`, et tient
  un manifeste pour la désinstallation (connexion et état de partie gardés).

## PLAN V2 (réalisé, voir ci-dessus)

Toutes les données sont relevées (partie complète du 2026-09-25/26). Étapes :
1. `tools/build_data_from_scans.py` :
   - lire `docs/reference/scans/*.json` + `placements_all.json` + `pickups_log.jsonl` (à copier
     depuis `reframework/data/re_village_ap_client/`) ;
   - régions via la table des zones (Village, Chateau Dimitrescu, Maison Beneviento, Reservoir,
     Usine Heisenberg, Chris, Fin du jeu) ;
   - exclure : ItemID 0, `ItemSpawnInfo*` (drops), catégorie « Objet clé » (tant que
     `randomize_key_items` n'est pas implémenté), `NEVER_RANDOMIZE` ;
   - classer via `reference/item_catalog_fr.json` (catégories) ;
   - noter `missable` (château, maison) et `room` sur chaque location ;
   - items Chris « locaux » aux locations Chris.
2. Boutique : locations depuis `reference/shop_duc_complet_fin_20260926.json` (formules,
   améliorations, valises, V61 Custom, SYG-12). Client : injection BuyUnit (post-hook de
   `collectBuyUnits`), achat intercepté sur `decideBuyItem` → check, article masqué après achat.
3. Plats : 6 locations (`reference/plats_du_duc.json`), check sur `RecipeManager.completed`.
4. Objectifs : `fin_du_jeu` (EndingFlow en Chapter3_2), boss (ids ci-dessus + trophées),
   `tous_les_checks`.
5. Envoi automatique des zones ratables : `get_CurrentChapter()` passé au-delà de la zone.
6. Générer une seed, puis tester sur une **nouvelle partie**.

**V3 (ensuite)** : visuels (modèles d'objets / logo AP, marqueurs, textes de proximité,
tracker), launcher avec installation automatique.

## Prochaines étapes concrètes (dans l'ordre)

1. Tester la version 1 en jeu avec un serveur local : connexion, check, retrait de l'objet
   d'origine, item reçu, compteur.
2. Scanner les autres zones (château, maison Beneviento, réservoir, usine…) avec des
   sauvegardes de début de chapitre, puis relancer `tools/build_data_from_scans.py`.
3. Modéliser la progression réelle (objets clés → zones) pour pouvoir mélanger aussi les
   objets clés.
4. Confort, sur le modèle du projet RE4R (github.com/LiterallyMetaphorical/RE4R-AP-Wizard) :
   launcher avec installation automatique, suivi des sauvegardes pour les items reçus,
   marqueurs des checks proches, boutique du Duke.

## Points d'attention transverses (rappel du prompt de conception)

- Idempotence : déjà implémentée côté Lua (fichier d'état local) et côté bridge Python
  (fichier d'état local séparé) — voir le code, pas juste un TODO.
- Gestion hors-ligne : pas encore implémentée (si `ap_bridge.py` perd la connexion au
  serveur, les nouvelles lignes de `checks_to_send.jsonl` restent en attente dans le
  fichier mais ne sont renvoyées qu'au prochain redémarrage du bridge — pas de reconnexion
  automatique pour l'instant).
- Distinguer checks obligatoires vs optionnels : pas encore modélisé dans `locations.json`
  (tout est actuellement traité comme rempli par le pool normal).
- Conflit "achat chez le Duke" vs "item reçu" : le Duke restant accessible en permanence
  dans RE Village, l'option 1 du prompt de conception (déclencher le check à l'achetabilité,
  pas à la possession réelle) s'applique directement — à implémenter dans `HOOKS.install()`.
- **Mallette du château après la cuisine, nom d'origine sur la ligne (corrigé et validé en jeu 2026-09-29)** :
  check « Compensateur de recul (LEMI) (2) #001 [S02] » (3725070903), mais
  la mallette montre LEMI **(1)** (2255157331) : la ligne n'était rattachée à aucun check
  (journal « ligne d'objet 2255157331 sans check reconnu », check à 0,8 m) et restait
  « Compensateur de recul (LEMI) » au lieu de « [AP] Fluide chimique ». Ramassage et check
  étaient déjà bons. `shop_ui.world.same_variant` : les variantes « (1) » / « (2) » d'un même
  objet (items.json : chargeurs F2 et M1911, compensateur LEMI) comptent comme le même objet
  dans `entry_for_item`.
- **Échelle des vrais modèles dans la boutique (2026-09-29, validé en jeu)** : Ferraille,
  Plante… s'affichaient énormes (montrés à la place du Remède, à son échelle). Tailles mesurées
  dans Blender (Remède 12,6 cm ; Plante 47,9 ; Ferraille 62 ; Pièces détachées 52,5 ; Sac de Lei
  35,2 ; Poudre noire 21,2 ; Fluide chimique 12,8) -> `shop_ui.REAL_MODEL_SCALE` = 0,126 / taille,
  appliqué par `shop_ui.preview_scale`. Curseur « Echelle des vrais modeles (boutique) » dans les
  outils de dev (multiplicateur, valeur notée dans le journal) pour ajuster.
- **Pots cassés (2026-09-29, corrigé et validé en jeu)** : 2 pots en check testés, l'objet devant le
  joueur passait en « [AP] » au bout de 2 à 3 s. Le placement (`ItemSpawnInfo`) n'apparaît qu'à la
  casse, donc absent du relevé (toutes les 8 s) ; le relevé forcé par la ligne d'objet se faisait à
  l'image suivante et la ligne restait d'origine jusqu'au setItemID suivant. Désormais relevé +
  nouvel essai dans le même appel (`shop_ui.world.on_set_item`). Le modèle 3D, lui, peut encore
  attendre le relevé (8 s max) tant que le joueur ne vise pas l'objet.
- **`createItemCore` nil pour LEMI (2) (2026-09-29)** : erreur « attempt to index a nil value »
  dans `display_core` (ligne d'objet cassée). Porteur de la ligne à la place, journal
  « createItemCore impossible ». LEMI (2) sans maillage connu (« pièce d'arme 3725070903 :
  maillage nil ») : affiché en mallette à pièce d'arme, comme dans le jeu d'origine.
- **Rotation des vrais modèles dans la boutique (2026-09-29, réglée en jeu par le joueur : Ferraille -56 / 116 / 0, Poudre noire -6 / 34 / 32)** : Ferraille vue surtout
  de dos -> `shop_ui.REAL_MODEL_ROT` (degrés X, Y, Z ajoutés aux curseurs « Rotation X/Y/Z
  (boutique) »), Ferraille = 35° autour de Y (sens à confirmer en jeu).
- **LEMI (2) bloqué dans le colis (corrigé et validé en jeu 2026-09-29)** : l'ID 3725070903 n'est pas
  créable (`createAndAddItem` / `createItemCore` nil) ; le mod le prenait pour « mallette pleine »
  (colis), puis la boutique l'ignorait. Refusé à chaque réception depuis le 2026-09-27. Le vrai
  objet est LEMI (1), 2255157331 (contenu de la mallette du château). `item.give_id` (LEMI (2) ->
  2255157331) et `item.variant_ids` (variantes « (N) » essayées par `give_item(id, n, item)` si le
  jeu refuse l'ID ; utile aussi pour les chargeurs F2 / M1911 (1)/(2), non vérifiés). Utilisé
  pour le don, le colis, la boutique (colis) et la ligne d'objet.
  Suite (2026-09-29) : colis -> LEMI donné (validé, journal « colis : … donné »). Au sol (pot
  « Poudre noire #008 [S01] ») : modèle de pièce pris sur `give_id` (LEMI (1), qui a un maillage)
  au lieu de la mallette ; nom affiché sans « (1) » / « (2) » (`scouted_items[…].label`).
- **Placement des objets AP au sol par boîtes englobantes (2026-09-29, validé en jeu)** :
  modèles décalés sur le côté dans les mallettes (Fluide chimique, LEMI), Mine géante enfoncée
  dans le sol à la place d'une Bombe tuyau, munitions de lance-grenades à moitié dans un meuble.
  Cause : notre os `_00` posé sur celui de l'objet d'origine, à son échelle (origine des modèles
  différente : pied, centre, bord ; objets d'origine agrandis par le jeu). Désormais
  (`shop_ui.world.place_by_box`, `GROUND`) : objet non rattaché (pas d'échelle héritée), taille
  réelle x `GROUND.scale` (logo AP x `GROUND.ap_scale` = 2), rotation de l'os `_00` d'origine, et
  bas-centre de sa boîte (`get_WorldAABB`) recalé sur le bas-centre de la boîte de l'objet
  d'origine, relevée avant de le cacher (sinon objet d'origine laissé visible jusqu'à 1,5 s, puis
  centre sur l'os `_00`). Journal « recalé de … (taille …) ». Outils de dev : case « placement par
  boites » (ancienne méthode si décochée) et curseurs d'échelle.
  Suite (2026-09-29) : tas de Ferraille (84 cm à l'échelle 1) dans une table à la place d'une
  boîte de cartouches -> taille plafonnée à `GROUND.fit` (1,5) x la taille de l'objet d'origine
  (au moins 10 cm), journal « taille réelle …, objet d'origine … ». Mallette du château : boîte de
  l'objet d'origine invalide tant que le joueur est loin (abandon après 1,5 s -> centre sur l'os
  `_00`, pas au milieu) ; l'abandon ne compte plus qu'à moins de 3 m.
- **Diagnostic des objets AP au sol (2026-09-29)** : bouton « Diagnostic des objets AP proches
  (journal) » dans les outils de dev (`shop_ui.world.diagnose`) : pour chaque objet AP à moins de
  6 m, position, ancre (os `_00`), attente, échelle, recalage, boîtes (la nôtre et celles de
  l'objet d'origine), affichage. Ouvert pour : Vivianite jamais visible dans un tiroir (« Fluide
  chimique #027 [S01] ») et objet du labyrinthe à bille de la salle du Duc invisible (« Crâne
  cramoisi #002 »). Ferraille de la boutique : rotation portée à 70°.
  Diagnostic (2026-09-29) : labyrinthe à bille -> boîte d'origine de 1,36 m (Crâne cramoisi
  #002), bas sous le plateau, munitions placées dessous : boîte ignorée si > max(0,6 m, 4 x notre
  taille), centre sur l'os `_00`. Tiroir de la Vivianite : notre objet affiché, 8,7 cm, posé au
  fond de la boîte d'origine (flacon couché de 25 cm) -> cause pas encore trouvée.
  Vivianite du tiroir validée en jeu (visible avec le placement par boîtes) ; trop petite ->
  `GROUND.model_scale` (échelle par modèle au sol), Vivianite (sm92_047_Gem) = 1,55, valeur
  choisie par le joueur. Le reste de l'affichage au sol : validé par le joueur (2026-09-29).
  Vivianite de nouveau sous le tiroir (2026-09-29, objet remplacé tiroir fermé) : l'objet
  d'origine caché, le jeu ne met plus à jour son os `_00`, resté à la place du tiroir fermé.
  `shop_ui.world.anchor_of` : décalage de l'os `_00` par rapport à l'objet relevé une fois (objet
  encore à jour), puis appliqué à la pose de l'objet, qui suit le tiroir. À valider.
- **Message DeathLink « tué par … » : validé en jeu (2026-09-29)** : mort par la nuée d'insectes
  (`BugSlipAttacker`), Joueur2 a reçu « Ethan was killed by a swarm of insects in Resident Evil
  Village. »
- **Icône du Sac de Lei sur la ligne d'objet (2026-09-29, validé en jeu)** : un check donnant un Sac
  de Lei gardait l'icône de l'objet d'origine (Munitions pour pistolet #010 [S04]) : l'argent était
  exclu de l'objet d'affichage (`on_set_item`). Inclus désormais (affichage seulement).
- **Objet AP dans le pot d'une Plante (2026-09-29, à régler en jeu)** : la Plante est plantée dans
  un pot du décor (invisible pour le mod) ; bas de sa boîte au fond du pot. `GROUND.host_lift`
  (par maillage d'origine) : notre objet posé à une fraction de la hauteur de l'objet d'origine,
  Plante = 0,3 (validé en jeu 2026-09-29), curseur « hauteur sur une Plante » dans les outils de dev.
- **Cachots du château = endroit sans retour (2026-09-29, signalé par le joueur)** : sous-sol où
  Lady Dimitrescu coupe la main, seule zone du château où l'on ne revient jamais. Ajouté à
  `MISSABLE_SPOTS` (tools/build_data_from_scans.py) : Sac de Lei #004, Poudre noire #002, Fluide
  chimique #001 [S08] -> toujours EXCLUS (objets sans importance). Vaut pour les seeds générées
  ensuite. Validés aussi le 2026-09-29 : mort DeathLink reçue, objet du labyrinthe à bille.
- **Mode 100 % (à faire) : aussi les cachots du château** (2026-09-29, demande du joueur) : avec
  l'option « bloquer », empêcher de quitter les cachots tant que les 3 checks [S08] ne sont pas
  faits (mur invisible ou interaction de sortie bloquée). Point de sortie à relever en jeu. Même
  principe que les autres zones ratables (château, maison Beneviento) et endroits sans retour.
  Vivianite encore sous le tiroir (2026-09-29, 22h15) : le tiroir n'emporte pas l'objet, il anime
  son os `_00` ; un maillage caché par `set_DrawDefault(false)` n'a plus ses os mis à jour.
  Objet d'origine désormais caché par ses parties (`shop_ui.world.hide_host` / `show_host`,
  parties remises à la restauration), toujours « dessiné », os `_00` vivant utilisé comme ancre.
  Échelle par modèle : le modèle peut être une table `{ mesh, mdf }` (clé = `mesh`), d'où
  l'échelle 1,55 de la Vivianite jamais appliquée.
- **Objets AP recréés en boucle (2026-09-29, corrigé et validé en jeu)** : 586 retraits « objet AP retiré » au
  journal ; la Vivianite était recréée toutes les ~8 s devant le joueur (au rythme du relevé).
  Suspect : référence `ItemSpawnInfo` gardée devenue illisible (erreur dans le `pcall` = « plus
  utilisé »). `shop_ui.world.still_used` : raison notée (« retiré : … » / « gardé malgré … »),
  erreur de lecture = gardé (retiré seulement après 10 s d'erreur) ; référence rafraîchie à chaque
  passage (`done.si`, `kept.si`).
  Rotation cumulée à chaque retour sur la Ferraille / la Poudre (2026-09-29) : `preview_orig`
  gardé après la remise d'origine, rotation de départ relevée ensuite sur l'objet déjà tourné.
  `preview_orig` oublié à la remise d'origine ; rotation appliquée seulement à l'objet relevé.
  Suite (2026-09-29, 22h50) : relever la position de départ à chaque sélection tombait parfois
  pendant l'animation de la boutique (objet énorme, rotation au hasard). État au repos du
  présentoir relevé une seule fois (`shop_ui.preview_rest`, journal « présentoir au repos »),
  toujours réutilisé. Rotations Ferraille / Poudre remises à zéro (réglées sur une base faussée),
  à régler de nouveau.
  Suite (2026-09-29, 23h15) : rotation « au repos » du présentoir différente à chaque relevé
  (animation de la boutique). Rotation désormais ABSOLUE (degrés X, Y, Z tels quels) pour un
  modèle de `REAL_MODEL_ROT` ou quand les curseurs ne sont pas à zéro, sinon rotation du jeu
  intacte. Échelle reposée à chaque passage (présentoir recréé par la boutique, échelle x2,8 d'origine
  revenue). Curseurs = valeurs absolues à enregistrer.
- **Plantage du jeu en changeant d'article en rafale dans la boutique (2026-09-29, 23h13)** :
  plantage dans un fil du moteur (reframework_crash.dmp) juste après l'échelle reposée à chaque
  passage. La boutique détruit et recrée le présentoir ; une adresse réutilisée faisait écrire dans
  le Transform d'un objet détruit (`preview_orig.transform`). `update_preview` n'écrit plus que
  dans le Transform de l'objet actuel (`cur_tf`) ; Transform différent = nouvel objet. À revérifier
  en changeant d'article en rafale.

## Objets clés mélangés (2026-09-30, fait hors jeu, À TESTER EN JEU)

- **Options** (`Options.py`) : `randomize_key_items` (actif), `randomize_beneviento_puzzles`
  (actif), nouvelle `key_items_placement` : `dans_leur_zone` (défaut : dans sa propre partie,
  dans la zone où l'objet sert) ou `partout` (aussi chez les autres joueurs).
- **Données** (`tools/build_data_from_scans.py`) : 38 checks d'objets clés, 35 items (dont
  « Clé ailée (progressive) » ×4 : chaque exemplaire donne le niveau suivant, ailée → quatre
  ailes → fœtus quatre ailes → fœtus six ailes). Ajoutés APRÈS Victory : ID existants inchangés.
  Restent à leur place : NEVER_RANDOMIZE, cartes, photos de chasse, carte au trésor, objets clés
  du 1er passage au Village (Chapter2_1), placements jamais ramassés (contenu coupé possible).
- **Logique = ordre réel d'une partie** (`pickups_log_20260926.jsonl`) : champ `order` de chaque
  location = rang de ramassage ; une location demande les objets clés ramassés avant elle.
  Check absent du journal : rang = dernier ramassage de son chapitre. Aucun objet clé sur les
  locations Chapter2_1 (`no_key_items` : placements plus chargés au Village 2_6), la boutique, les
  plats. Avec `zone_exclue`, les checks d'objets clés du château ne sont jamais exclus.
- **`dans_leur_zone`** : placement fait par l'apworld (`pre_fill`), par échéance croissante, sur
  une location libre de la zone de rang ≤ celui de l'objet. Le remplissage d'Archipelago seul
  échouait ~1 fois sur 2 (château avec zone_exclue, maison Beneviento : très peu de places).
  Validé : 100 seeds (5 configurations, dont multiworld `partout` + ChecksFinder), 0 échec, 0
  objet clé placé après l'endroit où il sert (script de contrôle du spoiler).
- **Client** :
  - ramassage d'un objet clé = check seulement si la location existe dans la seed ; sinon
    ramassage normal. Hors connexion : objet gardé, check envoyé à la connexion
    (`shop_ui.key_offline`) ;
  - clé progressive : `row.level` = rang de l'exemplaire reçu (`process_network`), niveaux
    inférieurs manquants redonnés ; tous les niveaux suivis pour le retrait de l'objet d'origine ;
  - **bug corrigé** : le client demandait au serveur (scout) toutes les locations du paquet de
    données, même absentes de la seed (checks Beneviento désactivés, boutique désactivée) →
    KeyError côté serveur, connexion coupée en boucle. `net.lua` lit `missing_locations` +
    `checked_locations` à la connexion (`net.seed_locations`), `cache_location_ids` filtre.
  - Test hors jeu (`tools/test_client_offline.lua`, faux REFramework complété) : OK ; étape clé
    ailée à part (`lua543.exe ../tools/test_client_offline.lua cle`, serveur de test NEUF).
- **Seed de test** : `seeds/test_cles/AP_59251848248019336035.zip` (Ethan + Joueur2
  ChecksFinder, objets clés `dans_leur_zone`, énigmes Beneviento non mélangées, DeathLink).
  Nouvelle partie nécessaire.
- **À vérifier en jeu** : retrait de l'objet clé d'origine au ramassage (même liste
  `Inventory.items`, journal « retrait : avant=… delta=… ») ; objet clé reçu utilisable sur sa
  porte / son énigme ; objet clé reçu AVANT d'entrer dans sa zone (le jeu le garde-t-il ?) ; clé
  ailée : ramasser un emplacement de clé ailée (le jeu retire-t-il le niveau d'avant ?) et portes
  à ailes ouvertes avec les niveaux reçus ; modèle / nom « [AP] » des objets clés au sol.
- **Boutique** : rotations absolues réglées par le joueur (`REAL_MODEL_ROT`) : Ferraille
  { -27,3 ; -9,4 ; 0 }, Poudre noire { -38,3 ; -23,1 ; 0 } (curseurs à remettre à zéro). Plantage
  en changeant d'article en rafale : corrigé, confirmé par le joueur.
- **Noms d'ennemis encore à relever** (DeathLink, `death_link.KILLERS`) : maison Beneviento
  (poupées, phase finale, bébé de la poursuite), monstres dehors après la maison, formes
  modifiées des lycans. Sœurs : toutes vérifiées.
- **Suite du 2026-09-30 (retours du joueur en jeu)** :
  - objets clés tassés au début du château : la logique prenait le rang de RAMASSAGE de chaque
    clé comme échéance. Nouvelle table `KEY_USE` (build_data_from_scans.py) = rang où la clé SERT
    (château, d'après le joueur : œil de la bague 45 = porte vers la 1re sœur, vin 81, Clé de la
    cour 83, Clé de Dimitrescu 111 = porte de sa chambre puis sous-sol, Boule 125 = piano de
    l'opéra, Trophée 138 = vissé à la place du masque, 4 masques 171 = porte des masques). Sans
    entrée : rang de ramassage + 0,5. `pre_fill` tire vers les places tardives (racine carrée).
    Reste à faire : même table pour le Village, le réservoir et l'usine (Clé en fer forgé : usage
    inconnu, prudent).
  - nouvelle valeur par défaut `key_items_placement: zone_ou_autres_jeux` : chez soi dans la zone,
    ~1 objet clé sur 2 chez les autres en multiworld (énigmes Beneviento toujours chez soi).
  - sauvegarde d'avant la seed rechargée (emplacement inconnu) : rien n'était redonné (11 checks
    « perdus »). `state.tracks_saves` (seed dont toutes les sauvegardes sont suivies) : sauvegarde
    inconnue = d'avant la seed, tout est redonné. La vraie partie (38281) garde l'ancien comportement.
  - objets AP au sol trop petits (Madalina, pièce mécanique : 10 cm à la place d'un Fragment de
    cristal) : `GROUND.min_size` 0,10 -> 0,20 m + curseur « taille min ».
  - 2e seed de test : `seeds/test_cles2/AP_65670341623212675357.zip` (nouvelle logique).
  - Validé en jeu le 2026-09-30 : sauvegarde d'avant la seed -> objets redonnés (quitter /
    continuer) ; bouton « Redonner tous les objets reçus » (outils) en secours.
  - Double modèle après changement de seed sans relancer le jeu (Cartouches de fusil de l'ancienne
    seed + Compensateur) : `shop_ui.world.remove` ; l'objet posé retient `label` / `model_key`, et
    il est retiré si l'objet prévu change (aussi vers « modèle d'origine gardé »).
  - Vivianite (7 cm) introuvable à la place d'une boîte de munitions : `GROUND.min_visible` = 0,12 m,
    taille d'affichage minimale (curseur). VALIDÉ en jeu. `min_size` reste le plancher du plafond.
- **Drops de boss (2026-09-30, option `boss_drops_as_checks`, active par défaut)** : certains boss
  meurent dans une scène scriptée ; leur trésor lâché (drop d'ennemi) sert de check. `BOSS_DROPS`
  (build_data_from_scans.py) : Buste cristallisé x3 (les 3 sœurs), Grand marteau cristallisé, Bête
  ancienne cristallisée (Village), Cœur mécanique complexe (usine). Client : trésor ramassé = 1er
  check de ce trésor pas encore fait (`locations.boss_drops`). Jamais d'objet clé dessus. À
  compléter avec le joueur : Crâne cristallisé parfait (x3), Aile cristallisée (x2), Bête
  cristallisée (x2), Cœur mécanique parfait (x2), Collier d'Ingrid, Grande masse cristallisée (Chris).
- **Ramassage (2026-09-30)** : objet AP caché dès le ramassage (`picked_hidden`, plus ~2 s) ; objet
  clé à MOI au sol ramassé sous sa vraie forme (présentation + son du jeu, `shop_ui.world.own_key`),
  pas redonné par le serveur (`state.given_by_pickup`) sauf après rechargement (`row.regive`) ;
  sons : `shop_ui.sound` (app.WwiseManagerApp.trigger), numéros par type à relever en jeu avec
  « Relever les sons de ramassage » (journal « son : ») puis à noter dans `shop_ui.sound.BY_TYPE`.
- **Outil `tools/send_check.py`** : valide un check d'Ethan à la main sur un serveur de TEST (refuse
  38281). Cas du 2026-09-30 : save du château d'une autre partie, Ange en bois #004 [S11] (qui porte
  le Sanguis Virginis dans test_cles2) déjà ramassé -> vin introuvable, blocage.
- Compteur « Salle X : aucun check » dans la cave à vin : les checks du château n'ont pas de salle
  connue (seulement le secteur) tant qu'ils n'ont pas été ramassés une fois (room_cache). À améliorer.
- Suite du 2026-09-30 soir : `GROUND.fit_h` = 1,5 (hauteur au plus 1,5 x celle de l'objet d'origine,
  au moins `min_h` 0,08 m) : Valise de 25 cm cachée dans un tiroir (poudre de 7 cm) -> VALIDÉ en jeu.
  Objets « ArchipelagoModel » orphelins balayés au démarrage et toutes les 30 s (`sweep_orphans`).
  Présentation plein écran des objets clés : `GetMode` d'un vrai emplacement d'objet clé recopié sur
  l'emplacement qui donne un de mes objets clés (`learn_get_mode` / `apply_key_mode`), à valider.
  Vrai objet clé ramassé tel quel (Bague) : VALIDÉ (gardé, pas redonné par le serveur).
  Valise ramassée au sol : mallette agrandie, objets bien rangés (pas de superposition) : VALIDÉ en jeu le 2026-09-30.
- **Sons et présentation au ramassage (2026-09-30 / 10-01), EN COURS** :
  - relevé des sons par hooks Wwise (`shop_ui.sound.install_capture`) : les vrais ramassages ne
    passent pas par ces fonctions (rien capté) ; numéros captés = bruit de fond. Méthode abandonnée.
  - constat : un ramassage fait le bruit de l'objet d'ORIGINE s'il n'est pas remplacé (fragment de
    mur -> bruit de fragment) ; l'objet créé par createItemCore n'a pas de lecteur de sons
    (`ItemCore.wwiseContainer`) : muet. Recopier ce lecteur (`copy_sound`) : DÉSACTIVÉ après un
    plantage (lien vers l'objet d'origine qui peut disparaître).
  - présentation plein écran : liée à l'emplacement, pas à l'objet (Sac de Lei [AP] sur le Verre
    carmin #004 présenté). Écrire `GetMode` : DÉSACTIVÉ (mode « normal » appris sur un Fragment =
    mode des trésors, recopié sur des munitions : présentation vide puis plantage). Reste en test :
    réponse forcée à `InteractItemGet.IsGetItemDetailSearchAfter` (journal « présentation : »).
  - validé : drop de boss « Buste cristallisé (1re sœur) » reconnu en jeu (check envoyé).
  - Drops de boss rattachés par POSITION (2026-10-01) : `drop_position` (journal de référence) ; drop
    ramassé = boss dont la position est la plus proche (< 20 m), sinon 1er check non fait. Avant :
    1re sœur retuée après rechargement comptée « 2e sœur ». Les morts des sœurs ne passent pas par
    registerDeadEnemy (scriptées).
  - Présentation : objet clé à moi ramassé sous sa vraie forme mais objet créé (createItemCore) ->
    pas de présentation (Sanguis Virginis). Emplacement d'objet clé d'origine (Sanguis dans le bain
    de sang) : scène + présentation montrant l'objet AP (Ferraille), via la ligne d'objet. Piste :
    modifier l'ItemCore d'origine sur place (set_itemID / set_spec) au lieu d'en créer un.
- **Bugs ouverts (2026-10-01, 1h35, seed test_cles3)** :
  - Crochet #010 [S11] (porte le Sanguis Virginis, check déjà fait, ramassé de nouveau après
    rechargement) : présentation plein écran « buguée » (objet de ramassage créé = Fragment).
  - Mallette LEMI (Compensateur de recul (LEMI) (2) #001 [S02], objet AP : Poudre noire) : le jeu a
    posé LEMI (1) (2255157331) à l'ouverture, ramassé TEL QUEL (pas remplacé : pas de ligne « le jeu
    a posé l'objet »), placement non trouvé -> location nil, check NON envoyé, vrai LEMI gardé ;
    présentation buguée. Validé le 2026-09-29, régression à chercher (sync_pickup / instance_get).
  - Journal : deux instances du mod écrivaient en même temps (horloges 1041 s / 2959 s) après le
    plantage de 00h38 (ancien re8.exe resté en mémoire ?).
  - (1h40) Mallette LEMI : le joueur a revérifié, fonctionne (bug ci-dessus non reproduit, clos).
  - Case INPLACE (objet d'origine modifié sur place) : 22 emplacements OK, SON présent partout (son de
    l'objet d'origine, pas de l'objet AP). Présentation des objets clés : à vérifier avec cette méthode.
- **Plantage du 2026-10-01 (1h53)** : mallette du LEMI, présentation plein écran du vrai LEMI (posé par
  le jeu, nouveau), le mod l'a retiré de la mallette PENDANT la présentation (+ remplacement du texte
  de description) -> plantage. Correctifs : pas « en jeu » tant que
  `GUIManager.get_isEnableDetailSearchFlow` est vrai (rien retiré ni donné pendant une présentation) ;
  remplacement du texte (`shop_ui.detail`, texte créé non protégé) et réponse forcée à
  `IsGetItemDetailSearchAfter` (jamais appelée par le jeu) DÉSACTIVÉS.
  Filet de sécurité validé : objet de mallette ramassé tel quel reconnu par l'objet / variante à
  moins de 3 m (« reconnu par l'objet ») -> check envoyé, vrai LEMI retiré.
  RESTE : empêcher la présentation plein écran d'un objet AP non-clé (vrai LEMI nouveau dans la
  mallette) ; nom affiché pendant une présentation = objet d'origine (piste : set_nameText, avec un
  texte protégé par add_ref).

### Plan fixé par le joueur pour la suite (2026-10-01, ~2h10), dans l'ordre

1. **Présentation plein écran (priorité)** : seulement pour les objets clés, à leur emplacement
   d'origine ET à un emplacement AP qui donne un de mes objets clés ; jamais pour un objet AP
   non-clé (mallette du LEMI = bug à finir). **Trouvé hors jeu le 2026-10-01** (voir plus bas).
2. **Sons personnalisés** : son de l'objet RAMASSÉ (pas de l'objet d'origine), et un son à part
   pour les objets AP (de préférence le son joué à l'ouverture de la présentation plein écran).
3. **Checks de chasse.**
4. **Mode 100 %** : le joueur doit l'expliquer. Ce n'est PAS un objectif (goal) : ça concerne le
   choix des checks des zones ratables (option `missable_checks`).
5. **Options yaml** : le joueur les lit dans le launcher Archipelago ; textes à retraduire /
   reformuler selon ses indications.
6. **Launcher, puis V1.**

### Présentation plein écran : modes de ramassage (2026-10-01, hors jeu)

`InteractItemGet.GetMode` = hash de `app.InteractItenGetModeNames` (il2cpp_dump), comparé aux
~450 lignes « GetMode= » du debug_log :

| hash | nom | emplacements |
|---|---|---|
| 2544608857 | FixDisplayCenter | objets clés (119/119) : toujours présenté |
| 2506306378 | FixDisplayCenterAnotherSE | trésors (Verre carmin, Crâne cramoisi) : présenté, autre son |
| 3660107107 | FixDisplayCenterOnce | munitions / ressources : présenté seulement si l'objet est nouveau |
| 1948795948 | Normal | Sac de Lei, mallette LEMI : jamais présenté |
| 1829006500 | DetailSearchAfter | (non vu) |
| 930583307 | FixDisplayCenterAfterDetailSearch | (non vu) |

Les anciennes étiquettes (« ordinaire », « normal » appris) étaient fausses : le plantage venait
d'un mode Once/AnotherSE recopié comme « normal ». Désormais `shop_ui.world.GET_MODE` (constantes)
et `WRITE_GET_MODE = true` : emplacement de la seed -> Normal, sauf un de MES objets clés pas encore
pris avec INPLACE -> FixDisplayCenter ; remis d'origine avec le modèle. Journal « présentation : X :
GetMode a -> b ». À VALIDER en jeu (test_cles3, 38282) : munitions/Fragment AP sans présentation,
Crochet #010 [S11] déjà fait sans présentation buguée, objet clé AP présenté. Mallette LEMI : son
emplacement est déjà Normal, la présentation venait de l'ouverture de la mallette (autre mécanisme).


### Mallette du LEMI : présentation (2026-10-03, test_cles3)

- La pièce posée par le jeu à l'ouverture de la mallette a son PROPRE `GetMode` : 2506306378
  (FixDisplayCenterAnotherSE), indépendant de celui de l'emplacement au sol (déjà Normal).
- Essai : l'écrire à Normal dans `case_watch` -> **jeu bloqué au ramassage** (`en jeu=false` sans
  fin, la mallette attend une présentation).
- Essai suivant : Once (3660107107), objet de ramassage déjà possédé (`WRITE_CASE_GET_MODE = true`,
  jamais pour un de mes objets clés). À valider en jeu (sauvegarder avant).
- Pistes : essayer FixDisplayCenterOnce (3660107107, Poudre noire déjà possédée -> pas présentée ?),
  ou garder la présentation mais afficher le bon objet / nom.
- **Crochet #010 [S11] (2026-10-03)** : emplacement passé à 1948795948 -> présentation vide (ni objet
  ni nom) puis jeu bloqué, comme la mallette. 1948795948 n'est pas « jamais présenté » : mode natif
  des objets qu'on ouvre (mallette LEMI, sac de Lei). `apply_key_mode` écrit désormais Once
  (3660107107) pour tout emplacement AP non-clé. VALIDÉ en jeu (Crochet #010 : rien affiché, pas de
  blocage ; mallette LEMI idem).
- **Présentation de MON objet clé sur un emplacement AP (2026-10-03)** : vin (Crochet #010) bien reçu,
  mais présenté sous le nom « Crochet » et sans modèle (la présentation montre l'objet d'origine,
  caché par le mod). Correctifs, À VALIDER en jeu : pour mon objet clé avec INPLACE, modèle posé sur
  l'objet d'origine lui-même (méthode 1, pas d'objet à part) ; nom remplacé par
  `GUIDetailSearch.set_nameText` près de l'emplacement (`shop_ui.detail.KEY_NAME`, texte add_ref,
  nom seulement). Seed test_cles3 remise à zéro (ancienne progression : `seeds/test_cles3/backup_20261003_1737`).
- **Seed test_chateau (2026-10-03, 18h31)** : crash du jeu (c0000005 dans re8.exe, aucune erreur Lua)
  ~13 s après l'entrée dans la Cave à vin, après avoir vu la Bague (mon objet clé, sur Fluide
  chimique #013 [S01], méthode 1 + GetMode clé) sans pouvoir la ramasser. Journal : ni ramassage ni
  présentation. Cause non trouvée (piste : maillage remplacé sur l'objet d'origine, méthode 1).
- **Nom d'origine sur les objets clés** (signalé par le joueur, deux cas : objet AP sur un emplacement
  d'objet clé, et mon objet clé posé ailleurs). Toutes les lignes d'objet sont pourtant reconnues.
  Ajouté, À VÉRIFIER : nom de la ligne vérifié avant chaque rendu pendant 4 s et remis s'il est
  réécrit (`shop_ui.world.keep_line_label`, journal « réécrite par le jeu ») ; journal « ligne
  d'objet (visé/obtenu) pour ... » pour les emplacements d'objets clés. Vérifié 18h45 : la ligne de
  la Bague affiche bien « [AP] Bague avec un œil écarlate », pas de réécriture.
- **2e crash (18h47:17)**, encore ~10 s après l'entrée dans la Cave à vin, où est la Bague (Fluide
  chimique #013 [S01], -40,2 -2,6 -31,5). Le Sanguis Virginis (mon objet clé sur Sac de Lei #030,
  même méthode) s'est ramassé normalement juste avant. Mallette pleine (Fusil F2 au colis).
  Traces ajoutées (`shop_ui.world.install_pickup_trace`, journal « ramassage (diag) ») sur les
  étapes d'app.InteractItemGet (startDetailSearch, AddInventory, InsertInventory…, aperçu
  mallette pleine IsItemGetInventoryPreviewCheck), actives près d'un de mes objets clés.
  -> le jeu PLANTAIT AU LANCEMENT avec ces hooks (sans erreur notée) : désactivés. Remplacés par une
  relecture des champs d'InteractItemGet toutes les 0,1 s (`poll_key_pickups`, sans hook).
  Mallette avec de la place : Bague toujours impossible à ramasser (pas la cause).
- **Bague : présentation ouverte puis interrompue (18h56)** : « nom remplacé -> Bague » à chaque appui,
  objet jamais reçu. Hypothèse : prefab de présentation de l'objet (`ItemSpecification.findPrefab`)
  non chargé dans cette zone (le Sanguis Virginis, prévu dans la cave, est présenté et reçu).
  Hypothèse FAUSSE (journal 18h57 : prefab de la Bague chargé), correctif retiré.
- **Bouton « Prendre » barré (logo interdit)** devant la Bague (dit par le joueur) : le jeu refuse
  d'avance. Cause probable : Bague DÉJÀ possédée (ramassée dans test_cles3 sur Poudre noire #003,
  même sauvegarde du jeu réutilisée pour test_chateau) ; objet clé unique. À vérifier (onglet
  objets clés). Limite : changer de seed sur la même sauvegarde du jeu.
  CONFIRMÉ par le joueur : Bague combinée déjà possédée ; séparée -> bouton plus barré.
- **Crashs dans la Cave à vin (test_chateau)** : 18h31:27, 18h47:17, 19h01:01, toujours dans la cave
  (10 à 45 s après l'entrée), même fonction NATIVE du moteur (re8.exe+0x41519c6 / +0x4151c06, au-delà
  de toutes les méthodes du dump il2cpp, max 0x4145b60). Suspect : la Bague posée par la méthode 1
  (maillage Jewelry posé sur l'objet Fluide chimique ri4003 lui-même), seule différence avec la
  visite sans crash de 18h13 (test_cles3). Test : ramasser la Bague puis rester dans la cave.
  **2026-10-04 00h50** : crash 1 s après la ligne d'objet de la Bague (approche), autre adresse
  (+0x44f2025). Méthode 1 pour mes objets clés COUPÉE (`shop_ui.world.KEY_MESH_INPLACE = false`) :
  objet à part comme les autres checks. Conséquence connue : présentation sans le bon modèle
  (l'objet d'origine, caché, est montré). À VÉRIFIER : plus de crash dans la cave.
  **00h54** : crash quand même (+0x4151c06, comme 18h47 / 19h01) -> pas la Bague. Constat : dans la
  cave, le Masque du chagrin est retiré (« objet plus posé ») puis reposé toutes les 1 à 2 s, avant
  chaque crash. À chaque retrait, le mod réécrivait dans les composants de l'objet du jeu (parties
  du maillage, DrawDefault, GetMode, ItemCore), peut-être déjà détruits (pcall ne rattrape pas une
  violation d'accès native), et lisait sa pose à chaque image jusqu'au nettoyage (0,5 s).
  Correctif À VÉRIFIER : objet du jeu disparu (`shop_ui.world.GONE`) -> seul NOTRE objet est
  détruit (`remove(key, rec, gone)`) ; pose image par image coupée dès que `get_spawnInstance`
  change (`rec.gone`, `update_prompt`). Méthode 1 des objets clés laissée coupée.
  **VALIDÉ en jeu** (confirmé par le joueur le 2026-10-06) : plus de crash dans la Cave à vin.
- **Vin (Sanguis Virginis) dans un pot (Sac de Lei #030)** : reçu mais SANS présentation plein écran
  (dit par le joueur). Objet apparu à la casse du pot (18h46:57), GetMode 1948795948 (mode des
  objets qu'on ouvre) passé à « clé », ramassé 3 s après. À creuser.
  Test proposé : Clé de Dimitrescu sur Sac de Lei #007 [S04] (sac au sol ou dans un pot ?).
- **Objet au sol invisible (2026-10-04)** : Hræsvelg d'acier sur Poudre noire #008 [S01] (modèle
  sm92_068_TreasureP), aussi Masque du plaisir #007 (sm92_047_Gem). DIAG : `get_MaterialNum=0`,
  0 texture. Matériau (create_resource) posé avant la fin de son chargement, jamais réappliqué.
  Correctif À VÉRIFIER : `shop_ui.world.retry_material` (4 fois / s, 30 s max ; journal « matériau
  chargé après N essai(s) » ou « JAMAIS chargé »).
  Résultat 01h53 : TreasureD et TreasureN JAMAIS chargés malgré 30 s d'essais (fichiers présents
  dans le pak) : cause inconnue. Repli : après 5 s, logo Archipelago à la place (taille remesurée).
  **2026-10-06, VALIDÉ en jeu** : le Hræsvelg d'acier (Poudre noire #008 [S01]) s'affiche avec son
  VRAI modèle (dit par le joueur). Journal : repli logo à 5 s, puis l'objet est recréé ~1 s après
  (« le jeu a remis ...ArchipelagoLogo..., nouveau remplacement ») avec le modèle TreasureP, cette
  fois chargé (2e création = ressource déjà en mémoire). Même schéma vu sur Trophée de chasse #010,
  Fragment de cristal #015, Poudre noire #019. Le logo peut donc apparaître ~1 s avant le vrai modèle.
- **Nom faux dans la présentation de mes objets clés (Boule (fleur et épées), 01h53)** : BUG du mod.
  `GUIDetailSearch.set_nameText` est le setter du composant via.gui.Text, pas du nom ; le hook y
  mettait une chaîne à la place du composant (texte faux, mémoire peut-être abîmée : piste pour
  les crashs près de mes objets clés). Corrigé : le hook retient l'écran, le nom est écrit par
  `get_nameText():set_Message` avant chaque rendu (`shop_ui.detail.keep_key_name`). À VÉRIFIER.
  Le modèle de la présentation reste celui de l'objet d'origine (méthode 1 coupée).
  2e essai (02h17) : aucun remplacement, set_nameText n'est appelé qu'à l'initialisation de
  l'interface. Désormais l'écran (app.GUIDetailSearch) est cherché dans la scène (1 fois / s)
  pendant une présentation près d'un de mes objets clés, nom écrit par set_Message. À VÉRIFIER.
  Méthode 1 (modèle sur l'objet d'origine) RÉACTIVÉE pour mes objets clés
  (`KEY_MESH_INPLACE = true`) : crash de 00h54 sans elle, causes probables corrigées. À VÉRIFIER
  (modèle dans la présentation, pas de crash).
  Résultat 02h22 (Boule) : MODÈLE OK dans la présentation ; écran trouvé, mais nom lu vide (« nom ""
  remplacé ») et nom d'origine toujours affiché : le nom vient du MessageId (via.gui.Text), prioritaire.
  3e essai À VÉRIFIER : MessageId remis à zéro (System.Guid vide) puis set_Message, à chaque image.
  Résultat 2026-10-06 (Bague, Fluide chimique #013 [S01], seed remise à zéro) : présentation OK
  (modèle), nom d'origine toujours affiché ; journal « nom "" (MessageId nil) » -> nameText n'est
  pas le texte affiché. 3e essai coupé (`shop_ui.detail.KEEP_NAME_TEXT = false`).
  4e essai À VÉRIFIER : le contenu vient de `app.GUIDetailSearchOrder.setMode(mode, InstanceWork)`
  (nom tiré de work.ItemID) ou `setMode(mode, System.Guid messageID)`. Hook sur les deux
  (`shop_ui.detail.install_order_hook`, `ORDER_HOOK`) : près d'un de mes objets clés, work avec un
  autre ItemID -> remplacé par une COPIE (copyFrom + set_itemID). Journal « présentation : setMode
  ... » (copie / déjà bon / messageID). Si plantage : `ORDER_HOOK = false`.
  Résultat (Boule, Munitions pour pistolet #005 [S02]) : nom faux ; un seul appel, la version
  messageID, 3 s après le ramassage (fin de présentation ?). Les appelants passent par
  `app.GUIOrderExtension.setDetailSearch`, qui contourne GUIDetailSearchOrder.
  5e essai À VÉRIFIER : hook sur le receveur `app.GUIDetailSearch.setMode(GUIRequest.Parameter)`
  (GUIRequestSetDetailSearchParameter : mode, messageID, work). Près de mon objet clé : work d'un
  autre ID -> `set_work(copie)` ; messageID non vide -> NameMessageID de mon objet clé
  (`findItemSpec(id).Basic`). Journal : toutes les lignes « présentation : setMode mode=... »
  près d'un emplacement AP, même sans objet clé.
  Résultat (Clé de la cour sur Ferraille #023 [S02]) : un appel, work=nil, messageID illisible
  (ToString sur le Guid échoue), donc rien remplacé.
  **Trouvé hors jeu (2026-10-06, désassemblage de re8.exe avec capstone, adresses du dump)** :
  `app.InteractManager.StartDetailSearch` crée l'écran puis appelle (setDetailSearch inliné)
  `setMode(mode, findItemSpec(id).Basic.NameMessageID)` : le nom passe TOUJOURS par messageID,
  pas par le work. 6e essai À VÉRIFIER : près de mon objet clé, si work est nil -> messageID
  remplacé par le NameMessageID de mon objet clé ; journal `nom="..."` (texte lu par
  via.gui.message.get). **VALIDÉ en jeu le 2026-10-06** (Boule (fleur et épées) sur Munitions pour
  pistolet #029 [S01] : bon nom affiché ; journal nom="Munitions pour pistolet" -> remplacé). Outils : scratchpad `redis.py` (désassemble une méthode du dump),
  `callers.py` (appels directs vers une méthode).
- **Objet clé sur un emplacement Sac de Lei : jamais de présentation (2026-10-06)** : PAS lié aux
  pots. Vin (Sac de Lei #030) et Bague (Sac de Lei #011, sac posé sur une caisse) : objet reçu,
  aucune présentation, alors que GetMode vaut bien FixDisplayCenter au ramassage. Désassemblage :
  `InteractItemGet.IsFixDisplayCenter` ne teste que GetMode (+0x88 : 2544608857, 930583307,
  3660107107, 2506306378) et n'est appelé que par `InteractManager.doLateUpdate`. Hypothèse : le
  sac de Lei n'a pas de composant de présentation (DetailSearch). Diagnostic ajouté sur la ligne
  « GetMode=... » (DetailSearch / DetailSearchRoot / DetailSearchObject / Interact : oui/nil).
  Résultat : hypothèse FAUSSE (Sac de Lei #011 a les mêmes composants que les autres objets ;
  seule différence, son GetMode d'origine 1948795948). **Choix du joueur : aucun de mes objets clés
  sur un emplacement Sac de Lei** (`_no_key_items` dans l'apworld, 23 emplacements sur 500 ;
  vérifié sur 5 seeds). Seed de test : `seeds/test_lei/AP_70877802567450825039.zip` sur 38282.
  **VALIDÉ en jeu le 2026-10-06** (seed test_lei : présentations « [AP] nom » des objets clés OK, « fonctionne nickel »).
- **Sons (2026-10-07, étape suivante du plan)** : sons système trouvés par désassemblage (appels à
  `app.WwiseManagerApp.trigger(UInt32)` avec un ID fixe). `InteractItemGet.startDetailSearch` joue
  2961364839 (objet clé, FixDisplayCenter) ou 3769661010 (trésor / Once ; aussi plat cuisiné, pièce
  d'arme posée) ; 4272878916 / 2582191558 = ouverture / fermeture des menus (états de mixage
  probables, à ne pas jouer seuls). `shop_ui.sound.GAME` + 2 boutons « Écouter » dans les outils de
  dev. À choisir par le joueur : son des objets AP des autres jeux (`BY_TYPE.archipelago`).
  Choix du joueur : objet d'un AUTRE jeu ramassé -> son trésor, ou son objet clé si c'est un objet
  de progression (flag 1 du LocationScouts, gardé dans `scouted_items[..].flags`). À VÉRIFIER en jeu.
  Le son de l'objet d'origine joue aussi (INPLACE). Reste : son de MES objets (pas l'objet d'origine).
- **Voix des personnages pour les pièges (2026-10-07, idée du joueur)** : ramasser un piège pour un
  autre joueur -> réplique type « bonne chance » ; RECEVOIR un piège -> rire de Dimitrescu / d'une
  sœur. Outil `shop_ui.voice` (outils de dev) : relevé 20 s des trigger* de via.wwise.WwiseContainer
  (journal « voix : ID objet=... xN »), puis relecture d'un ID de 3 façons (son système, sur Ethan,
  sur l'objet du personnage). Limite attendue : banque de voix chargée seulement dans la zone du
  personnage ; plan B = fichier audio joué hors du jeu. À TESTER.
  Relevé du 2026-10-07 (cinématique de Daniela, em1261) : seuls les rappels
  `WwiseContainerApp.triggered` donnent des ID valables (lus dans RequestInfo.TriggerId) ; les
  trigger* natifs donnent des valeurs fausses (décalage d'arguments). Candidats em1261 :
  1240965744, 2926056533, 2490342862, 4131117619, 3043407969, 3677412716 (à écouter).
  Résultat : **2490342862 = phrase + rire de Daniela** (« ça fait longtemps que je n'ai pas disséqué
  un homme »), choisie pour « piège ramassé pour un autre joueur ». « son système » et « sur Ethan »
  muets (le conteneur doit connaître le son), « sur le personnage » audible mais lointain. Essai :
  conteneur d'em1261 positionné sur Ethan (`trigger(UInt32, GameObject)`). Limite : seulement quand
  em1261 est dans la scène.
  VALIDÉ (audible de près). Branché : objet d'un autre jeu avec le flag 4 (piège) ramassé ->
  `shop_ui.voice.TRAP_FOR_OTHER` (Daniela) si em1261 est dans la scène, sinon son trésor. Bouton
  « TEST : piège ramassé pour un autre joueur ». À VÉRIFIER : repli hors du château.
  Plan B (son partout) : fichier .wav lu par Windows (lecteur PowerShell caché). Test d'abord :
  2 boutons « TEST fichier audio » (tada.wav ; os.execute + start /b, ou io.popen qui BLOQUE le
  jeu pendant la lecture) : fenêtre / sortie du plein écran ? Si OK : extraire la phrase de
  Daniela des archives du jeu (bnk/wem -> vgmstream -> wav).
  Résultat : os.execute / io.popen ABSENTS dans REFramework (sandbox) -> lecteur externe impossible.
  Option retenue par le joueur : son DANS le jeu via les banques Wwise, sans remplacer un son utilisé.
  Fait (2026-10-07) : phrase extraite. Chaîne : trigger 2490342862 -> `snd_eventlist_em1261_v_dialogue.wel`
  (entrées de 62 octets à 0x204, nombre à 0x200 : trigger, event Wwise, ...) -> event 1480136888 ->
  action Play -> Sound 353558410 -> source 1052782769 (Vorbis, streamé) dans
  `natives/stm/streaming/sound/wwise/em1261_v_dialogue.pck.3.x64.fr` (AKPK). Fichiers :
  `Assets/sons/daniela_2490342862.wem` / `.wav` (3,6 s, 48 kHz mono). Banques v135 (Wwise 2019.2).
  Placeholder : `system.wel` (37 triggers, joués par WwiseManagerApp) = surtout états / RTPC ;
  seuls 2 triggers jouent un son simple (2961364839, 3769661010 : jingles utilisés) ; un son
  « Silence » (339003922) existe mais aucun trigger n'y mène. AUCUN emplacement libre prouvé.
  Proposition : AJOUTER un son à nous dans system.bnk (Sound + Action Play + Event copiés d'un
  jingle, WEM de Daniela embarqué dans DIDX/DATA) + un trigger neuf dans system.wel, via pak patch.
  Scripts : scratchpad `wel.py`, `bnk.py` ; vgmstream-cli (scratchpad/vgmstream).
  FAIT (choix du joueur) : `tools/re_engine/make_ap_sound.py` ajoute à system.bnk un Event +
  Action Play + Sound (copies du jingle trésor, nouveaux ID FNV-1, Sound ajouté aux enfants de
  l'actor-mixer 356891578, WEM embarqué en DIDX/DATA, BKHD complété pour aligner DATA sur 16) et une
  entrée triée dans system.wel. Son `ap_trap_for_other` = trigger **586762491** (event 612372498).
  Sortie dans client/natives/... (pak de patch via install.py, JEU FERMÉ). Client :
  `shop_ui.sound.AP.TRAP_FOR_OTHER`, joué partout ; bouton « Écouter : son AP piège ». À VÉRIFIER
  en jeu (si les sons de menu disparaissent : banque refusée, retirer les 2 fichiers et réinstaller).
  Attention : system.bnk vient du patch_006 du jeu ; une mise à jour du jeu qui le change
  demanderait de relancer make_ap_sound.py.
  Résultat 1er essai (2026-10-07) : son AP MUET. Le conteneur système (`WwiseManagerApp.SystemContainer`,
  objet snd_system, 14 ressources) lit bien system.wel (+ system_id_*.wel, bgm…). 2e essai : objets
  insérés dans l'ordre de Wwise (Sound juste après le son modèle, avant l'actor-mixer ; Action après
  l'action modèle ; Event à la fin), un son PAR LANGUE (9, remarque du joueur : jeu anglais -> voix
  anglaise ; `shop_ui.sound.voice_id` via `via.wwise.WwiseDriver.get_Language`), et trigger de test
  `ap_test_treasure` (1788264539) -> event EXISTANT du jingle trésor : s'il joue, le .wel est bon et
  le souci est dans la banque. À TESTER (jeu fermé pour installer).
  **VALIDÉ en jeu le 2026-10-07** : trigger de test -> jingle OK ; phrase de Daniela jouée partout
  (village), en français ET en anglais. Par WwiseManagerApp.trigger, le jingle trésor s'entendait en
  plus (cause non trouvée) ; par le conteneur système directement (`shop_ui.sound.play_ap`) : phrase
  seule. Les sons ajoutés passent donc par play_ap. Branché : piège pour un autre joueur ramassé.
- **Bruit de ramassage de MES objets (2026-10-07)** : relevé : chaque objet riXXXX joue lui-même le
  trigger commun 1738562264 (« ramassage », sa liste snd_eventlist_riXXXX.wel -> sa banque
  riXXXX.bnk). make_ap_sound.py ajoute à system.bnk le bruit de 136 objets (Sound simple ou 1re
  variante d'un conteneur aléatoire ; 1,2 Mo), table ri -> trigger dans
  `client/reframework/data/re_village_ap_client/ap_sounds.json`. Client : MES objets (clés comprises)
  -> `shop_ui.sound.pickup_trigger(gid)` (ri via ItemSpecification.findPrefab) joué par play_ap ; le
  bruit de l'objet d'origine d'un emplacement AP est COUPÉ (`shop_ui.sound.mute_hook` : hooks sur
  les trigger* natifs de WwiseContainer, objet en args[1], ID en args[pos+1] ; SKIP si trigger
  1738562264 joué par un objet d'emplacement AP non ramassé, `shop_ui.sound.ap_inst` refait toutes
  les 0,5 s), posé une fois en jeu ; `MUTE_ORIGINAL = false` pour couper. Sans bruit connu (ri5101,
  ri3044…) : rien de joué en plus. L'outil ignore notre patch_014 (repart des fichiers d'origine).
  **VALIDÉ en jeu le 2026-10-07**, sauf les armes (Sniper, M1911 : pas de bruit simple) -> pour mes
  objets sans bruit connu, jingle trésor (choix du joueur).
  Sac de Lei : ramassage par un autre trigger (ri5101 -> 1399615424, relevé en jeu) :
  `PICKUP_TRIGGER_BY_RI` dans l'outil, `shop_ui.sound.MUTED_TRIGGERS` côté client (137 objets).
- **Drops de boss affichés en objet AP (2026-10-07)** : le Buste cristallisé de Bela restait affiché
  tel quel (check reconnu au ramassage depuis le 2026-09-30, mais jamais habillé : objet lâché,
  sans placement connu). `shop_ui.world.update` : un ItemSpawnInfo hors locations dont l'objet a
  l'ItemID d'un drop de boss -> check pas encore fait le plus proche de sa `drop_position` (< 20 m)
  -> entrée habillée comme un check (`boss_drop = true`), et son InteractItemGet noté dans
  `case_gets` (ramassage retrouvé même si l'objet est modifié sur place). À VÉRIFIER en jeu.
  1er essai raté (Buste de Bela, 04:03) : ligne d'objet vue (« 2078728602 sans check reconnu ») mais
  drop jamais repéré : les objets lâchés ne sont pas dans findComponents. Ajout des
  ItemSpawnInfo de `ItemSpawnInfoHolder.ItemSpawnInfoEnemyDropUseList` au relevé. À VÉRIFIER
  (journal « drop de boss au sol : … »).
  2e essai raté : rien non plus. Cause : les drops d'ennemis sont des
  `app.Spawn.ItemSpawnInfoEnemyDrop` (type frère d'ItemSpawnInfo, champ DropItemID, sans
  SpawnedInteractItemGetCache ni get_spawnItemId). 3e essai À VÉRIFIER : ces composants sont
  relevés à part (position de leur spawnInstance), journal « drop de boss au sol (EnemyDrop) ».
  Diagnostic (05:02) : 0 ItemSpawnInfoEnemyDrop ; le Buste EST dans ItemSpawnInfoEnemyDropUseList
  (9 ItemSpawnInfo) mais son ItemID n'était pas lu par l'objet (ItemCore sans GameObject).
  4e essai À VÉRIFIER : ItemID de secours = `get_spawnItemId` de l'emplacement, position du
  spawnInstance. VALIDÉS au passage : mallette LEMI réapparue (échange bloqué, « évité » x31) et
  Sanguis Virginis présenté « [AP] Grenades explosives » (emplacement retenu 6 s).
  **VALIDÉ en jeu (05:07)** : Buste de Bela habillé, rattaché à « Buste cristallisé (1re sœur) » à
  1,0 m. Le Buste de la 3e sœur tombe à 11,9 m de celui de Bela : le relevé prend désormais le
  check le plus proche TOUT COURT (déjà fait -> pas habillé), au lieu du plus proche pas fait (Bela
  retuée après son check aurait été prise pour la 3e sœur).
- **Présentation sur un emplacement d'objet clé d'origine (2026-10-07)** : Sanguis Virginis #001
  (bain de sang, présentation scénarisée) donnant [AP] Grenades explosives : présentation sans
  modèle AP et sous le nom d'origine. Correctifs À VÉRIFIER : méthode 1 (modèle posé sur l'objet
  d'origine) aussi pour tout emplacement `key_item_location` ; nom de la présentation pour tout
  emplacement AP proche (`shop_ui.world.near_ap_loc`, < 2,5 m, check pas fait) : mes objets ->
  NameMessageID + « [AP] nom », objets d'autres jeux -> titre « [AP] objet (joueur) » seulement.
  Résultat : modèle AP OK dans la présentation, nom toujours d'origine : aucun appel journalisé,
  la caméra de la présentation est loin (near_ap faux). Correctif À VÉRIFIER : l'emplacement AP
  retenu 6 s (`near_ap_loc_until`) suffit pour remplacer le nom.
- Mallette LEMI disparue (2026-10-07, test_lei remise à zéro) : PAS un bug du mod. Le jeu pose un
  Sac de Lei (spawnItemId 3196868754) à la place de la mallette déjà ouverte dans la sauvegarde du
  jeu (LEMI pris avant la remise à zéro de la seed). Limite connue : remettre une seed à zéro ne
  remet pas la sauvegarde du jeu.
  CORRIGÉ : vraie cause = échange arme / pièce d'arme -> Lei quand le joueur possède déjà l'objet
  (LEMI reçu du multiworld lors de tests ; table singletonuserdatas/itemspawnexchangedata.user,
  unités HasItemList -> ItemID). Choix du joueur : bloquer l'échange sur les emplacements AP :
  hook `app.Spawn.ItemSpawnInfo.ExchangeWeaponAndPartsCheck` sauté si l'ItemSpawnInfo est un
  emplacement de la seed (`shop_ui.world_exchange`, journal « échange … évité »). À VÉRIFIER (la
  mallette doit réapparaître au rechargement de la zone).
- Pots / caisses (2026-10-07) : signalés « sans objet AP » ; journal : bien habillés (ex. Munitions
  pour pistolet #012 [S02] -> [AP] Fragment de cristal). C'étaient MES objets (seed test : seul
  Joueur2 ChecksFinder, peu d'objets) affichés sous leur vrai modèle, comme prévu.
- **Double modèle (vrai + logo) sur l'Animal en bois (corps), Ferraille #016 [S02] (2026-10-07)** :
  matériau « pas chargé » après 5 s -> logo de secours, puis le jeu remettait le vrai modèle
  (« nouveau remplacement ») SANS détruire l'objet logo, resté jusqu'au balayage. Correctifs :
  l'ancien objet est détruit au remplacement (`shop_ui.world.remove`) ; 1er échec de
  matériau -> objet RECRÉÉ avec le vrai modèle (`shop_ui.world.mat_fail`), logo seulement au 2e.
  **Considéré VALIDÉ (2026-10-07, choix du joueur)** : cas difficile à reproduire, pas testé en
  jeu ; on se fiera aux retours des joueurs.
- **Faux check par objet recyclé (2026-10-07)** : un sac de Lei de caisse (pas un check) a envoyé
  « Sac de Lei #011 [S01] » (autre salle) : le jeu réutilise ses InteractItemGet, la comparaison
  par adresse (match_distance 0) trouvait l'ancien emplacement. Correctif : adresse acceptée
  seulement si l'emplacement est à moins de 3 m de l'objet ramassé ; `case_gets` (mallettes, drops
  de boss) seulement pour un check pas encore fait ; reconnaissance par POSITION
  (find_spawn_info_for, même numéro d'objet) : check pas encore fait et à 3 m au plus, sinon ignoré
  (journal « ignoré (reconnu par position…) ») ; « reconnu par l'objet » : check pas encore fait.
  Vaut pour toutes les caisses / pots au contenu aléatoire (demande du joueur). Note : tools/check_lua.py affiche « ERREUR »
  pour une fonction locale imbriquée mais sort avec le code 0 (ne bloque pas un `&&`).
- **Checks de chasse (2026-10-07, choix du joueur)** : ramasser une viande d'animal, checks AU
  COMPTE (« Chasse - Viande #3 » = 3e Viande ramassée hors emplacement AP). 6 viandes : communes
  Viande 3069621231, Volaille 3556586016, Poisson 471813919 ; rares Viande de qualité 3577251366,
  Poisson raffiné 3524738970, Gibier juteux 2615454163. Générateur (build_data_from_scans.py,
  HUNT_MEATS) : 105 locations possibles (30 par commune, 5 par rare) ajoutées EN FIN de données
  (les 500 locations existantes gardent leurs ID) + les 6 viandes comme objets. Apworld : options
  `hunting_checks` (case à cocher, activée par défaut) puis `hunting_checks_common` = POURCENTAGE
  (10-100, défaut 100, random possible) des viandes communes demandées par les 6 recettes
  (`HUNT_RECIPE_NEEDS` : Poisson 14, Volaille 12, Viande 12 ; au moins 1). Viandes RARES : 1 check
  chacune, fixe (les recettes n'en demandent qu'une). Par défaut 41 checks (vérifié ; 50 % -> 22) ; locations de
  chasse EXCLUDED (jamais de progression) ; chaque check met sa viande dans le pool. Client :
  `locations.hunts[ItemID]`, viande ramassée sans emplacement -> 1er check actif pas fait, viande
  GARDÉE (pas de retrait). Besoins des 6 recettes (dit par le joueur) : Poisson 14, Volaille 12,
  Viande 12, rares 1 chacune. Générations vérifiées (défaut 12 checks, max 105, 0 objet clé
  dessus). Seed de test : `seeds/test_chasse/AP_43344599983968189208.zip` (41 checks de chasse).
  **VALIDÉ en jeu le 2026-10-07** : 2 Volailles ramassées -> « Chasse - Volaille #1 » puis « #2 ».
  OPTION 2 (choix du joueur, codée le 2026-10-07 ; modèle AP sur la viande au sol VALIDÉ en jeu
  le 2026-10-07 avec le serveur connecté, ramassage / retrait à confirmer) : la viande au sol est habillée comme
  les autres checks (`shop_ui.world.assign_hunts` : viandes de ItemSpawnInfoEnemyDropUseList, ID par
  get_spawnItemId ; chacune reçoit le prochain check pas fait de sa viande, gardé d'un relevé à
  l'autre par `hunt_assign`, jamais deux fois le même ; au-delà : viande normale), ramassage
  retrouvé par `case_gets`, objet AP reçu et viande retirée (revient par le pool). Viande ramassée
  avant d'être habillée : reconnue par son numéro (prochain check), retrait tenté une fois.
  Progression de test_chasse remise à zéro (`seeds/test_chasse/backup_<date>`).
- **Voix pour les pièges (2026-10-07)** : choisies à l'écoute (toutes les voix courtes de Bela et
  Dimitrescu converties dans `Assets/sons/candidats_rire/`, durée en préfixe) : rire de Dimitrescu
  (em1000_v, média fr 1021590585) = piège REÇU ; cri de Bela (em1262_v, média fr 942265860) = piège
  « screamer ». Les médias changent de numéro selon la langue mais pas l'objet Sound :
  `VOICE_MEDIA` (outil) retrouve le Sound en fr puis son média dans chaque langue (9). Triggers des
  voix écrits dans ap_sounds.json (`voice`), lus par le client (`shop_ui.sound.AP.TRAP_LAUGH` /
  `TRAP_SCREAM` / `TRAP_FOR_OTHER`). Boutons « Écouter : rire de Dimitrescu / cri de Bela ».
  **VALIDÉ en jeu le 2026-10-07** (rire, cri, bruit du sac de Lei). Les .wav d'écoute ont été
  supprimés ; pour choisir d'autres répliques, refaire la conversion (vgmstream sur les médias
  DIDX de la banque de voix .fr).
- **Présentation d'un objet REÇU (2026-10-06, idée du joueur)** : objet clé envoyé par un autre jeu
  -> présentation comme au ramassage. Outils de dev, 2 boutons « TEST présentation » (ItemID du
  champ de test) : le vrai objet tombe aux pieds d'Ethan (`ItemSpawnInfoHolder.RequestEnemyDrop`),
  retrouvé dans `ItemSpawnInfoEnemyDropUseList`, puis méthode 1 = ramassage forcé
  (`InteractManager.RequestForceInteract`), méthode 2 = `InteractItemGet.startDetailSearch(joueur)`
  (`shop_ui.present`). Résultat 2026-10-07 : objets clés jamais posés par le drop (place réservée,
  rien au sol) ; Poudre noire posée mais jamais retrouvée par le mod (places et instances
  recyclées). **ABANDONNÉ** (choix du joueur) ; boutons laissés dans les outils de dev.
- **Préfixe « [AP] » dans la présentation (2026-10-06, demande du joueur)** : le nom est écrit dans
  `titleText` de GUIDetailSearch (champ +0x120, pas nameText : d'où l'échec des essais 2 et 3).
  Après le remplacement du messageID, `shop_ui.detail.keep_title` écrit « [AP] nom » dans titleText
  avant chaque rendu (MessageId vidé une fois), 20 s au plus, hors jeu seulement. VALIDÉ en jeu (Boule, 2026-10-06)
  (journal « présentation : titre -> ... »).
- **Masques et Trophée de chasse jamais mélangés (2026-10-06, choix du joueur)** : deux Masques du
  plaisir affichés et bugs de présentation -> `VANILLA_KEY_ITEMS` dans l'apworld (4 masques +
  Trophée de chasse) : leurs emplacements ne sont plus des locations, objets d'origine ramassés
  normalement (le client ne touche pas un emplacement d'objet clé absent de la seed).
  Seed de test : `seeds/test_vanilla_masques/AP_38502385572708853624.zip` sur 38282 (+ faux Joueur2).
- **Vin dans un pot (3e constat, 2026-10-06)** : Sanguis Virginis sur Sac de Lei #030 [S01], toujours
  sans présentation. Objet apparu en mode Normal (1948795948), passé à FixDisplayCenter 48 ms après,
  ramassé 1 s plus tard. Piste : objets sortis d'un pot préparés par le pot lui-même
  (`InteractItemGet.OverrideInteractFromItemSpawn`, `ItemGetConfigure.SetItemSpawnSetType`).
- **Vin dans un pot (2e essai, 02h15)** : toujours sans présentation. La ligne d'objet est préparée
  avec le Sac de Lei 7 ms après la casse, alors que le mod a déjà changé l'objet : ramassage
  préparé par le jeu à l'apparition. Le mode n'est pas dans le placement (ItemSpawnInfo), seulement
  dans l'objet apparu. En attente du test Sac de Lei #007 [S04] (sac au sol).
- **Seed test_chateau remise à zéro (2026-10-04)** à la demande du joueur, même seed, serveur 38282 ;
  ancienne progression (apsave + état du client) dans `seeds/test_chateau/backup_<date>`.
- **« Reset scripts » REFramework** : crash du jeu ~10 s après (18h50:42 et 18h58:09, objets du mod
  recréés). Relancer le jeu au lieu de recharger les scripts.
- **Morceaux de plaque (tombe du centre du Village, 2 boucs) jamais mélangés (2026-10-07)** :
  `SpawnInfo_VillageTombStonePlate_001` (Chapter2_6, S03) est connu des relevés mais pas dans la
  partie de référence (pickups_log_20260926) -> écarté des objets clés par le générateur ; catégorie
  « Objet clé » -> pas non plus une location normale. Un seul morceau à ramasser : l'autre est
  déjà posé sur la tombe (dit par le joueur). Correctif : `KEY_EXTRA` dans build_data_from_scans.py
  (objet clé hors partie de référence, rang = fin de son chapitre), `KEY_USE` = 10**6 (la tombe à
  trésor n'est pas un check : ne sert à aucune location, placé n'importe où dans le Village).
  Objet + location ajoutés EN FIN de données (131 objets / 605 locations existants inchangés,
  vérifié). Le trésor de la tombe EST un check : « Calice de Berengario #018 » (tombe à
  -216 -35 43 ; « [AP] Poudre noire » vu à l'ouverture, 2026-10-07) -> `LOCATION_REQUIRES_KEYS`
  (générateur, par GUID) écrit `requires_keys` sur la location, ajouté aux règles par l'apworld
  (seulement si l'objet clé est mélangé). Seule différence avec les données d'avant : ce champ.
  apworld installée ; 3 générations OK ; seed de test `seeds/test_plaque/AP_07796814757607704282.zip`
  (plaque sur Munitions pour pistolet #003 [S16]). À VÉRIFIER en jeu.
- **Gardien de la tombe (2026-10-07)** : lycan géant à hache qui apparaît à l'ouverture de la tombe,
  `em1062` (Chapter2_6, c02_6_AsyncCharacterPool), lâche une Grande hache cristallisée (1863717).
  DeathLink : `em1062 = "a giant axe-wielding Lycan"` (nom officiel inconnu). Drop en check
  (choix du joueur : demande la plaque, comme le Calice) : `BOSS_DROPS_EXTRA` dans le générateur,
  « Boss - Grande hache cristallisée (gardien de la tombe) », drop_position relevée au ramassage
  (-203.56 -34.51 51.37), rang 415.5, `requires_keys` = Morceau de plaque, ajoutée EN FIN de
  données (objet Grande hache cristallisée aussi). Le boss lâche la hache là où il meurt (dans son
  arène, rappel du joueur) : `drop_radius` = 60 m sur cette location ; le client prend
  `drop_radius or 20` aux 3 endroits de reconnaissance des drops (habillage x2, ramassage).
  Client et apworld installés. À VÉRIFIER en jeu.
- **Présentation sous un faux nom AP (2026-10-07)** : Morceau de plaque ramassé 2 s après la
  volaille habillée « Chasse - Volaille #4 » -> présentation « [AP] Plante » (emplacement AP retenu
  6 s, `near_ap_loc_until`). Correctif À VÉRIFIER : l'emplacement retenu ne vaut que si l'objet
  présenté est son objet d'origine (ItemID du work, sinon nom affiché) ; sinon journal
  « emplacement AP retenu ignoré ». Copié dans le jeu, actif au prochain lancement.
- **Tombe testée en jeu (2026-10-07, seed test_plaque)** : emplacement de la plaque -> objet AP
  (Viande) VALIDÉ ; plaque reçue du multiworld (envoyée avec tools/send_check.py) ; hache du
  gardien reconnue à 1,7 m de la position relevée, check envoyé, VALIDÉ. Défaut : présentation
  plein écran de la Grande hache au ramassage (objet AP non-clé : jamais de présentation). Cause :
  GetMode écrit via `SpawnedInteractItemGetCache` de l'emplacement (absent pour un drop d'ennemi)
  et position « près d'un emplacement AP » (hasHistory forcé) lue sur l'emplacement, pas sur
  l'objet tombé. Correctif À VÉRIFIER : l'entrée d'un drop de boss garde son InteractItemGet
  (`e.get`), utilisé par apply_key_mode (GetMode Once) et near_ap_watch (position). Vaut pour
  tous les drops de boss (Bustes, marteau...).
  Pas de sauvegarde de test disponible (dit par le joueur) : à vérifier au prochain drop de boss
  rencontré dans une partie (ou par les retours des joueurs).
- **Logo de l'écran titre (2026-10-07, image du joueur faite avec ChatGPT)** : le logo est une
  IMAGE, `gui/ui1000/tex/ui1000_00_iam.tex` (1024 x 512, BC7, 1 mip), découpée par
  `ui1000_00.uvs` (14 cases à 0x68 ; VILLAGE métal grand / métal / blanc = 0, 2, 3 ; biohazard
  4-5 ; resident evil 6-7 ; VIII 8 ; « LLAGE » 9 ; traînées 10 ; traits 12-13), menu
  `gui/ui1000/gui/ui1000.gui` (prefab guititle.pfb). Les versions blanches servent sans doute
  au flash de l'animation. `tools/re_engine/make_title_logo.py` : logo du joueur
  (`Assets/titre/logo_re_village_archipelago.png`) coupé en deux lignes par zones de pixels
  reliées (le g de Village descend dans la 2e ligne) : « RE Village » -> cases VILLAGE,
  « Archipelago By Snokayy » -> cases resident evil ET biohazard, versions blanches calculées,
  VIII et LLAGE vidés. Aperçus dans `Assets/titre/`.
  1er essai en jeu : sous-titre trop petit (pixels presque invisibles de la 1re ligne gardés ->
  cadre trop grand ; corrigé : alpha <= 8 mis à 0) ; ancien logo vu ~1 s : cause inconnue.
  PAS la vidéo `streaming/movie/moviefile/re logo animation.mov.1.x64` (VC-1 1080p, 5 s, WMA
  Pro) : c'est le logo RE ENGINE du démarrage (décodé avec ffmpeg, `tools/ffmpeg/`). Le menu
  titre n'utilise que ui1000_00 (ui1000/1010/1020.gui) : l'animation du logo est faite par le
  menu sur les cases de la texture, donc notre sous-titre (cases 6-7) a l'animation de
  « resident evil ».
  2e version (choix du joueur) : logo OFFICIEL gardé (VILLAGE, VIII, LLAGE), seul « resident
  evil » / « biohazard » remplacé par « Archipelago By Snokayy », couleur moyenne du « resident
  evil » d'origine (`--couleur=jeu`, défaut ; or / rouge possibles). La vidéo montre encore
  Le script ignore notre patch_014 pour repartir de la texture du jeu. **VALIDÉ en jeu le
  2026-10-07** : animation officielle sur « Archipelago By Snokayy », plus d'ancien texte.
- **Mode 100 % (2026-10-07, demande du joueur)** : option `missable_checks` : 3e choix
  `cent_pourcent` (= 2). Objectif : `tous_les_checks` RETIRÉ (faire tous les checks = mode
  100 %), numéros des autres choix inchangés ; client : objectif par défaut fin_du_jeu.
  Client (`shop_ui.no_return`, limite de 200 variables locales atteinte : tout dans shop_ui) :
  endroits sans retour = Cachots du château, Passage souterrain, Maison de Luiza
  (`missable_spot`), Château Dimitrescu (Chapter2_2), Maison Beneviento (Chapter2_3). Sorties
  dans `reframework/data/re_village_ap_client/no_return.json` ({endroit: [{chapter, pos, r}]}),
  relevées en jeu (outils de dev > « Mode 100 % : sorties sans retour » : choisir l'endroit,
  « Relever une sortie ICI », journal no_return_captures.jsonl ; case « TEST : murs actifs quel
  que soit le mode »). Dans la sphère d'une sortie (1,5 m) avec des checks manquants : retour à
  la dernière position sûre via `app.PlayerMovement.recovery(via.vec3)` (méthode trouvée dans
  il2cpp_dump, même principe que Player.WarpToPosition du client RE7) + message « Impossible
  d'avancer (endroit), il te manque : … » (6 noms max, toutes les 4 s). L'envoi automatique au
  changement de chapitre reste actif en cent_pourcent (filet de sécurité). Pas de mur au combat
  final. apworld : missable_spot toujours EXCLUDED tant que leurs sorties ne sont pas relevées.
  Génération en cent_pourcent OK. À FAIRE : relever les sorties en jeu (save du château :
  cachots après la 1re sœur), tester le recul, puis recopier no_return.json dans client/.
- **SOFTLOCK de la vidange (2026-10-07, seed test_100)** : énigme des 4 statues validée (plus
  d'interaction) mais le sang ne se vide pas, porte jamais ouverte (déjà vu « récemment » par le
  joueur). Ordre du jeu (rappel du joueur) : Sanguis Virginis dans le seau après Bela ->
  posé à l'étage (énigme du vin) -> Clé de la cour -> salle suivante = vidange. Sur cette seed,
  Clé de la cour reçue du multiworld (Ferraille #023 [S02]) SANS poser le vin : le jeu attend
  sans doute l'énigme du vin. 1er correctif (Sanguis #001 laissé tel quel, `shop_ui.no_touch`)
  fondé sur une confusion de salle : annulé, mécanisme gardé vide. 2e : Clé de la cour jamais
  mélangée, remplacé (choix du joueur) par un MUR ANTI-SOFTLOCK, actif dans tous les modes :
  segment « Salle des statues (vin à poser) » de `shop_ui.no_return` (always = true), bloque
  l'entrée tant que le check de l'emplacement d'origine de la Clé de la cour (récompense du vin)
  n'est pas fait ; message « Avant de continuer, pose le Sanguis Virginis à l'étage (énigme du vin) et ramasse le check
  dans la petite boîte, sinon la vidange ne se lancera pas. » (texte du joueur). Position
  de l'entrée À RELEVER en jeu (outil des sorties, endroit « Salle des statues »). Seed de test
  `seeds/test_100b/AP_30226473343793442368.zip` (Clé de la cour sur Munitions pour pistolet #012
  [S02], mode 100 %).
- **Optimisations (2026-10-07, micro-gels signalés)** : relevé toutes les 8 s : GUID gardé par
  objet (cache vidé toutes les 60 s et au changement de chapitre), seuls les objets de
  ItemSpawnInfoEnemyDropUseList examinés comme drops de boss / viandes ; nettoyage des modèles
  orphelins : parcours de tous les maillages une seule fois, ensuite registre
  `shop_ui.world.created` ; boucles 0,1 s : position seule (`entry_pos`, gardée dans l'entrée) ;
  journal : écrit toutes les 0,5 s (plus d'ouverture du fichier par ligne), > 8 Mo au chargement
  -> debug_log_old.txt. Journal « perf : relevé des emplacements X ms ». À VÉRIFIER en jeu.
- **Langue des messages (2026-10-07, demande du joueur)** : textes du mod déjà en fr / en selon la
  langue du jeu (`tr`). Ajouté : noms d'objets et de lieux traduits si le jeu n'est pas en
  français : `i18n.item(nom)` lit le nom de l'objet dans le jeu (ItemSpecification.findItemSpec
  -> Basic.NameMessageID -> via.gui.message.get, donc dans la langue choisie, 9 langues), cache
  par langue (`i18n.lang`) ; `i18n.loc(loc)` traduit le nom de l'objet d'un lieu (« Handgun
  Ammo #012 [S02] »), « Chasse - » -> « Hunt - ». Utilisé dans Check / Trouvé / Reçu / colis /
  mode 100 % (noms d'endroits : `name_en`). Restent en français : noms des boss entre
  parenthèses, noms dans le multiworld (apworld). À VÉRIFIER avec le jeu en anglais.
- **Sorties relevées (2026-10-07)** : `client/reframework/data/re_village_ap_client/no_return.json`
  = référence, copiée dans le jeu par install.py (ÉCRASE les relevés faits en jeu : les
  recopier d'abord depuis le no_return.json du jeu / no_return_captures.jsonl). Entrée de la
  zone de Dimitrescu (double porte avant la salle des statues ; d'habitude une cinématique y
  montre Dimitrescu, jouée SANS elle quand le vin n'est pas posé, dit par le joueur ; bloquer
  avant la porte pour que l'animation ne se lance pas) :
  -10.33 -8.68 -11.92, Chapter2_2, rayon 2 m (relevée par erreur sous « Cachots du château »,
  déplacée). 1er essai : « repoussé : nil » = pas encore de position sûre (relevé en étant sur la
  sortie) -> repli : poussé hors de la sphère à l'opposé du centre. Recul en jeu À VÉRIFIER.
- **Recul du mode 100 % / mur du vin (2026-10-07)** : 1er essai en jeu : message affiché mais pas
  de recul (« repoussé : false » = composant app.PlayerMovement introuvable sur l'objet joueur de
  PlayerUtility.getPlayer) -> cinématique de la porte jouée. Correctif À VÉRIFIER : recherche
  dans les enfants (3 niveaux, sans fonction imbriquée : tools/check_lua.py la refuse), tout type
  *PlayerMovement*, composants notés au journal (« mode 100 % : composants du joueur ») ;
  repli : Transform.set_Position. Le journal dit la méthode utilisée (recovery / set_Position).
  **VALIDÉ en jeu (2026-10-07 19:45)** : recul par `Transform.set_Position` (Ethan n'a pas de
  composant *PlayerMovement* : pl1000 = PlayerConfigureFPS, PlayerUpdaterFPS... ; recovery()
  n'existe que pour les personnages TPS). Mur du vin fonctionnel devant la porte de Dimitrescu.
- **Fenêtre au centre de l'écran (2026-10-07, demande du joueur, comme l'Archipelago de RE4)** :
  `shop_ui.popup.show(titre, lignes, durée)`, dessinée dans re.on_frame (imgui : fond sombre,
  bordure or, titre or agrandi, texte à la ligne ; styles et fonctions protégés par pcall).
  Utilisée par les murs (mode 100 % : liste des checks manquants ; mur du vin), affichée tant
  qu'on est repoussé + 4 s. Pas de bouton (pas de souris en jeu). À VÉRIFIER en jeu.
- **Fenêtre bloquante (2026-10-07, demande du joueur)** : `shop_ui.popup.show_modal` : jeu figé
  (`via.Scene.set_TimeScale(0)`, ancienne valeur remise), curseur affiché
  (`via.hid.Mouse.set_ShowCursor`, statique), bouton « J'ai compris, je vais le faire » ; aussi
  Entrée / Espace (`reframework:is_key_down`) ou bouton de validation de la manette
  (`via.hid.GamePad.get_MergedDevice():get_Button()` & `get_EnterButton()`), touche relâchée puis
  appuyée. Sécurités : fermeture seule après 120 s, et au rechargement des scripts. Murs : 1re
  fois = fenêtre bloquante ; dans les 20 s après l'avoir fermée = simple panneau (sinon elle se
  rouvrirait en boucle). Clic à la souris incertain (REFramework ne donne la souris à imgui que
  menu ouvert ?). À VÉRIFIER en jeu.
  Suite (2026-10-07, retours du joueur) : curseur via.hid.Mouse inutile (imgui n'a la souris que
  menu REFramework ouvert : le bouton se clique alors) -> retiré, touches indiquées en clair ;
  fenêtre bloquante à CHAQUE tentative ; pause du jeu lui-même : `app.GlobalService.requestPause(
  app.PauseType.InGameFullNoMenu, false)` / `requestReleasePause` (TimeScale = 0 en secours,
  méthode notée au journal « fenêtre bloquante : pause ») ; fenêtre dessinée même si la pause
  rend « en jeu » faux (isEnableInGameFlow). À VÉRIFIER.
  **VALIDÉ en jeu (2026-10-07)** : fenêtre bloquante + pause du jeu (requestPause), fermeture aux
  touches.
- **Boîte de dialogue DU JEU (2026-10-07, en cours)** : la fenêtre imgui ne reçoit pas la souris du
  jeu (curseur dessiné derrière). Piste : `app.DialogManager.openDialog(app.DialogManager.Parameter
  { dialogID = app.DialogDefine.<nom>.Hash, work = app.GUIDialog.Parameter { titleMsg, bodyMsg,
  button1Msg en texte brut } })`, fermeture = work.isClosed (258 boîtes dans app.DialogDefine ;
  candidates à un bouton : NoticeGameSystem00/01, SaveDone, InventoryNoEmpty...). Outil : outils
  de dev > « Boîte de dialogue du jeu (essai) » (Décrire = nombre de boutons / textes d'origine
  au journal ; TEST = ouverture avec un texte Archipelago ; case « Utiliser cette boîte pour les
  murs » -> `shop_ui.dialog.ENABLED`). Fenêtre imgui gardée en secours.
  Suite : 1er essai : `app.DialogDefine.<nom>` se lit comme un NOMBRE (hash), pas un objet
  (« attempt to index a number ») -> `shop_ui.dialog.hash_of`. 2e essai : NoticeGameSystem00
  s'ouvre (bouton OK, souris / manette du jeu) mais avec SON texte (nouveau mode de difficulté)
  et sans pause. Correctifs À VÉRIFIER : textes écrits dans titleText / bodyText (set_Message) à
  chaque lateUpdate des classes app.GUIMisc.Dialog* tant que la boîte est la nôtre ; pause du
  jeu à l'ouverture avec isNecessaryGUI = true (la boîte doit continuer à vivre), levée à la
  fermeture (`shop_ui.dialog.watch`, re.on_frame) ; fermée de force après 60 s.
  Suite : boîte fermée seule, jeu resté figé (pause système = la boîte disparaît sans isClosed) ->
  boîte du jeu figée par TimeScale = 0 (pas requestPause), fermeture aussi détectée par
  DialogManager.isShowing() == false, pas de réouverture tant qu'elle est affichée ; un clic
  n'importe où la fermait -> set_isClickableByOutRange(false) dans le hook. À VÉRIFIER.
  Suite : TimeScale = 0 -> boîte invisible (son animation ne joue plus), jeu figé. Nouvelle
  approche À VÉRIFIER : boîte ouverte sans pause ; à sa 1re mise à jour (hook lateUpdate) :
  set_isIgnoreSystemPause(true) puis requestPause(InGameFullNoMenu, isNecessaryGUI = true).
  **VALIDÉ en jeu (2026-10-07)** : boîte du jeu NoticeGameSystem00 avec notre titre / texte, jeu
  en pause derrière, fermeture par OK seulement. Activée par défaut pour les murs
  (`shop_ui.dialog.ENABLED = true`), fenêtre imgui en secours si l'ouverture échoue.
- **Cause du softlock de la vidange CONFIRMÉE (2026-10-07)** : vin posé + check de la petite boîte
  ramassé -> mur ouvert, la sœur attaque dans le hall (scénarisé, absent avant) et la cinématique
  de la porte montre Dimitrescu (absente avant). L'énigme du vin déclenche l'avancée du scénario ;
  la Clé de la cour reçue sans elle laissait le jeu dans un état incohérent. Mur du vin = bon
  correctif.
  **Vidange VALIDÉE (2026-10-07)** : statues -> sang vidé, porte ouverte. Softlock réglé.
- **Clé de Dimitrescu jamais mélangée (2026-10-07, softlock, choix du joueur)** : on la trouve
  DANS ses appartements, qu'on ne quitte qu'avec elle ; mélangée (seed test_100 : vraie clé sur
  Sanguis Virginis #001), le joueur entré sans elle était enfermé (débloqué avec
  tools/send_check.py). De plus l'emplacement de la clé n'a fait apparaître AUCUN objet
  (« instance=aucun » à 9 m) : cause inconnue (objet clé unique jugé déjà obtenu ? apparition
  scriptée ?). -> « Clé de Dimitrescu » dans VANILLA_KEY_ITEMS. Nouvelle seed de test
  `seeds/test_100b/AP_40268200579724997010.zip` (mode 100 %, Clé de la cour mélangée, Clé de
  Dimitrescu à sa place).
  Confirmé par le joueur : avec la clé reçue d'Archipelago (pas ramassée sur place), ouvrir la
  porte ne lance PAS la cinématique de Dimitrescu et on ne peut plus avancer : le ramassage de
  la clé dans ses appartements est lui-même un déclencheur du scénario. Même schéma que l'énigme
  du vin (Clé de la cour). À surveiller pour les autres objets clés : un ramassage ou une énigme
  qui fait avancer le scénario ne doit pas être court-circuité par un objet reçu.
- **Plantage du jeu (2026-10-07 22:55, c0000005 dans re8.exe)** quelques secondes après un check
  des cachots et une sauvegarde (changement de zone ?). Cause non prouvée ; deux optimisations du
  soir rendues sûres : nettoyage des modèles orphelins de nouveau par parcours de la scène
  (objets vivants seulement ; le registre ne détruisait peut-être un objet déjà détruit par le
  jeu), toutes les 2 min ; cache des GUID vidé aussi quand le nombre d'emplacements chargés
  change. À surveiller.
- **Sortie des cachots relevée (2026-10-07)** : devant le levier (les 3 checks [S08] se font avant
  le levier ; après : course-poursuite avec Dimitrescu), -22.82 -21.26 -16.10, Chapter2_2, rayon
  1,5 m. Recopiée dans client/.../no_return.json. **VALIDÉ en jeu (2026-10-07)** : bloqué avec
  les 3 checks manquants (boîte du jeu + liste), passage libre une fois les 3 faits.
- **Option « Mélanger les objets d'énigme de la maison Beneviento » RETIRÉE (2026-10-07, choix du
  joueur : énigmes scénarisées, trop de bugs)** : classe et champ supprimés d'Options.py, ses
  locations toujours inactives (`loc.beneviento`), slot_data `randomize_beneviento_puzzles` =
  false ; ligne retirée des yaml de test. Maison Beneviento : pas de mur du mode 100 % (objets
  tous obligatoires pour avancer). Description du mode 100 % mise à jour. Génération OK.
- **Sorties restantes du mode 100 %** : fin du château (avant le combat final), passage souterrain
  (tunnel du Village juste avant le château, checks Sac de Lei #002 / Munitions pour pistolet
  #001 [S09], rangs 36-37 ; mur à la sortie côté château), maison de Luiza (avant ce qui
  déclenche l'attaque des lycans). Nouvelle partie nécessaire pour les deux derniers.
- **Sortie de la fin du château relevée (2026-10-07)** : juste après la porte des masques, avant le
  combat final, -91.55 -11.91 -30.05, Chapter2_2, rayon 1,5 m. Blocage vu en jeu (98 manquants).
  PIÈGE corrigé : 11 checks du château ne se font qu'APRÈS ce point (S12 juste derrière, toit
  S09, 2 objets à x ≈ -150, Dimitrescu cristallisée) -> exclus du mur : rangs 172-179 de la partie
  de référence, et pour les rangs inconnus (180.5) position x < -94. Répétition du journal à
  chaque image supprimée (pas de nouveau message tant que la boîte du jeu est ouverte).
  ATTENTION : install.py écrase le no_return.json du jeu -> toujours recopier les relevés avant.
- **À FAIRE : vignes du château (2026-10-07, signalé par le joueur)** : on ne peut plus y retourner
  une fois entré dans le château -> leurs checks seraient perdus en mode 100 % (et le mur de fin
  du château les demanderait). Seul check « château » identifié à proximité : Plante #001 [S00]
  (-36.3 -18.3 23.8, jamais ramassée dans la partie de référence). Le joueur relèvera en jeu la
  position de l'entrée du château depuis les vignes ; ensuite : endroit « Vignes » (liste des
  checks d'après leur position) et exclure ces checks du mur de fin du château.
- **Couteau de départ disparu (2026-10-07, nouvelle partie, Chapter2_1)** : le jeu charge aussi les
  emplacements du 2e passage au Village (Chapter2_6) pendant le 1er ; le mod les habillait (ex.
  GM 79 #012 [S00] à -17.3 -43.4 132.1 : modèle caché + objet modifié sur place) et le couteau
  planté dans le meuble n'apparaissait plus. Correctif À VÉRIFIER : un emplacement dont le
  folder_path est d'un autre chapitre (ChapterN_M) que le chapitre en cours n'est jamais habillé
  (shop_ui.world.update) ni compté au ramassage (journal « ignoré (emplacement du …) ») ;
  chapitre en cours recopié dans `shop_ui.chapter` (le code du ramassage est avant last_chapter).
- **Check impossible de la maison du départ (2026-10-07)** : « Remède de premiers soins #004 [S00] »
  (-2.49 -44.54 159.58) = emplacement du chapitre 2_6 dans la maison où l'on prend le couteau,
  fermée au 2e passage (jamais ramassé dans la partie de référence) ; visible seulement au 1er
  passage (2_1), où l'ancien script l'habillait à tort. Choix du joueur : pas de mur, envoi
  automatique. Générateur : MISSABLE_SPOTS « Maison du départ » (EXCLUDED : jamais d'objet
  important) + `AUTO_SEND_GUIDS` -> champ `auto_send` ; client : `shop_ui.auto_send` envoie ces
  checks dès qu'on est connecté et en jeu (journal « envoi automatique (check impossible en
  jeu) »). Seul changement des données : ces 2 champs sur cette location.
- **Logo AP invisible sur le fusil à pompe (2026-10-08, M1897 #001)** : « boîte d'origine ignorée
  (1.59 m pour un objet de 0.09 m) » -> logo posé sur l'os _00 du fusil, dans la table. La règle
  (boîte d'origine démesurée ignorée, cas du Crâne cramoisi) ne s'applique plus quand l'objet
  d'origine est une ARME (vraie grande boîte) : logo posé au bas-centre de la boîte du fusil. À
  VÉRIFIER (ramassage possible même invisible : l'invite du jeu reste).
- **Fin de session 2026-10-08 ~00:15** : au 1er passage au Village (Chapter2_1), Ferraille du
  tracteur et Fragment de cristal dans l'œil du bouclier de la statue pas en objet AP : ce sont
  des emplacements du 2e passage (Chapter2_6), volontairement plus habillés depuis le correctif
  du couteau (1 seul emplacement 2_1 chargé : M1897 #001). À confirmer au chapitre 2_6.
  M1897 #001 : « objet pas posé par le jeu » après le Reset scripts (fusil caché + modifié sur
  place par l'ancien script) ; check envoyé à la main. Suite prévue par le joueur : finir les
  murs (passage souterrain, maison de Luiza, vignes), puis launcher et menus visuels en jeu.
- **Révision (2026-10-08, demande du joueur)** : les emplacements du 2e passage au Village
  (Chapter2_6) sont posés et ramassables dès le 1er (Chapter2_1) ; ramassés là sans être des
  checks, ils seraient perdus. Ils sont de nouveau habillés et comptés au 1er passage
  (`shop_ui.SAME_STAGE`), SAUF GM 79 #012 [S00] pendant le Chapter2_1 (`shop_ui.KNIFE_SPOT` :
  endroit du couteau de départ). La règle « autre chapitre » (`shop_ui.other_chapter`) reste pour
  les autres chapitres (habillage, ramassage, échange bloqué). À VÉRIFIER : couteau présent,
  Ferraille du tracteur et Fragment du bouclier en objets AP au 1er passage.
- **Demande à étudier (2026-10-08, le joueur)** : mélanger aussi les objets clés du 1er passage au
  Village (Chapter2_1 : Morceaux de relief vierge / démon...), sauf le couteau. Obstacles : ces
  emplacements ne sont pas dans les données (partie de référence commencée plus tard : un seul
  check 2_1, M1897 #001) -> relever le 2_1 en jeu (« Scanner la zone », nouvelle partie) ; et ils
  disparaissent en quittant le 2_1 (KEY_FORBIDDEN_CHAPTERS) -> murs ou objets sans importance
  seulement, à décider avec le joueur.
- **Morceaux de relief du 1er passage mélangés (2026-10-08, choix du joueur)** : vierge (église,
  rang 2) et démon (boîte au tournevis après la maison de Luiza, rang 30), posés ensemble à la
  porte ensuite -> KEY_USE 31 (placés sur un emplacement ramassé avant). `FIRST_PASS_KEYS` dans
  le générateur : leurs emplacements (Chapter2_1 seulement) = missable_spot « Village (1er
  passage) » (EXCLUDED), missable_chapter Chapter2_1 (envoi automatique en quittant le 1er
  passage), no_key_items ; ajoutés TOUT À LA FIN des données (vérifié : 0 changement des
  existants). Restent à leur place (joueur) : Coupe-boulon (ruines de la maison du début), Clé du
  pick-up (véhicule de la maison de Luiza), couteau et LEMI de départ (1er combat). Les objets
  ordinaires du 1er passage sont déjà des checks (51 emplacements partagés avec le 2e passage ;
  restent hors checks : caisses aléatoires et drops). 4 générations OK ; seed de test
  `seeds/test_reliefs/AP_80754904329572935804.zip`. Reçu du multiworld au lieu d'être ramassé :
  À VÉRIFIER que la porte s'ouvre (cas Clé de Dimitrescu / Clé de la cour).
- **Maison de Luiza : envoi automatique (2026-10-08, choix du joueur : pas de mur)** : champ
  `auto_send_after` = Chapter2_1 (générateur : AUTO_SEND_AFTER par missable_spot) sur ses 3
  checks et sur les 2 emplacements des reliefs ; client : envoyés en quittant ce chapitre (vers
  un autre chapitre), QUEL QUE SOIT le mode des zones ratables (journal « envoi automatique : N
  check(s) perdus du Chapter2_1 »). Seul changement des données : ce champ sur ces 5 locations.
  Ajout (2026-10-08, demande du joueur) : checks de Luiza envoyés DÈS le Morceau de relief démon
  (boîte au tournevis juste après la maison) : champ `auto_send_when` {location « Morceau de
  relief (démon) #009 », item_id 1132688171} ; client `shop_ui.auto_send_when` (toutes les
  secondes) : check du repère fait, ou objet du repère ramassé (`shop_ui.picked_item_ids`, rempli
  par le hook de ramassage). L'envoi en quittant le Chapter2_1 reste en secours.
- **Compteur de la salle (2026-10-08)** : « Salle Village - Champ en jachère : aucun check » alors
  qu'il y en a : deux salles du jeu portent ce nom (2075704987 et 3291355158), checks rattachés à
  l'autre numéro. Compté désormais par numéro OU par nom de salle (`room_name`). À VÉRIFIER.
  Suite : affichait 0 / 1 avec 3 checks déjà faits dans le champ : ces checks n'ont pas de salle
  dans les données, et le rattachement « ramassé ici » se trompait de salle. Salle apprise par la
  POSITION : chaque seconde, les checks à moins de 4 m (3 m en hauteur) du joueur sont rattachés
  au NOM de la salle actuelle (`room_cache.names`, sauvegardé) ; le compteur utilise ce nom en
  priorité. À VÉRIFIER (le compteur se complète en marchant près des checks).
  **VALIDÉ en jeu (2026-10-08)** : relief démon reçu du multiworld (pas ramassé sur place) ->
  porte ouverte, le joueur est passé au passage souterrain. Pas de softlock.
- **Passage souterrain : envoi automatique au lieu d'un mur (2026-10-08)** : sa porte se referme
  derrière le joueur ; le mur relevé par erreur APRÈS la porte (22.05 -30.08 -0.28, déjà
  Chapter2_2) l'aurait enfermé -> retiré du no_return.json du jeu. Juste après la porte le jeu est
  au Chapter2_2 : `AUTO_SEND_AFTER["Passage souterrain"] = "Chapter2_1"` (2 checks envoyés en
  franchissant la porte, tous modes). Description du mode 100 % mise à jour (cachots et fin du
  château ; Luiza / passage : exclus et envoyés tout seuls). Reste : vignes du château.
  RÉVISION (choix du joueur) : mur GARDÉ, collé à la porte côté château (22.05 -30.08 -0.28,
  Chapter2_2), rayon 2,5 m (la porte ne se referme qu'en s'éloignant). En mode 100 %, l'envoi au
  changement de chapitre est désactivé pour un endroit muni d'un mur (sinon le mur ne bloquerait
  jamais) ; filet `shop_ui.no_return.past_wall` : dans le chapitre de la sortie, à plus de 15 m du
  mur avec des checks manquants -> envoyés tout seuls. Hors mode 100 % : envoi en quittant le
  Chapter2_1 comme Luiza. Le joueur parle d'un 3e check dans le passage : les données n'en ont
  que 2 (Sac de Lei #002, Munitions pour pistolet #001) -> à identifier.
  Suite : « Passage souterrain 2 / 3 » : la Clé ailée #001 (pont, -159 -34 82) a un room_hash
  (4066587073) d'une AUTRE salle nommée « Passage souterrain ». Comparaison par nom réservée aux
  salles apprises par la position ; sinon numéro exact. Bouton de diagnostic : outils de dev >
  Mode 100 % > « Lister les checks comptés dans cette salle (journal) ».
- **2e plantage du jeu (2026-10-08 01:06:16, c0000005 dans re8.exe, RIP 7ff78a988389)** : achat-check
  « Duc - Formule : Mines » (01:06:03), boutique fermée (01:06:13, « prefabs d'origine remis »),
  don de la Coupe de Cesare (déjà donnée sans souci 2 fois avant) puis plantage 9 ms après. Cause
  non trouvée. Avec celui de 22:55 : deux plantages quelques secondes après un changement d'état.
  Si ça recommence : retirer toutes les optimisations du 2026-10-07 (cache GUID, registre des
  modèles, journal groupé) pour isoler, puis les remettre une par une.
- **BUG EN COURS (2026-10-08 01:12) : objet à quantité 0 dans la mallette** : case « Remède 0 »
  (capture du joueur), menu de confection figé avec « 000 » partout, boutique qui refuse un
  achat de 4000 Lei avec 4410 Lei. Avant : achat-check « Duc - Formule : Mines » (achat du jeu
  sauté, 3500 Lei débités, 01:06:03), crash 01:06:16, rechargement. Le mod n'a ni donné ni retiré
  de remède (ses retraits = Fragment de cristal 1943719610). Pistes : case préparée par le jeu pour
  l'achat sauté ; affichage de la boutique perturbé (modèle de la poudre noire pour le Remède
  1429493426). À trouver en priorité (peut expliquer crash + refus d'achat + menu figé).
- **Objets perdus après rechargement (2026-10-08, agrandissement de mallette)** : CAUSE TROUVÉE :
  juste après le chargement, le jeu refait une sauvegarde automatique (emplacement -1) ; le mod
  notait alors l'état actuel (13 objets) sur cet emplacement AVANT de comparer -> « 13 contre
  13 », rien redonné. Correctif : l'état de la sauvegarde chargée est retenu au moment de
  WriteBackSaveData (`save_sync.load_target`) et utilisé pour la comparaison. Récupération de la
  partie en cours : bouton « Redonner tous les objets reçus ». À VÉRIFIER : rechargement d'une
  sauvegarde plus ancienne -> objets reçus depuis redonnés.
- **Suite du bug de la mallette (2026-10-08 ~01:30)** : redon forcé (bouton) bloqué en boucle :
  createAndAddItem LÈVE une erreur (« pas_pret ») pour le Morceau de relief démon (déjà
  possédé), les Grenades aveuglantes et la Coupe de Cesare (10 fois d'affilée), d'autres objets
  passent. Correctifs : objet clé déjà dans la mallette = compté donné ; 10 refus de suite ->
  colis (la file ne bloque plus). Hypothèse principale : le crash de 01:06:16 (9 ms après le don
  de la Coupe de Cesare, donnée sans souci dans d'autres parties) a laissé une entrée corrompue
  -> confection figée (« 000 »), ajouts refusés, peut-être le refus d'achat chez le Duc.
  Sauvegarde du joueur jugée non réparable (2 seeds, redons forcés, crash) : nouvelle partie
  conseillée. À TESTER : don de la Coupe de Cesare (1614445624) sur une save propre.
  Vu aussi : « valise : ... cases max 77 » après une Valise reçue (00:35) : valeur à vérifier.
- **CAUSE TROUVÉE (2026-10-08, par le joueur) : objets donnés mallette pleine** : le jeu ne refuse
  pas createAndAddItem quand la mallette est pleine, il pose l'objet sur une case occupée ou hors
  grille -> objets superposés, confection figée (« 000 »), ajouts suivants refusés. Le mod ne
  voyait « plein » que si le jeu levait une erreur. Correctif : pour un objet qui prend une case
  (Ammo, Recovery, Weapon), case libre demandée d'abord (Inventory.getBlankSlotNo) ; aucune et pas
  de pile existante -> « plein » -> colis (redonné plus tard). Aussi : bouton « REPARER la
  mallette » (objets à 0 retirés, objets superposés / hors grille replacés sur une case libre via
  getBlankSlotNo) et réparation automatique 2 s après une Valise reçue. À VÉRIFIER en jeu.
- **Test de l'achat de la Coupe de Cesare (2026-10-08 ~01:55)** : achat-check chez le Duc + don de
  la Coupe de Cesare : pas de crash, objet reçu (script avec la vérification de case libre). Le
  crash de 01:06 venait donc très probablement de la mallette pleine / corrompue, pas de l'objet.
- **Vignes du château (2026-10-08)** : salle « Village - Vignes » (chapitre du château Chapter2_2) ;
  un seul check appris dans les vignes : Plante #001 [S00] (-36.3 -18.3 23.8), aucun autre check
  du château à z > 10. PIÈGE corrigé : le mur de fin du château la demandait alors qu'on ne
  revient plus aux vignes -> exclue (z > 15) du segment « Château Dimitrescu » ; nouveau segment
  « Vignes du château » (checks du château à z > 15). Mur à relever à l'entrée du château, côté
  vignes (outil des sorties, endroit « Vignes du château », après relance du jeu).
- **Crash 2026-10-08 01:54:57 (porte cochère du château)** : 13 ms après l'habillage de Poudre
  noire #003 [S00] avec MA Bague avec un œil écarlate, modèle sm90_066_Jewelry posé SUR l'objet
  du jeu (KEY_MESH_INPLACE). Même cause que les 4 crashs de la cave à vin (2026-10-04) avec la
  Bague. Correctif : modèle « Jewelry » jamais posé sur l'objet du jeu (objet à part). À VÉRIFIER.
- **Réparation de la mallette corrigée (2026-10-08 02:07)** : version précédente fausse (comparait
  les cases de TOUS les objets ; objets clés, formules et armes ont chacun leur numérotation :
  « case 0 » x3 sans superposition). Ne touche plus que les objets de la grille (Ammo, Recovery,
  Weapon), et replace aussi les piles « sans case » (-1 : 10 Munitions pour pistolet, 5
  Cartouches de fusil dans la save du joueur, donnés mallette pleine). Valise reçue à 02:05 :
  « cases max 126 » (45 au relevé de 01:37) : valeur anormale, Valises cumulées ? À VÉRIFIER.
  Crash à 02:03:34 PENDANT le chargement de la sauvegarde, avant toute action du mod : piste =
  piles sans case enregistrées dans la save.
- **Valise en boucle / mallette à 126 cases (2026-10-08 02:10-02:14) : BUG DU MOD (corrigé)** : la
  réparation ajoutée à 01:4x mettait `shop_ui.fix_case_at` dans give_item, AVANT la déclaration de
  shop_ui dans le fichier -> erreur Lua juste après addExtendLevel -> la Valise restait dans la
  file et était redonnée 4 fois par seconde (243 fois). Ligne retirée ; vérifié : plus aucune
  utilisation de shop_ui avant sa déclaration. Mur des vignes relevé par le joueur
  (-54.69 -9.98 6.68, Chapter2_2, entrée du château côté vignes), recopié dans client/.
- **Murs du passage souterrain et des vignes VALIDÉS en jeu (2026-10-08)**. Murs validés : vin,
  cachots, passage souterrain, vignes. Reste à vérifier : fin du château (blocage vu, liste
  corrigée de 12 checks d'après le mur non revérifiée).
- **Achat refusé (4000 Lei avec 4410)** : réglé d'après le joueur, conséquence de la mallette
  corrompue (Lei faussés). Plus de problème depuis la réparation.
- **Mur de fin du château VALIDÉ en jeu (2026-10-08)**. Les 5 murs sont validés (vin, cachots, fin
  du château, passage souterrain, vignes) : MODE 100 % TERMINÉ. Maison de Luiza et maison du
  départ : envoi automatique ; maison Beneviento : pas de mur (objets obligatoires).
- **Fragment de cristal tiré du mur (2026-10-08)** : Fragment de cristal #015 [S01] (FallByAttack)
  tombe quand on tire dessus ; ramassé à plus de 5 m de son emplacement -> « placement trouvé =
  false », check perdu (envoyé à la main). Correctif À VÉRIFIER : pour un emplacement
  FallByAttack, son InteractItemGet est noté dans `case_gets` (avant le retour anticipé des
  trésors dans swap_pickup) : le ramassage le retrouve où qu'il soit tombé.
- **Mur de fin du château inactif au tout début (2026-10-08)** : c'est la même porte qu'à
  l'arrivée (les sœurs enlèvent Ethan, puis les 4 statues). Segment « Château Dimitrescu » :
  `active` = au moins un check du château (selon son test) déjà fait ; évalué une fois par seconde.
- **Sauvegarde figée (2026-10-08 02:24, emplacement 18)** : script vivant pendant le freeze ;
  cause probable : niveau de mallette très au-delà du maximum (Valise donnée 243 fois ;
  app.InventoryExtendLevel n'a que Level1..Level6 ; 126 cases). Correctif À VÉRIFIER :
  `i18n.extend_level_info` (rangée dans i18n : limite des 200 variables locales) ramène le niveau
  au Level6 s'il le dépasse, au chargement d'une sauvegarde et avant chaque Valise ; Valise reçue
  au niveau maximum = comptée donnée sans agrandir.
- **Mallette ramenée au niveau maximum : VALIDÉ (2026-10-08)**, sauvegarde de nouveau possible.
  Redon après rechargement : OK (objets refusés juste après le chargement -> colis -> donnés
  10-30 s après). Bague avec un œil écarlate perdue : « déjà ramassé au sol, pas redonné » alors
  que la sauvegarde chargée était plus ancienne que ce ramassage. Correctif : refus seulement si
  l'objet est vraiment dans la mallette (inventory_quantity). Récupération : don manuel
  (ItemID 2183898626).
- **Mur « Porte de la Bague » (2026-10-08, demande du joueur)** : la porte s'ouvre au ramassage de
  la Bague ; un check d'avant (Ferraille #001 [S01], -73.4 -10.66 -38.86, jamais ramassé dans la
  partie de référence) devient inaccessible ensuite. Segment « Porte de la Bague » : checks exigés
  lus dans no_return.json (champ `requires` de la sortie). Position À RELEVER en jeu, puis
  ajouter requires = ["Ferraille #001 [S01]"].
  Relevé (2026-10-08 02:35) : -76.64 -11.99 -41.83, Chapter2_2, rayon 1,5 m, requires =
  ["Ferraille #001 [S01]"] ; recopié dans client/.../no_return.json. Actif en mode 100 %.
- **À FAIRE (2026-10-08) : présentation sur l'emplacement d'origine de la Bague** (check donnant
  du Poisson, à moi) : 1) modèle AP posé SUR l'objet du jeu (méthode 1 des key_item_location) ->
  la présentation, réglée pour une toute petite bague, zoome : Poisson ~3x trop grand ; adapter
  l'échelle du modèle à la taille de l'objet d'origine pendant la présentation. 2) nom d'origine
  affiché (pas « [AP] Poisson ») ; rien au journal : limite des notes de présentation atteinte
  (`shop_ui.detail.can_note`, 40 par session) -> relever la limite pour diagnostiquer.
- **Présentation sur un emplacement d'objet clé d'origine (2026-10-08, corrigé sans test, les
  joueurs testeront)** : 1) nom : la règle « objet présenté = objet d'origine » refusait l'objet
  de ramassage du mod (objet d'origine changé sur place en Fragment de cristal) -> accepté (ID
  PICKUP_ID ou son nom) ; limite des notes de présentation 40 -> 300. 2) taille : objet d'origine
  mesuré avant la pose (`shop_ui.world.mesh_size`, get_WorldAABB) ; 2 s après, modèle AP plus de
  1,5x plus grand -> réduit à la taille de l'objet d'origine (journal « réduit x… »).
- Mur de fin du château pas revenu après l'enlèvement (2026-10-08) : diagnostic ajouté (« mur de
  … ACTIF / inactif » au journal). À revoir.
- **Murs cassés par un reste de patch interrompu (2026-10-08 ~02:45)** : une ligne appelait
  `segment.active()` sans paramètre -> erreur dans shop_ui.no_return.update -> AUCUN mur ne
  bloquait depuis 02:35. Ligne retirée ; condition d'activation non voulue sur le mur des vignes
  retirée aussi. Mur de fin du château : actif DÉFINITIVEMENT dès que le check « Bague avec un œil
  écarlate #008 » est fait (choix du joueur ; risque connu : crash juste après la Bague sans
  sauvegarde) ; sans ce check dans la seed : dès qu'un check du château est fait.
  **VALIDÉ en jeu (2026-10-08)** : mur de fin du château actif après le check de la Bague (le
  joueur bloqué devant la porte après l'enlèvement), libre au tout début.
- **Plan suivant (fixé par le joueur, 2026-10-08)** : launcher ; réglages de l'apworld (options
  yaml) ; menus visuels en jeu (à expliquer) ; puis V1 en release GitHub (installation manuelle ;
  les autres passent par le launcher). Outil existant : tools/make_release.py.
- **Launcher (2026-10-08)** : `tools/launcher/` remplace `tools/installer/installer.py` (gardé,
  plus utilisé). Sur le modèle du launcher RE4R (« RE4R AP Wizard », regardé en l'exécutant).
  Python/tkinter, thème sombre + logo du titre, FR/EN selon la langue de Windows. Écrans :
  Accueil (Jouer / Préparer mes options / Héberger) ; Installation (badges jeu, REFramework, mod
  + version, fichiers loose, apworld ; installer / mettre à jour / désinstaller ; manifeste avec
  la version) ; Jouer (adresse, slot, mot de passe -> test de connexion en Tracker par
  `apnet.check` (websocket maison, wss/ws essayés, lien de page de room accepté) -> écrit
  connection.json avec l'adresse complète + auto=true, puis `steam://rungameid/1196590`) ;
  Mes options (formulaire construit depuis Options.py par `options_schema.py`, options « pas encore
  actif » cachées -> YAML ; VALIDÉ : seed générée avec ce YAML) ; Héberger (guide en 5 étapes :
  Archipelago, apworld, Players, Generate, archipelago.gg ou serveur local). Bas : ouvrir les
  journaux, rapport de bug (zip sur le Bureau, mot de passe masqué). Réglages du launcher :
  %APPDATA%\RE Village Archipelago\settings.json (+ launcher.log).
  `tools/make_release.py` construit `RE_Village_AP_Launcher.exe` + files/ (version.json,
  options.json). Testés : connexion (OK / slot inconnu / injoignable), installation + mise à jour
  + désinstallation dans un faux dossier de jeu, exe compilé. NON testés : room archipelago.gg
  (wss + lecture de la page de room), lancement réel par « Jouer », install sur le vrai jeu
  (attention : écrase no_return.json du jeu, comme install.py).
- **Launcher, ajouts (2026-10-08, demande du joueur)** : écran Jouer = enregistrement AUTOMATIQUE
  dans le jeu (connection.json, auto=true) 0,7 s après chaque modification de l'adresse / du slot /
  du mot de passe, sans test réseau (`apnet.guess_uri` : ws:// en local, sinon wss:// ; lien de
  page de room lu en arrière-plan) : ensuite lancer le jeu suffit. « Tester » / « Jouer » écrivent
  l'adresse vérifiée. Mes options : bouton « Importer un YAML… » (lecteur maison `read_yaml`,
  options pondérées = plus gros poids, YAML d'un autre jeu refusé) ; le nom du slot importé est
  aussi écrit dans le jeu si une adresse y est notée ; réglages gardés à chaque changement.
  Rappel : les réglages d'un multiworld déjà généré viennent du serveur (slot_data) à la connexion,
  pas du YAML.
- 2026-10-08 : mod retiré du jeu du joueur pour tester l'installation par le launcher ; tout est DÉPLACÉ dans resident_evil_village/backup_jeu_2026-10-08/ (données client : scans, états, captures no_return, connexion ; re2_fw_config.txt d'avant). REFramework gardé ; fichiers loose remis à false pour le test.
- **Avertissements et installation manuelle (2026-10-08, demande du joueur)** :
  - Mod (`shop_ui.notice`) : au lancement sans session (adresse/slot vides ou connexion auto
    coupée) -> fenêtre au centre, même à l'écran titre (popup « anywhere », 45 s, Entrée/Espace/A) :
    on jouera normalement + comment se connecter (launcher OU menu REFramework). Pas connecté 40 s
    après le lancement -> fenêtre « le serveur ne répond pas ». Connexion refusée -> fenêtre. En
    partie, connecté, mauvaise difficulté -> boîte du jeu bloquante (« J'ai compris »), une fois par
    chargement. Textes en haut à gauche MASQUÉS sans connexion ou en mauvaise difficulté.
  - Menu REFramework (Inser > Script Generated UI > RE Village Archipelago) : connexion lisible pour
    les joueurs sans launcher (explications, adresse/slot/mot de passe, port seul accepté).
    Outils de développement cachés sauf si `reframework/data/re_village_ap_client/dev.json`
    existe (posé par tools/install.py, jamais dans une release).
  - net.lua : adresse sans protocole -> ws:// en local, wss:// sinon (archipelago.gg).
  - Launcher : à la fermeture sans session enregistrée dans le jeu (mod installé) -> question
    « Quitter quand même ? » (Non = onglet Jouer). VALIDÉ (capture).
  - Release : make_release.py fait DEUX zips : `_launcher.zip` (exe + files) et `_manuel.zip`
    (jeu/ à copier, REFramework/dinput8.dll, apworld, LISEZMOI - README.txt FR/EN, texte dans
    tools/launcher/LISEZMOI_manuel.txt).
  - NON TESTÉ EN JEU : toutes les fenêtres du mod ci-dessus, le menu de connexion, wss.
- **Options refaites + apworld FR / EN (2026-10-08, demande du joueur)** :
  - 8 options, sans dépendance entre elles : goal, difficulty, missable_checks (« Zones sans
    retour »), key_items (a_leur_place / dans_leur_zone / zone_ou_multiworld ; « partout » RETIRÉ :
    blocages vus en test), duke_shop (normale / articles_uniques / articles_et_valises), boss_rewards,
    hunting (0-100 %, 0 = pas de chasse), death_link. Retirées : trésors vendus, munitions ; pièges
    à remettre quand ils seront codés (avec le visuel).
  - Langue : `apworld/residentevilvillage/lang.py` (LANG = "fr" / "en"). Mêmes clés d'options, mêmes
    numéros ; chaque choix accepte les mots des deux langues (alias) : un YAML FR marche avec
    l'apworld EN et inversement. slot_data : valeurs fixes (au_choix/casual/..., fin_du_jeu/
    tous_les_seigneurs/..., zone_exclue/envoi_auto/cent_pourcent) + "language". VALIDÉ : seed à 3
    joueurs (défaut, mots EN, mots FR).
  - Launcher : options lues en exécutant Options.py avec de fausses classes AP
    (`options_schema.build()` -> {"fr": [...], "en": [...]}), libellés dans la langue du launcher,
    import de YAML dans l'autre langue converti.
  - Client : numéros AP calculés depuis ses données (BASE_ID + rang, comme Data.load_data) ;
    `net.get_location_id` / `net.get_item_name` (nos objets) passent par ces tables -> le mod garde
    ses noms FR en interne et marche avec une partie FR ou EN. NON TESTÉ EN JEU.
  - Reste : noms EN officiels (outil de dev « Relever les noms FR / EN » -> names_fr_en.json),
    traduction des noms dans Data.py quand LANG = "en", construction des deux .apworld.
- **apworld EN FAIT (2026-10-08)** : noms officiels relevés en jeu (outil de dev « Relever les noms
  FR / EN » -> docs/reference/names_fr_en.json : 281 objets, 75 salles, 6 plats).
  `tools/make_names_en.py` -> data/names_en.json (135 objets, 609 checks, 9 régions ; échoue si un
  nom manque ou est en double). Data.py traduit au chargement si LANG = "en" (T / R / L) ; noms écrits
  en dur dans __init__ passés par T(). `install.py --lang en` / `install_apworld_to(target, lang)`
  réécrit lang.py dans le paquet. VALIDÉ : seed EN à 3 joueurs (mêmes nombres de checks qu'en FR,
  YAML aux mots FR accepté). Release : files/apworld/fr|en/ ; launcher : choix « Langue de
  l'apworld » (écran Installation, réglage apworld_lang), état affiche la langue installée ; zip
  manuel : apworld_FR/ et apworld_EN/.
- **Clé ailée progressive VALIDÉE en jeu (2026-10-08)** : seed seeds/test_cle_ailee (Ethan + faux
  joueur « Donneur » ; les 4 exemplaires d'Ethan placés chez le Donneur par plando, génération avec
  `--plando "bosses, items, texts, connections"` et Ethan en zone_ou_multiworld : en
  dans_leur_zone les clés sont local_items et le plando est ignoré). Envoi une par une :
  `python tools/send_check.py --port 38282 --slot Donneur "<check du Donneur>"` (liste dans
  seeds/test_cle_ailee/checks_donneur.json). Bug trouvé et corrigé : l'ancien niveau restait dans
  l'inventaire ; reduceItem ne retire PAS un objet clé -> removeItem(work, true) sur l'objet trouvé
  dans Inventory.get_items. Journal « clé progressive : quantités juste après / 3 s après ».
  Résultat : 1=1 -> 2 (1 retiré) -> 3 (2 retiré) -> 4 (3 retiré), aussi après rechargement.
  Remarque : l'administration à distance du serveur (!admin /send) est désactivée par host.yaml
  (server_password null, embarqué dans la seed) ; la console du serveur ne lit pas un tuyau.
  tools/admin_send.py et tools/server_console.py gardés mais inutilisables tels quels.
- **À faire pour la V1** : world_version « 0.0.1-dev » refusé par Archipelago 0.7 (manifeste
  invalide) -> vrai numéro (1.0.0).
- **apworld EN VALIDÉ EN JEU (2026-10-08)** : seed seeds/test_en (apworld EN, Ethan + Donneur,
  objets clés à leur place -> 503 checks). Le mod retrouve 503 / 503 checks par numéro ; check
  ramassé (« Castle Dimitrescu - Gunpowder #028 [S01] ») arrivé ; objet reçu du Donneur (« Sniper
  Rifle Ammo » côté serveur -> « Munitions de fusil sniper » donné) ; achat chez le Duc (« Duke's
  Shop - Duke - Recipe: Mines ») envoyé. Mes objets affichés en français, ceux des autres avec le
  nom du serveur (anglais en partie EN).
- **À améliorer** : un objet reçu pendant l'animation de ramassage est refusé (« pas_pret ») 10 fois
  en 2,5 s puis part au colis (donné 30 s plus tard). Attendre la fin de l'animation plutôt que
  compter les refus.
  CORRIGÉ (2026-10-08) : « pas_pret » réessayé jusqu'à 20 s avant le colis (les autres refus : 10 essais) ; « don : » écrit une fois. Non testé en jeu.
- **Menu en jeu du mod RE4 (référence, 2026-10-08)** : captures dans docs/reference/re4_menu/ (fenêtre
  « Archipelago RE4R » : The Checklist, Guidance, Hints, Something's Wrong, Server, Message Log,
  Customize ; bandeau en haut à droite « Leon | Chapter 7 | Dungeons | 2/5 Checked », « AP: Connected
  (slot) », « Progression Item Nearby » ; marqueur dans le monde « [AP] [Ch7] 7m | Dungeons |
  "Shotgun Shells x3" » (blanc ; rose avec « [Hint] » devant si le check a été hinté par n'importe quel
  joueur)). Code source : C:\Users\jmboe\Downloads\Archi RE4\assets\Lua\ArchipelagoRE4R\ui_*.lua.
- **Menu en jeu, étapes 1 et 2 VALIDÉES (2026-10-08)** :
  - `shop_ui.hud` : bandeau en haut à droite (« Ethan | zone | salle | x / y checks », « AP : connecté
    (slot) », « Objet de progression à proximité » en or) + messages ; marqueurs draw.world_text
    « [AP] 7m | salle » au-dessus des checks pas faits (distance 5-60 m, détail 1-3, autres chapitres
    en gris, [Hint] rose prévu). Salles qui ne sont qu'un numéro d'étage affichées en clair
    (Rez-de-chaussée / 1er étage / Sous-sol 3B ; EN 1F / 2F / MB3). Réglages : hud_prefs.json.
  - `shop_ui.menu` : fenêtre « RE Village Archipelago » (menu Inser ouvert), thème doré, onglets en
    boutons : Checks (zones repliables, salles sur 2 colonnes, checks manquants), Guidage, Connexion.
    Listes calculées 1 fois/s dans la boucle du jeu. Le menu REFramework ne garde que « Afficher la
    fenêtre du mod », l'état, le colis et les outils de dev.
  - LIMITE LUA : le fichier principal était à 200 variables locales (refusé en jeu). 14 constantes
    rangées dans la table K (187 locales) ; check_lua.py garde une marge de 4. Tout nouveau code :
    fonctions dans shop_ui.*, jamais de nouvelle locale au niveau du fichier ni de bloc do...end.
  - Reste (étape 3) : onglets Hints, Journal, Dépannage (forcer un check), Personnaliser.
- **Menu en jeu étape 3 VALIDÉE (2026-10-08)** : onglets Hints (points, achat « !hint » via le nom
  serveur de l'objet, liste _read_hints, checks hintés -> marqueurs roses [Hint]), Journal (PrintJSON
  rendu en texte par la DLL, 300 lignes, ligne de commande -> Say), Aide (redonner les objets reçus,
  réparer la mallette, valider un check à moins de 10 m avec confirmation, Release / Collect, rapport
  de bug), Personnaliser (couleur principale et barres, préréglages). net.lua : set_print_json_handler,
  retrieved / set_reply (_read_hints_<équipe>_<slot>), say, hint_points, server_item_name,
  get_location_name. Appels à la DLL seulement dans la boucle du jeu (shop_ui.hints.refresh).
  « boucle jeu » écrit au journal seulement en mode dev.
- **Pièges (à faire, idées du joueur, 2026-10-08)** : Faillite (-1000 Lei), Screamer (cri de Bela +
  flash rouge), Armes bloquées (15 s), Dégâts (-30 % de la vie, jamais mortel), Chargeur vidé (arme
  en main). Rire de Dimitrescu à la réception. Option apworld « Pièges (%) » + poids par piège.
- **Seed de test des pièges (2026-10-08)** : seeds/test_pieges (38282), les 5 pièges d'Ethan au début du château (liste dans seeds/test_pieges/pieges.json, plando). Boutons de test sans serveur : outils de dev > « Tester un piège ».
- **Pièges VALIDÉS en jeu (2026-10-08)** : Faillite, Screamer, Armes bloquées, Dégâts (boutons de test
  des outils de dev) et piège ramassé dans le monde (seed test_pieges). Bugs corrigés : apply_item
  appelait shop_ui avant sa déclaration (-> K.traps, K déclaré en haut du fichier) ; chargeur vidé :
  InstanceWork.isUsing jamais vrai -> arme en main par get_equipped_weapon_id() (EquipController capturé),
  balles chargées = IncludeStackSize de sa fiche (5 -> 0 validé, munitions infinies du jeu comprises).
  apworld : 5 objets « Piège : … » (type Trap, à la fin d'items.json, numéros inchangés), options
  trap_chance (%) + trap_*_weight (0-10) ; objets de remplissage remplacés à la génération.
- **ALPHA 0.9.0 PUBLIÉE (2026-10-08)** : dépôt https://github.com/Snokay/Archipelago-RE-Village (branche
  main ; .gitignore : pas de fichiers du jeu, sons extraits, seeds, builds, clone RE7, Blender/ffmpeg).
  Release pré-version v0.9.0-alpha avec _launcher.zip et _manuel.zip. README (joueurs, FR/EN) avec lien
  vers SETUP_GUIDE.md. Version : archipelago.json world_version, __init__.apworld_release_version,
  K.MOD_VERSION du client (les trois à changer ensemble). Release faite par l'API GitHub (pas de gh).
  Rapport de bug : bouton en jeu (Aide > bug_report.json) + launcher (autres_mods.txt, re2_fw_config,
  réglages du launcher).
- **0.9.1 (2026-10-08, correctif urgent)** : (1) couteau de départ disparu -> porte impossible à ouvrir,
  partie bloquée. GM 79 #012 [S00] (Chapter2_6, même endroit) était touché au 1er passage : l'échange
  arme/Lei est décidé au CHARGEMENT de la scène, avant la lecture du chapitre (shop_ui.chapter nil), donc
  l'exclusion KNIFE_SPOT (chapitre 2_1) ne s'appliquait pas. Désormais cet emplacement n'est touché
  (habillage, ramassage, échange) QUE pendant son propre chapitre, jamais tant que le chapitre est
  inconnu. NON TESTÉ en jeu (nouvelle partie). (2) Xbox Game Pass : « Jouer » lançait steam:// (rien
  ne se passait). Launcher : jeu trouvé aussi dans <lecteur>:\XboxGames\…\Content ; hors Steam, la
  connexion est notée et le joueur lance le jeu lui-même. REFramework sur Game Pass : non vérifié.
  README / SETUP_GUIDE : anglais d'abord, puis français.
- **Couteau de départ : VRAIE cause trouvée et VALIDÉE (2026-10-08, 0.9.1 republiée)** : hook
  InventoryManager.hasHistory (shop_ui.world.install_history_hook) répondait « déjà eu » pour TOUT objet
  à moins de 2,5 m d'un emplacement AP (pour éviter les présentations). Le jeu s'en sert aussi pour
  savoir si un objet unique doit apparaître : à côté de la boîte « Remède de premiers soins #004 [S00] »
  (First Aid Med #004), le couteau (2292458104) était déclaré déjà eu et disparaissait. Désormais seuls
  les objets de l'emplacement proche (objet d'origine, variantes, PICKUP_ID) sont concernés
  (shop_ui.world.near_ids). Sécurité en plus : aucun emplacement d'un autre chapitre touché tant que le
  joueur n'a pas le couteau (shop_ui.has_knife). L'exclusion KNIFE_SPOT de GM 79 #012 reste (inutile
  mais sans effet gênant). Validé en jeu sur une nouvelle partie.
- **0.9.1.1 (2026-10-08)** : version du mod / de la release dans le fichier `VERSION` (4 chiffres
  possibles, lu par make_release.py -> version.json du launcher) ; l'apworld garde son world_version
  X.Y.Z (0.9.1, inchangé). Correctifs : (1) armes posées (M1897 #001) : ramassage cassé (mode de
  ramassage changé + objet modifié) puis fusil disparu (hasHistory forcé) -> armes habillées mais
  ramassage jamais touché, hasHistory jamais forcé pour une arme ou un objet clé, logo d'au moins
  0,45 m sur une arme ; validé sur « M1897 » (2e fusil). (2) Fragments de cristal accumulés (un par
  ramassage AP) : reduceItem « ok » sans effet -> vérification et retrait direct dans les piles
  (shop_ui.inv_take) ; bouton des outils de dev « Retirer tous les Fragments de cristal ». Habillage
  des armes et retrait des Fragments NON TESTÉS en jeu au moment de la publication.
- **Launcher : mise à jour automatique (2026-10-08, demande du joueur)** : au démarrage, lecture des
  releases GitHub (pré-versions comprises, `core.check_update`) ; plus récente que files/version.json
  -> bandeau « Nouvelle version disponible » (Accueil et Installation) + « Mettre à jour » :
  téléchargement du _launcher.zip, remplacement du dossier files, installation du mod dans le jeu si
  déjà installé, exe du launcher remplacé après sa fermeture par un script (swap.bat dans
  %APPDATA%\RE Village Archipelago\update) puis relancé. Testé : recherche + téléchargement +
  remplacement + installation (faux dossier de jeu). À tester : remplacement de l'exe et redémarrage
  (exe compilé, jeu fermé). Les launchers 0.9.1.1 et avant n'ont pas cette fonction (dernier
  téléchargement manuel).
- **Screamer plus fort (2026-10-08, demande du joueur)** : make_ap_sound.py, VOLUME_DB = {ap_trap_scream: +12 dB} -> propriété Volume (id 0) ajoutée à l'objet Sound (liste de propriétés vide, réglages de l'actor-mixer du jingle). Banque régénérée ; déclencheurs inchangés. À valider en jeu (installation jeu fermé : pak).
- **0.9.1.2 (2026-10-08)** : launcher avec mise à jour automatique, screamer +12 dB, + correctifs 0.9.1.1. Bandeau de mise à jour vérifié sur l'exe compilé (copie réglée en 0.9.1 -> propose 0.9.1.1) ; refus propre si le jeu est lancé. Remplacement de l'exe + redémarrage : pas encore vu en vrai.
- **Pièges plafonnés (2026-10-08, demande du joueur)** : trap_chance 0-15 % (était 0-100, plus de 300 pièges possibles) ; au maximum ~67 pièges (génération à 15 % : 67 sur 528 checks). Description FR/EN : les objets importants ne sont jamais remplacés, chaque piège = une munition ou une ressource en moins. apworld modifié -> world_version à monter (0.9.2) à la prochaine publication ; un YAML au-dessus de 15 est refusé par la génération.
- **Pièges : nombre fixe, 20 au maximum (2026-10-08, demande du joueur : « ça peut ruiner l'archipelago »)** : option trap_count (0-20, défaut 0) à la place de trap_chance (%) ; la génération tire trap_count objets de remplissage au hasard (random.sample) et les remplace selon les poids. Validé : 20 pièges exactement. Clé YAML changée (trap_chance -> trap_count) : un ancien YAML avec trap_chance est ignoré / signalé par Archipelago. apworld à publier en 0.9.2.
- **0.9.1.3 publiée (2026-10-08)** : mod 0.9.1.3, apworld 0.9.2 (pièges : trap_count 0-20).
- **Fusil à pompe : emplacements jumeaux liés (2026-10-08, rapport du joueur)** : le jeu pose deux exemplaires du M1897 (« M1897 #001 », table du village, Chapter2_1 ; « M1897 », près de la première sauvegarde, Chapter2_6, échangé contre des Lei si on a déjà le fusil). C'étaient deux checks indépendants : après en avoir pris un, le guidage montrait encore l'autre (impossible à prendre si le premier avait disparu). Client : `K.TWINS` / `K.twin_ids` (rempli par cache_location_ids) ; send_pending_checks envoie aussi la jumelle ; mark_checked rattrape à la connexion une jumelle restée seule (anciennes parties). Seule paire d'armes en double dans locations.json. apworld inchangé. Mod 0.9.1.4.
- **Fragments de cristal : +13 hors emplacement (2026-10-08, rapport du joueur, château)** : le retrait après un check marchait (journal « 1 retiré(s) », quantité revenue), mais des ramassages de Fragment SANS emplacement (« placement trouvé = false », « location = nil ») en ajoutaient 13 d'un coup (2 -> 15 -> 28 -> 41 -> 54). Objet de ramassage du mod (PICKUP_ID) réutilisé par le jeu avec la pile d'un autre objet (cause exacte non vue : la pile est maintenant écrite au journal). Correctif : tout Fragment de cristal ramassé hors emplacement est retiré en entier (tous les vrais Fragments sont des checks). Mod 0.9.1.4.
- **0.9.1.4 publiée (2026-10-08)** : fusils à pompe jumeaux liés, Fragments hors emplacement retirés. apworld inchangé (0.9.2).
- **Objet clé perdu après rechargement (2026-10-09, rapport du joueur : Sanguis Virginis)** : cause = la sauvegarde automatique faite pendant un chargement (StartSave(-1)/(0) avant le traitement du chargement) notait l'index du mod (41) alors que la mallette était celle de la sauvegarde chargée (38) ; au chargement suivant de cette sauvegarde, les objets 39-41 étaient crus présents. Correctif : `save_sync.snapshot` prend l'index de la sauvegarde en cours de chargement tant que le chargement n'est pas traité. Nouveau bouton Aide « Redonner les objets clés manquants » (`save_sync.give_missing_keys` : objets clés reçus, hors clés progressives, absents de la mallette ; un objet clé déjà utilisé revient aussi).
- **Mur de la salle des statues après rechargement (2026-10-09, rapport du joueur)** : le mur anti-blocage (vin à poser) se fiait au check de l'énigme gardé par le serveur ; sauvegarde rechargée d'avant l'énigme -> check validé, vin pas posé, mur absent -> blocage possible. Le mur bloque maintenant aussi tant que le Sanguis Virginis est dans la mallette (le poser le retire).
- **Bouton des objets clés manquants corrigé (2026-10-09)** : les objets remis en file avaient un index <= last_applied_index et étaient jetés (« déjà donné ») ; marqués `extra` : donnés quand même, sans toucher au compteur.
- **Objets clés manquants : liste au choix (2026-10-09, retour du joueur : 5 proposés, 1 seul vraiment perdu)** : un objet clé utilisé (reliefs posés, Bague, Clé de la cour) est aussi absent de la mallette. Le bouton « Chercher les objets clés manquants » liste les absents, avec un bouton « Redonner » par objet (`save_sync.find_missing_keys` / `give_key`).
- **0.9.1.5 publiée (2026-10-09)** : sauvegarde auto pendant un chargement corrigée, bouton Aide « Chercher les objets clés manquants » (un bouton par objet), mur de la salle des statues selon le Sanguis dans la mallette. apworld inchangé (0.9.2).
- **Duc : arme-check revendue (2026-10-09, crash rapporté après la vente du V61 Custom ; idée du joueur)** : le jeu ajoute un article de rachat en plus de l'article-check -> deux articles pour la même arme reliés au même check (cause probable, pas reproduite). `shop_ui.dedupe_weapons` (après add_ap_shop_units) garde un seul article payant par arme-check de la boutique. À reproduire : V61 reçu tôt (Donneur), revendu sans acheter le check.
- **Duc : article à moitié échangé (2026-10-09, test de la revente des pièces du V61 après le crash rapporté)** : pas de crash chez nous, mais erreur « lua:4008 attempt to index a nil value » dans apply_shop_swaps : createItemCore renvoyait nil, l'article gardait le nouveau numéro (set_itemID déjà fait) avec l'ancienne fiche. Probable cause du crash du joueur. Correctif : l'article n'est modifié que si l'objet est créé ; numéro en échec écrit au journal. Même erreur déjà vue le 2026-10-08 (22:15, 00:28).
- **Duc : variante impossible à créer (2026-10-09)** : Compensateur de recul (LEMI) (2) (3725070903) refusé par createItemCore ; l'article est affiché sous une autre variante du même objet (LEMI (1), 2255157331). Validé en jeu : 9 checks, 9 échangés, plus d'erreur.
- **0.9.1.6 publiée (2026-10-09)** : boutique du Duc (article à moitié échangé, variante LEMI (2), anti-doublon arme-check). apworld inchangé (0.9.2).
- **Crash joueur chez le Duc (2026-10-09, rapport RE_Village_AP_rapport_20261009_014425)** : mallette pleine, W870 TAC au colis (« aucune case libre »), amélioration vendue pour faire de la place, puis article du colis (0 Lei) acheté -> journal coupé < 1 s après, reframework_crash.dmp : EXCEPTION_ACCESS_VIOLATION lecture 0xFFFFFFFFFFFFFFFF dans re8.exe+0x41ea5e4 (code natif, pas une méthode du dump il2cpp). Cause probable : le jeu ne refuse pas l'ajout mallette pleine (vu le 2026-10-08), arme posée sur des cases occupées. Correctif : `shop_ui.parcel_blocked` (pré-hook buyItem) refuse l'achat d'un article du colis sans case libre (getBlankSlotNo), message au joueur.
- **0.9.1.7 publiée (2026-10-09)** : colis du Duc refusé sans place dans la mallette (crash joueur). Non testé par nous ; le joueur concerné teste. apworld inchangé (0.9.2).
- **Niveau de mallette perdu au chargement (2026-10-09, rapport RE_Village_AP_rapport_20261009_125437 : objets superposés, agrandissement pas redonné, réparation sans effet, onglet Confection figé)** : Valise reçue d'Archipelago à 20:58 (45 -> 77 cases), sauvegarde 17 faite à 77 cases ; au chargement de cette sauvegarde, 45 cases alors que les objets sont rangés pour 77 (W870 TAC case 55, Bombe tuyau 46). Le don passe par `addExtendLevel` seul, sans l'objet Valise que le jeu garde après un vrai achat ; le niveau n'est enregistré nulle part dans la sauvegarde (aucun champ InventoryExtendLevel hors app.Inventory dans le dump), le jeu le recalcule au chargement (`restoreExtendLevel`, sans paramètre). La sauvegarde étant notée à l'index 75 (Valise comprise), rien n'était redonné. Correctif : niveau (champ V) noté avec chaque sauvegarde (`save_sync.snapshot`), remis au chargement puis 5 s après (`save_sync.restore_level`, ne baisse jamais) ; sans niveau noté (sauvegardes d'avant), monte au premier niveau qui contient toutes les cases occupées par les objets de la grille. Aussi au début du bouton « Réparer la mallette », dont les erreurs sont maintenant écrites au journal (rien n'était fait ni noté). À VÉRIFIER EN JEU.
- **0.9.1.8 publiée (2026-10-09)** : niveau de mallette remis au chargement (Valise reçue perdue au rechargement, objets superposés, Confection figée). Non testé par nous ; le joueur du rapport 20261009_125437 teste. apworld inchangé (0.9.2).
- **Valise reçue : objet Valise mis dans la mallette (2026-10-09, après 0.9.1.8)** : comme après un vrai achat, pour que le jeu retrouve le niveau tout seul au chargement (restoreExtendLevel, hypothèse : compte les objets Valise). createAndAddItem d'abord ; addExtendLevel seulement si le niveau n'a pas bougé (jamais deux agrandissements). Réussite = agrandissement fait OU objet ajouté (pas de redon en boucle). save_sync.restore_level (0.9.1.8) gardé en secours. VALIDÉ EN JEU (seed test_v61, 38282) : objet ajouté (0 -> 1), niveau 0 -> 1 et 45 -> 77 cases par createAndAddItem seul (pas d addExtendLevel, un seul agrandissement), sans objet superposé ; rechargement : 77 cases et objet Valise dans la sauvegarde, sans ligne « valise (chargement) » (le jeu recalcule bien le niveau d après les objets Valise) ; Duc - Valise 1 toujours proposée à 10 000.
- **0.9.1.9 publiée (2026-10-09)** : Valise reçue = objet Valise dans la mallette, agrandissement gardé par le jeu lui-même au chargement (validé en jeu). apworld inchangé (0.9.2).
- **Valises : contrôle de sécurité (2026-10-09, 2e rapport RE_Village_AP_rapport_20261009_163928, idée du joueur)** : le rapport (encore en 0.9.1.8) montre « case 55 hors de la mallette, aucun niveau ne convient » : `set_extendLevel` (setter brut) change le champ sans changer getMaxSlotCount ; `save_sync.restore_level` passe à `setExtendLevel`. Nouveau `save_sync.valise_check` (au chargement, +5 s, bouton Réparer) : Valises reçues déjà données (index <= min(index du mod, index de la sauvegarde chargée)) comparées aux objets Valise de la mallette ; celles qui manquent sont redonnées par give_item (objet + agrandissement). Si un redon agrandit sans ajouter l'objet : `state.valise_no_item`, contrôle coupé pour la seed (pas d'agrandissement à chaque chargement). Outil de dev « TEST : retirer l'objet Valise (niveau gardé) » pour reproduire. Le bouton « Réparer la mallette » renvoie « Invoke threw an exception » dans le déplacement des objets (cause non cherchée). Le joueur avait cliqué « Redonner tous les objets reçus » à 12:50 (index du mod 35 contre 75 pour sa sauvegarde) : objets en double attendus. NON TESTÉ en jeu (reproduction prévue).
- **0.9.1.10 publiée (2026-10-09)** : contrôle de sécurité des Valises, secours par setExtendLevel. Publiée sans test en jeu à la demande du joueur (le joueur du rapport teste). apworld inchangé (0.9.2).
- **Game Pass : modèle AP et logo absents (2026-10-09, rapport RE_Village_AP_rapport_20261009_200212)** : jeu Xbox (C:\XboxGames\Resident Evil Village\Content, exe F024294D.Village_1.1.0.0, module e812000 contre d110000 sur Steam, patchs officiels 001-002 seulement ; notre pak en patch_003). Script et checks OK, mais ni le pak ni les fichiers natives\ (LooseFileLoader actif) ne sont pris : objet AP invisible, icône d'origine. Diagnostic demandé : LooseFileLoader_LogAccessedFiles / LogLooseFiles = true dans re2_fw_config.txt, puis nouveau rapport.
- **Mur de la salle des statues fermé par un 2e Sanguis Virginis (2026-10-09, rapport RE_Village_AP_rapport_20261009_222228, 0.9.1.9)** : Sanguis AP ramassé (Fluide chimique #013 [S02], 21:08), vin posé et récompense prise (check Clé de la cour, 21:10), puis un 2e Sanguis (2685023068) ramassé à 21:20 dans les Appartements de Dimitrescu, sans emplacement d'objet à moins de 5 m (apparu par le jeu ; origine exacte inconnue : le Sanguis #001 d'origine était remplacé par un objet AP, drapeau de l'histoire jamais posé ?). Le mur (bloque si Sanguis dans la mallette, 0.9.1.5) restait fermé. Correctif : `state.wine_placed` mis à vrai au ramassage de la récompense de l'énigme (emplacement d'origine de la Clé de la cour), retenu par sauvegarde (snapshot `wine`, remis au chargement ; inconnu = nil -> règle d'avant) ; vin posé -> le Sanguis de la mallette ne compte plus. Bouton Aide « Le vin est déjà posé (ouvrir le mur de la salle des statues) » pour les sauvegardes d'avant. NON TESTÉ en jeu.
- **0.9.1.11 publiée (2026-10-09)** : mur de la salle des statues (2e Sanguis). apworld inchangé (0.9.2).
- **2e Sanguis Virginis retiré (2026-10-09, suite du rapport 20261009_222228)** : le seul Sanguis placé par le jeu est le seau (SpawnInfo_WitchBottleWine_001, scans du château) ; le 2e vient d'un script du jeu (origine exacte inconnue). Ramassé hors emplacement alors que le vin est posé (`state.wine_placed`) : retiré (vanilla_removals) avec un message. Bouton Aide « Le vin est déjà posé » : retire aussi le Sanguis de la mallette. NON TESTÉ en jeu.
- **Crash du jeu du développeur (2026-10-09 22:25, 0.9.1.10, vraie partie)** : EXCEPTION_ACCESS_VIOLATION dans re8.exe+0x4170da7 (code natif, aucune méthode du dump proche), pile passant par re8.exe+0x41ea389 : même zone que le crash du colis du Duc (re8.exe+0x41ea5e4, 0.9.1.7). Aucune action du mod juste avant (dernier don 22:23:45, LEMI en main 22:24:48, menus ouverts/fermés). Mallette pleine (45 cases), une trentaine d'objets donnés au chargement, plusieurs refusés -> colis. Lien avec la mallette probable mais non prouvé ; à vérifier : mallette au prochain chargement (cases en double).
- **Gel de la boutique après un achat-check (2026-10-09 22:39, partie du développeur, 0.9.1.11)** : achat-check « Duc - Canon long (V61 Custom) » (56000 Lei) -> reconstruction de la liste (process_shop_purchases : collectBuyUnits -> add_ap_shop_units) : « Exception thrown in REMethodDefinition::invoke for List<app.GUIShopBuy.BuyUnit>.Add » (accès mémoire, RCX=RDX=0), puis « setupScrollGrid : NullReferenceException » ; jeu figé (re8.exe vivant, plus d'image). Les 2 achats-checks juste avant (même chemin) étaient passés : intermittent. Hypothèse : BuyUnit / ItemCore créés par le mod libérés par le moteur avant l'ajout. Correctif : add_ref sur l'article et l'ItemCore créés ; `shop_ui.clean_units` retire les entrées vides de la liste à la fin d'add_ap_shop_units et avant setupScrollGrid. NON TESTÉ en jeu (non reproductible à la demande).
- **Colis : plus de redon automatique hors objets clés (2026-10-09, crash de 22:25, idée du joueur)** : le colis réessayait son 1er objet toutes les 10 s (Viande de qualité à ce moment-là), sans rien noter quand le jeu refusait ; un essai était dû vers 22:25:03-08, pendant la combinaison Collier incomplet + Rubis sang de pigeon (crash 22:25:08). Non prouvé, mais invisible dans le journal. Correctif : `process_parcel` ne redonne plus que les objets clés (type Key : pas de case, peuvent bloquer, pas de Duc partout) ; tout le reste se récupère chez le Duc (article à 0 Lei, refusé sans place : shop_ui.parcel_blocked). Chaque essai noté AVANT le don (« colis : essai X »). Messages du colis mis à jour (« à récupérer chez le Duc »). À surveiller aussi : inventory_repair.run (toutes les 5 s, isOverlap sur chaque objet) pendant une combinaison.
- **Launcher : REFramework d'une autre version remplacé (2026-10-09, rapport RE_Village_AP_rapport_20261009_214923)** : joueur Steam (même jeu, mêmes paks) figé sur un écran noir à chaque lancement ; le mod chargé (« Chargé : 608 locations ») puis plus rien, aucun debug_log. Il avait REFramework v1.5.9.1 + 503 commits (05/09/2026), gardé par l'installation (« REFramework already present: kept ») ; le nôtre : v1.5.9 + 7 (05/03/2025). Avec notre dinput8.dll, le jeu démarre (test du joueur). Correctif : `ensure_reframework` (installation) met un REFramework différent du nôtre (comparé par SHA-256) de côté sous `dinput8.dll.avant_archipelago` et pose le nôtre ; `check_reframework` fait de même avant « Jouer » (la mise à jour automatique installe avec le code de l'ANCIEN launcher) ; la désinstallation remet la copie. Testé hors jeu (faux dossier : installation, réinstallation, Jouer, désinstallation). Les erreurs « IntegrityCheckBypass: Could not find sussy_... » apparaissent aussi avec notre version : normales.
- **0.9.1.12 publiée (2026-10-09)** : Sanguis en double retiré, gel de la boutique après un achat-check, colis récupéré chez le Duc (redon automatique seulement pour les objets clés), launcher : REFramework d'une autre version remplacé par le nôtre. Non testé en jeu. apworld inchangé (0.9.2).
- **Objets sortis de la mallette (2026-10-09, partie du développeur, 0.9.1.12)** : en déplaçant un objet sur un autre (pas de place), le jeu a sorti un Remède de la grille (`1429493426x1@-1/-1/5`), puis un autre objet peu après ; aucune action du mod au journal. Cause probable : mallette trop pleine à cause des dons. give_item laissait passer un objet dès qu'une pile du même objet existait (même pleine, ou objet non empilable comme le Remède : 1 par case). Correctif : `K.MAX_STACK` (tailles maximales des piles du catalogue, munitions / soins / armes) ; don refusé (colis) si ni case libre ni assez de place dans les piles de la grille. `inventory_repair.run` (toutes les 5 s en jeu) replace aussi un soin ou une arme en case -1 (case libre, sinon colis chez le Duc). Munitions en case -1 = balles CHARGÉES dans l'arme (vu dans toutes les parties : 10, 9 après un tir, 16 avec le chargeur grande capacité) : jamais touchées, ni par la réparation automatique ni par le bouton « Réparer la mallette » (qui les traitait comme objets à replacer). NON TESTÉ en jeu.
- **« Piège ! Screamer ! » affiché en touchant un mur (2026-10-09)** : le mur prolongeait la fenêtre centrale de 4 s même fermée -> réaffichage de son dernier contenu (le piège). Prolongée seulement si encore affichée.
- **Gel au démarrage causé par un trainer (2026-10-09, même joueur que le REFramework récent)** : après passage à notre REFramework, le jeu gelait juste après le chargement du mod, puis REFramework désactivait le script. Cause : `reframework\plugins\re8_trainer.dll` (trainer de juillet 2023) ; retiré, le jeu démarre (confirmé par le joueur). Launcher : `other_mods` (plugins .dll de reframework\plugins et scripts Lua qui ne sont pas les nôtres) affichés dans l'état de l'installation (ligne « Autres mods », avertissement) et notés au journal avant « Jouer » ; le rapport de bug (autres_mods.txt) liste aussi les plugins REFramework et le dossier natives (fichiers séparés, ex. Fluffy Mod Manager).
- **0.9.1.13 publiée (2026-10-09)** : dons refusés sans place réelle dans les piles, soins/armes sortis de la grille replacés ou mis au colis, munitions chargées jamais touchées ; mur sans réaffichage du dernier piège ; launcher : autres mods REFramework signalés, rapport avec plugins et natives. Non testé en jeu. apworld inchangé (0.9.2).
- **Onglet Checks vide dans le prologue (2026-10-09, retour d'un joueur)** : « Connecte-toi à une partie Archipelago pour voir tes checks » alors que l'onglet Connexion disait connecté. Le prologue (Chapter1, aucun check) n'a pas de mallette -> is_in_game() faux -> la boucle du jeu s'arrêtait avant shop_ui.menu.refresh. Correctif : refresh appelé avant le test is_in_game (ne dépend que du serveur). NON TESTÉ en jeu.
- **0.9.1.14 publiée (2026-10-09)** : onglet Checks rempli même hors jeu (prologue sans mallette). Non testé en jeu. apworld inchangé (0.9.2).
- **Colis : quantité incomplète chez le Duc (2026-10-09, retour du joueur : 1 balle au lieu de 25)** : le jeu vend les munitions à l'unité (boutique d'origine : pile 1, quantité choisie au moment de l'achat) et ignore la pile de notre article à 0 Lei ; le colis était ensuite retiré en entier. Correctif : à l'achat d'un article du colis (quantité > 1), quantité notée ; 1 s après, ce que le jeu a donné est mesuré une fois et le reste est donné par le mod (`K.parcel_topup`, give_item avec vérification de place ; sinon message et nouvel essai toutes les 5 s). Deux articles identiques au colis (deux envois distincts) : le 2e réapparaît après l'achat du 1er (normal). NON TESTÉ en jeu.
- **2e colis identique impossible à acheter (2026-10-09, retour du joueur)** : après l'achat du 1er article du colis (stock 1 -> 0), le 2e colis du même objet ne créait pas de nouvel article (shop_has_unit trouvait l'article à 0 Lei déjà acheté) : article affiché à stock 0, impossible à acheter. Correctif (add_ap_shop_units) : article à 0 Lei de cet objet remis à 1 en stock tant que le colis en contient encore. NON TESTÉ en jeu.
- **0.9.1.15 publiée (2026-10-09)** : colis du Duc (quantité complétée par le mod, 2e colis identique achetable). Non testé en jeu. apworld inchangé (0.9.2).
- **Crash du jeu après le don d'une formule déjà possédée (2026-10-09 23:49, partie du développeur, 0.9.1.15)** : crash 11 ms après « don : Formule : Munitions de fusil sniper » ; pile : app.InventoryManager.doUpdate -> app.Inventory.updateOrder (+0x2b9) -> re8.exe+0x4151c23 (natif). La mallette contenait déjà 2 exemplaires de cette formule (3131688569, rapport de 23:12 ; doublons dus aux redons après rechargement). Une recette est unique dans le jeu de base. Correctif : apply_item ne redonne jamais une formule (nom « Formule ... ») déjà dans la mallette (comptée donnée) ; inventory_repair.run retire les formules en double (une gardée). Pistes liées : crash du 2026-10-08 9 ms après le don d'une Coupe de Cesare ; crash 22:25 (combinaison). NON TESTÉ en jeu.
- **Ascenseur de Beneviento infini (2026-10-09, joueur Game Pass, CONFIRMÉ)** : pas de fantôme de Mia dans la cour, ascenseur sans fin. Cause : Manivelle de cric reçue d'Archipelago et utilisée, mais le check de son emplacement d'origine (« Manivelle de cric #001 [S02] », Chapter2_6, 79.97 -36.1 135.4) jamais pris ; le prendre lance la scène scriptée du lycan sur le tracteur (passage sous le tracteur), puis Beneviento démarre (vérifié par le joueur). Correctif : murs d'histoire actifs dans tous les modes (always) : « Tracteur (Manivelle de cric) » (exige ce check) et « Ascenseur de Beneviento » (exige la Manivelle, « Volant de puits #001 [S00] » et « Clé à quatre ailes #004 [S00] », par précaution, choix du joueur). Fait = ramassé DANS CETTE SAUVEGARDE (`state.story`, retenu par sauvegarde dans le snapshot, remis au chargement ; sauvegarde inconnue : état du serveur ; emplacement pas mélangé : ne compte pas). `K.story_mark` au ramassage. POSITIONS À RELEVER en jeu (outils de dev > sorties, endroits « Tracteur (Manivelle de cric) » et « Ascenseur de Beneviento ») : sans position, pas de mur. NON TESTÉ en jeu.
- **Soin sorti de la grille pendant un déplacement (2026-10-09 ~00:20, partie du développeur)** : en promenant un objet dans la mallette (sans le poser), le soin survolé est sorti de la grille ; aucune ligne au journal ; puis onglet Confection figé (objet hors grille). Cause probable (hypothèse du joueur) : inventory_repair tournait menu ouvert (is_in_game vrai), voyait l'objet tenu « sur » le soin (isOverlap), mettait le soin en case -1 pour le replacer, puis une erreur (getBlankSlotNo / removeItem) interrompait toute la boucle sans log. Correctif : `K.case_busy()` (GUIManager.isShowingGUIInventory / isShowingGUIShop) : ni réparation, ni don, ni colis, ni complément de colis pendant que la mallette ou la boutique est affichée ; réparation objet par objet (pcall par objet), objet remis à sa case d'origine en cas d'erreur, erreur notée au journal. NON TESTÉ en jeu.
- **Ordre de l'histoire avant Beneviento (rappel du joueur, 2026-10-09)** : Manivelle de cric + Volant de puits -> Clé ailée 2 (Clé à quatre ailes) -> cinématique du Duc -> maison Beneviento ; une étape ratée = maison jamais lancée. Message du mur de l'ascenseur mis à jour avec cet ordre.
- **0.9.1.16 publiée (2026-10-10)** : formules jamais redonnées en double (crash), rien de donné ni réparé mallette/boutique ouverte + réparation objet par objet, murs d'histoire Tracteur / Ascenseur de Beneviento (positions à relever : inactifs d'ici là). Non testé en jeu. apworld inchangé (0.9.2).
- **Objets reçus pendant le prologue perdus (2026-10-10, joueurs Meduza et Fusenkai)** : « Reçu : ... » affiché dans le prologue (maison d'Ethan, Chapter1) ; le jeu y a un inventaire (is_in_game vrai) mais le remet à zéro au passage au village (Chapter2_1). Meduza : Bague avec un œil écarlate, Munitions de fusil sniper, Morceau de relief (démon), Ferraille donnés entre 18:27:46 et 18:29:42, absents de la mallette à 18:32 (4 objets). Correctif : `K.chapter` (chapitre courant, lisible avant shop_ui) ; ni la file des dons ni le colis ne donnent en Chapter1 (les objets attendent le village). Joueurs déjà touchés : objets clés via Aide > « Chercher les objets clés manquants » ; le reste (munitions, matériaux) n'est pas rattrapé automatiquement. NON TESTÉ en jeu.
- **Colis chez le Duc, suite (2026-10-10, test du développeur)** : le complément marchait mais seulement à la sortie de la boutique (voulu : rien de donné boutique ouverte) et donnait 1 de trop (mesure de départ prise après le don du jeu : « 0 donné par le jeu, 25 à compléter ») -> au moins 1 compté comme donné par le jeu, message à l'achat « le reste (N) arrive en quittant le Duc ». 2e colis identique toujours épuisé : le jeu ne reconstruit pas la liste après un achat normal (la remise en stock ne tournait qu'à collectBuyUnits) -> liste refaite 0,5 s après l'achat d'un colis quand un autre du même objet attend (`K.shop_refresh_at`). NON TESTÉ en jeu.
- **0.9.1.17 publiée (2026-10-10)** : aucun don ni colis pendant le prologue (objets perdus au passage au village) ; colis chez le Duc (complément exact, message, 2e colis identique achetable). Non testé en jeu. apworld inchangé (0.9.2).
- **Formule déjà possédée encore vendue par le Duc (2026-10-10, test du développeur)** : « Duc - Formule : Munitions de fusil sniper » (check fait, formule reçue d'Archipelago) restait en vente ; hide_done_shop_units ne masque que les objets PAS reçus ; le jeu ignore que la recette est connue (donnée par le mod). Le joueur l'a rachetée (00:36:48), puis la réparation l'a retirée comme doublon : payée pour rien. Correctif : article d'une formule déjà dans la mallette retiré de la liste du Duc, sauf si son check n'est pas encore fait (`K.is_formula`). NON TESTÉ en jeu.
- **Arme au sol impossible à ramasser mallette pleine (2026-10-10, Fusil F2 #013 [S06], test du développeur)** : « inventaire complet » alors que c'est un check ; depuis 0.9.1.1 les armes posées sont exclues de swap_pickup (le M1897 #001 cassait : mode de ramassage changé + objet modifié). Correctif : si l'arme ne tient pas dans la mallette (`shop_ui.world.weapon_fits` : getBlankSlotNo à plat et tournée), objet modifié sur place en objet d'une case (PICKUP_ID), mode de ramassage jamais changé ; avec de la place, rien ne change. VALIDÉ en jeu (2026-10-10 01:12, Fusil F2 #013 : modifié sur place, check envoyé, objet d'une case retiré).
- **Noms des checks en français pour un joueur anglais (2026-10-10, capture d'un joueur)** : l'onglet Checks (et la liste « Check bloqué » de l'Aide) affichait loc.name (données en français) ; les salles étaient traduites. Correctif : i18n.loc (nom de l'objet lu dans le jeu, dans sa langue) pour ces deux listes ; préfixe « Duc - » -> « Duke - ». L'apworld EN, lui, traduit bien (names_en.json au chargement). Reste en français : catégorie/description des objets de ce jeu dans la boutique (items.json). NON TESTÉ en jeu (jeu en anglais).
- **0.9.1.18 publiée (2026-10-10)** : formule déjà possédée plus vendue par le Duc, armes au sol ramassables mallette pleine (validé), noms des checks dans la langue du jeu (menu). Murs d'histoire toujours sans position. apworld inchangé (0.9.2).
- **Étiquettes « [AP] ... » en français pour un joueur anglais (2026-10-10, capture : « [AP] Munitions de fusil sniper »)** : pour un objet de ce jeu, l'étiquette (objet au sol, boutique, présentation, objet clé, colis) prenait le nom des données (français). Correctif : `K.ap_label` (nom lu dans le jeu, dans sa langue, via i18n.item ; objet d'un autre jeu : nom du serveur + joueur), « [Colis AP] » -> « [AP Parcel] », description des objets de ce jeu en anglais générique hors jeu français. NON TESTÉ en jeu (jeu en anglais).
- **Crashs intermittents dans Inventory.updateOrder (2026-10-10 03:24, partie du développeur)** : même signature qu'à 23:49 (re8.exe+0x4151c23 <- Inventory.updateOrder <- InventoryManager.doUpdate), mais aucun don au moment du crash (derniers dons 13 s avant, juste après le chargement ; crash en sortant de chez le Duc vers la salle des Quatre). Mallette au chargement sans anomalie visible (45 objets). Non reproduit en refaisant le même chemin. Précaution (cause non prouvée) : `K.case_busy` bloque aussi les dons 10 s après un chargement (`K.give_hold_until`) et 2 s après la fermeture de la mallette ou de la boutique. NON TESTÉ en jeu.
- **0.9.1.19 publiée (2026-10-10)** : étiquettes [AP] dans la langue du jeu (validé en anglais par le joueur), dons en pause 10 s après un chargement et 2 s après la fermeture de la mallette / boutique (précaution crashs intermittents). apworld inchangé (0.9.2).
- **Clés ailées : tous les niveaux gardés (2026-10-10, rapport du joueur)** : porte à deux ailes pas encore ouverte, Clé à quatre ailes refusée par le jeu ; le mod retirait les niveaux d'avant à chaque nouveau niveau (comme dans le jeu, où les portes s'ouvrent dans l'ordre). Correctif : plus aucun niveau retiré ; `K.progressive_fill` redonne les niveaux 1..N manquants après un don, et à chaque chargement d'après le nombre de clés reçues dans la sauvegarde (répare les parties d'avant). VALIDÉ en jeu (2026-10-10 03:53 : niveau 2 donné, niveau 1 gardé, quantités 1=1 2=1, porte à deux ailes ouverte).
- **Sécurité des clés ailées (2026-10-10, demande du joueur)** : `K.progressive_check` au chargement ET toutes les 30 s en jeu (file vide, mallette/boutique fermées, hors prologue) : autant de niveaux dans la mallette que d'exemplaires reçus et déjà donnés ; les manquants sont redonnés (jamais plus que reçus). NON TESTÉ en jeu (le don au chargement, lui, est validé).
- **0.9.1.20 publiée (2026-10-10)** : clés ailées, toutes les variantes gardées (validé), sécurité qui redonne les variantes manquantes. apworld inchangé (0.9.2).
- **Mur « Porte vers Beneviento » placé (2026-10-10)** : le joueur a relevé le mur devant la porte à quatre ailes qui mène vers Beneviento (Chapter2_6, -36.04 -33.99 92.03), d'abord par erreur dans « Maison Beneviento » (mur du mode 100 % exigeant les checks de la maison : aurait bloqué l'entrée pour toujours) et « Cachots du château » ; points retirés. Segment « Ascenseur de Beneviento » renommé « Porte vers Beneviento » (mêmes exigences : Manivelle de cric, Volant de puits, Clé à quatre ailes), rayon 3 m (1,5 m trop étroit sur les côtés). Reste : « Tracteur (Manivelle de cric) » à relever. NON TESTÉ en jeu.
- **Mur « Tracteur (Manivelle de cric) » placé (2026-10-10)** : relevé par le joueur juste avant le passage sous le tracteur (Chapter2_6, 47.45 -39.79 150.69), rayon 1,5 m. VALIDÉ en jeu : bloqué avec le message tant que le check de la Manivelle n'est pas pris, passage ouvert après l'avoir pris. Mur « Porte vers Beneviento » : message et rayon 3 m validés en jeu (ouverture après la séquence complète pas encore vue).
- **Checks de chasse farmables en rechargeant (2026-10-10, rapport du joueur)** : 2 poissons (em3090, pont Bridge_02) tués -> Poisson #1, #2 ; sauvegarde rechargée, les mêmes poissons -> #3, #4, #5 (le mod prenait le prochain check pas encore fait). Correctif : compteur PAR SAUVEGARDE (`state.hunts`, retenu dans le snapshot, remis au chargement ; sauvegarde inconnue : nombre de checks déjà faits) : la N-ième viande de ce type dans cette sauvegarde = check #N ; déjà fait = viande normale. NON TESTÉ en jeu.
- **DeathLink : noms d'ennemis ajoutés (2026-10-10)** : em1250 / em1251 = « a Moroaica » (créatures à faucille du château), em1270 = « a Samca » (créatures volantes) ; le lycan amélioré du 2_6 est em1240 (« a Lycan », déjà présent). Reste à identifier : em1230 (château, 1 tué), em1280.
