# Cartographie des checks — RE Village

**Source de vérité : `apworld/residentevilvillage/data/locations.json`** (54 checks +
1 location événement "Victory"). Ce fichier documente juste la vue d'ensemble et les
champs à remplir — ne pas dupliquer la liste ici à la main, elle dérivera du JSON.

## Répartition actuelle (générique, à remplacer par les vrais noms d'objets)

| Région | Nombre de checks | Inclut le boss ? |
|---|---|---|
| Village | 12 | non (hub) |
| Chateau Dimitrescu | 12 | oui (Alcina Dimitrescu, en dernier) |
| Maison Beneviento | 10 | oui (Donna Beneviento, en dernier) |
| Reservoir | 10 | oui (Salvatore Moreau, en dernier) |
| Usine Heisenberg | 10 | oui (Karl Heisenberg, en dernier) |
| Zone Finale | 1 (Victory, verrouillée) | — |

## Chaque entrée de `locations.json` a 3 champs à compléter en jeu

- `item_object` — l'identifiant de l'objet ramassable/déclencheur dans le moteur RE Engine.
- `parent_object` — son parent dans la hiérarchie de scène, si pertinent.
- `folder_path` — le chemin de dossier dans la hiérarchie de scène (pattern vu dans
  `residentevil2remake.apworld`, ex: `RopewayContents/World/Location_RPD/...`).

Tant que ces 3 champs valent `"TODO_A_VERIFIER_EN_JEU"`, `client/re_village_ap_client.lua`
ne peut pas détecter automatiquement le check correspondant — voir `HOOKS.install()` dans
ce fichier pour l'endroit exact où brancher la vraie détection une fois ces identifiants
connus.

## À faire ensuite

- [ ] Remplacer les noms génériques ("Objet ramasse au sol #3") par les vrais noms d'objets
      une fois identifiés (garder le nom stable après coup : il sert de clé partout, y
      compris dans `checks_to_send.jsonl`).
- [ ] Marquer les checks obligatoires vs optionnels (actuellement aucune distinction —
      voir note dans docs/README.md, section "Points d'attention transverses").
- [ ] Décider si les 4 combats de boss doivent avoir une règle d'accès en plus de la clé de
      zone (ex: nécessiter une arme minimale) — actuellement seule la clé de zone gate l'accès.
