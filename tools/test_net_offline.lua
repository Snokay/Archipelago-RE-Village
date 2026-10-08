--[[
    Test hors jeu du module réseau (client/reframework/autorun/re_village_ap/net.lua), dans les
    mêmes conditions que le jeu : un Lua 5.4.3 (la version de REFramework) qui charge
    lua-apclientpp.dll (qui embarque son propre Lua 5.4.7).

    Prérequis : un serveur Archipelago de TEST sur localhost:38283 avec un slot "Ethan" (jamais celui de la partie), et un
    lua543.exe compilé depuis lua-5.4.3 (python -m ziglang cc ... voir docs/README.md).
    Lancer depuis le dossier client/ (pour trouver la DLL) :
        lua543.exe ../tools/test_net_offline.lua
]]

package.path = "reframework/autorun/?.lua;" .. package.path
local net = require("re_village_ap/net")

local function say(...) print(os.date("%H:%M:%S"), ...) io.stdout:flush() end
local function sleep(s) local t = os.clock() + s while os.clock() < t do end end
local function fail(msg) say("ÉCHEC : " .. msg) os.exit(1) end

if net.load_error() then fail("DLL : " .. net.load_error()) end
net.game_name = "Resident Evil Village"
net.connect("localhost:38283", "Ethan", "") -- serveur de TEST, jamais celui de la partie

local checked, connected = {}, false
for _ = 1, 200 do
    for _, ev in ipairs(net.poll()) do
        if ev.kind == "connected" then connected = true
        elseif ev.kind == "checked" then for _, id in ipairs(ev.ids) do checked[id] = true end
        elseif ev.kind == "refused" or ev.kind == "error" then say(ev.kind, ev.text) end
    end
    if connected then break end
    sleep(0.05)
end
if not connected then fail("pas de connexion") end

-- Une location V2 quelconque : envoyée deux fois (le 2e envoi = check déjà validé, le scénario
-- des freezes du 2026-09-25), puis nos tables sont relues côté 5.4.3.
local id = net.get_location_id("Boutique du Duc - Duc - Plat : Pilaf complet")
say("get_location_id :", id)
if not id or id < 0 then fail("location V2 inconnue du serveur") end
local ids = { id }
for _ = 1, 2 do
    if not net.location_checks(ids) then fail("location_checks") end
    for _ = 1, 20 do net.poll() sleep(0.05) end
end
local c = 0
for _ in ipairs(ids) do c = c + 1 end
for _ in pairs(checked) do c = c + 1 end
say("OK : aucun blocage, tables lisibles (" .. c .. " parcours)")
net.disconnect()
