"""
Construit un .pak de patch RE Village (KPKA v4, sans compression) avec les fichiers du mod.

Usage : python tools/re_engine/pak_build.py SORTIE.pak DOSSIER_CLIENT
  Tous les fichiers de DOSSIER_CLIENT/natives/... sont mis dans le pak, à leur chemin
  (natives/stm/...).

Pourquoi (2026-09-26) : le REFramework de RE8 (v1.5.9) sert bien les fichiers "loose" ordinaires
(maillage, matériau, planche d'icônes), mais les textures des matériaux 3D restaient en damier
"texture manquante". Le jeu charge lui-même les paks re_chunk_000.pak.patch_00N.pak qui suivent
les siens (méthode de Fluffy Mod Manager et du mod RE4R), sans passer par REFramework.

Format (le même que pak_extract.py lit) : en-tête 16 octets ("KPKA", 4, 0, options 0, nb de
fichiers, 0), puis une entrée de 48 octets par fichier (hash minuscules, hash majuscules,
position, taille stockée, taille réelle, attributs 0 = non compressé, somme 0), puis les données.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
from pak_extract import path_hash  # noqa: E402


def collect(client_dir):
    files = []
    root = os.path.join(client_dir, "natives")
    for folder, _, names in os.walk(root):
        for name in names:
            full = os.path.join(folder, name)
            rel = os.path.relpath(full, client_dir).replace(os.sep, "/")
            files.append((rel, full))
    return sorted(files)


def build(out_path, client_dir):
    files = collect(client_dir)
    header_size = 16 + 48 * len(files)
    entries, blobs, offset = [], [], header_size
    for rel, full in files:
        data = open(full, "rb").read()
        lower, upper = path_hash(rel)
        entries.append(struct.pack("<IIQQQQQ", lower, upper, offset, len(data), len(data), 0, 0))
        blobs.append(data)
        offset += len(data)
        print(f"  {rel} ({len(data)} octets)")
    with open(out_path, "wb") as f:
        f.write(struct.pack("<4sBBHII", b"KPKA", 4, 0, 0, len(files), 0))
        for entry in entries:
            f.write(entry)
        for data in blobs:
            f.write(data)
    print(f"pak : {out_path} ({len(files)} fichiers, {offset} octets)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2])
