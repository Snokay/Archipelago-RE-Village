--[[
    Envoie UNE location précise au serveur, pour un check raté qu'on ne peut plus ramasser
    (ex. 2026-09-26 : Plante #001 de la maison de Luiza, inaccessible après l'attaque).
    Lancer depuis client/ :
        lua543.exe ../tools/send_location.lua "Village - Plante #001 [S02]" [hôte] [slot]
    Hôte par défaut : localhost:38281 (serveur de la partie), slot "Ethan".
]]
package.path = "reframework/autorun/?.lua;" .. package.path
local net = require("re_village_ap/net")
local function sleep(s) local t = os.clock() + s while os.clock() < t do end end
local NAME = arg[1]
net.game_name = "Resident Evil Village"
net.connect(arg[2] or "localhost:38281", arg[3] or "Ethan", "")
local connected = false
for _ = 1, 200 do
    for _, ev in ipairs(net.poll()) do
        if ev.kind == "connected" then connected = true end
        if ev.kind == "refused" or ev.kind == "error" then print(ev.kind, ev.text) end
    end
    if connected then break end
    sleep(0.05)
end
if not connected then print("pas de connexion") os.exit(1) end
local id = net.get_location_id(NAME)
print("location", NAME, "id", id)
if not id or id < 0 then print("location inconnue") os.exit(1) end
net.location_checks({ id })
for _ = 1, 30 do net.poll() sleep(0.05) end
net.disconnect()
print("envoyé")
