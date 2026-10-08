--[[
    Test hors jeu du client complet (re_village_ap_client.lua) avec un faux REFramework, sous
    Lua 5.4.3 (même version que REFramework) + la vraie lua-apclientpp.dll + un vrai serveur.

    Vérifie : connexion depuis le menu, réception des checks validés, dons d'items en jeu,
    et que la boucle tourne des centaines de fois sans blocage.

    Prérequis : serveur Archipelago de TEST sur localhost:38283 (slot "Ethan") -- jamais le serveur de la partie (38281), lua543.exe, et
    tools/test_data.lua généré par : python tools/make_test_data.py
    Lancer depuis client/ :  lua543.exe ../tools/test_client_offline.lua
]]

package.path = "reframework/autorun/?.lua;../tools/?.lua;" .. package.path
local DATA = require("test_data") -- locations/items convertis en tables Lua

local function say(...) print(os.date("%H:%M:%S"), ...) io.stdout:flush() end
local function sleep(s) local t = os.clock() + s while os.clock() < t do end end

-- Faux objets du jeu : juste assez pour que le mod se croie "en jeu" et puisse donner des items.
local given = {}
local function obj(methods)
    return { call = function(self, name, ...) local f = methods[name]; if f then return f(...) end end,
             get_field = function() return nil end }
