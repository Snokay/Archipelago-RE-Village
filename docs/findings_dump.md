# Ce qu'on a trouvé dans le dump SDK complet (2026-09-13)

## D'où ça vient

Deux passes :
1. Un premier dump ("Dump SDK") a planté (comportement connu/documenté) mais son log de
   session a quand même révélé 18 707 noms de classes (`docs/reference/app_types_from_crash_log_2026-09-13.txt`,
   voir historique de conversation).
2. Un second dump avec le bouton **"Dump il2cpp json Only"** (nécessite REFramework ≥ mars 2025,
   installé au passage) a réussi sans planter : `il2cpp_dump.json` complet, ~755 Mo, 21,5 millions
   de lignes. Ce fichier n'est PAS versionné dans le projet (trop gros) — il reste dans le dossier
   du jeu (`D:\Steam\steamapps\common\Resident Evil Village BIOHAZARD VILLAGE\il2cpp_dump.json`).
   Format : un objet JSON géant, une clé de premier niveau par classe (ex: `"app.ItemGetCore"`),
   avec ses `fields`, `methods` (nom, paramètres, type de retour), `properties`, `parent`, etc.

## LA découverte principale : comment le jeu donne réellement un objet au joueur

**`app.AddItemActionBase`** (hérite de `app.FSMActionBase`, donc un nœud d'arbre de comportement/FSM
utilisé partout dans les scènes scriptées du jeu — pas une fonction unique appelée une fois) expose :

```
addingCheckProcessingToInventory(arg: via.behaviortree.ActionArg,
                                  itemList: List<app.BaseAddItemData>,
                                  isOverwrite: bool = false) -> List<app.ItemCore>

addingCheckProcessingToKeyItem(arg: via.behaviortree.ActionArg,
                                keyItemList: List<app.BaseAddItemData>) -> List<app.ItemCore>
```

C'est LE point d'entrée générique utilisé par tout le jeu pour ajouter un ou plusieurs objets à
l'inventaire normal ou aux objets-clés. Ça sert potentiellement pour les DEUX sens :
- **Détection de check** : hooker cette méthode intercepte tout ramassage/don scripté d'objet
  n'importe où dans le jeu (le `itemList` en paramètre dit quel(s) objet(s) sont concernés).
- **Injection d'item reçu** : on peut probablement appeler nous-mêmes cette méthode (construire un
  `app.BaseAddItemData`, l'ajouter à une liste, appeler `addingCheckProcessingToInventory`) pour
  donner un item AP au joueur sans passer par un ramassage réel.

### `app.BaseAddItemData` — les champs exacts à remplir pour donner un item

