"""
Écrit une texture .tex.30 de RE Village NON compressée (RGBA8), avec sa chaîne de mips.

En-tête relevé le 2026-09-26 sur les textures du flacon (it04_000_AntisepticSolution_Medium) :
  0x00 "TEX\\0" | 0x04 version 30 | 0x08 largeur u16 | 0x0A hauteur u16 | 0x0C profondeur u16
  0x0E nb d'images u8 | 0x0F nb de mips << 4 | 0x10 format DXGI u32 | 0x14 -1 | 0x18..0x27 octets
  repris du modèle | 0x28 table des mips : position u64, pas (octets par ligne) u32, taille u32.
Les données suivent la table (0x28 + 16 x mips).
"""

import struct

from PIL import Image

FORMAT_RGBA8_UNORM = 28
FORMAT_RGBA8_SRGB = 29


def write_tex(path, image, template_header, srgb, mip_levels=1):
    """template_header : en-tête d'une texture qui se charge. Test en jeu du 2026-09-26 : avec
    l'en-tête des textures du flacon (octets 0x18..0x27 liés au streaming) et 11 mips, le moteur
    affichait son damier "texture manquante". L'en-tête de la planche d'icônes (1 mip), qui se
    charge, est donc à utiliser, avec mip_levels=1."""
    image = image.convert("RGBA")
    width, height = image.size
    mips = []
    level = image
    while len(mips) < mip_levels:
        mips.append(level)
        if level.width == 1 and level.height == 1:
            break
        level = level.resize((max(1, level.width // 2), max(1, level.height // 2)), Image.LANCZOS)
    header = bytearray(0x28 + 16 * len(mips))
    header[0:0x28] = template_header[0:0x28]
    struct.pack_into("<4sIHHHBB", header, 0, b"TEX\0", 30, width, height, 1, 1, len(mips) << 4)
    struct.pack_into("<Ii", header, 0x10, FORMAT_RGBA8_SRGB if srgb else FORMAT_RGBA8_UNORM, -1)
    offset = len(header)
    blobs = []
    for i, mip in enumerate(mips):
        data = mip.tobytes("raw", "RGBA")
        struct.pack_into("<QII", header, 0x28 + 16 * i, offset, mip.width * 4, len(data))
        offset += len(data)
        blobs.append(data)
    with open(path, "wb") as f:
        f.write(bytes(header))
        for data in blobs:
            f.write(data)
    return len(mips)


# Textures compressées (2026-09-26) : les matériaux 3D affichaient le damier "texture manquante"
# avec nos textures non compressées. On reproduit donc exactement les textures du flacon :
# même en-tête (octets de réglage 0x18..0x27 compris), même taille, même nombre de mips, format
# BC7 (98 / 99 sRGB) ou BC1 (71). Encodage : etcpak (entrée RGBA).
BC_FORMATS = {71: ("bc1", 8), 72: ("bc1", 8), 98: ("bc7", 16), 99: ("bc7", 16)}


def write_bc_tex(path, image, template):
    import etcpak
    width, height = struct.unpack_from("<HH", template, 8)
    mip_count = template[15] >> 4
    fmt = struct.unpack_from("<I", template, 16)[0]
    codec, block_bytes = BC_FORMATS[fmt]
    image = image.convert("RGBA").resize((width, height), Image.LANCZOS)
    header = bytearray(0x28 + 16 * mip_count)
    header[0:0x28] = template[0:0x28]
    offset = len(header)
    blobs = []
    for i in range(mip_count):
        w, h = max(1, width >> i), max(1, height >> i)
        mip = image.resize((w, h), Image.LANCZOS).tobytes("raw", "RGBA")
        data = etcpak.compress_bc1(mip, w, h) if codec == "bc1" else etcpak.compress_bc7(mip, w, h, None)
        struct.pack_into("<QII", header, 0x28 + 16 * i, offset, max(1, (w + 3) // 4) * block_bytes, len(data))
        offset += len(data)
        blobs.append(data)
    with open(path, "wb") as f:
        f.write(bytes(header))
        for data in blobs:
            f.write(data)
    return width, height, mip_count, fmt
