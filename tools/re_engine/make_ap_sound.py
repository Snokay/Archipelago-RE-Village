"""
Ajoute des sons Archipelago à la banque de sons SYSTÈME de RE Village (jouable partout par
app.WwiseManagerApp.trigger(id)), sans remplacer aucun son du jeu.

Usage : python tools/re_engine/make_ap_sound.py

Pourquoi (2026-10-07) : la phrase de Daniela (« ça fait longtemps que je n'ai pas disséqué un
homme » + rire, trigger 2490342862) ne joue que si Daniela est dans la scène (sa banque de voix).
REFramework interdit de lancer un lecteur externe (os.execute absent). Aucun son système n'est
libre (system.wel : états / RTPC, et 2 jingles utilisés). On AJOUTE donc nos propres objets.

Étapes :
  1. extrait du pak system.bnk.2.x64 et system.wel.11 (pak_extract) ;
  2. system.bnk (Wwise v135) : pour chaque voix de VOICES et chaque langue, copie la chaîne du jingle trésor
     (Event 524142899 -> Action Play 969562946 -> Sound 977466270, fils de l'actor-mixer
     356891578) avec de NOUVEAUX ID (FNV-1 32 bits du nom, comme Wwise), source = le .wem fourni,
     embarqué (DIDX + DATA, alignement 16) ; le nouveau Sound est ajouté aux enfants de
     l'actor-mixer (même bus / volume que le jingle) ;
  3. system.wel : une entrée de 62 octets (copie de celle du jingle) par son : trigger neuf ->
     event neuf ; entrées triées par trigger, nombre à 0x200 ;
  4. écrit les deux fichiers dans client/natives/stm/... (installés par tools/install.py, aussi
     dans le pak de patch).
Les .wem sont pris dans les fichiers du jeu (Wwise Vorbis, une copie par langue).
"""

import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
import pak_extract  # noqa: E402
from pak_extract import extract  # noqa: E402

# Toujours partir des fichiers D'ORIGINE : notre pak de patch (installé par tools/install.py)
# contient déjà un system.bnk modifié.
MOD_PAK = "re_chunk_000.pak.patch_014.pak"
_pak_files = pak_extract.pak_files
pak_extract.pak_files = lambda *a, **k: [p for p in _pak_files(*a, **k) if not p.endswith(MOD_PAK)]

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BNK_PATH = "natives/stm/sound/wwise/system.bnk.2.x64"
WEL_PATH = "natives/stm/sound/sound_asset/snd_eventlist/system/system.wel.11"

# Voix du jeu reprises (2026-10-07) : nom -> (banque de voix, event Wwise). Les voix existent en
# 9 langues (remarque du joueur : un jeu en anglais doit entendre l'anglais) : un son par langue,
# nommé <nom>_<langue>, trigger = fnv1(<nom>_<langue>) ; le client choisit selon la langue des
# voix (via.wwise.WwiseDriver.get_Language). Chaîne : event -> Action Play -> Sound -> source,
# .wem pris dans le .pck streamé de la langue (ou embarqué dans la banque).
VOICES = {
    # Daniela : « ça fait longtemps que je n'ai pas disséqué un homme » + rire (trigger 2490342862)
    "ap_trap_for_other": ("em1261_v_dialogue", 1480136888),
}
LANGS = ["ja", "en", "fr", "it", "de", "es", "ru", "ptbr", "zhcn"]
# Voix choisies à l'écoute (Assets/sons/candidats_rire, 2026-10-07) : nom -> (banque, ID du média
# dans la version FRANÇAISE). Les médias changent de numéro selon la langue, pas l'objet Sound
# qui les joue : on retrouve le Sound en français, puis son média dans chaque langue.
VOICE_MEDIA = {
    "ap_trap_laugh": ("em1000_v", 1021590585),    # Dimitrescu : rire (2,1 s) -> piège reçu
    "ap_trap_scream": ("em1262_v", 942265860),    # Bela : cri (5,4 s) -> piège « screamer »
}

