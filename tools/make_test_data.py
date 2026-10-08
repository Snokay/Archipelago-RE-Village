"""Convertit les données du client en tables Lua pour tools/test_client_offline.lua."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "client" / "reframework" / "data" / "re_village_ap_client"


def to_lua(value):
    if isinstance(value, dict):
        return "{" + ", ".join(f"[{json.dumps(k)}] = {to_lua(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "{" + ", ".join(to_lua(v) for v in value) + "}"
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    return json.dumps(value, ensure_ascii=False)


tables = {name: json.loads((DATA / f"{name}.json").read_text(encoding="utf-8")) for name in ("locations", "items")}
# ID AP de la clé ailée progressive (même calcul que apworld Data.py : BASE_ID + rang dans items.json).
crow = [i for i, item in enumerate(tables["items"]) if item["name"] == "Clé ailée (progressive)"]
extra = f",\n  crow_key_ap_id = {3908000000 + crow[0]}" if crow else ""
lua = "return {\n" + ",\n".join(f"  {name} = {to_lua(data)}" for name, data in tables.items()) + extra + "\n}\n"
(ROOT / "tools" / "test_data.lua").write_text(lua, encoding="utf-8")
print("tools/test_data.lua écrit")
