"""
Pont Archipelago <-> Resident Evil Village.

Pourquoi ce pont existe : le script REFramework (client/re_village_ap_client.lua) tourne
DANS le processus du jeu, dans un bac à sable Lua qui n'a pas d'accès fiable à un vrai
socket réseau (websocket) pour parler au serveur Archipelago. On sépare donc en deux :

    Jeu (REFramework/Lua)  <--fichiers JSON Lines-->  ap_bridge.py (ce script)  <--WebSocket AP-->  Serveur Archipelago

- Le Lua écrit une ligne JSON dans `checks_to_send.jsonl` à chaque check validé en jeu.
- Ce script lit les nouvelles lignes, envoie un paquet `LocationChecks` au serveur, et
  écrit chaque item reçu du serveur (`ReceivedItems`) dans `received_items.jsonl`.
- Le Lua relit `received_items.jsonl` à chaque frame (ou chaque seconde) pour injecter les
  items dans l'état du jeu.

Idempotence : ce script ne fait AUCUNE hypothèse sur ce qui a déjà été traité côté jeu.
C'est au Lua de ne jamais rejouer un item déjà injecté (voir re_village_ap_client.lua).
Côté check, ce script garde une trace locale (`sent_checks.json`) des ids déjà envoyés au
serveur, pour ne pas renvoyer un LocationChecks en double après un redémarrage.

Dépendances : `pip install websockets` (voir requirements.txt).

Statut : ébauche fonctionnelle du protocole réseau AP (RoomInfo -> Connect -> Connected ->
LocationChecks / ReceivedItems). Les identifiants de locations/items sont lus directement
depuis les fichiers JSON de l'apworld (../../apworld/residentevilvillage/data/), pour ne
jamais dupliquer ces tables à la main.
"""

import argparse
import asyncio
import json
import os
import sys

import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
APWORLD_DATA_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "apworld", "residentevilvillage", "data"))

# ⚠️ REFramework interdit les chemins absolus à son API io/json côté Lua (confirmé en jeu
# le 2026-09-13) : elle ne peut lire/écrire que dans <dossier du jeu>/reframework/data/, en
# relatif à ce dossier. Le Lua (re_village_ap_client.lua) utilise donc le sous-dossier
# "re_village_ap_client" sous reframework/data/ — ce script doit pointer au même endroit,
# d'où l'argument --game-dir obligatoire (le dossier contenant re8.exe et reframework/).
MOD_DATA_SUBDIR = "re_village_ap_client"

CHECKS_TO_SEND_FILE = None   # résolu dans main() une fois --game-dir connu
RECEIVED_ITEMS_FILE = None
SENT_CHECKS_STATE_FILE = None


def resolve_runtime_paths(game_dir):
    global CHECKS_TO_SEND_FILE, RECEIVED_ITEMS_FILE, SENT_CHECKS_STATE_FILE
    runtime_dir = os.path.join(game_dir, "reframework", "data", MOD_DATA_SUBDIR)
    CHECKS_TO_SEND_FILE = os.path.join(runtime_dir, "checks_to_send.jsonl")
    RECEIVED_ITEMS_FILE = os.path.join(runtime_dir, "received_items.jsonl")
    SENT_CHECKS_STATE_FILE = os.path.join(runtime_dir, "sent_checks.json")
    return runtime_dir

# Doit rester identique à Data.BASE_ID côté apworld (voir Data.py).
BASE_ID = 3908000000
LOCATION_ID_START = BASE_ID + 1000000000


def load_location_name_to_id():
    """Reconstruit location_name_to_id sans dépendre du package apworld (pas d'imports
    relatifs Archipelago ici, ce script tourne en dehors du contexte AP)."""
    with open(os.path.join(APWORLD_DATA_DIR, "locations.json"), encoding="utf-8") as f:
        locations = json.load(f)

    name_to_id = {}
    for key, loc in enumerate(locations):
        if "force_item" in loc:
            continue  # location événement (Victory), jamais envoyée sur le réseau
        stacked_name = loc["name"] if loc["name"] == "Victory" else f"{loc['region']} - {loc['name']}"
        name_to_id[stacked_name] = LOCATION_ID_START + key

    return name_to_id


def load_item_id_to_name():
    with open(os.path.join(APWORLD_DATA_DIR, "items.json"), encoding="utf-8") as f:
        items = json.load(f)

    id_to_name = {}
    key = 0
    for item in items:
        if item.get("type") == "Event":
            continue
        id_to_name[BASE_ID + key] = item["name"]
        key += 1

    return id_to_name


def ensure_runtime_files(runtime_dir):
    os.makedirs(runtime_dir, exist_ok=True)
    for path in (CHECKS_TO_SEND_FILE, RECEIVED_ITEMS_FILE):
        if not os.path.exists(path):
            open(path, "a", encoding="utf-8").close()
    if not os.path.exists(SENT_CHECKS_STATE_FILE):
        with open(SENT_CHECKS_STATE_FILE, "w", encoding="utf-8") as f:
            json.dump({"sent_location_ids": [], "checks_to_send_lines_read": 0,
                       "received_items_lines_written": 0}, f)