end
local money = 100000
local inventory = obj({
    get_items = function() return obj({ get_Count = function() return 0 end }) end,
    addMoney = function(n) given[#given + 1] = "Lei x" .. n; money = money + n end,
    getMoney = function() return money end,
    setMoney = function(n) money = n end,
})
local chapter, ending = "Chapter2_2", false
local full = false -- mallette pleine : createAndAddItem renvoie nil
local singletons = {
    ["app.GUIManager"] = obj({ get_isEnableInGameFlow = function() return true end,
                               get_isEnableEndingFlow = function() return ending end }),
    ["app.SceneTransitionManager"] = obj({ get_CurrentChapter = function() return chapter end }),
    ["app.InventoryManager"] = obj({
        get_activeInventory = function() return inventory end,
        createAndAddItem = function(id, n) if full then return nil end given[#given + 1] = id .. " x" .. n; return {} end,
    }),
}

log = { info = function(m) print("  [log] " .. m) end, warn = print, error = print }
json = {
    load_file = function(p)
        if p:find("locations.json") then return DATA.locations end
        if p:find("items.json") then return DATA.items end
        return nil
    end,
    dump_file = function() return true end,
    dump_string = function() return "{}" end,
}
-- Les hooks posés par le mod sont capturés par nom de méthode, pour les déclencher à la main.
local hooks = {}
sdk = {
    find_type_definition = function(type_name)
        return { get_method = function(_, name)
            return { name = name, type_name = type_name }
        end }
    end,
    get_managed_singleton = function(name) return singletons[name] end,
    hook = function(method, pre, post) hooks[method.type_name .. "." .. method.name] = { pre = pre, post = post } end,
    to_int64 = function(x) return x end,
    to_managed_object = function(x) return x end,
    to_ptr = function(x) return x end,
    PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = 1 },
}
local update, draw_ui
re = setmetatable({
    on_pre_application_entry = function(_, f) update = f end,
    on_frame = function() end,
    on_draw_ui = function(f) draw_ui = f end,
}, { __index = function() return function() end end }) -- on_script_reset, etc. : sans effet ici
local press = nil
imgui = setmetatable({
    tree_node = function() return true end,
    button = function(label) return label == press end,
    input_text = function(_, v) return false, v end,
}, { __index = function() return function() end end })

os.execute("mkdir re_village_ap_client 2> NUL")
dofile("reframework/autorun/re_village_ap_client.lua")

-- Remplir le slot puis cliquer "Se connecter" dans le menu.
local real_input = imgui.input_text
imgui.input_text = function(label, v)
    if label == "Slot" then return true, "Ethan" end
    if label == "Serveur" then return true, "localhost:38283" end -- serveur de TEST
    return false, v
end
press = "Se connecter"; draw_ui(); press = nil
imgui.input_text = real_input

local function run(n) for _ = 1, n do update(); sleep(0.01) end end
run(150)

-- Clé ailée progressive (2026-09-30, seed avec objets clés) : 3 exemplaires reçus = niveaux 1, 2
-- puis 3. Faux objets ajoutés à la réception du réseau (ID AP lu dans les données de test).
-- Lancement à part (argument "cle") : les faux objets (index 900000+) font passer le dernier
-- index donné au-delà des vrais, qui seraient ensuite ignorés par le reste du test.
local net = package.loaded["re_village_ap/net"]
local crow_id = DATA.crow_key_ap_id
if (arg or {})[1] ~= "cle" then
    say("clé ailée : testée à part (argument cle)")
elseif crow_id and net.get_item_name(crow_id) == "Clé ailée (progressive)" then
    local real_poll, fake = net.poll, {}
    for n = 1, 3 do fake[n] = { kind = "item", index = 900000 + n, item = crow_id, player = 1 } end
    net.poll = function() local evs = real_poll() for _, e in ipairs(fake) do evs[#evs + 1] = e end fake = {} return evs end
    local first = #given + 1
    run(400)
    net.poll = real_poll
    local levels = {}
    for i = first, #given do
        local id = tonumber(given[i]:match("^(%d+) x"))
        if id == 808039580 or id == 185799830 or id == 360286557 or id == 847933194 then levels[#levels + 1] = id end
    end
    say("clé ailée : objets donnés " .. table.concat(levels, ", "))
    if levels[#levels] ~= 360286557 then say("ÉCHEC : le 3e exemplaire ne donne pas le niveau 3") os.exit(1) end
    say("OK") os.exit(0)
else
    say("ÉCHEC : clé ailée absente de cette seed") os.exit(1)
end


-- Changement d'arme normal (2026-09-26) : requestUseItem n'est bloqué que pour une arme-check
-- ramassée il y a moins de 3 s ; ici aucune, donc l'appel doit passer.
local use_item = hooks["app.PlayerOrder.requestUseItem"]
say("hook requestUseItem posé :", use_item ~= nil)
if not use_item then say("ÉCHEC : hook requestUseItem absent") os.exit(1) end
local m1911 = { call = function(_, m) if m == "get_spec" then return { get_field = function() return 2735256250 end } end end }
if use_item.pre({ nil, nil, m1911 }) ~= 0 or use_item.post("orig") ~= "orig" then
    say("ÉCHEC : changement d'arme normal bloqué") os.exit(1)
end

-- Plat cuisiné : RecipeManager.completed(recipeID) du Poisson aux herbes
local recipe = hooks["app.RecipeManager.completed"]
say("hook plat posé :", recipe ~= nil)
if recipe then recipe.pre({ nil, nil, 4293784029 }) end
run(100)

-- Achat chez le Duc : decideBuyItem(itemCore) sur la Formule : Mines (ItemID 2980903038)
local buy = hooks["app.GUIShopBuy.decideBuyItem"]
say("hook achat posé :", buy ~= nil)
if buy then
    local shop = obj({ get_buyTargetUnit = function() return nil end })
    local core = { call = function(_, m) if m == "get_spec" then return { get_field = function() return 2980903038 end } end end }
    local before = money
    local r = buy.pre({ nil, shop, core })
    say("achat : SKIP_ORIGINAL =", r == 1, "valeur renvoyée =", buy.post(0))
    run(100)
    say(string.format("Lei : %d -> %d (prix attendu 3500)", before, money))
    -- Sur un serveur de test déjà utilisé, la location peut être faite : achat normal attendu.
    if r == 1 and before - money ~= 3500 then say("ÉCHEC : prix non retiré") os.exit(1) end
end
-- Sortie du château : Chapter2_2 -> Chapter2_6, les checks restants du château partent seuls.
chapter = "Chapter2_6"
run(150)
-- (après la sortie du château : les checks envoyés ont rapporté des objets à donner)
-- Mallette pleine (bug du 2026-09-26 : M1897 redonné en boucle, file bloquée) : les objets
-- refusés vont dans le colis et la file avance ; ensuite les dons reprennent.
full = true
local refused_from = #given
run(100)
full = false
local after_full = #given
run(100)
say("mallette pleine : dons pendant =", after_full - refused_from, ", après =", #given - after_full)
if #given - after_full == 0 then say("ÉCHEC : file bloquée après une mallette pleine") os.exit(1) end
-- Fin du jeu : EndingFlow vrai pendant Chapter3_2 -> objectif fin_du_jeu atteint.
chapter = "Chapter3_2"
run(120)
-- Crash du 2026-09-26 : au goal, le release donnait ~450 items d'un coup pendant la fin.
-- Plus rien ne doit être donné pendant EndingFlow, et hors fin : un item à la fois, espacés.
ending = true
run(120) -- EndingFlow est relu une fois par seconde
local given_at_ending = #given
run(150)
if #given ~= given_at_ending then say("ÉCHEC : items donnés pendant la fin du jeu") os.exit(1) end
ending = false
local before_burst = #given
run(10) -- ~0,1 s : au plus 1 item
if #given - before_burst > 1 then say("ÉCHEC : plusieurs items donnés d'un coup") os.exit(1) end
say("boucle : sans blocage")
say("objets donnés :", #given)
for _, g in ipairs(given) do say("  " .. g) end
if #given == 0 then say("ÉCHEC : aucun item donné") os.exit(1) end
say("OK")