# Bruits de ramassage des objets (2026-10-07) : chaque objet riXXXX a sa banque riXXXX.bnk et sa
# liste snd_eventlist_riXXXX.wel ; le ramassage = trigger commun PICKUP_TRIGGER. Pour chaque objet
# dont ce trigger joue un Sound à média embarqué (Event -> Play -> Sound, ou 1re variante d'un
# conteneur aléatoire), le média est
# copié dans system.bnk sous le nom ap_pickup_riXXXX (réglages du jingle, pas ceux de l'objet,
# dont le bus n'existe pas dans system.bnk). Table ri -> trigger écrite pour le client
# (client/reframework/data/re_village_ap_client/ap_sounds.json).
PICKUP_TRIGGER = 1738562264
# Objets dont le ramassage passe par un AUTRE trigger (relevé en jeu) : sac de Lei (2026-10-07).
PICKUP_TRIGGER_BY_RI = {"ri5101": 1399615424}
RI_LIST = os.path.join(os.path.dirname(__file__), "RE8_STM_Release.list")

TEMPLATE_EVENT = 524142899   # jingle trésor (trigger 3769661010)
TEMPLATE_TRIGGER = 3769661010
TEMPLATE_PARENT = 356891578  # actor-mixer du jingle


def fnv1(name):
    h = 2166136261
    for c in name.lower().encode("ascii"):
        h = (h * 16777619) & 0xFFFFFFFF
        h ^= c
    return h


def read_sections(b):
    out, o = [], 0
    while o + 8 <= len(b):
        tag, n = b[o:o + 4], struct.unpack_from("<I", b, o + 4)[0]
        out.append([tag, bytearray(b[o + 8:o + 8 + n])])
        o += 8 + n
    return out


def parse_hirc(body):
    count, p, objs = struct.unpack_from("<I", body, 0)[0], 4, []
    for _ in range(count):
        ln = struct.unpack_from("<I", body, p + 1)[0]
        objs.append(bytearray(body[p:p + 5 + ln]))
        p += 5 + ln
    return objs


def obj_id(o):
    return struct.unpack_from("<I", o, 5)[0]