| Champ | Type | Rôle |
|---|---|---|
| `itemID` | `System.String` | Identifiant de l'objet — **une chaîne, pas un nombre** (ex. probable : `"itm_xxx"`) |
| `addNum` | `System.Int32` | Quantité |
| `isOverwrite` | `bool` | Remplace le stack existant au lieu d'additionner |
| `isSetIncludeStackSize` / `includeStackSize` / `isSetMaxIncludeStackSize` | — | Gestion de stack max |
| `bulletID` | `System.String` | Sous-type de munition (si l'objet est une arme/munition) |
| `quickSlotID` | `System.UInt32` | Emplacement de raccourci à assigner |
| `isCustmizeWeapon` (faute d'origine dans le jeu) / `customUnit` | — | Cas des armes personnalisées |

Il existe aussi `get_itemIDHash() -> System.UInt32` : confirme que `itemID` (string) est hashé en
interne vers un entier — cohérent avec les IDs "decimal" vus dans les données de
`residentevil2remake.apworld` (probablement le même genre de hash appliqué à un ID string).

## ⚠️ Ce qui manque encore : la vraie liste des `itemID` (chaînes)

Le dump de types ne contient QUE la structure des classes (champs/méthodes), pas les données de
jeu elles-mêmes (les chaînes `itemID` réelles genre `"itm_handgunammo"` vivent dans des fichiers de
données du jeu, pas dans la réflexion C#). Recherché sans succès dans le dump : pas de classe
"table maître des objets" exploitable directement. Deux façons d'obtenir les vrais `itemID` :
1. **En jeu** : avec l'ObjectExplorer, inspecter une instance vivante d'`app.ItemCore` (ex: en ayant
   un objet en main ou dans l'inventaire) et lire son champ `itemID` réel.
2. Extraire les fichiers de données du jeu (`.user`/assets RE Engine) avec un outil dédié — plus
   lourd, pas nécessaire dans l'immédiat.

## Autres classes confirmées (première passe, toujours valables)

- Défaite de boss : `app.EnemyDeadCheck` / `app.EnemyDeadCheckBranch`
- Boutique du Duke (nommée en interne **"CPShop"**) : `app.GUIShopBuy`, `app.ChangeShopAssortmentAction`
- Puzzle confirmé et nommé (château) : `app.PianoPuzzle.*` (57 classes)
- Soin : `app.RecoverPlayerHPImmediately`, `app.RecoveryPlayerHealthPoint`
- Argent : `app.AddMoney` (aussi un nœud FSM, `start(arg)`, avec un champ `Parameter: app.AddMoneyParameter`)

## ✅ Détection de ramassage confirmée en jeu (2026-09-13, testé réellement)

Après plusieurs itérations de debug en conditions réelles (couteau + pistolet ramassés
plusieurs fois), la chaîne complète fonctionne :

```
sdk.find_type_definition("app.InteractItemGet"):get_method("InventoryInsertFinishItem")
```

Piégé (hook) avec succès. Détails confirmés par l'observation directe (pas une supposition) :
- La signature réelle vue par le hook a **5 arguments**, pas 2 comme le laissait penser la
  signature déclarée `(core: app.ItemCore)` dans le dump de types (probablement un paramètre
  caché lié à la convention d'appel native RE Engine).
- **`args[2]`** = `this` (l'instance `app.InteractItemGet`), pas l'item.
- **`args[3]`** = le véritable objet item, mais sous une **sous-classe concrète** de
  `app.ItemCore` (`app.WeaponMeleeCore` pour le couteau, `app.WeaponGunCore` pour le
  pistolet) — jamais littéralement `"app.ItemCore"`. Il ne faut donc jamais filtrer par nom
  de type exact, juste essayer `get_spec()` sur chaque objet managé rencontré.
- `args[3]:call("get_spec")` puis `:get_field("ItemID")` renvoie un vrai nombre.

**Résultats observés** (voir aussi `docs/reference/known_item_ids.md`, mis à jour au fur et
à mesure des tests en jeu) :

| Objet | ItemID | Classe |
|---|---|---|
| Couteau de combat | 2292458104 | app.WeaponMeleeCore |
| Pistolet de départ | 97158149 | app.WeaponGunCore |

Ces nombres sont presque certainement des **hash** (32 bits) d'identifiants string internes
(ex: `"itm_combatknife"`), pas de simples numéros de catalogue séquentiels comme les
"decimal" vus dans RE2R — mais peu importe pour nous : ils sont stables et reproductibles
(confirmé par plusieurs ramassages du même objet donnant le même nombre), donc directement
utilisables comme clé de correspondance ItemID -> nom de location AP.

Le code final (nettoyé du debug intermédiaire) est dans
`client/re_village_ap_client.lua`, fonction `HOOKS.install()`.

## Prochaine étape suggérée

Pas besoin de relancer le dump. Le plus rentable maintenant : soit (a) une courte session en jeu
pour lire un `itemID` réel via l'ObjectExplorer sur un objet tenu en main, soit (b) commencer à
écrire le vrai hook Lua sur `addingCheckProcessingToInventory`/`ToKeyItem` avec juste du `log.info`
pour dumper en clair les `itemID` observés pendant une vraie partie (la détection ET la découverte
des IDs en une seule étape, sans avoir à naviguer dans l'ObjectExplorer à la main).