def load_state():
    with open(SENT_CHECKS_STATE_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_state(state):
    with open(SENT_CHECKS_STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f)


class APBridge:
    def __init__(self, host, port, slot, password=None):
        self.host = host
        self.port = port
        self.slot = slot
        self.password = password
        self.location_name_to_id = load_location_name_to_id()
        self.item_id_to_name = load_item_id_to_name()
        self.state = load_state()
        self.websocket = None

    async def run(self):
        uri = f"ws://{self.host}:{self.port}"
        print(f"[ap_bridge] Connexion à {uri}...")

        async with websockets.connect(uri) as ws:
            self.websocket = ws

            # --- Handshake AP standard ---
            room_info = json.loads(await ws.recv())  # premier paquet: liste, contient RoomInfo
            print(f"[ap_bridge] RoomInfo reçu : {room_info}")

            connect_packet = [{
                "cmd": "Connect",
                "password": self.password,
                "game": "Resident Evil Village",
                "name": self.slot,
                "uuid": "re_village_ap_bridge",
                "version": {"major": 0, "minor": 5, "build": 0, "class": "Version"},
                "items_handling": 0b111,  # tous les items (y compris les nôtres et starting inventory)
                "tags": [],
                "slot_data": True,
            }]
            await ws.send(json.dumps(connect_packet))

            connected = json.loads(await ws.recv())
            print(f"[ap_bridge] Réponse de connexion : {connected}")

            if connected and connected[0].get("cmd") != "Connected":
                print("[ap_bridge] Connexion refusée, arrêt.")
                return

            print("[ap_bridge] Connecté. Boucle principale démarrée.")

            await asyncio.gather(
                self._poll_outgoing_checks(),
                self._listen_incoming(),
            )

    async def _poll_outgoing_checks(self):
        """Relit checks_to_send.jsonl périodiquement pour repérer les nouvelles lignes
        écrites par le client Lua, et envoie un LocationChecks pour chacune (une seule
        fois, grâce à sent_location_ids)."""
        while True:
            with open(CHECKS_TO_SEND_FILE, encoding="utf-8") as f:
                lines = f.readlines()

            new_lines = lines[self.state["checks_to_send_lines_read"]:]

            if new_lines:
                new_ids = []
                for line in new_lines:
                    line = line.strip()
                    if not line:
                        continue
                    entry = json.loads(line)
                    location_name = entry["location_name"]
                    location_id = self.location_name_to_id.get(location_name)

                    if location_id is None:
                        print(f"[ap_bridge] ATTENTION : location inconnue '{location_name}', ignorée.")
                        continue

                    if location_id in self.state["sent_location_ids"]:
                        continue  # déjà envoyé lors d'une session précédente (idempotence)

                    new_ids.append(location_id)
                    self.state["sent_location_ids"].append(location_id)

                self.state["checks_to_send_lines_read"] = len(lines)
                save_state(self.state)

                if new_ids:
                    await self.websocket.send(json.dumps([{"cmd": "LocationChecks", "locations": new_ids}]))
                    print(f"[ap_bridge] Checks envoyés : {new_ids}")

            await asyncio.sleep(1.0)

    async def _listen_incoming(self):
        async for message in self.websocket:
            for packet in json.loads(message):
                if packet.get("cmd") == "ReceivedItems":
                    self._handle_received_items(packet)
                elif packet.get("cmd") == "PrintJSON":
                    pass  # TODO : afficher dans une console/overlay si souhaité

    def _handle_received_items(self, packet):
        start_index = packet.get("index", 0)

        with open(RECEIVED_ITEMS_FILE, "a", encoding="utf-8") as f:
            for offset, item in enumerate(packet.get("items", [])):
                global_index = start_index + offset

                # index sert de clé d'idempotence pour le Lua : si l'index a déjà été
                # écrit lors d'une session précédente, ap_bridge ne le réécrit pas.
                if global_index < self.state["received_items_lines_written"]:
                    continue

                item_name = self.item_id_to_name.get(item["item"], f"UnknownItem({item['item']})")
                f.write(json.dumps({"index": global_index, "item_name": item_name}) + "\n")

        self.state["received_items_lines_written"] = max(
            self.state["received_items_lines_written"], start_index + len(packet.get("items", []))
        )
        save_state(self.state)
        print(f"[ap_bridge] {len(packet.get('items', []))} item(s) reçu(s), écrits dans received_items.jsonl")


def main():
    parser = argparse.ArgumentParser(description="Pont Archipelago pour Resident Evil Village")
    parser.add_argument("--host", default="archipelago.gg")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--slot", required=True, help="Nom du joueur (slot) tel que dans le yaml")
    parser.add_argument("--password", default=None)
    parser.add_argument("--game-dir", required=True,
                         help=r"Dossier d'installation du jeu, ex: D:\Steam\steamapps\common\Resident Evil Village BIOHAZARD VILLAGE")
    args = parser.parse_args()

    runtime_dir = resolve_runtime_paths(args.game_dir)
    ensure_runtime_files(runtime_dir)
    print(f"[ap_bridge] Fichiers de pont dans : {runtime_dir}")

    bridge = APBridge(args.host, args.port, args.slot, args.password)

    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        print("\n[ap_bridge] Arrêt demandé.")
        sys.exit(0)


if __name__ == "__main__":
    main()
