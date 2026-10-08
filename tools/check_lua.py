"""
Vérifie que les scripts Lua du client compilent, avec un vrai interpréteur Lua (via lupa).

Usage : pip install lupa, puis python tools/check_lua.py

(luaparser, utilisé avant, a laissé passer une chaîne coupée par un retour à la ligne que
REFramework a refusée le 2026-09-25.)
"""

import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
compile_check = LuaRuntime().eval("function(s, n) local f, e = load(s, n) return f ~= nil, e end")

failed = False
for path in sorted((ROOT / "client" / "reframework" / "autorun").rglob("*.lua")):
    # Marge de 4 variables locales (2026-10-08) : la version de Lua de lupa compte moins de variables
    # cachées dans les boucles que celle de REFramework ; un fichier à la limite des 200 locales
    # passait ici et était refusé en jeu (« too many local variables »).
    source = "local _marge1, _marge2, _marge3, _marge4 " + path.read_text(encoding="utf-8")
    ok, err = compile_check(source, str(path.relative_to(ROOT)))
    print(f"{'OK    ' if ok else 'ERREUR'} {path.relative_to(ROOT)}" + ("" if ok else f" : {err}"))
    failed = failed or not ok

# Garde-fou (2026-09-26) : deux fois, un correctif inséré après la DÉFINITION d'une fonction
# au lieu de son APPEL a enfermé du code dans une autre fonction (surveillance invisible).
# On refuse toute fonction locale imbriquée dans le client principal.
try:
    from luaparser import ast as lua_ast, astnodes
    funcs = (astnodes.Function, astnodes.LocalFunction, astnodes.AnonymousFunction, astnodes.Method)
    main = ROOT / "client" / "reframework" / "autorun" / "re_village_ap_client.lua"
    nested = []

    def walk(node, depth, parent):
        if isinstance(node, astnodes.LocalFunction) and depth > 0:
            nested.append(f"{node.name.id} (dans {parent})")
        for v in vars(node).values():
            kids = [v] if isinstance(v, astnodes.Node) else (
                [x for x in v if isinstance(x, astnodes.Node)] if isinstance(v, list) else [])
            for k in kids:
                walk(k, depth + (1 if isinstance(node, funcs) else 0),
                     node.name.id if isinstance(node, astnodes.LocalFunction) else parent)

    walk(lua_ast.parse(main.read_text(encoding="utf-8")), 0, None)
    if nested:
        print("ERREUR fonctions locales imbriquées (code mal inséré ?) : " + ", ".join(nested))
        failed = True
except ImportError:
    print("(luaparser absent : vérification des fonctions imbriquées sautée)")

sys.exit(1 if failed else 0)