def patch_bnk(data, sounds):
    secs = read_sections(data)
    sec = {bytes(t): s for t, s in secs}
    objs = parse_hirc(sec[b"HIRC"])
    by_id = {obj_id(o): o for o in objs}
    event = by_id[TEMPLATE_EVENT]
    action = by_id[struct.unpack_from("<I", event, 10)[0]]
    sound = by_id[struct.unpack_from("<I", action, 11)[0]]
    parent = by_id[TEMPLATE_PARENT]
    didx = [struct.unpack_from("<III", sec[b"DIDX"], 12 * k) for k in range(len(sec[b"DIDX"]) // 12)]
    blob = sec[b"DATA"]
    events = {}
    for name, wem_path in sounds.items():
        wem = open(wem_path, "rb").read()
        ids = {k: fnv1(f"{name}_{k}") for k in ("event", "action", "sound", "media")}
        for k, v in ids.items():
            if v in by_id or any(m == v for m, _, _ in didx):
                raise SystemExit(f"ID déjà pris : {name} {k} {v}")
        # média embarqué
        offset = (len(blob) + 15) & ~15
        blob.extend(b"\0" * (offset - len(blob)))
        blob.extend(wem)
        didx.append((ids["media"], offset, len(wem)))
        # Sound : id, source (plugin u32, stream u8, sourceID u32, taille u32)
        s = bytearray(sound)
        struct.pack_into("<I", s, 5, ids["sound"])
        struct.pack_into("<I", s, 14, ids["media"])
        struct.pack_into("<I", s, 18, len(wem))
        # Action Play : id, cible
        a = bytearray(action)
        struct.pack_into("<I", a, 5, ids["action"])
        struct.pack_into("<I", a, 11, ids["sound"])
        # Event : id, 1 action
        e = bytearray(event)
        struct.pack_into("<I", e, 5, ids["event"])
        struct.pack_into("<I", e, 10, ids["action"])
        # Ordre comme Wwise l'écrit (enfants avant parents) : Sound juste après le son modèle
        # (donc avant l'actor-mixer qui le liste), Action après l'action modèle, Event à la fin.
        objs.insert(objs.index(sound) + 1, s)
        objs.insert(objs.index(action) + 1, a)
        objs.append(e)
        # enfants de l'actor-mixer : liste triée en fin d'objet (nombre u32 + ID)
        count = next(c for c in range(1, 256)
                     if struct.unpack_from("<I", parent, len(parent) - 4 * (c + 1))[0] == c)
        n_pos = len(parent) - 4 * (count + 1)
        children = sorted(list(struct.unpack_from(f"<{count}I", parent, n_pos + 4)) + [ids["sound"]])
        del parent[n_pos:]
        parent += struct.pack(f"<I{len(children)}I", len(children), *children)
        struct.pack_into("<I", parent, 1, len(parent) - 5)
        events[name] = ids["event"]
    didx.sort()
    sec[b"DIDX"][:] = b"".join(struct.pack("<III", *d) for d in didx)
    sec[b"HIRC"][:] = struct.pack("<I", len(objs)) + b"".join(objs)
    # Les banques du jeu alignent le début des données de DATA sur 16 octets en complétant BKHD
    # par des zéros (system : BKHD 32, em1261_v : BKHD 28) ; DIDX ayant grandi, on refait pareil.
    before_data = 0
    for tag, body in secs:
        if tag == b"DATA":
            break
        before_data += 8 + len(body)
    sec[b"BKHD"].extend(b"\0" * ((-(before_data + 8)) % 16))
    out = bytearray()
    for tag, body in secs:
        out += tag + struct.pack("<I", len(body)) + body
    return bytes(out), events


# Trigger de TEST (2026-10-07, son AP muet) : trigger neuf -> event EXISTANT du jingle trésor.
# S'il joue le jingle, la liste .wel modifiée est bien prise et le souci vient de la banque.
TEST_TRIGGERS = {"ap_test_treasure": TEMPLATE_EVENT}


def patch_wel(data, events):
    b = bytearray(data)
    n = struct.unpack_from("<I", b, 0x200)[0]
    entries = [bytes(b[0x204 + 62 * k:0x204 + 62 * (k + 1)]) for k in range(n)]
    template = next(e for e in entries if struct.unpack_from("<I", e, 0)[0] == TEMPLATE_TRIGGER)
    triggers = {}
    for name, event_id in events.items():
        trig = fnv1(name)
        if any(struct.unpack_from("<I", e, 0)[0] == trig for e in entries):
            raise SystemExit(f"trigger déjà pris : {name} {trig}")
        e = bytearray(template)
        struct.pack_into("<II", e, 0, trig, event_id)
        entries.append(bytes(e))
        triggers[name] = trig
    entries.sort(key=lambda e: struct.unpack_from("<I", e, 0)[0])
    tail = b[0x204 + 62 * n:]
    return bytes(b[:0x200]) + struct.pack("<I", len(entries)) + b"".join(entries) + bytes(tail), triggers


def voice_wem(tmp, bank, event_id, lang):
    """.wem de la voix (event_id de la banque bank) dans la langue lang."""
    bnk_path = f"natives/stm/sound/wwise/{bank}.bnk.2.x64.{lang}"
    pck_path = f"natives/stm/streaming/sound/wwise/{bank}.pck.3.x64.{lang}"
    extract([bnk_path, pck_path], tmp)
    b = open(os.path.join(tmp, bnk_path), "rb").read()
    secs = {bytes(t): s for t, s in read_sections(b)}
    by_id = {obj_id(o): o for o in parse_hirc(secs[b"HIRC"])}
    action = by_id[struct.unpack_from("<I", by_id[event_id], 10)[0]]
    sound = by_id[struct.unpack_from("<I", action, 11)[0]]
    source = struct.unpack_from("<I", sound, 14)[0]
    didx = secs.get(b"DIDX", b"")
    for k in range(len(didx) // 12):
        media, off, size = struct.unpack_from("<III", didx, 12 * k)
        if media == source:
            return bytes(secs[b"DATA"][off:off + size])
    p = open(os.path.join(tmp, pck_path), "rb").read()
    _, lang_map, banks_lut, _, _ = struct.unpack_from("<5I", p, 8)
    o = 28 + lang_map + banks_lut
    for k in range(struct.unpack_from("<I", p, o)[0]):
        wid, block, size, start, _ = struct.unpack_from("<5I", p, o + 4 + 20 * k)
        if wid == source:
            return p[start * block:start * block + size]
    raise SystemExit(f"voix introuvable : {bank} {event_id} {lang}")


def bank_media(tmp, bank, lang):
    """(objets HIRC par ID, {média: octets}) de la banque bank dans la langue lang."""
    path = f"natives/stm/sound/wwise/{bank}.bnk.2.x64.{lang}"
    extract([path], tmp)
    b = open(os.path.join(tmp, path), "rb").read()
    secs = {bytes(t): x for t, x in read_sections(b)}
    by_id = {obj_id(o): o for o in parse_hirc(secs[b"HIRC"])}
    didx = secs.get(b"DIDX", b"")
    media = {}
    for k in range(len(didx) // 12):
        m, off, size = struct.unpack_from("<III", didx, 12 * k)
        media[m] = bytes(secs[b"DATA"][off:off + size])
    return by_id, media


def voice_media_wem(tmp, bank, fr_media, lang):
    fr_objs, _ = bank_media(tmp, bank, "fr")
    sound_id = next((i for i, o in fr_objs.items()
                     if o[0] == 2 and struct.unpack_from("<I", o, 14)[0] == fr_media), None)
    if sound_id is None:
        raise SystemExit(f"Sound introuvable : {bank} {fr_media}")
    objs, media = bank_media(tmp, bank, lang)
    source = struct.unpack_from("<I", objs[sound_id], 14)[0]
    if source not in media:
        raise SystemExit(f"média introuvable : {bank} {lang} {source}")
    return media[source]


def pickup_wems(tmp):
    """{riXXXX: .wem} des bruits de ramassage simples."""
    paths = []
    for line in open(RI_LIST, encoding="utf-8"):
        line = line.strip()
        if line.startswith("natives/stm/sound/sound_asset/snd_eventlist/ri/") and line.endswith(".wel.11"):
            paths.append(line)
    extract(paths, tmp)
    out = {}
    for wel_path in paths:
        ri = wel_path.rsplit("_", 1)[1].split(".")[0]
        if not os.path.exists(os.path.join(tmp, wel_path)):
            continue  # listé mais absent des paks
        w = open(os.path.join(tmp, wel_path), "rb").read()
        bank = w[:0x200].decode("utf-16-le").split(chr(0))[0].rsplit("/", 1)[1]
        n = struct.unpack_from("<I", w, 0x200)[0]
        events = [struct.unpack_from("<II", w, 0x204 + 62 * k) for k in range(n)]
        wanted = PICKUP_TRIGGER_BY_RI.get(ri, PICKUP_TRIGGER)
        event_id = next((e for t, e in events if t == wanted), None)
        if event_id is None:
            continue
        bnk_path = f"natives/stm/sound/wwise/{bank}.2.x64"
        extract([bnk_path], tmp)
        full = os.path.join(tmp, bnk_path)
        if not os.path.exists(full):
            continue
        b = open(full, "rb").read()
        secs = {bytes(t): x for t, x in read_sections(b)}
        if b"HIRC" not in secs or b"DIDX" not in secs:
            continue
        by_id = {obj_id(o): o for o in parse_hirc(secs[b"HIRC"])}
        event = by_id.get(event_id)
        if not event or event[9] != 1:
            continue
        action = by_id.get(struct.unpack_from("<I", event, 10)[0])
        if not action or struct.unpack_from("<H", action, 9)[0] != 0x0403:
            continue
        sound = by_id.get(struct.unpack_from("<I", action, 11)[0])
        if sound and sound[0] == 5:
            # conteneur aléatoire de variantes (Munitions, Ferraille, Lei...) : 1re variante
            # (premier Sound à média embarqué cité dans le conteneur)
            variant = None
            for q in range(9, len(sound) - 3):
                cand = by_id.get(struct.unpack_from("<I", sound, q)[0])
                if cand is not None and cand[0] == 2 and cand[13] == 0:
                    variant = cand
                    break
            sound = variant
        if not sound or sound[0] != 2 or sound[13] != 0:
            continue
        source = struct.unpack_from("<I", sound, 14)[0]
        didx = secs[b"DIDX"]
        for k in range(len(didx) // 12):
            media, off, size = struct.unpack_from("<III", didx, 12 * k)
            if media == source:
                out[ri] = bytes(secs[b"DATA"][off:off + size])
    return out


def main():
    sounds = {}
    with tempfile.TemporaryDirectory() as tmp:
        extract([BNK_PATH, WEL_PATH], tmp)
        bnk = open(os.path.join(tmp, BNK_PATH), "rb").read()
        wel = open(os.path.join(tmp, WEL_PATH), "rb").read()
        for name, (bank, event_id) in VOICES.items():
            for lang in LANGS:
                path = os.path.join(tmp, f"{name}_{lang}.wem")
                open(path, "wb").write(voice_wem(tmp, bank, event_id, lang))
                sounds[f"{name}_{lang}"] = path
        for name, (bank, fr_media) in VOICE_MEDIA.items():
            for lang in LANGS:
                path = os.path.join(tmp, f"{name}_{lang}.wem")
                open(path, "wb").write(voice_media_wem(tmp, bank, fr_media, lang))
                sounds[f"{name}_{lang}"] = path
        pickups = pickup_wems(tmp)
        for ri, wem in sorted(pickups.items()):
            path = os.path.join(tmp, f"ap_pickup_{ri}.wem")
            open(path, "wb").write(wem)
            sounds[f"ap_pickup_{ri}"] = path
        print(f"bruits de ramassage : {len(pickups)} objets, {sum(len(w) for w in pickups.values())} octets")
        new_bnk, events = patch_bnk(bnk, sounds)
    new_wel, triggers = patch_wel(wel, {**events, **TEST_TRIGGERS})
    for path, data in ((BNK_PATH, new_bnk), (WEL_PATH, new_wel)):
        target = os.path.join(ROOT, "client", path.replace("/", os.sep))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        open(target, "wb").write(data)
        print(f"écrit : {target} ({len(data)} octets)")
    table = {name[len("ap_pickup_"):]: trig for name, trig in triggers.items() if name.startswith("ap_pickup_")}
    target = os.path.join(ROOT, "client", "reframework", "data", "re_village_ap_client", "ap_sounds.json")
    import json
    voices = {}
    for name, trig in triggers.items():
        base, _, lang = name.rpartition("_")
        if lang in LANGS:
            voices.setdefault(base, {})[lang] = trig
    json.dump({"pickup": table, "voice": voices}, open(target, "w", encoding="utf-8"), indent=1, sort_keys=True)
    print(f"écrit : {target} ({len(table)} bruits de ramassage)")
    for name, trig in triggers.items():
        if name.startswith("ap_pickup_"):
            continue
        print(f"son {name} : trigger {trig} (event {events.get(name, TEST_TRIGGERS.get(name))})")


if __name__ == "__main__":
    main()
