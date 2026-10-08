# Cartographie des items recevables — RE Village

**Source de vérité : `apworld/residentevilvillage/data/items.json`.** Résumé ci-dessous,
vérifié par génération réelle (voir docs/README.md) : la somme des `count` (hors `Event`)
vaut exactement 54, pour matcher les 54 locations remplissables.

| Item | Type | Count | Progression ? |
|---|---|---|---|
| Cle de la Grille du Chateau | Key | 1 | oui |
| Cle de la Maison Beneviento | Key | 1 | oui |
| Cle du Reservoir | Key | 1 | oui |
| Cle de la Mine | Key | 1 | oui |
| Liasse de Lei | Money | 12 | non |
| Munitions Pistolet | Ammo | 8 | non |
| Munitions Fusil a pompe | Ammo | 6 | non |
| Munitions Magnum | Ammo | 4 | non |
| Kit de soin | Recovery | 8 | non |
| Poudre de craft | Craft | 6 | non |
| Composant d'amelioration d'arme | Useful | 3 | non |
| Costume alternatif d'Ethan | Filler | 1 | non |
| Piege - Inventaire encombre | Trap | 2 | non |
| Victory | Event | 0 (verrouillé) | oui (condition de fin) |

## Ce qu'il reste à faire pour que la réception soit réelle en jeu

Chaque nom d'item ci-dessus a une entrée correspondante dans `ITEM_EFFECTS` dans
`client/re_village_ap_client.lua`, actuellement une fonction vide. Il faut, pour chacune :

1. Identifier (via l'ObjectExplorer de REFramework) le manager du jeu qui gère cette
   ressource (inventaire, argent, clés).
2. Appeler la méthode adéquate dessus (ex: `manager:call("addItem", id, quantity)`,
   syntaxe exacte à confirmer une fois le manager identifié).
3. Piège ("Piege - Inventaire encombre") : décider de l'effet exact avant de coder quoi
   que ce soit — voir le point d'attention "Traps et items négatifs" dans
   `prompt-mods-archipelago (1).md`. Proposition de départ : ajoute un objet non-équipable
   qui prend une case d'inventaire jusqu'à être jeté manuellement (pas de perte de progression,
   juste une gêne temporaire).
