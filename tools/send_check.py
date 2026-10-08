"""
Valide des checks d'Ethan à la main sur un serveur de TEST (2026-09-30).

Sert quand une sauvegarde de test (faite avant la seed) n'a plus l'objet d'un emplacement : le
joueur ne peut pas le ramasser, l'objet Archipelago placé là n'arrive jamais (ex. Sanguis Virginis
sur « Ange en bois #004 [S11] », déjà ramassé dans la sauvegarde -> blocage).
Se connecte en plus du jeu (un slot accepte plusieurs clients), envoie les checks, se déconnecte.

  python tools/send_check.py --port 38282 "Chateau Dimitrescu - Ange en bois #004 [S11]" [...]
  python tools/send_check.py --port 38282 --find "Ange en bois"     (liste les noms qui contiennent ce texte)

Jamais sur la vraie partie (38281). Nécessite : pip install websockets
"""

import argparse
import asyncio
import json
import uuid

import websockets

GAME = "Resident Evil Village"


async def main(args):
    if args.port == 38281:
        raise SystemExit("refusé : 38281 = la vraie partie")
    async with websockets.connect(f"ws://{args.host}:{args.port}", max_size=None) as ws:
        json.loads(await ws.recv())  # RoomInfo
        await ws.send(json.dumps([{"cmd": "GetDataPackage", "games": [GAME]}]))
        names = {}
        while not names:
            for packet in json.loads(await ws.recv()):
                if packet["cmd"] == "DataPackage":
                    names = packet["data"]["games"][GAME]["location_name_to_id"]
        if args.find:
            for name in sorted(n for n in names if args.find.lower() in n.lower()):
                print(name)
            return
        await ws.send(json.dumps([{
            "cmd": "Connect", "game": GAME, "name": args.slot, "password": "", "uuid": str(uuid.uuid4()),
            "version": {"major": 0, "minor": 6, "build": 0, "class": "Version"},
            "items_handling": 0, "tags": [], "slot_data": False,
        }]))
        for packet in json.loads(await ws.recv()):
            if packet["cmd"] == "ConnectionRefused":
                raise SystemExit(f"connexion refusée : {packet.get('errors')}")
        ids = []
        for name in args.locations:
            if name not in names:
                raise SystemExit(f"location inconnue : {name} (essaie --find)")
            ids.append(names[name])
        await ws.send(json.dumps([{"cmd": "LocationChecks", "locations": ids}]))
        await asyncio.sleep(1)
        print(f"{len(ids)} check(s) envoyé(s) : " + ", ".join(args.locations))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("locations", nargs="*")
    parser.add_argument("--find")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=38282)
    parser.add_argument("--slot", default="Ethan")
    asyncio.run(main(parser.parse_args()))
