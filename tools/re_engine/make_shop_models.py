"""
Liste des objets que la boutique sait afficher d'origine (2026-09-27).

Usage : python tools/re_engine/make_shop_models.py

La boutique montre un objet grâce à son prefab "DetailSearch"
(natives/stm[/_ge]/environment/props/prefab/item/detailsearch/riNNNN_detailsearch.pfb.17).
Les objets sans ce prefab (Plante, Poudre noire, Fluide chimique, Sac de Lei...) ne
s'affichaient pas. On cherche donc dans les paks tous les riNNNN qui en ont un (la liste
d'Ekey est incomplète : on teste les 9000 numéros par leur hash) et on l'écrit dans
client/reframework/data/re_village_ap_client/shop_models.json. Le client compare avec le prefab
de l'objet (ItemSpecification.findPrefab -> ".../riNNNN/riNNNN_Inventory.pfb").
"models" donne aussi, pour chaque riNNNN, le maillage et le matériau de ce prefab (chemins sans
extension) : c'est le "vrai modèle" posé à la place des objets au sol (client, world_visuals).
"""

import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
import pak_extract  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "client", "reframework", "data", "re_village_ap_client", "shop_models.json")


def main():
    toc = set()
    for pak in pak_extract.pak_files():
        toc.update(pak_extract.read_toc(pak))
    found, paths = [], []
    for n in range(1000, 10000):
        for base in ("natives/stm", "natives/stm/_ge"):
            path = f"{base}/environment/props/prefab/item/detailsearch/ri{n}_detailsearch.pfb.17"
            if pak_extract.path_hash(path) in toc:
                found.append(f"ri{n}")
                paths.append(path)
                break
    models = {}
    with tempfile.TemporaryDirectory() as tmp:
        pak_extract.extract(paths, tmp)
        for ri, path in zip(found, paths):
            data = open(os.path.join(tmp, path), "rb").read()
            strings = [m.decode("utf-16-le") for m in re.findall(rb"(?:[\x20-\x7e]\x00){6,}", data)]
            mesh = next((x[:-5] for x in strings if x.lower().endswith(".mesh")), None)
            mdf = next((x[:-5] for x in strings if x.lower().endswith(".mdf2")), None)
            if mesh and mdf:
                models[ri] = {"mesh": mesh, "mdf": mdf}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"detailsearch": found, "models": models}, f, indent=0)
    print(f"{len(found)} objets affichables par la boutique -> {OUT}")


if __name__ == "__main__":
    main()
