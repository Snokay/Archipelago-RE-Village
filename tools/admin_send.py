"""
Donne un objet à un joueur pendant un test (2026-10-08) : se connecte au serveur en spectateur
(tracker) sur le slot du joueur, s'identifie comme admin (serveur lancé avec --server_password)
et envoie « !admin /send <joueur> <objet> ». Affiche les réponses du serveur.

Usage : python tools/admin_send.py ADRESSE SLOT MOT_DE_PASSE_ADMIN "NOM DE L'OBJET" [NOMBRE]
  ex. python tools/admin_send.py localhost:38282 Ethan admintest "Clé ailée (progressive)"
"""

import json
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "launcher"))
import apnet  # noqa: E402


def texts(ws, seconds):
    """Messages du serveur (PrintJSON) pendant `seconds` secondes."""
    out, end = [], time.time() + seconds
    ws.sock.settimeout(0.5)
    while time.time() < end:
        try:
            packets = json.loads(ws.recv())
        except (TimeoutError, OSError):
            continue
        except apnet.APError:
            break
        for p in packets:
            if p.get("cmd") == "PrintJSON":
                out.append("".join(part.get("text", "") for part in p.get("data", [])))
    return out


def main():
    address, slot, admin_pw, item = sys.argv[1:5]
    count = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    uris, _ = apnet.normalize(address)
    ws = apnet.WebSocket(uris[0])
    room = None
    while room is None:
        for p in json.loads(ws.recv()):
            if p.get("cmd") == "RoomInfo":
                room = p
    v = room["version"]
    ws.send(json.dumps([{"cmd": "Connect", "game": "", "name": slot, "password": "", "uuid": uuid.uuid4().hex,
                         "items_handling": 0, "tags": ["Tracker", "TextOnly"], "slot_data": False,
                         "version": {"major": v["major"], "minor": v["minor"], "build": v["build"], "class": "Version"}}]))
    texts(ws, 1.5)
    ws.send(json.dumps([{"cmd": "Say", "text": f"!admin login {admin_pw}"}]))
    for line in texts(ws, 1.5):
        print("serveur :", line)
    for _ in range(count):
        ws.send(json.dumps([{"cmd": "Say", "text": f"!admin /send {slot} {item}"}]))
        for line in texts(ws, 1.5):
            print("serveur :", line)
    ws.close()


if __name__ == "__main__":
    main()
