"""
Serveur Archipelago de test piloté par fichier (2026-10-08) : lance ArchipelagoServer.exe et lui
transmet chaque nouvelle ligne écrite dans un fichier de commandes (commandes de la console du
serveur, ex. /send Ethan "Clé ailée (progressive)"). Sert à donner des objets au joueur un par un
pendant un test en jeu.

Usage : python tools/server_console.py SEED.zip PORT FICHIER_COMMANDES [JOURNAL]
  echo /send Ethan "Clé ailée (progressive)" >> FICHIER_COMMANDES
"""

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

SERVER = Path(r"D:\Archipelago\ArchipelagoServer.exe")


def main():
    seed, port, commands = str(Path(sys.argv[1]).resolve()), sys.argv[2], Path(sys.argv[3]).resolve()
    log = Path(sys.argv[4]) if len(sys.argv) > 4 else commands.with_suffix(".log")
    commands.write_text("", encoding="utf-8")
    out = log.open("a", encoding="utf-8", errors="replace")
    proc = subprocess.Popen([str(SERVER), "--port", port, seed], stdin=subprocess.PIPE,
                            stdout=out, stderr=subprocess.STDOUT, cwd=str(SERVER.parent),
                            env={**os.environ, "PYTHONUNBUFFERED": "1"})
    done = 0

    def watch():
        nonlocal done
        while proc.poll() is None:
            lines = commands.read_text(encoding="utf-8-sig", errors="replace").splitlines()
            for line in lines[done:]:
                if line.strip():
                    out.write(f"\n>>> {line}\n")
                    out.flush()
                    proc.stdin.write((line + "\n").encode("utf-8"))
                    proc.stdin.flush()
            done = len(lines)
            time.sleep(0.5)
    threading.Thread(target=watch, daemon=True).start()
    proc.wait()


if __name__ == "__main__":
    main()
