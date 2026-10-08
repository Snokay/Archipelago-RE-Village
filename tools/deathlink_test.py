"""
Faux deuxième joueur pour tester le DeathLink (2026-09-27).

Se connecte au serveur sur un slot d'un autre jeu (par défaut "Joueur2", ChecksFinder, de
seeds/test_deathlink) avec le tag DeathLink, sans jouer à ce jeu :
  python tools/deathlink_test.py listen [--port 38282]
      reste connecté et note chaque mort reçue (celle d'Ethan quand il meurt dans RE Village) ;
      tant qu'il tourne, créer le fichier build/deathlink_kill fait mourir ce joueur : la mort
      est envoyée aux autres (Ethan doit avoir un game over), puis le fichier est supprimé.
  python tools/deathlink_test.py kill [--port 38282]
      se connecte, envoie une mort ("Joueur2 est mort") puis se déconnecte.
Nécessite : pip install websockets
"""

import argparse
import asyncio
import json
import time
import uuid
from pathlib import Path

import websockets

KILL_FILE = Path(__file__).resolve().parent.parent / "build" / "deathlink_kill"


async def connect(args):
    ws = await websockets.connect(f"ws://{args.host}:{args.port}", max_size=None)
    json.loads(await ws.recv())  # RoomInfo
    await ws.send(json.dumps([{
        "cmd": "Connect", "game": args.game, "name": args.name, "password": "", "uuid": str(uuid.uuid4()),
        "version": {"major": 0, "minor": 6, "build": 0, "class": "Version"},
        "items_handling": 0, "tags": ["DeathLink"], "slot_data": False,
    }]))
    for packet in json.loads(await ws.recv()):
        if packet["cmd"] == "ConnectionRefused":
            raise SystemExit(f"connexion refusée : {packet.get('errors')}")
    print(f"connecté en tant que {args.name} ({args.game}), tag DeathLink", flush=True)
    return ws


async def send_death(ws, args):
    await ws.send(json.dumps([{
        "cmd": "Bounce", "tags": ["DeathLink"],
        "data": {"time": time.time(), "source": args.name, "cause": f"{args.name} est mort (test)"},
    }]))
    print(f"{time.strftime('%H:%M:%S')} mort envoyée par {args.name}", flush=True)


async def listen(args):
    ws = await connect(args)

    async def watch_kill_file():
        while True:
            if KILL_FILE.exists():
                KILL_FILE.unlink()
                await send_death(ws, args)
            await asyncio.sleep(0.5)

    watcher = asyncio.create_task(watch_kill_file())
    try:
        async for message in ws:
            for packet in json.loads(message):
                if packet["cmd"] == "Bounced" and "DeathLink" in packet.get("tags", []):
                    data = packet.get("data", {})
                    print(f"{time.strftime('%H:%M:%S')} MORT REÇUE de {data.get('source')} : {data.get('cause')}",
                          flush=True)
    finally:
        watcher.cancel()


async def kill(args):
    ws = await connect(args)
    await send_death(ws, args)
    await asyncio.sleep(1)
    await ws.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["listen", "kill"])
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=38282)
    parser.add_argument("--name", default="Joueur2")
    parser.add_argument("--game", default="ChecksFinder")
    args = parser.parse_args()
    asyncio.run(listen(args) if args.mode == "listen" else kill(args))


if __name__ == "__main__":
    main()
