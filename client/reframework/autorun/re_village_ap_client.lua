--[[
    Client Archipelago pour Resident Evil Village — script REFramework.

    Installation : copier le contenu du dossier client/ dans le dossier du jeu
    (lua-apclientpp.dll à côté de re8.exe, reframework/ fusionné avec celui du jeu).

    Connexion : menu REFramework (touche Inser) > "RE Village Archipelago" > hôte / slot /
    mot de passe > Se connecter. On peut se connecter au menu principal : le mod n'agit
    qu'une fois dans une partie.

    Réseau : re_village_ap/net.lua (lua-apclientpp.dll). Lire la règle en tête de ce fichier :
    la DLL embarque un autre Lua que REFramework, ce qui a causé tous les freezes du
    2026-09-25. Ce fichier ne parle JAMAIS directement à la DLL.

    Fonctionnement (tout validé en jeu le 2026-09-25, voir docs/README.md) :
    - Check : un ramassage déclenche app.InteractItemGet.InventoryInsertFinishItem. On
      retrouve le placement d'origine (app.Spawn.ItemSpawnInfo, GUID unique) par position,
      puis la location AP correspondante dans locations.json.
    - L'objet d'origine est retiré de l'inventaire (Inventory.reduceItem), puisque le joueur
      reçoit à la place l'item Archipelago de ce check.
    - Item reçu : InventoryManager.createAndAddItem(itemID, quantité, 0, 0), ou
      Inventory.addMoney pour les Lei.
    - Les checks faits hors connexion sont gardés en attente et envoyés à la reconnexion.

    Limite connue : l'index du dernier item reçu est sauvegardé tout de suite. Si le joueur
    recharge une sauvegarde plus ancienne, les items reçus entre-temps ne sont pas redonnés
    (le client RE7 gère ça en suivant les sauvegardes du jeu, à faire ici aussi).
]]

local net = require("re_village_ap/net")

local MOD_NAME = "re_village_ap_client"
-- Constantes de réglage rangées dans une table (2026-10-08) : le fichier était à la limite des
-- 200 variables locales de Lua (script refusé au chargement).
local K = {}
K.GAME_NAME = "Resident Evil Village"
K.MOD_VERSION = "0.9.1.4" -- même numéro que l'apworld (archipelago.json) ; écrit au journal et au rapport de bug
K.MAX_MATCH_DISTANCE = 5.0
-- Emplacements jumeaux (2026-10-08) : le jeu pose deux exemplaires du M1897 (table du village et
-- près de la première sauvegarde), le second devient des Lei si on a déjà le fusil. Ramasser l'un
-- valide aussi l'autre, sinon un check impossible à prendre reste affiché.
K.TWINS = { { "M1897", "M1897 #001" } }
K.twin_ids = {} -- numéro AP -> numéro AP de la jumelle (rempli par cache_location_ids)

K.SHOW_OVERLAY = true

net.game_name = K.GAME_NAME

-- Couleur imgui (0xAABBGGRR) depuis "RRGGBB".
local function color(hex)
    return tonumber("FF" .. hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2), 16)
end

---------------------------------------------------------------------------
-- Données (générées par tools/build_data_from_scans.py)
---------------------------------------------------------------------------

local locations = json.load_file(MOD_NAME .. "/locations.json") or {}
local items = json.load_file(MOD_NAME .. "/items.json") or {}

-- Clé unique de chaque location : GUID du placement (monde), "shop:<ItemID>:<n>" (boutique du
-- Duc), "recipe:<RecipeID>" (plats du Duc). location_by_guid est indexé par cette clé.
local location_by_guid = {}
local total_locations = 0
local shop_locations_by_item = {} -- ItemID -> locations de boutique, par ordre d'achat
local recipe_locations = {}       -- RecipeID -> location
for _, loc in ipairs(locations) do
    local key = loc.guid
    if loc.kind == "shop" then
        key = "shop:" .. tostring(loc.shop_item_id) .. ":" .. tostring(loc.shop_index or 0)
        shop_locations_by_item[loc.shop_item_id] = shop_locations_by_item[loc.shop_item_id] or {}
        table.insert(shop_locations_by_item[loc.shop_item_id], loc)
    elseif loc.kind == "recipe" then
        key = "recipe:" .. tostring(loc.recipe_id)
        recipe_locations[loc.recipe_id] = loc
    elseif loc.kind == "hunt" then
        -- Chasse (2026-10-07) : locations.hunts[ItemID de la viande] = checks #1, #2... dans l'ordre.
        key = "hunt:" .. tostring(loc.hunt_item_id) .. ":" .. tostring(loc.hunt_index)
        locations.hunts = locations.hunts or {}
        locations.hunts[loc.hunt_item_id] = locations.hunts[loc.hunt_item_id] or {}
        table.insert(locations.hunts[loc.hunt_item_id], loc)
    elseif loc.kind == "bossdrop" then
        -- Drop de boss (2026-09-30) : locations.boss_drops[ItemID] = checks dans l'ordre.
        key = "bossdrop:" .. tostring(loc.drop_item_id) .. ":" .. tostring(loc.drop_index)
        locations.boss_drops = locations.boss_drops or {}
        locations.boss_drops[loc.drop_item_id] = locations.boss_drops[loc.drop_item_id] or {}
        table.insert(locations.boss_drops[loc.drop_item_id], loc)
    end
    if key then
        loc.key = key
        location_by_guid[key] = loc
        total_locations = total_locations + 1
    end
end
for _, list in pairs(shop_locations_by_item) do
    table.sort(list, function(a, b) return (a.shop_index or 0) < (b.shop_index or 0) end)
end
for _, list in pairs(locations.hunts or {}) do
    table.sort(list, function(a, b) return a.hunt_index < b.hunt_index end)
end

-- Trophées des seigneurs : les combats de Dimitrescu, Beneviento et Heisenberg sont scriptés
-- (pas de registerDeadEnemy) ; ramasser leur trophée prouve leur mort (relevé 2026-09-26).
local BOSS_TROPHIES = {
    [1773855935] = "dimitrescu", -- Dimitrescu cristallisée
    [3171683355] = "beneviento", -- Angie
    [2641189703] = "moreau",     -- Yeux de Moreau
    [3784538847] = "heisenberg", -- Cerveau d'Heisenberg
}
local BOSS_KILLS = { em1302 = "moreau" } -- nom interne de l'ennemi (registerDeadEnemy)
local pending_boss_events = {}           -- rempli dans les hooks, traité dans la boucle

local item_by_name = {}
for _, item in ipairs(items) do
    item_by_name[item.name] = item
end
-- Variantes « (1) » / « (2) » d'un même objet : certains ID ne sont pas créables par le jeu
-- (LEMI (2), 3725070903 : createAndAddItem nil, pris pour « mallette pleine » et bloqué dans le
-- colis, 2026-09-29 ; la mallette du château contient en fait LEMI (1)). give_id = ID à donner.
for _, item in ipairs(items) do
    local base = item.name:match("^(.-)%s*%(%d+%)$")
    if base then
        item.variant_ids = {}
        for _, other in ipairs(items) do
            if other ~= item and other.name:match("^(.-)%s*%(%d+%)$") == base then
                item.variant_ids[#item.variant_ids + 1] = other.game_item_id
            end
        end
    end
end
if item_by_name["Compensateur de recul (LEMI) (2)"] then
    item_by_name["Compensateur de recul (LEMI) (2)"].give_id = 2255157331
end

local function full_location_name(loc)
    return loc.region .. " - " .. loc.name
end

-- Numéros AP calculés comme l'apworld (Data.load_data : BASE_ID + rang dans items.json,
-- BASE_ID + 1 000 000 000 + rang dans locations.json ; données identiques côté client). Le mod
-- marche ainsi avec une partie générée par l'apworld FR ou EN (noms différents, mêmes numéros).
do
    local BASE_ID = 3908000000
    local location_ids, item_names = {}, {}
    for i, item in ipairs(items) do
        if item.type ~= "Event" then item_names[BASE_ID + i - 1] = item.name end
    end
    for i, loc in ipairs(locations) do
        if not loc.force_item then location_ids[full_location_name(loc)] = BASE_ID + 1000000000 + i - 1 end
    end
    net.set_id_tables(location_ids, item_names)
end

---------------------------------------------------------------------------
-- Journal de diagnostic
---------------------------------------------------------------------------

-- Freeze du 2026-09-25 en ramassant un objet (le jeu se fige, sans erreur ; il ne freeze pas
-- sans le mod). Ce journal est ouvert, écrit puis fermé à chaque ligne, et on l'appelle AVANT
-- chaque étape : la dernière ligne indique où le jeu s'est figé.
-- Fichier : reframework/data/re_village_ap_client/debug_log.txt
-- Optimisation (2026-10-07, micro-gels) : le fichier était ouvert et refermé à CHAQUE ligne
-- (rafales de dizaines de lignes, fichier de 22 Mo, antivirus). Lignes gardées en mémoire et
-- écrites d'un coup toutes les 0,5 s (debug_log(nil) = écrire si c'est l'heure, appelé par la
-- boucle du jeu). Au chargement, un journal de plus de 8 Mo devient debug_log_old.txt.
local debug_log
do
    local path = MOD_NAME .. "/debug_log.txt"
    local pending, next_flush = {}, 0
    local f = io.open(path, "r")
    if f then
        local size = f:seek("end")
        f:close()
        -- os.remove / os.rename n'existent pas dans REFramework (script arrêté au chargement,
        -- 2026-10-07) : copie dans debug_log_old.txt puis journal vidé, avec io seulement.
        if size and size > 8 * 1024 * 1024 then
            pcall(function()
                local src = io.open(path, "rb")
                local data = src:read("a")
                src:close()
                local dst = io.open(MOD_NAME .. "/debug_log_old.txt", "wb")
                dst:write(data)
                dst:close()
                io.open(path, "w"):close()
            end)
        end
    end
    debug_log = function(text)
        if text ~= nil then
            pending[#pending + 1] = string.format("%s (%.3f) %s\n", os.date("%H:%M:%S"), os.clock(), text)
            if #pending < 200 then return end
        elseif #pending == 0 or os.clock() < next_flush then
            return
        end
        next_flush = os.clock() + 0.5
        local file = io.open(path, "a")
        if file then
            file:write(table.concat(pending))
            file:close()
        end
        pending = {}
    end
end

debug_log("===== script chargé (mod " .. K.MOD_VERSION .. ") =====")

---------------------------------------------------------------------------
-- Messages à l'écran
---------------------------------------------------------------------------

-- Langue des textes du mod (demande du joueur, 2026-09-26) : français si le jeu est en
-- français, anglais sinon. via.gui.GUISystem.get_MessageLanguage() (via.Language : 1 anglais,
-- 2 français dans le RE Engine), relu toutes les 5 s dans la boucle du jeu. Si la lecture
-- échoue, on reste en français. Les noms d'objets et de lieux (données de l'apworld) restent
-- en français.
local i18n = { fr = true, next_check = 0, logged = false }
local function tr(fr, en) if i18n.fr then return fr end return en end
function i18n.update()
    if os.clock() < i18n.next_check then return end
    i18n.next_check = os.clock() + 5
    local ok, lang = pcall(function()
        return sdk.call_native_func(sdk.get_native_singleton("via.gui.GUISystem"),
            sdk.find_type_definition("via.gui.GUISystem"), "get_MessageLanguage")
    end)
    if ok and type(lang) == "number" then i18n.fr, i18n.lang = lang == 2, lang end
    if not i18n.logged then
        i18n.logged = true
        local file = io.open(MOD_NAME .. "/debug_log.txt", "a")
        if file then
            file:write(string.format("langue du jeu : %s (%s) -> textes en %s\n", tostring(lang),
                ok and "ok" or "échec", i18n.fr and "français" or "anglais"))
            file:close()
        end
    end
end
-- État réseau affiché (net_status garde les valeurs françaises en interne).
-- Noms d'objets et de lieux dans les messages (2026-10-07, demande du joueur : un joueur anglais
-- ne comprend pas les noms français des données). Jeu en français : noms des données tels quels.
-- Sinon : nom de l'objet lu dans le jeu, dans sa langue (fiche ItemSpecification -> NameMessageID
-- -> via.gui.message.get), gardé en cache par langue ; lieu « <objet> #012 [S02] » : seul le nom de
-- l'objet est traduit, « Chasse - » / « Boss - » aussi. Nom introuvable : nom des données.
i18n.names = {}
function i18n.item(name)
    if i18n.fr or not name then return name end
    local cache_key = tostring(i18n.lang) .. ":" .. name
    if i18n.names[cache_key] ~= nil then return i18n.names[cache_key] or name end
    local text = nil
    pcall(function()
        local def = item_by_name[name]
        local id = def and (def.levels and def.levels[1] or def.game_item_id)
        if not id then return end
        local spec = sdk.get_managed_singleton("app.ItemSpecification"):call("findItemSpec", id)
        local guid = spec:get_field("Basic"):get_field("NameMessageID")
        text = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, guid)
    end)
    if text == "" then text = nil end
    i18n.names[cache_key] = text or false
    return text or name
end
function i18n.loc(loc)
    local name = loc and loc.name
    if i18n.fr or not name then return name end
    local prefix = ""
    for fr, en in pairs({ ["Chasse - "] = "Hunt - ", ["Boss - "] = "Boss - " }) do
        if name:sub(1, #fr) == fr then prefix, name = en, name:sub(#fr + 1) end
    end
    local base = loc.original_item
    if base and name:sub(1, #base) == base then
        name = i18n.item(base) .. name:sub(#base + 1)
    end
    return prefix .. name
end

function i18n.status(status)
    if status == "connecté" then return tr("connecté", "connected") end
    if status == "déconnecté" then return tr("déconnecté", "disconnected") end
    if status == "connexion" then return tr("connexion", "connecting") end
    return status
end

local messages = {}

local function add_message(text)
    table.insert(messages, { text = text, time = os.clock() })
    if #messages > 6 then table.remove(messages, 1) end
    log.info(string.format("[%s] %s", MOD_NAME, text))
end

---------------------------------------------------------------------------
-- État persistant, un fichier par seed + slot
---------------------------------------------------------------------------

local session = nil -- { seed, slot, file }
local state = { last_applied_index = -1, pending_checks = {}, parcel = {} }
local checked_ids = {} -- locations déjà validées côté serveur
local checked_count = 0 -- tenu à jour à part : ne jamais parcourir checked_ids depuis l'affichage

-- Crash du 2026-09-25 : parcourir checked_ids avec pairs() dans l'affichage (re.on_frame)
-- pendant que le callback réseau le modifiait (re.on_pre_application_entry) a donné
-- "invalid key to 'next'". L'erreur a interrompu la fenêtre imgui avant end_window et a fait
-- planter le jeu. Le compteur est donc maintenu à part.
local function add_checked(id)
    if id and not checked_ids[id] then
        checked_ids[id] = true
        checked_count = checked_count + 1
    end
end
local goal_sent = false

local function save_state()
    if session then json.dump_file(session.file, state) end
end

local function load_state(seed, slot)
    session = { seed = seed, slot = slot,
        file = string.format("%s/state_%s_%s.json", MOD_NAME, tostring(seed), tostring(slot)) }
    local ok, loaded = pcall(json.load_file, session.file)
    state = { last_applied_index = -1, pending_checks = {}, parcel = {} }
    if ok and type(loaded) == "table" then
        state.last_applied_index = loaded.last_applied_index or -1
        state.pending_checks = loaded.pending_checks or {}
        state.bosses = loaded.bosses or {}
        state.received_ids = loaded.received_ids or {}
        state.parcel = loaded.parcel or {}
        state.saves = loaded.saves or {}
        state.checkpoint = loaded.checkpoint
        state.tracks_saves = loaded.tracks_saves
        state.given_by_pickup = loaded.given_by_pickup
    end
    -- Toutes les sauvegardes de cette seed sont suivies (2026-09-30) : état neuf, ou aucun
    -- emplacement réel noté jusqu'ici. Alors une sauvegarde inconnue date d'AVANT la seed.
    -- La vraie partie (38281, commencée avant le suivi, emplacements notés) n'est pas concernée.
    if state.tracks_saves == nil then
        local real_slot = false
        for slot in pairs(state.saves or {}) do
            if tonumber(slot) and tonumber(slot) >= 0 then real_slot = true end
        end
        state.tracks_saves = not real_slot
    end
    state.parcel = state.parcel or {}
end

---------------------------------------------------------------------------
-- Accès au jeu
---------------------------------------------------------------------------

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

local function get_active_inventory()
    local mgr = sdk.get_managed_singleton("app.InventoryManager")
    if not mgr then return nil, nil end
    local ok, inv = pcall(function() return mgr:call("get_activeInventory") end)
    if not ok then return mgr, nil end
    return mgr, inv
end

-- "En jeu" = le GUIManager est en mode InGame ET un inventaire est actif, depuis au moins
-- 3 secondes. On peut se connecter depuis le menu principal, mais le mod n'agit (items,
-- retraits, affichage) qu'une fois dans une partie (demande du joueur, 2026-09-25, après un
-- crash au menu principal). Ce mode est aussi coupé pendant les menus et animations de
-- ramassage, ce qui évite de toucher à l'inventaire à ces moments-là.
-- L'état est calculé dans la boucle du jeu (UpdateBehavior) et seulement LU dans
-- l'affichage (on_frame), qui tourne sur un autre fil : l'affichage n'appelle jamais le jeu.
K.IN_GAME_SETTLE_SECONDS = 3.0
local in_game = false
local in_game_since = nil

local function update_in_game_state()
    local ok, flag = pcall(function()
        return sdk.get_managed_singleton("app.GUIManager"):call("get_isEnableInGameFlow")
    end)
    local _, inv = get_active_inventory()
    local raw = ok and flag == true and inv ~= nil
    -- Présentation plein écran ouverte (2026-10-01 : plantage en retirant le vrai LEMI pendant sa
    -- présentation) : pas « en jeu », rien n'est retiré ni donné avant sa fermeture.
    if raw then
        local ok_d, detail = pcall(function()
            return sdk.get_managed_singleton("app.GUIManager"):call("get_isEnableDetailSearchFlow")
        end)
        if ok_d and detail == true then raw = false end
    end
    if not raw then
        in_game_since = nil
        in_game = false
        return
    end
    in_game_since = in_game_since or os.clock()
    in_game = os.clock() - in_game_since >= K.IN_GAME_SETTLE_SECONDS
end

local function is_in_game()
    return in_game
end

-- Relevé complet de la mallette (diagnostic des achats-checks, 2026-09-26) : "ItemID x pile"
-- pour chaque emplacement, pour voir où le jeu range un objet acheté.
local function inventory_dump()
    local _, inv = get_active_inventory()
    if not inv then return "inventaire indisponible" end
    local parts = {}
    pcall(function()
        local list = inv:call("get_items")
        for i = 0, list:call("get_Count") - 1 do
            local work = list:call("get_Item", i):call("get_work")
            parts[#parts + 1] = tostring(work:call("get_itemID")) .. "x" .. tostring(work:call("get_stackSize"))
                .. "@" .. tostring(work:call("get_slotNo")) .. "/" .. tostring(work:call("get_lastSlotNo"))
                .. "/" .. tostring(work:call("get_centeringSafeSlotNo"))
        end
    end)
    local max = nil
    pcall(function() max = inv:call("getMaxSlotCount") end)
    return #parts .. " emplacements, " .. tostring(max) .. " cases : " .. table.concat(parts, " ")
end

-- Quantité totale d'un ItemID dans l'inventaire actif (somme des piles).
local function inventory_quantity(item_id)
    local _, inv = get_active_inventory()
    if not inv then return nil end
    local total = 0
    local ok = pcall(function()
        local list = inv:call("get_items")
        for i = 0, list:call("get_Count") - 1 do
            local work = list:call("get_Item", i):call("get_work")
            if work:call("get_itemID") == item_id then
                total = total + work:call("get_stackSize")
            end
        end
    end)
    return ok and total or nil
end

local function get_scene()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
end

local function find_all_components(type_name)
    local ok, comps = pcall(function()
        return get_scene():call("findComponents(System.Type)", sdk.typeof(type_name))
    end)
    if not ok or not comps then return {} end
    return comps:get_elements()
end

local function get_item_id_from_core(item_core)
    if not item_core then return nil end
    local ok, id = pcall(function() return item_core:call("get_spec"):get_field("ItemID") end)
    return ok and id or nil
end

local function get_gameobject_identity(go, ident)
    ident = ident or {}
    if not go then return ident end
    pcall(function() ident.item_object = go:call("get_Name") end)
    pcall(function() ident.folder_path = go:call("get_Folder"):call("get_Path") end)
    pcall(function()
        local transform = go:call("get_Transform")
        local pos = transform:call("get_Position")
        ident.item_position = { round2(pos.x), round2(pos.y), round2(pos.z) }
        local parent_tf = transform:call("get_Parent")
        if parent_tf then
            ident.parent_object = parent_tf:call("get_GameObject"):call("get_Name")
        end
    end)
    return ident
end

-- Salles de la carte (2026-09-25) : ItemSpawnInfo.MapRoomNames[] (app.MapRoomName,
-- MapRoomNameHash) -> MapManager.findRoomData(hash) -> RoomUnit.RoomNameGUID -> texte.
local room_name_cache = {}

local function guid_text(guid)
    local ok, text = pcall(function()
        return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, guid)
    end)
    return ok and text or nil
end

local function room_name(hash)
    if not hash or hash == 0 then return nil end
    if room_name_cache[hash] ~= nil then return room_name_cache[hash] or nil end
    local name = nil
    pcall(function()
        local unit = sdk.get_managed_singleton("app.MapManager"):call("findRoomData", hash)
        if unit then name = guid_text(unit:get_field("RoomNameGUID")) end
    end)
    if name == "" then name = nil end
    room_name_cache[hash] = name or false
    return name
end

local function get_spawn_info_identity(spawn_info)
    local ident = {}
    pcall(function() ident.guid = tostring(spawn_info:call("get_myGUID"):call("ToString()")) end)
    pcall(function() ident.item_id = spawn_info:call("get_spawnItemId") end)
    pcall(function() ident.stack = spawn_info:call("get_spawnStackNum") end)
    pcall(function() ident.completed = spawn_info:call("get_isCompleted") end)
    pcall(function() ident.spawned = spawn_info:call("get_isSpawned") end)
    pcall(function() get_gameobject_identity(spawn_info:call("get_GameObject"), ident) end)
    pcall(function()
        local rooms = spawn_info:get_field("MapRoomNames")
        if rooms and rooms:get_size() > 0 then
            ident.room_hash = rooms:get_element(0):get_field("MapRoomNameHash")
            ident.room = room_name(ident.room_hash)
        end
    end)
    return ident
end

-- Placement d'origine d'un objet ramassé : le placement le plus proche (< 5 m) qui contient
-- le même ItemID. Comparer les objets eux-mêmes ne marche pas depuis Lua (testé le
-- 2026-09-25) ; la position a donné 0 m pour une ferraille, 3,2 m pour une spinelle.
local function find_spawn_info_for(go, item_id)
    local go_pos = go and get_gameobject_identity(go).item_position
    if not go_pos or not item_id then return nil, nil end
    local best, best_dist = nil, K.MAX_MATCH_DISTANCE

    for _, spawn_info in ipairs(find_all_components("app.Spawn.ItemSpawnInfo")) do
        local ok_id, sid = pcall(function() return spawn_info:call("get_spawnItemId") end)
        if ok_id and sid == item_id then
            local pos = get_gameobject_identity(spawn_info:call("get_GameObject")).item_position
            if pos then
                local dx, dy, dz = pos[1] - go_pos[1], pos[2] - go_pos[2], pos[3] - go_pos[3]
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist < best_dist then best, best_dist = spawn_info, dist end
            end
        end
    end
    return best, best_dist
end

-- Renvoie true si l'objet est donné, sinon false et la raison : "pas_pret" (inventaire pas
-- encore disponible, on réessaie) ou "plein" (le jeu refuse l'objet : mallette pleine).
-- Valise (agrandissement de mallette) : test en jeu du 2026-09-26, createAndAddItem agrandit
-- bien la grille mais sans replacer les objets (objets superposés). On passe par
-- Inventory.addExtendLevel(), la montée de niveau de la mallette.
local VALISE_ITEM_ID = 269218988
-- Achat d'une Valise qui est un check : le jeu agrandit la mallette PENDANT l'achat (avant
-- decideBuyItem). Le hook d'addExtendLevel refuse l'agrandissement tant que cette date n'est
-- pas passée, sauf pour une Valise donnée par le mod (own_extend).
local block_extend_until = -math.huge
local own_extend = false
-- Niveau de mallette relevé au début de l'achat d'une Valise-check (avant l'agrandissement du
-- jeu), remis 2 s après l'achat (hook de blocage abandonné : freeze au démarrage).
local valise_level_before = nil

-- Recettes débloquées (onglet Confection) : InventoryManager.craftStateUnits, liste de
-- CraftStateUnit { ItemID, IsNew }. Acheter une Formule-check débloquait la recette en plus
-- de l'objet Archipelago (test du 2026-09-26) : on relève la liste au début de chaque achat
-- et on retire, après un achat-check, les recettes apparues pendant l'achat.
local function craft_state_ids()
    local ids, names = {}, {}
    local ok, err = pcall(function()
        local list = sdk.get_managed_singleton("app.InventoryManager"):call("get_craftStateUnits")
        for i = 0, list:call("get_Count") - 1 do
            local id = list:call("get_Item", i):get_field("ItemID")
            ids[id] = true
            names[#names + 1] = tostring(id)
        end
    end)
    debug_log(string.format("formule : recettes débloquées (%s) : %d : %s", ok and "ok" or tostring(err),
        #names, table.concat(names, " ")))
    return ids
end

local function remove_new_craft_states(before)
    local removed = {}
    pcall(function()
        local list = sdk.get_managed_singleton("app.InventoryManager"):call("get_craftStateUnits")
        for i = list:call("get_Count") - 1, 0, -1 do
            local id = list:call("get_Item", i):get_field("ItemID")
            if not before[id] then
                list:call("RemoveAt", i)
                removed[#removed + 1] = tostring(id)
            end
        end
    end)
    return removed
end
local craft_before_buy = nil

-- 3e essai (2026-09-26) : craftStateUnits ne contient que des marqueurs "nouveau". Une formule
-- vit dans les recettes de l'inventaire (Inventory.findRecipes, objets cachés) et dans
-- l'historique des objets obtenus (InventoryManager.histories).
local function recipe_count(item_id)
    local n = 0
    pcall(function()
        local _, inv = get_active_inventory()
        local list = inv:call("findRecipes", false)
        for i = 0, list:call("get_Count") - 1 do
            if list:call("get_Item", i):call("get_itemID") == item_id then n = n + 1 end
        end
    end)
    return n
end

local function has_history(item_id)
    local ok, v = pcall(function()
        return sdk.get_managed_singleton("app.InventoryManager"):call("hasHistory", item_id)
    end)
    return ok and v or false
end

-- Tous les inventaires du jeu (InventoryManager.inventories, Dictionary<InventoryName, Inventory>).
local function all_inventories()
    local result = {}
    pcall(function()
        local dict = sdk.get_managed_singleton("app.InventoryManager"):call("get_inventories")
        local entries = dict:get_field("_entries") or dict:get_field("entries")
        for _, entry in ipairs(entries:get_elements()) do
            local inv = entry:get_field("value")
            if inv then result[#result + 1] = inv end
        end
    end)
    return result
end

-- Retire la formule achetée comme check : recettes (cachées comprises), dans TOUS les
-- inventaires (4e essai : la recette restait en Confection avec 0 recette dans l'inventaire
-- actif), et historique.
local function forget_recipe(item_id, recipes_before, history_before)
    local removed = 0
    pcall(function()
        local _, inv = get_active_inventory()
        local list = inv:call("findRecipes", false)
        local extra = recipe_count(item_id) - (recipes_before or 0)
        for i = list:call("get_Count") - 1, 0, -1 do
            if extra <= 0 then break end
            local work = list:call("get_Item", i)
            if work:call("get_itemID") == item_id then
                inv:call("removeItem", work, true)
                removed = removed + 1
                extra = extra - 1
            end
        end
    end)
    local report = {}
    for n, other in ipairs(all_inventories()) do
        pcall(function()
            local found = 0
            local list = other:call("findRecipes", false)
            for i = list:call("get_Count") - 1, 0, -1 do
                local work = list:call("get_Item", i)
                if work:call("get_itemID") == item_id then
                    found = found + 1
                    other:call("removeItem", work, true)
                    removed = removed + 1
                end
            end
            local has = other:call("hasItem", item_id, true, false)
            report[#report + 1] = string.format("inv%d: %d recette(s) retirée(s), possède encore %s", n, found, tostring(has))
        end)
    end
    debug_log(string.format("formule %s : %d inventaire(s) : %s", tostring(item_id), #report, table.concat(report, " ; ")))
    local hist_removed = false
    if not history_before then
        hist_removed = pcall(function()
            sdk.get_managed_singleton("app.InventoryManager"):call("get_histories"):call("Remove", item_id)
        end)
    end
    debug_log(string.format("formule %s : %d recette(s) retirée(s), historique retiré : %s, reste %d recette(s), historique %s",
        tostring(item_id), removed, tostring(hist_removed), recipe_count(item_id), tostring(has_history(item_id))))
end
local recipe_state_at_buy = nil

-- Après un changement de niveau de mallette : la "dernière case" des objets est alignée sur
-- leur case actuelle, sinon une partie revient à l'ancienne (objets superposés).
local function sync_last_slots(inv)
    return pcall(function()
        local list = inv:call("get_items")
        for i = 0, list:call("get_Count") - 1 do
            local work = list:call("get_Item", i):call("get_work")
            local slot = work:call("get_slotNo")
            if slot and slot >= 0 then
                work:call("set_lastSlotNo", slot)
                work:call("set_centeringSafeSlotNo", slot)
            end
        end
    end)
end

-- item (facultatif) : fiche items.json ; si le jeu refuse l'ID, ses variantes sont essayées
-- (voir give_id, plus haut).
-- Niveau de mallette borné (2026-10-08 : Valise donnée 243 fois en boucle -> niveau très au-delà
-- du maximum du jeu, Level1..Level6 -> 126 cases, sauvegarde figée). Renvoie le niveau actuel et
-- le maximum (champ V des app.InventoryExtendLevel.Value) ; ramène au maximum si dépassé.
-- (rangée dans i18n, table déclarée tôt : limite de 200 variables locales atteinte)
function i18n.extend_level_info(inv, clamp)
    local cur, max_v, max_value = nil, nil, nil
    pcall(function()
        cur = inv:call("get_extendLevel"):get_field("V")
        max_value = sdk.find_type_definition("app.InventoryExtendLevel"):get_field("Level6"):get_data(nil)
        max_v = max_value:get_field("V")
    end)
    if clamp and cur and max_v and cur > max_v then
        local ok = pcall(function() inv:call("set_extendLevel", max_value) end)
        debug_log(string.format("valise : niveau de mallette %s au-delà du maximum %s -> ramené au maximum (%s)",
            tostring(cur), tostring(max_v), ok and "ok" or "échec"))
        cur = max_v
    end
    return cur, max_v
end

local function give_item(item_id, count, item)
    local mgr, inv = get_active_inventory()
    if not mgr then return false, "pas_pret" end
    if item_id == VALISE_ITEM_ID then
        if not inv then return false, "pas_pret" end
        local before = nil
        pcall(function() before = inv:call("get_extendLevel") end)
        local cur, max_v = i18n.extend_level_info(inv, true)
        if cur and max_v and cur >= max_v then
            debug_log("valise : mallette déjà au niveau maximum, pas d'agrandissement")
            return true
        end
        -- La réussite ne dépend QUE de addExtendLevel : tout le reste est protégé à part, pour
        -- ne jamais réessayer (et agrandir la mallette en boucle) après un agrandissement fait.
        own_extend = true
        local ok = pcall(function() inv:call("addExtendLevel") end)
        own_extend = false
        if not ok then return false, "pas_pret" end
        pcall(function()
            -- 2e test du 2026-09-26 : addExtendLevel renumérote bien les cases (9 -> 11
            -- colonnes), mais 2 s plus tard une partie des objets revenait à son ANCIEN numéro
            -- (objets superposés). On aligne leur "dernière case" sur la nouvelle.
            -- Protégé à part : un échec ici ne doit pas faire croire que la Valise n'a pas été
            -- donnée (le mod réessaierait et agrandirait la mallette en boucle).
            local sync_ok, sync_err = sync_last_slots(inv)
            debug_log("valise : dernières cases alignées : " .. (sync_ok and "ok" or tostring(sync_err)))
            -- Objets superposés après une Valise reçue (2026-09-27) : l'affichage de la mallette
            -- (GUIInventory) garde ses anciennes positions ; on le reconstruit pour la nouvelle
            -- taille, comme le jeu (setupItemExtend).
            local rebuilt = 0
            for _, gui in ipairs(find_all_components("app.GUIInventory")) do
                if pcall(function() gui:call("setupItemExtend") end) then rebuilt = rebuilt + 1 end
            end
            debug_log("valise : affichage de la mallette reconstruit (" .. rebuilt .. ")")
            debug_log(string.format("valise : niveau de mallette %s -> %s, cases max %s", tostring(before),
                tostring(inv:call("get_extendLevel")), tostring(inv:call("getMaxSlotCount"))))
        end)
        -- (2026-10-08 : une ligne ici utilisait shop_ui, pas encore défini à cet endroit du fichier
        -- -> erreur APRÈS l'agrandissement -> Valise redonnée en boucle, mallette à 126 cases.
        -- Retirée ; réparation de la mallette : bouton des outils.)
        return true
    end
    -- Mallette pleine (2026-10-08, cause de la mallette corrompue : objets donnés mallette pleine,
    -- posés sur des cases occupées -> confection figée, ajouts refusés) : le jeu ne refuse PAS
    -- l'ajout. Pour un objet qui prend une case (munitions, soins, armes), on demande d'abord une
    -- case libre au jeu ; aucune et pas de pile existante -> "plein" (colis, redonné plus tard).
    if item and (item.type == "Ammo" or item.type == "Recovery" or item.type == "Weapon") and inv then
        local free = nil
        pcall(function()
            local res = inv:call("getBlankSlotNo", item_id, false)
            free = res and res:call("get_slotNo")
        end)
        if free ~= nil and free < 0 and (inventory_quantity(item_id) or 0) == 0 then
            debug_log("don : " .. tostring(item.name) .. " : aucune case libre dans la mallette")
            return false, "plein"
        end
    end
    local ok, core = pcall(function() return mgr:call("createAndAddItem", item_id, count, 0, 0) end)
    if not ok then return false, "pas_pret" end
    if core == nil and item and not item.give_id then
        for _, vid in ipairs(item.variant_ids or {}) do
            local ok_v, core_v = pcall(function() return mgr:call("createAndAddItem", vid, count, 0, 0) end)
            if ok_v and core_v ~= nil then
                item.give_id = vid
                debug_log(string.format("don : %s donné sous l'ID %s (variante)", item.name, tostring(vid)))
                return true
            end
        end
    end
    if core == nil then return false, "plein" end
    return true
end

local function give_money(amount)
    local _, inv = get_active_inventory()
    if not inv then return false end
    return pcall(function() inv:call("addMoney", amount) end)
end

---------------------------------------------------------------------------
-- Envoi des checks
---------------------------------------------------------------------------

local function is_connected()
    return net.is_connected()
end

-- Difficulté imposée par le yaml (option "difficulty", transmise en slot_data). Lue via
-- app.GameRecordManager.getDifficulty(false). Valeurs SUPPOSÉES d'après app.RankDifficult
-- (Easy 0, Normal 1, Hard 2, VeryHard 3) : à confirmer en jeu (valeur affichée dans le menu).
-- Hashs relevés en jeu le 2026-09-26 (difficulties.json, GameOptionManager).
K.DIFFICULTY_VALUES = {
    casual = 2081395632,             -- Facile
    standard = 1948795948,
    hardcore = 4054003385,
    village_des_ombres = 3214231311,
}
local required_difficulty = nil -- nom venant du slot_data ; nil ou "au_choix" = pas de contrainte
local game_difficulty = nil     -- valeur lue dans le jeu

-- Test du 2026-09-26 : getDifficulty renvoie un identifiant HACHÉ (2081395632 en Casual), pas
-- 0-3. La liste des difficultés (hash + nom affiché) est dans app.GameOptionManager
-- .get_userdatas() -> Difficulties (Difficulty, MessageGUID). On la lit une fois, on l'écrit
-- dans difficulties.json et on affiche le nom de la difficulté en cours.
local difficulty_names = nil -- hash -> nom affiché

local function load_difficulty_names()
    if difficulty_names then return end
    local names, list = {}, {}
    local ok = pcall(function()
        local datas = sdk.get_managed_singleton("app.GameOptionManager"):call("get_userdatas")
        for i = 0, datas:call("get_Count") - 1 do
            local diffs = datas:call("get_Item", i):get_field("Difficulties")
            if diffs then
                for j = 0, diffs:call("get_Count") - 1 do
                    local u = diffs:call("get_Item", j)
                    local hash = u:get_field("Difficulty")
                    local text = nil
                    pcall(function()
                        text = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
                            :call(nil, u:get_field("MessageGUID"))
                    end)
                    names[hash] = text or "?"
                    list[#list + 1] = { order = j, hash = hash, name = text }
                end
            end
        end
    end)
    if ok and #list > 0 then
        difficulty_names = names
        json.dump_file(MOD_NAME .. "/difficulties.json", list)
    end
end

local function read_game_difficulty()
    local ok, v = pcall(function()
        return sdk.get_managed_singleton("app.GameRecordManager"):call("getDifficulty", false)
    end)
    return ok and v or nil
end

-- Vrai si les checks doivent être ignorés : partie pas dans la difficulté du yaml.
local function wrong_difficulty()
    local expected = required_difficulty and K.DIFFICULTY_VALUES[required_difficulty]
    if expected == nil or game_difficulty == nil then return false end
    return game_difficulty ~= expected
end

-- Numéros AP des locations, calculés une fois à la connexion.
local location_id_by_guid = {}

local function cache_location_ids()
    location_id_by_guid = {}
    local n = 0
    for key, loc in pairs(location_by_guid) do
        local id = net.get_location_id(full_location_name(loc))
        -- Le paquet de données connaît TOUTES les locations du jeu ; seules celles de la seed
        -- comptent (net.seed_locations, lu à la connexion), sinon le serveur coupe au scout.
        if id and net.seed_locations and not net.seed_locations[id] then id = nil end
        if id then
            location_id_by_guid[key] = id
            n = n + 1
        end
    end
    K.twin_ids = {}
    local by_name = {}
    for key, loc in pairs(location_by_guid) do by_name[loc.name] = location_id_by_guid[key] end
    for _, pair in ipairs(K.TWINS) do
        local a, b = by_name[pair[1]], by_name[pair[2]]
        if a and b then K.twin_ids[a] = b; K.twin_ids[b] = a end
    end
    debug_log(string.format("numéros de location en cache : %d / %d", n, total_locations))
    -- Seules les locations de CETTE seed comptent (boutique désactivée, etc.).
    if n > 0 then total_locations = n end
end

local function get_location_id(loc)
    return location_id_by_guid[loc.key]
end

local function send_pending_checks()
    if not is_connected() or #state.pending_checks == 0 then return end
    local ids = {}
    for _, guid in ipairs(state.pending_checks) do
        local id = location_id_by_guid[guid]
        if id and not checked_ids[id] then table.insert(ids, id) end
    end
    for i = 1, #ids do
        local twin = K.twin_ids[ids[i]]
        if twin and not checked_ids[twin] then table.insert(ids, twin) end
    end
    if #ids > 0 then
        debug_log(string.format("LocationChecks (%d)...", #ids))
        net.location_checks(ids)
        debug_log("LocationChecks terminé")
        for _, id in ipairs(ids) do add_checked(id) end
    end
    -- La file n'est vidée que quand le serveur confirme (voir mark_checked).
end

-- Appelée depuis la boucle principale uniquement, JAMAIS depuis le hook de ramassage :
-- le 2026-09-25, un envoi fait pendant le ramassage (check déjà validé) a figé le jeu entier
-- (journal de diagnostic : dernière ligne "envoi du check").
local function queue_check(loc)
    if wrong_difficulty() then
        add_message(tr("Check ignoré : la partie n'est pas en difficulté ", "Check ignored: the game is not on difficulty ") .. tostring(required_difficulty))
        debug_log("check ignoré (mauvaise difficulté) : " .. loc.name)
        return
    end
    local id = get_location_id(loc)
    debug_log(string.format("queue_check : id=%s, déjà validé=%s", tostring(id), tostring(id and checked_ids[id] or false)))
    do
        if id and checked_ids[id] then
            debug_log("check déjà validé, pas de renvoi : " .. loc.name)
            return
        end
    end
    for _, key in ipairs(state.pending_checks) do
        if key == loc.key then
            debug_log("queue_check : déjà en attente")
            return
        end
    end
    table.insert(state.pending_checks, loc.key)
    debug_log("queue_check : sauvegarde de l'état")
    save_state()
    debug_log("queue_check : envoi")
    send_pending_checks()
end

-- Checks détectés par le hook de ramassage, traités à la frame suivante.
local picked_locations = {}
picked_locations.for_rooms = {} -- ramassés, à rattacher à la salle actuelle (update_zone_stats)

local function process_picked_locations()
    if #picked_locations == 0 then return end
    local batch = picked_locations
    picked_locations = { for_rooms = batch.for_rooms }
    for _, loc in ipairs(batch) do
        table.insert(picked_locations.for_rooms, loc)
        debug_log("envoi du check : " .. loc.name)
        add_message(tr("Check : ", "Check: ") .. i18n.loc(loc))
        queue_check(loc)
        debug_log("check traité : " .. loc.name)
    end
end


-- Objectif choisi dans le yaml (slot_data "goal") : fin_du_jeu (défaut), tous_les_seigneurs,
-- dimitrescu, beneviento, moreau, heisenberg. « tous_les_checks » retiré (2026-10-07, choix du
-- joueur : tous les checks = mode 100 % de l'option des zones ratables), gardé pour les
-- anciennes seeds.
local goal_mode = "fin_du_jeu"
local missable_mode = "envoi_auto"

local function goal_reached()
    local b = state.bosses or {}
    if goal_mode == "fin_du_jeu" then return b.fin_du_jeu == true end
    if goal_mode == "tous_les_seigneurs" then
        return b.dimitrescu and b.beneviento and b.moreau and b.heisenberg or false
    end
    if goal_mode ~= "tous_les_checks" then return b[goal_mode] == true end
    return total_locations > 0 and checked_count >= total_locations
end

local function check_goal()
    if goal_sent or not is_connected() then return end
    if goal_reached() then
        net.goal()
        goal_sent = true
        add_message(tr("OBJECTIF ATTEINT (", "GOAL COMPLETE (") .. goal_mode .. ") !")
    end
end

local function process_boss_events()
    if #pending_boss_events == 0 then return end
    local batch = pending_boss_events
    pending_boss_events = {}
    state.bosses = state.bosses or {}
    for _, boss in ipairs(batch) do
        if not state.bosses[boss] then
            state.bosses[boss] = true
            add_message(tr("Progression : ", "Progress: ") .. boss)
            debug_log("progression objectif : " .. boss)
        end
    end
    save_state()
    check_goal()
end

---------------------------------------------------------------------------
-- Réception des items
---------------------------------------------------------------------------

local items_queue = {}
-- Crash du 2026-09-26 : au goal, le serveur libère tout (release) et ~450 items ont été donnés
-- dans la même frame pendant la cinématique de fin ; le jeu a planté 4 s plus tard. On donne
-- donc un item à la fois, espacés, et rien pendant la fin du jeu (EndingFlow).
local last_item_give = -math.huge
local ending_active = false

local function apply_item(row)
    local item_name = net.get_item_name(row.item)
    local item = item_name and item_by_name[item_name]
    -- Objet clé à moi ramassé au sol sous sa vraie forme (2026-09-30, voir swap_pickup) : déjà
    -- dans la mallette, présentation et son du jeu compris. Redonné seulement après un
    -- rechargement de sauvegarde (row.regive, save_sync).
    -- 2026-10-08 (Bague perdue après rechargement d'une sauvegarde plus ancienne) : seulement si
    -- l'objet est VRAIMENT dans la mallette
    if row.location and row.player == net.get_player_number() and not row.regive
            and (state.given_by_pickup or {})[tostring(row.location)]
            and not (item and (inventory_quantity(item.game_item_id) or 0) == 0) then
        debug_log("don : " .. tostring(item_name) .. " déjà ramassé au sol (objet clé), pas redonné")
        add_message(tr("Trouvé : ", "Found: ") .. tostring(i18n.item(item_name)))
        return true
    end
    if not item then
        add_message(tr("Item inconnu reçu : ", "Unknown item received: ") .. tostring(item_name))
        return true -- on ne bloque pas la file pour un item qu'on ne sait pas donner
    end

    if not row.fails then debug_log("don : " .. item_name) end -- une ligne, pas une par essai
    local ok, reason
    if item.type == "Trap" then
        ok = K.traps.apply(item) -- K : déclaré en haut du fichier (shop_ui n'existe pas encore ici)
    elseif item.type == "Money" then
        ok = give_money(item.quantity or 500) -- 500 : un sac de Lei du Village (vu en jeu)
    elseif item.levels then
        -- Objet clé progressif (clés ailées, 2026-09-30) : le N-ième exemplaire reçu donne le
        -- niveau N (row.level, voir process_network). Comme dans le jeu, la clé SE TRANSFORME :
        -- les niveaux d'avant sont retirés de l'inventaire une fois le nouveau donné (2026-10-08,
        -- test en jeu : la Clé ailée restait à côté de la Clé à quatre ailes).
        local level = math.min(row.level or 1, #item.levels)
        ok, reason = give_item(item.levels[level], 1)
        if ok then
            -- reduceItem ne retire pas un objet clé (essai du 2026-10-08 : quantité restée à 1) :
            -- removeItem sur l'objet lui-même, trouvé dans la liste de l'inventaire.
            local _, inv = get_active_inventory()
            local lower = {}
            for i = 1, level - 1 do lower[item.levels[i]] = i end
            pcall(function()
                local list = inv:call("get_items")
                local works = {}
                for i = 0, list:call("get_Count") - 1 do works[#works + 1] = list:call("get_Item", i):call("get_work") end
                for _, work in ipairs(works) do
                    local n = lower[work:call("get_itemID")]
                    if n then
                        local removed = pcall(function() inv:call("removeItem", work, true) end)
                        debug_log(string.format("clé progressive : niveau %d retiré (remplacé par le niveau %d) : %s",
                            n, level, tostring(removed)))
                    end
                end
            end)
        end
        debug_log(string.format("don : %s niveau %d (objet %s) : %s", item_name, level, tostring(item.levels[level]), tostring(ok)))
        -- Diagnostic (2026-10-08 : Clé ailée « donnée » mais absente de l'inventaire) : quantités de
        -- tous les niveaux tout de suite, puis 3 s plus tard (le jeu jette-t-il la clé ?).
        local parts = {}
        for i, id in ipairs(item.levels) do parts[#parts + 1] = i .. "=" .. tostring(inventory_quantity(id)) end
        debug_log("clé progressive : quantités juste après le don : " .. table.concat(parts, " "))
        i18n.key_diag = { at = os.clock() + 3, levels = item.levels }
    else
        ok, reason = give_item(item.give_id or item.game_item_id, item.quantity or 1, item)
    end
    state.received_ids = state.received_ids or {}
    if not ok and reason == "plein" then
        -- Bug du 2026-09-26 : mallette pleine, le jeu refusait le M1897 et le mod réessayait
        -- 4 fois par seconde en bloquant tous les items suivants. On le met dans le colis.
        table.insert(state.parcel, item_name)
        state.received_ids[tostring(item.game_item_id)] = true
        debug_log("don refusé (mallette pleine) : " .. item_name .. " -> colis")
        add_message(tr("Mallette pleine : " .. item_name .. " mis dans le colis (fais de la place)",
            "Case full: " .. i18n.item(item_name) .. " put in the parcel (make some room)"))
        return true
    end
    if not ok then
        -- 2026-10-08 (bouton « Redonner tout » bloqué en boucle sur le Morceau de relief démon,
        -- déjà possédé) : objet clé déjà dans la mallette = donné ; et un objet refusé 10 fois de
        -- suite part au colis, la file n'est plus jamais bloquée.
        local gid = item.game_item_id
        if item.type == "Key" and gid and (inventory_quantity(gid) or 0) > 0 then
            debug_log("don : " .. item_name .. " déjà dans la mallette (objet clé), compté comme donné")
            state.received_ids[tostring(gid)] = true
            return true
        end
        row.fails = (row.fails or 0) + 1
        -- « pas_pret » (2026-10-08, test EN) : le jeu refuse les ajouts pendant l'animation de
        -- ramassage ou une présentation ; 10 refus arrivaient en 2,5 s et l'objet partait au colis
        -- (donné 30 s plus tard). On réessaie donc jusqu'à 20 s avant le colis.
        if reason == "pas_pret" then
            row.first_fail = row.first_fail or os.clock()
            if os.clock() - row.first_fail < 20 then return false end
        elseif row.fails < 10 then
            return false
        end
        table.insert(state.parcel, item_name)
        debug_log(string.format("don refusé %d fois : %s (%s) -> colis", row.fails, item_name, tostring(reason)))
        return true
    end
    state.received_ids[tostring(item.game_item_id)] = true

    local sender = net.get_player_alias(row.player)
    local me = net.get_player_alias(net.get_player_number())
    if sender == me then
        add_message(tr("Trouvé : ", "Found: ") .. i18n.item(item_name))
    else
        add_message(string.format(tr("Reçu : %s (de %s)", "Received: %s (from %s)"), i18n.item(item_name), sender))
    end
    return true
end

local vanilla_removals = {} -- objets d'origine à retirer (voir "Détection des ramassages")
local current_zone = nil      -- zone majoritaire parmi les placements chargés (scan automatique)

local function current_zone_is_chris()
    return current_zone == "Chris"
end

local function process_items_queue()
    if #items_queue == 0 or not is_in_game() then return end
    -- seulement les objets vraiment à donner (2026-10-08 : à la connexion le serveur renvoie toute
    -- la liste, déjà donnée ; le message annonçait « 14 en attente » pour rien)
    local to_give = 0
    for _, row in ipairs(items_queue) do
        if (row.index or 0) > state.last_applied_index then to_give = to_give + 1 end
    end
    if to_give > 10 and os.clock() > (net.backlog_notice or 0) then
        net.backlog_notice = os.clock() + 60
        add_message(string.format(tr("%d objets Archipelago en attente : distribution lente pour ne pas faire planter le jeu",
            "%d Archipelago items waiting: slow delivery so the game does not crash"), to_give))
    end
    -- Bug du 2026-09-25 : une poudre reçue pendant l'attente du retrait d'une poudre ramassée
    -- a été comptée dans la différence et retirée aussi. On attend donc la fin des retraits.
    if #vanilla_removals > 0 then return end
    if ending_active then return end
    local remaining = {}
    local holding = false
    local given = false
    for _, row in ipairs(items_queue) do
        -- Passage Chris : Chris a son propre inventaire. Les objets d'Ethan attendent qu'Ethan
        -- reprenne la main (on garde l'ordre des index : tout ce qui suit attend aussi).
        if not holding and current_zone_is_chris() then
            local name = net.get_item_name(row.item)
            local def = name and item_by_name[name]
            if def and not def.chris_only then holding = true end
        end
        -- Un item toutes les 0,25 s ; 1,2 s quand beaucoup attendent. Crash du 2026-09-27 : à
        -- la connexion à un multiworld déjà avancé (~500 items), 38 items en 10 s ont fait
        -- planter le moteur de son du jeu (Wwise : un son et une notification par objet).
        local interval = #items_queue > 10 and 1.2 or 0.25
        local too_soon = given or os.clock() - last_item_give < interval
        if row.index <= state.last_applied_index and not row.extra then
            -- déjà donné (renvoyé par le serveur à la reconnexion) : on l'oublie
        elseif holding or too_soon then
            table.insert(remaining, row)
        else
            given = true
            last_item_give = os.clock()
            if apply_item(row) then
                -- don en plus (bouton des objets clés manquants) : le compteur ne bouge pas
                if not row.extra then state.last_applied_index = row.index end
                save_state()
            else
                table.insert(remaining, row) -- réessai au prochain tour (inventaire pas prêt...)
            end
        end
    end
    items_queue = remaining
end

-- Colis : objets refusés faute de place. On en redonne un toutes les 10 s, dans l'ordre,
-- dès que la mallette a de la place.

-- Objets superposés (2026-09-27, après la Valise reçue à la sortie du château) : la mallette
-- croyait avoir de la place et le colis y ajoutait des armes par-dessus d'autres objets. Chaque
-- objet superposé (Inventory.isOverlap) est sorti de la grille puis reposé sur une case libre
-- (getBlankSlotNo, tourné si besoin) ; sans place, il est retiré et remis en tête du colis.
-- Appelé avant chaque don du colis et toutes les 5 s en jeu (hors menus : is_in_game).
local inventory_repair = { next = 0, gid_to_name = nil, last_parcel_try = -math.huge }
function inventory_repair.run()
    local _, inv = get_active_inventory()
    if not inv then return end
    if not inventory_repair.gid_to_name then
        inventory_repair.gid_to_name = {}
        for name, def in pairs(item_by_name) do
            if def.game_item_id then inventory_repair.gid_to_name[def.game_item_id] = name end
        end
    end
    local moved, parceled, stuck = {}, {}, {}
    pcall(function()
        local list = inv:call("get_items")
        local cores = {}
        for i = 0, list:call("get_Count") - 1 do cores[#cores + 1] = list:call("get_Item", i) end
        for _, core in ipairs(cores) do
            local work = core:call("get_work")
            local slot = work:call("get_slotNo")
            if slot and slot >= 0 and not work:get_field("IsHidden") and inv:call("isOverlap", core) then
                local id = work:call("get_itemID")
                local horizontal = work:call("get_isHorizontal")
                work:call("set_slotNo", -1)
                local res = inv:call("getBlankSlotNo", id, horizontal)
                local free = res and res:call("get_slotNo") or -1
                if free >= 0 then
                    work:call("set_slotNo", free)
                    work:call("set_isHorizontal", res:call("get_isHorizontal"))
                    work:call("set_lastSlotNo", free)
                    work:call("set_centeringSafeSlotNo", free)
                    moved[#moved + 1] = string.format("%s %d->%d", tostring(id), slot, free)
                elseif inventory_repair.gid_to_name[id] then
                    local name = inventory_repair.gid_to_name[id]
                    inv:call("removeItem", work, true)
                    table.insert(state.parcel, 1, name)
                    parceled[#parceled + 1] = name
                else
                    work:call("set_slotNo", slot) -- objet hors Archipelago : laissé en place
                    stuck[#stuck + 1] = tostring(id)
                end
            end
        end
    end)
    if #moved + #parceled + #stuck == 0 then return end
    if #parceled > 0 then save_state() end
    for _, gui in ipairs(find_all_components("app.GUIInventory")) do
        pcall(function() gui:call("setupItemExtend") end)
    end
    debug_log(string.format("mallette : objets superposés : déplacés [%s], remis au colis [%s], sans place [%s]",
        table.concat(moved, ", "), table.concat(parceled, ", "), table.concat(stuck, ", ")))
    if #parceled > 0 then
        add_message(string.format(tr("Mallette pleine : %s remis au colis", "Case full: %s put back in the parcel"),
            table.concat(parceled, ", ")))
    end
end
function inventory_repair.update()
    if not is_in_game() or ending_active or #vanilla_removals > 0 or os.clock() < inventory_repair.next then return end
    inventory_repair.next = os.clock() + 5.0
    inventory_repair.run()
end

local function process_parcel()
    if #state.parcel == 0 or not is_in_game() or ending_active or #vanilla_removals > 0 then return end
    if os.clock() - inventory_repair.last_parcel_try < 10.0 then return end
    inventory_repair.last_parcel_try = os.clock()
    inventory_repair.run()
    local name = state.parcel[1]
    local item = item_by_name[name]
    if not item then
        table.remove(state.parcel, 1)
        save_state()
        return
    end
    local ok = give_item(item.give_id or item.game_item_id, item.quantity or 1, item)
    if ok then
        table.remove(state.parcel, 1)
        save_state()
        debug_log("colis : " .. name .. " donné")
        add_message(string.format(tr("Colis : %s récupéré (%d restant(s))", "Parcel: %s collected (%d left)"), name, #state.parcel))
    end
end


---------------------------------------------------------------------------
-- Rechargement de sauvegarde (2026-09-27)
---------------------------------------------------------------------------
-- Bug : les objets reçus depuis la dernière sauvegarde disparaissaient au rechargement (la
-- mallette revient à son état sauvegardé, mais le mod les comptait déjà comme donnés). On note
-- donc, à chaque sauvegarde, l'index du dernier objet donné et le colis, par emplacement ; quand
-- la mallette est remise depuis une sauvegarde, les objets reçus après sont redonnés.
-- API relevée dans il2cpp_dump.json : app.SaveLoadManager.StartSave / StartLoad (numéro
-- d'emplacement), app.InventoryManager.GetSaveSection (mallette prise pour une sauvegarde ou un
-- point de reprise) et WriteBackSaveData (mallette remise depuis une sauvegarde).
-- Les hooks ne font que noter ; le travail est fait dans la boucle du jeu (save_sync.update).
local save_sync = { history = {}, saving_slot = nil, load_slot = nil, loaded = false, dirty = false, captures = 0 }

function save_sync.snapshot()
    local index, src = state.last_applied_index, state.parcel
    -- Sauvegarde automatique faite PENDANT un chargement (2026-10-09, Sanguis Virginis perdu) : la
    -- mallette est celle de la sauvegarde chargée, pas encore complétée par les objets à redonner.
    -- Noter l'index du mod (41) au lieu de celui de la sauvegarde chargée (38) faisait croire, au
    -- chargement suivant, que ces objets y étaient déjà.
    if save_sync.loaded or save_sync.load_target ~= nil or save_sync.load_slot ~= nil then
        local t = save_sync.load_target
        if t == nil and save_sync.load_slot then t = state.saves and state.saves[tostring(save_sync.load_slot)] end
        if t and t.index < index then index, src = t.index, t.parcel end
    end
    local parcel = {}
    for i, name in ipairs(src or {}) do parcel[i] = name end
    return { index = index, parcel = parcel }
end

-- Objets clés manquants (2026-10-09) : objets clés reçus (pas les clés progressives) absents de
-- la mallette. Un objet clé UTILISÉ (relief posé, clé de porte) est aussi absent : le joueur
-- choisit donc lui-même lesquels redonner (liste de l'onglet Aide). Appelé depuis la boucle du jeu.
function save_sync.find_missing_keys()
    local list, seen = {}, {}
    for index, row in pairs(save_sync.history) do
        local name = net.get_item_name(row.item) or ""
        local def = item_by_name[name]
        if def and def.type == "Key" and not def.levels and not seen[name]
                and (inventory_quantity(def.game_item_id) or 0) == 0 then
            seen[name] = true
            list[#list + 1] = { index = index, name = name }
        end
    end
    table.sort(list, function(a, b) return a.index < b.index end)
    save_sync.missing_list = list
    debug_log(string.format("bouton : %d objet(s) clé(s) absent(s) de la mallette", #list))
end

function save_sync.give_key(index)
    local row = save_sync.history[index]
    if not row then return end
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.regive = true
    copy.extra = true -- déjà compté comme donné : la file le jetterait sinon
    items_queue[#items_queue + 1] = copy
    debug_log("bouton : objet clé redonné : " .. tostring(net.get_item_name(row.item)))
end

-- Entier 32 bits signé passé à un hook.
function save_sync.arg_int(arg)
    local v = sdk.to_int64(arg) & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

function save_sync.install_hooks()
    local slm = sdk.find_type_definition("app.SaveLoadManager")
    local inv = sdk.find_type_definition("app.InventoryManager")
    local hook = function(def, name, pre)
        local method = def and def:get_method(name)
        if not method then
            debug_log("sauvegardes : méthode introuvable " .. name)
            return
        end
        sdk.hook(method, function(args) pcall(pre, args) end, function(retval) return retval end)
    end
    hook(slm, "StartSave", function(args)
        save_sync.saving_slot = save_sync.arg_int(args[5])
        if session then
            state.saves = state.saves or {}
            state.saves[tostring(save_sync.saving_slot)] = save_sync.snapshot()
            save_sync.dirty = true
        end
    end)
    hook(slm, "StartLoad", function(args)
        save_sync.load_slot = save_sync.arg_int(args[5])
        -- État noté de la sauvegarde qu'on charge, retenu tout de suite : la sauvegarde
        -- automatique faite pendant le chargement l'écrasait (2026-10-08, StartSave(-1) avant
        -- WriteBackSaveData).
        if session then
            local t = state.saves and state.saves[tostring(save_sync.load_slot)]
            save_sync.load_target = t and { index = t.index, parcel = t.parcel } or false
            save_sync.load_target_slot = save_sync.load_slot
        end
    end)
    hook(inv, "GetSaveSection", function()
        save_sync.captures = save_sync.captures + 1
        if not session then return end
        local snap = save_sync.snapshot()
        state.checkpoint = snap
        if save_sync.saving_slot then
            state.saves = state.saves or {}
            state.saves[tostring(save_sync.saving_slot)] = snap
        end
        save_sync.dirty = true
    end)
    hook(inv, "WriteBackSaveData", function()
        -- 2026-10-08 (agrandissement de mallette perdu après un plantage) : juste après un
        -- chargement, le jeu refait une sauvegarde automatique (emplacement -1) qui écrasait
        -- l'état noté de la sauvegarde chargée avant la comparaison (13 contre 13, rien redonné).
        -- L'état est donc retenu ICI, au moment du chargement.
        -- sans StartLoad (reprise après une mort : point de reprise), état retenu ici
        if session and not save_sync.loaded and save_sync.load_target == nil and not save_sync.load_slot then
            local t = state.checkpoint
            save_sync.load_target = t and { index = t.index, parcel = t.parcel } or false
        end
        save_sync.loaded = true
        save_sync.picked_locs = {} -- objets au sol revenus avec la sauvegarde : habillés à nouveau
        if shop_ui.notice then shop_ui.notice.diff_warned = false end -- avertissement de difficulté redonné
    end)
end
save_sync.install_hooks()

function save_sync.update()
    if save_sync.missing_keys and session then
        save_sync.missing_keys = nil
        pcall(save_sync.find_missing_keys)
    end
    if save_sync.give_index and session then
        local index = save_sync.give_index
        save_sync.give_index = nil
        pcall(save_sync.give_key, index)
    end
    if save_sync.saving_slot and save_sync.dirty then
        debug_log(string.format("sauvegarde (emplacement %d) : dernier objet donné = %d, colis %d, prises %d",
            save_sync.saving_slot, state.last_applied_index, #state.parcel, save_sync.captures))
        save_sync.saving_slot = nil
    end
    if save_sync.dirty then
        save_sync.dirty = false
        save_state()
    end
    -- Mallette remise : on attend d'être connecté (état de la seed chargé) pour comparer.
    if not save_sync.loaded or not session or ending_active then return end
    save_sync.loaded = false
    local slot = save_sync.load_slot
    save_sync.load_slot = nil
    -- Bouton « Redonner tous les objets reçus » (outils, 2026-09-30) : comme une sauvegarde d'avant
    -- la seed (secours après un plantage ou un Reset scripts fait après le chargement).
    local force_all = save_sync.force_all
    save_sync.force_all = nil
    -- Emplacement connu sans état noté (sauvegarde faite avant cette version, ou avec une autre
    -- partie Archipelago) : on ne sait pas, donc on ne redonne rien. Le point de reprise
    -- (state.checkpoint) ne sert que sans numéro d'emplacement (continuer après une mort).
    local target
    if save_sync.load_target ~= nil then
        target = save_sync.load_target or nil -- retenu au chargement (voir WriteBackSaveData)
    elseif slot then target = state.saves and state.saves[tostring(slot)] else target = state.checkpoint end
    save_sync.load_target = nil
    -- Test du 2026-09-30 : save du château faite avant la seed de test, rechargée après 11 checks ;
    -- rien n'était redonné (emplacement inconnu). Si la seed suit toutes ses sauvegardes, une
    -- sauvegarde inconnue n'a aucun objet de la seed : on redonne tout.
    if force_all then
        target = { index = -1, parcel = {} }
        debug_log("bouton : tous les objets reçus sont redonnés")
    elseif not target and state.tracks_saves then
        target = { index = -1, parcel = {} }
        debug_log("chargement : sauvegarde d'avant cette seed, tous les objets reçus sont redonnés")
    end
    debug_log(string.format("chargement (emplacement %s) : sauvegarde au dernier objet %s, mod au dernier objet %d",
        tostring(slot), target and tostring(target.index) or "inconnu", state.last_applied_index))
    -- diagnostic de la mallette à chaque chargement (2026-10-08 : mallette corrompue après un crash)
    pcall(function() debug_log("mallette au chargement : " .. inventory_dump()) end)
    pcall(function()
        local _, inv = get_active_inventory()
        if inv then i18n.extend_level_info(inv, true) end
    end)
    if not target or target.index >= state.last_applied_index then return end
    local lost = state.last_applied_index - target.index
    state.last_applied_index = target.index
    state.parcel = target.parcel or {}
    state.checkpoint = target
    local queued = {}
    for _, row in ipairs(items_queue) do queued[row.index] = true end
    for index, row in pairs(save_sync.history) do
        if index > target.index and not queued[index] then
            row.regive = true -- objet clé ramassé au sol : la sauvegarde ne l'a pas, on le redonne
            items_queue[#items_queue + 1] = row
        end
    end
    table.sort(items_queue, function(a, b) return a.index < b.index end)
    save_state()
    add_message(string.format(tr("Sauvegarde rechargée : %d objet(s) Archipelago redonné(s)",
        "Save reloaded: %d Archipelago item(s) given again"), lost))
end


---------------------------------------------------------------------------
-- DeathLink (2026-09-27)
---------------------------------------------------------------------------
-- Option du yaml (slot_data "death_link"). Notre mort = début de l'écran de game over
-- (app.GameOverManager.get_isRunning passe à vrai), quelle qu'en soit la cause. Mort d'un autre
-- joueur = app.GameOverManager.requestGameOver, dès qu'on est en jeu (pas pendant la fin).
-- Le game over qu'on déclenche ainsi n'est pas renvoyé (sinon les joueurs s'entretueraient).
local death_link = { enabled = false, was_running = false, pending = nil, ours_until = -math.huge }

function death_link.receive(ev)
    if not death_link.enabled or ev.source == net.get_player_alias(net.get_player_number()) then return end
    death_link.pending = ev
    debug_log("DeathLink reçu : " .. tostring(ev.source) .. " (" .. tostring(ev.cause) .. ")")
end

-- Message envoyé (en anglais, lu par tout le multiworld) : « tué par … » si le coup mortel
-- (doDie, voir death_link.hits) date de moins de 20 s et que son auteur est connu, sinon message
-- générique. Auteurs relevés en jeu (debug_log « coup reçu » / « mort d'Ethan ») ; un auteur
-- inconnu est noté dans le journal pour compléter la table.
-- Identifiants : docs/README.md « Identifiants de boss confirmés » et kills.jsonl.
death_link.KILLERS = {
    em1000 = "Lady Dimitrescu",                    -- griffes NailAttack_L, 400 (confirmé 2026-09-27)
    em1240 = "a Lycan",                            -- lycans de base
    em1060 = "Urias",                              -- boss de la forteresse (marteau)
    em1061 = "Urias Strajer",                      -- version Mégamycète (partie Chris)
    em1062 = "a giant axe-wielding Lycan",         -- gardien de la tombe du Village (2026-10-07)
    em1281 = "a werewolf",                         -- mini-boss de la maison brûlée
    em1030 = "a Soldat",                           -- soldats de l'usine
    em1031 = "a Soldat",
    em1040 = "Sturm",                              -- mini-boss à hélice de l'usine
    em1260 = "Cassandra Dimitrescu",               -- 2e sœur tuée (2026-09-27 20:34)
    em1261 = "Daniela Dimitrescu",                 -- 3e sœur tuée (confirmé 2026-09-27 20:49)
    em1262 = "Bela Dimitrescu",                    -- 1re sœur tuée (2026-09-27 nuit)
    em1302 = "Moreau",
    BugSlipAttacker = "a swarm of insects",        -- nuée des filles de Dimitrescu (2026-09-27)
}
function death_link.cause(me)
    local hit = death_link.hits and death_link.hits.fatal
    if hit then death_link.hits.fatal = nil end
    local killer = hit and os.clock() - (hit.time or 0) < 20 and death_link.KILLERS[hit.owner or ""]
    if hit and not killer then debug_log("DeathLink : auteur inconnu " .. json.dump_string(hit)) end
    if killer then return me .. " was killed by " .. killer .. " in Resident Evil Village." end
    return me .. " died in Resident Evil Village."
end

function death_link.update()
    if not death_link.enabled and not death_link.test then return end
    local gom = sdk.get_managed_singleton("app.GameOverManager")
    if not gom then return end
    local running = false
    pcall(function() running = gom:call("get_isRunning") == true end)
    if running and not death_link.was_running then
        if os.clock() < death_link.ours_until then
            death_link.ours_until = -math.huge
        else
            local me = net.get_player_alias(net.get_player_number())
            net.send_death(death_link.cause(me))
            add_message(tr("Mort envoyée aux autres joueurs (DeathLink)", "Death sent to the other players (DeathLink)"))
            debug_log("DeathLink envoyé")
        end
    end
    death_link.was_running = running
    local ev = death_link.pending
    if ev and not running and is_in_game() and not ending_active then
        death_link.pending = nil
        death_link.test = nil
        death_link.ours_until = os.clock() + 15
        local ok, err = pcall(function() gom:call("requestGameOver") end)
        add_message(string.format(tr("DeathLink : tué par %s", "DeathLink: killed by %s"), tostring(ev.source)))
        debug_log("DeathLink : game over demandé, " .. tostring(ok) .. " " .. tostring(err or ""))
    end
end

---------------------------------------------------------------------------
-- Callbacks Archipelago
---------------------------------------------------------------------------

-- Objet placé sur chaque location de boutique (LocationScouts à la connexion), pour afficher
-- "[AP] <objet reçu>" chez le Duc (demande du joueur, 2026-09-26).
local scouted_items = {}

-- État de la boutique regroupé dans une table (limite de 200 variables locales de Lua) :
--   swap_map : ItemID affiché -> location (articles montrés sous l'objet qu'ils donnent) ;
--   bought   : articles-checks achetés mais pas encore envoyés ;
--   offered  : ItemID -> prix des articles-checks vus chez le Duc ;
--   last_tab : dernier onglet noté dans le journal.
-- swap_map est reconstruit à chaque liste ; bought et offered sont vidés à la connexion.
local shop_ui = { swap_map = {}, bought = {}, offered = {}, last_tab = nil, ap_model_units = {}, key_offline = {} }
-- Retire n exemplaires de l'objet item_id en modifiant directement ses piles (2026-10-08 : reduceItem
-- répond « ok » sans rien retirer pour certains objets : Fragments de cristal des ramassages AP
-- accumulés dans la mallette, objets clés). Renvoie le nombre retiré.
function shop_ui.inv_take(inv, item_id, n)
    local list = inv:call("get_items")
    local works = {}
    for i = 0, list:call("get_Count") - 1 do works[#works + 1] = list:call("get_Item", i):call("get_work") end
    local taken = 0
    for _, work in ipairs(works) do
        if n - taken <= 0 then break end
        if work:call("get_itemID") == item_id then
            local stack = work:call("get_stackSize") or 0
            local take = math.min(stack, n - taken)
            if take > 0 then
                if take >= stack then
                    inv:call("removeItem", work, true)
                elseif not pcall(function() work:call("set_stackSize", stack - take) end) then
                    work:set_field("StackSize", stack - take)
                end
                taken = taken + take
            end
        end
    end
    return taken
end

-- Sons au ramassage (2026-09-30, demande du joueur). Le jeu ne joue pas le vrai son (objet de
-- ramassage remplacé par un Fragment de cristal, voir swap_pickup). Son joué par
-- app.WwiseManagerApp.trigger(numéro). Numéros par catégorie d'objet (items.json) : relevés en
-- jeu avec l'outil « Relever les sons de ramassage » (journal « son : »), puis notés ici.
shop_ui.sound = { ids = {}, capture_until = 0, capture_item = nil, installed = false }

-- Présentation plein écran (2026-10-01) : modèle de l'objet AP, mais NOM et description de l'objet
-- d'origine de l'emplacement (Ferraille montrée sous le nom « Sanguis Virginis »). On remplace le
-- texte d'app.GUIDetailSearch (set_nameText / set_descText) dans les 5 s qui suivent le ramassage
-- d'un check.
shop_ui.detail = { pending = nil }
function shop_ui.detail.on_pickup(loc)
    local lid = get_location_id(loc)
    local sc = lid and scouted_items[lid]
    if not sc then return end
    local def = sc.mine and item_by_name[sc.name]
    local desc = def and def.description ~= "" and def.description
        or string.format(tr("Objet Archipelago pour %s (%s).", "Archipelago item for %s (%s)."), sc.player, sc.game)
    shop_ui.detail.pending = { name = "[AP] " .. sc.label, desc = desc, until_t = os.clock() + 5 }
end
function shop_ui.detail.install()
    local def = sdk.find_type_definition("app.GUIDetailSearch")
    if not def then return end
    for field, method in pairs({ name = "set_nameText", desc = "set_descText" }) do
        local m = def:get_method(method)
        if m then
            sdk.hook(m, function(args)
                local pd = shop_ui.detail.pending
                if pd and os.clock() < pd.until_t then
                    pcall(function() args[3] = sdk.to_ptr(sdk.create_managed_string(pd[field])) end)
                    shop_ui.detail.note = "présentation : texte remplacé (" .. field .. ") -> " .. pd[field]
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end
    end
end
-- DÉSACTIVÉ (2026-10-01, 1h53) : plantage du jeu juste après un remplacement de description (texte
-- créé non protégé, ou objet d'origine retiré pendant la présentation).
-- pcall(shop_ui.detail.install)

-- Nom de MON objet clé pendant sa présentation (2026-10-03 : vin ramassé sur le Crochet #010,
-- présenté sous le nom « Crochet »). Seulement le nom (pas la description), seulement près d'un
-- emplacement qui donne un de mes objets clés (near_ap_watch), texte protégé (add_ref) et gardé.
-- ERREUR corrigée le 2026-10-04 : set_nameText est le SETTER du composant texte (via.gui.Text) de
-- la présentation, pas du nom ; on y glissait une chaîne à la place du composant (nom faux pour la
-- Boule (fleur et épées), et sans doute de la mémoire abîmée). Désormais le hook ne change rien :
-- il retient l'écran de présentation, et le nom est écrit dans son texte (set_Message) avant
-- chaque rendu tant qu'on est près de l'emplacement (shop_ui.detail.keep_key_name).
-- 2e essai (2026-10-04, 02h17) : set_nameText n'est appelé qu'à l'initialisation de l'interface,
-- jamais pendant une présentation (Boule : aucun remplacement). L'écran (composant
-- app.GUIDetailSearch) est cherché dans la scène, au plus 1 fois par seconde, pendant une
-- présentation (hors jeu) près d'un de mes objets clés.
function shop_ui.detail.install_key_name() end
function shop_ui.detail.keep_key_name()
    local k = shop_ui.world and shop_ui.world.near_key_def
    if not k or os.clock() > (shop_ui.world.near_key_until or 0) or is_in_game() then return end
    if not shop_ui.detail.gui and os.clock() >= (shop_ui.detail.next_find or 0) then
        shop_ui.detail.next_find = os.clock() + 1
        local found = find_all_components("app.GUIDetailSearch")
        if found and found[1] then
            shop_ui.detail.gui = found[1]:add_ref()
            debug_log("présentation : écran GUIDetailSearch trouvé (" .. #found .. ")")
        end
    end
    local gui = shop_ui.detail.gui
    if not gui then return end
    local text = gui:call("get_nameText")
    if not text then return end
    local now = text:call("get_Message")
    -- 3e essai (02h22 : nom lu vide, Boule toujours affichée sous le nom d'origine) : le nom vient
    -- d'un identifiant de message (MessageId), prioritaire sur Message. Il est remis à zéro.
    local id_str = nil
    pcall(function() id_str = text:call("get_MessageId"):call("ToString") end)
    local has_id = id_str ~= nil and id_str ~= shop_ui.detail.EMPTY_GUID
    if has_id or now ~= k.name then
        if has_id then
            local ok, err = pcall(function()
                text:call("set_MessageId", ValueType.new(sdk.find_type_definition("System.Guid")))
            end)
            if not ok and not shop_ui.detail.id_error_logged then
                shop_ui.detail.id_error_logged = true
                debug_log("présentation : MessageId non effacé : " .. tostring(err))
            end
        end
        text:call("set_Message", k.name)
        if (shop_ui.detail.renamed or 0) < 20 then
            shop_ui.detail.renamed = (shop_ui.detail.renamed or 0) + 1
            shop_ui.detail.note = string.format("présentation : nom \"%s\" (MessageId %s) remplacé -> %s",
                tostring(now), tostring(id_str), k.name)
        end
    end
end
shop_ui.detail.EMPTY_GUID = "00000000-0000-0000-0000-000000000000"
-- 3e essai COUPÉ (2026-10-06) : Bague présentée sous le nom d'origine, journal « nom "" (MessageId
-- nil) » : nameText n'est pas le texte affiché. Remplacé par install_order_hook (plus bas).
shop_ui.detail.KEEP_NAME_TEXT = false
re.on_pre_application_entry("BeginRendering", function()
    if shop_ui.detail.KEEP_NAME_TEXT then pcall(shop_ui.detail.keep_key_name) end
end)
shop_ui.detail.KEY_NAME = true
if shop_ui.detail.KEY_NAME then pcall(shop_ui.detail.install_key_name) end

-- 4e essai (2026-10-06, remplacé par le 5e ci-dessous) : la présentation reçoit son contenu par app.GUIDetailSearchOrder.setMode,
-- soit (mode, ItemCore.InstanceWork) (nom tiré de work.ItemID), soit (mode, System.Guid messageID).
-- Près d'un de MES objets clés : si le work porte un autre ItemID, on passe à sa place une COPIE
-- (copyFrom) avec l'ID de mon objet clé (le work d'origine n'est pas touché). Le cas messageID est
-- seulement relevé au journal (« présentation : setMode ... »).
shop_ui.detail.notes = {}
function shop_ui.detail.can_note()
    shop_ui.detail.note_total = (shop_ui.detail.note_total or 0) + 1
    return shop_ui.detail.note_total <= 300 -- 40 trop bas (2026-10-08 : plus rien noté en fin de session)
end
-- 5e essai (2026-10-06, Boule) : setMode de l'ordre jamais appelé avec le work pendant la
-- présentation (1 seul appel, messageID, 3 s après le ramassage) : les appelants passent par
-- app.GUIOrderExtension.setDetailSearch, qui contourne GUIDetailSearchOrder. Hook sur le
-- RECEVEUR : app.GUIDetailSearch.setMode(GUIRequest.Parameter) (paramètre
-- GUIRequestSetDetailSearchParameter : mode, messageID, work). Près d'un de MES objets clés :
-- work avec un autre ItemID -> set_work(copie avec mon ID) ; messageID non vide -> remplacé par le
-- NameMessageID de mon objet clé (ItemSpecification.findItemSpec(id).Basic). Tout est journalisé
-- (« présentation : setMode ... »).
function shop_ui.detail.key_name_guid(id)
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    return specs:call("findItemSpec", id):get_field("Basic"):get_field("NameMessageID")
end
function shop_ui.detail.on_set_mode(args)
    local k = shop_ui.world and shop_ui.world.near_key_def
    local near = k and os.clock() <= (shop_ui.world.near_key_until or 0)
    local near_ap = os.clock() <= (shop_ui.world and shop_ui.world.near_ap_until or 0)
    -- 2026-10-07 (Sanguis Virginis #001, bain de sang) : pendant la présentation la caméra s'éloigne
    -- (near_ap faux, rien remplacé ni journalisé) : emplacement AP retenu 6 s (near_ap_watch).
    local near_loc = os.clock() <= (shop_ui.world and shop_ui.world.near_ap_loc_until or 0)
    if not near and not near_ap and not near_loc then return end
    -- Pas mon objet clé mais un emplacement AP proche (2026-10-07 : Sanguis Virginis #001 donnant
    -- des Grenades, présentation de l'objet d'origine sous son nom) : nom de l'objet AP.
    local held_loc = nil
    if not near then
        local loc = os.clock() <= (shop_ui.world.near_ap_loc_until or 0) and shop_ui.world.near_ap_loc
        local lid = loc and get_location_id(loc)
        local sc = lid and scouted_items[lid]
        if sc then
            local def = sc.mine and item_by_name[sc.name]
            k = { name = sc.label, game_item_id = def and def.game_item_id }
            near, held_loc = true, loc
        end
    end
    local p = sdk.to_managed_object(args[3])
    local ptype = p and p:get_type_definition():get_full_name() or "nil"
    if ptype ~= "app.GUIDetailSearchOrder.GUIRequestSetDetailSearchParameter" then
        -- 2026-10-07 (Sanguis : aucun appel journalisé) : autres paramètres notés
        if shop_ui.detail.can_note() then
            shop_ui.detail.notes[#shop_ui.detail.notes + 1] = "présentation : setMode paramètre " .. ptype .. " (ignoré)"
        end
        return
    end
    local work = p:call("get_work")
    local id = work and work:get_field("ItemID")
    -- Texte du messageID (nom affiché) : via.gui.message.get(guid). ToString sur le Guid échouait
    -- (journal « messageID=nil »), d'où le 5e essai sans effet : la présentation passe par
    -- messageID = findItemSpec(id).Basic.NameMessageID (InteractManager.StartDetailSearch,
    -- désassemblé hors jeu le 2026-10-06), jamais par le work.
    local g = nil
    pcall(function()
        g = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
            :call(nil, p:get_field("<messageID>k__BackingField"))
    end)
    local mode = nil
    pcall(function() mode = p:call("get_mode"):get_field("_Hash") end)
    local what = "rien"
    -- 2026-10-07 (Morceau de plaque ramassé 2 s après la volaille « Chasse - Volaille #4 ») :
    -- l'emplacement retenu 6 s ne vaut que si l'objet présenté est bien son objet d'origine (par
    -- l'ItemID du work, sinon par le nom affiché), sinon la présentation garde son vrai nom.
    if held_loc then
        local orig = held_loc.original_item or ""
        local def = item_by_name[orig]
        -- objet de ramassage du mod (objet d'origine modifié sur place, 2026-10-08 : Bague #008
        -- donnant du Poisson, présentée sous le nom d'origine) : c'est bien cet emplacement
        local pickup_id = shop_ui.world and shop_ui.world.PICKUP_ID
        local pickup_name = nil
        for n, d in pairs(item_by_name) do if d.game_item_id == pickup_id then pickup_name = n end end
        local same = (id ~= nil and def ~= nil and def.game_item_id == id)
            or (id ~= nil and id == pickup_id)
            or (g ~= nil and tostring(g) ~= "" and orig:sub(1, #tostring(g)) == tostring(g))
            or (g ~= nil and pickup_name ~= nil and tostring(g) == pickup_name)
        if not same then
            near = false
            what = "emplacement AP retenu ignoré (" .. held_loc.name .. " : objet d'origine " .. orig .. ")"
        end
    end
    if near then
        if work and k.game_item_id and id ~= k.game_item_id then
            local copy = sdk.create_instance("app.ItemCore.InstanceWork"):add_ref()
            copy:call("copyFrom", work)
            copy:call("set_itemID", k.game_item_id)
            shop_ui.detail.work_copy = copy
            p:call("set_work", copy)
            what = "work -> copie " .. tostring(k.game_item_id)
        elseif not work then
            -- objet d'un autre jeu : pas de fiche, nom écrit seulement dans le titre (keep_title)
            if k.game_item_id then p:call("set_messageID", shop_ui.detail.key_name_guid(k.game_item_id)) end
            what = "messageID -> nom de " .. k.name
            shop_ui.detail.title = { gui = sdk.to_managed_object(args[2]):add_ref(), text = "[AP] " .. k.name,
                until_t = os.clock() + 20 }
        end
    end
    if shop_ui.detail.can_note() then
        shop_ui.detail.notes[#shop_ui.detail.notes + 1] = string.format(
            "présentation : setMode mode=%s work=%s nom=\"%s\" clé proche=%s : %s",
            tostring(mode), tostring(id), tostring(g), near and k.name or "non", what)
    end
end
function shop_ui.detail.install_order_hook()
    local m = sdk.find_type_definition("app.GUIDetailSearch"):get_method("setMode")
    sdk.hook(m, function(args)
        local ok, err = pcall(shop_ui.detail.on_set_mode, args)
        if not ok and shop_ui.detail.can_note() then
            shop_ui.detail.notes[#shop_ui.detail.notes + 1] = "présentation : erreur setMode : " .. tostring(err)
        end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval) return retval end)
    debug_log("présentation : hook GUIDetailSearch.setMode posé")
end
shop_ui.detail.ORDER_HOOK = true

-- Échange arme / pièce d'arme -> Lei (2026-10-07, mallette LEMI remplacée par un sac de Lei : le
-- joueur avait déjà le LEMI, reçu du multiworld). Le jeu décide l'échange dans
-- app.Spawn.ItemSpawnInfo.ExchangeWeaponAndPartsCheck (appelé par RequestSpawnOrResume) : sauté
-- pour les emplacements de la seed, qui apparaissent donc toujours sous leur forme d'origine (le
-- check, lui, donne l'objet AP). Demande du joueur (option 2).
-- Emplacement d'un autre chapitre que le chapitre en cours ? (2026-10-07/08) Village : les
-- emplacements du 2e passage (Chapter2_6) sont posés et ramassables dès le 1er (Chapter2_1) :
-- ramassés là, ils seraient perdus -> autorisés (demande du joueur), SAUF GM 79 #012 [S00], posé
-- à l'endroit du couteau de départ (couteau disparu quand il était habillé).
shop_ui.SAME_STAGE = { Chapter2_1 = { Chapter2_6 = true } }
-- Couteau de départ (bug de l'alpha 0.9.0, 2026-10-08 : couteau disparu, porte bloquée, partie
-- bloquée) : GM 79 #012 [S00] (Chapter2_6) est au même endroit. Il n'est touché (habillage,
-- ramassage, échange arme/Lei bloqué) QUE pendant son propre chapitre : jamais au 1er passage, ni
-- tant que le chapitre n'est pas encore lu (l'échange est décidé au chargement de la scène, avant).
shop_ui.KNIFE_SPOT = { ["GM 79 #012 [S00]"] = true }
function shop_ui.other_chapter(loc)
    if not loc or not loc.folder_path then return false end
    local lc = loc.folder_path:match("Chapter%d_%d")
    local nc = shop_ui.chapter and tostring(shop_ui.chapter):match("Chapter%d_%d") or nil
    if shop_ui.KNIFE_SPOT[loc.name] then return nc == nil or nc ~= lc end
    if not lc or not nc or lc == nc then return false end
    -- Couteau de départ toujours disparu en 0.9.1 (2026-10-08) : il n'est PAS à côté de GM 79 #012.
    -- Les objets de ramassage du jeu sont recyclés ; habiller au 1er passage les emplacements du
    -- 2e (chargés mais pas vraiment en jeu) touchait celui du couteau. Tant que le joueur n'a pas
    -- le couteau, aucun emplacement d'un autre chapitre n'est touché (shop_ui.has_knife, relevé
    -- une fois par seconde dans la boucle du jeu) ; ensuite, règle SAME_STAGE habituelle.
    if not shop_ui.has_knife then return true end
    return not (shop_ui.SAME_STAGE[nc] or {})[lc]
end
shop_ui.world_exchange = { BLOCK = true, blocked = 0 }
-- Emplacements SCÉNARISÉS : le mod ne touche pas à l'objet du jeu (ni modèle, ni objet modifié
-- sur place, ni échange bloqué) ; le check part quand même au ramassage (placement reconnu),
-- l'objet d'origine est retiré ensuite. Vide pour l'instant (2026-10-07 : le Sanguis Virginis
-- y avait été mis à tort, le softlock de la vidange venait de la Clé de la cour, voir l'apworld).
shop_ui.no_touch = {}
function shop_ui.world_exchange.install()
    local m = sdk.find_type_definition("app.Spawn.ItemSpawnInfo"):get_method("ExchangeWeaponAndPartsCheck")
    sdk.hook(m, function(args)
        local skip = false
        pcall(function()
            local si = sdk.to_managed_object(args[2])
            local guid = tostring(si:call("get_myGUID"):call("ToString()"))
            local loc = location_by_guid[guid]
            if loc and get_location_id(loc) and not shop_ui.no_touch[loc.name] and not shop_ui.other_chapter(loc) then
                skip = true
                shop_ui.world_exchange.blocked = shop_ui.world_exchange.blocked + 1
                shop_ui.world_exchange.last = loc.name
            end
        end)
        return skip and sdk.PreHookResult.SKIP_ORIGINAL or sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval) return retval end)
    debug_log("échange arme/pièce -> Lei : bloqué sur les emplacements AP (hook posé)")
end
if shop_ui.world_exchange.BLOCK then pcall(shop_ui.world_exchange.install) end
-- Préfixe « [AP] » (2026-10-06, demande du joueur) : le nom est écrit par GUIDetailSearch.setMode
-- dans titleText (champ +0x120, désassemblage) par GUIExtension.setMessageID. Après le
-- remplacement du messageID, on écrit « [AP] nom » dans titleText (MessageId vidé une fois,
-- prioritaire sur Message) avant chaque rendu, 20 s au plus, seulement pendant la présentation.
function shop_ui.detail.keep_title()
    local t = shop_ui.detail.title
    if not t then return end
    if os.clock() > t.until_t then shop_ui.detail.title = nil return end
    if is_in_game() then return end
    local text = t.gui:call("get_titleText")
    if not text or text:call("get_Message") == t.text then return end
    if not t.id_cleared then
        t.id_cleared = true
        local ok, err = pcall(function()
            text:call("set_MessageId", ValueType.new(sdk.find_type_definition("System.Guid")))
        end)
        if shop_ui.detail.can_note() then
            shop_ui.detail.notes[#shop_ui.detail.notes + 1] = "présentation : titre -> " .. t.text
                .. (ok and "" or (" (MessageId non vidé : " .. tostring(err) .. ")"))
        end
    end
    text:call("set_Message", t.text)
end
re.on_pre_application_entry("BeginRendering", function()
    if shop_ui.detail.title then pcall(shop_ui.detail.keep_title) end
end)
if shop_ui.detail.ORDER_HOOK then pcall(shop_ui.detail.install_order_hook) end
shop_ui.sound.BY_TYPE = {
    -- Recovery = 0, Ammo = 0, Craft = 0, Treasure = 0, Key = 0, Other = 0, archipelago = 0,
}
-- Sons du jeu trouvés par désassemblage (2026-10-07), app.WwiseManagerApp.trigger(id) :
-- InteractItemGet.startDetailSearch joue KEY (GetMode FixDisplayCenter, objet clé) ou TREASURE
-- (GetMode AnotherSE / Once ; aussi plat cuisiné et pièce d'arme posée). MENU_OPEN / MENU_CLOSE
-- (4272878916 / 2582191558) = ouverture/fermeture des menus (mallette, sauvegarde, présentation) :
-- probablement des états de mixage, à NE PAS jouer seuls.
shop_ui.sound.GAME = { KEY = 2961364839, TREASURE = 3769661010 }
-- Sons AJOUTÉS par le mod à la banque système (tools/re_engine/make_ap_sound.py, 2026-10-07 ;
-- installés dans le pak de patch) : trigger = FNV-1 du nom. Jouables partout.
-- Une version par langue des voix (remarque du joueur : jeu en anglais -> voix anglaise), choisie
-- par via.wwise.WwiseDriver.get_Language (via.Language : 0 ja, 1 en, 2 fr, 3 it, 4 de, 5 es,
-- 6 ru, 10 ptbr, 13 zhcn ; anglais sinon). TEST_TREASURE : trigger neuf -> jingle trésor existant.
-- Voix : lues dans ap_sounds.json (écrit par make_ap_sound.py) au premier usage, nom -> langue -> trigger.
--   TRAP_FOR_OTHER : Daniela, phrase + rire (piège ramassé pour un autre joueur)
--   TRAP_LAUGH : Dimitrescu, rire (pour les pièges REÇUS, quand ils existeront)
--   TRAP_SCREAM : Bela, cri (piège « screamer », idée du joueur)
shop_ui.sound.AP = { TEST_TREASURE = 1788264539 }
shop_ui.sound.VOICE_NAMES = { TRAP_FOR_OTHER = "ap_trap_for_other", TRAP_LAUGH = "ap_trap_laugh",
    TRAP_SCREAM = "ap_trap_scream" }
setmetatable(shop_ui.sound.AP, { __index = function(_, key)
    local name = shop_ui.sound.VOICE_NAMES[key]
    local voices = name and shop_ui.sound.ap_table and shop_ui.sound.ap_table.voice
    return voices and voices[name] or nil
end })
shop_ui.sound.LANGS = { [0] = "ja", [1] = "en", [2] = "fr", [3] = "it", [4] = "de", [5] = "es", [6] = "ru",
    [10] = "ptbr", [13] = "zhcn" }
-- Sons ajoutés : joués par le conteneur système lui-même (WwiseManagerApp.SystemContainer) ; par
-- WwiseManagerApp.trigger, le jingle trésor s'est fait entendre en plus (2026-10-07), jamais par
-- le conteneur directement (validé en jeu, fr et en).
function shop_ui.sound.play_ap(id)
    if not id then return end
    pcall(function()
        sdk.get_managed_singleton("app.WwiseManagerApp"):get_field("SystemContainer"):call("trigger(System.UInt32)", id)
    end)
end
function shop_ui.sound.voice_id(by_lang)
    if not by_lang then return nil, nil end
    local lang = nil
    pcall(function()
        lang = sdk.find_type_definition("via.wwise.WwiseDriver"):get_method("get_Language"):call(nil)
    end)
    return by_lang[shop_ui.sound.LANGS[tonumber(lang) or 1] or "en"] or by_lang.en, lang
end
function shop_ui.sound.play(id)
    if not id or id == 0 then return end
    pcall(function() sdk.get_managed_singleton("app.WwiseManagerApp"):call("trigger(System.UInt32)", id) end)
end
-- Au ramassage d'un check : son de l'objet AP (le vrai objet clé à moi a déjà le sien).
-- Bruits de ramassage ajoutés (tools/re_engine/make_ap_sound.py) : objet riXXXX -> trigger.
shop_ui.sound.ap_table = json.load_file(MOD_NAME .. "/ap_sounds.json") or {}
shop_ui.sound.PICKUP_TRIGGER = 1738562264 -- trigger commun « ramassage » de tous les objets riXXXX
-- triggers de ramassage coupés sur les emplacements AP (sac de Lei : 1399615424, relevé 2026-10-07)
shop_ui.sound.MUTED_TRIGGERS = { [1738562264] = true, [1399615424] = true }
function shop_ui.sound.pickup_trigger(gid)
    if not gid then return nil end
    local ri = nil
    pcall(function()
        local prefab = sdk.get_managed_singleton("app.ItemSpecification"):call("findPrefab", gid)
        ri = tostring(prefab:call("get_Path")):match("(ri%d+)_")
    end)
    return ri and (shop_ui.sound.ap_table.pickup or {})[ri] or nil
end
-- Objets posés sur les emplacements AP pas encore ramassés (adresse du GameObject -> location),
-- refait toutes les 0,5 s : leur bruit de ramassage d'origine est coupé.
shop_ui.sound.ap_inst = {}
function shop_ui.sound.refresh_ap_inst()
    if os.clock() < (shop_ui.sound.next_inst or 0) then return end
    shop_ui.sound.next_inst = os.clock() + 0.5
    local map = {}
    for _, e in ipairs(shop_ui.world.entries or {}) do
        pcall(function()
            -- location_done est défini plus bas (local) : appelé via shop_ui.location_done
            if shop_ui.location_done(e.loc) == nil or (save_sync.picked_locs or {})[e.loc.key] then return end
            local inst = e.si:call("get_spawnInstance")
            if inst then map[inst:get_address()] = e.loc end
        end)
    end
    shop_ui.sound.ap_inst = map
end
-- Coupe le bruit de ramassage (trigger commun) joué par un objet d'emplacement AP. Hooks sur les
-- trigger* natifs de via.wwise.WwiseContainer (objet en args[1], pas de contexte), posés une fois
-- en jeu (pas au démarrage : des hooks posés au lancement ont déjà fait planter le jeu).
shop_ui.sound.MUTE_ORIGINAL = true
function shop_ui.sound.mute_hook()
    if shop_ui.sound.mute_installed or not shop_ui.sound.MUTE_ORIGINAL then return end
    shop_ui.sound.mute_installed = true
    local n = 0
    local def = sdk.find_type_definition("via.wwise.WwiseContainer")
    for _, m in ipairs(def and def:get_methods() or {}) do
        local name = m:get_name()
        if name:sub(1, 7) == "trigger" and name ~= "triggered" then
            local pos = nil
            for i, t in ipairs(m:get_param_types() or {}) do
                if not pos and t:get_full_name() == "System.UInt32" then pos = i end
            end
            if pos then
                n = n + 1
                sdk.hook(m, function(args)
                    local skip = false
                    pcall(function()
                        local id = sdk.to_int64(args[pos + 1]) & 0xFFFFFFFF
                        if not shop_ui.sound.MUTED_TRIGGERS[id] then return end
                        local go = sdk.to_managed_object(args[1]):call("get_GameObject")
                        local loc = go and shop_ui.sound.ap_inst[go:get_address()]
                        if loc then
                            skip = true
                            shop_ui.sound.muted_note = loc.name
                        end
                    end)
                    return skip and sdk.PreHookResult.SKIP_ORIGINAL or sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval) return retval end)
            end
        end
    end
    debug_log("son : bruit de ramassage d'origine coupé sur les emplacements AP (" .. n .. " hooks)")
end
function shop_ui.sound.on_pickup(loc, picked_item_id)
    if os.clock() < shop_ui.sound.capture_until then return end
    local lid = get_location_id(loc)
    local sc = lid and scouted_items[lid]
    if not sc then return end
    local def = sc.mine and item_by_name[sc.name]
    -- MES objets (2026-10-07) : bruit de ramassage du vrai objet (ajouté à la banque système,
    -- ap_sounds.json), le bruit de l'objet d'origine étant coupé (shop_ui.sound.mute_hook). Objets
    -- clés compris (avant : gardaient le bruit de l'objet d'origine posé sur place).
    -- Sans bruit connu (armes : Sniper, M1911…, conteneurs complexes ; sac de Lei) : jingle trésor,
    -- le son des objets Archipelago (2026-10-07, choix du joueur), sinon silence (origine coupée).
    if sc.mine then
        local trig = shop_ui.sound.pickup_trigger(def and def.game_item_id)
        if trig then shop_ui.sound.pending_ap = trig else shop_ui.sound.pending = shop_ui.sound.GAME.TREASURE end
        return
    end
    -- Objet d'un AUTRE jeu (2026-10-07, choix du joueur) : son trésor du jeu ; son objet clé si
    -- c'est un objet de progression (flag 1).
    if not sc.mine then
        -- Piège pour un autre joueur (flag 4, 2026-10-07, choix du joueur) : phrase + rire de
        -- Daniela si elle est dans la scène (shop_ui.voice.TRAP_FOR_OTHER), sinon son trésor.
        if ((sc.flags or 0) & 4) ~= 0 then
            shop_ui.voice.trap_pending = true
            return
        end
        shop_ui.sound.pending = ((sc.flags or 0) & 1) ~= 0 and shop_ui.sound.GAME.KEY or shop_ui.sound.GAME.TREASURE
        return
    end
    local kind = def and def.type or "archipelago"
    shop_ui.sound.pending = shop_ui.sound.BY_TYPE[kind] or shop_ui.sound.BY_TYPE.archipelago
end
-- Outil : journalise les sons déclenchés dans les 1,5 s après chaque ramassage normal (hooks posés
-- à la demande seulement : les sons du jeu passent par là en permanence).
function shop_ui.sound.install_capture()
    if shop_ui.sound.installed then return end
    shop_ui.sound.installed = true
    local n = 0
    for _, tname in ipairs({ "via.wwise.WwiseContainer", "app.WwiseManagerApp" }) do
        local def = sdk.find_type_definition(tname)
        for _, m in ipairs(def and def:get_methods() or {}) do
            local name = m:get_name()
            if name == "trigger" or name == "postEvent" then
                local pos = nil
                for i, t in ipairs(m:get_param_types() or {}) do
                    if not pos and t:get_full_name() == "System.UInt32" then pos = i end
                end
                if pos then
                    n = n + 1
                    sdk.hook(m, function(args)
                        if os.clock() < shop_ui.sound.capture_until then
                            local id = sdk.to_int64(args[pos + 2]) & 0xFFFFFFFF
                            shop_ui.sound.ids[#shop_ui.sound.ids + 1] = tname .. "." .. name .. " " .. tostring(id)
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end, function(retval) return retval end)
                end
            end
        end
    end
    debug_log("son : relevé posé sur " .. n .. " méthodes ; ramasse des objets normaux (Plante, munitions, objet clé...)")
end
-- Présentation d'un objet REÇU (2026-10-06, idée du joueur : objet clé envoyé par un autre jeu ->
-- présentation plein écran comme au ramassage). Outils de test, deux méthodes. Les deux font
-- tomber le vrai objet aux pieds d'Ethan comme un drop d'ennemi
-- (ItemSpawnInfoHolder.RequestEnemyDrop), retrouvent son InteractItemGet dans
-- ItemSpawnInfoEnemyDropUseList (nouvel objet avec le bon ItemID, 8 s au plus), puis :
--  méthode 1 : ramassage forcé par le jeu (InteractManager.RequestForceInteract(objet, joueur)) :
--              présentation + son + mallette, comme un vrai ramassage ;
--  méthode 2 : présentation lancée directement (InteractItemGet.startDetailSearch(joueur)).
-- Journal « présentation (test) : ... ». Un drop non ramassé reste au sol (ramassable).
shop_ui.present = { pending = nil }
function shop_ui.present.drop_list()
    local holder = sdk.get_managed_singleton("app.ItemSpawnInfoHolder")
    return holder and holder:get_field("ItemSpawnInfoEnemyDropUseList")
end
-- 1er essai (2026-10-07) : objet jamais retrouvé. 2e essai : recherche dans toute la scène
-- (findComponents) -> 4,5 s de gel et rien trouvé : RETIRÉ. Le drop réserve bien une entrée dans
-- ItemSpawnInfoEnemyDropUseList (4 -> 7 en 3 essais) mais aucun objet n'apparaît : on journalise
-- l'état de ces entrées (IsSpawned, IsLatestRequestFaild...).
function shop_ui.present.each_si(fn)
    local holder = sdk.get_managed_singleton("app.ItemSpawnInfoHolder")
    local list = holder and holder:get_field("ItemSpawnInfoEnemyDropUseList")
    if not list then return end
    for i = 0, list:call("get_Count") - 1 do
        local si = list:call("get_Item", i)
        if si and fn(si) then return end
    end
end
function shop_ui.present.each_get(fn)
    shop_ui.present.each_si(function(si)
        local get = si:get_field("SpawnedInteractItemGetCache")
        return get and fn(get)
    end)
end
function shop_ui.present.describe_new(p)
    shop_ui.present.each_si(function(si)
        local inst0 = nil
        pcall(function() inst0 = si:call("get_spawnInstance") end)
        if inst0 and p.before_si[inst0:get_address()] then return false end
        local f = {}
        for _, name in ipairs({ "RequestDropItemID", "IsSpawned", "IsLatestRequestFaild", "IsRequestEnemyDropCancel",
                "IsReserveSpawn", "IsUsingSpawn", "IsRequestedSpawnOrResume", "RequestEnemyDropForUpdate" }) do
            local v = "?"
            pcall(function() v = tostring(si:get_field(name)) end)
            f[#f + 1] = name .. "=" .. v
        end
        local inst = nil
        pcall(function() inst = si:call("get_spawnInstance") end)
        f[#f + 1] = "spawnInstance=" .. (inst and "oui" or "nil")
        debug_log("présentation (test) : entrée de drop : " .. table.concat(f, " "))
        return false
    end)
end
function shop_ui.present.counts()
    local holder = sdk.get_managed_singleton("app.ItemSpawnInfoHolder")
    local out = {}
    for _, f in ipairs({ "ItemSpawnInfoEnemyDropUseList", "ItemSpawnInfoEnemyDropList" }) do
        local n = "?"
        pcall(function() n = holder:get_field(f):call("get_Count") end)
        out[#out + 1] = f .. "=" .. tostring(n)
    end
    return table.concat(out, " ")
end
function shop_ui.present.start(id, method)
    local player = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
    if not player or not id then
        debug_log("présentation (test) : joueur ou ItemID introuvable")
        return
    end
    local tf = player:call("get_Transform")
    local pos, rot = tf:call("get_Position"), tf:call("get_Rotation")
    local holder = sdk.get_managed_singleton("app.ItemSpawnInfoHolder")
    local drop = nil
    for _, m in ipairs(holder:get_type_definition():get_methods()) do
        if m:get_name() == "RequestEnemyDrop" and m:get_num_params() == 9 then drop = m end
    end
    local before, before_si = {}, {}
    shop_ui.present.each_get(function(get) before[get:get_address()] = true end)
    -- Entrées de drop recyclées (2026-10-07 : liste restée à 7, aucune « nouvelle » entrée) : on
    -- retient les spawnInstance existants, le nouvel objet est celui dont l'instance est nouvelle.
    shop_ui.present.each_si(function(si)
        local inst = nil
        pcall(function() inst = si:call("get_spawnInstance") end)
        if inst then before_si[inst:get_address()] = true end
    end)
    local counts = shop_ui.present.counts()
    local handle = drop:call(holder, id, 1, pos, rot, pos, rot, true, 0.0, true)
    debug_log("présentation (test) : RequestEnemyDrop -> " .. tostring(handle) .. " ; avant : " .. counts)
    shop_ui.present.pending = { id = id, method = method, before = before, before_si = before_si, until_t = os.clock() + 8,
        player = player:add_ref() }
    debug_log("présentation (test) : objet " .. tostring(id) .. " lâché aux pieds d'Ethan, méthode " .. method)
end
function shop_ui.present.update()
    local p = shop_ui.present.pending
    if not p then return end
    if os.clock() > p.until_t then
        shop_ui.present.pending = nil
        debug_log("présentation (test) : objet lâché introuvable après 8 s ; après : " .. shop_ui.present.counts())
        pcall(shop_ui.present.describe_new, p)
        return
    end
    if os.clock() < (p.next_t or 0) then return end
    p.next_t = os.clock() + 0.25
    -- 3e essai (Poudre noire, 2026-10-07) : objet bien posé (IsSpawned, spawnInstance) mais
    -- SpawnedInteractItemGetCache vide : l'InteractItemGet est pris sur le spawnInstance de la
    -- NOUVELLE entrée de drop (comme shop_ui.world.instance_get), sans comparer l'ItemID.
    -- Les objets clés, eux, ne sont jamais posés par ce système (entrée réservée, rien au sol).
    shop_ui.present.each_si(function(si)
        local inst, get = nil, nil
        pcall(function() inst = si:call("get_spawnInstance") end)
        if not inst or p.before_si[inst:get_address()] then return false end
        pcall(function() get = inst:call("getComponent(System.Type)", sdk.typeof("app.InteractItemGet")) end)
        get = get or si:get_field("SpawnedInteractItemGetCache")
        if not get then return false end
        shop_ui.present.pending = nil
        local ok, err = pcall(function()
            if p.method == 1 then
                sdk.get_managed_singleton("app.InteractManager"):call("RequestForceInteract", get, p.player)
            else
                get:call("startDetailSearch", p.player)
            end
        end)
        debug_log(string.format("présentation (test) : objet %s retrouvé, méthode %d : %s",
            tostring(p.id), p.method, ok and "appel fait" or ("ERREUR " .. tostring(err))))
        return true
    end)
end

-- Voix des personnages (2026-10-07, idée du joueur) : rire de Dimitrescu / d'une sœur quand on
-- REÇOIT un piège, réplique « bonne chance » quand on ramasse un piège pour un autre joueur.
-- Outil de relevé : pendant 20 s, toutes les méthodes trigger* de via.wwise.WwiseContainer sont
-- écoutées (ID du son + nom de l'objet qui le joue), résumé dans le journal (« voix : »). Puis
-- essai de relecture d'un ID de 3 façons : son système (WwiseManagerApp), sur Ethan (son
-- WwiseContainer), sur l'objet qui l'a joué au relevé (banque de son du personnage chargée).
shop_ui.voice = { seen = {}, until_t = 0, installed = false, id_text = "" }
-- 1er relevé (sœur qui rit en cinématique, 2026-10-07) : 0 son via les trigger* de
-- via.wwise.WwiseContainer. Ajouts : trigger* d'app.WwiseContainerApp, et surtout son rappel
-- triggered(gameObject, requestInfo, [jointhash,] requestId), appelé pour chaque son joué (aussi
-- ceux des animations) ; ID du son = via.wwise.WwiseManager.getTriggerIdByRequestId(requestId).
function shop_ui.voice.record(id, owner, method)
    local rec = shop_ui.voice.seen[id]
    if rec then rec.count = rec.count + 1 return end
    shop_ui.voice.seen[id] = { count = 1, owner = owner, method = method, t = os.clock() }
end
function shop_ui.voice.install()
    if shop_ui.voice.installed then return end
    shop_ui.voice.installed = true
    local n = 0
    local wm = sdk.find_type_definition("via.wwise.WwiseManager"):get_method("getTriggerIdByRequestId")
    for _, tname in ipairs({ "via.wwise.WwiseContainer", "app.WwiseContainerApp" }) do
        local def = sdk.find_type_definition(tname)
        for _, m in ipairs(def and def:get_methods() or {}) do
            local name = m:get_name()
            local types = m:get_param_types() or {}
            if name:sub(1, 7) == "trigger" and name ~= "triggered" then
                local pos = nil
                for i, t in ipairs(types) do
                    if not pos and t:get_full_name() == "System.UInt32" then pos = i end
                end
                if pos then
                    n = n + 1
                    sdk.hook(m, function(args)
                        if os.clock() < shop_ui.voice.until_t then
                            pcall(function()
                                -- Méthodes natives (via.*) : pas de contexte en args[1] (2026-10-07 :
                                -- ID faux et objet « ? » avec args[2] / pos+2). On essaie les deux.
                                local shift = 2
                                local owner = "?"
                                pcall(function() owner = sdk.to_managed_object(args[2]):call("get_GameObject"):call("get_Name") end)
                                if owner == "?" then
                                    pcall(function() owner = sdk.to_managed_object(args[1]):call("get_GameObject"):call("get_Name") end)
                                    if owner ~= "?" then shift = 1 end
                                end
                                local id = sdk.to_int64(args[pos + shift]) & 0xFFFFFFFF
                                if shop_ui.voice.seen[id] then shop_ui.voice.record(id) return end
                                shop_ui.voice.record(id, owner, tname .. "." .. name .. (shift == 1 and " (natif)" or ""))
                            end)
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end, function(retval) return retval end)
                end
            elseif name == "triggered" then
                local last = #types
                n = n + 1
                sdk.hook(m, function(args)
                    if os.clock() < shop_ui.voice.until_t then
                        pcall(function()
                            -- 2e relevé : getTriggerIdByRequestId renvoyait toujours 4294967295
                            -- (em1261 x19) : ID lu dans le RequestInfo (TriggerId, sinon EventId).
                            local info = sdk.to_managed_object(args[4])
                            local id = info and info:call("get_TriggerId")
                            if not id or id == 0 or id == 4294967295 then
                                id = info and info:call("get_EventId")
                            end
                            if not id or id == 0 or id == 4294967295 then
                                id = wm:call(nil, sdk.to_int64(args[last + 2]) & 0xFFFFFFFF)
                            end
                            if shop_ui.voice.seen[id] then shop_ui.voice.record(id) return end
                            local owner = "?"
                            pcall(function() owner = sdk.to_managed_object(args[3]):call("get_Name") end)
                            if owner == "?" then
                                pcall(function() owner = sdk.to_managed_object(args[2]):call("get_GameObject"):call("get_Name") end)
                            end
                            shop_ui.voice.record(id, owner, "triggered")
                        end)
                    end
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval) return retval end)
            end
        end
    end
    debug_log("voix : relevé posé sur " .. n .. " méthodes")
end
function shop_ui.voice.start()
    pcall(shop_ui.voice.install)
    shop_ui.voice.seen = {}
    shop_ui.voice.until_t = os.clock() + 20
    shop_ui.voice.reported = false
    debug_log("voix : relevé pendant 20 s")
end
function shop_ui.voice.update()
    if shop_ui.voice.reported or shop_ui.voice.until_t == 0 or os.clock() < shop_ui.voice.until_t then return end
    shop_ui.voice.reported = true
    local list = {}
    for id, rec in pairs(shop_ui.voice.seen) do list[#list + 1] = { id = id, rec = rec } end
    table.sort(list, function(a, b) return a.rec.t < b.rec.t end)
    debug_log("voix : fin du relevé, " .. #list .. " son(s) différent(s)")
    for _, e in ipairs(list) do
        debug_log(string.format("voix : %d  objet=%s  x%d  (%s, +%.1f s)", e.id, e.rec.owner, e.rec.count,
            e.rec.method, e.rec.t - (shop_ui.voice.until_t - 20)))
    end
end
-- Fichier audio joué hors du jeu (2026-10-07, test) : le jeu ne lit que ses propres sons ; on
-- demande à Windows de lire un .wav (lecteur PowerShell caché). Deux variantes à comparer
-- (fenêtre qui clignote ? sortie du plein écran ?) : os.execute et io.popen.
shop_ui.voice.TEST_WAV = "C:/Windows/Media/tada.wav"
function shop_ui.voice.play_file(path, how)
    local ps = string.format([[powershell -NoProfile -WindowStyle Hidden -Command "(New-Object Media.SoundPlayer '%s').PlaySync()"]], path)
    local ok, err = pcall(function()
        if how == "popen" then
            local f = io.popen(ps)
            if f then f:close() end
        else
            os.execute('start "" /b ' .. ps)
        end
    end)
    debug_log(string.format("son fichier (%s) : os=%s io.popen=%s -> %s", how, tostring(os and os.execute ~= nil),
        tostring(io and io.popen ~= nil), ok and "appel fait" or ("ERREUR " .. tostring(err))))
    return ok and ("lecture demandée (" .. how .. ")") or ("erreur : " .. tostring(err))
end
-- Voix jouées en partie : conteneur du personnage positionné sur Ethan (seule méthode audible de
-- près, validée le 2026-10-07). owner = nom de l'objet du personnage dans la scène.
shop_ui.voice.TRAP_FOR_OTHER = { id = 2490342862, owner = "em1261" } -- Daniela : phrase + rire
function shop_ui.voice.play_near(v)
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    local go = scene:call("findGameObject(System.String)", v.owner)
    if not go then return false end
    local c = go:call("getComponent(System.Type)", sdk.typeof("via.wwise.WwiseContainer"))
    if not c then return false end
    local player = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
    c:call("trigger(System.UInt32, via.GameObject)", v.id, player)
    return true
end
-- Depuis le son ajouté à la banque système (2026-10-07) : joué partout par trigger système.
function shop_ui.voice.update_trap()
    if not shop_ui.voice.trap_pending then return end
    shop_ui.voice.trap_pending = false
    local id, lang = shop_ui.sound.voice_id(shop_ui.sound.AP.TRAP_FOR_OTHER)
    debug_log("son : piège pour un autre joueur -> phrase de Daniela (son AP " .. tostring(id) .. ", langue " .. tostring(lang) .. ")")
    shop_ui.sound.play_ap(id)
end
function shop_ui.voice.play(id, how)
    if not id then return "ID invalide" end
    local ok, err = pcall(function()
        if how == "system" then
            sdk.get_managed_singleton("app.WwiseManagerApp"):call("trigger(System.UInt32)", id)
        elseif how == "ethan" then
            local player = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
            local c = player:call("getComponent(System.Type)", sdk.typeof("via.wwise.WwiseContainer"))
            c:call("trigger(System.UInt32)", id)
        else
            -- objet qui a joué ce son au relevé, retrouvé par son nom dans la scène
            -- sans relevé dans cette session : objet par défaut em1261 (Daniela, phrase + rire
            -- 2490342862, trouvés le 2026-10-07)
            local rec = shop_ui.voice.seen[id] or { owner = "em1261" }
            local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
            local go = scene:call("findGameObject(System.String)", rec.owner)
            local c = go:call("getComponent(System.Type)", sdk.typeof("via.wwise.WwiseContainer"))
            if how == "owner_at_ethan" then
                -- 2026-10-07 : « sur Ethan » muet (le conteneur d'Ethan ne connaît pas les sons de
                -- Daniela), « sur le personnage » audible mais lointain : son joué par le conteneur
                -- du personnage, POSITIONNÉ sur Ethan (trigger(UInt32, GameObject)).
                local player = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
                c:call("trigger(System.UInt32, via.GameObject)", id, player)
            else
                c:call("trigger(System.UInt32)", id)
            end
        end
    end)
    debug_log(string.format("voix : lecture %d (%s) : %s", id, how, ok and "appel fait" or ("ERREUR " .. tostring(err))))
    return ok and ("joué (" .. how .. ")") or ("erreur : " .. tostring(err))
end

function shop_ui.sound.update()
    if shop_ui.detail.note then
        debug_log(shop_ui.detail.note)
        shop_ui.detail.note = nil
    end
    while shop_ui.detail.notes[1] do debug_log(table.remove(shop_ui.detail.notes, 1)) end
    if shop_ui.world and shop_ui.world.detail_note then
        debug_log(shop_ui.world.detail_note)
        shop_ui.world.detail_note = nil
    end
    if shop_ui.sound.pending then
        shop_ui.sound.play(shop_ui.sound.pending)
        shop_ui.sound.pending = nil
    end
    if is_in_game() then
        pcall(shop_ui.sound.mute_hook)
        pcall(shop_ui.sound.refresh_ap_inst)
    end
    if shop_ui.sound.pending_ap then
        shop_ui.sound.play_ap(shop_ui.sound.pending_ap)
        debug_log("son : bruit de ramassage AP " .. shop_ui.sound.pending_ap)
        shop_ui.sound.pending_ap = nil
    end
    if shop_ui.world_exchange and shop_ui.world_exchange.last then
        debug_log("échange arme/pièce -> Lei évité : " .. shop_ui.world_exchange.last .. " (" .. shop_ui.world_exchange.blocked .. " au total)")
        shop_ui.world_exchange.last = nil
    end
    if shop_ui.sound.muted_note then
        debug_log("son : bruit d'origine coupé (" .. shop_ui.sound.muted_note .. ")")
        shop_ui.sound.muted_note = nil
    end
    if #shop_ui.sound.ids > 0 and os.clock() >= shop_ui.sound.capture_until then
        debug_log(string.format("son : ramassage de l'objet %s -> %s", tostring(shop_ui.sound.capture_item),
            table.concat(shop_ui.sound.ids, ", ")))
        shop_ui.sound.ids = {}
    end
end

-- Articles-checks achetés mais pas encore envoyés : le jeu reconstruit la liste du Duc juste
-- après l'achat, avant que la boucle n'envoie le check (l'article restait affiché). Vidé à
-- chaque connexion.

-- Objets placés : boutique ET emplacements au sol (modèles et noms "[AP]", 2026-09-27).
local function scout_shop_locations()
    local ids = {}
    for _, list in pairs(shop_locations_by_item) do
        for _, loc in ipairs(list) do
            local id = get_location_id(loc)
            if id then ids[#ids + 1] = id end
        end
    end
    local shop_count = #ids
    for guid in pairs(location_by_guid) do
        local id = location_id_by_guid[guid]
        if id then ids[#ids + 1] = id end
    end
    if #ids > 0 then net.location_scouts(ids) end
    debug_log(string.format("scout : %d locations demandées au serveur (%d boutique)", #ids, shop_count))
end

local function on_connected(ev)
    death_link.enabled = ev and ev.death_link == true
    required_difficulty = ev and ev.difficulty ~= "" and ev.difficulty or nil
    goal_mode = (ev and ev.goal ~= "" and ev.goal) or "fin_du_jeu"
    missable_mode = (ev and ev.missable ~= "" and ev.missable) or "envoi_auto"
    load_state(net.get_seed(), net.get_slot())
    -- Bug du 2026-09-27 : passage de la vraie partie (38281) au serveur de test (38282) sans
    -- relancer le jeu ; l'historique des objets de la vraie partie a été redonné dans la partie
    -- de test (38 objets, puis crash). Historique et file d'attente repartent donc de zéro à
    -- chaque connexion (le serveur renvoie tous les objets de CETTE partie juste après).
    save_sync.history = {}
    items_queue = {}
    cache_location_ids()
    checked_ids = {}
    checked_count = 0
    goal_sent = false
    add_message(string.format(tr("Connecté (%s). %d checks en attente d'envoi.", "Connected (%s). %d checks waiting to be sent."),
        tostring(session.slot), #state.pending_checks))
    send_pending_checks()
    for key in pairs(shop_ui.key_offline) do
        local loc = location_by_guid[key]
        if loc and get_location_id(loc) then queue_check(loc) end
    end
    shop_ui.key_offline = {}
    scouted_items = {}
    scout_shop_locations()
    shop_ui.bought = {}
    shop_ui.offered = {}
end


-- location_checked arrive à la connexion avec les checks déjà connus du serveur, mais pas
-- après nos propres envois : ceux-là sont comptés localement dans send_pending_checks.
local function mark_checked(ids)
    local n = 0
    for _, id in ipairs(ids) do add_checked(id); n = n + 1 end
    debug_log(string.format("location_checked reçu : %d ids, total validé %d", n, checked_count))
    -- Jumelle restée seule (partie commencée avant le lien des emplacements jumeaux) : rattrapée.
    local twins = {}
    for id, twin in pairs(K.twin_ids) do
        if checked_ids[id] and not checked_ids[twin] then table.insert(twins, twin) end
    end
    if #twins > 0 and is_connected() then
        debug_log(string.format("emplacements jumeaux : %d rattrapé(s)", #twins))
        net.location_checks(twins)
        for _, id in ipairs(twins) do add_checked(id) end
    end

    local still_pending = {}
    for _, guid in ipairs(state.pending_checks) do
        local id = location_id_by_guid[guid]
        if not (id and checked_ids[id]) then table.insert(still_pending, guid) end
    end
    state.pending_checks = still_pending
    save_state()
    check_goal()
end

-- Événements réseau, décodés par net.poll() (voir re_village_ap/net.lua).
local function process_network()
    for _, ev in ipairs(net.poll()) do
        if ev.kind == "connected" then
            on_connected(ev)
        elseif ev.kind == "item" then
            save_sync.history[ev.index] = ev
            ev.level = 1
            for index, row in pairs(save_sync.history) do
                if index < ev.index and row.item == ev.item then ev.level = ev.level + 1 end
            end
            items_queue[#items_queue + 1] = ev
        elseif ev.kind == "checked" then
            mark_checked(ev.ids)
        elseif ev.kind == "death" then
            death_link.receive(ev)
        elseif ev.kind == "scout" then
            local game = net.get_player_game(ev.player)
            local name = net.get_item_name(ev.item, game) or ("objet " .. tostring(ev.item))
            local mine = ev.player == net.get_player_number()
            local player = net.get_player_alias(ev.player)
            -- Nom affiché sans le « (1) » / « (2) » des variantes (« Compensateur de recul (LEMI) (2) »,
            -- 2026-09-29) ; name garde le nom exact (items.json).
            scouted_items[ev.location] = { name = name, mine = mine, player = player, game = game or "?",
                flags = ev.flags or 0, -- classement AP : 1 = progression, 2 = utile, 4 = piège
                label = mine and (name:gsub("%s*%(%d+%)$", "")) or (name .. " (" .. player .. ")") }
            shop_ui.scout_count = (shop_ui.scout_count or 0) + 1
            if shop_ui.scout_count == 1 or (not mine and shop_ui.scout_count < 20) then
                debug_log(string.format("scout : %s -> %s (joueur %s, à moi : %s), %d réponse(s)",
                    tostring(ev.location), name, tostring(player), tostring(mine), shop_ui.scout_count))
            end
        elseif ev.kind == "disconnected" then
            add_message(tr("Déconnecté du serveur Archipelago.", "Disconnected from the Archipelago server."))
        elseif ev.kind == "print" then
            pcall(shop_ui.journal.add, ev.type, ev.text)
        elseif ev.kind == "hints" then
            pcall(shop_ui.hints.set, ev.list)
        elseif ev.kind == "refused" then
            add_message(tr("Connexion refusée : ", "Connection refused: ") .. ev.text)
            pcall(shop_ui.notice.on_refused, ev.text)
        elseif ev.kind == "error" and ev.text ~= "" then
            debug_log("erreur réseau : " .. ev.text)
        end
    end
end

---------------------------------------------------------------------------
-- Détection des ramassages
---------------------------------------------------------------------------

-- Retrait de l'objet d'origine. Crash du 2026-09-25 : on retirait get_stackSize() de l'objet
-- ramassé, qui valait en fait la pile TOTALE de l'inventaire (3 poudres au lieu d'1), et on le
-- faisait à la frame suivante, pendant l'animation de ramassage. Maintenant :
--   - la quantité de chaque objet concerné est photographiée à chaque frame (quantities_before) ;
--   - au ramassage, on garde la quantité d'avant ;
--   - 2 s plus tard, et seulement "en jeu", on retire la différence (quantité actuelle - avant).
local REMOVAL_DELAY_SECONDS = 2.0
local quantities_before = {}
local tracked_item_ids = {}
for _, item in ipairs(items) do
    if item.game_item_id and item.type ~= "Money" then tracked_item_ids[item.game_item_id] = true end
    for _, level_id in ipairs(item.levels or {}) do tracked_item_ids[level_id] = true end
end

local function get_money()
    local _, inv = get_active_inventory()
    if not inv then return nil end
    local ok, money = pcall(function() return inv:call("getMoney") end)
    return ok and money or nil
end

-- Arme en main (2026-09-25) : au ramassage d'une arme, le jeu la met en main pour
-- l'animation. Retirée de l'inventaire, elle restait tenue jusqu'au changement d'arme. On
-- mémorise l'arme tenue AVANT le ramassage pour la rééquiper après le retrait.
-- app.EquipController (composant du joueur) : EquipWeaponIdRight, equipWeapon(itemID, nom).
local equipped_before = nil

-- Recherche coûteuse (parcours de la scène) : résultat gardé 5 s.
local player_equip, player_equip_time = nil, -100

-- Test du 2026-09-25 : findComponents ne trouve AUCUN app.EquipController (c'est un "agent"
-- rangé dans CharacterCore, pas un composant de scène). On le récupère donc au vol : le jeu
-- appelle sans cesse isGunEquip / isMeleeEquip / currentPlayerWeaponId sur le contrôleur du
-- joueur. On garde celui qui gère le plus d'armes (les ennemis en ont aussi un).
local player_equip_address = nil
local player_equip_weapons = 0

local function consider_equip_controller(eq)
    if not eq then return end
    local ok_addr, addr = pcall(function() return eq:get_address() end)
    if not ok_addr or addr == player_equip_address then return end
    local ok, n = pcall(function() return eq:get_field("ManagedWeapons"):call("get_Count") end)
    if ok and n and n > player_equip_weapons then
        pcall(function() eq:add_ref() end)
        player_equip, player_equip_address, player_equip_weapons = eq, addr, n
    end
end

local function install_equip_capture()
    local def = sdk.find_type_definition("app.EquipController")
    if not def then return end
    for _, name in ipairs({ "isGunEquip", "isMeleeEquip", "currentPlayerWeaponId", "equipWeapon" }) do
        local method = def:get_method(name)
        if method then
            sdk.hook(method, function(args)
                pcall(function() consider_equip_controller(sdk.to_managed_object(args[2])) end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end
    end
end
install_equip_capture()

local function describe_equip_controllers()
    return { string.format("capturé : %s (%d armes)", tostring(player_equip_address), player_equip_weapons) }
end

local function get_player_equip()
    return player_equip
end

local function get_equipped_weapon_id()
    local eq = get_player_equip()
    if not eq then return nil end
    local ok, id = pcall(function() return eq:call("get_equipWeaponIdRight") end)
    return ok and id or nil
end

-- Test du 2026-09-25 : equipWeapon(itemID, "") ne fait rien. Essais, dans l'ordre :
--   A. equipWeapon(itemID, findEquipParamNameByID(itemID)) ;
--   B. equipWeapon(WeaponCore) avec l'arme de même ItemID dans get_EquipWeaponList().
local function equip_weapon(item_id)
    local eq = get_player_equip()
    if not eq then return false, "EquipController du joueur introuvable" end
    local before = get_equipped_weapon_id()

    local param_name = nil
    pcall(function() param_name = eq:call("findEquipParamNameByID", item_id) end)
    if param_name and param_name ~= "" then
        pcall(function() eq:call("equipWeapon(System.UInt32, System.String)", item_id, param_name) end)
        if get_equipped_weapon_id() == item_id then return true, "A (" .. param_name .. ")" end
    end

    local ids = {}
    local ok_b, err_b = pcall(function()
        local list = eq:call("get_EquipWeaponList")
        for i = 0, list:call("get_Count") - 1 do
            local w = list:call("get_Item", i)
            local wid = get_item_id_from_core(w)
            ids[#ids + 1] = tostring(wid)
            if wid == item_id then
                eq:call("equipWeapon(app.WeaponCore)", w)
                return
            end
        end
    end)
    if get_equipped_weapon_id() == item_id then return true, "B (WeaponCore)" end
    return false, string.format("échec (param=%s, B=%s, armes=%s, avant=%s)", tostring(param_name),
        ok_b and "ok" or tostring(err_b), table.concat(ids, ","), tostring(before))
end

-- 2 FPS pendant Miranda (2026-09-26) : on appelait inventory_quantity pour chacun des ~86
-- ItemID suivis, à chaque frame, soit un parcours complet de l'inventaire par ItemID.
-- Un seul parcours par frame suffit.
local function snapshot_quantities()
    if #vanilla_removals > 0 then return end -- ne pas écraser une quantité "avant" en cours d'usage
    local _, inv = get_active_inventory()
    local totals = {}
    local ok = inv and pcall(function()
        local list = inv:call("get_items")
        for i = 0, list:call("get_Count") - 1 do
            local work = list:call("get_Item", i):call("get_work")
            local id = work:call("get_itemID")
            if tracked_item_ids[id] then totals[id] = (totals[id] or 0) + work:call("get_stackSize") end
        end
    end)
    for item_id in pairs(tracked_item_ids) do
        quantities_before[item_id] = ok and (totals[item_id] or 0) or nil
    end
    quantities_before.money = get_money()
    equipped_before = get_equipped_weapon_id()
end
local last_pickup_debug = nil

local function log_pickup_debug(ident)
    last_pickup_debug = ident
    local file = io.open(MOD_NAME .. "/pickups_log.jsonl", "a")
    if file then
        file:write(json.dump_string(ident) .. "\n")
        file:close()
    end
end

local weapon_check_pending = {} -- ItemID -> os.clock() du ramassage d'une arme-check

local function on_item_picked(interact, core)
    debug_log("ramassage : début du hook")
    if shop_ui.sound.installed then
        shop_ui.sound.capture_until = os.clock() + 1.5
        pcall(function() shop_ui.sound.capture_item = get_item_id_from_core(core) end)
    end
    local go = nil
    pcall(function() go = interact:call("get_GameObject") end)
    local picked_item_id = get_item_id_from_core(core)
    if picked_item_id and BOSS_TROPHIES[picked_item_id] then
        table.insert(pending_boss_events, BOSS_TROPHIES[picked_item_id])
    end
    debug_log("ramassage : ItemID " .. tostring(picked_item_id) .. ", quantité avant " .. tostring(quantities_before[picked_item_id]) .. " ; recherche du placement")

    local spawn_info, dist = nil, nil
    -- Coffre à pièce d'arme (2026-09-27) : l'objet ramassé (LEMI (1)) n'était pas celui prévu
    -- (LEMI (2)), le placement n'était pas trouvé par numéro d'objet : pas de check, et l'objet
    -- d'origine gardé. On compare d'abord l'objet à ramasser lui-même à ceux des checks.
    -- Objets RECYCLÉS par le jeu (2026-10-07 : sac de Lei d'une caisse pris pour « Sac de Lei
    -- #011 [S01] », une autre salle, même objet réutilisé) : l'adresse ne suffit pas, l'emplacement
    -- doit être à moins de 3 m de l'objet ramassé.
    pcall(function()
        local addr = interact:get_address()
        local gp = go and get_gameobject_identity(go).item_position
        local close = function(e)
            if not gp then return true end
            local ep = get_spawn_info_identity(e.si).item_position
            return ep ~= nil and (ep[1] - gp[1]) ^ 2 + (ep[2] - gp[2]) ^ 2 + (ep[3] - gp[3]) ^ 2 < 9
        end
        for _, e in ipairs(shop_ui.world.entries or {}) do
            local get = e.si:get_field("SpawnedInteractItemGetCache")
            if get and get:get_address() == addr and close(e) then spawn_info, dist = e.si, 0 break end
            -- Objet apparu à la casse / l'ouverture (autre que le cache, voir instance_get).
            local inst_get = shop_ui.world.instance_get(e)
            if inst_get and inst_get:get_address() == addr and close(e) then spawn_info, dist = e.si, 0 break end
        end
    end)
    local by_position = false
    if not spawn_info then
        spawn_info, dist = find_spawn_info_for(go, picked_item_id)
        by_position = spawn_info ~= nil
    end
    debug_log("ramassage : placement trouvé = " .. tostring(spawn_info ~= nil) .. " ; lecture identité")
    local ident = spawn_info and get_spawn_info_identity(spawn_info) or {}
    ident.picked_item_id = picked_item_id
    -- objets ramassés (repères d'envoi automatique, données : auto_send_when.item_id)
    shop_ui.picked_item_ids = shop_ui.picked_item_ids or {}
    if picked_item_id then shop_ui.picked_item_ids[picked_item_id] = true end
    ident.match_distance = dist
    local loc = ident.guid and location_by_guid[ident.guid]
    -- Emplacement d'un autre chapitre (2026-10-07, couteau de départ, voir shop_ui.world.update) :
    -- pas de check envoyé pour lui
    if loc and shop_ui.other_chapter(loc) then
        debug_log("ramassage : " .. loc.name .. " ignoré (emplacement d'un autre chapitre, chapitre en cours " .. tostring(shop_ui.chapter) .. ")")
        loc = nil
    end
    -- Caisses / pots au contenu aléatoire (2026-10-07, demande du joueur : « pour toutes les box
    -- sans check ») : reconnu seulement par la position (objet du même numéro à moins de 3 m),
    -- un objet de caisse ne doit pas valider un check déjà fait ni un check à plus de 3 m (sinon
    -- l'objet ramassé était retiré pour rien).
    if loc and by_position and ((dist or 99) > 3 or shop_ui.location_done(loc) ~= false) then
        debug_log(string.format("ramassage : %s ignoré (reconnu par position à %.1f m, déjà fait : %s)",
            loc.name, dist or -1, tostring(shop_ui.location_done(loc))))
        loc = nil
    end
    -- Rayon de reconnaissance : 20 m, ou drop_radius de la location (2026-10-07 : la hache du
    -- gardien de la tombe tombe où il meurt, n'importe où dans son arène).
    -- Drop de boss (2026-09-30) : trésor lâché ramassé = 1er check de ce trésor pas encore fait
    -- (le jeu ne dit pas quel boss ; l'ordre des boss est fixe). Tous faits : ramassage normal.
    if not loc and picked_item_id and (locations.boss_drops or {})[picked_item_id] then
        -- Drop le plus proche de sa position dans la partie de référence (moins de 20 m) : c'est
        -- ce boss-là, même s'il a déjà été compté (retué après un rechargement : rien de neuf).
        local pos = ident.item_position
        local best, best_d = nil, math.huge
        for _, candidate in ipairs(pos and locations.boss_drops[picked_item_id] or {}) do
            local cp = candidate.drop_position
            if cp then
                local d = (cp[1] - pos[1]) ^ 2 + (cp[2] - pos[2]) ^ 2 + (cp[3] - pos[3]) ^ 2
                if d < best_d and d < (candidate.drop_radius or 20) ^ 2 then best, best_d = candidate, d end
            end
        end
        if best then loc = best end
        debug_log(string.format("drop de boss : position %s -> %s", pos and table.concat(pos, " ") or "?",
            best and best.name or "aucune proche, 1er check non fait"))
    end
    -- Mallette à pièce d'arme (2026-10-01) : l'objet posé par le jeu à l'ouverture (LEMI (1)) n'est
    -- pas toujours relié à temps à l'emplacement (relevé toutes les 0,5 s) ; ramassé juste après
    -- l'ouverture, le check était perdu et le vrai LEMI gardé. Secours : même objet ou variante de
    -- l'objet d'origine d'un check posé à moins de 3 m.
    if not loc then
        pcall(function() loc = shop_ui.world.case_gets[interact:get_address()] end)
        -- objet recyclé après coup (voir plus haut) : seulement un check pas encore fait
        if loc and shop_ui.location_done(loc) ~= false then loc = nil end
        if loc then debug_log("ramassage : objet de mallette modifié -> " .. loc.name) end
    end
    if not loc and picked_item_id then
        pcall(function()
            local gp = go and get_gameobject_identity(go).item_position
            if not gp then return end
            for _, e in ipairs(shop_ui.world.entries or {}) do
                local orig = item_by_name[e.loc.original_item or ""]
                local oid = orig and orig.game_item_id
                if oid and (oid == picked_item_id or orig.give_id == picked_item_id
                        or shop_ui.world.same_variant(oid, picked_item_id)) then
                    local ep = get_gameobject_identity(e.si:call("get_GameObject")).item_position
                    local d2 = ep and ((ep[1] - gp[1]) ^ 2 + (ep[2] - gp[2]) ^ 2 + (ep[3] - gp[3]) ^ 2)
                    if d2 and d2 < 9 and shop_ui.location_done(e.loc) == false then
                        loc = e.loc
                        debug_log(string.format("ramassage : %s reconnu par l'objet (%s, %.1f m)", e.loc.name,
                            tostring(picked_item_id), math.sqrt(d2)))
                        break
                    end
                end
            end
        end)
    end
    if not loc and picked_item_id and (locations.boss_drops or {})[picked_item_id] then
        for _, candidate in ipairs(locations.boss_drops[picked_item_id]) do
            local id = get_location_id(candidate)
            local pending = false
            for _, k in ipairs(state.pending_checks) do if k == candidate.key then pending = true end end
            if id and not checked_ids[id] and not pending then loc = candidate break end
        end
    end
    ident.location = loc and loc.name or nil
    debug_log("ramassage : écriture pickups_log")
    log_pickup_debug(ident)
    debug_log("ramassage : location = " .. tostring(ident.location))

    -- Viande d'animal ramassée hors emplacement AP (checks de chasse, 2026-10-07) : prochain check
    -- de cette viande actif dans la seed et pas encore fait (#1, puis #2...). Au-delà : viande normale.
    if not loc and picked_item_id and (locations.hunts or {})[picked_item_id] then
        for _, candidate in ipairs(locations.hunts[picked_item_id]) do
            if get_location_id(candidate) and shop_ui.location_done(candidate) == false then
                loc = candidate
                break
            end
        end
        debug_log("chasse : viande " .. tostring(picked_item_id) .. " -> " .. (loc and loc.name or "aucun check restant"))
        ident.location = loc and loc.name or nil
    end
    -- Fragments de cristal ramassés hors emplacement (2026-10-08, rapport du joueur : +13 Fragments à
    -- chaque fois, château) : objet de ramassage du mod (PICKUP_ID) réutilisé par le jeu avec la pile
    -- d'un autre objet. Tous les vrais Fragments sont des checks : celui-ci est retiré en entier.
    if not loc and picked_item_id and picked_item_id == shop_ui.world.PICKUP_ID then
        local stack = nil
        pcall(function() stack = core:call("get_work"):call("get_stackSize") end)
        debug_log(string.format("ramassage : Fragment de cristal hors emplacement (pile %s), retiré", tostring(stack)))
        table.insert(vanilla_removals, { item_id = picked_item_id, before = quantities_before[picked_item_id] or 0,
            due = os.clock() + REMOVAL_DELAY_SECONDS })
        return
    end
    if not loc then return end -- objet hors Archipelago (objet clé, drop d'ennemi...)
    -- Objet clé (2026-09-30) : check seulement si cette seed mélange les objets clés (location
    -- connue du serveur). Sinon ramassage normal. Pas connecté : ramassage normal aussi, et le
    -- check est envoyé à la connexion (shop_ui.key_offline) ; on garde alors l'objet d'origine.
    if loc.key_item_location and not get_location_id(loc) then
        if not is_connected() then
            shop_ui.key_offline[loc.key] = true
            debug_log("ramassage : objet clé hors connexion, check envoyé à la connexion : " .. loc.name)
        end
        return
    end
    save_sync.picked_locs = save_sync.picked_locs or {}
    save_sync.picked_locs[loc.key] = true -- objet au sol : modèle d'origine remis (objet recyclé)
    shop_ui.sound.on_pickup(loc, picked_item_id)
    shop_ui.detail.on_pickup(loc)
    -- Objet clé à moi ramassé sous sa vraie forme (swap_pickup) : on le garde (pas de retrait), le
    -- serveur ne le redonnera pas (state.given_by_pickup, apply_item).
    do
        local lid = get_location_id(loc)
        local sc = lid and scouted_items[lid]
        local own = sc and sc.mine and item_by_name[sc.name]
        if own and own.type == "Key" and not own.levels and picked_item_id == own.game_item_id
                and not checked_ids[lid] then
            state.given_by_pickup = state.given_by_pickup or {}
            state.given_by_pickup[tostring(lid)] = true
            table.insert(picked_locations, loc)
            debug_log("ramassage : objet clé " .. sc.name .. " ramassé tel quel, gardé")
            return
        end
    end

    -- Chasse (option 2 du joueur, 2026-10-07) : traitée comme les autres checks (viande habillée
    -- en objet AP au sol, objet AP reçu, viande retirée ; elle revient par le pool). Avant : viande
    -- gardée et objet AP donné à part.

    -- Un sac de Lei ramassé ajoute directement de l'argent (500 Lei, test du 2026-09-25) :
    -- on retire alors la différence d'argent au lieu d'un objet.
    -- Caisse cassée : Lei posés par le jeu à la place de l'objet prévu (2026-09-27).
    local is_money = loc.original_item == "Sac de Lei" or picked_item_id == (item_by_name["Sac de Lei"] or {}).game_item_id
    local item_def = item_by_name[loc.original_item]
    local is_weapon = item_def and item_def.type == "Weapon" and picked_item_id == item_def.game_item_id
    if is_weapon then weapon_check_pending[picked_item_id] = os.clock() end
    table.insert(vanilla_removals, {
        item_id = picked_item_id,
        money = is_money,
        weapon = is_weapon,
        equipped_before = equipped_before,
        before = (is_money and quantities_before.money or quantities_before[picked_item_id]) or 0,
        due = os.clock() + REMOVAL_DELAY_SECONDS,
    })
    table.insert(picked_locations, loc) -- envoyé plus tard par la boucle principale
    debug_log("ramassage : fin du hook")
end

local function process_vanilla_removals()
    if #vanilla_removals == 0 then return end
    if not is_in_game() then return end -- présentation ouverte, menu... (plantage du 2026-10-01)
    local _, inv = get_active_inventory()
    if not inv then return end
    local now = os.clock()
    local remaining = {}
    for _, r in ipairs(vanilla_removals) do
        if now < r.due then
            table.insert(remaining, r)
        elseif r.money then
            local current = get_money()
            local delta = current and (current - r.before) or 0
            debug_log(string.format("retrait Lei : avant=%d maintenant=%s delta=%d", r.before, tostring(current), delta))
            if delta > 0 then
                local ok, err = pcall(function() inv:call("setMoney", current - delta) end)
                debug_log("retrait Lei : " .. (ok and "ok" or tostring(err)))
            end
        else
            if r.shop_price and r.money_before then
                local now_money = get_money()
                local charged = now_money and (r.money_before - now_money) or 0
                debug_log(string.format("achat-check : Lei %d -> %s, prix %d, débité par le jeu %d",
                    r.money_before, tostring(now_money), r.shop_price, charged))
                -- Test du 2026-09-26 (Valise) : le prix change avec l'avancement (10 000 débités,
                -- 50 000 dans les données de fin de partie) et le mod avait retiré 40 000 de plus.
                -- Le mod ne débite donc QUE si le jeu n'a rien débité (article déjà possédé), et
                -- jamais en dessous de 0.
                if now_money and charged <= 0 then
                    local price = math.min(r.unit_price or r.shop_price, now_money)
                    local ok = pcall(function() inv:call("setMoney", now_money - price) end)
                    debug_log(string.format("achat-check : le jeu n'a rien débité, %d retirés par le mod (%s)",
                        price, ok and "ok" or "échec"))
                end
            end
            if r.shop_price then debug_log("boutique : mallette APRÈS achat : " .. inventory_dump()) end
            debug_log("retrait : lecture quantité de " .. tostring(r.item_id))
            local current = inventory_quantity(r.item_id)
            local delta = current and (current - r.before) or 0
            debug_log(string.format("retrait : avant=%d maintenant=%s delta=%d", r.before, tostring(current), delta))
            log.info(string.format("[%s] Retrait objet d'origine %s : avant %d, maintenant %s, retrait %d",
                MOD_NAME, tostring(r.item_id), r.before, tostring(current), delta))
            if delta > 0 then
                debug_log("retrait : appel reduceItem")
                local ok, err = pcall(function()
                    inv:call("reduceItem(System.UInt32, System.Int32, System.Boolean, System.Boolean)", r.item_id, delta, false, false)
                end)
                debug_log("retrait : reduceItem terminé, " .. (ok and "ok" or tostring(err)))
                -- reduceItem peut répondre « ok » sans rien retirer (Fragments accumulés, 2026-10-08) :
                -- on vérifie, et on retire directement dans les piles si besoin.
                local after = inventory_quantity(r.item_id)
                if after and after > current - delta then
                    local ok2, taken = pcall(shop_ui.inv_take, inv, r.item_id, after - (current - delta))
                    debug_log(string.format("retrait : reduceItem sans effet (%d), retrait direct dans les piles : %s",
                        after, ok2 and (tostring(taken) .. " retiré(s)") or tostring(taken)))
                end
                if r.weapon then
                    debug_log(string.format("retrait arme : en main avant=%s, maintenant=%s",
                        tostring(r.equipped_before), tostring(get_equipped_weapon_id())))
                end
                if not ok then
                    log.warn(string.format("[%s] reduceItem a échoué : %s", MOD_NAME, tostring(err)))
                end
            end
            if r.recipe_before and (r.recipe_before.history == false or recipe_count(r.item_id) > r.recipe_before.recipes) then
                forget_recipe(r.item_id, r.recipe_before.recipes, r.recipe_before.history)
            end
            if r.craft_before then
                craft_state_ids() -- journal : liste après l'achat
                local removed = remove_new_craft_states(r.craft_before)
                if #removed > 0 then
                    debug_log("formule : recette(s) débloquée(s) par l'achat-check retirée(s) : " .. table.concat(removed, ", "))
                end
            end
            if r.restore_level then
                -- Valise achetée comme check : on remet l'ancien niveau de mallette.
                valise_level_before = nil
                local ok_level = pcall(function() inv:call("setExtendLevel", r.restore_level) end)
                local ok_sync = sync_last_slots(inv)
                local max = nil
                pcall(function() max = inv:call("getMaxSlotCount") end)
                debug_log(string.format("valise : niveau de mallette remis (%s), cases max %s, cases alignées %s",
                    ok_level and "ok" or "échec", tostring(max), tostring(ok_sync)))
                -- 1er test : un objet Valise restait dans la mallette après la remise du niveau.
                local left = (inventory_quantity(VALISE_ITEM_ID) or 0) - r.before
                if left > 0 then
                    local ok_again = pcall(function()
                        inv:call("reduceItem(System.UInt32, System.Int32, System.Boolean, System.Boolean)", VALISE_ITEM_ID, left, false, false)
                    end)
                    debug_log(string.format("valise : %d objet(s) Valise encore présent(s) après la remise, retrait : %s, reste %s",
                        left, ok_again and "ok" or "échec", tostring(inventory_quantity(VALISE_ITEM_ID))))
                end
            end
        end
    end
    vanilla_removals = remaining
end

-- Mise en main automatique d'une arme ramassée : app.PlayerMovement.requestUseGetWeapon(item).
-- Rééquiper l'arme précédente via EquipController.equipWeapon cassait l'animation (test du
-- 2026-09-25 : arme rangée sans rien sortir, puis deux armes en main). On BLOQUE donc la mise
-- en main quand l'arme ramassée est un check, au lieu de la corriger après coup.
-- Le hook de ramassage note l'ItemID de chaque arme-check ; si la mise en main arrive
-- avant, on consulte la liste des locations d'armes pas encore validées.

-- Test du 2026-09-25 (Wolfsbane) : app.PlayerMovement.requestUseGetWeapon n'est PAS appelé ;
-- Ethan utilise sans doute une variante générique (PlayerMovementTPS<...Pl1001>). On bloque
-- toutes les variantes trouvées, et on journalise d'autres candidates pour vérifier.
K.AUTOEQUIP_BLOCK_TYPES = {
    "app.PlayerMovement",
    "app.PlayerMovementTPS`1<app.PlayerReferenceContainerPl1001>",
    "app.PlayerMovementTPS`1<app.PlayerReferenceContainerTPS>",
    "app.PlayerMovementTPS`1",
}
K.AUTOEQUIP_LOG_ONLY = {
    { "app.PlayerOrder", "notifyPickUpWeapon" },
    { "app.PlayerOrder", "requestUseSavedEquipWeapon" },
}
-- Test du 2026-09-26 (M1897) : requestUseGetWeapon n'est jamais appelé. Au ramassage, le jeu
-- appelle PlayerOrder.notifyPickUpWeapon puis PlayerOrder.requestUseItem(ItemCore, for_event,
-- restore_request) -> Boolean, qui lance la mise en main (animation). requestUseItem sert aussi
-- aux changements d'arme normaux : on ne bloque que l'arme-check ramassée il y a moins de 3 s,
-- et on renvoie false (demande refusée). Pl2001 = Chris (même signature, relevé dans le dump).
K.USE_ITEM_BLOCK_TYPES = { "app.PlayerOrder", "app.PlayerOrderPl2001" }

local function install_use_item_block()
    for _, type_name in ipairs(K.USE_ITEM_BLOCK_TYPES) do
        local def = sdk.find_type_definition(type_name)
        local method = def and def:get_method("requestUseItem")
        if method then
            local skipped = false
            sdk.hook(method, function(args)
                skipped = false
                pcall(function()
                    local id = get_item_id_from_core(sdk.to_managed_object(args[3]))
                    local t = id and weapon_check_pending[id]
                    skipped = t ~= nil and os.clock() - t < 3.0
                    -- piège « Armes bloquées » (2026-10-08) : aucune mise en main, sauf les soins
                    if not skipped and shop_ui.traps and os.clock() < shop_ui.traps.jam_until
                            and not shop_ui.traps.is_heal(id) then
                        skipped = true
                    end
                    debug_log(string.format("arme (journal) : %s.requestUseItem(%s)%s", type_name,
                        tostring(id), skipped and " -> mise en main BLOQUÉE (arme-check)" or ""))
                end)
                if skipped then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                if skipped then
                    skipped = false
                    return sdk.to_ptr(0)
                end
                return retval
            end)
            debug_log("hook requestUseItem posé sur " .. type_name)
        end
    end
end

-- Journal de l'agrandissement de mallette (2026-09-26) : une Valise donnée agrandit la grille
-- mais les objets se chevauchent. On note ce que le jeu appelle lors d'un vrai achat de Valise,
-- avec la mallette avant / après (ID x pile @ case).
local function install_extend_logging()
    for _, entry in ipairs({ { "app.Inventory", "addExtendLevel" }, { "app.Inventory", "setExtendLevel" },
            { "app.Inventory", "restoreExtendLevel" }, { "app.GUIInventory", "setupItemExtend" } }) do
        local def = sdk.find_type_definition(entry[1])
        local method = def and def:get_method(entry[2])
        if method then
            sdk.hook(method, function(args)
                debug_log(string.format("mallette : %s.%s appelé ; %s", entry[1], entry[2], inventory_dump()))
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                debug_log(string.format("mallette : après %s.%s ; %s", entry[1], entry[2], inventory_dump()))
                return retval
            end)
        end
    end
end

-- Bloque l'agrandissement quand la Valise achetée est un check (voir block_extend_until).
local function install_extend_block()
    local def = sdk.find_type_definition("app.Inventory")
    local method = def and def:get_method("addExtendLevel")
    if not method then return end
    sdk.hook(method, function(args)
        if not own_extend and os.clock() < block_extend_until then
            block_extend_until = -math.huge
            debug_log("valise : agrandissement bloqué (Valise achetée comme check)")
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval) return retval end)
end

-- Freeze au démarrage (2026-09-26, 2 lancements sur 2) avec ce hook : désactivé le temps
-- de trouver la cause.
K.EXTEND_BLOCK_HOOK = false

local function install_weapon_autoequip_block()
    if K.EXTEND_BLOCK_HOOK then install_extend_block() end
    -- install_extend_logging() : diagnostic de la Valise terminé (2026-09-26), désactivé.
    install_use_item_block()
    for _, type_name in ipairs(K.AUTOEQUIP_BLOCK_TYPES) do
        local def = sdk.find_type_definition(type_name)
        local method = def and def:get_method("requestUseGetWeapon")
        if method then
            sdk.hook(method, function(args)
                local skip = false
                pcall(function()
                    local id = get_item_id_from_core(sdk.to_managed_object(args[3]))
                    local t = id and weapon_check_pending[id]
                    skip = t ~= nil and os.clock() - t < 3.0
                    debug_log(string.format("arme ramassée : %s.requestUseGetWeapon(%s), check récent=%s -> %s",
                        type_name, tostring(id), tostring(t ~= nil), skip and "mise en main BLOQUÉE" or "laissée"))
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
            debug_log("hook requestUseGetWeapon posé sur " .. type_name)
        end
    end
    for _, entry in ipairs(K.AUTOEQUIP_LOG_ONLY) do
        local def = sdk.find_type_definition(entry[1])
        local method = def and def:get_method(entry[2])
        if method then
            sdk.hook(method, function(args)
                pcall(function()
                    local id = nil
                    pcall(function() id = get_item_id_from_core(sdk.to_managed_object(args[3])) end)
                    debug_log(string.format("arme (journal) : %s.%s(%s)", entry[1], entry[2], tostring(id)))
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
            debug_log("journal posé sur " .. entry[1] .. "." .. entry[2])
        end
    end
end
install_weapon_autoequip_block()

local function install_pickup_hook()
    local def = sdk.find_type_definition("app.InteractItemGet")
    local method = def and def:get_method("InventoryInsertFinishItem")
    if not method then
        log.error(string.format("[%s] app.InteractItemGet.InventoryInsertFinishItem introuvable", MOD_NAME))
        return
    end
    -- Confirmé en jeu : args[2] = this (app.InteractItemGet), args[3] = l'ItemCore ramassé.
    sdk.hook(method, function(args)
        local ok, err = pcall(function()
            on_item_picked(sdk.to_managed_object(args[2]), sdk.to_managed_object(args[3]))
        end)
        if not ok then log.error(string.format("[%s] erreur hook ramassage : %s", MOD_NAME, tostring(err))) end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval) return retval end)
end

install_pickup_hook()

---------------------------------------------------------------------------
-- Outils de développement
---------------------------------------------------------------------------

local last_tool_message = ""

local function scan_zone()
    local results, completed = {}, 0
    for _, spawn_info in ipairs(find_all_components("app.Spawn.ItemSpawnInfo")) do
        local ident = get_spawn_info_identity(spawn_info)
        if ident.completed then completed = completed + 1 end
        results[#results + 1] = ident
    end
    if #results == 0 then
        last_tool_message = "0 placement trouvé (pas encore en jeu ?)"
        return
    end
    local path = string.format("%s/scan_%s.json", MOD_NAME, os.date("%Y%m%d_%H%M%S"))
    json.dump_file(path, { count = #results, placements = results })
    last_tool_message = string.format("%d placements (%d déjà ramassés) -> %s", #results, completed, path)
    log.info(string.format("[%s] [SCAN] %s", MOD_NAME, last_tool_message))
end

-- Boutique du Duc (recherche, 2026-09-25) : app.GUIShopBuy est l'écran d'achat. Sa liste
-- d'articles (buyUnits) contient des app.GUIShopBuy.BuyUnit (itemID, price, stackSize,
-- stockCount). Objectif : y ajouter des articles "Archipelago" qui valident un check.
local function read_shop()
    local shops = find_all_components("app.GUIShopBuy")
    if #shops == 0 then return nil, "boutique non ouverte" end
    local results = {}
    for si, shop in ipairs(shops) do
        local ok, units = pcall(function() return shop:call("get_buyUnits") end)
        if ok and units then
            for i = 0, units:call("get_Count") - 1 do
                local u = units:call("get_Item", i)
                local entry = { shop = si }
                pcall(function() entry.item_id = u:call("get_itemID") end)
                pcall(function() entry.price = u:call("get_price") end)
                pcall(function() entry.stack = u:call("get_stackSize") end)
                pcall(function() entry.stock = u:call("get_stockCount") end)
                pcall(function() entry.sort = u:call("get_sortOrder") end)
                pcall(function() entry.is_new = u:call("get_isNew") end)
                results[#results + 1] = entry
            end
        end
        pcall(function() results.assortment_hash = shop:call("get_assortmentHash") end)
    end
    return results
end

local function dump_shop()
    local results, err = read_shop()
    if not results then
        last_tool_message = "Boutique : " .. err .. " (ouvre l'écran d'achat du Duc)"
        return
    end
    local path = string.format("%s/shop_%s.json", MOD_NAME, os.date("%Y%m%d_%H%M%S"))
    json.dump_file(path, { units = results })

    -- La liste ne contient que l'onglet ouvert (constaté le 2026-09-25) : on cumule tous les
    -- relevés dans shop_all.json, par ItemID, pour avoir la boutique complète.
    local merged_path = MOD_NAME .. "/shop_all.json"
    local ok, merged = pcall(json.load_file, merged_path)
    if not ok or type(merged) ~= "table" then merged = {} end
    local added = 0
    for _, u in ipairs(results) do
        local key = tostring(u.item_id)
        if not merged[key] then added = added + 1 end
        u.seen = os.date("%Y-%m-%d %H:%M")
        merged[key] = u
    end
    json.dump_file(merged_path, merged)
    last_tool_message = string.format("Boutique : %d articles dans cet onglet (%d nouveaux) -> shop_all.json", #results, added)
end

-- EXPÉRIENCE (désactivée par défaut, case à cocher dans les outils) : ajouter un article
-- "1 poudre pour 1 Lei" à la liste du Duc, pour voir si un article ajouté s'affiche et
-- s'achète. Premier test du 2026-09-25 : buyItem puis decideBuyItem(itemCore) à l'achat.
local shop_experiment = false
local TEST_SHOP_ITEM_ID = 3461208890 -- poudre
local shop_being_collected = nil

-- item_id : TEST_SHOP_ITEM_ID (poudre), ou le porteur Archipelago (test du logo 3D dans la
-- boutique, 2026-09-27 : logo "en œufs" au sol, à comparer).
local function add_test_shop_unit(shop, item_id)
    item_id = item_id or TEST_SHOP_ITEM_ID
    local units = shop:call("get_buyUnits")
    for i = 0, units:call("get_Count") - 1 do
        if units:call("get_Item", i):call("get_itemID") == item_id then return end
    end
    local unit = sdk.create_instance("app.GUIShopBuy.BuyUnit")
    unit:call(".ctor")
    unit:call("set_itemID", item_id)
    unit:call("set_price", 1)
    unit:call("set_stackSize", 1)
    unit:call("set_stockCount", 1)
    unit:call("set_sortOrder", 1)
    local core = sdk.get_managed_singleton("app.InventoryManager"):call("createItemCore", item_id, 1, 0, 0)
    unit:call("set_work", core:call("get_work"))
    units:call("Add", unit)
    debug_log("boutique : article de test " .. tostring(item_id) .. " ajouté (" .. units:call("get_Count") .. " articles)")
end

-- Catalogue : nom (dans la langue du jeu), catégorie et description de chaque objet, à partir
-- des fiches app.ItemSpecificationData.SpecUnit (Basic.NameMessageID...) traduites par
-- via.gui.message.get(guid). Fichier : reframework/data/re_village_ap_client/item_catalog.json
local function message_text(guid)
    local ok, text = pcall(function()
        return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, guid)
    end)
    return ok and text or nil
end

local function dump_item_catalog()
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    if not specs then
        last_tool_message = "Catalogue : ItemSpecification introuvable"
        return
    end
    local catalog, count = {}, 0
    local lists = specs:call("get_itemSpecsList")
    for i = 0, lists:call("get_Count") - 1 do
        local units = lists:call("get_Item", i):get_field("SpecUnits")
        for j = 0, units:call("get_Count") - 1 do
            pcall(function()
                local unit = units:call("get_Item", j)
                local basic = unit:get_field("Basic")
                -- Icône et objets factices (2026-09-26) : pour choisir un objet porteur de
                -- l'icône Archipelago (objet factice, jamais obtenu en partie normale).
                catalog[tostring(unit:get_field("ItemID"))] = {
                    name = message_text(basic:get_field("NameMessageID")),
                    category = message_text(basic:get_field("CategoryMessageID")),
                    info = message_text(basic:get_field("SimpleInfoMessageID")),
                    max_stack = basic:get_field("MaxStackSize"),
                    dummy = unit:get_field("IsDummy"),
                    hide_list = basic:get_field("IsHideList"),
                    icon_asset = basic:get_field("IconAssetNo"),
                    icon_pattern = basic:get_field("IconPatternNo"),
                    icon_sequence = basic:get_field("IconSequenceNo"),
                    small_icon_asset = basic:get_field("SmallIconAssetNo"),
                    small_icon_pattern = basic:get_field("SmallIconPatternNo"),
                }
                count = count + 1
            end)
        end
    end
    json.dump_file(MOD_NAME .. "/item_catalog.json", catalog)
    last_tool_message = string.format("Catalogue : %d objets -> %s/item_catalog.json", count, MOD_NAME)
end

-- Noms officiels en français ET en anglais (2026-10-08, apworld FR / EN) : objets (fiches
-- ItemSpecification), salles (MapManager userdatas -> Units -> RoomUnits, RoomNameGUID) et plats
-- du Duc (RecipeManager, TitleGUID), via via.gui.message.get(guid, via.Language) : English = 1,
-- French = 2. Fichier : reframework/data/re_village_ap_client/names_fr_en.json
function shop_ui.names_both(guid)
    local get = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid, via.Language)")
    local fr, en = nil, nil
    pcall(function() fr = get:call(nil, guid, 2) end)
    pcall(function() en = get:call(nil, guid, 1) end)
    if not fr or fr == "" then return nil end
    return { fr = fr, en = en }
end
function shop_ui.dump_names()
    local both = shop_ui.names_both
    local out = { items = {}, rooms = {}, recipes = {}, categories = {} }
    local counts = { items = 0, rooms = 0, recipes = 0 }
    pcall(function()
        local lists = sdk.get_managed_singleton("app.ItemSpecification"):call("get_itemSpecsList")
        for i = 0, lists:call("get_Count") - 1 do
            local units = lists:call("get_Item", i):get_field("SpecUnits")
            for j = 0, units:call("get_Count") - 1 do
                pcall(function()
                    local unit = units:call("get_Item", j)
                    local basic = unit:get_field("Basic")
                    local name = both(basic:get_field("NameMessageID"))
                    if name then
                        out.items[tostring(unit:get_field("ItemID"))] = name
                        counts.items = counts.items + 1
                        local cat = both(basic:get_field("CategoryMessageID"))
                        if cat then out.categories[cat.fr] = cat.en end
                    end
                end)
            end
        end
    end)
    pcall(function()
        local datas = sdk.get_managed_singleton("app.MapManager"):call("get_userdatas")
        local seen = {}
        for i = 0, datas:call("get_Count") - 1 do
            local units = datas:call("get_Item", i):get_field("Units")
            for j = 0, units:call("get_Count") - 1 do
                pcall(function()
                    local rooms = units:call("get_Item", j):get_field("RoomUnits")
                    for k = 0, rooms:call("get_Count") - 1 do
                        pcall(function()
                            local name = both(rooms:call("get_Item", k):get_field("RoomNameGUID"))
                            if name and not seen[name.fr] then
                                seen[name.fr] = true
                                out.rooms[#out.rooms + 1] = name
                                counts.rooms = counts.rooms + 1
                            end
                        end)
                    end
                end)
            end
        end
    end)
    pcall(function()
        local datas = sdk.get_managed_singleton("app.RecipeManager"):call("get_userdatas")
        for i = 0, datas:call("get_Count") - 1 do
            local units = datas:call("get_Item", i):get_field("Units")
            for j = 0, units:call("get_Count") - 1 do
                pcall(function()
                    local name = both(units:call("get_Item", j):get_field("TitleGUID"))
                    if name then
                        out.recipes[#out.recipes + 1] = name
                        counts.recipes = counts.recipes + 1
                    end
                end)
            end
        end
    end)
    json.dump_file(MOD_NAME .. "/names_fr_en.json", out)
    last_tool_message = string.format("Noms FR/EN : %d objets, %d salles, %d plats -> %s/names_fr_en.json",
        counts.items, counts.rooms, counts.recipes, MOD_NAME)
    debug_log(last_tool_message)
end

-- Plats du Duc (futurs checks) : app.RecipeManager (singleton). userdatas → Units (RecipeID,
-- TitleGUID, MaterialUnits, Reward) ; recipeUnits = état sauvegardé (IsCheckIt, IsCompleted).
-- Fichier : reframework/data/re_village_ap_client/recipes.json
local function dump_recipes()
    local mgr = sdk.get_managed_singleton("app.RecipeManager")
    if not mgr then
        last_tool_message = "Plats : RecipeManager introuvable"
        return
    end
    local recipes, count = {}, 0
    local datas = mgr:call("get_userdatas")
    for i = 0, datas:call("get_Count") - 1 do
        local units = datas:call("get_Item", i):get_field("Units")
        if units then
            for j = 0, units:call("get_Count") - 1 do
                pcall(function()
                    local u = units:call("get_Item", j)
                    local id = u:get_field("RecipeID")
                    local entry = {
                        title = message_text(u:get_field("TitleGUID")),
                        content = message_text(u:get_field("ContentGUID")),
                        materials = {},
                    }
                    pcall(function()
                        local reward = u:get_field("Reward")
                        entry.reward_money = reward:get_field("Money")
                        entry.reward_text = message_text(reward:get_field("RewardGUID"))
                    end)
                    pcall(function()
                        local mats = u:get_field("MaterialUnits")
                        for k = 0, mats:call("get_Count") - 1 do
                            local m = mats:call("get_Item", k)
                            local fields = {}
                            for _, f in ipairs(m:get_type_definition():get_fields()) do
                                local okv, v = pcall(function() return m:get_field(f:get_name()) end)
                                if okv and (type(v) == "number" or type(v) == "boolean") then fields[f:get_name()] = v end
                            end
                            entry.materials[#entry.materials + 1] = fields
                        end
                    end)
                    pcall(function() entry.completed = mgr:call("isCompleted", id) end)
                    pcall(function() entry.seen = mgr:call("isCheckIt", id) end)
                    recipes[tostring(id)] = entry
                    count = count + 1
                end)
            end
        end
    end
    json.dump_file(MOD_NAME .. "/recipes.json", recipes)
    last_tool_message = string.format("Plats : %d recettes -> recipes.json", count)
end

local function install_recipe_logging()

    local def = sdk.find_type_definition("app.RecipeManager")
    if not def then return end
    for _, name in ipairs({ "completed", "delived", "checkIt" }) do
        local method = def:get_method(name)
        if method then
            sdk.hook(method, function(args)
                pcall(function()
                    local rid = sdk.to_int64(args[3]) & 0xFFFFFFFF
                    debug_log(string.format("plat : %s, recipeID=%s", name, tostring(rid)))
                    -- Plat cuisiné (confirmé le 2026-09-25) : check, envoyé par la boucle principale.
                    if name == "completed" and recipe_locations[rid] then
                        table.insert(picked_locations, recipe_locations[rid])
                    end
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end
    end
end
install_recipe_logging()

-- Morts d'ennemis (futur objectif "battre tel boss", 2026-09-25) : app.EnemyManager
-- .registerDeadEnemy(deadEnemy, damageInfo). On note le nom interne (emXXXX) de chaque ennemi
-- tué pour identifier les boss. Fichier : reframework/data/re_village_ap_client/kills.jsonl
local function install_kill_logging()

    local def = sdk.find_type_definition("app.EnemyManager")
    local method = def and def:get_method("registerDeadEnemy")
    if not method then return end
    sdk.hook(method, function(args)
        pcall(function()
            local go = sdk.to_managed_object(args[3])
            local name = go and go:call("get_Name") or "?"
            local folder = "?"
            pcall(function() folder = go:call("get_Folder"):call("get_Path") end)
            debug_log(string.format("ennemi tué : %s (%s)", tostring(name), tostring(folder)))
            if BOSS_KILLS[name] then table.insert(pending_boss_events, BOSS_KILLS[name]) end
            local file = io.open(MOD_NAME .. "/kills.jsonl", "a")
            if file then
                file:write(json.dump_string({ time = os.date("%Y-%m-%d %H:%M:%S"), name = name, folder = folder }) .. "\n")
                file:close()
            end
        end)
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval) return retval end)
end
install_kill_logging()

-- Coups reçus par Ethan (relevé du 2026-09-27, pour un message DeathLink « tué par … ») :
-- PlayerDamageResponser`1<…>.calcDamage(damageInfo, baseDamage) à chaque coup, doDie(record) à la
-- mort. On note l'attaquant (DamageInfo.get_AttackOwner / AttackGameObject) et le type
-- d'attaque (AttackUserData). Journal : lignes « coup reçu » / « mort d'Ethan » du debug_log.
death_link.hits = { last = nil, logged = 0 }
function death_link.hits.describe(info)
    local d = {}
    pcall(function() d.owner = tostring(info:call("get_AttackOwner"):call("get_Name")) end)
    pcall(function() d.attack_go = tostring(info:call("get_AttackGameObject"):call("get_Name")) end)
    pcall(function()
        local ud = info:call("get_AttackUserData")
        d.attack_type = ud:get_type_definition():get_full_name()
        pcall(function() d.attack_name = tostring(ud:call("get_Name")) end)
    end)
    pcall(function() d.damage = info:get_field("Damage") end)
    pcall(function() d.parts = tostring(info:get_field("Parts")) end)
    return d
end
function death_link.hits.install()
    for _, tname in ipairs({ "app.PlayerDamageResponser`1<app.PlayerReferenceContainerFPS>",
            "app.PlayerDamageResponser`1<app.PlayerReferenceContainerTPS>" }) do
        local def = sdk.find_type_definition(tname)
        local calc = def and def:get_method("calcDamage")
        local die = def and def:get_method("doDie")
        if calc then
            sdk.hook(calc, function(args)
                pcall(function()
                    local hit = death_link.hits.describe(sdk.to_managed_object(args[3]))
                    hit.time = os.clock()
                    death_link.hits.last = hit
                    -- Moustiques : ~10 coups/s, 200 lignes pleines en 20 s. Noté seulement quand
                    -- l'attaquant ou l'attaque change.
                    local key = tostring(hit.owner) .. "|" .. tostring(hit.attack_name)
                    if key ~= death_link.hits.last_key and death_link.hits.logged < 500 then
                        death_link.hits.last_key = key
                        death_link.hits.logged = death_link.hits.logged + 1
                        debug_log("coup reçu : " .. json.dump_string(hit))
                    end
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end
        if die then
            sdk.hook(die, function(args)
                pcall(function()
                    local record = sdk.to_managed_object(args[3])
                    local hit = record and death_link.hits.describe(record:get_field("DamageInfo")) or {}
                    hit.time = os.clock()
                    death_link.hits.fatal = hit
                    debug_log("mort d'Ethan : " .. json.dump_string(hit) .. " ; dernier coup : "
                        .. json.dump_string(death_link.hits.last or {}))
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end
        debug_log(string.format("coups reçus : %s -> calcDamage %s, doDie %s", tname, tostring(calc ~= nil), tostring(die ~= nil)))
    end
end
death_link.hits.install()

-- Progression de l'histoire (2026-09-26) : la mort de Heisenberg n'est PAS passée par
-- registerDeadEnemy (combat scripté). Pistes de détection des boss, journalisées pour l'instant :
--   - LevelFlowManager.setCompleteChapterFlag(chapter_index) / setChapterStart(hash) ;
--   - SceneTransitionManager.get_CurrentChapter() (texte), surveillé à chaque seconde ;
--   - trophée du boss ramassé (ex. "Cerveau d'Heisenberg", déjà dans pickups_log.jsonl).
-- Fichier : reframework/data/re_village_ap_client/progress.jsonl
local function log_progress(entry)
    entry.time = os.date("%Y-%m-%d %H:%M:%S")
    debug_log("progression : " .. json.dump_string(entry))
    local file = io.open(MOD_NAME .. "/progress.jsonl", "a")
    if file then
        file:write(json.dump_string(entry) .. "\n")
        file:close()
    end
end

local function install_progress_logging()
    local def = sdk.find_type_definition("app.LevelFlowManager")
    if not def then return end
    for _, name in ipairs({ "setCompleteChapterFlag", "setChapterStart" }) do
        local method = def:get_method(name)
        if method then
            sdk.hook(method, function(args)
                pcall(function()
                    log_progress({ event = name, value = sdk.to_int64(args[3]) & 0xFFFFFFFF })
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end
    end
end
install_progress_logging()

local last_chapter, last_chapter_check = nil, 0
local last_ending_flow = nil
local watch_error_logged, chapter_status_logged = false, false
-- Zone actuelle d'après le chapitre (remplace le scan automatique, retiré le 2026-09-26 car
-- trop coûteux). Noms = régions de l'apworld (champ "region" de locations.json).
K.CHAPTER_ZONES = {
    Chapter2_1 = "Village", Chapter2_6 = "Village",
    Chapter2_2 = "Chateau Dimitrescu",
    Chapter2_3 = "Maison Beneviento",
    Chapter2_4 = "Reservoir",
    Chapter2_5 = "Usine Heisenberg", Chapter2_7 = "Usine Heisenberg",
    Chapter3_1 = "Chris",
    Chapter3_2 = "Fin du jeu",
}

local function watch_current_chapter()
    if os.clock() - last_chapter_check < 1.0 then return end
    last_chapter_check = os.clock()
    -- Fin du jeu (2026-09-26) : Miranda n'est pas passée par registerDeadEnemy (combat
    -- scripté). GUIManager.get_isEnableEndingFlow devrait passer à vrai pendant la fin.
    local ok_end, err_end = pcall(function()
        local ending = sdk.get_managed_singleton("app.GUIManager"):call("get_isEnableEndingFlow")
        ending = tostring(ending)
        ending_active = ending == "true"
        if ending ~= last_ending_flow then
            log_progress({ event = "fin_du_jeu (EndingFlow)", value = ending })
            last_ending_flow = ending
        end
        -- Fin du jeu confirmée le 2026-09-26 : EndingFlow vrai pendant le dernier chapitre.
        if ending == "true" and last_chapter == "Chapter3_2" then
            table.insert(pending_boss_events, "fin_du_jeu")
        end
    end)
    if not ok_end and not watch_error_logged then
        watch_error_logged = true
        debug_log("progression : erreur EndingFlow : " .. tostring(err_end))
    end
    local ok, chapter = pcall(function()
        return sdk.get_managed_singleton("app.SceneTransitionManager"):call("get_CurrentChapter")
    end)
    if not chapter_status_logged then
        chapter_status_logged = true
        debug_log(string.format("progression : lecture du chapitre -> ok=%s valeur=%s", tostring(ok), tostring(chapter)))
    end
    chapter = chapter and tostring(chapter) or nil
    if ok and chapter and chapter ~= last_chapter then
        log_progress({ event = "chapitre", from = last_chapter, to = chapter })
        local old = last_chapter
        last_chapter = chapter
        shop_ui.chapter = chapter -- lisible par le code écrit avant cette variable (ramassage)
        current_zone = K.CHAPTER_ZONES[chapter]
        -- Zone ratable terminée : le jeu quitte son chapitre pour un AUTRE chapitre (pas pour
        -- l'écran titre, où le chapitre devient "").
        -- (mode 100 % : aussi, filet de sécurité si une sortie n'a pas de mur)
        -- Endroits perdus envoyés tout seuls en quittant leur chapitre, QUEL QUE SOIT le mode
        -- (données : auto_send_after ; maison de Luiza, emplacements des reliefs, 2026-10-08)
        if old and old ~= "" and chapter ~= "" then
            local auto = 0
            for _, loc in pairs(location_by_guid) do
                local id = loc.auto_send_after == old and get_location_id(loc)
                -- mode 100 % : un endroit qui a un mur n'est pas envoyé ici (sinon le mur ne
                -- bloquerait jamais) ; filet : shop_ui.no_return.past_wall
                local walled = missable_mode == "cent_pourcent" and loc.missable_spot
                    and #(shop_ui.no_return.exits[loc.missable_spot] or {}) > 0
                if id and not checked_ids[id] and not walled then
                    queue_check(loc)
                    auto = auto + 1
                end
            end
            if auto > 0 then debug_log(string.format("envoi automatique : %d check(s) perdus du %s", auto, old)) end
        end
        if old and old ~= "" and chapter ~= "" and (missable_mode == "envoi_auto" or missable_mode == "cent_pourcent") then
            local sent = 0
            for _, loc in pairs(location_by_guid) do
                local id = loc.missable_chapter == old and get_location_id(loc)
                if id and not checked_ids[id] then
                    queue_check(loc)
                    sent = sent + 1
                end
            end
            if sent > 0 then
                add_message(string.format(tr("Zone terminée : %d checks restants envoyés automatiquement",
                    "Area finished: %d remaining checks sent automatically"), sent))
                debug_log(string.format("envoi automatique : %d checks de %s", sent, old))
            end
        end
    end
end

-- Boutique du Duc (V2) : le 1er achat de chaque article unique est un check.
--   - decideBuyItem(itemCore) (confirmé comme étape d'achat le 2026-09-25) : si l'article a une
--     location pas encore faite, on bloque l'achat normal (SKIP_ORIGINAL), la boucle principale
--     retire le prix et envoie le check.
--   - collectBuyUnits (post) : un article dont toutes les locations sont faites est masqué, sauf
--     si l'objet a été reçu via Archipelago (rachat après revente, règle du joueur).
local shop_purchases = {}

local function location_done(loc)
    local id = get_location_id(loc)
    if not id then return nil end -- pas dans cette seed (boutique désactivée)
    if checked_ids[id] or shop_ui.bought[loc.key] then return true end
    for _, key in ipairs(state.pending_checks) do
        if key == loc.key then return true end
    end
    return false
end
shop_ui.location_done = location_done

-- Objet d'un article du Duc. Test du 2026-09-26 : pour les accessoires, le numéro de l'ARTICLE
-- (ex. 2044788832) n'est pas celui de l'objet vendu (Détente sensible 3787717904) : on lit
-- donc l'objet de l'article (work), et le numéro de l'article seulement en secours.
local function unit_item_id(unit)
    local ok, id = pcall(function() return unit:call("get_work"):call("get_itemID") end)
    if ok and id then return id end
    return unit:call("get_itemID")
end

local function next_shop_location(item_id)
    for _, loc in ipairs(shop_locations_by_item[item_id] or {}) do
        if location_done(loc) == false then return loc end
    end
    return nil
end

-- Articles-checks affichés sous l'objet Archipelago qu'ils donnent (demande du joueur,
-- 2026-09-26 : modèle 3D, icône, catégorie et description du vrai objet quand il est de ce
-- jeu). ItemID affiché -> location, reconstruit à chaque collectBuyUnits (apply_shop_swaps).

-- Location de boutique derrière un ItemID affiché (article échangé d'abord, sinon l'article du jeu).
local function shop_loc_for(item_id)
    if not item_id then return nil end
    local loc = shop_ui.swap_map[item_id]
    if loc and location_done(loc) == false then return loc end
    return next_shop_location(item_id)
end

-- Valise-checks (bug trouvé le 2026-09-26) : le mod remet la mallette à son ancien niveau après
-- l'achat, donc le Duc repropose la Valise au prix du premier niveau (10 000), et chaque achat
-- validait la Valise-check suivante. On reproduit la progression du jeu à partir du nombre de
-- Valise-checks faites : prix du N-ième achat, et pas plus de Valises proposées que le jeu
-- normal à ce chapitre (relevés de la boutique : 1 au château, 2 après, 3 dès l'usine).
local VALISE_PRICES = { 10000, 30000, 50000 }
K.VALISE_MAX_BY_CHAPTER = {
    Chapter2_1 = 1, Chapter2_2 = 1,
    Chapter2_3 = 2, Chapter2_4 = 2, Chapter2_6 = 2,
    Chapter2_5 = 3, Chapter2_7 = 3, Chapter3_1 = 3, Chapter3_2 = 3,
}

-- État des Valise-checks : nil si aucune en attente (jeu normal), sinon (proposée, prix).
local function valise_status()
    local list = shop_locations_by_item[VALISE_ITEM_ID]
    if not list then return nil end
    local done, pending = 0, 0
    for _, loc in ipairs(list) do
        local d = location_done(loc)
        if d == true then done = done + 1 elseif d == false then pending = pending + 1 end
    end
    if pending == 0 then return nil end -- toutes faites (ou boutique non mélangée) : jeu normal
    local allowed = K.VALISE_MAX_BY_CHAPTER[last_chapter or ""] or 0
    return done < allowed, VALISE_PRICES[done + 1] or VALISE_PRICES[#VALISE_PRICES]
end

local function adjust_valise_unit(shop)
    local offered, price = valise_status()
    if offered == nil then return end
    local units = shop:call("get_buyUnits")
    for i = units:call("get_Count") - 1, 0, -1 do
        local unit = units:call("get_Item", i)
        if unit_item_id(unit) == VALISE_ITEM_ID then
            if not offered then
                units:call("RemoveAt", i)
            else
                unit:call("set_price", price)
            end
        end
    end
end

-- Armes qui sont des checks dans le monde (bug du 2026-09-26) : les ramasser pose l'indicateur
-- "déjà obtenue" du jeu, et le Duc propose un rachat (M1897 à 24 000) alors que le joueur n'a
-- jamais eu l'arme. Le rachat est masqué tant qu'elle n'a pas été reçue par Archipelago, ou
-- tant qu'elle attend dans le colis (le colis la donne à 0 Lei).
local world_check_weapon_ids = {}
for _, loc in ipairs(locations) do
    local def = loc.kind == "world" and item_by_name[loc.original_item]
    if def and def.type == "Weapon" and def.game_item_id then world_check_weapon_ids[def.game_item_id] = true end
end

local function hide_done_shop_units(shop)
    local units = shop:call("get_buyUnits")
    for i = units:call("get_Count") - 1, 0, -1 do
        local id = unit_item_id(units:call("get_Item", i))
        local list = shop_locations_by_item[id]
        if list and not (state.received_ids or {})[tostring(id)] then
            local all_done, any = true, false
            for _, loc in ipairs(list) do
                local done = location_done(loc)
                if done ~= nil then any = true end
                if done == false then all_done = false end
            end
            if any and all_done then units:call("RemoveAt", i) end
        end
    end
end

-- Boutique ouverte : collectBuyUnits est rappelé sans cesse tant qu'elle est affichée.
local open_shop, open_shop_seen = nil, -math.huge

-- Boutique affichée ? (bug du 2026-09-26 : "collectBuyUnits appelé il y a moins de 2 s" ne
-- marchait pas, le jeu ne reconstruit la liste qu'au changement d'article). Le GUIManager le dit.
local function shop_is_open()
    if not open_shop then return false end
    local ok, v = pcall(function() return sdk.get_managed_singleton("app.GUIManager"):call("isShowingGUIShop") end)
    return ok and v == true
end

-- Achat-check : le jeu débite le prix et donne l'objet (retiré par process_vanilla_removals) ;
-- ici on envoie seulement le check.
local function process_shop_purchases()
    if #shop_purchases == 0 then return end
    local batch = shop_purchases
    shop_purchases = {}
    for _, loc in ipairs(batch) do
        debug_log(string.format("boutique : check envoyé %s (Lei %s)", loc.name, tostring(get_money())))
        table.insert(picked_locations, loc)
    end
    -- Formule-check : l'achat du jeu est sauté, donc la liste n'est pas reconstruite et
    -- l'article restait affiché. On signale au Duc que sa liste a changé.
    -- set_changed(true) seul ne suffisait pas (test du 2026-09-26) : on reconstruit et on
    -- redessine la liste.
    if shop_is_open() then
        local shop = open_shop
        local report = {}
        for _, step in ipairs({ "collectBuyUnits", "sortBuyItem", "setupScrollGrid", "setupScrollList" }) do
            local ok = pcall(function() shop:call(step) end)
            report[#report + 1] = step .. "=" .. (ok and "ok" or "échec")
        end
        pcall(function() shop:call("set_changed", true) end)
        debug_log("boutique : liste reconstruite : " .. table.concat(report, " "))
    end
end

-- Articles ajoutés par Archipelago (2026-09-26, demandes du joueur) :
--   - article-check dont l'objet a déjà été REÇU via Archipelago : le jeu le masque ou le
--     marque acquis (ex. Détente sensible reçue d'un check) et le check devenait impossible.
--     On le remet dans la liste, jamais "épuisé", au prix de la location ;
--   - colis (objets refusés, mallette pleine) : proposés à 0 Lei. Le jeu vérifie la place.
-- Le nom affiché devient "[AP] ..." ou "[Colis AP] ..." (panneau de détail de l'article).
-- Journalise le chaque hook de boutique (pour situer un éventuel freeze).
local first_calls = {}
local function first_call(name)
    if first_calls[name] then return end
    first_calls[name] = true
    debug_log("boutique : " .. name)
end

local function parcel_index_of(item_id)
    for i, name in ipairs(state.parcel) do
        local def = item_by_name[name]
        if def and (def.give_id or def.game_item_id) == item_id then return i end
    end
    return nil
end

local function shop_has_unit(units, item_id, price)
    for i = 0, units:call("get_Count") - 1 do
        local u = units:call("get_Item", i)
        if unit_item_id(u) == item_id and (price == nil or u:call("get_price") == price) then return true end
    end
    return false
end

local function add_shop_unit(units, item_id, price, count)
    local unit = sdk.create_instance("app.GUIShopBuy.BuyUnit")
    unit:call(".ctor")
    unit:call("set_itemID", item_id)
    unit:call("set_price", price)
    unit:call("set_stackSize", count or 1)
    unit:call("set_stockCount", 1)
    unit:call("set_sortOrder", 1)
    local core = sdk.get_managed_singleton("app.InventoryManager"):call("createItemCore", item_id, count or 1, 0, 0)
    if not core then
        -- 2026-09-27 : createItemCore nil pour un article (erreur qui bloquait tous les ajouts).
        shop_ui.core_nil_logged = shop_ui.core_nil_logged or {}
        if not shop_ui.core_nil_logged[item_id] then
            shop_ui.core_nil_logged[item_id] = true
            debug_log("boutique : objet " .. tostring(item_id) .. " impossible à créer (createItemCore nil), article ignoré")
        end
        return
    end
    unit:call("set_work", core:call("get_work"))
    units:call("Add", unit)
end

local function add_ap_shop_units(shop)
    local units = shop:call("get_buyUnits")
    local received = state.received_ids or {}
    for item_id, list in pairs(shop_locations_by_item) do
        -- (la Valise est gérée par adjust_valise_unit : prix et disponibilité par chapitre)
        local loc = item_id ~= VALISE_ITEM_ID and received[tostring(item_id)] and next_shop_location(item_id)
        if loc and not shop_has_unit(units, item_id) then
            add_shop_unit(units, item_id, loc.price or 0)
            first_call("remise en vente " .. loc.name)
        end
    end
    for _, name in ipairs(state.parcel) do
        local def = item_by_name[name]
        local gid = def and (def.give_id or def.game_item_id)
        if gid and not shop_has_unit(units, gid, 0) then
            add_shop_unit(units, gid, 0, def.quantity or 1)
        end
    end
end


-- Nom affiché de l'article sélectionné.
-- unit_price : prix de l'article sélectionné, si connu. Bug du 2026-09-26 : le rachat du jeu
-- (M1897 à 24 000) s'appelait aussi "[Colis AP]" ; seul l'article à 0 Lei est le colis.
local function ap_shop_label(item_id, unit_price)
    local loc = shop_loc_for(item_id)
    if loc then
        local id = get_location_id(loc)
        local s = id and scouted_items[id]
        return "[AP] " .. ((s and s.label) or loc.original_item)
    end
    local i = item_id and unit_price == 0 and parcel_index_of(item_id)
    if i then return "[Colis AP] " .. state.parcel[i] end
    return nil
end

-- Freeze au démarrage du 2026-09-26 avec ces trois hooks : réactivés un par un pour trouver
-- le coupable. Démarrage OK sans aucun des trois.
K.SHOP_HOOK_CAN_BUY = true   -- canBuyItem : achat d'un article-check déjà possédé
K.SHOP_HOOK_SOLD_OUT = true  -- isSoldOutByUnit : jamais "épuisé"
K.SHOP_HOOK_RENAME = false   -- nom "[AP] ..." au changement de sélection

-- Prix réellement affiché par le Duc pour cet ItemID (il change avec l'avancement).
local function shop_unit_price(item_id)
    local price = nil
    pcall(function()
        local units = open_shop:call("get_buyUnits")
        for i = 0, units:call("get_Count") - 1 do
            local u = units:call("get_Item", i)
            if unit_item_id(u) == item_id then price = u:call("get_price") break end
        end
    end)
    return price
end

-- Onglets du Duc (relevés le 2026-09-26) : 0 Tout, 1 Autres, 2 Soin, 3 Munitions, 4 Armes,
-- 5 Éléments. Demande du joueur : tous les articles Archipelago (checks et colis) dans
-- "Autres", et plus dans leur onglet d'origine. La liste ne contient que l'onglet ouvert : les
-- articles-checks proposés sont donc mémorisés quand on les voit (onglet "Tout" en général).

local function regroup_ap_units(shop)
    local tab = shop:call("get_lastCategoryIndex")
    local units = shop:call("get_buyUnits")
    for i = 0, units:call("get_Count") - 1 do
        local unit = units:call("get_Item", i)
        local id = unit_item_id(unit)
        if id ~= VALISE_ITEM_ID and next_shop_location(id) then shop_ui.offered[id] = unit:call("get_price") end
    end
    if tab == 0 then return end
    if tab == 1 then
        local present = {}
        for i = 0, units:call("get_Count") - 1 do present[unit_item_id(units:call("get_Item", i))] = true end
        for id, price in pairs(shop_ui.offered) do
            if not present[id] and next_shop_location(id) then add_shop_unit(units, id, price) end
        end
        local valise_offered, valise_price = valise_status()
        if valise_offered and not present[VALISE_ITEM_ID] then add_shop_unit(units, VALISE_ITEM_ID, valise_price) end
        for _, name in ipairs(state.parcel) do
            local def = item_by_name[name]
            local gid = def and (def.give_id or def.game_item_id)
            if gid and not shop_has_unit(units, gid, 0) then
                add_shop_unit(units, gid, 0, def.quantity or 1)
            end
        end
        return
    end
    -- Autres onglets : on retire articles-checks et colis.
    for i = units:call("get_Count") - 1, 0, -1 do
        local unit = units:call("get_Item", i)
        local id = unit_item_id(unit)
        if next_shop_location(id) or (unit:call("get_price") == 0 and parcel_index_of(id)) then
            units:call("RemoveAt", i)
        end
    end
end

-- Affiche un article-check sous l'objet qu'il donne, si c'est un objet de ce jeu. Pas
-- d'échange si cet objet est déjà dans la liste, ou si c'est un article-check ou de l'argent :
-- un achat normal ne doit jamais être pris pour le check.
-- Chaque article-check est rattaché à sa location (shop_ui.unit_loc, par adresse de l'article),
-- puis affiché sous l'objet qu'il donne si c'est un objet de ce jeu (sauf l'argent). Depuis le
-- 2026-09-26, l'article sélectionné est connu par lastIndex : l'échange se fait donc aussi quand
-- l'objet est déjà dans la liste (l'achat suit l'article, pas l'objet affiché).
local function apply_shop_swaps(shop)
    shop_ui.swap_map = {}
    shop_ui.unit_loc = {}
    shop_ui.ap_model_units = {}
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    pcall(shop_ui.audit_models, specs)
    local stats = { checks = 0, scouted = 0, other = 0, swapped = 0 }
    local units = shop:call("get_buyUnits")
    local mgr = sdk.get_managed_singleton("app.InventoryManager")
    for i = 0, units:call("get_Count") - 1 do
        local ok_swap, err_swap = pcall(function()
            local unit = units:call("get_Item", i)
            local id = unit_item_id(unit)
            local loc = next_shop_location(id)
            if not loc then return end
            shop_ui.unit_loc[unit:get_address()] = loc
            local lid = get_location_id(loc)
            local s = lid and scouted_items[lid]
            stats.checks = stats.checks + 1
            if s then stats.scouted = stats.scouted + 1 end
            if s and not s.mine then stats.other = stats.other + 1 end
            local def = s and s.mine and item_by_name[s.name]
            local gid = def and def.game_item_id
            if s and not s.mine and shop_ui.carrier_ready then
                def, gid = nil, shop_ui.CARRIER_ID -- objet d'un autre jeu : icône Archipelago
                shop_ui.ap_model_units[unit:get_address()] = shop_ui.AP_MODEL
            elseif gid and shop_ui.carrier_ready and (shop_ui.REAL_MODELS[gid] or def.type == "Money"
                    or shop_ui.overrides[gid] or shop_ui.native_display(specs, gid, def) == false) then
                -- Objet de ce jeu que la boutique ne sait pas afficher (matériaux, Sac de Lei ;
                -- 2026-09-26/27 : rien, ou la Valise d'origine, s'affichait) : porteur, avec le
                -- vrai modèle de l'objet s'il est connu, sinon le modèle Archipelago. Ses textes
                -- (nom, catégorie, description) restent les siens (update_shop_label).
                -- Test (outils de dev) : logo Archipelago à la place du vrai modèle, pour le comparer
                -- au logo "en œufs" vu au sol (2026-09-27).
                shop_ui.ap_model_units[unit:get_address()] = (shop_ui.ap_test and shop_ui.AP_MODEL)
                    or shop_ui.REAL_MODELS[gid] or shop_ui.AP_MODEL
                local ok_o, done = pcall(shop_ui.override_prefab, specs, gid)
                if not (ok_o and done) then
                    gid = shop_ui.CARRIER_ID -- secours : sous le porteur (icône Archipelago)
                    if not ok_o then stats.error = "prefab : " .. tostring(done) end
                end
            elseif def and def.type == "Money" then
                gid = nil
            end
            if gid and gid ~= id then
                local core = mgr:call("createItemCore", gid, def and def.quantity or 1, 0, 0)
                unit:call("set_itemID", gid)
                unit:call("set_work", core:call("get_work"))
                shop_ui.swap_map[gid] = loc
                stats.swapped = stats.swapped + 1
            end
        end)
        if not ok_swap then stats.error = tostring(err_swap) end
    end
    local summary = string.format("%d checks, %d connus, %d pour un autre jeu, %d échangés (porteur prêt : %s)%s",
        stats.checks, stats.scouted, stats.other, stats.swapped, tostring(shop_ui.carrier_ready),
        stats.error and (" ; erreur : " .. stats.error) or "")
    if summary ~= shop_ui.last_swap_summary then
        shop_ui.last_swap_summary = summary
        debug_log("boutique : affichage AP : " .. summary)
    end
end

-- Article sélectionné : lastIndex = sa position dans la liste (vérifié en jeu le 2026-09-26,
-- objet et prix concordants sur 12 sélections, onglets Tout et Autres).
function shop_ui.selected(shop)
    local index = shop:call("get_lastIndex")
    local units = shop:call("get_buyUnits")
    if index and index >= 0 and index < units:call("get_Count") then return units:call("get_Item", index) end
    return nil
end

-- Location derrière un article : lien posé par apply_shop_swaps, sinon d'après son objet.
-- Porteur de l'icône Archipelago (2026-09-26) : Item_VillageProto_000, un prototype inutilisé
-- (nom "#Rejected#" dans le jeu), seul objet de la case d'icône 20. Son icône passe à la case 19
-- de ui0100, qu'aucun objet n'utilise et où tools/re_engine/make_ap_icon.py a collé le logo
-- (natives/stm/gui/ui0100/tex/ui0100_iam.tex.30, chargé en "loose" par REFramework).
-- Les articles pour un autre jeu sont affichés sous ce porteur.
shop_ui.CARRIER_ID = 3155046651
-- Second prototype inutilisé (Item_VillageProto_001), icône Archipelago, sans prefab : objet
-- d'affichage de la ligne d'objet à l'écran pour les objets des autres jeux.
shop_ui.LINE_CARRIER_ID = 2236906984
shop_ui.CARRIER_ICON_PATTERN = 19
shop_ui.carrier_ready = false

function shop_ui.setup_carrier()
    if shop_ui.carrier_ready or shop_ui.carrier_missing then return end
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    if not specs then return end
    local lists = specs:call("get_itemSpecsList")
    for i = 0, lists:call("get_Count") - 1 do
        local units = lists:call("get_Item", i):get_field("SpecUnits")
        for j = 0, units:call("get_Count") - 1 do
            local unit = units:call("get_Item", j)
            if unit:get_field("ItemID") == shop_ui.LINE_CARRIER_ID then
                -- Porteur de la ligne d'objet (voir shop_ui.LINE_CARRIER_ID).
                pcall(function()
                    local b = unit:get_field("Basic")
                    b:set_field("IconAssetNo", 0)
                    b:set_field("IconPatternNo", shop_ui.CARRIER_ICON_PATTERN)
                    shop_ui.line_carrier_ready = true
                    debug_log("porteur de la ligne d'objet : icône Archipelago posée (" .. tostring(shop_ui.LINE_CARRIER_ID) .. ")")
                end)
            end
            if unit:get_field("ItemID") == shop_ui.CARRIER_ID then
                local basic = unit:get_field("Basic")
                local before = basic:get_field("IconPatternNo")
                basic:set_field("IconPatternNo", shop_ui.CARRIER_ICON_PATTERN)
                shop_ui.carrier_ready = true
                debug_log(string.format("porteur Archipelago : icône %s -> %s", tostring(before),
                    tostring(basic:get_field("IconPatternNo"))))
                if shop_ui.line_carrier_ready then return end
            end
        end
    end
    if shop_ui.carrier_ready then return end
    shop_ui.carrier_missing = true
    debug_log("porteur Archipelago introuvable : icône d'origine pour les objets des autres jeux")
end

-- Modèle 3D Archipelago du porteur (2026-09-26) : une petite table InventoryItemPrefabHolder
-- (porteur -> prefab) est ajoutée par ItemSpecification.register ; findPrefab la vérifie toutes
-- les 10 s et elle est remise si le jeu a rechargé ses tables.
-- Un prefab à part ("ri9990") faisait échouer la création de l'objet porteur (createItemCore :
-- "Invoke threw an exception") : le jeu n'accepte que les ressources d'objets qu'il connaît. Le
-- porteur prend donc le prefab du Remède (ri1020), et le maillage de l'objet affiché dans la
-- boutique est remplacé à la volée par le modèle Archipelago (shop_ui.update_preview,
-- tools/re_engine/make_ap_model.py).
shop_ui.AP_PREFAB_PATH = "Character/It/Prefab_ResourceItem/ri1020/ri1020_Inventory.pfb"
shop_ui.PREVIEW_OBJECT = "ri1020_DetailSearch"
shop_ui.AP_MODEL = "Character/It/it99/000/it99_000_ArchipelagoLogo_Model0000" -- .mesh / .mdf2
-- (Tests du 2026-09-26 : le flacon d'origine s'affichait bien par cette méthode, notre maillage en
-- damier même avec le matériau du flacon -> il lui manquait le second jeu d'UV.)
-- (Test 3 : damier même avec 2 jeux d'UV et le matériau du flacon ; le flacon réexporté par RE
-- Mesh Editor s'affichait bien -> il manquait le squelette / les poids, ajoutés à l'export.)
shop_ui.preview_next = 0
-- Décalage de position de l'objet affiché (réglage en direct, outils de développement).
shop_ui.AP_PREVIEW_OFFSET = { x = 0.0, y = 0.0, z = 0.0 }
-- Test du 2026-09-26 : le modèle s'affichait beaucoup trop gros (mis à la taille du flacon mesurée
-- à l'import, fausse). Échelle appliquée à l'objet affiché, à ajuster puis à intégrer à l'export.
shop_ui.AP_PREVIEW_SCALE = 1.0 -- taille intégrée à l'export (0,08, choisie en jeu le 2026-09-26)

-- Objet affiché dans la boutique pour un article Archipelago (is_ap) : maillage et matériau
-- Archipelago ; remis d'origine dès qu'un autre article est sélectionné.
-- Vrais modèles des objets de ce jeu que la boutique ne sait pas afficher (demande du joueur,
-- 2026-09-27 : Plante, Fluide chimique, Sac de Lei... sans modèle, la Valise à la place du Sac
-- de Lei). La boutique ne précharge que les modèles des objets vendus d'origine ; ces articles
-- passent donc sous le porteur (Remède, toujours chargé) et son maillage est remplacé par celui
-- de l'objet posé au sol (chemins relevés dans les paks, tools/re_engine/pak_extract.py).
shop_ui.REAL_MODELS = {
    [1166469749] = "Character/It/it04/020/it04_020_Herb_Green",                                 -- Plante
    [3461208890] = "Character/It/it04/040/it04_040_Gunpowder_Standard",                          -- Poudre noire
    [526649991] = "Character/It/it04/060/it04_060_Chemical_Standard",                            -- Fluide chimique
    [3196868754] = "Environment/Props/Resource/sm9X/sm92_020_Money/sm92_020_Money_00",           -- Sac de Lei
    [1394398957] = "Environment/Props/Resource/sm9X/sm92_003_Scrap/sm92_003_Scrap_00",           -- Ferraille
    [3397831806] = "Environment/Props/Resource/sm9X/sm92_004_Scrap/sm92_004_Scrap_00",           -- Pièces détachées
}
-- Échelle de ces vrais modèles dans la boutique (2026-09-29 : Ferraille, Plante énormes à l'écran).
-- Affichés à la place du Remède (12,6 cm, taille pour laquelle la boutique cadre la vue) : facteur =
-- 0,126 / plus grande dimension du maillage (mesurée dans Blender). Multiplicateur réglable en
-- direct dans les outils de développement (shop_ui.REAL_SCALE_MULT).
shop_ui.REAL_MODEL_SCALE = {
    ["Character/It/it04/020/it04_020_Herb_Green"] = 0.26,                                  -- 47,9 cm
    ["Character/It/it04/040/it04_040_Gunpowder_Standard"] = 0.59,                          -- 21,2 cm
    ["Character/It/it04/060/it04_060_Chemical_Standard"] = 0.98,                           -- 12,8 cm
    ["Environment/Props/Resource/sm9X/sm92_020_Money/sm92_020_Money_00"] = 0.36,           -- 35,2 cm
    ["Environment/Props/Resource/sm9X/sm92_003_Scrap/sm92_003_Scrap_00"] = 0.20,           -- 62,0 cm
    ["Environment/Props/Resource/sm9X/sm92_004_Scrap/sm92_004_Scrap_00"] = 0.24,           -- 52,5 cm
}
shop_ui.REAL_SCALE_MULT = 1.0

-- Échelle de l'objet affiché dans la boutique pour ce modèle.
function shop_ui.preview_scale(model)
    if model == shop_ui.AP_MODEL then return shop_ui.AP_PREVIEW_SCALE end
    return (shop_ui.REAL_MODEL_SCALE[model] or 1.0) * shop_ui.REAL_SCALE_MULT
end
-- Pièces d'arme (type Upgrade, 2026-09-27 : la Crosse du V61 Custom montrait le V61 entier au
-- sol). Pas de fichier à part : la pièce est une partie du maillage de son arme, et l'examen dans
-- l'inventaire (riNNNN_DetailSearch) n'allume que cette partie. Les parties à allumer sont dans
-- la fiche de la pièce : ItemSpecification.findItemSpec(id).Attachment.OnPartsNos (Crosse V61 =
-- { 5 }, relevé en jeu avec tools/dump_mesh_parts.lua). Maillage : celui de sa présentation
-- (shop_ui.real_model). Sinon : mallette à pièce d'arme.
shop_ui.PART_MODELS = {} -- gid -> { mesh, mdf, parts } ou false (calculé une fois)
shop_ui.PARTS_CASE_MODEL = "Environment/Props/Resource/sm8X/sm82_005_CustomPartsCase/sm82_005_CustomPartsCase_00"

function shop_ui.part_model(specs, gid)
    if shop_ui.PART_MODELS[gid] ~= nil then return shop_ui.PART_MODELS[gid] or nil end
    local result = false
    local ok, err = pcall(function()
        local base = shop_ui.real_model(specs, gid)
        local list = specs:call("findItemSpec", gid):get_field("Attachment"):get_field("OnPartsNos")
        local parts = {}
        for i = 0, list:call("get_Count") - 1 do parts[#parts + 1] = list:call("get_Item", i) end
        if type(base) == "table" and #parts > 0 then
            result = { mesh = base.mesh, mdf = base.mdf, parts = parts }
        end
        debug_log(string.format("pièce d'arme %s : maillage %s, parties %s", tostring(gid),
            type(base) == "table" and base.mesh or tostring(base), table.concat(parts, ",")))
    end)
    if not ok then debug_log("pièce d'arme " .. tostring(gid) .. " : " .. tostring(err)) end
    shop_ui.PART_MODELS[gid] = result
    return result or nil
end

-- Parties du maillage à afficher : celles du modèle (model.parts) s'il en donne, sinon toutes.
function shop_ui.apply_parts(mesh, model)
    local only = nil
    if type(model) == "table" and model.parts then
        only = {}
        for _, pi in ipairs(model.parts) do only[pi] = true end
    end
    for pi = 0, 63 do pcall(function() mesh:call("setPartsEnable", pi, only == nil or only[pi] == true) end) end
end
shop_ui.holders = {}

-- Objets que la boutique sait afficher d'origine : ceux qui ont un prefab DetailSearch
-- (shop_models.json, fait par tools/re_engine/make_shop_models.py). Tous les autres objets de ce
-- jeu passent par le porteur : vrai modèle s'il est dans REAL_MODELS, sinon modèle Archipelago.
shop_ui.detailsearch = {}
shop_ui.ri_models = {} -- riNNNN -> { mesh, mdf } : modèle de présentation de chaque objet
do
    local ok, data = pcall(json.load_file, MOD_NAME .. "/shop_models.json")
    if ok and type(data) == "table" then
        for _, ri in ipairs(data.detailsearch or {}) do shop_ui.detailsearch[ri] = true end
        shop_ui.ri_models = data.models or {}
    end
end

-- Vrai modèle d'un objet de ce jeu : modèle au sol connu (REAL_MODELS), sinon celui de sa
-- présentation (prefab DetailSearch de son riNNNN), sinon nil.
function shop_ui.real_model(specs, gid)
    if shop_ui.REAL_MODELS[gid] then return shop_ui.REAL_MODELS[gid] end
    if shop_ui.overrides[gid] then return nil end -- prefab remplacé le temps de la boutique
    local prefab = specs and specs:call("findPrefab", gid)
    local ri = prefab and tostring(prefab:call("get_Path")):match("(ri%d+)_")
    local model = ri and shop_ui.ri_models[ri] or nil
    -- "Prop_Itemset" : rien de visible au sol -> modèle Archipelago à la place. (La Valise,
    -- sm80_058_Rucksack, est bien celle de la boutique, relevé du 2026-09-27 : gardée.)
    if model and model.mesh:find("Prop_Itemset", 1, true) then return nil end
    return model
end

-- true si la boutique sait montrer cet objet elle-même (nil = on ne sait pas encore).
-- Armes, améliorations, formules, Valise, Crochet : vendus par le Duc, affichés par lui.
shop_ui.SOLD_BY_DUKE_TYPES = { Weapon = true, Upgrade = true, Other = true }
function shop_ui.native_display(specs, gid, def)
    if def and shop_ui.SOLD_BY_DUKE_TYPES[def.type] then return true end
    if not specs or next(shop_ui.detailsearch) == nil then return nil end
    local prefab = specs:call("findPrefab", gid)
    if not prefab then return false end
    local ri = tostring(prefab:call("get_Path")):match("(ri%d+)_")
    return ri ~= nil and shop_ui.detailsearch[ri] == true
end

-- Une fois par partie : objets de ce jeu qui s'afficheront avec le logo Archipelago faute de
-- vrai modèle connu (à ajouter dans REAL_MODELS).
function shop_ui.audit_models(specs)
    if shop_ui.audited or not specs or next(shop_ui.detailsearch) == nil then return end
    shop_ui.audited = true
    local missing = {}
    for name, def in pairs(item_by_name) do
        local gid = def.game_item_id
        if gid and not shop_ui.REAL_MODELS[gid] and def.type ~= "Money"
                and shop_ui.native_display(specs, gid, def) == false then
            local prefab = specs:call("findPrefab", gid)
            missing[#missing + 1] = name .. " (" .. (prefab and tostring(prefab:call("get_Path")) or "pas de prefab") .. ")"
        end
    end
    table.sort(missing)
    debug_log("boutique : objets sans modèle connu (logo Archipelago) : " .. (#missing > 0 and table.concat(missing, ", ") or "aucun"))
end

-- Maillage + matériau (gardés pour toute la partie). model = chemin sans extension commun aux
-- deux fichiers, ou { mesh = ..., mdf = ... } (chemins sans extension, shop_models.json).
function shop_ui.model_holders(model)
    local mesh_path = type(model) == "table" and model.mesh or model
    local mdf_path = type(model) == "table" and model.mdf or model
    local key = mesh_path .. "|" .. mdf_path
    local h = shop_ui.holders[key]
    if not h then
        h = {
            mesh = sdk.create_resource("via.render.MeshResource", mesh_path .. ".mesh"):add_ref()
                :create_holder("via.render.MeshResourceHolder"):add_ref(),
            mdf = sdk.create_resource("via.render.MeshMaterialResource", mdf_path .. ".mdf2"):add_ref()
                :create_holder("via.render.MeshMaterialResourceHolder"):add_ref(),
        }
        shop_ui.holders[key] = h
    end
    return h
end

-- Rotation choisie dans les outils de dev (shop_ui.preview_rot, degrés), appliquée par-dessus la
-- rotation d'origine de l'objet affiché, à chaque mise à jour (la boutique peut la remettre).
-- Rotation propre à certains vrais modèles dans la boutique, en degrés autour de X, Y, Z, ajoutée
-- aux curseurs des outils de dev (2026-09-29 : Ferraille vue surtout de dos, tournée vers la gauche).
shop_ui.REAL_MODEL_ROT = {
    -- Valeurs absolues réglées en jeu par le joueur avec les curseurs (2026-09-30).
    ["Environment/Props/Resource/sm9X/sm92_003_Scrap/sm92_003_Scrap_00"] = { -27.289, -9.446, 0 },
    ["Environment/Props/Resource/sm9X/sm92_004_Scrap/sm92_004_Scrap_00"] = { -27.289, -9.446, 0 },
    ["Character/It/it04/040/it04_040_Gunpowder_Standard"] = { -38.309, -23.090, 0 },
}

-- Rotation ABSOLUE (2026-09-29, 23h) : la rotation « au repos » du présentoir change d'une
-- sélection à l'autre (animation de la boutique : 3 relevés très différents), une rotation
-- relative à elle tombait au hasard. Pour un modèle réglé (REAL_MODEL_ROT) ou quand les curseurs
-- ne sont pas à zéro : rotation posée telle quelle (degrés X, Y, Z), à chaque passage. Sinon on ne
-- touche à rien (rotation du jeu), sauf pour rendre au jeu un objet qu'on vient de tourner.
function shop_ui.apply_preview_rotation(go, model)
    local user, extra = shop_ui.preview_rot or { 0, 0, 0 }, shop_ui.REAL_MODEL_ROT[model]
    local tf = go:call("get_Transform")
    local forced = extra ~= nil or user[1] ~= 0 or user[2] ~= 0 or user[3] ~= 0
    if not forced then
        if shop_ui.rot_forced and shop_ui.preview_rest then tf:call("set_LocalRotation", shop_ui.preview_rest.rotation) end
        shop_ui.rot_forced = false
        return
    end
    extra = extra or { 0, 0, 0 }
    local r = { user[1] + extra[1], user[2] + extra[2], user[3] + extra[3] }
    local hx, hy, hz = math.rad(r[1]) / 2, math.rad(r[2]) / 2, math.rad(r[3]) / 2
    local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
    local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
    local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
    tf:call("set_LocalRotation", qz * qy * qx)
    shop_ui.rot_forced = true
end

-- Objet affiché dans la boutique : model = chemin (sans extension) du maillage à montrer à la
-- place du Remède porteur (modèle Archipelago ou vrai modèle de l'objet), nil = remis d'origine.
function shop_ui.update_preview(model)
    if os.clock() < shop_ui.preview_next then return end
    shop_ui.preview_next = os.clock() + 0.05
    local go = get_scene():call("findGameObject(System.String)", shop_ui.PREVIEW_OBJECT)
    local mesh = go and go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if not mesh then
        if model and (shop_ui.preview_missing_count or 0) < 5 then
            shop_ui.preview_missing_count = (shop_ui.preview_missing_count or 0) + 1
            debug_log("modèle Archipelago : objet affiché introuvable (" .. shop_ui.PREVIEW_OBJECT .. ", "
                .. tostring(go ~= nil) .. ")")
        end
        return
    end
    local address = mesh:get_address()
    -- Plantage du jeu (2026-09-29, changements d'article en rafale) : la boutique détruit et recrée
    -- le présentoir ; une adresse de maillage réutilisée faisait écrire dans le Transform d'un
    -- objet détruit (preview_orig.transform). On n'écrit que dans le Transform de l'objet actuel,
    -- et un Transform différent = nouvel objet (remplacement refait).
    local cur_tf = go:call("get_Transform")
    if shop_ui.preview_orig and shop_ui.preview_orig.transform:get_address() ~= cur_tf:get_address() then
        shop_ui.preview_orig = nil
        shop_ui.preview_swapped = nil
        shop_ui.preview_key = nil
    end
    local is_ap = model == shop_ui.AP_MODEL
    if model then
        local h = shop_ui.model_holders(model)
        local ok_r, err_r = pcall(shop_ui.apply_preview_rotation, go, model)
        if not ok_r and not shop_ui.rot_error_logged then
            shop_ui.rot_error_logged = true
            debug_log("boutique : erreur de rotation " .. tostring(err_r))
        end
        if shop_ui.preview_swapped == address and shop_ui.preview_key == model then
            -- Damier (matériau par défaut) malgré des textures valides, 2026-09-26 : le matériau
            -- posé juste après setMesh, pendant le chargement du maillage, ne tenait pas. On le
            -- repose pendant 2 s, puis on note le matériau réellement en place.
            if os.clock() - (shop_ui.preview_swap_time or 0) < 2.0 then
                mesh:call("set_Material", h.mdf)
            elseif not shop_ui.preview_material_logged then
                shop_ui.preview_material_logged = true
                local current = nil
                pcall(function() current = mesh:call("get_Material"):call("get_ResourcePath") end)
                debug_log("modèle affiché : matériau en place : " .. tostring(current))
            end
            -- Échelle reposée à chaque passage (2026-09-29 : Ferraille redevenue énorme après
            -- plusieurs changements d'article, la boutique remettant la sienne).
            if shop_ui.preview_orig then
                local o, k = shop_ui.preview_orig.scale, shop_ui.preview_scale(model)
                cur_tf:call("set_LocalScale", Vector3f.new(o.x * k, o.y * k, o.z * k))
            end
            if shop_ui.preview_rescale and shop_ui.preview_orig then
                shop_ui.preview_rescale = false
                local k = shop_ui.preview_scale(model)
                local p, d = shop_ui.preview_orig.position, is_ap and shop_ui.AP_PREVIEW_OFFSET or { x = 0, y = 0, z = 0 }
                cur_tf:call("set_LocalPosition", Vector3f.new(p.x + d.x, p.y + d.y, p.z + d.z))
                debug_log(string.format("boutique : échelle %s (multiplicateur vrais modèles %.2f), décalage %.3f %.3f %.3f pour %s", tostring(k), shop_ui.REAL_SCALE_MULT, d.x, d.y, d.z, model))
            end
            return
        end
        local transform = go:call("get_Transform")
        if shop_ui.preview_swapped ~= address or not shop_ui.preview_orig then
            -- État au repos du présentoir (Remède, ri1020), relevé UNE fois (2026-09-29 : relevé à
            -- chaque sélection, parfois pendant l'animation de la boutique -> Ferraille énorme ou
            -- mal tournée au hasard). Toujours le même objet : on repart toujours de cet état.
            if not shop_ui.preview_rest then
                shop_ui.preview_rest = { scale = transform:call("get_LocalScale"),
                    position = transform:call("get_LocalPosition"), rotation = transform:call("get_LocalRotation") }
                local r = shop_ui.preview_rest
                debug_log(string.format("boutique : présentoir au repos : échelle %.3f, rotation (%.3f %.3f %.3f %.3f)",
                    r.scale.x, r.rotation.w, r.rotation.x, r.rotation.y, r.rotation.z))
            end
            local rest = shop_ui.preview_rest
            shop_ui.preview_orig = { mesh = mesh:call("getMesh"), mdf = mesh:call("get_Material"),
                transform = transform, scale = rest.scale, position = rest.position, rotation = rest.rotation }
            pcall(function() shop_ui.preview_orig.mesh:add_ref() end)
            pcall(function() shop_ui.preview_orig.mdf:add_ref() end)
        end
        -- Décalage réglé pour le modèle Archipelago seulement ; échelle propre à chaque modèle
        -- (shop_ui.preview_scale).
        local p, o = shop_ui.preview_orig.position, is_ap and shop_ui.AP_PREVIEW_OFFSET or { x = 0, y = 0, z = 0 }
        transform:call("set_LocalPosition", Vector3f.new(p.x + o.x, p.y + o.y, p.z + o.z))
        local k = shop_ui.preview_scale(model)
        transform:call("set_LocalScale", Vector3f.new(shop_ui.preview_orig.scale.x * k,
            shop_ui.preview_orig.scale.y * k, shop_ui.preview_orig.scale.z * k))
        mesh:call("setMesh", h.mesh)
        mesh:call("set_Material", h.mdf)
        shop_ui.preview_swapped = address
        shop_ui.preview_key = model
        if not shop_ui.preview_scale_logged then
            shop_ui.preview_scale_logged = true
            local sc = shop_ui.preview_orig.scale
            debug_log(string.format("boutique : échelle de l'objet affiché %.3f %.3f %.3f", sc.x, sc.y, sc.z))
        end
        shop_ui.preview_swap_time = os.clock()
        shop_ui.preview_material_logged = false
        debug_log("modèle affiché : " .. model)
    elseif shop_ui.preview_swapped == address and shop_ui.preview_orig then
        mesh:call("setMesh", shop_ui.preview_orig.mesh)
        mesh:call("set_Material", shop_ui.preview_orig.mdf)
        pcall(function() cur_tf:call("set_LocalScale", shop_ui.preview_orig.scale) end)
        pcall(function() cur_tf:call("set_LocalPosition", shop_ui.preview_orig.position) end)
        pcall(function()
            if shop_ui.preview_orig.rotation then
                cur_tf:call("set_LocalRotation", shop_ui.preview_orig.rotation)
            end
        end)
        shop_ui.preview_swapped = nil
        shop_ui.preview_key = nil
        -- Oublié après remise d'origine (2026-09-29 : la Ferraille tournait un peu plus à chaque
        -- retour dessus : la rotation de départ était relevée sur l'objet déjà tourné).
        shop_ui.preview_orig = nil
    end
end
-- (Test du 2026-09-26 avec le prefab des cartouches, ri2020 : elles s'affichaient, donc la
-- boutique utilise bien le prefab enregistré.)
shop_ui.model_next_check = 0

function shop_ui.setup_model()
    if shop_ui.model_failed or os.clock() < shop_ui.model_next_check then return end
    shop_ui.model_next_check = os.clock() + 10
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    if not specs then return end
    local current = specs:call("findPrefab", shop_ui.CARRIER_ID)
    if current and current:call("get_Path") == shop_ui.AP_PREFAB_PATH then
        -- Déjà posé avant un "Reset scripts" : la table n'était plus connue, override_prefab
        -- échouait et la Plante de la boutique passait sous le porteur (icône AP, 2026-09-27).
        -- C'est la table où l'entrée a été ajoutée (1re de la liste, voir plus bas).
        if not shop_ui.model_holder then
            shop_ui.model_holder = specs:call("get_prefabHolderList"):call("get_Item", 0)
        end
        if not shop_ui.model_ready_logged then
            local ready = current:call("get_Ready")
            debug_log("modèle Archipelago : prefab prêt = " .. tostring(ready))
            if ready then shop_ui.model_ready_logged = true end
        end
        return
    end
    -- 1er essai du 2026-09-26 : exception sans détail. Chaque étape est donc notée, et le
    -- prefab est d'abord cloné depuis celui d'un objet existant (Remède, 1429493426), puis créé
    -- de zéro en secours.
    local step = "début"
    local ok, err = pcall(function()
        step = "création du prefab"
        -- 4e essai : le clone du prefab du Remède gardait la ressource du Remède malgré
        -- set_Path (le Remède s'affichait). Prefab neuf d'abord, clone seulement en secours.
        local prefab = nil
        pcall(function()
            prefab = sdk.create_instance("via.Prefab")
            prefab:call(".ctor")
        end)
        shop_ui.model_source = prefab and "prefab neuf" or "clone du Remède"
        if not prefab then
            local base = specs:call("findPrefab", 1429493426)
            prefab = base and base:call("Clone")
        end
        pcall(function() prefab = prefab:add_ref() end)
        step = "set_Path"
        prefab:call("set_Path", shop_ui.AP_PREFAB_PATH)
        step = "set_Standby"
        pcall(function() prefab:call("set_Standby", true) end)
        -- 2e essai : créer une entrée (InventoryItemPrefabHolder.Unit) échoue ("entrée de
        -- table"). On copie donc une entrée d'une table du jeu, on l'ajoute à cette table, puis
        -- on la désenregistre / réenregistre (index éventuel construit à l'enregistrement).
        step = "table du jeu"
        local holder = specs:call("get_prefabHolderList"):call("get_Item", 0)
        local units = holder:get_field("Units")
        step = "copie d'une entrée"
        local unit = units:call("get_Item", 0):call("MemberwiseClone"):add_ref()
        -- 3e essai : ItemID est le NOM interne (texte) ; le numéro utilisé partout est ItemIDHash.
        step = "entrée : objet"
        unit:set_field("ItemIDHash", shop_ui.CARRIER_ID)
        pcall(function() unit:set_field("ItemID", sdk.create_managed_string("Item_VillageProto_000")) end)
        step = "entrée : prefab"
        unit:set_field("ItemPrefab", prefab)
        step = "ajout de l'entrée"
        units:call("Add", unit)
        step = "réenregistrement"
        pcall(function() specs:call("unregister(app.InventoryItemPrefabHolder)", holder) end)
        specs:call("register(app.InventoryItemPrefabHolder)", holder)
        shop_ui.model_holder = holder
        step = "fini"
    end)
    if not ok then err = "étape " .. step .. " : " .. tostring(err) end
    local found = nil
    pcall(function() found = specs:call("findPrefab", shop_ui.CARRIER_ID):call("get_Path") end)
    debug_log(string.format("modèle Archipelago : enregistrement %s (%s), findPrefab -> %s",
        ok and "ok" or tostring(err), tostring(shop_ui.model_source), tostring(found)))
    if not ok then shop_ui.model_failed = true end
    -- Diagnostic (2026-09-26, le Remède s'affichait) : nos fichiers sont-ils trouvés ?
    pcall(function()
        local prefab = specs:call("findPrefab", shop_ui.CARRIER_ID)
        local report = {}
        for _, m in ipairs({ "get_Exist", "get_Ready", "get_Valid", "get_Standby" }) do
            local ok_m, v = pcall(function() return prefab:call(m) end)
            report[#report + 1] = m .. "=" .. (ok_m and tostring(v) or "?")
        end
        for _, res in ipairs({ { "via.render.MeshResource", "Character/It/it99/000/it99_000_ArchipelagoLogo_Model0000.mesh" },
                { "via.render.MeshMaterialResource", "Character/It/it99/000/it99_000_ArchipelagoLogo_Model0000.mdf2" },
                { "via.Prefab", shop_ui.AP_PREFAB_PATH },
                -- Damier "texture manquante" sur le modèle (2026-09-26) : nos textures, et une du flacon.
                { "via.render.TextureResource", "Character/It/it99/000/it99_000_ArchipelagoLogo_Model0000_A_ALBM.tex" },
                { "via.render.TextureResource", "Character/It/it99/000/it99_000_ArchipelagoLogo_Model0000_A_NRMR.tex" },
                { "via.render.TextureResource", "Character/It/it04/000/it04_000_AntisepticSolution_Medium_A_ALBM.tex" },
                { "via.render.TextureResource", "GUI/ui0100/tex/ui0100_IAM.tex" } }) do
            local ok_r, r = pcall(function() return sdk.create_resource(res[1], res[2]) end)
            report[#report + 1] = res[1] .. "=" .. (ok_r and tostring(r ~= nil) or ("erreur " .. tostring(r)))
        end
        debug_log("modèle Archipelago : " .. table.concat(report, " "))
    end)
end

-- Icône d'origine pour les objets de ce jeu sans modèle de boutique (demande du joueur,
-- 2026-09-27 : sous le porteur, la Plante avait l'icône Archipelago). L'article garde donc son
-- vrai objet (icône, nom), et seulement pendant que la boutique est ouverte, l'entrée de prefab de
-- cet objet pointe vers celui du porteur (Remède) : la boutique crée ri1020_DetailSearch, dont
-- update_preview remplace le maillage par le vrai modèle. Tout est remis à la fermeture.
shop_ui.overrides = {}

function shop_ui.reregister(specs, holders)
    for holder in pairs(holders) do
        pcall(function() specs:call("unregister(app.InventoryItemPrefabHolder)", holder) end)
        pcall(function() specs:call("register(app.InventoryItemPrefabHolder)", holder) end)
    end
end

function shop_ui.override_prefab(specs, gid)
    if shop_ui.overrides[gid] then return true end
    local prefab = specs:call("findPrefab", shop_ui.CARRIER_ID)
    if not prefab or not shop_ui.model_holder then return false end
    local touched, entry = {}, { changed = {} }
    local list = specs:call("get_prefabHolderList")
    for i = 0, list:call("get_Count") - 1 do
        local holder = list:call("get_Item", i)
        local units = holder:get_field("Units")
        for j = 0, units:call("get_Count") - 1 do
            local u = units:call("get_Item", j)
            if u:get_field("ItemIDHash") == gid then
                local orig = u:get_field("ItemPrefab")
                pcall(function() orig:add_ref() end)
                entry.changed[#entry.changed + 1] = { unit = u, orig = orig, holder = holder }
                u:set_field("ItemPrefab", prefab)
                touched[holder] = true
            end
        end
    end
    if #entry.changed == 0 then
        local units = shop_ui.model_holder:get_field("Units")
        local u = units:call("get_Item", 0):call("MemberwiseClone"):add_ref()
        u:set_field("ItemIDHash", gid)
        u:set_field("ItemPrefab", prefab)
        units:call("Add", u)
        entry.added = u
        touched[shop_ui.model_holder] = true
    end
    shop_ui.reregister(specs, touched)
    shop_ui.overrides[gid] = entry
    return true
end

function shop_ui.restore_prefabs()
    if next(shop_ui.overrides) == nil or shop_is_open() then return end
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    if not specs then return end
    local touched = {}
    for _, entry in pairs(shop_ui.overrides) do
        for _, c in ipairs(entry.changed) do
            pcall(function() c.unit:set_field("ItemPrefab", c.orig) end)
            touched[c.holder] = true
        end
        if entry.added then
            pcall(function() shop_ui.model_holder:get_field("Units"):call("Remove", entry.added) end)
            touched[shop_ui.model_holder] = true
        end
    end
    shop_ui.overrides = {}
    shop_ui.reregister(specs, touched)
    debug_log("boutique : prefabs d'origine remis")
end

---------------------------------------------------------------------------
-- Objets au sol (demande du joueur, 2026-09-27)
---------------------------------------------------------------------------
-- Chaque emplacement-check encore à faire montre ce qu'il donne vraiment : modèle Archipelago
-- pour un objet d'un autre jeu, vrai modèle de l'objet pour un objet de ce jeu (même si ce n'est
-- pas un modèle "au sol" d'origine). Quand on s'en approche, l'invite d'action affiche
-- "[AP] objet". L'objet posé est ItemSpawnInfo.get_spawnInstance (via.GameObject) ; son maillage
-- est remplacé comme dans la boutique (shop_ui.model_holders).
shop_ui.world = { entries = {}, next_scan = 0, next_update = 0, swapped = {}, kept = {}, logged = 0 }

-- Composants via.render.Mesh d'un objet et de ses enfants (2 niveaux).
function shop_ui.world.meshes(go, out, depth)
    out = out or {}
    depth = depth or 0
    local mesh = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if mesh then out[#out + 1] = mesh end
    if depth < 2 then
        local child = go:call("get_Transform"):call("get_Child")
        while child do
            shop_ui.world.meshes(child:call("get_GameObject"), out, depth + 1)
            child = child:call("get_Next")
        end
    end
    return out
end

-- Placement par boîtes englobantes (2026-09-29 : modèles décalés sur le côté dans les mallettes,
-- Mine géante enfoncée dans le sol à la place d'une Bombe tuyau, munitions à moitié dans un
-- meuble). Avant : notre os "_00" sur celui de l'objet d'origine, à l'échelle de l'objet
-- d'origine ; or chaque modèle a son origine ailleurs (pied, centre, bord) et certains objets
-- d'origine sont agrandis par le jeu (x1,6). Désormais : notre objet n'est plus rattaché à
-- l'objet d'origine (pas d'échelle héritée), il est à sa taille réelle (x GROUND.scale ; logo AP
-- x GROUND.ap_scale, car réduit à 8 cm pour la boutique), tourné comme l'os "_00" d'origine, et
-- déplacé pour que le bas-centre de sa boîte (get_WorldAABB) tombe sur le bas-centre de la boîte
-- de l'objet d'origine (relevée avant de le cacher). GROUND.enabled = false : ancienne méthode.
-- Taille plafonnée (2026-09-29 : tas de Ferraille de 84 cm dans une table, à la place d'une boîte
-- de cartouches) : au plus GROUND.fit x la taille de l'objet d'origine (au moins GROUND.min_size).
-- Taille minimale 0,10 -> 0,20 m (2026-09-30) : Madalina (corps, 57 cm) à la place d'un Fragment
-- de cristal de 3 cm réduite à 10 cm, invisible pour le joueur (pareil pour une pièce mécanique).
-- min_visible (2026-09-30) : taille minimale d'AFFICHAGE (m). min_size ne fait que relever le
-- plafond ; une Vivianite de 7 cm posée à la place d'une boîte de munitions restait introuvable.
-- fit_h (2026-09-30) : hauteur au plus fit_h x celle de l'objet d'origine (au moins min_h). Valise
-- de 25 cm de haut à la place d'une poudre de 7 cm dans un tiroir : cachée dans le meuble.
shop_ui.world.GROUND = { enabled = true, scale = 1.0, ap_scale = 2.0, fit = 1.5, min_size = 0.20, min_visible = 0.12,
    fit_h = 1.5, min_h = 0.08 }
-- Échelle propre à certains modèles au sol (x GROUND.scale). Vivianite trop petite dans le
-- tiroir (2026-09-29, réglée en jeu par le joueur à 1,55 ; les autres objets vont bien).
shop_ui.world.GROUND.model_scale = {
    ["Environment/Props/Resource/sm9X/sm92_047_Gem/sm92_047_Gem_00"] = 1.55, -- Vivianite
}
-- Objet d'origine planté dans un pot du décor (2026-09-29 : munitions à la place d'une Plante,
-- dans le pot) : le bas de la Plante est au fond du pot, que le mod ne voit pas (il fait partie
-- du décor). Notre objet est posé plus haut : fraction de la hauteur de l'objet d'origine
-- (maillage d'origine en minuscules). Réglable dans les outils de dev.
shop_ui.world.GROUND.host_lift = {
    ["character/it/it04/020/it04_020_herb_green.mesh"] = 0.3, -- Plante
}

-- Boîte englobante dans le monde d'un maillage affiché, nil si invalide (objet caché ou pas
-- encore dessiné : bornes à +/-3,4e38).
function shop_ui.world.box(mesh)
    local ok, lo, hi = pcall(function()
        local b = mesh:call("get_WorldAABB")
        return b:get_field("minpos"), b:get_field("maxpos")
    end)
    if not ok or not lo or not hi then return nil end
    for _, x in ipairs({ lo.x, lo.y, lo.z, hi.x, hi.y, hi.z }) do
        if x ~= x or math.abs(x) > 1e5 then return nil end
    end
    if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z then return nil end
    return { lo = { x = lo.x, y = lo.y, z = lo.z }, hi = { x = hi.x, y = hi.y, z = hi.z } }
end

function shop_ui.world.union_box(meshes)
    local u = nil
    for _, m in ipairs(meshes or {}) do
        local b = shop_ui.world.box(m)
        if b and not u then
            u = b
        elseif b then
            for _, a in ipairs({ "x", "y", "z" }) do
                u.lo[a] = math.min(u.lo[a], b.lo[a])
                u.hi[a] = math.max(u.hi[a], b.hi[a])
            end
        end
    end
    return u
end

-- Bas-centre de la boîte de l'objet d'origine, relatif à son point d'ancrage (os "_00").
function shop_ui.world.target_of(box, anchor)
    return { x = (box.lo.x + box.hi.x) / 2 - anchor.x, y = box.lo.y - anchor.y, z = (box.lo.z + box.hi.z) / 2 - anchor.z }
end

-- Pose par boîtes englobantes (voir GROUND), à chaque image.
-- Objet d'origine caché par ses PARTIES, pas par set_DrawDefault(false) (2026-09-29 : Vivianite
-- sous le tiroir ouvert). Le tiroir n'emporte pas l'objet : il anime son os "_00". Un maillage non
-- dessiné n'a plus ses os mis à jour, l'os restait à la place du tiroir fermé. Parties éteintes,
-- le maillage reste "dessiné" et ses os suivent.
function shop_ui.world.hide_host(host)
    if not host.parts then
        host.parts = {}
        for pi = 0, 63 do
            pcall(function() host.parts[pi] = host.mesh:call("getPartsEnable", pi) end)
        end
    end
    for pi = 0, 63 do pcall(function() host.mesh:call("setPartsEnable", pi, false) end) end
    pcall(function() host.mesh:call("set_DrawDefault", true) end)
end

function shop_ui.world.show_host(host)
    for pi, enabled in pairs(host.parts or {}) do
        pcall(function() host.mesh:call("setPartsEnable", pi, enabled) end)
    end
    pcall(function() host.mesh:call("set_DrawDefault", host.draw ~= false) end)
end

-- Ancre (position et rotation de l'os "_00" d'origine) recalculée depuis l'objet d'origine lui-même
-- (2026-09-29 : Vivianite restée sous le tiroir ouvert). L'objet d'origine caché, le jeu ne met
-- plus à jour ses os : l'os "_00" restait à la place du tiroir fermé. Son décalage par rapport à
-- l'objet est relevé une fois (objet encore à jour), puis appliqué à la pose de l'objet, qui suit
-- le tiroir.
function shop_ui.world.anchor_of(rec)
    local hj = rec.host_tf:call("getJointByName", "_00")
    if hj then return hj:call("get_Position"), hj:call("get_Rotation") end
    local hp, hr = rec.host_tf:call("get_Position"), rec.host_tf:call("get_Rotation")
    if not rec.joint_off then
        rec.joint_off, rec.joint_rot = Vector3f.new(0, 0, 0), Quaternion.new(1, 0, 0, 0)
        pcall(function()
            local hj = rec.host_tf:call("getJointByName", "_00")
            if not hj then return end
            local jp, jr = hj:call("get_Position"), hj:call("get_Rotation")
            local inv = Quaternion.new(hr.w, -hr.x, -hr.y, -hr.z)
            rec.joint_off = inv * Vector3f.new(jp.x - hp.x, jp.y - hp.y, jp.z - hp.z)
            rec.joint_rot = inv * jr
        end)
    end
    local o = hr * rec.joint_off
    return Vector3f.new(hp.x + o.x, hp.y + o.y, hp.z + o.z), hr * rec.joint_rot
end

function shop_ui.world.place_by_box(rec)
    local anchor, rot = shop_ui.world.anchor_of(rec)
    local tf = rec.go:call("get_Transform")
    -- Objet d'origine pas encore dessiné (boîte invalide) : il reste visible, le nôtre caché,
    -- jusqu'à 1,5 s ; ensuite (sans boîte), centre de notre boîte sur l'os "_00" d'origine.
    if rec.pending_hide then
        local hb = shop_ui.world.union_box(rec.host_meshes)
        -- Mallette du château (2026-09-29) : l'objet d'origine n'est dessiné qu'une fois proche et
        -- mallette ouverte ; abandon (centre sur l'os "_00") seulement 1,5 s après être arrivé à
        -- moins de 3 m.
        local close = false
        pcall(function()
            local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position")
            close = (cam.x - anchor.x) ^ 2 + (cam.y - anchor.y) ^ 2 + (cam.z - anchor.z) ^ 2 < 9
        end)
        if close then rec.close_since = rec.close_since or os.clock() else rec.close_since = nil end
        if hb or (rec.close_since and os.clock() - rec.close_since > 1.5) then
            rec.pending_hide = false
            if hb then
                rec.target_rel = shop_ui.world.target_of(hb, anchor)
                rec.host_size = math.max(hb.hi.x - hb.lo.x, hb.hi.y - hb.lo.y, hb.hi.z - hb.lo.z)
                rec.host_height = hb.hi.y - hb.lo.y
            end
            for _, host in ipairs(rec.hosts or {}) do shop_ui.world.hide_host(host) end
            pcall(function() rec.mesh:call("set_DrawDefault", true) end)
        end
    end
    local G = shop_ui.world.GROUND
    -- Modèle = chemin, ou table { mesh, mdf } (Vivianite, 2026-09-29 : échelle 1,55 jamais appliquée).
    local key = type(rec.model) == "table" and rec.model.mesh or rec.model
    local k = rec.is_ap and G.ap_scale or G.scale * (G.model_scale[key] or 1.0)
    if rec.natural and rec.host_size then
        k = math.min(k, math.max(rec.host_size * G.fit, G.min_size) / rec.natural)
    end
    if rec.natural_h and rec.natural_h > 0 and rec.host_height then
        k = math.min(k, math.max(rec.host_height * G.fit_h, G.min_h) / rec.natural_h)
    end
    if rec.natural and rec.natural > 0 and rec.natural * k < (G.min_visible or 0) then
        k = G.min_visible / rec.natural
    end
    -- Arme d'origine (2026-10-08, M1897 #001 : logo de 0,18 m sur un fusil de 1,59 m, invisible) :
    -- au moins 0,45 m.
    local weapon_def = item_by_name[rec.loc and rec.loc.original_item or ""]
    if weapon_def and weapon_def.type == "Weapon" and rec.natural and rec.natural > 0 and rec.natural * k < 0.45 then
        k = 0.45 / rec.natural
    end
    rec.k = k
    tf:call("set_LocalScale", Vector3f.new(k, k, k))
    rec.fix = rec.fix or { x = 0, y = 0, z = 0 }
    tf:call("set_Rotation", rot)
    tf:call("set_Position", Vector3f.new(anchor.x + rec.fix.x, anchor.y + rec.fix.y, anchor.z + rec.fix.z))
    -- Recalage : la boîte de notre maillage suit avec une image de retard, d'où l'attente
    -- entre deux corrections.
    if rec.pending_hide or os.clock() < (rec.next_fit or 0) then return end
    rec.next_fit = os.clock() + 0.15
    local b = shop_ui.world.box(rec.mesh)
    if not b then return end
    -- Taille réelle de notre modèle (à l'échelle 1), mesurée une fois ; l'échelle en tient compte
    -- à l'image suivante, puis la position se recale.
    if not rec.natural and rec.k and rec.k > 0 then
        rec.natural = math.max(b.hi.x - b.lo.x, b.hi.y - b.lo.y, b.hi.z - b.lo.z) / rec.k
        rec.natural_h = (b.hi.y - b.lo.y) / rec.k
        -- Boîte d'origine démesurée (2026-09-29, labyrinthe à bille de la salle du Duc : 1,36 m pour
        -- le Crâne cramoisi, bas de la boîte sous le plateau, munitions invisibles dessous) : on
        -- l'ignore, centre de notre boîte sur l'os "_00".
        -- Sauf pour une ARME d'origine (2026-10-07 : M1897 #001, 1,59 m, vraie taille d'un fusil ;
        -- le logo posé sur l'os _00 finissait dans la table, invisible).
        local orig_def = item_by_name[rec.loc and rec.loc.original_item or ""]
        local orig_weapon = orig_def and orig_def.type == "Weapon"
        if rec.host_size and not orig_weapon and rec.host_size > math.max(0.6, 4 * rec.natural) then
            debug_log(string.format("objet au sol : %s : boîte d'origine ignorée (%.2f m pour un objet de %.2f m), centre sur l'os _00",
                rec.loc.name, rec.host_size, rec.natural))
            rec.target_rel, rec.host_size = nil, nil
        end
        if rec.host_size and (shop_ui.world.size_logged or 0) < 60 then
            shop_ui.world.size_logged = (shop_ui.world.size_logged or 0) + 1
            debug_log(string.format("objet au sol : %s : taille réelle %.2f, objet d'origine %.2f (échelle %.2f)",
                rec.loc.name, rec.natural, rec.host_size, rec.k))
        end
        return
    end
    local t = rec.target_rel
    local cx, cz = (b.lo.x + b.hi.x) / 2, (b.lo.z + b.hi.z) / 2
    local dx, dy, dz
    if t then
        local lift = (shop_ui.world.GROUND.host_lift[rec.host_path or ""] or 0) * (rec.host_height or 0)
        dx, dy, dz = anchor.x + t.x - cx, anchor.y + t.y + lift - b.lo.y, anchor.z + t.z - cz
    else
        dx, dy, dz = anchor.x - cx, anchor.y - (b.lo.y + b.hi.y) / 2, anchor.z - cz
    end
    if math.abs(dx) + math.abs(dy) + math.abs(dz) > 0.003 then
        rec.fix = { x = rec.fix.x + dx, y = rec.fix.y + dy, z = rec.fix.z + dz }
        rec.fits = (rec.fits or 0) + 1
        if rec.fits <= 2 and (shop_ui.world.fit_logged or 0) < 60 then
            shop_ui.world.fit_logged = (shop_ui.world.fit_logged or 0) + 1
            debug_log(string.format("objet au sol : %s : recalé de %.3f %.3f %.3f (taille %.2f x %.2f x %.2f, cible %s)",
                rec.loc.name, dx, dy, dz, b.hi.x - b.lo.x, b.hi.y - b.lo.y, b.hi.z - b.lo.z,
                t and "bas-centre de l'objet d'origine" or "os _00"))
        end
    end
end

-- Diagnostic (outils de dev, 2026-09-29 : Vivianite jamais visible dans un tiroir, objet du
-- labyrinthe à bille invisible) : état de chaque objet AP à moins de 6 m, dans le journal.
function shop_ui.world.fmt_box(b)
    return b and string.format("%.2f %.2f %.2f -> %.2f %.2f %.2f", b.lo.x, b.lo.y, b.lo.z, b.hi.x, b.hi.y, b.hi.z) or "invalide"
end

function shop_ui.world.diagnose()
    local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position")
    local fmt_box = shop_ui.world.fmt_box
    local count = 0
    for _, rec in pairs(shop_ui.world.swapped) do
        pcall(function()
            if not rec.go then return end
            local p = rec.go:call("get_Transform"):call("get_Position")
            local d = math.sqrt((p.x - cam.x) ^ 2 + (p.y - cam.y) ^ 2 + (p.z - cam.z) ^ 2)
            if d > 6 then return end
            count = count + 1
            local info = { string.format("dist %.1f", d), string.format("position %.2f %.2f %.2f", p.x, p.y, p.z) }
            pcall(function()
                local a = shop_ui.world.anchor_of(rec)
                local hj = rec.host_tf:call("getJointByName", "_00")
                local j = hj and hj:call("get_Position")
                info[#info + 1] = string.format("ancre %.2f %.2f %.2f (os _00 du jeu : %s)", a.x, a.y, a.z,
                    j and string.format("%.2f %.2f %.2f", j.x, j.y, j.z) or "aucun")
            end)
            info[#info + 1] = "par boîtes " .. tostring(rec.by_box) .. ", en attente " .. tostring(rec.pending_hide)
            info[#info + 1] = string.format("échelle %s, taille réelle %s, objet d'origine %s", tostring(rec.k),
                tostring(rec.natural), tostring(rec.host_size))
            if rec.fix then info[#info + 1] = string.format("recalage %.3f %.3f %.3f", rec.fix.x, rec.fix.y, rec.fix.z) end
            if rec.target_rel then
                info[#info + 1] = string.format("cible %.3f %.3f %.3f", rec.target_rel.x, rec.target_rel.y, rec.target_rel.z)
            end
            info[#info + 1] = "notre boîte " .. fmt_box(shop_ui.world.box(rec.mesh))
            pcall(function() info[#info + 1] = "notre affichage " .. tostring(rec.mesh:call("get_DrawDefault")) end)
            pcall(function() info[#info + 1] = "maillage " .. tostring(rec.mesh:call("getMesh"):call("get_ResourcePath")) end)
            pcall(function() info[#info + 1] = "GO actif " .. tostring(rec.go:call("get_UpdateSelf")) .. "/" .. tostring(rec.go:call("get_DrawSelf")) end)
            for i, host in ipairs(rec.hosts or {}) do
                pcall(function()
                    info[#info + 1] = string.format("origine %d : affichage %s, boîte %s", i,
                        tostring(host.mesh:call("get_DrawDefault")), fmt_box(shop_ui.world.box(host.mesh)))
                end)
            end
            debug_log("diagnostic : " .. rec.loc.name .. " : " .. table.concat(info, " ; "))
        end)
    end
    debug_log(string.format("diagnostic : %d objet(s) AP à moins de 6 m (caméra %.2f %.2f %.2f)", count, cam.x, cam.y, cam.z))
end

-- Pose de notre objet (2026-09-27, objets couchés sur le côté) : l'objet d'origine place son
-- modèle avec son os "_00" (tiroir qui s'ouvre, objet posé à plat). On copie la pose réelle de
-- cet os dans le monde, moins la position de notre propre os "_00" (ce que faisait la 1re
-- méthode, où notre maillage suivait cet os). Appelé à chaque image : le tiroir bouge.
function shop_ui.world.follow_joint(rec)
    if rec.by_box then return shop_ui.world.place_by_box(rec) end
    local hj = rec.host_tf:call("getJointByName", "_00")
    if not hj then return end
    local tf = rec.go:call("get_Transform")
    if not rec.bind_offset then
        rec.bind_offset = Vector3f.new(0, 0, 0)
        pcall(function()
            local own = tf:call("getJointByName", "_00")
            local p = own and own:call("get_BaseLocalPosition")
            if p then rec.bind_offset = Vector3f.new(p.x, p.y, p.z) end
        end)
        local ws = shop_ui.world.world_scale(rec.host_tf)
        rec.world_k = ws and ws.x or 1
    end
    local rot = hj:call("get_Rotation")
    local off = rec.bind_offset
    local k = rec.world_k
    local shifted = rot * Vector3f.new(-off.x * k, -off.y * k, -off.z * k)
    local pos = hj:call("get_Position")
    tf:call("set_Rotation", rot)
    tf:call("set_Position", Vector3f.new(pos.x + shifted.x, pos.y + shifted.y, pos.z + shifted.z))
end

-- Crée notre objet (via.GameObject + via.render.Mesh) sous l'objet d'origine, dont les
-- maillages sont cachés. nil si impossible (la méthode 1 prend alors le relais).
function shop_ui.world.spawn_own(meshes, h, model)
    local ok, res = pcall(function()
        local host_tf = meshes[1]:call("get_GameObject"):call("get_Transform")
        local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)"):call(nil, "ArchipelagoModel")
        if not go then return nil end
        pcall(function() go = go:add_ref() end)
        shop_ui.world.created[go:get_address()] = go
        local mc = go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        mc:call("setMesh", h.mesh)
        mc:call("set_Material", h.mdf)
        shop_ui.apply_parts(mc, model)
        local tf = go:call("get_Transform")
        local by_box = shop_ui.world.GROUND.enabled
        if not by_box then
            tf:call("set_Parent", host_tf)
            tf:call("set_LocalPosition", Vector3f.new(0, 0, 0))
            tf:call("set_LocalScale", Vector3f.new(1, 1, 1))
        end
        -- (Pose : shop_ui.world.follow_joint, à chaque image.)
        -- Logo "en œufs" au sol, rond en boutique (2026-09-27) : matrice complète notée, pour
        -- voir un éventuel cisaillement (axes non perpendiculaires) que les échelles ne montrent pas.
        if (shop_ui.world.matrix_logged or 0) < 6 then
            shop_ui.world.matrix_logged = (shop_ui.world.matrix_logged or 0) + 1
            pcall(function()
                local m = tf:call("get_WorldMatrix")
                local rows = {}
                for r = 0, 3 do
                    local v = m[r]
                    rows[#rows + 1] = string.format("(%.3f %.3f %.3f %.3f)", v.x, v.y, v.z, v.w)
                end
                local a, b, c = m[0], m[1], m[2]
                debug_log(string.format("objet au sol : matrice de l'objet AP sous %s : %s ; produits scalaires ab %.4f ac %.4f bc %.4f",
                    tostring(host_tf:call("get_GameObject"):call("get_Name")), table.concat(rows, " "),
                    a.x * b.x + a.y * b.y + a.z * b.z, a.x * c.x + a.y * c.y + a.z * c.z, b.x * c.x + b.y * c.y + b.z * c.z))
            end)
        end
        local hosts = {}
        -- Boîte de l'objet d'origine, relevée AVANT de le cacher (caché : boîte invalide).
        local host_box = by_box and shop_ui.world.union_box(meshes) or nil
        local pending = by_box and not host_box
        for _, m in ipairs(meshes) do
            hosts[#hosts + 1] = { mesh = m, draw = m:call("get_DrawDefault") }
            if not pending then
                if by_box then shop_ui.world.hide_host(hosts[#hosts]) else m:call("set_DrawDefault", false) end
            end
        end
        if pending then mc:call("set_DrawDefault", false) end
        local rec = { go = go, mesh = mc, hosts = hosts, host_tf = host_tf, by_box = by_box,
            host_meshes = meshes, pending_hide = pending, is_ap = model == shop_ui.AP_MODEL, model = model, holder = h }
        pcall(function() rec.host_path = meshes[1]:call("getMesh"):call("get_ResourcePath"):lower() end)
        if host_box then
            rec.target_rel = shop_ui.world.target_of(host_box, (shop_ui.world.anchor_of(rec)))
            rec.host_size = math.max(host_box.hi.x - host_box.lo.x, host_box.hi.y - host_box.lo.y, host_box.hi.z - host_box.lo.z)
            rec.host_height = host_box.hi.y - host_box.lo.y
        end
        return rec
    end)
    if not ok then
        if not shop_ui.world.own_error_logged then
            shop_ui.world.own_error_logged = true
            debug_log("objet au sol : création de l'objet AP impossible (" .. tostring(res) .. "), méthode 1")
        end
        return nil
    end
    return res
end

-- "Reset scripts" / rechargement du mod : nos objets sont retirés et les objets d'origine
-- réaffichés (sinon objet AP orphelin, ou objet d'origine resté caché).
re.on_script_reset(function()
    for _, rec in pairs(shop_ui.world.kept) do pcall(shop_ui.world.restore_pickup, rec) end
    for _, rec in pairs(shop_ui.world.swapped) do
        pcall(shop_ui.world.restore_pickup, rec)
        if rec.go then
            pcall(function()
                shop_ui.world.created[rec.go:get_address()] = nil
                sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)"):call(nil, rec.go)
            end)
            for _, host in ipairs(rec.hosts or {}) do shop_ui.world.show_host(host) end
        elseif rec.originals then
            for i, m in ipairs(rec.meshes) do
                local o = rec.originals[i]
                pcall(function()
                    m:call("setMesh", o.mesh)
                    m:call("set_Material", o.mdf)
                end)
            end
        end
    end
end)

-- Objets recyclés (2026-09-27) : le jeu réutilise les objets posés (pool). Un flacon passé en
-- Fragment de cristal pour un check est ressorti tel quel pour un autre check (Fluide chimique
-- #027, qui devait garder son flacon). Dès qu'un objet modifié ne sert plus à son check (check
-- fait, ou objet rendu au pool / donné à un autre emplacement), son modèle d'origine est remis.
-- Encore utilisé pour son check ? (2026-09-29 : 586 retraits / recréations, toutes les ~8 s pour
-- la Vivianite devant le joueur.) Une ERREUR de lecture (objet du jeu plus accessible par la
-- référence gardée) ne vaut plus retrait ; raison notée dans le journal.
shop_ui.world.GONE = "objet plus posé (get_spawnInstance nil)"
function shop_ui.world.still_used(rec, key)
    local reason = nil
    local ok, err = pcall(function()
        local inst = rec.si:call("get_spawnInstance")
        if location_done(rec.loc) == nil then
            reason = "check absent de la seed"
        elseif (save_sync.picked_locs or {})[rec.loc.key] then
            reason = "objet ramassé"
        elseif inst == nil then
            reason = shop_ui.world.GONE
        elseif inst:get_address() ~= key then
            reason = "autre objet posé (pool)"
        end
    end)
    if not ok then
        -- Erreur qui dure (zone déchargée) : retrait quand même au bout de 10 s.
        rec.err_since = rec.err_since or os.clock()
        return os.clock() - rec.err_since < 10, "erreur de lecture : " .. tostring(err)
    end
    rec.err_since = nil
    return reason == nil, reason
end

-- Retire notre objet posé et remet l'objet d'origine (plus utilisé, ou modèle à changer).
-- gone : l'objet du jeu n'est plus posé (get_spawnInstance nil). Crashs du moteur dans la Cave à vin
-- (2026-10-03/04, 5 fois, code natif ; pcall ne rattrape pas) : le Masque du chagrin y est retiré
-- puis reposé toutes les 1 à 2 s, et on réécrivait chaque fois dans ses composants (maillages,
-- ramassage), peut-être déjà détruits. Objet du jeu disparu : on ne touche plus qu'à NOTRE objet.
function shop_ui.world.remove(key, rec, gone)
    if not gone then shop_ui.world.restore_pickup(rec) end
    if rec.go then
        pcall(function()
            shop_ui.world.created[rec.go:get_address()] = nil
            sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)"):call(nil, rec.go)
        end)
        if not gone then
            for _, host in ipairs(rec.hosts or {}) do shop_ui.world.show_host(host) end
        end
        shop_ui.world.swapped[key] = nil
        if (shop_ui.world.restore_logged or 0) < 20 then
            shop_ui.world.restore_logged = (shop_ui.world.restore_logged or 0) + 1
            debug_log("objet au sol : objet AP retiré, objet d'origine réaffiché (" .. rec.loc.name .. ")")
        end
    else
        for i, m in ipairs(gone and {} or rec.meshes) do
            local o = rec.originals[i]
            pcall(function()
                m:call("setMesh", o.mesh)
                m:call("set_Material", o.mdf)
                m:call("get_GameObject"):call("get_Transform"):call("set_LocalScale", o.scale)
                for pi, enabled in pairs(o.parts or {}) do m:call("setPartsEnable", pi, enabled) end
                for _, js in ipairs(o.joints or {}) do js.joint:call("set_LocalScale", js.scale) end
            end)
        end
        shop_ui.world.swapped[key] = nil
        if (shop_ui.world.restore_logged or 0) < 20 then
            shop_ui.world.restore_logged = (shop_ui.world.restore_logged or 0) + 1
            debug_log("objet au sol : modèle d'origine remis (" .. rec.loc.name .. " n'utilise plus cet objet)")
        end
    end
end

function shop_ui.world.restore_unused()
    for key, rec in pairs(shop_ui.world.kept) do
        local still, why = shop_ui.world.still_used(rec, key)
        if not still then
            if why ~= shop_ui.world.GONE then shop_ui.world.restore_pickup(rec) end
            shop_ui.world.kept[key] = nil
        end
    end
    for key, rec in pairs(shop_ui.world.swapped) do
        if rec.originals or rec.go then
            -- Check fait : habillé tant que l'objet n'est pas ramassé (sauvegarde rechargée).
            local still, why = shop_ui.world.still_used(rec, key)
            if why and (shop_ui.world.why_logged or 0) < 40 then
                shop_ui.world.why_logged = (shop_ui.world.why_logged or 0) + 1
                debug_log("objet au sol : " .. rec.loc.name .. " : " .. (still and "gardé malgré " or "retiré : ") .. why)
            end
            if not still then shop_ui.world.remove(key, rec, why == shop_ui.world.GONE) end
        end
    end
end

-- Échelle uniforme (2026-09-27 : modèle Archipelago "compressé en largeur" au sol). Certains
-- objets d'origine ont une échelle différente selon l'axe, héritée par le modèle posé à leur
-- place : on remet le même facteur sur les 3 axes (le plus grand, dans le repère du monde).
function shop_ui.world.world_scale(tf)
    local ok, v = pcall(function()
        local m = tf:call("get_WorldMatrix")
        local a, b, c = m[0], m[1], m[2]
        return { x = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z), y = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z),
            z = math.sqrt(c.x * c.x + c.y * c.y + c.z * c.z) }
    end)
    return ok and v or nil
end

function shop_ui.world.uniform_scale(mesh, originals)
    local tf = mesh:call("get_GameObject"):call("get_Transform")
    -- Logo "en œufs" dans un tiroir (2026-09-27) : les boules du FBX sont bien rondes, mais le
    -- modèle suit l'os "_00" de l'objet hôte, qui peut être étiré sur un axe (boîte de
    -- munitions). Les os de l'objet sont donc aussi remis à une échelle uniforme.
    pcall(function()
        local joints = tf:call("get_Joints")
        local report = {}
        for i = 0, joints:get_size() - 1 do
            local j = joints:get_element(i)
            local js = j:call("get_LocalScale")
            local jk = math.max(math.abs(js.x), math.abs(js.y), math.abs(js.z))
            report[#report + 1] = string.format("%s %.3f %.3f %.3f", tostring(j:call("get_Name")), js.x, js.y, js.z)
            if jk > 0 and (math.abs(js.x - jk) > 1e-4 or math.abs(js.y - jk) > 1e-4 or math.abs(js.z - jk) > 1e-4) then
                if originals then originals[#originals + 1] = { joint = j, scale = js } end
                j:call("set_LocalScale", Vector3f.new(jk, jk, jk))
            end
        end
        if (shop_ui.world.joint_logged or 0) < 15 then
            shop_ui.world.joint_logged = (shop_ui.world.joint_logged or 0) + 1
            debug_log("objet au sol : os de " .. tostring(mesh:call("get_GameObject"):call("get_Name")) .. " : " .. table.concat(report, " ; "))
        end
    end)
    local ls = tf:call("get_LocalScale")
    -- get_Scale n'existe pas ici (erreur silencieuse, 2026-09-27) : échelle réelle dans le monde
    -- lue dans la matrice (longueur de chaque axe).
    local ws = shop_ui.world.world_scale(tf) or ls
    local k = math.max(math.abs(ws.x), math.abs(ws.y), math.abs(ws.z))
    if k <= 0 or (math.abs(ws.x - k) < 1e-4 and math.abs(ws.y - k) < 1e-4 and math.abs(ws.z - k) < 1e-4) then return end
    local fx = ws.x ~= 0 and ls.x * k / math.abs(ws.x) or ls.x
    local fy = ws.y ~= 0 and ls.y * k / math.abs(ws.y) or ls.y
    local fz = ws.z ~= 0 and ls.z * k / math.abs(ws.z) or ls.z
    tf:call("set_LocalScale", Vector3f.new(fx, fy, fz))
    if (shop_ui.world.scale_logged or 0) < 10 then
        shop_ui.world.scale_logged = (shop_ui.world.scale_logged or 0) + 1
        debug_log(string.format("objet au sol : échelle %.3f %.3f %.3f rendue uniforme (%.3f)", ws.x, ws.y, ws.z, k))
    end
end

-- Modèle à montrer pour une location, et son nom (nil = laisser l'objet d'origine).
function shop_ui.world.model_for(loc, specs)
    local lid = get_location_id(loc)
    local s = lid and scouted_items[lid]
    if not s then return nil, nil end
    local label = "[AP] " .. s.label
    -- Check déjà fait mais objet encore là (sauvegarde rechargée, demande du joueur 2026-09-27) :
    -- toujours habillé ; le ramasser ne donne rien (objet d'origine retiré, pas de renvoi).
    if location_done(loc) then label = label .. tr(" (déjà obtenu)", " (already obtained)") end
    -- Arme posée (2026-10-08, M1897 #001 sur sa table : rien à ramasser) : habillée comme les
    -- autres (demande du joueur), mais son ramassage n'est jamais touché (shop_ui.world.swap_pickup) :
    -- la vraie arme se ramasse normalement, le check part, l'arme est retirée ensuite (is_weapon).
    if not s.mine then return shop_ui.AP_MODEL, label end
    local def = item_by_name[s.name]
    local gid = def and def.game_item_id
    local original = item_by_name[loc.original_item or ""]
    -- Même objet qu'à l'origine : modèle gardé ("keep"), mais nom "[AP]" quand même (demande du
    -- joueur, 2026-09-27 : munitions d'un pot sans "[AP]", on ne savait pas si c'était un check).
    if gid and original and gid == original.game_item_id then return "keep", label end
    -- Pièce d'arme : modèle de l'ID réellement donné (LEMI (2) sans maillage, LEMI (1) oui, 2026-09-29).
    if def and def.type == "Upgrade" then
        return shop_ui.part_model(specs, def.give_id or gid) or shop_ui.PARTS_CASE_MODEL, label
    end
    local model = gid and shop_ui.real_model(specs, gid)
    if not model and (shop_ui.world.nomodel_logged or 0) < 30 then
        shop_ui.world.nomodel_logged = (shop_ui.world.nomodel_logged or 0) + 1
        debug_log(string.format("objet au sol : pas de vrai modèle pour %q (objet %s, trouvé : %s)",
            tostring(s.name), tostring(gid), tostring(def ~= nil)))
    end
    return model or shop_ui.AP_MODEL, label
end

-- Objets « ArchipelagoModel » orphelins (2026-09-30 : balles de fusil de l'ancienne seed restées
-- à côté du Compensateur, même après Reset scripts) : tout objet de ce nom que le mod ne suit plus
-- est détruit. Au démarrage (tous orphelins), puis toutes les 30 s.
-- Optimisation (2026-10-07, micro-gels signalés par le joueur) : parcourir TOUS les maillages de
-- la scène (des milliers) toutes les 30 s gelait le jeu un instant. Parcours complet une seule
-- fois (orphelins d'un chargement précédent du script), ensuite seulement les objets créés par
-- ce chargement (shop_ui.world.created, rempli par spawn_own).
shop_ui.world.next_sweep = 0
shop_ui.world.created = {}
-- Plus grande dimension de la boîte d'un maillage (get_WorldAABB) ; nil si absurde (boîte pas
-- encore calculée : ±3,4e38 vu le 2026-10-07).
function shop_ui.world.mesh_size(m)
    local size = nil
    pcall(function()
        local box = m:call("get_WorldAABB")
        local lo, hi = box:get_field("minpos"), box:get_field("maxpos")
        size = math.max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
    end)
    if size and size > 0.001 and size < 20 then return size end
    return nil
end

function shop_ui.world.skip_reason(e, why)
    shop_ui.world.skip_logged = shop_ui.world.skip_logged or {}
    if shop_ui.world.skip_logged[e.loc.name] ~= why then
        shop_ui.world.skip_logged[e.loc.name] = why
        debug_log("objet au sol : " .. e.loc.name .. " pas habillé : " .. why)
    end
end
function shop_ui.world.sweep_orphans()
    local live = {}
    for _, rec in pairs(shop_ui.world.swapped) do
        if rec.go then pcall(function() live[rec.go:get_address()] = true end) end
    end
    local destroy = sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)")
    local destroyed = 0
    -- 2026-10-07 (plantage du jeu après un changement de zone) : détruire un objet du registre
    -- pouvait viser un objet DÉJÀ détruit par le jeu avec sa salle. Retour à la méthode sûre
    -- (parcours de la scène : objets vivants seulement), mais toutes les 2 minutes ; le registre
    -- sert seulement à oublier les objets suivis.
    if true then
        shop_ui.world.full_sweep_done = true
        for addr in pairs(shop_ui.world.created) do
            if not live[addr] then shop_ui.world.created[addr] = nil end
        end
        for _, mesh in ipairs(find_all_components("via.render.Mesh")) do
            pcall(function()
                local go = mesh:call("get_GameObject")
                if go and go:call("get_Name") == "ArchipelagoModel" and not live[go:get_address()] then
                    destroy:call(nil, go)
                    destroyed = destroyed + 1
                end
            end)
        end
    else
        for addr, go in pairs(shop_ui.world.created) do
            if not live[addr] then
                shop_ui.world.created[addr] = nil
                pcall(function() destroy:call(nil, go) end)
                destroyed = destroyed + 1
            end
        end
    end
    if destroyed > 0 then debug_log("objet au sol : " .. destroyed .. " objet(s) Archipelago orphelin(s) détruit(s)") end
end

-- Mallette à pièce d'arme (2026-10-01, demande du joueur : JAMAIS de présentation pour un objet AP
-- non-clé). À l'ouverture, le jeu pose la vraie pièce (LEMI (1), nouvelle -> présentation plein
-- écran) dans un objet à ramasser qui n'est pas celui de l'emplacement. Près d'une mallette AP pas
-- encore faite (4 m), on cherche toutes les 0,1 s l'objet à ramasser posé à moins de 1,5 m qui porte
-- la pièce d'origine (ou une variante) et on le modifie sur place AVANT le ramassage.
shop_ui.world.case_gets = {} -- adresse de l'objet à ramasser -> location

-- Présentation « découverte d'un nouvel objet » au ramassage (2026-10-01 : Crochet, pièce d'arme de
-- la mallette) : le jeu demande InventoryManager.hasHistory(objet) ; l'objet demandé est celui
-- d'ORIGINE, pas celui qu'on donne. Près d'un emplacement AP (2,5 m), on répond « déjà eu », sauf
-- pour un de mes objets clés posé là (présentation voulue).
shop_ui.world.near_ap_until = 0
shop_ui.world.near_keys = {}
function shop_ui.world.install_history_hook()
    local m = sdk.find_type_definition("app.InventoryManager"):get_method("hasHistory")
    if not m then return end
    local ids = {}
    sdk.hook(m, function(args)
        ids[#ids + 1] = sdk.to_int64(args[3]) & 0xFFFFFFFF
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local id = table.remove(ids)
        -- Seulement les objets de l'emplacement AP proche (2026-10-08, bug du couteau de départ : le
        -- jeu demande aussi hasHistory pour décider si un objet unique doit encore apparaître ; près de
        -- la boîte « Remède de premiers soins #004 [S00] », le couteau était déclaré déjà eu et
        -- disparaissait, porte bloquée).
        if id and os.clock() < shop_ui.world.near_ap_until and not shop_ui.world.near_keys[id]
                and (shop_ui.world.near_ids or {})[id] then
            if (shop_ui.world.hist_logged or 0) < 30 and (sdk.to_int64(retval) & 1) == 0 then
                shop_ui.world.hist_logged = (shop_ui.world.hist_logged or 0) + 1
                shop_ui.world.detail_note = "présentation : hasHistory(" .. tostring(id) .. ") forcé à vrai (emplacement AP proche)"
            end
            return sdk.to_ptr(1)
        end
        return retval
    end)
end
pcall(shop_ui.world.install_history_hook)

-- Position d'un objet, sans le reste de l'identité (nom, dossier, parent) : pour les boucles
-- fréquentes (2026-10-07, optimisation). Gardée dans l'entrée (e.pos) jusqu'au relevé suivant :
-- les emplacements ne bougent pas.
function shop_ui.world.pos_of(go)
    local p = go and go:call("get_Transform"):call("get_Position")
    return p and { p.x, p.y, p.z }
end
function shop_ui.world.entry_pos(e)
    if not e.pos then e.pos = shop_ui.world.pos_of((e.get or e.si):call("get_GameObject")) end
    return e.pos
end

function shop_ui.world.near_ap_watch()
    local cam = nil
    pcall(function() cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if not cam then return end
    local keys, near, key_def, allowed = {}, false, nil, { [shop_ui.world.PICKUP_ID] = true }
    local best_loc, best_d = nil, 6.25
    for _, e in ipairs(shop_ui.world.entries or {}) do
        pcall(function()
            -- drop de boss : position de l'objet tombé, pas celle de l'emplacement (2026-10-07)
            local ep = shop_ui.world.entry_pos(e)
            local d = ep and (ep[1] - cam.x) ^ 2 + (ep[2] - cam.y) ^ 2 + (ep[3] - cam.z) ^ 2
            if d and d < best_d and location_done(e.loc) == false then best_loc, best_d = e.loc, d end
            if ep and d < 6.25 then
                near = true
                -- objets concernés par cet emplacement (seuls ceux-là peuvent être déclarés « déjà eus »)
                local orig = item_by_name[e.loc.original_item or ""]
                -- jamais pour un objet unique (arme, objet clé) : le jeu s'en sert pour décider s'il
                -- doit encore apparaître (couteau de départ disparu, 2026-10-08)
                if orig and orig.type ~= "Weapon" and orig.type ~= "Key" then
                    if orig.game_item_id then allowed[orig.game_item_id] = true end
                    for _, vid in ipairs(orig.variant_ids or {}) do allowed[vid] = true end
                end
                local k = shop_ui.world.own_key(e.loc)
                if k then keys[k.game_item_id] = true key_def = key_def or k end
            end
        end)
    end
    shop_ui.world.near_keys = keys
    shop_ui.world.near_ids = allowed
    -- emplacement AP pas encore fait le plus proche (< 2,5 m) : nom de la présentation (2026-10-07)
    if best_loc then shop_ui.world.near_ap_loc, shop_ui.world.near_ap_loc_until = best_loc, os.clock() + 6 end
    if key_def then shop_ui.world.near_key_def, shop_ui.world.near_key_until = key_def, os.clock() + 3 end
    if near then shop_ui.world.near_ap_until = os.clock() + 0.5 end
end
shop_ui.world.next_case = 0
function shop_ui.world.case_watch()
    if os.clock() < shop_ui.world.next_case then return end
    shop_ui.world.next_case = os.clock() + 0.1
    pcall(shop_ui.world.near_ap_watch)
    pcall(shop_ui.world.poll_key_pickups)
    local cam = nil
    pcall(function() cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if not cam then return end
    local cases = {}
    for _, e in ipairs(shop_ui.world.entries or {}) do
        local orig = item_by_name[e.loc.original_item or ""]
        -- Faite ou non (déjà faite : le vrai objet serait retiré de toute façon, pas de présentation).
        if orig and orig.type == "Upgrade" and location_done(e.loc) ~= nil then
            local ep = shop_ui.world.entry_pos(e)
            if ep and (ep[1] - cam.x) ^ 2 + (ep[2] - cam.y) ^ 2 + (ep[3] - cam.z) ^ 2 < 16 then
                cases[#cases + 1] = { e = e, pos = ep, orig = orig }
            end
        end
    end
    if #cases == 0 then return end
    for _, get in ipairs(find_all_components("app.InteractItemGet")) do
        pcall(function()
            local core = get:get_field("ItemCore")
            local id = core and get_item_id_from_core(core)
            if not id or id == shop_ui.world.PICKUP_ID then return end
            local gp = get_gameobject_identity(get:call("get_GameObject")).item_position
            if not gp then return end
            for _, c in ipairs(cases) do
                local oid = c.orig.game_item_id
                local same = id == oid or id == c.orig.give_id or shop_ui.world.same_variant(oid, id)
                local d2 = (c.pos[1] - gp[1]) ^ 2 + (c.pos[2] - gp[2]) ^ 2 + (c.pos[3] - gp[3]) ^ 2
                if same and d2 < 2.25 then
                    local key_def = shop_ui.world.own_key(c.e.loc)
                    local gid = key_def and key_def.game_item_id or shop_ui.world.PICKUP_ID
                    local ok, err = pcall(shop_ui.world.modify_inplace, core, gid, 1)
                    shop_ui.world.case_gets[get:get_address()] = c.e.loc
                    debug_log(string.format("mallette : %s : pièce posée par le jeu (%s) modifiée sur place -> %s (%s)",
                        c.e.loc.name, tostring(id), tostring(gid), ok and "ok" or tostring(err)))
                    -- Présentation (2026-10-03) : la pièce posée par le jeu a son propre GetMode
                    -- (2506306378, AnotherSE : Poudre noire AP présentée en plein écran). L'écrire à
                    -- Normal BLOQUE le jeu au ramassage (en jeu=false sans fin : la mallette attend
                    -- une présentation). Essai : Once (présenté seulement si l'objet est nouveau ;
                    -- la pièce devient l'objet de ramassage, déjà possédé). Objet clé à moi : gardé.
                    if shop_ui.world.WRITE_CASE_GET_MODE and not key_def then
                        local mode = shop_ui.world.GET_MODE.once
                        local old = get:get_field("GetMode")
                        get:set_field("GetMode", mode)
                        debug_log(string.format("présentation : mallette %s : GetMode %s -> %s",
                            c.e.loc.name, tostring(old), tostring(mode)))
                    end
                    return
                end
            end
        end)
    end
end

-- Modèle invisible (2026-10-04 : Hræsvelg d'acier sur Poudre noire #008, DIAG : get_MaterialNum=0,
-- 0 texture). Le matériau (create_resource) se charge en différé : posé avant la fin du chargement
-- d'un modèle que la scène n'utilisait pas encore, il restait vide. Réappliqué 4 fois par seconde
-- jusqu'à ce que le maillage ait ses matériaux.
function shop_ui.world.retry_material(rec)
    if (rec.mesh:call("get_MaterialNum") or 0) > 0 then
        rec.mat_ok = true
        if rec.mat_retries and rec.mat_retries > 0 then
            debug_log(string.format("objet au sol : %s : matériau chargé après %d essai(s)", rec.loc.name, rec.mat_retries))
        end
        return
    end
    if os.clock() < (rec.mat_next or 0) then return end
    rec.mat_next = os.clock() + 0.25
    rec.mat_retries = (rec.mat_retries or 0) + 1
    -- 2026-10-04 : certains trésors (TreasureD, TreasureN, TreasureP) ne chargent JAMAIS leur
    -- matériau, même après 30 s : au bout de 5 s, logo Archipelago à la place (objet visible).
    if rec.mat_retries > 20 then
        local failed = type(rec.model) == "table" and tostring(rec.model.mdf) or tostring(rec.model)
        -- 2026-10-07 : recréé, l'objet charge en général son matériau (Hræsvelg d'acier, Animal en
        -- bois : vrai modèle affiché après le logo). 1er échec : objet recréé avec le vrai modèle ;
        -- logo seulement au 2e échec pour ce check.
        shop_ui.world.mat_fail = shop_ui.world.mat_fail or {}
        if rec.model ~= shop_ui.AP_MODEL and not shop_ui.world.mat_fail[rec.loc.key] then
            shop_ui.world.mat_fail[rec.loc.key] = true
            debug_log(string.format("objet au sol : %s : matériau pas chargé en 5 s (%s), objet recréé", rec.loc.name, failed))
            for key, other in pairs(shop_ui.world.swapped) do
                if other == rec then pcall(shop_ui.world.remove, key, rec) end
            end
            rec.mat_ok = true
            return
        end
        if rec.model ~= shop_ui.AP_MODEL then
            debug_log(string.format("objet au sol : %s : matériau jamais chargé (%s), logo Archipelago à la place",
                rec.loc.name, failed))
            rec.model, rec.holder, rec.mat_retries = shop_ui.AP_MODEL, shop_ui.model_holders(shop_ui.AP_MODEL), 0
            -- Taille et recalage remesurés pour le nouveau modèle (place_by_box).
            rec.is_ap, rec.natural, rec.natural_h, rec.fix, rec.k = true, nil, nil, nil, nil
        else
            rec.mat_ok = true
            debug_log(string.format("objet au sol : %s : matériau du logo Archipelago jamais chargé", rec.loc.name))
        end
        return
    end
    rec.mesh:call("setMesh", rec.holder.mesh)
    rec.mesh:call("set_Material", rec.holder.mdf)
    shop_ui.apply_parts(rec.mesh, rec.model)
end

-- Viandes au sol (checks de chasse, option 2, 2026-10-07) : chacune reçoit le prochain check de
-- sa viande pas encore fait (#1, #2...) ; une viande garde son check d'un relevé à l'autre
-- (hunt_assign, par adresse de l'emplacement), deux viandes n'ont jamais le même. Au-delà : viande
-- normale, pas habillée.
shop_ui.world.hunt_assign = {}
function shop_ui.world.assign_hunts(drops, entries)
    local used, keep = {}, {}
    local function_done = shop_ui.location_done
    for _, d in ipairs(drops) do
        local prior = shop_ui.world.hunt_assign[d.si:get_address()]
        if prior and function_done(prior) == false and not used[prior.key] then
            used[prior.key] = true
            d.loc = prior
        end
    end
    for _, d in ipairs(drops) do
        if not d.loc then
            for _, candidate in ipairs(locations.hunts[d.id] or {}) do
                if get_location_id(candidate) and function_done(candidate) == false and not used[candidate.key] then
                    used[candidate.key] = true
                    d.loc = candidate
                    break
                end
            end
        end
        if d.loc then
            keep[d.si:get_address()] = d.loc
            entries[#entries + 1] = { si = d.si, loc = d.loc, hunt_drop = true }
            if d.get then shop_ui.world.case_gets[d.get:get_address()] = d.loc end
            if (shop_ui.world.hunt_logged or 0) < 30 and shop_ui.world.hunt_assign[d.si:get_address()] ~= d.loc then
                shop_ui.world.hunt_logged = (shop_ui.world.hunt_logged or 0) + 1
                debug_log("chasse : viande au sol " .. tostring(d.id) .. " -> " .. d.loc.name)
            end
        end
    end
    shop_ui.world.hunt_assign = keep
end

function shop_ui.world.update()
    pcall(shop_ui.world.case_watch) -- aussi pendant l'ouverture de la mallette (peut être une présentation)
    if is_in_game() and os.clock() >= shop_ui.world.next_sweep then
        shop_ui.world.next_sweep = os.clock() + 120
        pcall(shop_ui.world.sweep_orphans)
    end
    -- Objet ramassé (2026-09-30 : l'objet AP restait ~2 s, jusqu'au nettoyage) : caché tout de
    -- suite, à chaque image ; le nettoyage normal le détruit ensuite.
    for _, rec in pairs(shop_ui.world.swapped) do
        if rec.mesh and not rec.picked_hidden and (save_sync.picked_locs or {})[rec.loc.key] then
            rec.picked_hidden = true
            pcall(function() rec.mesh:call("set_DrawDefault", false) end)
        end
        if rec.holder and not rec.mat_ok then pcall(shop_ui.world.retry_material, rec) end
    end
    if not is_in_game() or os.clock() < shop_ui.world.next_update then return end
    shop_ui.world.next_update = os.clock() + 0.5
    if os.clock() >= shop_ui.world.next_scan then
        shop_ui.world.next_scan = os.clock() + 8
        local scan_t0 = os.clock()
        local entries = {}
        -- Objets lâchés par les ennemis (2026-10-07 : Buste de Bela jamais repéré) : rangés dans
        -- ItemSpawnInfoHolder.ItemSpawnInfoEnemyDropUseList, absents de findComponents ; ajoutés.
        local spawn_infos = find_all_components("app.Spawn.ItemSpawnInfo")
        local hunt_drops = {}
        local dropped = {}
        pcall(function()
            local seen = {}
            -- 2e essai : les drops d'ennemis sont des app.Spawn.ItemSpawnInfoEnemyDrop (type à part,
        -- pas un ItemSpawnInfo : DropItemID, pas de SpawnedInteractItemGetCache ni get_spawnItemId).
        for _, si in ipairs(find_all_components("app.Spawn.ItemSpawnInfoEnemyDrop")) do
            pcall(function()
                local id = si:get_field("DropItemID")
                local list = locations.boss_drops and locations.boss_drops[id]
                local inst = list and si:call("get_spawnInstance")
                if not inst then return end
                local pos = get_gameobject_identity(inst).item_position
                local best, best_d = nil, math.huge
                for _, candidate in ipairs(pos and list or {}) do
                    local cp = candidate.drop_position
                    if cp then
                        local d = (cp[1] - pos[1]) ^ 2 + (cp[2] - pos[2]) ^ 2 + (cp[3] - pos[3]) ^ 2
                        if d < best_d and d < (candidate.drop_radius or 20) ^ 2 then best, best_d = candidate, d end
                    end
                end
                if best and location_done(best) ~= false then best = nil end
                if (shop_ui.world.drop_logged or 0) < 20 then
                    shop_ui.world.drop_logged = (shop_ui.world.drop_logged or 0) + 1
                    debug_log(string.format("drop de boss au sol (EnemyDrop) : objet %s à %s -> %s (%.1f m)", tostring(id),
                        pos and table.concat(pos, " ") or "?", best and best.name or "aucun check proche", math.sqrt(best_d)))
                end
                if best then
                    local get = inst:call("getComponent(System.Type)", sdk.typeof("app.InteractItemGet"))
                    entries[#entries + 1] = { si = si, loc = best, boss_drop = true, get = get }
                    if get then shop_ui.world.case_gets[get:get_address()] = best end
                end
            end)
        end
        for _, si in ipairs(spawn_infos) do seen[si:get_address()] = true end
            local list = sdk.get_managed_singleton("app.ItemSpawnInfoHolder"):get_field("ItemSpawnInfoEnemyDropUseList")
            for i = 0, list:call("get_Count") - 1 do
                local si = list:call("get_Item", i)
                if si and not seen[si:get_address()] then
                    spawn_infos[#spawn_infos + 1] = si
                    dropped[si:get_address()] = true
                end
            end
        end)
        -- Optimisation (2026-10-07, micro-gel toutes les 8 s) : GUID gardé par objet (texte
        -- recalculé pour des centaines d'emplacements à chaque relevé) ; cache vidé toutes les
        -- 60 s et au changement de chapitre (adresse réutilisée par un autre objet).
        -- vidé aussi quand le nombre d'emplacements chargés change (chargement de zone : adresses
        -- réutilisées, 2026-10-07)
        if os.clock() >= (shop_ui.world.guid_cache_until or 0) or shop_ui.world.guid_cache_chapter ~= last_chapter
                or shop_ui.world.guid_cache_count ~= #spawn_infos then
            shop_ui.world.guid_cache, shop_ui.world.guid_cache_until = {}, os.clock() + 60
            shop_ui.world.guid_cache_chapter, shop_ui.world.guid_cache_count = last_chapter, #spawn_infos
        end
        local guid_cache = shop_ui.world.guid_cache
        for _, si in ipairs(spawn_infos) do
            pcall(function()
                local addr = si:get_address()
                local guid = guid_cache[addr]
                if not guid then
                    guid = tostring(si:call("get_myGUID"):call("ToString()"))
                    guid_cache[addr] = guid
                end
                local loc = location_by_guid[guid]
                -- Emplacement d'un AUTRE chapitre (2026-10-07 : début du Village, Chapter2_1, les
                -- emplacements du 2e passage, Chapter2_6, sont chargés aussi ; habillés, ils ont
                -- fait disparaître le couteau de départ planté dans le meuble) : jamais touché.
                if loc and shop_ui.other_chapter(loc) then loc = false end
                if loc and location_done(loc) ~= nil then
                    entries[#entries + 1] = { si = si, loc = loc }
                -- drops de boss et viandes : seulement parmi les objets lâchés (liste des drops) ;
                -- avant, chaque emplacement ordinaire était ouvert (composant + objet) à chaque relevé
                elseif not loc and locations.boss_drops and dropped[addr] then
                    -- Drop de boss au sol (2026-10-07 : Buste cristallisé de Bela affiché tel quel) :
                    -- objet lâché par le boss, sans placement connu. Check pas encore fait le plus
                    -- proche de sa position de référence (< 20 m, comme au ramassage) -> habillé.
                    local inst = si:call("get_spawnInstance")
                    local get = inst and inst:call("getComponent(System.Type)", sdk.typeof("app.InteractItemGet"))
                    local core = get and get:get_field("ItemCore")
                    local id = core and get_item_id_from_core(core)
                    -- 2026-10-07 : Buste de Bela dans ItemSpawnInfoEnemyDropUseList mais ItemID
                    -- illisible par l'objet : numéro de l'emplacement (get_spawnItemId) en secours.
                    if not (id and (locations.boss_drops[id] or (locations.hunts or {})[id])) then
                        pcall(function() id = si:call("get_spawnItemId") end)
                    end
                    -- Viande d'animal au sol (chasse) : rattachée après la boucle (numéros #1, #2...).
                    if id and (locations.hunts or {})[id] then
                        hunt_drops[#hunt_drops + 1] = { si = si, id = id, get = get }
                        return
                    end
                    local list = id and locations.boss_drops[id]
                    if not list then return end
                    local pos = (inst and get_gameobject_identity(inst).item_position) or get_spawn_info_identity(si).item_position
                    local best, best_d = nil, math.huge
                    for _, candidate in ipairs(pos and list or {}) do
                        local cp = candidate.drop_position
                        -- le plus proche TOUT COURT (2026-10-07 : Buste de la 3e sœur à 11,9 m de celui
                        -- de Bela ; Bela retuée après son check aurait été prise pour la 3e) ; déjà
                        -- fait -> pas habillé.
                        if cp then
                            local d = (cp[1] - pos[1]) ^ 2 + (cp[2] - pos[2]) ^ 2 + (cp[3] - pos[3]) ^ 2
                            if d < best_d and d < (candidate.drop_radius or 20) ^ 2 then best, best_d = candidate, d end
                        end
                    end
                    local nearest = best
                    if best and location_done(best) ~= false then best = nil end
                    if (shop_ui.world.drop_logged or 0) < 20 then
                        shop_ui.world.drop_logged = (shop_ui.world.drop_logged or 0) + 1
                        local dists = {}
                        for _, c in ipairs(list) do
                            local cp = c.drop_position
                            dists[#dists + 1] = string.format("%s=%s/%s", c.name,
                                cp and pos and string.format("%.1f m", math.sqrt((cp[1] - pos[1]) ^ 2 + (cp[2] - pos[2]) ^ 2 + (cp[3] - pos[3]) ^ 2)) or "?",
                                tostring(location_done(c)))
                        end
                        debug_log(string.format("drop de boss au sol : objet %s à %s -> %s ; %s", tostring(id),
                            pos and table.concat(pos, " ") or "?", best and best.name or ((nearest and nearest.name .. " déjà fait") or "aucun check proche"), table.concat(dists, ", ")))
                    end
                    if best then
                        entries[#entries + 1] = { si = si, loc = best, boss_drop = true, get = get }
                        -- l'objet peut être modifié sur place (autre ItemID) : le ramassage le
                        -- retrouve par son InteractItemGet, comme les mallettes (case_gets)
                        shop_ui.world.case_gets[get:get_address()] = best
                    end
                end
            end)
        end
        pcall(shop_ui.world.assign_hunts, hunt_drops, entries)
        if #entries ~= #shop_ui.world.entries and (shop_ui.world.count_logged or 0) < 40 then
            shop_ui.world.count_logged = (shop_ui.world.count_logged or 0) + 1
            debug_log(string.format("objet au sol : %d placements de checks chargés (avant : %d)", #entries, #shop_ui.world.entries))
        end
        shop_ui.world.entries = entries
        -- durée du relevé (2026-10-07, micro-gels) : notée les 30 premières fois et si > 10 ms
        local ms = (os.clock() - scan_t0) * 1000
        shop_ui.world.scan_logged = (shop_ui.world.scan_logged or 0) + 1
        if shop_ui.world.scan_logged <= 30 or ms > 10 then
            debug_log(string.format("perf : relevé des emplacements %.1f ms (%d emplacements, %d checks)", ms, #spawn_infos, #entries))
        end
    end
    pcall(shop_ui.world.restore_unused)
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    local near = {}
    for _, e in ipairs(shop_ui.world.entries) do
        local ok, err = pcall(function()
            -- raison notée une fois par emplacement (2026-10-08 : M1897 #001 détecté, jamais habillé)
            local skip = shop_ui.world.skip_reason
            if location_done(e.loc) == nil then return skip(e, "pas dans la seed") end
            if (save_sync.picked_locs or {})[e.loc.key] then return skip(e, "déjà ramassé (sauvegarde)") end
            if shop_ui.no_touch[e.loc.name] then return skip(e, "emplacement scénarisé") end
            local inst = e.si:call("get_spawnInstance")
            if not inst then return skip(e, "objet pas posé par le jeu (get_spawnInstance nil)") end
            local model, label = shop_ui.world.model_for(e.loc, specs)
            if not model then return skip(e, "pas de modèle") end
            e.inst, e.label = inst, label
            if not e.orig_id then
                local original = item_by_name[e.loc.original_item or ""]
                e.orig_id = original and original.game_item_id or -1
            end
            near[#near + 1] = e
            local key = inst:get_address()
            if model == "keep" then
                -- Objet posé par nous avant (autre seed) : retiré, le modèle d'origine revient.
                if shop_ui.world.swapped[key] then pcall(shop_ui.world.remove, key, shop_ui.world.swapped[key]) end
                -- Modèle gardé, mais ramassage en Lei quand même (mallette pleine, voir swap_pickup).
                local kept = shop_ui.world.kept[key]
                if not kept then
                    kept = { si = e.si, inst = inst, loc = e.loc }
                    shop_ui.world.kept[key] = kept
                    pcall(shop_ui.world.swap_pickup, e, kept)
                end
                kept.si = e.si
                pcall(shop_ui.world.sync_pickup, e, kept)
                e.pickup = kept.pickup
                return
            end
            local done = shop_ui.world.swapped[key]
            -- Changement de seed sans relancer le jeu (2026-09-30) : l'ancien objet (Cartouches de
            -- fusil) restait à côté du nouveau (Compensateur). Modèle ou nom différent : on retire.
            if done and done.label and (done.label ~= label or done.model_key ~= tostring(model)) then
                debug_log("objet au sol : " .. e.loc.name .. " : objet changé (" .. tostring(done.label) .. " -> " .. tostring(label) .. ")")
                pcall(shop_ui.world.remove, key, done)
                done = nil
            end
            if done then done.si = e.si end
            -- La ligne d'objet montre toujours l'objet posé à l'origine, pas celui du ramassage
            -- (2026-09-27 : plus aucun "[AP]" quand on cherchait l'objet de remplacement).
            if done then
                pcall(shop_ui.world.sync_pickup, e, done)
                pcall(shop_ui.world.apply_key_mode, done) -- mode appris après la pose
                e.pickup = done.pickup
            end
            local h = shop_ui.model_holders(model)
            if not done then
                -- Test du 2026-09-27 : le maillage de get_spawnInstance remplacé, la Plante des
                -- vignes restait visible. Le modèle visible peut être ailleurs : on prend aussi
                -- InteractItemGet.ItemSetGameObject et ItemSpawnInfo.MeshRotationGameObject.
                local roots, meshes, seen, report = { { "instance", inst } }, {}, {}, {}
                pcall(function()
                    local get = e.si:get_field("SpawnedInteractItemGetCache")
                    local target = get and get:get_field("ItemSetGameObject"):call("get_Target")
                    if target then roots[#roots + 1] = { "ItemSet", target } end
                end)
                pcall(function()
                    local target = e.si:get_field("MeshRotationGameObject"):call("get_Target")
                    if target then roots[#roots + 1] = { "MeshRotation", target } end
                end)
                for _, r in ipairs(roots) do
                    for _, m in ipairs(shop_ui.world.meshes(r[2])) do
                        local a = m:get_address()
                        local path = "?"
                        pcall(function() path = m:call("getMesh"):call("get_ResourcePath") end)
                        -- Coffre à pièce d'arme (CustomPartsCase) : le coffre reste, seule la
                        -- pièce à l'intérieur est remplacée (2026-09-27 : coffre caché, ferraille
                        -- géante à la place).
                        if path:find("PartsCase", 1, true) then seen[a] = true end
                        if not seen[a] then
                            seen[a] = true
                            meshes[#meshes + 1] = m
                            report[#report + 1] = r[1] .. ":" .. tostring(m:call("get_GameObject"):call("get_Name")) .. "=" .. tostring(path)
                        end
                    end
                end
                if #meshes == 0 then return end
                -- Méthode 2 (2026-09-27) : notre propre objet, avec son propre squelette, rattaché
                -- à l'objet d'origine (caché). Le modèle greffé sur le squelette de l'objet
                -- d'origine se déformait (logo "en œufs") ou restait invisible (Vivianite sur un
                -- flacon sans os "_00").
                -- Mon objet clé, objet d'origine modifié sur place (2026-10-03 : vin présenté sans
                -- modèle, la présentation montre l'objet d'origine, caché) : méthode 1, le modèle
                -- est posé sur l'objet d'origine lui-même (remis à l'objet ramassé ou retiré).
                -- DÉSACTIVÉ (2026-10-04, KEY_MESH_INPLACE) : crash du moteur (code natif) en approchant
                -- la Bague posée ainsi sur un Fluide chimique (4 fois, Cave à vin, dès la ligne d'objet).
                -- 2026-10-07 : aussi sur les emplacements d'objet clé d'origine (Sanguis Virginis #001,
                -- bain de sang : présentation scénarisée de l'objet d'origine -> sans modèle AP).
                -- Bague (modèle Jewelry) JAMAIS posée sur l'objet du jeu : crash du moteur à chaque fois
                -- (cave à vin 2026-10-04 x4 ; Poudre noire #003 [S00], porte cochère, 2026-10-08) ->
                -- objet à part.
                local model_path = type(model) == "table" and model.mesh or tostring(model)
                local key_here = shop_ui.world.KEY_MESH_INPLACE == true and shop_ui.world.INPLACE == true
                    and (shop_ui.world.own_key(e.loc) ~= nil or e.loc.key_item_location == true)
                    and not model_path:find("Jewelry", 1, true)
                local own = not key_here and shop_ui.world.spawn_own(meshes, h, model) or nil
                if own then
                    shop_ui.world.hide_icon(e.si, e.loc)
                    own.meshes, own.time, own.si, own.inst, own.loc, own.probe = { own.mesh }, os.clock(), e.si, inst, e.loc, true
                    own.label, own.model_key = label, tostring(model)
                    shop_ui.world.swapped[key] = own
                    pcall(shop_ui.world.follow_joint, shop_ui.world.swapped[key])
                    pcall(shop_ui.world.swap_pickup, e, shop_ui.world.swapped[key])
                    if shop_ui.world.logged < 300 then
                        shop_ui.world.logged = shop_ui.world.logged + 1
                        debug_log(string.format("objet au sol : %s -> %s, modèle %s (objet à part) ; maillages cachés : %s",
                            e.loc.name, label, type(model) == "table" and model.mesh or tostring(model), table.concat(report, ", ")))
                    end
                    return
                end
                -- Méthode 1 (secours) : modèle d'origine gardé, remis quand l'objet ne sert plus
                -- à ce check (voir shop_ui.world.restore_unused).
                local originals = {}
                for i, m in ipairs(meshes) do
                    local o = { mesh = m:call("getMesh"), mdf = m:call("get_Material"),
                        scale = m:call("get_GameObject"):call("get_Transform"):call("get_LocalScale"), parts = {} }
                    o.size = shop_ui.world.mesh_size(m) -- taille de l'objet d'origine (voir done.probe)
                    for pi = 0, 31 do
                        pcall(function() o.parts[pi] = m:call("getPartsEnable", pi) end)
                    end
                    pcall(function() o.mesh:add_ref() end)
                    pcall(function() o.mdf:add_ref() end)
                    originals[i] = o
                end
                for i, m in ipairs(meshes) do
                    m:call("setMesh", h.mesh)
                    m:call("set_Material", h.mdf)
                    originals[i].joints = {}
                    shop_ui.world.uniform_scale(m, originals[i].joints)
                    -- Boîte de munitions "placeholder" posée sur un Sac de Lei (2026-09-27) : le sac
                    -- n'affiche qu'une partie de son maillage (parts [false,false,true,...]) et
                    -- le nouveau maillage en héritait. Toutes les parties sont réactivées (sauf
                    -- pièce d'arme : seulement la sienne).
                    shop_ui.apply_parts(m, model)
                end
                shop_ui.world.hide_icon(e.si, e.loc)
                shop_ui.world.swapped[key] = { meshes = meshes, time = os.clock(), originals = originals,
                    si = e.si, inst = inst, loc = e.loc, label = label, model_key = tostring(model) }
                -- Taille et position (Valise invisible dans un tiroir, 2026-09-27) : noté une fois
                -- par objet 2 s plus tard, quand le maillage est chargé (voir plus bas).
                shop_ui.world.swapped[key].probe = true
                pcall(shop_ui.world.swap_pickup, e, shop_ui.world.swapped[key])
                if shop_ui.world.logged < 300 then
                    shop_ui.world.logged = shop_ui.world.logged + 1
                    debug_log(string.format("objet au sol : %s -> %s, modèle %s ; maillages : %s", e.loc.name, label,
                        type(model) == "table" and model.mesh or tostring(model), table.concat(report, ", ")))
                end
            elseif os.clock() - done.time < 6.0 then
                -- Matériau reposé pendant le chargement du maillage (damier vu dans la boutique).
                for _, m in ipairs(done.meshes) do m:call("set_Material", h.mdf) end
                if not done.pending_hide then
                    for _, host in ipairs(done.hosts or {}) do
                        if done.by_box then
                            shop_ui.world.hide_host(host)
                        else
                            pcall(function() host.mesh:call("set_DrawDefault", false) end)
                        end
                    end
                end
                -- Vivianite invisible jusqu'à ce qu'on s'éloigne puis revienne (2026-09-27) : le
                -- maillage n'était pas encore chargé quand il a été posé. On le repose à 1,5 s et
                -- à 4 s (avec ses parties), une fois chargé.
                local age = os.clock() - done.time
                done.remesh = done.remesh or 0
                if (done.remesh == 0 and age > 1.5) or (done.remesh == 1 and age > 4.0) then
                    done.remesh = done.remesh + 1
                    for _, m in ipairs(done.meshes) do
                        m:call("setMesh", h.mesh)
                        m:call("set_Material", h.mdf)
                        shop_ui.apply_parts(m, model)
                    end
                end
            elseif done.probe then
                done.probe = false
                -- Modèle AP posé sur l'objet du jeu bien plus grand que lui (2026-10-08 : Poisson sur
                -- l'emplacement de la Bague, ~3x trop grand dans la présentation, réglée pour une
                -- bague) : ramené à la taille de l'objet d'origine.
                pcall(function()
                    local orig = done.originals and done.originals[1] and done.originals[1].size
                    local now = shop_ui.world.mesh_size(done.meshes[1])
                    if orig and now and now > orig * 1.5 then
                        local f = orig / now
                        for i, m in ipairs(done.meshes) do
                            local sc = done.originals[i].scale
                            m:call("get_GameObject"):call("get_Transform"):call("set_LocalScale",
                                Vector3f.new(sc.x * f, sc.y * f, sc.z * f))
                        end
                        debug_log(string.format("objet au sol : %s : modèle AP %.2f m sur un objet de %.2f m -> réduit x%.2f",
                            e.loc.name, now, orig, f))
                    end
                end)
                local info = {}
                pcall(function()
                    local p = inst:call("get_Transform"):call("get_Position")
                    info[#info + 1] = string.format("position %.2f %.2f %.2f", p.x, p.y, p.z)
                end)
                for _, getter in ipairs({ "get_WorldAABB", "get_BoundingAABB", "get_AABB" }) do
                    pcall(function()
                        local box = done.meshes[1]:call(getter)
                        local lo, hi = box:get_field("minpos"), box:get_field("maxpos")
                        info[#info + 1] = string.format("%s %.2f %.2f %.2f -> %.2f %.2f %.2f", getter,
                            lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
                    end)
                end
                if (shop_ui.world.probe_logged or 0) < 40 then
                    shop_ui.world.probe_logged = (shop_ui.world.probe_logged or 0) + 1
                    debug_log("objet au sol : " .. e.loc.name .. " : " .. table.concat(info, " ; "))
                end
            else
                -- Tiroir du couloir du château (2026-09-27) : modèle d'origine revenu. Si le jeu
                -- a remis un autre maillage, on refait le remplacement.
                local current = nil
                pcall(function() current = done.meshes[1]:call("getMesh"):call("get_ResourcePath") end)
                local wanted = (type(model) == "table" and model.mesh or model) .. ".mesh"
                -- Boîte de munitions "placeholder" (2026-09-27) : matériau pas pris quand le
                -- maillage met plus de 2 s à charger -> matériau vérifié aussi, et reposé.
                local current_mdf = nil
                pcall(function() current_mdf = done.meshes[1]:call("get_Material"):call("get_ResourcePath") end)
                local wanted_mdf = (type(model) == "table" and model.mdf or model) .. ".mdf2"
                if current_mdf and current_mdf:lower() ~= wanted_mdf:lower() then
                    for _, m in ipairs(done.meshes) do m:call("set_Material", h.mdf) end
                    if (shop_ui.world.mdf_logged or 0) < 10 then
                        shop_ui.world.mdf_logged = (shop_ui.world.mdf_logged or 0) + 1
                        debug_log("objet au sol : " .. e.loc.name .. " : matériau " .. tostring(current_mdf) .. " remplacé à nouveau")
                    end
                end
                if current and current:lower() ~= wanted:lower() then
                    -- 2026-10-07 (Animal en bois) : l'ancien objet (logo de secours) restait affiché
                    -- à côté du nouveau jusqu'au balayage : il est maintenant détruit tout de suite.
                    if done.go then pcall(shop_ui.world.remove, key, done) end
                    shop_ui.world.swapped[key] = nil
                    if (shop_ui.world.reswap_logged or 0) < 5 then
                        shop_ui.world.reswap_logged = (shop_ui.world.reswap_logged or 0) + 1
                        debug_log("objet au sol : " .. e.loc.name .. " : le jeu a remis " .. current .. ", nouveau remplacement")
                    end
                end
            end
        end)
        if not ok and shop_ui.world.logged < 300 then
            shop_ui.world.logged = shop_ui.world.logged + 1
            debug_log("objet au sol : erreur " .. tostring(err))
        end
    end
    shop_ui.world.near = near
end

-- Mallette pleine (2026-09-27 : Fusil F2 #013 -> Plante, « sac trop petit pour l'arme » ; puis
-- pareil pour les munitions). Le jeu vérifie la place pour l'objet de InteractItemGet.ItemCore
-- AVANT le ramassage (le hook de ramassage n'est jamais appelé), donc un check est impossible à
-- prendre sac plein, quel que soit l'objet. Tout objet au sol devient donc 1 Fragment de
-- cristal (trésor : ne prend pas de case), retiré comme tout objet d'origine ; l'objet AP arrive
-- par le serveur. Remis d'origine avec le modèle (restore_pickup).
-- 1er essai en Lei (2026-09-27, 22h40) : le jeu montre alors l'argent reçu, et plus la ligne
-- d'objet (setItemID jamais appelé) : plus de "[AP]" sur aucun check.
shop_ui.world.PICKUP_ID = (item_by_name["Fragment de cristal"] or {}).game_item_id or 1943719610
-- Objet d'origine modifié sur place (son + présentation) : par défaut depuis le 2026-10-01 (sons
-- retrouvés, présentation du Crochet corrigée) ; case dans les outils pour revenir à l'ancienne méthode.
shop_ui.world.INPLACE = true
-- Modèle de MON objet clé posé sur l'objet d'origine lui-même (méthode 1, pour la présentation) :
-- coupé le 2026-10-04 à 00h50 (crashs du moteur), RÉACTIVÉ à 02h20 : le crash de 00h54 a eu lieu
-- sans lui ; causes probables corrigées depuis (écritures dans des objets du jeu détruits, voir
-- shop_ui.world.remove ; chaîne glissée à la place du texte de la présentation). Sans lui, la
-- présentation de mon objet clé montre l'objet d'origine (caché) : pas de modèle.
shop_ui.world.KEY_MESH_INPLACE = true
-- Objet clé à moi (2026-09-30, demande du joueur) : ramassé sous sa VRAIE forme, avec la
-- présentation et le son du jeu (pas de souci de place : onglet des objets clés). Pas les clés
-- progressives (le niveau dépend des exemplaires déjà reçus).
function shop_ui.world.own_key(loc)
    local lid = get_location_id(loc)
    local sc = lid and scouted_items[lid]
    local def = sc and sc.mine and item_by_name[sc.name]
    if def and def.type == "Key" and not def.levels and not checked_ids[lid] then return def end
    return nil
end

-- Présentation plein écran d'un objet clé (2026-09-30 : Bague ramassée sur l'emplacement d'une
-- Poudre noire, sans présentation) : elle dépend du mode de ramassage de l'EMPLACEMENT
-- (InteractItemGet.GetMode). Mode relevé sur les vrais emplacements d'objets clés, recopié quand
-- un de mes objets clés est ramassé ailleurs.
function shop_ui.world.learn_get_mode(e)
    local get = e.si:get_field("SpawnedInteractItemGetCache")
    if not get then return end
    local mode = get:get_field("GetMode")
    local key_spot = e.loc.key_item_location == true
    if (shop_ui.world.mode_logged or 0) < 40 then
        shop_ui.world.mode_logged = (shop_ui.world.mode_logged or 0) + 1
        -- Diagnostic (2026-10-06) : Sac de Lei = pas de présentation même en FixDisplayCenter.
        -- Hypothèse : pas de composant de présentation (DetailSearch) sur les sacs de Lei.
        local ds = {}
        for _, f in ipairs({ "DetailSearch", "DetailSearchRoot", "DetailSearchObject", "Interact" }) do
            local v = nil
            pcall(function() v = get:get_field(f) end)
            ds[#ds + 1] = f .. "=" .. (v == nil and "nil" or "oui")
        end
        debug_log(string.format("objet au sol : %s : GetMode=%s (emplacement d'objet clé : %s), IsDelayFinishDetailSearch=%s, %s",
            e.loc.name, tostring(mode), tostring(key_spot), tostring(get:get_field("IsDelayFinishDetailSearch")),
            table.concat(ds, " ")))
    end
    if key_spot and mode and not shop_ui.world.key_get_mode then
        shop_ui.world.key_get_mode = mode
        shop_ui.world.key_delay = get:get_field("IsDelayFinishDetailSearch")
        debug_log("objet au sol : mode de ramassage des objets clés = " .. tostring(mode))
    end
    -- Mode « normal » (2026-09-30 : Sac de Lei [AP] sur le Verre carmin #004, rangé avec les objets
    -- clés -> présentation d'objet clé pour un Sac de Lei).
    if not key_spot and mode and not shop_ui.world.normal_get_mode
            and not (e.loc.folder_path or ""):find("KeyItem", 1, true) then
        shop_ui.world.normal_get_mode = mode
        shop_ui.world.normal_delay = get:get_field("IsDelayFinishDetailSearch")
        debug_log("objet au sol : mode de ramassage normal = " .. tostring(mode))
    end
end

-- Présentation plein écran (2026-09-30) : GetMode ne suffit pas (Sac de Lei [AP] sur le Verre
-- carmin #004 toujours présenté). On répond nous-mêmes à InteractItemGet.IsGetItemDetailSearchAfter
-- pour nos emplacements : oui seulement pour un de mes objets clés (detail_after[adresse]).
shop_ui.world.detail_after = {}
-- Modes de ramassage (app.InteractItenGetModeNames, relevés dans il2cpp_dump le 2026-10-01) :
-- clés = FixDisplayCenter (toujours présenté), trésors = FixDisplayCenterAnotherSE, munitions et
-- ressources = FixDisplayCenterOnce (présenté seulement la 1re fois), Normal = jamais présenté.
-- Le plantage du 2026-10-01 venait d'un mode « Once » appris et pris pour « normal ».
shop_ui.world.GET_MODE = { normal = 1948795948, key = 2544608857, once = 3660107107, treasure = 2506306378 }
shop_ui.world.WRITE_GET_MODE = true
shop_ui.world.WRITE_CASE_GET_MODE = true -- mallette : Once (Normal bloquait le jeu, 2026-10-03)
function shop_ui.world.install_detail_hook()
    local m = sdk.find_type_definition("app.InteractItemGet"):get_method("IsGetItemDetailSearchAfter")
    if not m then debug_log("présentation : IsGetItemDetailSearchAfter introuvable") return end
    local pending = {}
    sdk.hook(m, function(args)
        pending[#pending + 1] = sdk.to_int64(args[2])
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local addr = table.remove(pending)
        local want = addr and shop_ui.world.detail_after[addr]
        -- Objet posé par le jeu à l'ouverture d'une mallette (2026-10-01 : Poudre noire AP présentée
        -- en plein écran, car le vrai LEMI posé par le jeu était nouveau) : pas d'adresse connue ;
        -- on prend l'emplacement AP le plus proche (moins de 1,5 m).
        if want == nil and addr then
            pcall(function()
                local get = sdk.to_managed_object(addr)
                local gp = get_gameobject_identity(get:call("get_GameObject")).item_position
                local best_d = 2.25
                for _, e in ipairs(shop_ui.world.entries or {}) do
                    local ep = get_gameobject_identity(e.si:call("get_GameObject")).item_position
                    local d2 = ep and gp and ((ep[1] - gp[1]) ^ 2 + (ep[2] - gp[2]) ^ 2 + (ep[3] - gp[3]) ^ 2)
                    if d2 and d2 < best_d and location_done(e.loc) ~= nil then
                        best_d = d2
                        want = shop_ui.world.own_key(e.loc) ~= nil
                    end
                end
            end)
        end
        if (shop_ui.world.detail_calls or 0) < 20 then
            shop_ui.world.detail_calls = (shop_ui.world.detail_calls or 0) + 1
            shop_ui.world.detail_note = string.format("présentation : IsGetItemDetailSearchAfter appelé, jeu=%s, emplacement AP=%s",
                tostring(sdk.to_int64(retval) & 1 == 1), tostring(want))
        end
        if want == nil then return retval end
        if (shop_ui.world.detail_logged or 0) < 30 then
            shop_ui.world.detail_logged = (shop_ui.world.detail_logged or 0) + 1
            shop_ui.world.detail_note = string.format("présentation : emplacement AP, jeu=%s -> %s",
                tostring(sdk.to_int64(retval) & 1 == 1), tostring(want))
        end
        return sdk.to_ptr(want and 1 or 0)
    end)
end
-- DÉSACTIVÉ (2026-10-01) : jamais appelé par le jeu pour les présentations (journal).
-- pcall(shop_ui.world.install_detail_hook)

function shop_ui.world.apply_key_mode(rec)
    if rec.si and rec.loc then
        pcall(function()
            local get = rec.si:get_field("SpawnedInteractItemGetCache")
            if get then
                shop_ui.world.detail_after[get:get_address()] =
                    shop_ui.world.own_key(rec.loc) ~= nil or rec.pickup_key == true
            end
        end)
    end
    -- Mode écrit (2026-10-01) : valeurs du dump, plus de mode appris. Objet clé à moi = présentation
    -- seulement si l'objet d'origine est modifié sur place (INPLACE : l'objet présenté est le vrai
    -- objet clé) ; sinon Normal (aucune présentation, jamais pour un objet AP non-clé).
    if not shop_ui.world.WRITE_GET_MODE then return end
    if rec.mode_set or not rec.si or not rec.loc then return end
    if location_done(rec.loc) == nil then return end -- pas dans cette seed : mode du jeu
    local want_key = (shop_ui.world.own_key(rec.loc) ~= nil or rec.pickup_key == true) and shop_ui.world.INPLACE == true
    -- Pas Normal (2026-10-03) : 1948795948 = mode des objets qu'on OUVRE (mallette, sac de Lei) ;
    -- sur un objet ordinaire, présentation vide puis jeu bloqué (Crochet #010, mallette LEMI).
    -- Once : présenté seulement si l'objet est nouveau (objet de ramassage déjà possédé,
    -- hasHistory forcé près d'un emplacement AP).
    local mode = want_key and shop_ui.world.GET_MODE.key or shop_ui.world.GET_MODE.once
    local delay = nil
    pcall(function()
        -- drop de boss (2026-10-07, hache du gardien présentée) : pas de cache sur l'emplacement,
        -- l'objet à ramasser est noté dans l'entrée (rec.get)
        local get = rec.get or rec.si:get_field("SpawnedInteractItemGetCache")
        if not get then return end
        rec.mode_get = get
        rec.old_mode = get:get_field("GetMode")
        rec.old_delay = get:get_field("IsDelayFinishDetailSearch")
        get:set_field("GetMode", mode)
        if delay ~= nil then get:set_field("IsDelayFinishDetailSearch", delay) end
        rec.mode_set = true
        debug_log(string.format("présentation : %s : GetMode %s -> %s (%s)", rec.loc.name,
            tostring(rec.old_mode), tostring(mode), want_key and "objet clé" or "once"))
    end)
end

-- Son du ramassage (2026-09-30) : l'objet créé par createItemCore n'a pas de lecteur de sons
-- (ItemCore.wwiseContainer) : ramassage muet. Un fragment de mur non remplacé faisait bien son
-- bruit. On recopie le lecteur de sons de l'objet d'origine sur l'objet de ramassage.
-- DÉSACTIVÉ (2026-10-01) : présentation vide puis plantage du jeu ; le lecteur de sons recopié
-- reste lié à l'objet d'origine, qui peut disparaître. À reprendre autrement.
shop_ui.world.COPY_SOUND = false
function shop_ui.world.copy_sound(from, to)
    if not shop_ui.world.COPY_SOUND then return end
    for _, f in ipairs({ "<wwiseContainer>k__BackingField", "<wwiseMonitoredValues>k__BackingField" }) do
        local ok, err = pcall(function()
            local v = from:get_field(f)
            if v ~= nil then to:set_field(f, v) end
        end)
        if not ok and (shop_ui.world.sound_err or 0) < 3 then
            shop_ui.world.sound_err = (shop_ui.world.sound_err or 0) + 1
            debug_log("objet au sol : son non recopié (" .. f .. ") : " .. tostring(err))
        end
    end
end

function shop_ui.world.swap_pickup(e, rec)
    pcall(shop_ui.world.learn_get_mode, e)
    -- Arme posée : ni mode de ramassage changé, ni objet modifié (voir shop_ui.world.model_for)
    local weapon_def = item_by_name[e.loc.original_item or ""]
    if weapon_def and weapon_def.type == "Weapon" then return end
    rec.si, rec.loc, rec.get = rec.si or e.si, rec.loc or e.loc, rec.get or e.get
    if rec.pickup then shop_ui.world.apply_key_mode(rec) return end
    local key_def = shop_ui.world.own_key(e.loc)
    rec.pickup_key = key_def ~= nil
    shop_ui.world.apply_key_mode(rec)
    -- Objet qui TOMBE quand on tire dessus (FallByAttack : fragments de cristal sur les murs,
    -- 2026-10-08 : Fragment de cristal #015 [S01] ramassé à plus de 5 m de son emplacement, check
    -- perdu) : son objet à ramasser est noté, le ramassage le retrouve où qu'il soit tombé.
    if (e.loc.item_object or ""):find("FallByAttack", 1, true) then
        pcall(function()
            local g = e.si:get_field("SpawnedInteractItemGetCache")
            if g then shop_ui.world.case_gets[g:get_address()] = e.loc end
        end)
    end
    local orig = item_by_name[e.loc.original_item or ""]
    if key_def and orig and orig.game_item_id == key_def.game_item_id then return end -- déjà le bon
    if not key_def and orig and (orig.type == "Money" or orig.type == "Treasure") then return end
    local get = e.si:get_field("SpawnedInteractItemGetCache")
    local core = get and get:get_field("ItemCore")
    if not core then return end
    local gid, qty = shop_ui.world.PICKUP_ID, 1
    if key_def then gid = key_def.game_item_id end
    -- EXPÉRIMENTAL (2026-10-01, case « Ramassage : modifier l'objet d'origine ») : l'objet créé par
    -- createItemCore n'a ni son ni présentation ; on modifie l'objet d'origine sur place (numéro
    -- d'objet + fiche), il garde son lecteur de sons et ses réglages. Remis d'origine ensuite.
    if shop_ui.world.INPLACE then
        local ok, err = pcall(function()
            local old = shop_ui.world.modify_inplace(core, gid, qty)
            rec.pickup = { get = get, core = core, gid = gid, new = core, key = key_def ~= nil, inplace = old }
        end)
        debug_log(string.format("objet au sol : %s : objet d'origine MODIFIÉ sur place -> %s x%d (%s)",
            e.loc.name, tostring(gid), qty, ok and "ok" or tostring(err)))
        if ok then return end
    end
    local new = sdk.get_managed_singleton("app.InventoryManager"):call("createItemCore", gid, qty, 0, 0)
    if not new then return end
    new = new:add_ref()
    pcall(function() core:add_ref() end)
    shop_ui.world.copy_sound(core, new)
    get:set_field("ItemCore", new)
    rec.pickup = { get = get, core = core, gid = gid, new = new, key = key_def ~= nil }
    debug_log(string.format("objet au sol : %s : objet d'origine remplacé par l'objet %s x%d pour le ramassage",
        e.loc.name, tostring(gid), qty))
end

function shop_ui.world.restore_pickup(rec)
    pcall(function()
        local get = rec.si and rec.si:get_field("SpawnedInteractItemGetCache")
        if get then shop_ui.world.detail_after[get:get_address()] = nil end
    end)
    if rec.mode_set then
        pcall(function()
            rec.mode_get:set_field("GetMode", rec.old_mode)
            rec.mode_get:set_field("IsDelayFinishDetailSearch", rec.old_delay)
        end)
        rec.mode_set = nil
    end
    if not rec.pickup then return end
    if rec.pickup.inplace then
        local old = rec.pickup.inplace
        pcall(function()
            local work = rec.pickup.core:call("get_work")
            rec.pickup.core:call("set_spec", old.spec)
            work:call("set_itemID", old.id)
            work:call("set_stackSize", old.stack)
        end)
        rec.pickup = nil
        return
    end
    pcall(function() rec.pickup.get:set_field("ItemCore", rec.pickup.core) end)
    rec.pickup = nil
end

-- Mallette à pièce d'arme ouverte, caisse cassée (2026-09-27) : le jeu pose alors un autre objet
-- (LEMI (1) au lieu du LEMI (2) prévu ; Lei pour « Munitions pour pistolet #012 »), par-dessus
-- notre objet de ramassage. Ce nouvel objet devient l'objet d'origine (ligne d'objet, remise),
-- et il est remplacé à nouveau s'il prend une case.
function shop_ui.world.instance_get(e)
    local get = nil
    pcall(function()
        local inst = e.si:call("get_spawnInstance")
        get = inst and inst:call("getComponent(System.Type)", sdk.typeof("app.InteractItemGet"))
    end)
    return get
end

-- Modifie un objet du jeu sur place (voir INPLACE) ; renvoie de quoi le remettre.
function shop_ui.world.modify_inplace(core, gid, qty)
    local specs = sdk.get_managed_singleton("app.ItemSpecification")
    local work = core:call("get_work")
    local old = { id = work:call("get_itemID"), stack = work:call("get_stackSize"), spec = core:call("get_spec") }
    core:add_ref()
    core:call("set_spec", specs:call("findItemSpec", gid))
    work:call("set_itemID", gid)
    work:call("set_stackSize", qty)
    return old
end

function shop_ui.world.sync_pickup(e, rec)
    local p = rec and rec.pickup
    if not p then return end
    -- Objet modifié sur place (2026-10-01 : mallette du LEMI, présentation buguée) : l'objet posé par
    -- le jeu à l'ouverture est modifié à son tour, au lieu d'être remplacé par un objet créé.
    if p.inplace then
        local get_now = shop_ui.world.instance_get(e)
        if get_now and get_now:get_address() ~= p.get:get_address() then p.get = get_now:add_ref() end
        local live = p.get:get_field("ItemCore")
        if not live or live:get_address() == p.core:get_address() then return end
        local id = get_item_id_from_core(live)
        if id == p.gid then return end
        local def = nil
        for _, d in pairs(item_by_name) do if d.game_item_id == id then def = d break end end
        local free = id == (item_by_name["Sac de Lei"] or {}).game_item_id or (def and def.type == "Treasure")
        if free and not p.key then return end
        local ok, old = pcall(shop_ui.world.modify_inplace, live, p.gid, 1)
        if ok then p.core, p.new, p.inplace = live, live, old end
        debug_log(string.format("objet au sol : %s : le jeu a posé l'objet %s, modifié sur place -> %s (%s)",
            e.loc.name, tostring(id), tostring(p.gid), ok and "ok" or tostring(old)))
        return
    end
    -- Objet réellement apparu (composant de l'instance) différent du cache : on suit celui-là.
    local get_now = shop_ui.world.instance_get(e)
    if get_now and get_now:get_address() ~= p.get:get_address() then
        pcall(function() p.get:set_field("ItemCore", p.core) end)
        p.get = get_now:add_ref()
        p.new = sdk.get_managed_singleton("app.InventoryManager"):call("createItemCore", p.gid, 1, 0, 0):add_ref()
        shop_ui.world.copy_sound(p.core, p.new)
        p.get_changed = true
        debug_log("objet au sol : " .. e.loc.name .. " : objet apparu différent du cache, suivi")
    end
    local live = p.get:get_field("ItemCore")
    if not live or live:get_address() == p.new:get_address() then return end
    live = live:add_ref()
    p.core = live
    local id = get_item_id_from_core(live)
    local def = nil
    for _, d in pairs(item_by_name) do if d.game_item_id == id then def = d break end end
    local free = id == (item_by_name["Sac de Lei"] or {}).game_item_id or (def and def.type == "Treasure")
    if not free then p.get:set_field("ItemCore", p.new) else p.new = live end
    debug_log(string.format("objet au sol : %s : le jeu a posé l'objet %s (%s)", e.loc.name, tostring(id),
        free and "gardé" or "remplacé à nouveau pour le ramassage"))
end

-- Icône sous le nom (test du 2026-09-27 : celle de l'objet d'origine, fausse). Elle vient de
-- l'ItemCore de l'objet à ramasser, le même qui entre dans la mallette et sert à reconnaître le
-- check (on_item_picked) : on ne le change pas, on cache l'icône. Journal : les deux ItemCore
-- (InteractItemGet et InteractBasic), pour voir si l'un sert seulement à l'affichage.
-- Test du 2026-09-30 : plus aucun bruit au ramassage d'un objet AP (même un Sac de Lei, ramassé tel
-- quel) ; DispItemIcon = false coupe peut-être aussi l'animation de ramassage et son son. Case
-- « Cacher l'icône au ramassage » dans les outils (vaut pour les objets posés ensuite).
shop_ui.world.HIDE_ICON = true
function shop_ui.world.hide_icon(si, loc)
    if not shop_ui.world.HIDE_ICON then return end
    local report = {}
    pcall(function()
        local get = si:get_field("SpawnedInteractItemGetCache")
        if get then
            get:set_field("DispItemIcon", false)
            local core = get:get_field("ItemCore")
            report[#report + 1] = "InteractItemGet.ItemCore=" .. tostring(get_item_id_from_core(core))
                .. "@" .. tostring(core and core:get_address())
        end
    end)
    pcall(function()
        local basic = si:get_field("Interact")
        if basic then
            basic:set_field("IsDispItemIcon", false)
            local core = basic:get_field("ItemCore")
            report[#report + 1] = "InteractBasic.ItemCore=" .. tostring(get_item_id_from_core(core))
                .. "@" .. tostring(core and core:get_address())
        end
    end)
    if (shop_ui.world.icon_logged or 0) < 5 then
        shop_ui.world.icon_logged = (shop_ui.world.icon_logged or 0) + 1
        debug_log("objet au sol : icône cachée pour " .. loc.name .. " ; " .. table.concat(report, ", "))
    end
end

-- (Invite "E Prendre" : laissée telle quelle, demande du joueur du 2026-09-27 ; le "[AP] objet"
-- est sur la ligne d'objet affichée à l'écran, ci-dessous.)

-- Ligne d'objet affichée à l'écran près d'un objet à ramasser (GUIItemLineInfo : nom, icône,
-- quantité). Tests du 2026-09-27 : icône cachée puis remise en se tournant, ancien texte et
-- ancienne icône en s'éloignant. Désormais, au moment où le jeu remplit la ligne (setItemID), on
-- repère le check montré (objet d'origine = objet affiché, le plus proche de la caméra) et on
-- remplace l'objet DU PARAMÈTRE d'affichage par un objet créé pour l'occasion : le vrai objet
-- (objet de ce jeu) ou le porteur (icône Archipelago, autre jeu). L'objet ramassé (celui de
-- InteractItemGet) n'est pas touché. La ligne reste liée à ce check jusqu'au prochain setItemID.
shop_ui.world.display_cores = {}

function shop_ui.world.display_core(gid)
    local core = shop_ui.world.display_cores[gid]
    if not core then
        -- createItemCore rend nil pour certains objets (LEMI (2), 2026-09-29 : erreur, ligne
        -- d'origine) : porteur de la ligne à la place (icône Archipelago).
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local made = mgr and mgr:call("createItemCore", gid, 1, 0, 0)
        if not made then
            if (shop_ui.world.core_failed_logged or 0) < 10 then
                shop_ui.world.core_failed_logged = (shop_ui.world.core_failed_logged or 0) + 1
                debug_log("objet au sol : createItemCore impossible pour " .. tostring(gid) .. ", porteur à la place")
            end
            if gid == shop_ui.LINE_CARRIER_ID or not shop_ui.line_carrier_ready then return nil end
            return shop_ui.world.display_core(shop_ui.LINE_CARRIER_ID)
        end
        core = made:add_ref()
        shop_ui.world.display_cores[gid] = core
    end
    return core
end

-- Objet réellement posé (InteractItemGet.ItemCore) : peut différer de l'objet d'origine prévu
-- (coffre à pièce d'arme : LEMI (1) posé pour le check LEMI (2), ligne sans "[AP]", 2026-09-27).
function shop_ui.world.live_core(e)
    local core = nil
    pcall(function() core = e.si:get_field("SpawnedInteractItemGetCache"):get_field("ItemCore") end)
    return core
end

-- Variantes « (1) » / « (2) » d'un même objet (items.json) : la mallette du château après la
-- cuisine montre LEMI (1) pour le check LEMI (2), ligne restée d'origine (2026-09-29).
function shop_ui.world.same_variant(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    if not shop_ui.world.variant_names then
        local m = {}
        for _, it in ipairs(items) do
            if it.game_item_id and it.name and it.name:find("%(%d+%)$") then
                m[it.game_item_id] = (it.name:gsub("%s*%(%d+%)$", ""))
            end
        end
        shop_ui.world.variant_names = m
    end
    local m = shop_ui.world.variant_names
    return m[a] ~= nil and m[a] == m[b]
end

function shop_ui.world.entry_for_item(id, core)
    if not shop_ui.world.near or #shop_ui.world.near == 0 then return nil end
    local addr = core and core:get_address()
    local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position")
    local best, best_d = nil, 6.0 * 6.0
    for _, e in ipairs(shop_ui.world.near) do
        -- Objet posé avant le remplacement (swap_pickup), sinon objet posé actuel.
        local live = e.pickup and e.pickup.core or shop_ui.world.live_core(e)
        local now = shop_ui.world.live_core(e) -- objet posé par le jeu à l'ouverture / la casse
        local inst_get = shop_ui.world.instance_get(e)
        if inst_get then
            local c = inst_get:get_field("ItemCore")
            if c and addr and c:get_address() == addr then return e end
            if c and get_item_id_from_core(c) == id then return e end
        end
        if addr and ((live and live:get_address() == addr) or (now and now:get_address() == addr)) then return e end
        -- Caisse cassée / mallette ouverte : le vrai objet est celui du placement (get_spawnItemId,
        -- Lei pour « Munitions pour pistolet #012 »), pas celui du cache SpawnedInteractItemGetCache.
        local sid = nil
        pcall(function() sid = e.si:call("get_spawnItemId") end)
        if e.orig_id == id or sid == id or (live and get_item_id_from_core(live) == id) or (now and get_item_id_from_core(now) == id)
            or (e.pickup and e.pickup.gid == id) or shop_ui.world.same_variant(e.orig_id, id) then
            local p = e.inst:call("get_Transform"):call("get_Position")
            local d = (p.x - cam.x) ^ 2 + (p.y - cam.y) ^ 2 + (p.z - cam.z) ^ 2
            if d < best_d then best, best_d = e, d end
        end
    end
    return best
end

-- Avant setItemID : check montré, et objet d'affichage à sa place.
function shop_ui.world.on_set_item(param, picked)
    shop_ui.world.line_entry = nil
    shop_ui.world.line_picked = picked == true
    local core = param:call("get_itemCore")
    local id = get_item_id_from_core(core)
    local e = id and shop_ui.world.entry_for_item(id, core)
    if not e and id and os.clock() - (shop_ui.world.forced_scan or -10) > 2 then
        -- Caisse / pot cassé (2026-09-27 : ni modèle ni "[AP]") : l'objet peut venir d'un placement
        -- apparu après le dernier relevé (toutes les 8 s). Relevé refait tout de suite, 1 fois / 2 s,
        -- et nouvel essai dans le même appel (2026-09-29 : relevé à l'image suivante, la ligne
        -- restait d'origine 2 à 3 s, jusqu'au setItemID suivant).
        shop_ui.world.forced_scan = os.clock()
        shop_ui.world.next_scan, shop_ui.world.next_update = 0, 0
        pcall(shop_ui.world.update)
        e = shop_ui.world.entry_for_item(id, core)
        if not e and (locations.boss_drops or {})[id] and not shop_ui.world.drop_diag_done then
            -- Diagnostic (2026-10-07) : Buste de Bela jamais repéré (ni ItemSpawnInfo ni
            -- ItemSpawnInfoEnemyDrop) : d'où vient l'objet visé ?
            shop_ui.world.drop_diag_done = (shop_ui.world.drop_diag_n or 0) >= 2
            shop_ui.world.drop_diag_n = (shop_ui.world.drop_diag_n or 0) + 1
            pcall(function()
                local go = core:call("get_GameObject")
                local chain, t = {}, go and go:call("get_Transform")
                for _ = 1, 5 do
                    if not t then break end
                    local g = t:call("get_GameObject")
                    local comps = {}
                    pcall(function()
                        local arr = g:call("get_Components")
                        for _, c in ipairs(arr and arr:get_elements() or {}) do
                            comps[#comps + 1] = c:get_type_definition():get_full_name()
                        end
                    end)
                    chain[#chain + 1] = tostring(g:call("get_Name")) .. " [" .. table.concat(comps, ",") .. "]"
                    t = t:call("get_Parent")
                end
                debug_log("drop diag : objet visé " .. tostring(id) .. " : " .. table.concat(chain, " <- "))
                local n1, ids = 0, {}
                for _, si in ipairs(find_all_components("app.Spawn.ItemSpawnInfoEnemyDrop")) do
                    n1 = n1 + 1
                    local inst = nil
                    pcall(function() inst = si:call("get_spawnInstance") end)
                    ids[#ids + 1] = tostring(si:get_field("DropItemID")) .. (inst and ("=" .. tostring(inst:call("get_Name"))) or "")
                end
                debug_log("drop diag : " .. n1 .. " ItemSpawnInfoEnemyDrop : " .. table.concat(ids, ", "))
                local list = sdk.get_managed_singleton("app.ItemSpawnInfoHolder"):get_field("ItemSpawnInfoEnemyDropUseList")
                local u = {}
                for i = 0, list:call("get_Count") - 1 do
                    local si = list:call("get_Item", i)
                    local inst = nil
                    pcall(function() inst = si:call("get_spawnInstance") end)
                    local sid = nil
                    pcall(function() sid = si:call("get_spawnItemId") end)
                    u[#u + 1] = tostring(sid) .. (inst and ("=" .. tostring(inst:call("get_Name"))) or "")
                end
                debug_log("drop diag : EnemyDropUseList (" .. #u .. ") : " .. table.concat(u, ", "))
            end)
        end
        if not e then
            if (shop_ui.world.unmatched_logged or 0) < 30 then
                shop_ui.world.unmatched_logged = (shop_ui.world.unmatched_logged or 0) + 1
                debug_log(string.format("objet au sol : ligne d'objet %s sans check reconnu (%d checks proches), nouveau relevé",
                    tostring(id), #(shop_ui.world.near or {})))
                -- Détail des checks proches : quel objet chacun annonce, et à quelle distance.
                pcall(function()
                    local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position")
                    for _, n in ipairs(shop_ui.world.near or {}) do
                        local info = { n.loc.name, "orig=" .. tostring(n.orig_id) }
                        pcall(function() info[#info + 1] = "spawnItemId=" .. tostring(n.si:call("get_spawnItemId")) end)
                        pcall(function() info[#info + 1] = "cache=" .. tostring(get_item_id_from_core(shop_ui.world.live_core(n))) end)
                        pcall(function() info[#info + 1] = "avant=" .. tostring(n.pickup and get_item_id_from_core(n.pickup.core)) end)
                        pcall(function()
                            local g = shop_ui.world.instance_get(n)
                            info[#info + 1] = "instance=" .. (g and tostring(get_item_id_from_core(g:get_field("ItemCore"))) or "aucun")
                        end)
                        pcall(function()
                            local p = n.inst:call("get_Transform"):call("get_Position")
                            info[#info + 1] = string.format("dist=%.1f", math.sqrt((p.x - cam.x) ^ 2 + (p.y - cam.y) ^ 2 + (p.z - cam.z) ^ 2))
                        end)
                        debug_log("  check proche : " .. table.concat(info, " "))
                    end
                end)
            end
        end
    end
    if not e then return end
    shop_ui.world.line_entry = e
    if (e.loc.key_item_location == true or (e.loc.folder_path or ""):find("KeyItem", 1, true)
            or shop_ui.world.own_key(e.loc)) and (shop_ui.world.key_line_logged or 0) < 20 then
        shop_ui.world.key_line_logged = (shop_ui.world.key_line_logged or 0) + 1
        debug_log(string.format("objet au sol : ligne d'objet (%s) pour %s : objet %s, texte voulu \"%s\"",
            picked and "obtenu" or "visé", e.loc.name, tostring(id), tostring(e.label)))
    end
    local lid = get_location_id(e.loc)
    local s = lid and scouted_items[lid]
    local gid = nil
    if s and not s.mine then
        -- Ligne d'objet : icône Remède avec le porteur (2026-09-27 ; la ligne suit sans doute son
        -- prefab, celui du Remède pour le modèle 3D de la boutique). Second porteur, sans prefab.
        gid = (shop_ui.line_carrier_ready and shop_ui.LINE_CARRIER_ID)
            or (shop_ui.carrier_ready and shop_ui.CARRIER_ID) or nil
    elseif s then
        -- Sac de Lei compris (2026-09-29 : icône de l'objet d'origine sur la ligne). Seulement
        -- l'objet d'AFFICHAGE : le ramassage, lui, n'est jamais en Lei (voir PICKUP_ID).
        local def = item_by_name[s.name]
        gid = def and (def.give_id or def.game_item_id) or nil
    end
    local shown = gid and gid ~= id and shop_ui.world.display_core(gid)
    if shown then param:call("set_itemCore", shown) end
end

function shop_ui.world.apply_line(line)
    if not line then return end
    local e = shop_ui.world.line_entry
    local stack = line:call("get_stackDisplayPanel")
    if e and (location_done(e.loc) ~= nil or shop_ui.world.line_picked) then
        line:call("get_itemnameText"):call("set_Message", e.label)
        shop_ui.world.line_keep = { line = line, label = e.label, loc = e.loc.name, until_t = os.clock() + 4 }
        -- Icône Archipelago qui s'affiche en flacon sur cette ligne (2026-09-27) : planche
        -- d'icônes utilisée par la ligne, notée une fois.
        if not shop_ui.world.line_icon_logged then
            shop_ui.world.line_icon_logged = true
            local info = {}
            local tex = line:call("get_iconTexture")
            for _, getter in ipairs({ "get_Texture", "get_TexturePath", "get_UVSequenceResource", "get_UVSequence",
                    "get_PatternNo", "get_SequenceNo", "get_RegionRect", "get_ResourcePath" }) do
                pcall(function()
                    local v = tex:call(getter)
                    local ok_p, path = pcall(function() return v:call("get_ResourcePath") end)
                    info[#info + 1] = getter .. "=" .. tostring(ok_p and path or v)
                end)
            end
            debug_log("objet au sol : icône de la ligne : " .. table.concat(info, " ; "))
        end
        pcall(function() line:call("get_iconPanel"):call("set_Visible", true) end)
        pcall(function() stack:call("set_Visible", false) end)
        shop_ui.world.line_hidden = true
    elseif shop_ui.world.line_hidden then
        pcall(function() stack:call("set_Visible", true) end)
        shop_ui.world.line_hidden = false
    end
    if not (e and (location_done(e.loc) ~= nil or shop_ui.world.line_picked)) then shop_ui.world.line_keep = nil end
end

-- Objets clés (2026-10-03) : nom d'origine sur la ligne d'objet, alors que les autres checks ont
-- bien « [AP] ... ». Le jeu réécrit sans doute le nom APRÈS setItemID pour ces objets : le nom
-- est vérifié avant chaque rendu pendant 4 s et remis s'il a changé (journal : ce que le jeu a écrit).
function shop_ui.world.keep_line_label()
    local k = shop_ui.world.line_keep
    if not k then return end
    if os.clock() > k.until_t then shop_ui.world.line_keep = nil return end
    local text = k.line:call("get_itemnameText")
    local now = text and text:call("get_Message")
    if now ~= nil and now ~= k.label then
        text:call("set_Message", k.label)
        if (shop_ui.world.relabel_logged or 0) < 30 then
            shop_ui.world.relabel_logged = (shop_ui.world.relabel_logged or 0) + 1
            debug_log(string.format("objet au sol : ligne de %s réécrite par le jeu (\"%s\"), remise à \"%s\"",
                k.loc, tostring(now), k.label))
        end
    end
end
re.on_pre_application_entry("BeginRendering", function() pcall(shop_ui.world.keep_line_label) end)

-- DIAG (2026-10-03) : Bague (mon objet clé, posée sur Fluide chimique #013, mode objet clé) impossible
-- à ramasser, puis crash du jeu, deux fois. Étapes du ramassage notées dans le journal (près d'un de
-- mes objets clés seulement) pour voir où le jeu s'arrête. Mallette pleine à ce moment-là.
shop_ui.world.pickup_trace = 0
function shop_ui.world.install_pickup_trace()
    local def = sdk.find_type_definition("app.InteractItemGet")
    if not def then return end
    for _, name in ipairs({ "startDetailSearch", "AddInventory", "InsertInventory", "InsertInventoryInternal",
            "InventoryInsertCancelItem", "InventoryInsertFinishItem", "RequestInteractOverrideItemGet",
            "IsItemGetInventoryPreviewCheck", "RequestItemCore", "SetupItemCore" }) do
        local m = def:get_method(name)
        if m then
            local stack = {}
            sdk.hook(m, function(args)
                local active = os.clock() < (shop_ui.world.near_key_until or 0) and shop_ui.world.pickup_trace < 80
                stack[#stack + 1] = active
                if active then
                    shop_ui.world.pickup_trace = shop_ui.world.pickup_trace + 1
                    local info = "?"
                    pcall(function()
                        local get = sdk.to_managed_object(args[2])
                        local core = get:get_field("ItemCore")
                        info = string.format("objet %s, GetMode %s, InventoryFullOnlyAppearPerformance %s",
                            tostring(get_item_id_from_core(core)), tostring(get:get_field("GetMode")),
                            tostring(get:get_field("InventoryFullOnlyAppearPerformance")))
                    end)
                    debug_log("ramassage (diag) : " .. name .. " : " .. info)
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                if table.remove(stack) then
                    debug_log(string.format("ramassage (diag) : %s -> %s", name, tostring(sdk.to_int64(retval))))
                end
                return retval
            end)
        end
    end
end
-- DÉSACTIVÉ (2026-10-03, 18h51) : le jeu plantait au lancement avec ces hooks (sans erreur notée).
-- pcall(shop_ui.world.install_pickup_trace)

-- DIAG sans hook : près d'un de mes objets clés posé ailleurs (méthode sur place), l'état de son
-- InteractItemGet est relu toutes les 0,1 s ; chaque changement est noté (« ramassage (diag) »).
shop_ui.world.pickup_poll = {}
function shop_ui.world.poll_key_pickups()
    if os.clock() > (shop_ui.world.near_key_until or 0) then return end
    for _, e in ipairs(shop_ui.world.entries or {}) do
        if shop_ui.world.own_key(e.loc) then
            pcall(function()
                local get = e.si:get_field("SpawnedInteractItemGetCache")
                if not get then return end
                local parts = {}
                for _, f in ipairs({ "GetMode", "ItemGetRequest", "RequestItemGetInteract", "TemporaryInventoryOperationResult",
                        "IsHighLightNow", "DelayFinish", "InventoryFullOnlyAppearPerformance", "MeshInitDispOff" }) do
                    local ok, v = pcall(function() return get:get_field(f) end)
                    if ok and type(v) == "userdata" then
                        local okn, n = pcall(function() return v:get_type_definition():get_full_name() end)
                        v = okn and n or "objet"
                    end
                    parts[#parts + 1] = f .. "=" .. tostring(ok and v or "?")
                end
                pcall(function() parts[#parts + 1] = "objet=" .. tostring(get_item_id_from_core(get:get_field("ItemCore"))) end)
                local state = table.concat(parts, " ")
                local key = e.loc.name
                if shop_ui.world.pickup_poll[key] ~= state and shop_ui.world.pickup_trace < 120 then
                    shop_ui.world.pickup_poll[key] = state
                    shop_ui.world.pickup_trace = shop_ui.world.pickup_trace + 1
                    debug_log("ramassage (diag) : " .. key .. " : " .. state)
                end
            end)
        end
    end
end

-- setItemID : objet visé ; getItemID : objet ramassé ("obtenu", 2026-09-27 : la ligne
-- repassait à l'objet d'origine au ramassage). Même traitement, le texte "[AP]" restant affiché
-- même si le check vient d'être validé.
function shop_ui.world.install_line_hook()
    local def = sdk.find_type_definition("app.GUIItemLineInfo")
    for _, name in ipairs({ "setItemID", "getItemID" }) do
        local method = def and def:get_method(name)
        if not method then
            debug_log("objet au sol : GUIItemLineInfo." .. name .. " introuvable")
        else
            sdk.hook(method, function(args)
                shop_ui.world.hook_line = sdk.to_managed_object(args[2])
                local ok, err = pcall(shop_ui.world.on_set_item, sdk.to_managed_object(args[3]), name == "getItemID")
                if not ok and not shop_ui.world.set_item_error_logged then
                    shop_ui.world.set_item_error_logged = true
                    debug_log("objet au sol : erreur de la ligne d'objet (" .. name .. ") " .. tostring(err))
                end
            end, function(retval)
                shop_ui.world.line = shop_ui.world.hook_line
                pcall(shop_ui.world.apply_line, shop_ui.world.line)
                return retval
            end)
        end
    end
end
shop_ui.world.install_line_hook()

function shop_ui.world.update_prompt()
    if not is_in_game() then return end
    for key, rec in pairs(shop_ui.world.swapped) do
        -- Objet du jeu retiré entre deux nettoyages (0,5 s) : plus de lecture de sa pose (voir
        -- shop_ui.world.remove, crashs de la Cave à vin). Le placement (si), lui, reste.
        if rec.go and rec.host_tf and not rec.gone then
            local inst = nil
            pcall(function() inst = rec.si:call("get_spawnInstance") end)
            if inst == nil or inst:get_address() ~= key then rec.gone = true end
        end
        if rec.go and rec.host_tf and not rec.gone then
            local ok_f, err_f = pcall(shop_ui.world.follow_joint, rec)
            if not ok_f and not shop_ui.world.follow_error_logged then
                shop_ui.world.follow_error_logged = true
                debug_log("objet au sol : erreur de pose (os _00) " .. tostring(err_f))
            end
        end
    end
    if shop_ui.world.line then
        local ok_l, err_l = pcall(shop_ui.world.apply_line, shop_ui.world.line)
        if not ok_l and not shop_ui.world.line_error_logged then
            shop_ui.world.line_error_logged = true
            debug_log("objet au sol : erreur de la ligne d'objet " .. tostring(err_l))
        end
    end
end

function shop_ui.loc_of(unit)
    local linked = shop_ui.unit_loc and shop_ui.unit_loc[unit:get_address()]
    if linked then
        if location_done(linked) == false then return linked end
        return nil
    end
    return next_shop_location(unit_item_id(unit))
end

-- Renommage "[AP] ..." sans hook (les hooks de sélection ont fait figer le jeu au démarrage,
-- 2026-09-26) : appelé par la boucle du jeu, seulement quand la boutique vient d'être vue.
local function update_shop_label()
    if not shop_is_open() then return end
    pcall(function()
        local unit = shop_ui.selected(open_shop)
        if not unit then return end
        local item_id = unit_item_id(unit)
        -- Relevé (2026-09-27, Valise) : modèle réellement affiché pour chaque article, noté une
        -- fois par objet, 1 s après la sélection (le temps que la boutique crée l'objet affiché).
        shop_ui.model_seen = shop_ui.model_seen or {}
        if shop_ui.model_probe_id ~= item_id then
            shop_ui.model_probe_id, shop_ui.model_probe_time = item_id, os.clock()
        elseif not shop_ui.model_seen[item_id] and os.clock() - shop_ui.model_probe_time > 1.0 then
            shop_ui.model_seen[item_id] = true
            local shown = {}
            for _, m in ipairs(find_all_components("via.render.Mesh")) do
                pcall(function()
                    local go_name = m:call("get_GameObject"):call("get_Name")
                    if go_name:find("DetailSearch", 1, true) and m:call("get_DrawDefault") ~= false then
                        shown[#shown + 1] = go_name .. " = " .. tostring(m:call("getMesh"):call("get_ResourcePath"))
                            .. " | " .. tostring(m:call("get_Material"):call("get_ResourcePath"))
                    end
                end)
            end
            debug_log(string.format("boutique : modèle affiché pour %s : %s", tostring(item_id), table.concat(shown, " ; ")))
        end
        local loc = shop_ui.loc_of(unit)
        local lid = loc and get_location_id(loc)
        local s = lid and scouted_items[lid]
        local label = nil
        if loc then
            label = "[AP] " .. ((s and s.label) or loc.original_item)
        elseif unit:call("get_price") == 0 and parcel_index_of(item_id) then
            label = "[Colis AP] " .. state.parcel[parcel_index_of(item_id)]
        end
        if label then open_shop:call("get_itemNameText"):call("set_Message", label) end
        local model = loc and shop_ui.ap_model_units[unit:get_address()] or nil
        if not model and not loc and shop_ui.ap_test and item_id == shop_ui.CARRIER_ID then
            model = shop_ui.AP_MODEL -- article AP de test (outils de dev)
        end
        if shop_ui.ap_test and item_id == shop_ui.CARRIER_ID and not shop_ui.ap_test_logged then
            shop_ui.ap_test_logged = true
            debug_log(string.format("boutique : article AP de test sélectionné, location %s, modèle %s",
                tostring(loc and loc.name), tostring(model)))
        end
        local ok_preview, err_preview = pcall(shop_ui.update_preview, model)
        if not ok_preview and not shop_ui.preview_error_logged then
            shop_ui.preview_error_logged = true
            debug_log("modèle Archipelago : erreur au remplacement du maillage : " .. tostring(err_preview))
        end
        if s and not s.mine then
            open_shop:call("get_itemCategoryText"):call("set_Message", tr("Objet pour le jeu de ", "Item for the game of ") .. s.player)
            open_shop:call("get_itemDescriptionText"):call("set_Message", string.format(
                tr("Objet Archipelago pour le jeu de %s (%s). Il sera envoyé une fois acheté.",
                    "Archipelago item for %s's game (%s). It will be sent once bought."), s.player, s.game))
        elseif s then
            -- Objet de ce jeu : catégorie et description écrites par le mod (items.json), car la
            -- boutique ne sait pas afficher celles des matériaux ("#Rejected#
            -- item_material_004_Desc" pour la Poudre noire, test du 2026-09-26).
            local def = item_by_name[s.name]
            local category = def and def.category ~= "" and def.category or tr("Objet Archipelago", "Archipelago item")
            local desc = def and def.description ~= "" and def.description
                or string.format(tr("Objet pour ton jeu : %s.", "Item for your game: %s."), s.name)
            open_shop:call("get_itemCategoryText"):call("set_Message", category)
            open_shop:call("get_itemDescriptionText"):call("set_Message", desc .. tr(" Tu le recevras une fois acheté.", " You will receive it once bought."))
        end
    end)
end

local function hide_unreceived_rebuys(shop)
    local units = shop:call("get_buyUnits")
    local received = state.received_ids or {}
    for i = units:call("get_Count") - 1, 0, -1 do
        local unit = units:call("get_Item", i)
        local id = unit_item_id(unit)
        if world_check_weapon_ids[id] and unit:call("get_price") > 0 and not shop_locations_by_item[id]
                and (not received[tostring(id)] or parcel_index_of(id)) then
            units:call("RemoveAt", i)
        end
    end
end

-- Journal des achats + expérience ci-dessus.
local function install_shop_hooks()
    local def = sdk.find_type_definition("app.GUIShopBuy")
    if not def then return end
    for _, name in ipairs({ "buyItem", "decideBuyItem", "buyUnitItem" }) do
        local method = def:get_method(name)
        if method then
            local skip_result = false
            sdk.hook(method, function(args)
                skip_result = false
                if name == "buyItem" then
                    -- Article-check (2026-09-26) : on saute l'achat du jeu, le mod débite le prix
                    -- affiché et envoie le check, rien n'est donné. Validé d'abord sur les
                    -- Formules (la recette restait en Confection malgré tous les retraits), puis
                    -- étendu à tout : la Valise agrandie puis remise 2 s après désordonnait la
                    -- mallette si on l'ouvrait entre-temps. Sans assez de Lei, le jeu refuse.
                    -- (L'ancienne méthode, achat puis retrait, reste dans decideBuyItem en secours.)
                    pcall(function()
                        local unit = shop_ui.selected(sdk.to_managed_object(args[2]))
                        local loc = unit and shop_ui.loc_of(unit)
                        if loc then
                            local price = unit:call("get_price") or loc.price or 0
                            local money = get_money()
                            local _, inv = get_active_inventory()
                            if money and inv and money >= price then
                                inv:call("setMoney", money - price)
                                table.insert(shop_purchases, loc)
                                shop_ui.bought[loc.key] = true
                                skip_result = true
                                debug_log(string.format("boutique : article-check %s, achat du jeu sauté, %d Lei débités",
                                    loc.name, price))
                            end
                        end
                    end)
                    if skip_result then return sdk.PreHookResult.SKIP_ORIGINAL end
                    craft_before_buy = craft_state_ids()
                    recipe_state_at_buy = nil
                    pcall(function()
                        local work = sdk.to_managed_object(args[2]):call("get_currentItemWork")
                        local id = work and work:call("get_itemID")
                        if id then
                            recipe_state_at_buy = { id = id, recipes = recipe_count(id), history = has_history(id) }
                            debug_log(string.format("achat : %s, recettes %d, historique %s", tostring(id),
                                recipe_state_at_buy.recipes, tostring(recipe_state_at_buy.history)))
                        end
                    end)
                    -- Début d'un achat : si c'est une Valise-check, l'agrandissement sera refusé.
                    pcall(function()
                        local shop = sdk.to_managed_object(args[2])
                        local work = shop:call("get_currentItemWork")
                        local id = work and work:call("get_itemID")
                        if id == VALISE_ITEM_ID and next_shop_location(id) then
                            local _, inv = get_active_inventory()
                            valise_level_before = inv and inv:call("get_extendLevel")
                            debug_log("valise : achat d'une Valise-check, niveau de mallette relevé : "
                                .. tostring(valise_level_before))
                        end
                    end)
                end
                pcall(function()
                    local shop = sdk.to_managed_object(args[2])
                    local unit = shop:call("get_buyTargetUnit")
                    local picked = nil
                    if name == "decideBuyItem" then picked = get_item_id_from_core(sdk.to_managed_object(args[3])) end
                    debug_log(string.format("boutique : %s, cible itemID=%s prix=%s, itemCore=%s", name,
                        tostring(unit and unit:call("get_itemID")), tostring(unit and unit:call("get_price")), tostring(picked)))
                    local loc = picked and next_shop_location(picked)
                    local parcel_i = picked and not loc and parcel_index_of(picked)
                    if parcel_i then
                        -- Achat normal (0 Lei pour l'article du colis, ou rachat au prix du jeu) :
                        -- l'objet est donné par le jeu, on le retire du colis.
                        debug_log("boutique : colis récupéré : " .. state.parcel[parcel_i])
                        add_message(string.format(tr("Colis : %s récupéré chez le Duc", "Parcel: %s collected at the Duke"), state.parcel[parcel_i]))
                        table.remove(state.parcel, parcel_i)
                        save_state()
                    end
                    if loc then
                        -- Test en jeu du 2026-09-26 : bloquer decideBuyItem n'empêchait ni le
                        -- débit ni le don de l'objet (objets en double, prix payé 2 fois).
                        -- On laisse donc l'achat se faire, puis l'objet acheté est retiré comme
                        -- un objet ramassé, et le check part.
                        local item_def = item_by_name[loc.original_item]
                        table.insert(vanilla_removals, {
                            item_id = picked,
                            weapon = item_def and item_def.type == "Weapon",
                            equipped_before = equipped_before,
                            -- 3e test du 2026-09-26 : l'objet acheté est déjà ajouté dès buyItem,
                            -- AVANT decideBuyItem (2 avant / 2 après, rien retiré). On prend donc la
                            -- quantité relevée à la frame précédente, avant le clic.
                            before = quantities_before[picked] or inventory_quantity(picked) or 0,
                            due = os.clock() + REMOVAL_DELAY_SECONDS,
                            -- 2e test du 2026-09-26 : pour un objet déjà possédé, le jeu n'a ni
                            -- débité ni donné l'objet. On vérifie donc les deux après coup.
                            shop_price = loc.price or 0,
                            unit_price = shop_unit_price(picked),
                            restore_level = picked == VALISE_ITEM_ID and valise_level_before or nil,
                            craft_before = craft_before_buy,
                            recipe_before = recipe_state_at_buy and recipe_state_at_buy.id == picked
                                and recipe_state_at_buy or nil,
                            money_before = get_money(),
                        })
                        table.insert(shop_purchases, loc)
                        shop_ui.bought[loc.key] = true
                        debug_log("boutique : achat-check " .. loc.name .. " (objet acheté retiré dans 2 s)")
                        debug_log("boutique : mallette AVANT achat : " .. inventory_dump())
                    end
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                if skip_result then
                    skip_result = false
                    return sdk.to_ptr(1) -- "achat fait" pour l'interface
                end
                return retval
            end)
        end
    end
    local collect = def:get_method("collectBuyUnits")
    if collect then
        sdk.hook(collect, function(args)
            shop_being_collected = sdk.to_managed_object(args[2])
            open_shop, open_shop_seen = shop_being_collected, os.clock()
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval)
            local shop = shop_being_collected
            shop_being_collected = nil
            if shop_experiment and shop then
                local ok, err = pcall(add_test_shop_unit, shop)
                if not ok then debug_log("boutique : échec ajout article de test : " .. tostring(err)) end
            end
            if shop then
                local ok, err = pcall(hide_done_shop_units, shop)
                if not ok then debug_log("boutique : échec masquage : " .. tostring(err)) end
                ok, err = pcall(hide_unreceived_rebuys, shop)
                if not ok then debug_log("boutique : échec masquage rachats : " .. tostring(err)) end
                ok, err = pcall(adjust_valise_unit, shop)
                if not ok then debug_log("boutique : échec masquage : " .. tostring(err)) end
                ok, err = pcall(add_ap_shop_units, shop)
                if not ok then debug_log("boutique : échec ajout articles AP : " .. tostring(err)) end
                ok, err = pcall(regroup_ap_units, shop)
                if not ok then debug_log("boutique : échec regroupement dans Autres : " .. tostring(err)) end
                ok, err = pcall(apply_shop_swaps, shop)
                if not ok then debug_log("boutique : échec affichage des objets AP : " .. tostring(err)) end
                -- Diagnostic des onglets (2026-09-26) : numéro d'onglet et ItemID de la liste,
                -- noté seulement quand l'onglet change.
                pcall(function()
                    local tab = shop:call("get_lastCategoryIndex")
                    if tab ~= shop_ui.last_tab then
                        shop_ui.last_tab = tab
                        local ids = {}
                        local units = shop:call("get_buyUnits")
                        for i = 0, units:call("get_Count") - 1 do
                            ids[#ids + 1] = tostring(units:call("get_Item", i):call("get_itemID"))
                        end
                        debug_log(string.format("boutique : onglet %s, %d articles : %s", tostring(tab), #ids, table.concat(ids, " ")))
                    end
                end)
            end
            return retval
        end)
    end

    -- Jamais "épuisé / acquis" pour un article-check pas encore fait ni pour le colis.
    local sold_out = K.SHOP_HOOK_SOLD_OUT and def:get_method("isSoldOutByUnit")
    if sold_out then
        local force_available = false
        sdk.hook(sold_out, function(args)
            first_call("GUIShopBuy.isSoldOutByUnit")
            force_available = false
            pcall(function()
                local unit = sdk.to_managed_object(args[3])
                force_available = shop_ui.loc_of(unit) ~= nil
                    or (unit:call("get_price") == 0 and parcel_index_of(unit_item_id(unit)) ~= nil)
            end)
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval)
            if force_available then
                force_available = false
                return sdk.to_ptr(0)
            end
            return retval
        end)
    end

    -- Achat refusé par le jeu (objet déjà possédé) : autorisé pour un article-check si on a
    -- l'argent (le jeu débite le prix lui-même).
    local can_buy = K.SHOP_HOOK_CAN_BUY and def:get_method("canBuyItem")
    if can_buy then
        local shop_obj = nil
        sdk.hook(can_buy, function(args)
            first_call("GUIShopBuy.canBuyItem")
            shop_obj = sdk.to_managed_object(args[2])
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval)
            local result = retval
            pcall(function()
                local shop = shop_obj
                shop_obj = nil
                local unit = shop and shop_ui.selected(shop)
                local loc = unit and shop_ui.loc_of(unit)
                if not loc then return end
                local status_def = sdk.find_type_definition("app.GUIShopBuy.BuyStatus")
                local can = status_def:get_field("Can"):get_data(nil)
                local money = get_money() or 0
                if money >= (loc.price or 0) and sdk.to_int64(retval) ~= can:get_address() then
                    debug_log("boutique : achat autorisé (article-check déjà possédé) : " .. loc.name)
                    result = sdk.to_ptr(can:get_address())
                end
            end)
            return result
        end)
    end

    -- Nom "[AP] ..." de l'article sélectionné. Freeze du 2026-09-26 juste après un rechargement
    -- avec un hook sur onLateUpdate (appelé à chaque frame) : on ne réécrit le nom qu'au
    -- changement de sélection.
    for _, name in ipairs({ "scrollGridSelectionChanged", "scrollListSelectionChanged" }) do
        local method = K.SHOP_HOOK_RENAME and def:get_method(name)
        if method then
            local shop_obj = nil
            sdk.hook(method, function(args)
                shop_obj = sdk.to_managed_object(args[2])
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                first_call("GUIShopBuy." .. name)
                pcall(function()
                    local shop = shop_obj
                    shop_obj = nil
                    local work = shop and shop:call("get_currentItemWork")
                    local label = work and ap_shop_label(work:call("get_itemID"))
                    if label then shop:call("get_itemNameText"):call("set_Message", label) end
                end)
                return retval
            end)
        end
    end
end
install_shop_hooks()

local zone_lines = {}     -- textes prêts à afficher (calculés dans la boucle du jeu)
local current_zone_line = nil
local last_zone_stats = 0

local current_room_line = nil

-- Salles des emplacements, apprises en jeu (demande du joueur, 2026-09-26) : 288 locations sur
-- 456 n'avaient pas de salle dans les relevés (château entier, une partie du village). À la
-- 1re visite d'une salle, on relit UNE fois les ItemSpawnInfo chargés (MapRoomNames) ; le
-- résultat est gardé dans room_cache.json pour ne jamais relire une salle déjà vue.
local ROOM_CACHE_FILE = MOD_NAME .. "/room_cache.json"
local room_cache = { guids = {}, scanned = {} }
local last_room_scan = -math.huge

do
    local ok, saved = pcall(json.load_file, ROOM_CACHE_FILE)
    if ok and type(saved) == "table" then
        room_cache.guids = saved.guids or {}
        room_cache.scanned = saved.scanned or {}
        room_cache.names = saved.names or {} -- salles apprises par la position (2026-10-08)
    end
    for guid, hash in pairs(room_cache.guids) do
        local loc = location_by_guid[guid]
        if loc and not loc.room_hash then loc.room_hash = hash end
    end
end

-- Bug du 2026-09-27 (vignes du château) : la salle a été relue alors que la plante était déjà
-- ramassée, 0 emplacement trouvé, et la salle notée "vue" pour toujours ("pas de checks").
-- Désormais : une salle n'est notée vue que si la lecture a trouvé quelque chose (sinon jusqu'à
-- 5 essais, espacés de 10 s), et chaque check ramassé est rattaché à la salle où on est.
room_cache.tries = {}
local function learn_rooms(current_hash)
    local key = tostring(current_hash)
    if #picked_locations.for_rooms > 0 then
        for _, loc in ipairs(picked_locations.for_rooms) do
            if loc.guid and not loc.room_hash then
                loc.room_hash = current_hash
                room_cache.guids[loc.guid] = current_hash
                debug_log("salles : " .. loc.name .. " rattaché à la salle " .. key .. " (ramassé ici)")
            end
        end
        picked_locations.for_rooms = {}
        pcall(json.dump_file, ROOM_CACHE_FILE, room_cache)
    end
    if room_cache.scanned[key] or (room_cache.tries[key] or 0) >= 5 or os.clock() - last_room_scan < 10.0 then return end
    last_room_scan = os.clock()
    room_cache.tries[key] = (room_cache.tries[key] or 0) + 1
    local learned = 0
    for _, spawn_info in ipairs(find_all_components("app.Spawn.ItemSpawnInfo")) do
        pcall(function()
            local rooms = spawn_info:get_field("MapRoomNames")
            if not rooms or rooms:get_size() == 0 then return end
            local guid = tostring(spawn_info:call("get_myGUID"):call("ToString()"))
            local loc = location_by_guid[guid]
            if loc and not loc.room_hash then
                local hash = rooms:get_element(0):get_field("MapRoomNameHash")
                loc.room_hash = hash
                room_cache.guids[guid] = hash
                learned = learned + 1
            end
        end)
    end
    if learned > 0 then room_cache.scanned[key] = true end
    local tries = room_cache.tries
    room_cache.tries = nil -- pas dans le fichier
    pcall(json.dump_file, ROOM_CACHE_FILE, room_cache)
    room_cache.tries = tries
    debug_log(string.format("salles : %d emplacement(s) rattaché(s) à leur salle (salle %s, essai %d)", learned, key, tries[key]))
end

local function update_zone_stats()
    if os.clock() - last_zone_stats < 1.0 then return end
    last_zone_stats = os.clock()
    shop_ui.has_knife = (inventory_quantity(2292458104) or 0) > 0 -- couteau (voir shop_ui.other_chapter)
    game_difficulty = read_game_difficulty()
    load_difficulty_names()

    -- Salle actuelle, et checks de cette salle (locations portant son room_hash).
    current_room_line = nil
    shop_ui.hud_room = nil
    pcall(function()
        local unit = sdk.get_managed_singleton("app.MapManager"):call("get_currentRoomUnit")
        if not unit then return end
        local hash = unit:get_field("NameHash")
        local name = guid_text(unit:get_field("RoomNameGUID"))
        -- Noms incomplets ("Château Dimitrescu - 0", 2026-09-27) : détails notés une fois par salle.
        shop_ui.rooms_logged = shop_ui.rooms_logged or {}
        if not shop_ui.rooms_logged[hash] then
            shop_ui.rooms_logged[hash] = true
            local details = {}
            for _, f in ipairs({ "FloorNo", "ZoneTextName", "ZonePanelName", "ZoneID", "MapID" }) do
                pcall(function() details[#details + 1] = f .. "=" .. tostring(unit:get_field(f)) end)
            end
            pcall(function() details[#details + 1] = "AreaNameID=" .. tostring(unit:get_field("AreaNameID")) end)
            debug_log(string.format("salle %s : nom %q ; %s", tostring(hash), tostring(name), table.concat(details, " ")))
        end
        if not name or name == "" then return end
        learn_rooms(hash)
        -- Salle apprise par la POSITION (2026-10-08 : checks sans salle dans les données, ou
        -- rattachés à la salle où l'on était au moment du ramassage) : un check à moins de 4 m
        -- (3 m en hauteur) du joueur est dans la salle actuelle ; gardé dans room_cache.names.
        room_cache.names = room_cache.names or {}
        local ppos = nil
        pcall(function()
            local pl = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
            local v = pl:call("get_Transform"):call("get_Position")
            ppos = { v.x, v.y, v.z }
        end)
        if ppos then
            local changed = false
            for guid, loc in pairs(location_by_guid) do
                local lp = loc.item_position
                if lp and room_cache.names[guid] ~= name and math.abs(lp[2] - ppos[2]) < 3
                        and (lp[1] - ppos[1]) ^ 2 + (lp[3] - ppos[3]) ^ 2 < 16 then
                    room_cache.names[guid] = name
                    changed = true
                end
            end
            if changed and os.clock() >= (shop_ui.next_room_save or 0) then
                shop_ui.next_room_save = os.clock() + 10
                local tries = room_cache.tries
                room_cache.tries = nil
                pcall(json.dump_file, ROOM_CACHE_FILE, room_cache)
                room_cache.tries = tries
            end
        end
        local done, total = 0, 0
        shop_ui.room_list = {} -- checks comptés dans la salle (bouton des outils de dev)
        for guid, loc in pairs(location_by_guid) do
            -- même salle = même numéro OU même nom (2026-10-08 : deux salles « Village - Champ en
            -- jachère », checks rattachés à l'autre -> « aucun check »)
            local learned_name = room_cache.names[guid]
            -- nom de salle seulement s'il a été appris par la position (2026-10-08 : deux salles
            -- « Passage souterrain » distantes, la Clé ailée #001 du pont comptée ici) ; sinon le
            -- numéro exact
            local same = learned_name == name or (not learned_name and loc.room_hash == hash)
            if same and not (loc.key_item_location and not location_id_by_guid[guid]) then
                total = total + 1
                shop_ui.room_list[#shop_ui.room_list + 1] = string.format("%s (%s, salle %s)", loc.name,
                    learned_name and "position" or "numéro", tostring(learned_name or loc.room_hash))
                local id = location_id_by_guid[guid]
                if id and checked_ids[id] then done = done + 1 end
            end
        end
        shop_ui.hud_room = { name = name, done = done, total = total }
        if total == 0 then
            current_room_line = string.format(tr("Salle %s : aucun check connu dans cette salle", "Room %s: no known checks in this room"), name)
        elseif done == total then
            current_room_line = string.format(tr("Salle %s : %d / %d, tous les checks sont récupérés", "Room %s: %d / %d, all checks collected"), name, done, total)
        else
            current_room_line = string.format(tr("Salle %s : %d / %d checks", "Room %s: %d / %d checks"), name, done, total)
        end
    end)
    local stats, order = {}, {}
    for guid, loc in pairs(location_by_guid) do
        local zone = loc.region
        if loc.key_item_location and not location_id_by_guid[guid] then zone = nil end
        if zone and not stats[zone] then stats[zone] = { done = 0, total = 0 }; order[#order + 1] = zone end
        if zone then
            stats[zone].total = stats[zone].total + 1
            local id = location_id_by_guid[guid]
            if id and checked_ids[id] then stats[zone].done = stats[zone].done + 1 end
        end
    end
    table.sort(order)
    local lines = {}
    for _, zone in ipairs(order) do
        lines[#lines + 1] = string.format("%s : %d / %d", zone, stats[zone].done, stats[zone].total)
    end
    zone_lines = lines
    shop_ui.hud_zone = current_zone and stats[current_zone] and
        { name = current_zone, done = stats[current_zone].done, total = stats[current_zone].total } or nil
    if current_zone then
        local st = stats[current_zone]
        current_zone_line = st
            and string.format(tr("Zone %s : %d / %d checks", "Area %s: %d / %d checks"), current_zone, st.done, st.total)
            or string.format(tr("Zone %s : pas encore de checks dans cette version", "Area %s: no checks in this version yet"), current_zone)
    else
        current_zone_line = nil
    end
    -- Menu du Duc ouvert : zone = toute la boutique, salle = checks achetables maintenant.
    if shop_is_open() then
        local st = stats["Boutique du Duc"]
        if st then
            current_zone_line = string.format(tr("Zone Boutique du Duc : %d / %d checks", "Area Duke's shop: %d / %d checks"), st.done, st.total)
        end
        -- Articles-checks proposés, tous onglets confondus (mémorisés par regroup_ap_units) : la
        -- liste du jeu ne contient que l'onglet ouvert ("Duc : 0 / 4" au lieu de 6).
        local available = 0
        for id in pairs(shop_ui.offered) do
            if next_shop_location(id) then available = available + 1 end
        end
        if valise_status() then available = available + 1 end
        -- a / b : a = articles-checks déjà achetés (hors plats), b = achetés + à acheter maintenant.
        local bought = 0
        for _, list in pairs(shop_locations_by_item) do
            for _, loc in ipairs(list) do
                if location_done(loc) == true then bought = bought + 1 end
            end
        end
        current_room_line = string.format(tr("Duc : %d / %d checks (%d à acheter maintenant)", "Duke: %d / %d checks (%d to buy now)"),
            bought, bought + available, available)
    end
end

---------------------------------------------------------------------------
-- Bandeau et marqueurs (2026-10-08, demande du joueur : comme le mod de RE4)
---------------------------------------------------------------------------
-- Bandeau en haut à droite : « Ethan | zone | salle | x / y checks », « AP : connecté (slot) »,
-- « Objet de progression à proximité » (un de mes checks pas faits, à portée des marqueurs, contient
-- un objet de progression), puis les messages récents. Rien sans connexion ou en mauvaise
-- difficulté (fenêtres d'avertissement à la place, shop_ui.notice).
-- Marqueurs dans le monde (draw.world_text) au-dessus de chaque check pas fait, à portée :
--   détail 1 : [AP] 7m          détail 2 : + salle (défaut)          détail 3 : + objet d'origine
--   « +3m » / « -3m » quand le check est nettement plus haut / plus bas.
-- Calcul dans la boucle du jeu toutes les 0,25 s (position du joueur, salles) ; l'affichage ne fait
-- que dessiner la liste prête. Réglages gardés dans hud_prefs.json (menu REFramework, « Guidage »).
-- Couleurs (thème doré du mod) : texte blanc ; check d'un autre chapitre : gris transparent ;
-- check hinté : rose « [Hint] » (rempli par l'onglet Hints, étape 3).
shop_ui.hud = { markers = {}, next_update = 0, progression_near = false, hinted = {},
    PREFS_FILE = MOD_NAME .. "/hud_prefs.json",
    prefs = { markers = true, distance = 20, detail = 2, other_chapters = false, window = true, tab = 1,
        accent = { 0.784, 0.659, 0.416 }, bar = { 0.784, 0.659, 0.416 } } }
-- Dans une fonction : un bloc do...end au niveau du fichier ajoute ses variables (et celles de la
-- boucle) aux 200 locales maximum du fichier, déjà presque toutes prises (erreur au chargement du
-- 2026-10-08, que check_lua.py ne voyait pas).
function shop_ui.hud.load_prefs()
    local ok, saved = pcall(json.load_file, shop_ui.hud.PREFS_FILE)
    if ok and type(saved) == "table" then
        for k, v in pairs(saved) do
            if shop_ui.hud.prefs[k] ~= nil and type(v) == type(shop_ui.hud.prefs[k]) then shop_ui.hud.prefs[k] = v end
        end
    end
end
shop_ui.hud.load_prefs()
shop_ui.hud.COLOR_TEXT = 0xFFFFFFFF
shop_ui.hud.COLOR_OTHER = 0x99AAAAAA
shop_ui.hud.COLOR_HINT = 0xFFD08BE8   -- #E88BD0 (ABGR)
shop_ui.hud.COLOR_GOLD = 0xFF5AC8F0   -- or du mod (#F0C85A, ABGR)
shop_ui.hud.COLOR_GREEN = 0xFF7FFF7F

function shop_ui.hud.save_prefs()
    pcall(json.dump_file, shop_ui.hud.PREFS_FILE, shop_ui.hud.prefs)
end

-- nom court d'une salle : « Château Dimitrescu - Cave à vin » -> « Cave à vin ». Certaines salles
-- n'ont qu'un numéro d'étage (« Château Dimitrescu - 0 », « Usine d'Heisenberg - -3B ») : affiché en
-- clair (2026-10-08 : le joueur voyait « [AP] 7m | 0 »).
function shop_ui.hud.short_room(name)
    if not name then return nil end
    local part = name:match(" %- (.+)$") or name
    local minus, num, suffix = part:match("^(%-?)(%d+)(%a?)$")
    if not num then return part end
    num = tonumber(num)
    if minus == "-" then
        return tr("Sous-sol " .. num .. suffix, (suffix ~= "" and "M" or "") .. "B" .. num)
    end
    if num == 0 then return tr("Rez-de-chaussée", "1F") end
    return tr(num == 1 and "1er étage" or (num .. "e étage"), (num + 1) .. "F")
end

-- nom affiché d'une zone de l'apworld (les noms des données n'ont pas d'accents)
shop_ui.hud.ZONE_NAMES = {
    ["Chateau Dimitrescu"] = { "Château Dimitrescu", "Castle Dimitrescu" },
    ["Maison Beneviento"] = { "Maison Beneviento", "House Beneviento" },
    ["Reservoir"] = { "Réservoir", "Reservoir" },
    ["Usine Heisenberg"] = { "Usine d'Heisenberg", "Heisenberg's Factory" },
    ["Boutique du Duc"] = { "Boutique du Duc", "Duke's Shop" },
    ["Fin du jeu"] = { "Fin du jeu", "Endgame" },
}
function shop_ui.hud.zone_name(zone)
    local pair = shop_ui.hud.ZONE_NAMES[zone]
    return pair and tr(pair[1], pair[2]) or zone
end

function shop_ui.hud.update()
    local h = shop_ui.hud
    if os.clock() < h.next_update then return end
    h.next_update = os.clock() + 0.25
    local markers, near, nearby = {}, false, {}
    if is_in_game() and net.is_connected() and not wrong_difficulty() then
        local ppos = nil
        pcall(function()
            local pl = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
            local v = pl:call("get_Transform"):call("get_Position")
            ppos = { v.x, v.y, v.z }
        end)
        if ppos then
            local max_d2 = h.prefs.distance * h.prefs.distance
            for guid, loc in pairs(location_by_guid) do
                local id = location_id_by_guid[guid]
                local pos = loc.item_position
                if id and pos and not checked_ids[id] then
                    local dx, dy, dz = pos[1] - ppos[1], pos[2] - ppos[2], pos[3] - ppos[3]
                    local d2 = dx * dx + dy * dy + dz * dz
                    local other = shop_ui.other_chapter(loc)
                    if d2 <= 100 and not other then
                        nearby[#nearby + 1] = { guid = guid, name = loc.name, d = math.sqrt(d2) }
                    end
                    if h.prefs.markers and d2 <= max_d2 and (not other or h.prefs.other_chapters) then
                        local scout = scouted_items[id]
                        if scout and (scout.flags or 0) & 1 == 1 and not other then near = true end
                        local parts = { string.format("[AP] %dm", math.floor(math.sqrt(d2) + 0.5)) }
                        if math.abs(dy) >= 2 then parts[1] = parts[1] .. string.format(" %+dm", math.floor(dy + 0.5)) end
                        if h.prefs.detail >= 2 then
                            local room = room_cache.names[guid] or (loc.room_hash and room_name(loc.room_hash))
                            if room then parts[#parts + 1] = h.short_room(room) end
                        end
                        if h.prefs.detail >= 3 and loc.original_item then
                            parts[#parts + 1] = '"' .. i18n.item(loc.original_item) .. '"'
                        end
                        local text = table.concat(parts, " | ")
                        local col = other and h.COLOR_OTHER or h.COLOR_TEXT
                        if h.hinted[id] then text, col = "[Hint] " .. text, h.COLOR_HINT end
                        markers[#markers + 1] = { pos[1], pos[2] + 0.35, pos[3], text, col }
                    end
                end
            end
        end
    end
    table.sort(nearby, function(a, b) return a.d < b.d end)
    h.markers, h.progression_near, h.nearby = markers, near, nearby
end

-- Affichage (re.on_frame) : marqueurs prêts, aucun appel au jeu.
function shop_ui.hud.draw_markers()
    for _, m in ipairs(shop_ui.hud.markers) do
        draw.world_text(m[4], Vector3f.new(m[1], m[2], m[3]), m[5])
    end
end

-- Lignes du bandeau (en haut à droite)
function shop_ui.hud.banner_lines()
    local h = shop_ui.hud
    local first = { "Ethan" }
    local z, r = shop_ui.hud_zone, shop_ui.hud_room
    if z then first[#first + 1] = h.zone_name(z.name) end
    if r and r.total > 0 then
        first[#first + 1] = h.short_room(r.name)
        first[#first + 1] = string.format(tr("%d / %d checks", "%d / %d checks"), r.done, r.total)
    elseif z then
        first[#first + 1] = string.format(tr("%d / %d checks", "%d / %d checks"), z.done, z.total)
    end
    local lines = { { table.concat(first, " | "), h.COLOR_TEXT },
        { string.format(tr("AP : connecté (%s)", "AP: connected (%s)"), tostring(net.slot or "?")), h.COLOR_GREEN } }
    if h.progression_near then
        lines[#lines + 1] = { tr("Objet de progression à proximité", "Progression item nearby"), h.COLOR_GOLD }
    end
    local jam = shop_ui.traps and shop_ui.traps.jam_until - os.clock() or 0
    if jam > 0 then
        lines[#lines + 1] = { string.format(tr("Armes bloquées : %d s", "Weapons jammed: %d s"), math.ceil(jam)), 0xFF4040FF }
    end
    return lines
end

-- Réglages (menu REFramework, en attendant la fenêtre du mod)
function shop_ui.hud.draw_ui()
    local p, changed, v = shop_ui.hud.prefs, false, nil
    imgui.text_colored(tr("Marqueurs dans le monde", "World markers"), shop_ui.menu.ACCENT)
    imgui.text(tr("Les checks pas encore faits affichent « [AP] » et leur distance au-dessus de l'objet.",
        "Unchecked spots show \"[AP]\" and their distance above the item."))
    changed, v = imgui.checkbox(tr("Afficher les marqueurs des checks", "Show check markers"), p.markers)
    if changed then p.markers = v; shop_ui.hud.save_prefs() end
    changed, v = imgui.slider_int(tr("Distance d'affichage (m)", "Display distance (m)"), p.distance, 5, 60)
    if changed then p.distance = v; shop_ui.hud.save_prefs() end
    local labels = { tr("1 : [AP] et distance", "1: [AP] and distance"), tr("2 : + salle", "2: + room"),
        tr("3 : + objet d'origine du jeu", "3: + the game's original item") }
    changed, v = imgui.combo(tr("Détail des marqueurs", "Marker detail"), p.detail, labels)
    if changed then p.detail = v; shop_ui.hud.save_prefs() end
    changed, v = imgui.checkbox(tr("Montrer aussi les checks des autres chapitres (grisés)",
        "Also show checks from other chapters (greyed)"), p.other_chapters)
    if changed then p.other_chapters = v; shop_ui.hud.save_prefs() end
end

---------------------------------------------------------------------------
-- Pièges (2026-10-08, idées du joueur)
---------------------------------------------------------------------------
-- Objets « Piège : … » (type Trap, champ trap dans items.json), donnés comme les autres objets
-- (donc seulement en jeu, jamais pendant un menu ou une présentation). Effets :
--   bankrupt  : -1000 Lei (jamais sous 0)
--   screamer  : cri de Bela + flash rouge d'une demi-seconde
--   jam       : arme rangée, aucune mise en main pendant 15 s sauf les soins (hook requestUseItem)
--   damage    : -30 % de la vie actuelle, jamais mortel (vie max mesurée par un retrait de 1 PV)
--   empty_mag : balles chargées de l'arme en main (InstanceWork.IncludeStackSize) remises à 0
-- Rire de Dimitrescu à la réception (cri de Bela pour le screamer).
shop_ui.traps = { jam_until = 0, flash_until = 0, JAM_SECONDS = 15, LEI = 1000, DAMAGE = 0.30 }
K.traps = shop_ui.traps -- pour apply_item, écrit avant la déclaration de shop_ui (bug du 2026-10-08)
shop_ui.traps.NAMES = { bankrupt = { "Faillite ! La banque te prend 1000 Lei", "Bankruptcy! The bank takes 1000 Lei" },
    screamer = { "Screamer !", "Screamer!" },
    jam = { "Armes bloquées pendant 15 secondes !", "Weapons jammed for 15 seconds!" },
    damage = { "Dégâts ! Tu perds 30 % de ta vie", "Damage! You lose 30% of your health" },
    empty_mag = { "Chargeur vidé ! Recharge ton arme", "Empty magazine! Reload your weapon" } }

-- objet de soin (toujours utilisable pendant « Armes bloquées »)
function shop_ui.traps.is_heal(item_id)
    if not item_id then return false end
    if not shop_ui.traps.heal_ids then
        shop_ui.traps.heal_ids = {}
        for _, it in ipairs(items) do
            if it.type == "Recovery" and it.game_item_id then shop_ui.traps.heal_ids[it.game_item_id] = true end
        end
    end
    return shop_ui.traps.heal_ids[item_id] == true
end

function shop_ui.traps.player_order()
    return sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayerOrder"):call(nil)
end

function shop_ui.traps.apply(item)
    local t = shop_ui.traps
    local key = item.trap or ""
    local voice = key == "screamer" and shop_ui.sound.AP.TRAP_SCREAM or shop_ui.sound.AP.TRAP_LAUGH
    pcall(function()
        local id = shop_ui.sound.voice_id(voice)
        if id then shop_ui.sound.play_ap(id) end
    end)
    local ok, err = pcall(t["do_" .. key])
    debug_log(string.format("piège reçu : %s -> %s", key, ok and "fait" or ("ERREUR " .. tostring(err))))
    local name = t.NAMES[key]
    if name then add_message(tr("Piège ! ", "Trap! ") .. tr(name[1], name[2])) end
    shop_ui.popup.show(tr("Piège !", "Trap!"), { name and tr(name[1], name[2]) or key }, 4)
    return true -- un piège raté n'est jamais redonné (pas de blocage de la file)
end

function shop_ui.traps.do_bankrupt()
    local money = get_money() or 0
    local take = math.min(shop_ui.traps.LEI, money)
    if take > 0 then give_money(-take) end
    debug_log(string.format("piège faillite : %d Lei -> %d", money, money - take))
end

function shop_ui.traps.do_screamer()
    shop_ui.traps.flash_until = os.clock() + 0.6
end

function shop_ui.traps.do_jam()
    local t = shop_ui.traps
    t.jam_until = os.clock() + t.JAM_SECONDS
    pcall(function() t.player_order():call("requestRemoveWeapon", false) end)
end

function shop_ui.traps.do_damage()
    local order = shop_ui.traps.player_order()
    local status = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayerStatus"):call(nil)
    local r0 = status:call("get_healthRate")
    order:call("subHealth", 1.0, false)
    local r1 = status:call("get_healthRate")
    if not (r0 and r1 and r0 > r1) then
        debug_log(string.format("piège dégâts : vie max inconnue (taux %s -> %s), rien de plus", tostring(r0), tostring(r1)))
        return
    end
    local max = 1.0 / (r0 - r1)
    local current = r1 * max
    local sub = math.min(current * shop_ui.traps.DAMAGE, current - 1)
    if sub > 0 then order:call("subHealth", sub, false) end
    debug_log(string.format("piège dégâts : vie %.0f / %.0f, retiré %.0f, taux %.2f", current, max, sub, status:call("get_healthRate")))
end

function shop_ui.traps.do_empty_mag()
    -- Arme en main : contrôleur d'équipement du joueur (get_equipped_weapon_id). InstanceWork.isUsing
    -- n'est jamais vrai (relevé du 2026-10-08) ; les balles chargées sont IncludeStackSize de la
    -- fiche de l'arme (5 = « 5 / ... » affiché en jeu).
    local weapon = get_equipped_weapon_id()
    local _, inv = get_active_inventory()
    local list = inv:call("get_items")
    local emptied = 0
    for i = 0, list:call("get_Count") - 1 do
        local work = list:call("get_Item", i):call("get_work")
        local loaded = work:get_field("IncludeStackSize") or 0
        if weapon and work:call("get_itemID") == weapon and loaded > 0 then
            work:set_field("IncludeStackSize", 0)
            emptied = emptied + 1
            debug_log(string.format("piège chargeur vidé : arme %s, %d balle(s) retirée(s)", tostring(weapon), loaded))
        end
    end
    -- compteur interne de l'arme (au cas où l'affichage en dépend), noté pour le diagnostic
    pcall(function()
        local list_w = get_player_equip():call("get_EquipWeaponList")
        for i = 0, list_w:call("get_Count") - 1 do
            local w = list_w:call("get_Item", i)
            local wid = nil
            pcall(function() wid = w:call("get_itemID") end)
            local usable = nil
            pcall(function() usable = w:get_field("<usableBulletNum>k__BackingField") end)
            if usable ~= nil then
                debug_log(string.format("piège chargeur vidé : WeaponCore %s usableBulletNum=%s", tostring(wid), tostring(usable)))
            end
        end
    end)
    if emptied == 0 then
        debug_log(string.format("piège chargeur vidé : arme en main %s, rien à vider", tostring(weapon)))
    end
end

-- flash rouge plein écran (re.on_frame, aucun appel au jeu)
function shop_ui.traps.draw_flash()
    local left = shop_ui.traps.flash_until - os.clock()
    if left <= 0 then return end
    local w, h = 1920, 1080
    pcall(function()
        local size = imgui.get_display_size()
        if size and size.x > 0 then w, h = size.x, size.y end
    end)
    local alpha = math.floor(math.min(1, left / 0.6) * 170)
    draw.filled_rect(0, 0, w, h, (alpha << 24) | 0x000010C0)
end

---------------------------------------------------------------------------
-- Connexion (paramètres mémorisés dans reframework/data/re_village_ap_client/connection.json)
---------------------------------------------------------------------------

local CONNECTION_FILE = MOD_NAME .. "/connection.json"
local conn = { host = "localhost:38281", slot = "", password = "", auto = false }
do
    local ok, saved = pcall(json.load_file, CONNECTION_FILE)
    if ok and type(saved) == "table" then
        conn.host = saved.host or conn.host
        conn.slot = saved.slot or conn.slot
        conn.password = saved.password or conn.password
        conn.auto = saved.auto == true
    end
end

---------------------------------------------------------------------------
-- Boucle principale et affichage
---------------------------------------------------------------------------

-- Tout ce qui touche au jeu ou au réseau se fait ICI, dans la boucle du jeu. Les boutons du
-- menu (fil d'affichage) ne font que poser une demande, exécutée au tour suivant.
local requests = { connect = false, disconnect = false, scan = false, shop = false, catalog = false, recipes = false, give = nil, money = false, knife = false }
local net_status = "déconnecté" -- lu par l'affichage, calculé ici

-- Reconnexion automatique (Reset scripts, relance du jeu) si on était connecté la dernière
-- fois, sauf déconnexion volontaire. Ajouté le 2026-09-25 : un Reset scripts coupait la
-- connexion sans prévenir.
if conn.auto and conn.slot ~= "" then requests.connect = true end
local last_heartbeat = 0

-- Fenêtre au centre de l'écran (2026-10-07, demande du joueur : comme l'Archipelago de RE4, au
-- lieu du message en haut à gauche). shop_ui.popup.show(titre, lignes, durée) ; dessinée par
-- re.on_frame. Panneau d'information sans bouton (pas de souris en jeu). Styles imgui protégés :
-- une fonction absente de cette version de REFramework est simplement ignorée.
shop_ui.popup = { title = nil, lines = {}, until_t = 0 }
function shop_ui.popup.show(title, lines, seconds)
    shop_ui.popup.title, shop_ui.popup.lines = title, lines
    shop_ui.popup.anywhere, shop_ui.popup.button = false, nil
    shop_ui.popup.until_t = os.clock() + (seconds or 5)
end
-- Fenêtre BLOQUANTE (2026-10-07, demande du joueur) : jeu figé (via.Scene.TimeScale = 0), curseur
-- affiché (via.hid.Mouse.ShowCursor), bouton « J'ai compris, je vais le faire » ; aussi Entrée,
-- Espace ou le bouton de validation de la manette (touche relâchée puis appuyée, pour ne pas
-- fermer avec une touche déjà enfoncée). Fermeture : jeu remis à sa vitesse, curseur rendu.
-- Sécurités : fermeture seule après 120 s, et au rechargement des scripts.
-- Boîte de dialogue DU JEU (2026-10-07, demande du joueur : un vrai menu, comme l'Archipelago de
-- RE4 ; la fenêtre imgui ne reçoit pas la souris du jeu). app.DialogManager.openDialog(
-- app.DialogManager.Parameter{ dialogID = hash d'une boîte existante (app.DialogDefine.<nom>),
-- work = app.GUIDialog.Parameter{ titleMsg, bodyMsg, button1Msg : TEXTE BRUT } }). Fermée :
-- work.isClosed. Boîte à réutiliser à trouver en jeu (outils de dev > « Boîte de dialogue du
-- jeu »). ENABLED = vrai une fois validée : les murs l'utilisent à la place de la fenêtre imgui.
shop_ui.dialog = {
    ENABLED = true, -- VALIDÉ en jeu le 2026-10-07 (NoticeGameSystem00 : notre texte, jeu en pause, bouton OK)
    NAME = "NoticeGameSystem00",
    CANDIDATES = { "NoticeGameSystem00", "NoticeGameSystem01", "SaveDone", "InventoryNoEmpty",
        "PopUp_Inventory_Close", "TEST" },
    selected = 1,
}
-- numéro d'une boîte : app.DialogDefine.<nom> se lit directement comme un nombre (2026-10-07)
function shop_ui.dialog.hash_of(v)
    if type(v) == "number" then return v end
    local h = nil
    pcall(function() h = v:get_field("Hash") end)
    return h
end
function shop_ui.dialog.describe(name)
    local out = name
    pcall(function()
        local hash = shop_ui.dialog.hash_of(sdk.find_type_definition("app.DialogDefine"):get_field(name):get_data(nil))
        out = out .. " hash=" .. tostring(hash)
        local dm = sdk.get_managed_singleton("app.DialogManager")
        for _, data in ipairs(dm:call("get_userdatas"):get_elements()) do
            for _, unit in ipairs(data:get_field("Units"):get_elements()) do
                if shop_ui.dialog.hash_of(unit:get_field("DialogID")) == hash then
                    local title = ""
                    pcall(function() title = guid_text(unit:get_field("TitleGUID")) or "" end)
                    local body = ""
                    pcall(function() body = guid_text(unit:get_field("DescriptionGUID")) or "" end)
                    out = out .. string.format(" boutons=%d type=%s titre=\"%s\" texte=\"%s\"",
                        unit:get_field("Items"):call("get_Count"), tostring(unit:get_field("DisplayTypeHash")),
                        title, body:sub(1, 80))
                end
            end
        end
    end)
    return out
end
function shop_ui.dialog.open(title, body, button, name)
    if shop_ui.dialog.work and shop_ui.dialog.is_open() then return true end
    name = name or shop_ui.dialog.NAME
    local ok, err = pcall(function()
        local id = sdk.find_type_definition("app.DialogDefine"):get_field(name):get_data(nil)
        local work = sdk.create_instance("app.GUIDialog.Parameter"):add_ref()
        work:set_field("<titleMsg>k__BackingField", sdk.create_managed_string(title))
        work:set_field("<bodyMsg>k__BackingField", sdk.create_managed_string(body))
        work:set_field("<button1Msg>k__BackingField", sdk.create_managed_string(button))
        local param = sdk.create_instance("app.DialogManager.Parameter"):add_ref()
        param:call("set_dialogID", shop_ui.dialog.hash_of(id))
        param:call("set_work", work)
        param:call("set_isExclusive", true)
        param:call("set_priority", 100)
        param:call("set_titleID", sdk.find_type_definition("System.Guid"):get_field("Empty"):get_data(nil))
        sdk.get_managed_singleton("app.DialogManager"):call("openDialog", param)
        shop_ui.dialog.work, shop_ui.dialog.param, shop_ui.dialog.opened_at = work, param, os.clock()
        shop_ui.dialog.text = { title = title, body = body, button = button }
    end)
    -- Pause : posée par apply_text dès que la boîte existe (après isIgnoreSystemPause). Essais du
    -- 2026-10-07 : pause système tout de suite = boîte fermée seule ; temps à 0 = boîte invisible
    -- (son animation ne joue plus).
    if ok then shop_ui.dialog.want_pause = true end
    debug_log(string.format("boîte du jeu : ouverture %s -> %s", shop_ui.dialog.describe(name), ok and "ok" or tostring(err)))
    return ok
end
-- vrai tant que la boîte ouverte par le mod est affichée
function shop_ui.dialog.is_open()
    local work = shop_ui.dialog.work
    if not work then return false end
    local closed = true
    pcall(function() closed = work:get_field("<isClosed>k__BackingField") == true end)
    -- 2026-10-07 : boîte disparue sans isClosed (jeu resté figé) -> aussi fermée quand le
    -- gestionnaire n'affiche plus rien
    if not closed then
        pcall(function()
            if sdk.get_managed_singleton("app.DialogManager"):call("isShowing") == false then closed = true end
        end)
    end
    if closed and os.clock() - (shop_ui.dialog.opened_at or 0) > 0.5 then
        pcall(function()
            debug_log("boîte du jeu : fermée (résultat " .. tostring(work:get_field("<result>k__BackingField")) .. ")")
        end)
        shop_ui.dialog.work = nil
        return false
    end
    return true
end
-- La boîte ignore titleMsg / bodyMsg (2026-10-07 : texte d'origine affiché, mode de
-- difficulté) : nos textes écrits dans ses zones de texte (via.gui.Text.set_Message) à chaque
-- lateUpdate des classes de boîtes, tant que la boîte ouverte est la nôtre.
function shop_ui.dialog.apply_text(dialog)
    local t = shop_ui.dialog.text
    if not t or not shop_ui.dialog.work then return end
    -- 2026-10-07 : un clic n'importe où fermait la boîte (réglage d'origine de la boîte) ;
    -- seul le bouton la ferme
    pcall(function()
        if dialog:call("get_isClickableByOutRange") then dialog:call("set_isClickableByOutRange", false) end
    end)
    pcall(function()
        if not dialog:call("get_isIgnoreSystemPause") then dialog:call("set_isIgnoreSystemPause", true) end
    end)
    if shop_ui.dialog.want_pause and not shop_ui.dialog.paused then
        shop_ui.dialog.want_pause = false
        shop_ui.dialog.paused = true
        shop_ui.popup.set_pause(true, true)
    end
    for getter, value in pairs({ get_titleText = t.title, get_bodyText = t.body }) do
        pcall(function()
            local text = dialog:call(getter)
            if text and text:call("get_Message") ~= value then text:call("set_Message", value) end
        end)
    end
    if not shop_ui.dialog.text_logged then
        shop_ui.dialog.text_logged = true
        debug_log("boîte du jeu : texte remplacé dans " .. dialog:get_type_definition():get_full_name())
    end
end
function shop_ui.dialog.install_hooks()
    for _, name in ipairs({ "app.GUIMisc.DialogOneButton", "app.GUIMisc.DialogImageOneButton",
            "app.GUIMisc.DialogTwoButton", "app.GUIMisc.DialogThreeButton", "app.GUIMisc.DialogNoInput" }) do
        pcall(function()
            local m = sdk.find_type_definition(name):get_method("lateUpdate")
            sdk.hook(m, function(args)
                if shop_ui.dialog.work then
                    pcall(shop_ui.dialog.apply_text, sdk.to_managed_object(args[2]))
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)
        end)
    end
end
pcall(shop_ui.dialog.install_hooks)
-- Fin de la boîte : pause levée ; sécurité : fermée de force après 60 s.
function shop_ui.dialog.watch()
    if not shop_ui.dialog.paused then
        if shop_ui.dialog.want_pause and not shop_ui.dialog.is_open() then shop_ui.dialog.want_pause = false end
        return
    end
    if shop_ui.dialog.work and os.clock() - (shop_ui.dialog.opened_at or 0) > 60 then
        pcall(function() sdk.get_managed_singleton("app.DialogManager"):call("closeDialog(app.DialogManager.Parameter)", shop_ui.dialog.param) end)
        debug_log("boîte du jeu : fermée de force après 60 s")
        shop_ui.dialog.work = nil
    end
    if not shop_ui.dialog.is_open() then
        shop_ui.dialog.paused, shop_ui.dialog.text, shop_ui.dialog.text_logged = false, nil, false
        shop_ui.popup.set_pause(false, true)
    end
end
re.on_script_reset(function()
    if shop_ui.dialog.paused then pcall(shop_ui.popup.set_pause, false, true) end
end)

function shop_ui.dialog.draw_ui()
    if not imgui.tree_node("Boîte de dialogue du jeu (essai)") then return end
    local changed, value = imgui.combo("Boîte", shop_ui.dialog.selected, shop_ui.dialog.CANDIDATES)
    if changed then shop_ui.dialog.selected = value end
    local name = shop_ui.dialog.CANDIDATES[shop_ui.dialog.selected]
    if imgui.button("Décrire (journal)") then debug_log("boîte du jeu : " .. shop_ui.dialog.describe(name)) end
    if imgui.button("TEST : ouvrir avec un texte Archipelago") then
        shop_ui.dialog.open("Archipelago", "Texte d'essai du mod : si tu lis ceci, la boîte du jeu accepte notre texte.",
            "J'ai compris", name)
    end
    imgui.text("Ouverte : " .. tostring(shop_ui.dialog.is_open()))
    local en_changed, en = imgui.checkbox("Utiliser cette boîte pour les murs", shop_ui.dialog.ENABLED)
    if en_changed then shop_ui.dialog.ENABLED, shop_ui.dialog.NAME = en, name end
    imgui.tree_pop()
end

shop_ui.popup.modal = false
-- Pause du jeu lui-même (2026-10-07, demande du joueur) : app.GlobalService.requestPause(type,
-- isNecessaryGUI) / requestReleasePause(type), type app.PauseType.InGameFullNoMenu (pause
-- complète, sans le menu pause). Si l'appel échoue : temps du jeu à 0 (via.Scene.TimeScale).
-- Curseur : via.hid.Mouse.ShowCursor ne rend pas la souris à imgui (essayé, retiré) ; le
-- bouton se clique menu REFramework ouvert, sinon touches.
function shop_ui.popup.set_pause(on, gui, timescale_only)
    local ok = not timescale_only and pcall(function()
        local service = sdk.find_type_definition("app.GlobalService")
        local ptype = sdk.find_type_definition("app.PauseType"):get_field("InGameFullNoMenu"):get_data(nil)
        if on then
            service:get_method("requestPause"):call(nil, ptype, gui == true)
        else
            service:get_method("requestReleasePause"):call(nil, ptype)
        end
    end)
    if on then shop_ui.popup.pause_method = ok and "requestPause" or "TimeScale" end
    debug_log(string.format("fenêtre bloquante : pause %s (%s)", on and "demandée" or "levée", tostring(shop_ui.popup.pause_method)))
    if shop_ui.popup.pause_method ~= "TimeScale" then return end
    pcall(function()
        local scene = get_scene()
        if on then
            shop_ui.popup.old_scale = scene:call("get_TimeScale")
            scene:call("set_TimeScale", 0.0)
        else
            scene:call("set_TimeScale", shop_ui.popup.old_scale or 1.0)
        end
    end)
end
function shop_ui.popup.show_modal(title, lines, button)
    if shop_ui.popup.modal or shop_ui.dialog.is_open() then return end
    button = button or tr("J'ai compris, je vais le faire", "Got it, I'll do it")
    if shop_ui.dialog.ENABLED then
        if shop_ui.dialog.open(title, table.concat(lines, "\n"), button) then
            return
        end
    end
    shop_ui.popup.show(title, lines, 120)
    shop_ui.popup.button = button
    shop_ui.popup.modal, shop_ui.popup.armed = true, false
    shop_ui.popup.set_pause(true)
    debug_log("fenêtre bloquante ouverte : " .. tostring(title))
end
function shop_ui.popup.close()
    if not shop_ui.popup.modal then return end
    shop_ui.popup.modal = false
    shop_ui.popup.until_t = 0
    shop_ui.popup.closed_at = os.clock()
    shop_ui.popup.set_pause(false)
    debug_log("fenêtre bloquante fermée")
end
-- Entrée / Espace / validation manette : vrai seulement quand la touche vient d'être appuyée
function shop_ui.popup.confirm_pressed()
    local down = false
    pcall(function()
        if reframework:is_key_down(0x0D) or reframework:is_key_down(0x20) then down = true end
    end)
    pcall(function()
        local pad = sdk.find_type_definition("via.hid.GamePad")
        local dev = pad:get_method("get_MergedDevice"):call(nil)
        local enter = pad:get_method("get_EnterButton"):call(nil)
        local buttons = dev:call("get_Button")
        if enter and buttons and (buttons & enter) ~= 0 then down = true end
    end)
    if not down then shop_ui.popup.armed = true return false end
    return shop_ui.popup.armed == true
end
re.on_script_reset(function() pcall(shop_ui.popup.close) end)

function shop_ui.popup.draw()
    local p = shop_ui.popup
    if p.modal and (os.clock() > p.until_t or shop_ui.popup.confirm_pressed()) then shop_ui.popup.close() end
    if p.anywhere and not p.modal and os.clock() <= p.until_t and shop_ui.popup.confirm_pressed() then
        p.until_t, p.anywhere = 0, false
    end
    if not p.title or os.clock() > p.until_t then return end
    local w, h = 1920, 1080
    pcall(function()
        local size = imgui.get_display_size()
        if size and size.x > 0 then w, h = size.x, size.y end
    end)
    local box_w = math.min(760, w * 0.6)
    local colors, vars = 0, 0
    pcall(function() imgui.push_style_color(2, 0xE6100C0A) colors = colors + 1 end)  -- fond
    pcall(function() imgui.push_style_color(5, 0xFF3C8CD2) colors = colors + 1 end)  -- bordure (or)
    pcall(function() imgui.push_style_var(3, 8.0) vars = vars + 1 end)               -- coins arrondis
    pcall(function() imgui.push_style_var(4, 2.0) vars = vars + 1 end)               -- épaisseur bordure
    pcall(function() imgui.push_style_var(2, Vector2f.new(22, 18)) vars = vars + 1 end) -- marges
    imgui.set_next_window_pos({ (w - box_w) / 2, h * 0.32 })
    pcall(function() imgui.set_next_window_size({ box_w, 0 }) end)
    imgui.begin_window("Archipelago##popup", nil, 1 | 2 | 4 | 8 | 64) -- sans titre, fixe, taille auto
    pcall(function()
        pcall(function() imgui.set_window_font_scale(1.35) end)
        imgui.text_colored(p.title, 0xFF5AC8F0)
        pcall(function() imgui.set_window_font_scale(1.15) end)
        imgui.separator()
        imgui.spacing()
        for _, line in ipairs(p.lines) do
            local wrapped = pcall(imgui.push_text_wrap_pos, box_w - 22)
            imgui.text(line)
            if wrapped then pcall(imgui.pop_text_wrap_pos) end
        end
        if p.modal then
            imgui.spacing()
            imgui.separator()
            imgui.spacing()
            if imgui.button(p.button or tr("J'ai compris, je vais le faire", "Got it, I'll do it")) then
                shop_ui.popup.close_requested = true
            end
            imgui.text_colored(tr("Pour fermer : appuie sur Entrée ou Espace (clavier),",
                "To close: press Enter or Space (keyboard),"), 0xFFA0A0A0)
            imgui.text_colored(tr("ou sur A (Xbox) / Croix (PlayStation) à la manette.",
                "or A (Xbox) / Cross (PlayStation) on a controller."), 0xFFA0A0A0)
        end
    end)
    imgui.end_window()
    if shop_ui.popup.close_requested then
        shop_ui.popup.close_requested = false
        shop_ui.popup.close()
    end
    if vars > 0 then pcall(imgui.pop_style_var, vars) end
    if colors > 0 then pcall(imgui.pop_style_color, colors) end
end

---------------------------------------------------------------------------
-- Avertissements (2026-10-08, demande du joueur)
---------------------------------------------------------------------------
-- 1. Au lancement du jeu, aucune session enregistrée (adresse / slot vides, ou connexion auto
--    coupée par une déconnexion volontaire) : fenêtre au centre de l'écran, même à l'écran titre
--    (popup « anywhere », non bloquante, 45 s, Entrée / Espace / A pour fermer) : on jouera
--    normalement ; pour se connecter, passer par le launcher (onglet Jouer).
-- 2. Connexion auto qui n'aboutit pas 40 s après le lancement : même fenêtre (serveur injoignable,
--    room endormie...). Connexion refusée : idem, tout de suite.
-- 3. En partie, connecté, mauvaise difficulté : boîte du jeu (bloquante, comme les murs) une fois
--    par chargement ; aucun check ne compte dans cette difficulté.
-- Les textes en haut à gauche sont masqués sans connexion ou en mauvaise difficulté (on_frame).
shop_ui.notice = { started = os.clock(), launch_done = false, slow_done = false, diff_warned = false }
-- Outils de développement du menu REFramework : seulement avec dev.json (tools/install.py le pose ;
-- jamais dans une version distribuée).
shop_ui.DEV = json.load_file(MOD_NAME .. "/dev.json") ~= nil
shop_ui.notice.DIFF_LABELS = {
    casual = { "Facile", "Casual" }, standard = { "Standard", "Standard" }, hardcore = { "Hardcore", "Hardcore" },
    village_des_ombres = { "Village des ombres", "Village of Shadows" },
}
function shop_ui.notice.show_anywhere(title, lines, seconds)
    shop_ui.popup.show(title, lines, seconds)
    shop_ui.popup.anywhere = true
    shop_ui.popup.armed = false
end
function shop_ui.notice.how_to_connect()
    return {
        tr("Pour jouer en Archipelago, il te faut l'adresse de la room, ton nom de slot et le mot de passe",
            "To play with Archipelago you need the room address, your slot name and the password"),
        tr("(s'il y en a un), donnés par l'hôte. Deux façons de les entrer :",
            "(if any), given by the host. Two ways to enter them:"),
        tr("- avec le launcher RE Village Archipelago : onglet « Jouer » ;",
            "- with the RE Village Archipelago launcher: \"Play\" tab;"),
        tr("- sans launcher (installation manuelle) : touche Inser pour ouvrir le menu REFramework,",
            "- without the launcher (manual install): press Insert to open the REFramework menu,"),
        tr("  « Script Generated UI » > « RE Village Archipelago », puis « Se connecter ».",
            "  \"Script Generated UI\" > \"RE Village Archipelago\", then \"Connect\"."),
        tr("Ils sont gardés : ensuite, le jeu se connecte tout seul à chaque lancement.",
            "They are kept: afterwards, the game connects by itself at every start."),
    }
end
function shop_ui.notice.diff_label(name)
    local pair = shop_ui.notice.DIFF_LABELS[name or ""]
    return pair and tr(pair[1], pair[2]) or tostring(name)
end
function shop_ui.notice.update()
    local n = shop_ui.notice
    local since = os.clock() - n.started
    local has_session = conn.auto and conn.slot ~= "" and conn.host ~= ""
    if not n.launch_done and since > 6 then
        n.launch_done = true
        if not has_session then
            local lines = {
                tr("Tu n'es connecté à aucune session Archipelago : si tu lances une partie, tu joueras",
                    "You are not connected to any Archipelago session: if you start a game, you will play"),
                tr("normalement, sans objets mélangés ni checks.", "normally, with no shuffled items and no checks."),
                "",
            }
            if conn.slot ~= "" and not conn.auto then
                lines[3] = tr("(La connexion automatique a été coupée par une déconnexion dans le menu du mod.)",
                    "(Automatic connection was turned off by a disconnect in the mod menu.)")
            end
            for _, line in ipairs(n.how_to_connect()) do lines[#lines + 1] = line end
            n.show_anywhere(tr("Archipelago : aucune session", "Archipelago: no session"), lines, 45)
            debug_log("avertissement : aucune session enregistrée au lancement")
        end
    end
    if net_status == "connecté" and shop_ui.popup.anywhere then
        shop_ui.popup.until_t, shop_ui.popup.anywhere = 0, false
    end
    if has_session and not n.slow_done and since > 40 and net_status ~= "connecté" then
        n.slow_done = true
        n.show_anywhere(tr("Archipelago : pas encore connecté", "Archipelago: not connected yet"), {
            string.format(tr("Le serveur %s ne répond pas (slot %s). Une room archipelago.gg endormie se réveille",
                "Server %s does not answer (slot %s). A sleeping archipelago.gg room wakes up"), conn.host, conn.slot),
            tr("en ouvrant sa page. Vérifie l'adresse : launcher (onglet « Jouer », « Tester la connexion »)",
                "when its page is opened. Check the address: launcher (\"Play\" tab, \"Test connection\")"),
            tr("ou menu REFramework (touche Inser > RE Village Archipelago).",
                "or REFramework menu (Insert key > RE Village Archipelago)."),
            tr("Le mod réessaie tout seul. Tant qu'il n'est pas connecté, les checks ne sont pas envoyés.",
                "The mod keeps retrying. Until it is connected, checks are not sent."),
        }, 30)
        debug_log("avertissement : pas connecté 40 s après le lancement")
    end
    -- mauvaise difficulté : une fois par chargement (remis à zéro par WriteBackSaveData et quand
    -- la difficulté n'est plus lisible : écran titre)
    if game_difficulty == nil then n.diff_warned = false end
    if not n.diff_warned and is_in_game() and net_status == "connecté" and wrong_difficulty() then
        n.diff_warned = true
        local current = difficulty_names and difficulty_names[game_difficulty] or "?"
        local wanted = n.diff_label(required_difficulty)
        shop_ui.popup.show_modal(tr("Archipelago : mauvaise difficulté", "Archipelago: wrong difficulty"), {
            string.format(tr("Cette partie est en difficulté « %s », mais ta session Archipelago demande « %s ».",
                "This game is on \"%s\" difficulty, but your Archipelago session requires \"%s\"."), current, wanted),
            tr("Aucun check ne sera validé tant que tu joues dans cette difficulté.",
                "No check will count while you play on this difficulty."),
            string.format(tr("Recommence une nouvelle partie en « %s ».", "Start a new game on \"%s\"."), wanted),
        }, tr("J'ai compris", "Got it"))
        debug_log(string.format("avertissement : mauvaise difficulté (%s, demandée %s)", tostring(current), tostring(required_difficulty)))
    end
end
function shop_ui.notice.on_refused(text)
    shop_ui.notice.slow_done = true
    shop_ui.notice.show_anywhere(tr("Archipelago : connexion refusée", "Archipelago: connection refused"), {
        string.format(tr("Le serveur %s a refusé la connexion du slot « %s » : %s",
            "Server %s refused slot \"%s\": %s"), conn.host, conn.slot, tostring(text)),
        tr("Vérifie le nom du slot (majuscules comprises) et le mot de passe : launcher (onglet « Jouer »)",
            "Check the slot name (case matters) and the password: launcher (\"Play\" tab)"),
        tr("ou menu REFramework (touche Inser > RE Village Archipelago).",
            "or REFramework menu (Insert key > RE Village Archipelago)."),
    }, 30)
end

---------------------------------------------------------------------------
-- Mode 100 % (missable_checks = cent_pourcent, 2026-10-07, demande du joueur)
---------------------------------------------------------------------------
-- Endroits sans retour (cachots du château, passage souterrain, maison de Luiza, château
-- Dimitrescu, maison Beneviento) : mur invisible à chaque sortie tant qu'il reste des checks de
-- l'endroit. Le joueur qui entre dans la sphère d'une sortie est remis à sa dernière position
-- sûre (app.PlayerMovement.recovery(via.vec3), méthode du client RE7) et un message liste les
-- checks manquants. Pas de mur pour le combat final du Village (la fin du jeu envoie tout).
-- Sorties : no_return.json (relevées en jeu avec les outils de dev) :
--   { "<endroit>": [ { "chapter": "Chapter2_2", "pos": [x, y, z], "r": 1.5 }, ... ], ... }
shop_ui.no_return = {
    SEGMENTS = {
        { name = "Cachots du château", name_en = "Castle dungeon", test = function(loc) return loc.missable_spot == "Cachots du château" end },
        { name = "Passage souterrain", name_en = "Underground passage", test = function(loc) return loc.missable_spot == "Passage souterrain" end },
        { name = "Maison de Luiza", name_en = "Luiza's house", test = function(loc) return loc.missable_spot == "Maison de Luiza" end },
        -- Château : mur juste après la porte des masques (avant le combat final). Les checks faits
        -- APRÈS ce point ne comptent pas, sinon on ne passerait jamais (2026-10-07, 11 checks) :
        -- rangs 172 à 179 de la partie de référence (S12, toit S09, Dimitrescu cristallisée) et,
        -- pour ceux jamais ramassés dans cette partie, ceux situés au-delà du mur (x < -94).
        { name = "Château Dimitrescu", name_en = "Castle Dimitrescu", test = function(loc)
              if loc.missable_chapter ~= "Chapter2_2" then return false end
              local order, p = loc.order or 0, loc.item_position
              if order >= 172 and order < 180 then return false end
              if p and p[1] < -94 then return false end
              if p and p[3] > 15 then return false end -- vignes : endroit à part (plus bas)
              return true
          end,
          -- Actif seulement après un 1er check du château (2026-10-08) : c'est la MÊME porte qu'au
          -- tout début (les sœurs enlèvent Ethan, puis les 4 statues) ; le mur bloquait le début.
          -- Choix du joueur (2026-10-08) : actif DÉFINITIVEMENT dès que le check de l'emplacement
          -- de la Bague (#008) est fait (gardé par le serveur). Seul risque : crash juste après la
          -- Bague sans sauvegarde. Sans ce check dans la seed (objets clés pas mélangés) : actif
          -- dès qu'un check du château est fait.
          active = function(segment)
              local ring_seen = false
              for _, loc in pairs(location_by_guid) do
                  if loc.key_item_location and (loc.name or ""):find("Bague avec un", 1, true) then
                      local done = location_done(loc)
                      if done ~= nil then
                          ring_seen = true
                          if done == true then return true end
                      end
                  end
              end
              if ring_seen then return false end
              for _, loc in pairs(location_by_guid) do
                  if segment.test(loc) and location_done(loc) == true then return true end
              end
              return false
          end },
        -- Vignes du château (2026-10-08) : on n'y revient plus une fois entré dans le château ;
        -- checks du château situés côté vignes (z > 15 : Plante #001 [S00], -36.3 -18.3 23.8).
        -- Mur à l'entrée du château, côté vignes.
        { name = "Vignes du château", name_en = "Castle vineyard", test = function(loc)
              local p = loc.item_position
              return loc.missable_chapter == "Chapter2_2" and p ~= nil and p[3] > 15
          end },
        { name = "Maison Beneviento", name_en = "House Beneviento", test = function(loc) return loc.missable_chapter == "Chapter2_3" end },
        -- Porte qui s'ouvre au ramassage de la Bague (2026-10-08, demande du joueur) : un check
        -- d'avant cette porte devient inaccessible ensuite. Checks exigés lus dans no_return.json
        -- (champ « requires » de la sortie : noms des locations), pour les ajuster sans code.
        { name = "Porte de la Bague", name_en = "Ring door", test = function(loc)
              for _, exit in ipairs(shop_ui.no_return.exits["Porte de la Bague"] or {}) do
                  for _, n in ipairs(exit.requires or {}) do
                      if n == loc.name then return true end
                  end
              end
              return false
          end },
        -- Anti-softlock (2026-10-07, idée du joueur), actif dans TOUS les modes : entrée de la
        -- salle des statues (vidange). Le jeu ne vide le sang que si l'énigme du vin est faite ;
        -- avec la Clé de la cour reçue du multiworld, on pouvait y entrer sans avoir posé le vin
        -- (statues validées, sang jamais vidé, porte fermée). Vin posé = check de l'emplacement
        -- d'origine de la Clé de la cour fait (l'énigme y fait apparaître l'objet).
        { name = "Salle des statues (vin à poser)", always = true,
          blockers = function()
              local loc = shop_ui.no_return.courtyard_loc()
              if not loc then return {} end
              -- Check validé mais sauvegarde rechargée d'avant l'énigme (2026-10-09, rapport du
              -- joueur) : le serveur garde le check, pas la partie. Sanguis Virginis encore dans la
              -- mallette = vin pas posé (le poser le retire).
              local sv = item_by_name["Sanguis Virginis"]
              local holding = sv and (inventory_quantity(sv.game_item_id) or 0) > 0
              if location_done(loc) ~= false and not holding then return {} end
              return { tr("pose le Sanguis Virginis à l'étage (énigme du vin) et prends ce qu'il donne",
                  "place the Sanguis Virginis upstairs (wine puzzle) and take what it gives") }
          end,
          message = function()
              return tr("Avant de continuer, pose le Sanguis Virginis à l'étage (énigme du vin) et ramasse le check dans la petite boîte, sinon la vidange ne se lancera pas.",
                  "Before going further, place the Sanguis Virginis upstairs (wine puzzle) and pick up the check in the small box, otherwise the blood will never drain.")
          end },
    },
    FILE = MOD_NAME .. "/no_return.json",
    CAPTURE_FILE = MOD_NAME .. "/no_return_captures.jsonl",
    DEFAULT_RADIUS = 1.5,
    exits = {},
    safe = nil,
    next_message = 0,
    selected = 1,
}
shop_ui.no_return.exits = json.load_file(shop_ui.no_return.FILE) or {}

function shop_ui.no_return.player()
    local player = sdk.find_type_definition("app.PlayerUtility"):get_method("getPlayer"):call(nil)
    if not player then return nil end
    local p = player:call("get_Transform"):call("get_Position")
    return player, { p.x, p.y, p.z }
end

-- Composant de déplacement d'Ethan (2026-10-07 : absent de l'objet joueur lui-même,
-- « repoussé : false ») : cherché aussi dans les objets enfants (3 niveaux) ; tout type dont un
-- parent s'appelle *PlayerMovement* ; composants vus notés une fois au journal (diagnostic).
function shop_ui.no_return.movement(player)
    if shop_ui.no_return.mv_cache and shop_ui.no_return.mv_owner == player:get_address() then
        return shop_ui.no_return.mv_cache
    end
    local seen, found = {}, nil
    local todo = { { player, 0 } }
    while #todo > 0 and not found do
        local go, depth = table.unpack(table.remove(todo, 1))
        pcall(function()
            for _, c in ipairs(go:call("get_Components"):get_elements()) do
                local td = c:get_type_definition()
                seen[#seen + 1] = tostring(go:call("get_Name")) .. ":" .. td:get_full_name()
                while td and not found do
                    if td:get_full_name():find("PlayerMovement", 1, true) then found = c end
                    td = td:get_parent_type()
                end
            end
        end)
        if depth < 3 then
            pcall(function()
                local child = go:call("get_Transform"):call("get_Child")
                while child do
                    todo[#todo + 1] = { child:call("get_GameObject"), depth + 1 }
                    child = child:call("get_Next")
                end
            end)
        end
    end
    if not shop_ui.no_return.mv_logged then
        shop_ui.no_return.mv_logged = true
        debug_log("mode 100 % : composants du joueur : " .. table.concat(seen, ", ", 1, math.min(#seen, 80)))
        debug_log("mode 100 % : déplacement = " .. (found and found:get_type_definition():get_full_name() or "introuvable"))
    end
    shop_ui.no_return.mv_cache, shop_ui.no_return.mv_owner = found, player:get_address()
    return found
end

-- Emplacement d'origine de la Clé de la cour (récompense de l'énigme du vin), s'il est dans la seed.
function shop_ui.no_return.courtyard_loc()
    if shop_ui.no_return.courtyard == nil then
        shop_ui.no_return.courtyard = false
        for _, loc in pairs(location_by_guid) do
            if loc.key_item_location and loc.original_item == "Clé de la cour" then shop_ui.no_return.courtyard = loc end
        end
    end
    local loc = shop_ui.no_return.courtyard
    return loc and get_location_id(loc) and loc or nil
end

function shop_ui.no_return.missing(segment)
    if segment.blockers then return segment.blockers() end
    local out = {}
    for _, loc in pairs(location_by_guid) do
        if segment.test(loc) and location_done(loc) == false then out[#out + 1] = i18n.loc(loc) end
    end
    table.sort(out)
    return out
end

function shop_ui.no_return.warp(player, pos)
    local v = Vector3f.new(pos[1], pos[2], pos[3])
    local mv = shop_ui.no_return.movement(player)
    if mv then
        local ok = pcall(function() mv:call("recovery(via.vec3)", v) end)
        if ok then return "recovery" end
    end
    -- dernier recours : position du joueur écrite directement (peut être reprise par le jeu)
    local ok = pcall(function() player:call("get_Transform"):call("set_Position", v) end)
    return ok and "set_Position" or false
end

function shop_ui.no_return.update()
    if not in_game or not is_connected() then return end
    local full = missable_mode == "cent_pourcent" or shop_ui.no_return.force
    local player, pos = nil, nil
    local inside, inside_exit, outside_all = nil, nil, true
    for _, segment in ipairs(shop_ui.no_return.SEGMENTS) do
        local exits = (full or segment.always) and shop_ui.no_return.exits[segment.name] or {}
        if #exits > 0 and segment.active then
            if os.clock() >= (segment.active_until or 0) then
                segment.active_until = os.clock() + 1
                local was = segment.is_active
                segment.is_active = segment.active(segment)
                if was ~= segment.is_active then
                    debug_log("mode 100 % : mur de " .. segment.name .. (segment.is_active and " ACTIF" or " inactif"))
                end
            end
            if not segment.is_active then exits = {} end
        end
        if #exits > 0 and not pos then
            player, pos = shop_ui.no_return.player()
            if not pos then return end
        end
        for _, exit in ipairs(exits) do
            if exit.chapter == last_chapter then
                local d = math.sqrt((exit.pos[1] - pos[1]) ^ 2 + (exit.pos[2] - pos[2]) ^ 2 + (exit.pos[3] - pos[3]) ^ 2)
                local r = exit.r or shop_ui.no_return.DEFAULT_RADIUS
                if d < r + 0.75 then outside_all = false end
                if d < r and not inside then inside, inside_exit = segment, exit end
            end
        end
    end
    if outside_all then shop_ui.no_return.safe = pos end
    -- filet « passé au-delà du mur » DÉSACTIVÉ (2026-10-08) : il envoyait les checks du passage
    -- dès qu'on était loin du mur (partie chargée ailleurs, ou mur côté Village)
    -- pcall(shop_ui.no_return.past_wall, pos)
    if not inside then return end
    local missing = shop_ui.no_return.missing(inside)
    if #missing == 0 then return end
    -- Pas encore de position sûre (2026-10-07 : sortie relevée en étant dessus, « repoussé : nil ») :
    -- poussé hors de la sphère, à l'opposé du centre de la sortie (à plat).
    local target = shop_ui.no_return.safe
    if not target then
        local c, r = inside_exit.pos, inside_exit.r or shop_ui.no_return.DEFAULT_RADIUS
        local dx, dz = pos[1] - c[1], pos[3] - c[3]
        local len = math.sqrt(dx * dx + dz * dz)
        if len < 0.05 then dx, dz, len = 1, 0, 1 end
        target = { c[1] + dx / len * (r + 1), pos[2], c[3] + dz / len * (r + 1) }
    end
    local warped = shop_ui.no_return.warp(player, target)
    if shop_ui.popup.title and not shop_ui.popup.modal then shop_ui.popup.until_t = math.max(shop_ui.popup.until_t, os.clock() + 4) end
    if not shop_ui.popup.modal and not shop_ui.dialog.is_open() then
        local shown = {}
        for i = 1, math.min(#missing, 6) do shown[i] = missing[i] end
        local more = #missing > 6 and string.format(tr(" (+%d autres)", " (+%d more)"), #missing - 6) or ""
        local show = shop_ui.popup.show_modal -- à chaque tentative (2026-10-07, demande du joueur)
        if inside.message then
            show(tr("Impossible d'avancer", "You can't go further"), { inside.message(missing) }, 6)
        else
            local lines = { string.format(tr("%s : il te manque encore ces checks :", "%s: these checks are still missing:"),
                tr(inside.name, inside.name_en or inside.name)) }
            for _, name in ipairs(shown) do lines[#lines + 1] = "  - " .. name end
            if more ~= "" then lines[#lines + 1] = more end
            show(tr("Impossible d'avancer", "You can't go further"), lines, 6)
        end
        debug_log(string.format("mode 100 %% : sortie de %s bloquée (%d checks manquants, repoussé : %s)",
            inside.name, #missing, tostring(warped)))
    end
end

-- Filet de sécurité (2026-10-08, passage souterrain) : joueur passé de l'autre côté d'un mur
-- (dans le chapitre de la sortie, à plus de 15 m) avec des checks manquants -> envoyés tout seuls,
-- personne ne reste bloqué.
function shop_ui.no_return.past_wall(pos)
    for _, segment in ipairs(shop_ui.no_return.SEGMENTS) do
        for _, exit in ipairs(shop_ui.no_return.exits[segment.name] or {}) do
            if exit.chapter == last_chapter and exit.far_sent == nil then
                local d2 = (exit.pos[1] - pos[1]) ^ 2 + (exit.pos[2] - pos[2]) ^ 2 + (exit.pos[3] - pos[3]) ^ 2
                -- seulement après avoir vu le joueur PRÈS du mur dans cette session (2026-10-08 :
                -- partie chargée loin derrière, au château -> checks du passage envoyés à tort)
                local r = (exit.r or shop_ui.no_return.DEFAULT_RADIUS) + 5
                if d2 < r * r then exit.seen_near = true end
                if d2 > 225 and exit.seen_near and segment.name == "Passage souterrain" then
                    exit.far_sent = true
                    local sent = 0
                    for _, loc in pairs(location_by_guid) do
                        if segment.test(loc) and location_done(loc) == false then
                            queue_check(loc)
                            sent = sent + 1
                        end
                    end
                    if sent > 0 then debug_log("mode 100 % : passé au-delà du mur de " .. segment.name .. ", " .. sent .. " check(s) envoyés") end
                end
            end
        end
    end
end

-- Outils de dev : relever une sortie à la position du joueur (ajoutée tout de suite, et notée
-- dans no_return_captures.jsonl pour être recopiée dans no_return.json).
function shop_ui.no_return.capture()
    local _, pos = shop_ui.no_return.player()
    if not pos then return end
    local segment = shop_ui.no_return.SEGMENTS[shop_ui.no_return.selected]
    local exit = { chapter = last_chapter, pos = pos, r = shop_ui.no_return.DEFAULT_RADIUS }
    shop_ui.no_return.exits[segment.name] = shop_ui.no_return.exits[segment.name] or {}
    table.insert(shop_ui.no_return.exits[segment.name], exit)
    json.dump_file(shop_ui.no_return.FILE, shop_ui.no_return.exits)
    local f = io.open(shop_ui.no_return.CAPTURE_FILE, "a")
    if f then
        f:write(json.dump_string({ segment = segment.name, chapter = last_chapter, pos = pos,
            time = os.date("%Y-%m-%d %H:%M:%S") }) .. "\n")
        f:close()
    end
    add_message(string.format("Sortie relevée : %s (%s) %.2f %.2f %.2f", segment.name, tostring(last_chapter),
        pos[1], pos[2], pos[3]))
    debug_log("mode 100 % : sortie relevée " .. json.dump_string(exit) .. " pour " .. segment.name)
end

function shop_ui.no_return.draw_ui()
    if not imgui.tree_node("Mode 100 % : sorties sans retour") then return end
    imgui.text("Mode actuel : " .. tostring(missable_mode) .. " (murs actifs en cent_pourcent ; « vin à poser » : toujours)")
    local test_changed, test_on = imgui.checkbox("TEST : murs actifs quel que soit le mode", shop_ui.no_return.force == true)
    if test_changed then shop_ui.no_return.force = test_on end
    local names = {}
    for i, segment in ipairs(shop_ui.no_return.SEGMENTS) do
        names[i] = string.format("%s (%d sortie(s))", segment.name, #(shop_ui.no_return.exits[segment.name] or {}))
    end
    local changed, value = imgui.combo("Endroit", shop_ui.no_return.selected, names)
    if changed then shop_ui.no_return.selected = value end
    if imgui.button("Relever une sortie ICI (position du joueur)") then pcall(shop_ui.no_return.capture) end
    if imgui.button("Lister les checks comptés dans cette salle (journal)") then
        debug_log("salle actuelle : " .. #(shop_ui.room_list or {}) .. " check(s) : " .. table.concat(shop_ui.room_list or {}, " ; "))
    end
    local _, pos = shop_ui.no_return.player()
    if pos then imgui.text(string.format("Position : %.2f %.2f %.2f, chapitre %s", pos[1], pos[2], pos[3], tostring(last_chapter))) end
    local segment = shop_ui.no_return.SEGMENTS[shop_ui.no_return.selected]
    local ok, missing = pcall(shop_ui.no_return.missing, segment)
    if ok then imgui.text(string.format("Checks manquants (%s) : %d", segment.name, #missing)) end
    if imgui.button("Effacer les sorties de cet endroit") then
        shop_ui.no_return.exits[segment.name] = nil
        json.dump_file(shop_ui.no_return.FILE, shop_ui.no_return.exits)
    end
    imgui.tree_pop()
end

-- Checks impossibles en jeu (données : auto_send), envoyés dès qu'on est connecté et en jeu
-- (2026-10-07 : Remède de premiers soins #004 [S00], maison du départ fermée au chapitre 2_6).
-- Envoi dès qu'un repère est ramassé (données : auto_send_when { location, item_id }) : check
-- du repère fait, ou objet du repère ramassé. Vérifié toutes les secondes. (2026-10-08 : maison
-- de Luiza dès le Morceau de relief démon.)
function shop_ui.auto_send_when()
    if not in_game or not is_connected() or os.clock() < (shop_ui.next_when or 0) then return end
    shop_ui.next_when = os.clock() + 1
    shop_ui.when_done = shop_ui.when_done or {}
    for _, loc in pairs(location_by_guid) do
        local w = loc.auto_send_when
        if w and not shop_ui.when_done[loc.key] and location_done(loc) == false then
            local trigger = false
            for _, other in pairs(location_by_guid) do
                if other.name == w.location and location_done(other) == true then trigger = true end
            end
            if (shop_ui.picked_item_ids or {})[w.item_id] then trigger = true end
            if trigger then
                shop_ui.when_done[loc.key] = true
                debug_log("envoi automatique (repère " .. tostring(w.location) .. ") : " .. loc.name)
                queue_check(loc)
            end
        end
    end
end

function shop_ui.auto_send()
    pcall(shop_ui.auto_send_when)
    if shop_ui.auto_sent or not in_game or not is_connected() then return end
    shop_ui.auto_sent = true
    for _, loc in pairs(location_by_guid) do
        if loc.auto_send and location_done(loc) == false then
            debug_log("envoi automatique (check impossible en jeu) : " .. loc.name)
            queue_check(loc)
        end
    end
end

re.on_pre_application_entry("UpdateBehavior", function()
    debug_log(nil)
    pcall(shop_ui.auto_send)
    i18n.update()
    pcall(shop_ui.no_return.update)
    pcall(shop_ui.setup_carrier)
    pcall(shop_ui.setup_model)
    if shop_ui.DEV and os.clock() - last_heartbeat >= 1.0 then
        last_heartbeat = os.clock()
        debug_log(string.format("boucle jeu : en jeu=%s, réseau=%s, retraits=%d, items=%d",
            tostring(in_game), net_status, #vanilla_removals, #items_queue))
    end

    if requests.disconnect then
        requests.disconnect = false
        net.disconnect()
        conn.auto = false
        json.dump_file(CONNECTION_FILE, conn)
        add_message(tr("Déconnecté.", "Disconnected."))
    end
    if requests.names then
        requests.names = false
        local ok_n, err_n = pcall(shop_ui.dump_names)
        if not ok_n then last_tool_message = "Noms FR/EN : erreur " .. tostring(err_n) end
    end
    if requests.connect then
        requests.connect = false
        conn.auto = true
        json.dump_file(CONNECTION_FILE, conn)
        if net.load_error() then
            add_message(tr("Module réseau introuvable : ", "Network module not found: ") .. net.load_error())
        else
            net.connect(conn.host, conn.slot, conn.password)
            add_message(tr("Connexion à ", "Connecting to ") .. conn.host .. "...")
        end
    end

    process_network()
    net_status = net.state()
    pcall(watch_current_chapter)
    update_in_game_state()
    process_shop_purchases()
    update_shop_label()
    pcall(shop_ui.restore_prefabs)
    pcall(shop_ui.world.update)
    shop_ui.world.update_prompt()
    process_picked_locations()
    process_boss_events()
    check_goal()
    -- La boutique n'est pas "en jeu" (menu ouvert) : relevé possible à tout moment.
    if requests.catalog then
        requests.catalog = false
        local ok, err = pcall(dump_item_catalog)
        if not ok then last_tool_message = "Catalogue : erreur " .. tostring(err) end
    end
    if requests.recipes then
        requests.recipes = false
        local ok, err = pcall(dump_recipes)
        if not ok then last_tool_message = "Plats : erreur " .. tostring(err) end
    end
    if requests.shop then
        requests.shop = false
        dump_shop()
    end
    if not is_in_game() then return end

    if requests.scan then
        requests.scan = false
        scan_zone()
    end
    if requests.give then
        local r = requests.give
        requests.give = nil
        last_tool_message = give_item(r.id, r.count) and "Objet donné" or "ECHEC du don"
    end
    if requests.knife then
        requests.knife = false
        for _, line in ipairs(describe_equip_controllers()) do debug_log("EquipController " .. line) end
        local before = get_equipped_weapon_id()
        local ok, msg = equip_weapon(2292458104) -- couteau
        last_tool_message = string.format("Equiper couteau : %s (arme avant : %s, après : %s)", msg, tostring(before), tostring(get_equipped_weapon_id()))
        debug_log(last_tool_message)
    end
    -- Réparation (2026-10-08 : case « Remède 0 » après un achat-check chez le Duc, confection
    -- figée) : mallette notée au journal, objets à quantité 0 remis à 1 puis retirés (reduceItem).
    if requests.fix_zero then
        requests.fix_zero = false
        debug_log("réparation mallette : AVANT : " .. inventory_dump())
        local _, inv = get_active_inventory()
        local fixed = 0
        pcall(function()
            local list = inv:call("get_items")
            for i = list:call("get_Count") - 1, 0, -1 do
                local work = list:call("get_Item", i):call("get_work")
                local id, n = work:call("get_itemID"), work:call("get_stackSize")
                if id and id ~= 0 and n == 0 then
                    work:call("set_stackSize", 1)
                    inv:call("reduceItem(System.UInt32, System.Int32, System.Boolean, System.Boolean)", id, 1, false, false)
                    fixed = fixed + 1
                    debug_log("réparation mallette : objet " .. tostring(id) .. " à 0 retiré")
                end
            end
        end)
        -- Objets superposés (2026-10-08, après une Valise : objets restés sur leurs anciennes
        -- cases) : un objet sur une case déjà prise, ou hors de la mallette, est déplacé sur une
        -- case libre trouvée par le jeu (Inventory.getBlankSlotNo), puis l'affichage est refait.
        local moved = 0
        pcall(function()
            local max = inv:call("getMaxSlotCount")
            local list = inv:call("get_items")
            -- SEULEMENT les objets de la grille (munitions, soins, armes, explosifs) : objets clés,
            -- formules, trésors, matériaux ont leur propre numérotation (Photo, Formule et Couteau
            -- tous « case 0 » sans être superposés). Pile de la grille sans case (-1) : à placer.
            local grid_types = { Ammo = true, Recovery = true, Weapon = true }
            local type_of = {}
            for _, def in pairs(item_by_name) do
                if def.game_item_id then type_of[def.game_item_id] = def.type end
            end
            local seen, conflicts = {}, {}
            for i = 0, list:call("get_Count") - 1 do
                local work = list:call("get_Item", i):call("get_work")
                local slot = work:call("get_slotNo")
                if grid_types[type_of[work:call("get_itemID")] or ""] and slot then
                    if slot < 0 or seen[slot] or (max and slot >= max) then
                        conflicts[#conflicts + 1] = work
                    else
                        seen[slot] = true
                    end
                end
            end
            for _, work in ipairs(conflicts) do
                local id, old = work:call("get_itemID"), work:call("get_slotNo")
                work:call("set_slotNo", -1)
                local res = inv:call("getBlankSlotNo", id, false)
                local ns = res and res:call("get_slotNo")
                if ns and ns >= 0 then
                    work:call("set_slotNo", ns)
                    work:call("set_lastSlotNo", ns)
                    work:call("set_centeringSafeSlotNo", ns)
                    moved = moved + 1
                    debug_log(string.format("réparation mallette : objet %s case %s -> %s", tostring(id), tostring(old), tostring(ns)))
                else
                    work:call("set_slotNo", old)
                    debug_log(string.format("réparation mallette : objet %s case %s : aucune case libre", tostring(id), tostring(old)))
                end
            end
        end)
        for _, gui in ipairs(find_all_components("app.GUIInventory")) do pcall(function() gui:call("setupItemExtend") end) end
        debug_log("réparation mallette : APRÈS : " .. inventory_dump())
        last_tool_message = string.format("Mallette : %d objet(s) à 0 retiré(s), %d objet(s) superposé(s) replacé(s)", fixed, moved)
        if fixed + moved > 0 then
            add_message(string.format(tr("Mallette réparée : %d objet(s) replacé(s)", "Case repaired: %d item(s) moved"), fixed + moved))
        end
    end
    if requests.clear_fragments then
        requests.clear_fragments = nil
        local _, inv_f = get_active_inventory()
        local count = inventory_quantity(shop_ui.world.PICKUP_ID) or 0
        local ok_f, taken = pcall(shop_ui.inv_take, inv_f, shop_ui.world.PICKUP_ID, count)
        last_tool_message = string.format("Fragments de cristal : %s retiré(s) sur %d", ok_f and tostring(taken) or tostring(taken), count)
        debug_log(last_tool_message)
    end
    if requests.bug_report then
        requests.bug_report = nil
        local ok_r, err_r = pcall(shop_ui.help.write_report)
        if not ok_r then
            debug_log("rapport de bug : erreur " .. tostring(err_r))
            shop_ui.help.report_msg = tr("Erreur pendant le rapport : ", "Report error: ") .. tostring(err_r)
        end
    end
    if requests.trap then
        local key = requests.trap
        requests.trap = nil
        shop_ui.traps.apply({ trap = key })
    end
    if requests.say then
        local text = requests.say
        requests.say = nil
        if net.say(text) then debug_log("commande envoyée : " .. text) end
    end
    if requests.force_check then
        local loc = location_by_guid[requests.force_check]
        requests.force_check = nil
        if loc then
            debug_log("aide : check validé à la main : " .. loc.name)
            queue_check(loc)
        end
    end
    if shop_ui.fix_case_at and os.clock() >= shop_ui.fix_case_at then
        shop_ui.fix_case_at = nil
        requests.fix_zero = true
    end
    if requests.money then
        requests.money = false
        last_tool_message = give_money(1000) and "+1000 Lei" or "ECHEC Lei"
    end

    process_vanilla_removals()
    save_sync.update()
    shop_ui.sound.update()
    pcall(shop_ui.present.update)
    pcall(shop_ui.voice.update)
    pcall(shop_ui.voice.update_trap)
    death_link.update()
    process_items_queue()
    if i18n.key_diag and os.clock() >= i18n.key_diag.at then
        local parts = {}
        for i, id in ipairs(i18n.key_diag.levels) do parts[#parts + 1] = i .. "=" .. tostring(inventory_quantity(id)) end
        debug_log("clé progressive : quantités 3 s après le don : " .. table.concat(parts, " "))
        i18n.key_diag = nil
    end
    process_parcel()
    inventory_repair.update()
    snapshot_quantities()
    update_zone_stats()
    pcall(shop_ui.hud.update)
    pcall(shop_ui.menu.refresh)
    pcall(shop_ui.notice.update)
end)

re.on_frame(function()
    -- fenêtre bloquante : dessinée même si la pause du jeu fait passer « en jeu » à faux
    if is_in_game() or shop_ui.popup.modal or shop_ui.popup.anywhere then pcall(shop_ui.popup.draw) end
    pcall(shop_ui.traps.draw_flash)
    pcall(shop_ui.dialog.watch)
    if not K.SHOW_OVERLAY or not is_in_game() then return end
    local now = os.clock()
    local visible = {}
    for _, m in ipairs(messages) do
        if now - m.time < 10 then visible[#visible + 1] = m.text end
    end
    local connected = net_status == "connecté"
    -- 2026-10-08 (demande du joueur) : rien en haut à gauche sans connexion ou en mauvaise
    -- difficulté (fenêtres d'avertissement à la place, shop_ui.notice)
    if not connected or wrong_difficulty() then return end

    pcall(shop_ui.hud.draw_markers)
    -- Bandeau en haut à droite (2026-10-08, comme le mod de RE4 ; le détail des checks par zone est
    -- dans le menu REFramework). Tout est préparé AVANT begin_window, et le contenu est protégé par
    -- pcall : une erreur entre begin_window et end_window casse imgui et fait planter le jeu.
    local lines = shop_ui.hud.banner_lines()
    local w = 1920
    pcall(function()
        local size = imgui.get_display_size()
        if size and size.x > 0 then w = size.x end
    end)
    local placed = pcall(imgui.set_next_window_pos, Vector2f.new(w - 30, 30), 1, Vector2f.new(1.0, 0.0))
    if not placed then imgui.set_next_window_pos({ w - 460, 30 }) end
    imgui.begin_window("RE Village Archipelago", nil,
        1 | 2 | 4 | 8 | 64 | 128) -- sans titre, fixe, sans fond, taille auto
    pcall(function()
        for _, line in ipairs(lines) do imgui.text_colored(line[1], line[2]) end
        for _, text in ipairs(visible) do imgui.text(text) end
    end)
    imgui.end_window()
end)

local test_item_id = "3461208890" -- poudre
local test_item_count = "1"

---------------------------------------------------------------------------
-- Fenêtre du mod (2026-10-08, demande du joueur : comme le mod de RE4)
---------------------------------------------------------------------------
-- Fenêtre « RE Village Archipelago » affichée quand le menu REFramework est ouvert (touche Inser),
-- thème doré du mod. Onglets (boutons : pas d'onglets imgui dans cette version de REFramework) :
-- Checks (par zone puis par salle, checks manquants), Guidage (marqueurs), Connexion.
-- Les listes sont calculées dans la boucle du jeu (refresh, 1 fois par seconde) ; l'affichage ne
-- fait que dessiner. Numéros de couleurs / styles imgui : les stables (repris du mod de RE4).
shop_ui.menu = { data = nil, next_refresh = 0, ACCENT = 0xFF6AA8C8 } -- or #C8A86A (ABGR)
shop_ui.menu.TABS = { { "Checks", "Checks" }, { "Guidage", "Guidance" }, { "Hints", "Hints" },
    { "Journal", "Message log" }, { "Aide", "Help" }, { "Personnaliser", "Customize" }, { "Connexion", "Connection" } }
shop_ui.menu.ZONE_ORDER = { "Village", "Chateau Dimitrescu", "Maison Beneviento", "Reservoir", "Usine Heisenberg",
    "Chris", "Fin du jeu", "Boutique du Duc" }
shop_ui.menu.KIND_LABELS = { hunt = { "Chasse", "Hunting" }, recipe = { "Plats du Duc", "Duke's dishes" },
    bossdrop = { "Boss", "Bosses" }, shop = { "Articles du Duc", "Duke's items" } }
-- couleurs RGBA (0-1) : fenêtre sombre, accent or
shop_ui.menu.COLORS = {
    { 2, { 0.067, 0.071, 0.082, 0.97 } }, { 3, { 0.090, 0.094, 0.110, 1 } }, { 5, { 0.35, 0.30, 0.20, 1 } },
    { 7, { 0.13, 0.14, 0.17, 1 } }, { 8, { 0.18, 0.19, 0.23, 1 } }, { 9, { 0.22, 0.23, 0.27, 1 } },
    { 10, { 0.10, 0.09, 0.07, 1 } }, { 11, { 0.20, 0.17, 0.11, 1 } },
    { 18, { 0.784, 0.659, 0.416, 1 } }, { 19, { 0.784, 0.659, 0.416, 1 } }, { 20, { 0.85, 0.74, 0.51, 1 } },
    { 21, { 0.16, 0.17, 0.20, 1 } }, { 22, { 0.24, 0.22, 0.17, 1 } }, { 23, { 0.784, 0.659, 0.416, 1 } },
    { 24, { 0.17, 0.15, 0.11, 1 } }, { 25, { 0.25, 0.21, 0.14, 1 } }, { 26, { 0.32, 0.27, 0.17, 1 } },
    { 27, { 0.35, 0.30, 0.20, 1 } }, { 42, { 0.784, 0.659, 0.416, 1 } }, { 43, { 0.784, 0.659, 0.416, 1 } },
}
shop_ui.menu.VARS = { { 3, 8.0 }, { 12, 6.0 }, { 21, 6.0 }, { 2, { 12, 10 } }, { 11, { 8, 4 } }, { 14, { 8, 6 } } }

-- nom de check lisible : sans « [S01] » ni le code entre parenthèses des doublons
function shop_ui.menu.check_label(name)
    return (name:gsub(" %[S%d+%]", ""):gsub(" %(%x%x%x%x%x%x%x%x%)", ""))
end

-- Boucle du jeu : zones -> groupes (salle, ou type de check) -> checks manquants.
function shop_ui.menu.refresh()
    local m = shop_ui.menu
    if os.clock() < m.next_refresh then return end
    m.next_refresh = os.clock() + 1
    local zones, done_all, total_all = {}, 0, 0
    for guid, loc in pairs(location_by_guid) do
        local id = location_id_by_guid[guid]
        if id then
            local zname = loc.region or "?"
            local zone = zones[zname]
            if not zone then
                zone = { name = zname, done = 0, total = 0, groups = {} }
                zones[zname] = zone
            end
            local kind = m.KIND_LABELS[loc.kind or ""]
            local gname = kind and tr(kind[1], kind[2]) or nil
            if not gname then
                local room = room_cache.names[guid] or (loc.room_hash and room_name(loc.room_hash))
                gname = room and shop_ui.hud.short_room(room) or tr("Autres", "Other")
            end
            local group = zone.groups[gname]
            if not group then
                group = { name = gname, done = 0, total = 0, missing = {} }
                zone.groups[gname] = group
            end
            local done = checked_ids[id] == true
            zone.total, group.total, total_all = zone.total + 1, group.total + 1, total_all + 1
            if done then
                zone.done, group.done, done_all = zone.done + 1, group.done + 1, done_all + 1
            else
                group.missing[#group.missing + 1] = m.check_label(loc.name)
            end
        end
    end
    local list = {}
    for _, zname in ipairs(m.ZONE_ORDER) do
        if zones[zname] then list[#list + 1] = zones[zname]; zones[zname] = nil end
    end
    for _, zone in pairs(zones) do list[#list + 1] = zone end
    for _, zone in ipairs(list) do
        local groups = {}
        for _, g in pairs(zone.groups) do
            table.sort(g.missing)
            groups[#groups + 1] = g
        end
        table.sort(groups, function(a, b) return a.name < b.name end)
        zone.groups = groups
    end
    m.data = { zones = list, done = done_all, total = total_all }
    pcall(shop_ui.hints.refresh)
end

function shop_ui.menu.push_style()
    local n_vars, n_colors = 0, 0
    local a, b = shop_ui.hud.prefs.accent, shop_ui.hud.prefs.bar
    for _, c in ipairs(shop_ui.menu.COLORS) do
        if c[1] == 18 or c[1] == 19 or c[1] == 23 then c[2] = { a[1], a[2], a[3], 1 } end
        if c[1] == 20 then c[2] = { math.min(1, a[1] + 0.07), math.min(1, a[2] + 0.07), math.min(1, a[3] + 0.07), 1 } end
        if c[1] == 42 or c[1] == 43 then c[2] = { b[1], b[2], b[3], 1 } end
    end
    shop_ui.menu.ACCENT = 0xFF000000 | (math.floor(a[3] * 255) << 16) | (math.floor(a[2] * 255) << 8) | math.floor(a[1] * 255)
    for _, v in ipairs(shop_ui.menu.VARS) do
        local value = type(v[2]) == "table" and Vector2f.new(v[2][1], v[2][2]) or v[2]
        if pcall(imgui.push_style_var, v[1], value) then n_vars = n_vars + 1 end
    end
    for _, c in ipairs(shop_ui.menu.COLORS) do
        local col = c[2]
        if pcall(imgui.push_style_color, c[1], Vector4f.new(col[1], col[2], col[3], col[4])) then n_colors = n_colors + 1 end
    end
    return n_vars, n_colors
end

function shop_ui.menu.progress(done, total, label)
    if total <= 0 then return end
    if not pcall(imgui.progress_bar, done / total, Vector2f.new(-1, 0), label) then imgui.text(label) end
end

function shop_ui.menu.draw_checks()
    local data = shop_ui.menu.data
    if not data or data.total == 0 then
        imgui.text(tr("Connecte-toi à une partie Archipelago pour voir tes checks (onglet Connexion).",
            "Connect to an Archipelago game to see your checks (Connection tab)."))
        return
    end
    imgui.text_colored(string.format(tr("Checks trouvés : %d / %d", "Checks found: %d / %d"), data.done, data.total), shop_ui.menu.ACCENT)
    shop_ui.menu.progress(data.done, data.total, "")
    imgui.spacing()
    for zi, zone in ipairs(data.zones) do
        local label = string.format("%s   %d / %d##zone%d", shop_ui.hud.zone_name(zone.name), zone.done, zone.total, zi)
        if imgui.collapsing_header(label) then
            -- deux colonnes (tableau imgui, comme le mod de RE4) ; une seule si indisponible
            local ok_t, table_open = pcall(imgui.begin_table, "zone_table" .. zi, 2, 512 + 32768)
            local cols = ok_t and table_open
            for gi, g in ipairs(zone.groups) do
                if cols then pcall(imgui.table_next_column) end
                local text = string.format("%s - %d / %d", g.name, g.done, g.total)
                if #g.missing == 0 then
                    imgui.text_colored("   " .. text, 0xFF7FFF7F) -- salle terminée
                elseif imgui.tree_node(text .. "##g" .. zi .. "_" .. gi) then
                    for _, name in ipairs(g.missing) do imgui.text(name) end
                    imgui.tree_pop()
                end
            end
            if cols then pcall(imgui.end_table) end
        end
    end
end

function shop_ui.menu.draw_connection()
    -- Connexion (2026-10-08, demande du joueur : comme le client RE7, pour ceux qui installent le
    -- mod à la main sans le launcher). Valeurs gardées dans connection.json à la connexion, puis
    -- reconnexion automatique à chaque lancement du jeu.
    local status_color = net_status == "connecté" and 0xFF00FF7F or 0xFF7280FA
    imgui.text_colored(tr("Etat : ", "Status: ") .. i18n.status(net_status), status_color)
    local changed
    if net_status == "déconnecté" then
        imgui.text(tr("Entre les informations données par l'hôte de la partie, puis « Se connecter ».",
            "Enter the details given by the game's host, then \"Connect\"."))
        imgui.text(tr("Elles sont gardées : ensuite, le jeu se reconnecte tout seul à chaque lancement.",
            "They are kept: afterwards, the game reconnects by itself at every start."))
    end
    changed, conn.host = imgui.input_text(tr("Adresse (ex. archipelago.gg:38281)", "Address (e.g. archipelago.gg:38281)"), conn.host)
    changed, conn.slot = imgui.input_text(tr("Nom du slot", "Slot name"), conn.slot)
    changed, conn.password = imgui.input_text(tr("Mot de passe (facultatif)", "Password (optional)"), conn.password)
    if net_status == "déconnecté" then
        if imgui.button(tr("Se connecter", "Connect")) then
            conn.host = (conn.host:gsub("^%s+", ""):gsub("%s+$", ""))
            conn.slot = (conn.slot:gsub("^%s+", ""):gsub("%s+$", ""))
            conn.host = conn.host:gsub("^/connect%s+", "")
            if conn.host:match("^%d+$") then conn.host = "archipelago.gg:" .. conn.host end
            if conn.host ~= "" and conn.slot ~= "" then requests.connect = true end
        end
    else
        if imgui.button(tr("Se déconnecter", "Disconnect")) then requests.disconnect = true end
        if net_status ~= "connecté" then
            imgui.same_line()
            imgui.text(tr("(connexion en cours : le serveur ne répond pas encore)", "(connecting: the server is not answering yet)"))
        end
    end
    imgui.spacing()
    imgui.text(string.format(tr("Difficulté du jeu : %s ; demandée : %s", "Game difficulty: %s; required: %s"),
        tostring(difficulty_names and difficulty_names[game_difficulty] or "?"),
        required_difficulty and shop_ui.notice.diff_label(required_difficulty) or tr("au choix", "any")))
end

-- Journal (onglet) : messages du serveur, et une ligne pour écrire (message ou commande).
shop_ui.journal = { lines = {}, input = "" }
shop_ui.journal.COLORS = { Hint = 0xFFD08BE8, ItemSend = 0xFF6AA8C8, ItemCheat = 0xFF6AA8C8, Goal = 0xFF7FFF7F,
    Release = 0xFF7FFF7F, Collect = 0xFF7FFF7F, Join = 0xFFAAAAAA, Part = 0xFFAAAAAA, Chat = 0xFFFFFFFF,
    ServerChat = 0xFFFFFFFF, Countdown = 0xFFFFFFFF }
function shop_ui.journal.add(kind, text)
    local j = shop_ui.journal
    table.insert(j.lines, 1, { os.date("%H:%M"), kind or "", text })
    while #j.lines > 300 do table.remove(j.lines) end
end
function shop_ui.journal.draw()
    local j = shop_ui.journal
    local changed
    changed, j.input = imgui.input_text("##journal_input", j.input)
    imgui.same_line()
    if imgui.button(tr("Envoyer", "Send")) and j.input ~= "" then
        requests.say, j.input = j.input, ""
    end
    imgui.text(tr("Écris un message, ou une commande Archipelago (!hint objet, !release, !collect...).",
        "Type a message, or an Archipelago command (!hint item, !release, !collect...)."))
    imgui.separator()
    if #j.lines == 0 then
        imgui.text(tr("Aucun message pour l'instant : objets reçus et envoyés, hints et objectifs s'affichent ici.",
            "No messages yet: received and sent items, hints and goals show up here."))
    end
    for _, line in ipairs(j.lines) do
        imgui.text_colored("[" .. line[1] .. "] " .. line[3], j.COLORS[line[2]] or 0xFFFFFFFF)
    end
end

-- Hints (onglet) : liste du serveur (_read_hints), noms résolus dans la boucle du jeu (appels à la
-- DLL interdits depuis l'affichage) ; mes checks hintés pas trouvés -> marqueurs roses.
shop_ui.hints = { raw = {}, rows = {}, choices = {}, filter = "", choice = 1, dirty = false }
function shop_ui.hints.set(list)
    shop_ui.hints.raw, shop_ui.hints.dirty = list or {}, true
end
function shop_ui.hints.refresh()
    local hs = shop_ui.hints
    if not net.is_connected() then return end
    hs.points, hs.cost = net.hint_points()
    -- objets de mon jeu qu'on peut demander (nom affiché du mod + nom du serveur pour !hint)
    if #hs.choices == 0 then
        local seen = {}
        for _, it in ipairs(items) do
            if it.type ~= "Event" and it.type ~= "Money" and not seen[it.name] then
                seen[it.name] = true
                local id = nil
                for i, other in ipairs(items) do if other == it then id = 3908000000 + i - 1 end end
                local server = id and net.server_item_name(id)
                if server then hs.choices[#hs.choices + 1] = { label = i18n.item(it.name), server = server } end
            end
        end
        table.sort(hs.choices, function(a, b) return a.label < b.label end)
    end
    if not hs.dirty then return end
    hs.dirty = false
    local me = net.get_player_number()
    local rows, hinted = {}, {}
    for _, h in ipairs(hs.raw) do
        if h.receiving == me or h.finding == me then
            local receiver_game = net.get_player_game(h.receiving)
            local finder_game = net.get_player_game(h.finding)
            rows[#rows + 1] = {
                item = tostring(net.get_item_name(h.item, receiver_game) or h.item),
                receiver = net.get_player_alias(h.receiving),
                location = tostring(net.get_location_name(h.location, finder_game) or h.location),
                finder = net.get_player_alias(h.finding),
                found = h.found, mine_to_find = h.finding == me,
            }
            if h.finding == me and not h.found then hinted[h.location] = true end
        end
    end
    table.sort(rows, function(a, b) return (a.found and 1 or 0) < (b.found and 1 or 0) end)
    hs.rows = rows
    shop_ui.hud.hinted = hinted
end
function shop_ui.hints.draw()
    local hs = shop_ui.hints
    if net_status ~= "connecté" then -- état calculé par la boucle du jeu (pas d'appel à la DLL ici)
        imgui.text(tr("Connecte-toi pour voir et acheter des hints (onglet Connexion).", "Connect to see and buy hints (Connection tab)."))
        return
    end
    imgui.text(tr("Un hint coûte des points, gagnés en faisant des checks. Il dit où se trouve un de tes objets.",
        "A hint costs points, earned by finding checks. It tells you where one of your items is."))
    imgui.text_colored(string.format(tr("Points de hint : %s | Coût d'un hint : %s", "Hint points: %s | Cost per hint: %s"),
        tostring(hs.points or "?"), tostring(hs.cost or "?")), shop_ui.menu.ACCENT)
    imgui.spacing()
    imgui.text_colored(tr("Où est mon objet ?", "Where is my item?"), shop_ui.menu.ACCENT)
    local changed
    changed, hs.filter = imgui.input_text(tr("Filtrer", "Filter"), hs.filter)
    local labels, servers = {}, {}
    local f = hs.filter:lower()
    for _, c in ipairs(hs.choices) do
        if f == "" or c.label:lower():find(f, 1, true) then
            labels[#labels + 1] = c.label
            servers[#servers + 1] = c.server
        end
    end
    if #labels > 0 then
        if hs.choice > #labels then hs.choice = 1 end
        changed, hs.choice = imgui.combo(tr("Objet", "Item"), hs.choice, labels)
        if imgui.button(tr("Acheter un hint pour cet objet", "Buy a hint for this item")) then
            requests.say = "!hint " .. servers[hs.choice]
        end
    else
        imgui.text(tr("Aucun objet ne correspond.", "No matching item."))
    end
    imgui.spacing()
    imgui.separator()
    imgui.text_colored(string.format(tr("Hints de la partie (%d)", "Game hints (%d)"), #hs.rows), shop_ui.menu.ACCENT)
    for _, r in ipairs(hs.rows) do
        local line = string.format(tr("%s pour %s : %s (chez %s)%s", "%s for %s: %s (in %s's world)%s"), r.item, r.receiver,
            r.location, r.finder, r.found and tr(" - trouvé", " - found") or "")
        imgui.text_colored(line, r.found and 0xFFAAAAAA or (r.mine_to_find and 0xFFD08BE8 or 0xFFFFFFFF))
    end
end

-- Aide (onglet) : boutons en cas de souci (2026-10-08, demande du joueur : remplace les outils
-- de dev pour les vrais joueurs).
shop_ui.help = { confirm = nil }
-- Rapport de bug (2026-10-08, demande du joueur) : instantané de la partie dans bug_report.json,
-- ajouté au zip du launcher. Construit dans la boucle du jeu (appels au jeu et à la DLL).
function shop_ui.help.write_report()
    local report = {
        mod_version = K.MOD_VERSION, date = os.date("%Y-%m-%d %H:%M:%S"), clock = os.clock(),
        seed = session and tostring(session.seed) or nil, slot = conn.slot, host = conn.host,
        auto_connect = conn.auto, status = net_status, in_game = is_in_game(),
        chapter = tostring(shop_ui.chapter), zone = current_zone,
        room = shop_ui.hud_room and shop_ui.hud_room.name or nil,
        difficulty_game = difficulty_names and difficulty_names[game_difficulty] or tostring(game_difficulty),
        difficulty_required = required_difficulty, wrong_difficulty = wrong_difficulty(),
        checks_done = checked_count, checks_total = total_locations,
        pending_checks = #state.pending_checks, last_applied_index = state.last_applied_index,
        items_queue = #items_queue, parcel = state.parcel, money = get_money(),
        inventory = inventory_dump(), messages = {}, journal = {}, prefs = shop_ui.hud.prefs,
        hints = #shop_ui.hints.rows, traps_jam_left = math.max(0, shop_ui.traps.jam_until - os.clock()),
    }
    for _, m in ipairs(messages) do report.messages[#report.messages + 1] = m.text end
    for i, line in ipairs(shop_ui.journal.lines) do
        if i > 50 then break end
        report.journal[#report.journal + 1] = line[1] .. " [" .. line[2] .. "] " .. line[3]
    end
    json.dump_file(MOD_NAME .. "/bug_report.json", report)
    debug_log("rapport de bug écrit (bug_report.json)")
    shop_ui.help.report_msg = tr("Rapport créé (" .. report.date .. "). Fais maintenant « Rapport de bug » dans le launcher.",
        "Report created (" .. report.date .. "). Now use \"Bug report\" in the launcher.")
end
function shop_ui.help.draw()
    local hp = shop_ui.help
    imgui.text(tr("Quelque chose ne va pas ? Ces boutons règlent les problèmes les plus courants.",
        "Something wrong? These buttons fix the most common problems."))
    imgui.spacing()
    imgui.text_colored(tr("Objets reçus manquants", "Missing received items"), shop_ui.menu.ACCENT)
    imgui.text(tr("Après un plantage ou une vieille sauvegarde : redonne tous les objets Archipelago reçus.",
        "After a crash or an old save: gives back every Archipelago item received."))
    if imgui.button(tr("Redonner tous les objets reçus", "Give back all received items")) then
        save_sync.force_all = true
        save_sync.loaded = true
    end
    imgui.text(tr("Objet clé perdu (sauvegarde rechargée) : liste les objets clés reçus absents de la mallette.",
        "Key item lost (save reloaded): lists the received key items missing from the case."))
    imgui.text(tr("Ceux déjà utilisés dans le jeu (reliefs posés, clés de porte...) y sont aussi : redonne seulement celui qui te manque.",
        "Those already used in the game (placed reliefs, door keys...) are listed too: only give back the one you lack."))
    if imgui.button(tr("Chercher les objets clés manquants", "Find missing key items")) then
        save_sync.missing_keys = true
    end
    local missing = save_sync.missing_list
    if missing then
        if #missing == 0 then imgui.text(tr("  Aucun : tous tes objets clés reçus sont dans la mallette.", "  None: all your received key items are in the case.")) end
        for i, m in ipairs(missing) do
            if imgui.button(tr("Redonner", "Give back") .. "##key" .. i) then
                save_sync.give_index = m.index
                table.remove(missing, i)
                break
            end
            imgui.same_line()
            imgui.text(i18n.item(m.name))
        end
    end
    imgui.spacing()
    imgui.text_colored(tr("Mallette bizarre", "Weird case"), shop_ui.menu.ACCENT)
    imgui.text(tr("Objets superposés, quantité 0, case qu'on ne peut pas utiliser : remet la mallette en ordre.",
        "Overlapping items, quantity 0, unusable slot: puts the case back in order."))
    if imgui.button(tr("Réparer la mallette", "Repair the case")) then requests.fix_zero = true end
    imgui.spacing()
    imgui.text_colored(tr("Check bloqué", "Stuck check"), shop_ui.menu.ACCENT)
    imgui.text(tr("Un objet impossible à ramasser ou un check qui ne part pas : valide un check à moins de 10 m.",
        "An item you cannot pick up or a check that does not send: sends a check within 10 m."))
    local nearby = shop_ui.hud.nearby or {}
    if #nearby == 0 then
        imgui.text(tr("(aucun check pas fait à moins de 10 m)", "(no unchecked spot within 10 m)"))
    end
    for i, n in ipairs(nearby) do
        if i > 6 then break end
        imgui.text(string.format("%s (%d m)", shop_ui.menu.check_label(n.name), math.floor(n.d + 0.5)))
        imgui.same_line()
        if hp.confirm == n.guid then
            if imgui.button(tr("Confirmer##c", "Confirm##c") .. i) then
                requests.force_check, hp.confirm = n.guid, nil
            end
            imgui.same_line()
            if imgui.button(tr("Annuler##a", "Cancel##a") .. i) then hp.confirm = nil end
        elseif imgui.button(tr("Valider##v", "Send##v") .. i) then
            hp.confirm = n.guid
        end
    end
    imgui.spacing()
    imgui.text_colored(tr("Partie terminée ?", "Finished the game?"), shop_ui.menu.ACCENT)
    imgui.text(tr("Une fois ton objectif atteint : Release envoie aux autres tous tes objets restants, Collect récupère les tiens.",
        "Once your goal is done: Release sends your remaining items to the others, Collect gets yours."))
    if imgui.button("Release") then requests.say = "!release" end
    imgui.same_line()
    if imgui.button("Collect") then requests.say = "!collect" end
    imgui.spacing()
    imgui.text_colored(tr("Signaler un bug", "Report a bug"), shop_ui.menu.ACCENT)
    imgui.text(tr("1. Juste après le bug, clique ici : le mod note l'état de ta partie (bug_report.json).",
        "1. Right after the bug, click here: the mod records your game state (bug_report.json)."))
    if imgui.button(tr("Créer un rapport de bug", "Create a bug report")) then requests.bug_report = true end
    if shop_ui.help.report_msg then imgui.text_colored(shop_ui.help.report_msg, 0xFF7FFF7F) end
    imgui.text(tr("2. Launcher > « Rapport de bug » : zip de tous les journaux sur ton Bureau, à envoyer au développeur.",
        "2. Launcher > \"Bug report\": zips all the logs on your Desktop, to send to the developer."))
    imgui.text(tr("   Sans launcher : envoie le dossier reframework\\data\\re_village_ap_client du jeu (zippé).",
        "   Without the launcher: send the game's reframework\\data\\re_village_ap_client folder (zipped)."))
end

-- Personnaliser (onglet) : couleur principale et couleur des barres, gardées sur ce PC.
shop_ui.menu.PRESETS = {
    { { "Or", "Gold" }, { 0.784, 0.659, 0.416 } }, { { "Bleu Archipelago", "Archipelago blue" }, { 0.31, 0.63, 1.0 } },
    { { "Rouge sang", "Blood red" }, { 0.78, 0.22, 0.22 } }, { { "Vert plante", "Herb green" }, { 0.36, 0.70, 0.36 } },
    { { "Violet", "Violet" }, { 0.62, 0.42, 0.88 } }, { { "Blanc os", "Bone white" }, { 0.90, 0.88, 0.82 } },
}
function shop_ui.menu.draw_customize()
    local p = shop_ui.hud.prefs
    for _, row in ipairs({ { "accent", tr("Couleur principale (onglet actif, titres, cases)", "Main colour (active tab, titles, checkboxes)") },
            { "bar", tr("Barres de progression", "Progress bars") } }) do
        imgui.text_colored(row[2], shop_ui.menu.ACCENT)
        for i, preset in ipairs(shop_ui.menu.PRESETS) do
            if i > 1 then imgui.same_line() end
            local c = preset[2]
            local pushed = 0
            for _, idx in ipairs({ 21, 22, 23 }) do
                if pcall(imgui.push_style_color, idx, Vector4f.new(c[1], c[2], c[3], 1)) then pushed = pushed + 1 end
            end
            local dark = c[1] * 0.3 + c[2] * 0.59 + c[3] * 0.11 > 0.5
            if pcall(imgui.push_style_color, 0, dark and Vector4f.new(0.05, 0.05, 0.05, 1) or Vector4f.new(1, 1, 1, 1)) then pushed = pushed + 1 end
            if imgui.button(tr(preset[1][1], preset[1][2]) .. "##" .. row[1] .. i) then
                p[row[1]] = { c[1], c[2], c[3] }
                shop_ui.hud.save_prefs()
            end
            if pushed > 0 then pcall(imgui.pop_style_color, pushed) end
        end
        imgui.spacing()
    end
    shop_ui.menu.progress(7, 10, tr("7 / 10, exemple", "7 / 10, sample"))
    if imgui.button(tr("Couleurs par défaut", "Default colours")) then
        p.accent, p.bar = { 0.784, 0.659, 0.416 }, { 0.784, 0.659, 0.416 }
        shop_ui.hud.save_prefs()
    end
end

function shop_ui.menu.draw()
    local p = shop_ui.hud.prefs
    if not p.window or not reframework:is_drawing_ui() then return end
    local n_vars, n_colors = shop_ui.menu.push_style()
    pcall(imgui.set_next_window_size, Vector2f.new(860, 560), 4)
    local still_open = imgui.begin_window("RE Village Archipelago##ap_window", true, 0)
    local ok, err = pcall(function()
        for i, t in ipairs(shop_ui.menu.TABS) do
            if i > 1 then imgui.same_line() end
            local active = (p.tab == i)
            local pushed = 0
            if active then
                local a = p.accent
                for _, idx in ipairs({ 21, 22, 23 }) do
                    if pcall(imgui.push_style_color, idx, Vector4f.new(a[1], a[2], a[3], 1)) then pushed = pushed + 1 end
                end
                if pcall(imgui.push_style_color, 0, Vector4f.new(0.09, 0.075, 0.04, 1)) then pushed = pushed + 1 end
            end
            if imgui.button(tr(t[1], t[2]) .. "##tab" .. i) and p.tab ~= i then
                p.tab = i
                shop_ui.hud.save_prefs()
            end
            if pushed > 0 then pcall(imgui.pop_style_color, pushed) end
        end
        imgui.separator()
        local tab_draw = { shop_ui.menu.draw_checks, shop_ui.hud.draw_ui, shop_ui.hints.draw, shop_ui.journal.draw,
            shop_ui.help.draw, shop_ui.menu.draw_customize, shop_ui.menu.draw_connection }
        if p.tab < 1 or p.tab > #tab_draw then p.tab = 1 end
        tab_draw[p.tab]()
    end)
    imgui.end_window()
    if n_colors > 0 then pcall(imgui.pop_style_color, n_colors) end
    if n_vars > 0 then pcall(imgui.pop_style_var, n_vars) end
    if still_open == false then
        p.window = false
        shop_ui.hud.save_prefs()
    end
    if not ok and shop_ui.menu.last_error ~= tostring(err) then
        shop_ui.menu.last_error = tostring(err)
        debug_log("fenêtre du mod : erreur " .. tostring(err))
    end
end
re.on_frame(function() pcall(shop_ui.menu.draw) end)

re.on_draw_ui(function()
    if not imgui.tree_node("RE Village Archipelago") then return end

    local w_changed, w_show = imgui.checkbox(tr("Afficher la fenêtre du mod (checks, guidage, connexion)",
        "Show the mod window (checks, guidance, connection)"), shop_ui.hud.prefs.window)
    if w_changed then
        shop_ui.hud.prefs.window = w_show
        shop_ui.hud.save_prefs()
    end
    local status_color = net_status == "connecté" and 0xFF00FF7F or 0xFF7280FA
    imgui.text_colored(tr("Etat : ", "Status: ") .. i18n.status(net_status), status_color)
    if #state.parcel > 0 then
        imgui.text(string.format(tr("Colis (mallette pleine) : %d objet(s) : %s", "Parcel (case full): %d item(s): %s"), #state.parcel,
            table.concat(state.parcel, ", ")))
    end
    if shop_ui.DEV and imgui.tree_node("Outils de développement") then
        shop_ui.no_return.draw_ui()
        shop_ui.dialog.draw_ui()
        if session then
            imgui.text(string.format("Session %s / %s, dernier item : %d, checks en attente : %d",
                tostring(session.seed), tostring(session.slot), state.last_applied_index, #state.pending_checks))
        end
        -- Réglage en direct de la taille du modèle Archipelago dans la boutique (2026-09-26).
        local scale_changed, new_scale = imgui.drag_float("Echelle du modele AP", shop_ui.AP_PREVIEW_SCALE, 0.002, 0.005, 2.0)
        if scale_changed then
            shop_ui.AP_PREVIEW_SCALE = new_scale
            shop_ui.preview_rescale = true
        end
        -- Objets AP au sol (2026-09-29) : placement par boîtes englobantes, taille réglable.
        -- Pris en compte pour les objets remplacés ensuite (la taille : tout de suite).
        local g = shop_ui.world.GROUND
        local g_changed, g_on = imgui.checkbox("Objets au sol : placement par boites (nouveau)", g.enabled)
        if g_changed then g.enabled = g_on end
        local gs_changed, gs = imgui.drag_float("Objets au sol : echelle", g.scale, 0.01, 0.1, 5.0)
        if gs_changed then g.scale = gs end
        local ga_changed, ga = imgui.drag_float("Objets au sol : echelle du logo AP", g.ap_scale, 0.01, 0.1, 10.0)
        if ga_changed then g.ap_scale = ga end
        local gf_changed, gf = imgui.drag_float("Objets au sol : taille max (x objet d'origine)", g.fit, 0.05, 0.5, 5.0)
        if gf_changed then g.fit = gf end
        local gm_changed, gm = imgui.drag_float("Objets au sol : taille min (m)", g.min_size, 0.01, 0.0, 1.0)
        if gm_changed then g.min_size = gm end
        local gv_changed, gv = imgui.drag_float("Objets au sol : taille d'affichage min (m)", g.min_visible, 0.01, 0.0, 1.0)
        if gv_changed then g.min_visible = gv end
        local gh_changed, gh = imgui.drag_float("Objets au sol : hauteur max (x objet d'origine)", g.fit_h, 0.05, 0.5, 10.0)
        if gh_changed then g.fit_h = gh end
        if imgui.button("Relever les sons de ramassage (journal)") then shop_ui.sound.install_capture() end
        local ip_changed, ip = imgui.checkbox("Ramassage : modifier l'objet d'origine (EXPERIMENTAL, son / presentation)", shop_ui.world.INPLACE == true)
        if ip_changed then
            shop_ui.world.INPLACE = ip
            debug_log("objet au sol : ramassage par objet d'origine modifié : " .. tostring(ip) .. " (objets posés ensuite)")
        end
        local hi_changed, hi = imgui.checkbox("Cacher l'icone au ramassage (DispItemIcon, test du son)", shop_ui.world.HIDE_ICON)
        if hi_changed then
            shop_ui.world.HIDE_ICON = hi
            -- Appliqué tout de suite aux objets déjà posés.
            for _, rec in pairs(shop_ui.world.swapped) do
                pcall(function() rec.si:get_field("SpawnedInteractItemGetCache"):set_field("DispItemIcon", not hi) end)
            end
            for _, rec in pairs(shop_ui.world.kept) do
                pcall(function() rec.si:get_field("SpawnedInteractItemGetCache"):set_field("DispItemIcon", not hi) end)
            end
            debug_log("objet au sol : icône au ramassage " .. (hi and "cachée" or "affichée"))
        end
        if imgui.button("Redonner tous les objets recus (sauvegarde d'avant la seed / plantage)") then
            save_sync.force_all = true
            save_sync.loaded = true
        end
        local hl = g.host_lift["character/it/it04/020/it04_020_herb_green.mesh"]
        local hl_changed, hl_new = imgui.drag_float("Objets au sol : hauteur sur une Plante (x sa hauteur)", hl, 0.01, 0.0, 1.0)
        if hl_changed then
            g.host_lift["character/it/it04/020/it04_020_herb_green.mesh"] = hl_new
            debug_log(string.format("objet au sol : hauteur sur une Plante : %.2f", hl_new))
        end
        if imgui.button("Diagnostic des objets AP proches (journal)") then
            local ok_d, err_d = pcall(shop_ui.world.diagnose)
            if not ok_d then debug_log("diagnostic : erreur " .. tostring(err_d)) end
        end
        -- Multiplicateur de l'échelle des vrais modèles (Plante, Ferraille…) dans la boutique
        -- (2026-09-29) ; la valeur finale est notée dans le journal.
        local real_changed, real_mult = imgui.drag_float("Echelle des vrais modeles (boutique)", shop_ui.REAL_SCALE_MULT, 0.01, 0.1, 5.0)
        if real_changed then
            shop_ui.REAL_SCALE_MULT = real_mult
            shop_ui.preview_rescale = true
        end
        -- Rotation du modèle affiché dans la boutique (2026-09-27, pour regarder le logo sous
        -- tous les angles). Degrés autour de X, Y, Z ; 0/0/0 = rotation d'origine.
        shop_ui.preview_rot = shop_ui.preview_rot or { 0, 0, 0 }
        for i, axis in ipairs({ "X", "Y", "Z" }) do
            local rot_changed, v = imgui.slider_float("Rotation " .. axis .. " (boutique)", shop_ui.preview_rot[i], -180, 180)
            if rot_changed then shop_ui.preview_rot[i] = v end
        end
        if imgui.button("Rotation : remise à zéro") then shop_ui.preview_rot = { 0, 0, 0 } end
        -- (Curseurs de position retirés : la boutique repositionne l'objet affiché à chaque image,
        -- le centrage se fait dans le maillage, tools/re_engine/blender_make_ap_mesh.py.)
        if imgui.button("Scanner la zone") then requests.scan = true end
        if imgui.button("Relever la boutique") then requests.shop = true end
        if imgui.button("Catalogue des objets") then requests.catalog = true end
        if imgui.button("Retirer tous les Fragments de cristal (accumulés par le bug du retrait)") then
            requests.clear_fragments = true
        end
        imgui.text("Tester un piège :")
        for _, key in ipairs({ "bankrupt", "screamer", "jam", "damage", "empty_mag" }) do
            imgui.same_line()
            if imgui.button(key .. "##trap") then requests.trap = key end
        end
        if imgui.button("Relever les noms FR / EN (objets, salles, plats)") then requests.names = true end
        if imgui.button("Relever les plats du Duc") then requests.recipes = true end
        changed, shop_experiment = imgui.checkbox("EXPERIENCE : article de test chez le Duc (1 poudre pour 1 Lei)", shop_experiment)
        changed, shop_ui.ap_test = imgui.checkbox("TEST : logo AP à la place des vrais modèles dans la boutique (Ferraille, Plante...)", shop_ui.ap_test == true)
        changed, test_item_id = imgui.input_text("ItemID", test_item_id)
        changed, test_item_count = imgui.input_text("Quantite", test_item_count)
        if imgui.button("TEST : donner l'objet") then
            requests.give = { id = tonumber(test_item_id), count = tonumber(test_item_count) or 1 }
        end
        if imgui.button("TEST : +1000 Lei") then requests.money = true end
        if imgui.button("REPARER la mallette (objets superposés, quantité 0)") then requests.fix_zero = true end
        if imgui.button("DIAG : modèles au sol (texture manquante)") then
            -- 2026-09-27 : boîte de munitions sans texture. Compare nos objets modifiés à ceux du
            -- jeu qui ont le même maillage (matériau, nombre de matériaux, chargement).
            pcall(function()
                local describe = function(m)
                    local out = {}
                    pcall(function() out[#out + 1] = "mesh=" .. tostring(m:call("getMesh"):call("get_ResourcePath")) end)
                    pcall(function() out[#out + 1] = "mdf=" .. tostring(m:call("get_Material"):call("get_ResourcePath")) end)
                    for _, getter in ipairs({ "get_MaterialNum", "get_DrawDefault", "get_Enabled", "get_LodMode",
                            "get_LodLevel", "get_LodCount", "getTextureCount", "getPartsEnableCount",
                            "getMaterialsEnableCount", "get_MaterialParamCount", "get_StreamingPriority" }) do
                        pcall(function() out[#out + 1] = getter .. "=" .. tostring(m:call(getter)) end)
                    end
                    pcall(function()
                        local n = m:call("getMaterialTextureNum", 0)
                        local texs = {}
                        for i = 0, math.min(n, 12) - 1 do
                            local name = m:call("getMaterialTextureName", 0, i)
                            local path = "?"
                            pcall(function() path = m:call("getMaterialTexture", 0, i):call("get_ResourcePath") end)
                            texs[#texs + 1] = tostring(name) .. "=" .. tostring(path)
                        end
                        out[#out + 1] = "textures(mat0)=[" .. table.concat(texs, ", ") .. "]"
                    end)
                    pcall(function()
                        local parts = {}
                        for i = 0, math.min(m:call("getPartsEnableCount"), 8) - 1 do
                            parts[#parts + 1] = tostring(m:call("getPartsEnable", i))
                        end
                        out[#out + 1] = "parts=[" .. table.concat(parts, ",") .. "]"
                    end)
                    pcall(function() out[#out + 1] = "objet=" .. tostring(m:call("get_GameObject"):call("get_Name")) end)
                    -- Logo "en œufs" dans un tiroir : échelles de toute la chaîne des parents.
                    pcall(function()
                        local chain = {}
                        local tf = m:call("get_GameObject"):call("get_Transform")
                        while tf and #chain < 8 do
                            local ls = tf:call("get_LocalScale")
                            local ws = shop_ui.world.world_scale(tf) or { x = -1, y = -1, z = -1 }
                            chain[#chain + 1] = string.format("%s[local %.3f %.3f %.3f | monde %.3f %.3f %.3f | joint %s]",
                                tostring(tf:call("get_GameObject"):call("get_Name")), ls.x, ls.y, ls.z, ws.x, ws.y, ws.z,
                                tostring(tf:call("get_ParentJoint")))
                            tf = tf:call("get_Parent")
                        end
                        out[#out + 1] = "parents=" .. table.concat(chain, " < ")
                    end)
                    return table.concat(out, " ")
                end
                local ours = {}
                for _, rec in pairs(shop_ui.world.swapped) do
                    for _, m in ipairs(rec.meshes or {}) do
                        ours[m:get_address()] = true
                        debug_log("DIAG modèle (mod) " .. tostring(rec.loc and rec.loc.name) .. " : " .. describe(m))
                    end
                end
                local count = 0
                for _, m in ipairs(find_all_components("via.render.Mesh")) do
                    if not ours[m:get_address()] and count < 15 then
                        local path = ""
                        pcall(function() path = m:call("getMesh"):call("get_ResourcePath") end)
                        if path:find("Character/It/", 1, true) or path:find("sm92_", 1, true) then
                            count = count + 1
                            debug_log("DIAG modèle (jeu) : " .. describe(m))
                        end
                    end
                end
            end)
            last_tool_message = "Diagnostic écrit dans debug_log.txt"
        end
        imgui.text("Sons du jeu (début de présentation) :")
        if imgui.button("Écouter : son objet clé (2961364839)") then shop_ui.sound.play(shop_ui.sound.GAME.KEY) end
        if imgui.button("Écouter : son trésor / ressource (3769661010)") then shop_ui.sound.play(shop_ui.sound.GAME.TREASURE) end
        if imgui.button("Écouter : son AP piège pour un autre joueur (langue du jeu)") then
            local id, lang = shop_ui.sound.voice_id(shop_ui.sound.AP.TRAP_FOR_OTHER)
            shop_ui.sound.play_ap(id)
            last_tool_message = "son AP " .. tostring(id) .. " (langue " .. tostring(lang) .. ")"
        end
        if imgui.button("Écouter : rire de Dimitrescu (piège reçu)") then
            shop_ui.sound.play_ap((shop_ui.sound.voice_id(shop_ui.sound.AP.TRAP_LAUGH)))
        end
        imgui.same_line()
        if imgui.button("Écouter : cri de Bela (screamer)") then
            shop_ui.sound.play_ap((shop_ui.sound.voice_id(shop_ui.sound.AP.TRAP_SCREAM)))
        end
        if imgui.button("TEST : trigger neuf -> jingle trésor (1788264539)") then shop_ui.sound.play(shop_ui.sound.AP.TEST_TREASURE) end
        -- Diagnostic (2026-10-07 : son AP muet) : relevé des voix (20 s) puis son AP et jingle
        -- trésor ; le journal dit si le jeu a lancé une requête de son (« triggered ») pour chacun.
        -- 2e diagnostic : les sons système ne passent pas par « triggered ». On liste les
        -- ressources (listes de sons .wel) du conteneur système d'app.WwiseManagerApp.
        if imgui.button("DIAG : listes de sons du conteneur système") then
            local ok, err = pcall(function()
                local c = sdk.get_managed_singleton("app.WwiseManagerApp"):get_field("SystemContainer")
                local n = c:call("getContainableAssetCount")
                debug_log("son système : " .. tostring(n) .. " ressource(s), objet " .. tostring(c:call("get_GameObject"):call("get_Name")))
                for i = 0, n - 1 do
                    local h = c:call("getContainableAsset", i)
                    local path = "?"
                    pcall(function() path = h:call("get_ResourcePath") end)
                    debug_log("son système : ressource " .. i .. " = " .. tostring(path))
                end
            end)
            last_tool_message = ok and "Listes écrites dans le journal (« son système : »)" or ("erreur : " .. tostring(err))
        end
        if imgui.button("DIAG : son AP (relevé + son AP + jingle trésor)") then
            shop_ui.voice.start()
            shop_ui.sound.play((shop_ui.sound.voice_id(shop_ui.sound.AP.TRAP_FOR_OTHER)))
            shop_ui.sound.play(shop_ui.sound.GAME.TREASURE)
            last_tool_message = "DIAG son AP : résultat dans 20 s (journal « voix : »)"
        end
        imgui.text("Voix des personnages (rire, réplique) :")
        if imgui.button("Relever les voix (20 s, journal)") then
            shop_ui.voice.start()
            last_tool_message = "Relevé des voix : 20 s, fais parler/rire le personnage"
        end
        changed, shop_ui.voice.id_text = imgui.input_text("ID son", shop_ui.voice.id_text)
        if imgui.button("Jouer : son système") then last_tool_message = shop_ui.voice.play(tonumber(shop_ui.voice.id_text), "system") end
        imgui.same_line()
        if imgui.button("Jouer : sur Ethan") then last_tool_message = shop_ui.voice.play(tonumber(shop_ui.voice.id_text), "ethan") end
        imgui.same_line()
        if imgui.button("Jouer : sur le personnage") then last_tool_message = shop_ui.voice.play(tonumber(shop_ui.voice.id_text), "owner") end
        if imgui.button("TEST fichier audio : os.execute (tada.wav)") then
            last_tool_message = shop_ui.voice.play_file(shop_ui.voice.TEST_WAV, "execute")
        end
        imgui.same_line()
        if imgui.button("TEST fichier audio : io.popen (tada.wav)") then
            last_tool_message = shop_ui.voice.play_file(shop_ui.voice.TEST_WAV, "popen")
        end
        if imgui.button("TEST : piège ramassé pour un autre joueur") then
            shop_ui.voice.trap_pending = true
            last_tool_message = "Piège pour un autre joueur simulé (voir journal « son : »)"
        end
        if imgui.button("Jouer : personnage, position d'Ethan") then last_tool_message = shop_ui.voice.play(tonumber(shop_ui.voice.id_text), "owner_at_ethan") end
        imgui.text("Présentation d'un objet reçu (ItemID ci-dessus, ex. Bague 2183898626) :")
        if imgui.button("TEST présentation : méthode 1 (ramassage forcé)") then
            pcall(shop_ui.present.start, tonumber(test_item_id), 1)
            last_tool_message = "Présentation (test) méthode 1 : voir debug_log.txt"
        end
        if imgui.button("TEST présentation : méthode 2 (présentation directe)") then
            pcall(shop_ui.present.start, tonumber(test_item_id), 2)
            last_tool_message = "Présentation (test) méthode 2 : voir debug_log.txt"
        end
        if imgui.button("TEST : DeathLink reçu (game over)") then
            -- Simule la mort d'un autre joueur (même si DeathLink est désactivé dans le yaml).
            death_link.pending = { source = "TEST", cause = "" }
            death_link.test = true
        end

        if last_tool_message ~= "" then imgui.text(last_tool_message) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

log.info(string.format("[%s] Chargé : %d locations, %d items.", MOD_NAME, total_locations, #items))
