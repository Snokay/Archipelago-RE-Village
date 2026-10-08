"""
Extrait des fichiers des .pak de RE Village (format KPKA v4 du RE Engine), sans outil externe.

Usage : python tools/re_engine/pak_extract.py SORTIE chemin1 [chemin2 ...]
  ex. : python tools/re_engine/pak_extract.py extrait natives/stm/gui/ui1110/tex/ui1110_000_im.tex.30

Les chemins viennent de RE8_STM_Release.list (liste d'Ekey, github.com/Ekey/REE.PAK.Tool).
Le pak le plus récent (patch le plus haut) gagne, comme dans le jeu.

Format (d'après REE.PAK.Tool) :
  en-tête 16 octets : "KPKA", version majeure u8, mineure u8, options u16, nb de fichiers u32,
  empreinte u32 ; puis une entrée de 48 octets par fichier : hash minuscules u32, hash majuscules
  u32, position u64, taille compressée u64, taille réelle u64, attributs u64, somme u64.
  hash = murmur3_32(chemin en UTF-16LE, graine 0xFFFFFFFF). Compression = attributs & 0xF :
  0 aucune, 1 deflate brut, 2 zstd.
"""

import glob
import os
import struct
import sys
import zlib

import mmh3
import zstandard

GAME_DIR = r"D:\Steam\steamapps\common\Resident Evil Village BIOHAZARD VILLAGE"


def path_hash(path):
    lower = mmh3.hash(path.lower().encode("utf-16-le"), 0xFFFFFFFF, signed=False)
    upper = mmh3.hash(path.upper().encode("utf-16-le"), 0xFFFFFFFF, signed=False)
    return lower, upper


def read_toc(pak_path):
    with open(pak_path, "rb") as f:
        magic, major, minor, feature, count, _ = struct.unpack("<4sBBHII", f.read(16))
        if magic != b"KPKA":
            raise ValueError(f"{pak_path} : pas un pak RE Engine")
        if feature & 8:
            raise ValueError(f"{pak_path} : table chiffrée, non gérée")
        if major != 4:
            raise ValueError(f"{pak_path} : version {major}.{minor} non gérée")
        toc = {}
        raw = f.read(48 * count)
        for i in range(count):
            lo, up, off, csize, usize, attr, _ = struct.unpack_from("<IIQQQQQ", raw, i * 48)
            toc[(lo, up)] = (off, csize, usize, attr)
        return toc


def pak_files(game_dir=GAME_DIR):
    base = os.path.join(game_dir, "re_chunk_000.pak")
    patches = sorted(glob.glob(base + ".patch_*.pak"), reverse=True)
    return patches + [base]  # du plus récent au plus ancien


def extract(paths, out_dir, game_dir=GAME_DIR):
    wanted = {path_hash(p): p for p in paths}
    found = {}
    for pak in pak_files(game_dir):
        toc = read_toc(pak)
        for key, path in wanted.items():
            if path not in found and key in toc:
                found[path] = (pak, toc[key])
    for path in paths:
        if path not in found:
            print(f"introuvable : {path}")
            continue
        pak, (off, csize, usize, attr) = found[path]
        with open(pak, "rb") as f:
            f.seek(off)
            data = f.read(csize)
        comp = attr & 0xF
        if comp == 1:
            data = zlib.decompress(data, -15)
        elif comp == 2:
            data = zstandard.ZstdDecompressor().decompress(data, max_output_size=usize)
        target = os.path.join(out_dir, path.replace("/", os.sep))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
        print(f"{path} ({usize} octets, {os.path.basename(pak)})")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    extract(sys.argv[2:], sys.argv[1])
