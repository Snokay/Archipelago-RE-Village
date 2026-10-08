# ItemID connus

Source principale (2026-09-25) : le scan des placements `app.Spawn.ItemSpawnInfo`. Le nom de
chaque placement contient le nom interne de l'objet (`SpawnInfo_HandGun_Bullet_001` →
`HandGun_Bullet`), ce qui permet de faire la correspondance nom ↔ ItemID sans ambiguïté.
Le scan brut est dans `scans/village_chapitre2_1_scan_20260925.json`.

Ces nombres sont des hash 32 bits d'identifiants internes. Ils sont stables et directement
utilisables avec `InventoryManager.createAndAddItem(itemID, quantité, 0, 0)` (don confirmé en
jeu le 2026-09-25 avec la poudre).

| Nom interne | Objet | ItemID |
|---|---|---|
| Knife | Couteau | 2292458104 |
| HandGunFirst | Pistolet de départ (LEMI) | 97158149 |
| ShotGunPompType | Fusil à pompe (M1897) | 2838037082 |
| GranadeLauncher | Lance-grenades | 2576167331 |
| Mine | Mine | 3213662355 |
| HandGun_Bullet | Munitions pistolet | 1179972000 |
| ShotGun_Bullet | Munitions fusil à pompe | 1731811000 |
| SniperRifleBullet | Munitions fusil de précision | 3919597625 |
| Material_GunPowder | Poudre | 3461208890 |
| Material_ChemicalLiquid | Liquide chimique | 526649991 |
| Material_ScrapA | Ferraille | 1394398957 |
| Material_Herb | Herbe | 1166469749 |
| CureMedicine | Médicament | 1429493426 |
| BaggedMoney | Sac de Lei | 3196868754 |
| Treasure_BloodStone_Small | Trésor : petite pierre de sang | 1970592906 |
| Treasure_SpinelFallByAttack | Trésor : spinelle (tombe quand on tire dessus) | 1943719610 |
| VillageChainCutter | Clé : coupe-chaîne | 1664342338 |
| VillageTrackKeyAndDriver | Clé : clé + tournevis (?) | 2328275556 |
| VillageReliefEye | Clé : relief de l'œil | 1132688171 |
| VillageReliefSword | Clé : relief de l'épée | 3619364444 |
| VillageTombStonePlate | Clé : plaque de pierre tombale | 3801239996 |

## À exclure des checks

`ItemSpawnInfo_EmDrop_*` et `ItemSpawnInfoRandomDrop_*` ont un ItemID à 0 : ce sont des
emplacements de butin d'ennemis et de drops aléatoires, pas des objets fixes.

## Comment en ajouter

Menu REFramework (touche Inser) → "RE Village Archipelago" → **Scanner la zone**, dans chaque
nouvelle zone. Le fichier `scan_<date>.json` arrive dans
`reframework/data/re_village_ap_client/`.
