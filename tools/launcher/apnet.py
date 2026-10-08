"""
Test de connexion à un serveur Archipelago, sans dépendance (websocket minimal, bibliothèque
standard seulement).

check(adresse, slot, mot_de_passe) se connecte comme un tracker (tags ["Tracker"], game ""),
ce qui vérifie l'adresse, le slot et le mot de passe sans jouer à la place du joueur. Renvoie
l'adresse complète qui a marché (wss:// ou ws://), à écrire dans connection.json : le client en
jeu l'utilise telle quelle.

Adresses acceptées : "archipelago.gg:38281", "/connect archipelago.gg:38281", "38281" (port
seul = archipelago.gg), "localhost:38281", "ws://..." / "wss://...", et le lien de la page de la
room (https://archipelago.gg/room/...) : la page est ouverte (ce qui réveille une room endormie)
et l'adresse y est lue.
"""

import base64
import json
import os
import re
import socket
import ssl
import struct
import urllib.request
import uuid

GAME = "Resident Evil Village"


class APError(Exception):
    pass


# --- Adresse ----------------------------------------------------------------------------------

def resolve_room_page(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": "RE-Village-AP-Launcher"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        html = r.read().decode("utf-8", errors="replace")
    host = re.match(r"https?://([^/]+)", url).group(1)
    m = re.search(r"/connect\s+([\w.\-]+:\d{2,5})", html) or re.search(re.escape(host) + r":(\d{2,5})", html)
    if not m:
        raise APError("no address on the room page")
    return m.group(1) if ":" in m.group(1) else f"{host}:{m.group(1)}"


def normalize(address):
    """Renvoie (liste d'URI à essayer dans l'ordre, adresse lue)."""
    address = address.strip()
    address = re.sub(r"^/connect\s+", "", address)
    if re.match(r"https?://", address):
        address = resolve_room_page(address)
    if re.fullmatch(r"\d{2,5}", address):
        address = "archipelago.gg:" + address
    if "://" in address:
        return [address], address
    if ":" not in address:
        address += ":38281"
    local = re.match(r"(localhost|127\.|192\.168\.|10\.)", address)
    order = ["ws://", "wss://"] if local else ["wss://", "ws://"]
    return [p + address for p in order], address


def guess_uri(address):
    """Adresse complète sans test réseau (enregistrement automatique) : ws:// en local, sinon
    wss://. None pour un lien de page de room (à lire d'abord)."""
    address = re.sub(r"^/connect\s+", "", address.strip())
    if not address or re.match(r"https?://", address):
        return None
    if re.fullmatch(r"\d{2,5}", address):
        address = "archipelago.gg:" + address
    if "://" in address:
        return address
    if ":" not in address:
        address += ":38281"
    local = re.match(r"(localhost|127\.|192\.168\.|10\.)", address)
    return ("ws://" if local else "wss://") + address


# --- Websocket minimal ------------------------------------------------------------------------

class WebSocket:
    def __init__(self, uri, timeout=8):
        m = re.match(r"(wss?)://([^/:]+)(?::(\d+))?(/.*)?$", uri)
        if not m:
            raise APError("bad address")
        scheme, host, port, path = m.group(1), m.group(2), m.group(3), m.group(4) or "/"
        port = int(port or (443 if scheme == "wss" else 80))
        sock = socket.create_connection((host, port), timeout=timeout)
        if scheme == "wss":
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        self.sock = sock
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                raise APError("connection closed during handshake")
            head += chunk
        head, self.buf = head.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise APError("not a websocket server")

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise APError("connection closed")
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def send(self, text, opcode=1):
        payload = text.encode() if isinstance(text, str) else text
        n = len(payload)
        header = bytes([0x80 | opcode])
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 8:
                raise APError("closed by server")
            if opcode == 9:
                self.send(data, opcode=10)
                continue
            if opcode == 10:
                continue
            message += data
            if b0 & 0x80:
                return message.decode("utf-8", errors="replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# --- Test -------------------------------------------------------------------------------------

def _packets(ws):
    for packet in json.loads(ws.recv()):
        yield packet


def check(address, slot, password=""):
    """Renvoie un dict : ok, uri (adresse à mémoriser), address, game_ok, code d'erreur, texte."""
    uris, shown = normalize(address)
    last = None
    for uri in uris:
        try:
            ws = WebSocket(uri)
        except (OSError, APError) as e:
            last = e
            continue
        try:
            room = None
            while room is None:
                for p in _packets(ws):
                    if p.get("cmd") == "RoomInfo":
                        room = p
            v = room.get("version", {})
            ws.send(json.dumps([{"cmd": "Connect", "game": "", "name": slot, "password": password,
                                 "uuid": uuid.uuid4().hex, "items_handling": 0, "tags": ["Tracker"],
                                 "slot_data": False,
                                 "version": {"major": v.get("major", 0), "minor": v.get("minor", 6),
                                             "build": v.get("build", 0), "class": "Version"}}]))
            while True:
                for p in _packets(ws):
                    if p.get("cmd") == "ConnectionRefused":
                        return {"ok": False, "uri": uri, "address": shown,
                                "error": ",".join(p.get("errors", [])) or "refused"}
                    if p.get("cmd") == "Connected":
                        game = None
                        for info in p.get("slot_info", {}).values():
                            if info.get("name") == slot:
                                game = info.get("game")
                        return {"ok": True, "uri": uri, "address": shown, "game": game,
                                "game_ok": game == GAME, "games": room.get("games", [])}
        except (OSError, APError, ValueError) as e:
            last = e
        finally:
            ws.close()
    return {"ok": False, "uri": None, "address": shown, "error": "unreachable", "detail": str(last)}


if __name__ == "__main__":
    import sys
    print(check(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""))
