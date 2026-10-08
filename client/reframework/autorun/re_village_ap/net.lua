--[[
    Connexion Archipelago pour le client RE Village (remplace AP_REF, repris du client RE7).

    ⚠️ RÈGLE CRITIQUE — deux interpréteurs Lua différents partagent les mêmes données :
    REFramework embarque Lua 5.4.3, lua-apclientpp.dll embarque sa propre copie (5.4.7).
    Les rappels (handlers) du module réseau sont exécutés par la copie de la DLL. Prouvé hors
    du jeu le 2026-09-25 (tools/test_net_offline.lua) : une table à clés numériques remplie
    dans un rappel est illisible côté REFramework (t[id] == nil, "invalid key to 'next'"),
    et une table de REFramework relue après être passée à la DLL peut boucler à l'infini
    (freezes du jeu en ramassant un objet). Donc :
      1. Dans un rappel : lire les arguments, fabriquer du TEXTE avec l'opérateur ..
         (+ string.format), et le déposer dans la boîte `inbox` (clés texte uniquement).
         Aucune fonction table.*, aucune écriture dans une autre table.
      2. Côté REFramework : toujours donner à la DLL une table NEUVE, jamais réutilisée.
      3. Les messages de la boîte sont décodés par net.poll(), côté REFramework.
]]

local net = {}

local AP = nil
local client = nil
local load_error = nil

-- Chargement borné de la DLL (le client RE7 bouclait à l'infini en cas d'échec).
do
    local opener, err = package.loadlib("lua-apclientpp.dll", "luaopen_apclientpp")
    if opener then
        local ok, mod = pcall(opener)
        if ok then AP = mod else load_error = tostring(mod) end
    else
        load_error = tostring(err)
    end
end

-- Boîte aux lettres : clés texte "m1", "m2"... et le compteur dans le champ texte "n".
local inbox = { n = 0, read = 0 }

local function post(kind, payload)
    local n = inbox.n + 1
    inbox["m" .. n] = kind .. "|" .. (payload or "")
    inbox.n = n
end

net.game_name = ""
net.host, net.slot, net.password = "localhost:38281", "", ""

function net.load_error() return load_error end

function net.state()
    if not client then return "déconnecté" end
    local ok, st = pcall(function() return client:get_state() end)
    if not ok then return "déconnecté" end
    if st == AP.State.SLOT_CONNECTED then return "connecté" end
    if st == AP.State.DISCONNECTED then return "déconnecté" end
    return "connexion"
end

function net.is_connected()
    return net.state() == "connecté"
end

function net.connect(host, slot, password)
    if not AP then return false end
    net.disconnect()
    net.host, net.slot, net.password = host, slot, password or ""
    local uri = host
    -- Sans protocole : ws:// en local, wss:// ailleurs (archipelago.gg n'accepte que wss ;
    -- 2026-10-08, adresse tapée à la main dans le menu). Le launcher écrit l'adresse complète.
    if not uri:find("://") then
        local local_host = uri:match("^localhost") or uri:match("^127%.") or uri:match("^192%.168%.") or uri:match("^10%.")
        uri = (local_host and "ws://" or "wss://") .. uri
    end
    client = AP("", net.game_name, uri)

    -- Tous les rappels ci-dessous tournent dans le Lua de la DLL : voir la règle en tête.
    client:set_socket_connected_handler(function() post("socket", "") end)
    client:set_socket_error_handler(function(e) post("error", "" .. (e or "")) end)
    client:set_socket_disconnected_handler(function() post("disconnected", "") end)
    client:set_room_info_handler(function()
        client:ConnectSlot(net.slot, net.password, 7, { "Lua-APClientPP" }, { 0, 5, 0 })
    end)
    client:set_slot_connected_handler(function(slot_data)
        local death_link = slot_data and slot_data.death_link and "1" or "0"
        if death_link == "1" then
            -- Tag DeathLink : le serveur nous renvoie les morts des autres joueurs (Bounced).
            client:ConnectUpdate(nil, { "Lua-APClientPP", "DeathLink" })
        end
        local difficulty, goal, missable = "", "", ""
        if slot_data and type(slot_data.difficulty) == "string" then difficulty = slot_data.difficulty end
        if slot_data and type(slot_data.goal) == "string" then goal = slot_data.goal end
        if slot_data and type(slot_data.missable_checks) == "string" then missable = slot_data.missable_checks end
        -- Locations de CETTE seed (restantes + faites), en texte (règle en tête). Sans elles, le
        -- client demandait au serveur des locations absentes de la seed (checks d'énigmes Beneviento
        -- désactivés, boutique désactivée...) : KeyError côté serveur, connexion coupée en boucle
        -- (test hors jeu du 2026-09-30). Tableau ou ensemble selon la DLL : on accepte les deux.
        local locs = ""
        for _, field in ipairs({ "missing_locations", "checked_locations" }) do
            local ok, t = pcall(function() return client[field] end)
            if ok and type(t) == "table" then
                for k, v in pairs(t) do
                    local id = type(v) == "number" and v or k
                    if type(id) == "number" then locs = locs .. string.format("%d", id) .. "," end
                end
            end
        end
        post("slotlocs", locs)
        post("connected", death_link .. "|" .. difficulty .. "|" .. goal .. "|" .. missable)
        -- Hints (2026-10-08, onglet Hints) : liste durable du serveur « _read_hints_<équipe>_<slot> »,
        -- demandée (Get) puis suivie (SetNotify) ; réponses dans retrieved / set_reply.
        pcall(function()
            net.hints_key = string.format("_read_hints_%d_%d", client:get_team_number(), client:get_player_number())
            client:SetNotify({ net.hints_key })
            client:Get({ net.hints_key })
        end)
    end)
    -- Hints en texte : « receveur,trouveur,location,objet,trouvé(0/1),drapeaux; ... » (règle en tête).
    local function post_hints(value)
        local parts = {}
        for _, h in ipairs(type(value) == "table" and value or {}) do
            if type(h) == "table" then
                parts[#parts + 1] = string.format("%d,%d,%d,%d,%d,%d", tonumber(h.receiving_player) or 0,
                    tonumber(h.finding_player) or 0, tonumber(h.location) or 0, tonumber(h.item) or 0,
                    h.found and 1 or 0, tonumber(h.item_flags) or 0)
            end
        end
        post("hints", table.concat(parts, ";"))
    end
    client:set_retrieved_handler(function(map)
        if net.hints_key and type(map) == "table" and map[net.hints_key] ~= nil then post_hints(map[net.hints_key]) end
    end)
    client:set_set_reply_handler(function(msg)
        if net.hints_key and type(msg) == "table" and msg.key == net.hints_key then post_hints(msg.value) end
    end)
    -- Messages du serveur (journal, 2026-10-08) : « type<TAB>texte », rendu en texte par la DLL.
    client:set_print_json_handler(function(msg, extra)
        local kind = (type(msg) == "table" and msg.type) or (type(extra) == "table" and extra.type) or ""
        local ok, text = pcall(function()
            local data = type(msg) == "table" and msg.data or msg
            return client:render_json(data, AP.RenderFormat.TEXT)
        end)
        if ok and type(text) == "string" and text ~= "" then post("print", tostring(kind) .. "\t" .. text) end
    end)
    client:set_slot_refused_handler(function(reasons)
        local text = ""
        for _, r in ipairs(reasons or {}) do text = text .. r .. " " end
        post("refused", text)
    end)
    client:set_items_received_handler(function(items)
        for _, it in ipairs(items) do
            post("item", string.format("%d,%d,%d,%d", it.index, it.item, it.location or 0, it.player or 0))
        end
    end)
    -- Réponse à LocationScouts : l'objet placé sur chaque location demandée.
    client:set_location_info_handler(function(items)
        for _, it in ipairs(items) do
            post("scout", string.format("%d,%d,%d,%d", it.location or 0, it.item, it.player or 0, it.flags or 0))
        end
    end)
    -- DeathLink reçu : "source<TAB>cause" (texte uniquement, voir la règle en tête).
    client:set_bounced_handler(function(bounce)
        local is_death = false
        for _, tag in ipairs((bounce and bounce.tags) or {}) do
            if tag == "DeathLink" then is_death = true end
        end
        if not is_death then return end
        local data = bounce.data or {}
        post("death", tostring(data.source or "?") .. "\t" .. tostring(data.cause or ""))
    end)
    client:set_location_checked_handler(function(ids)
        local text = ""
        for _, id in ipairs(ids) do text = text .. string.format("%d", id) .. "," end
        post("checked", text)
    end)
    return true
end

function net.disconnect()
    if client then
        client = nil
        collectgarbage("collect")
    end
end

-- À appeler à chaque frame depuis la boucle du jeu. Renvoie la liste des événements reçus,
-- sous forme de tables construites ici (côté REFramework, donc sûres) :
--   { kind = "connected", death_link = bool }
--   { kind = "item", index, item, location, player }
--   { kind = "checked", ids = { ... } }
--   { kind = "scout", location, item, player, flags }
--   { kind = "disconnected" } / { kind = "refused", text } / { kind = "error", text }
function net.poll()
    if client then pcall(function() client:poll() end) end
    local events = {}
    while inbox.read < inbox.n do
        inbox.read = inbox.read + 1
        local key = "m" .. inbox.read
        local msg = inbox[key]
        inbox[key] = nil
        local kind, payload = msg:match("^(%a+)|(.*)$")
        if kind == "item" then
            local a, b, c, d = payload:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
            events[#events + 1] = { kind = "item", index = tonumber(a), item = tonumber(b),
                location = tonumber(c), player = tonumber(d) }
        elseif kind == "scout" then
            local a, b, c, d = payload:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
            events[#events + 1] = { kind = "scout", location = tonumber(a), item = tonumber(b),
                player = tonumber(c), flags = tonumber(d) }
        elseif kind == "checked" then
            local ids = {}
            for id in payload:gmatch("%-?%d+") do ids[#ids + 1] = tonumber(id) end
            events[#events + 1] = { kind = "checked", ids = ids }
        elseif kind == "slotlocs" then
            -- Ensemble des locations de la seed (nil si la DLL ne les donne pas : tout est gardé).
            local set, n = {}, 0
            for id in payload:gmatch("%-?%d+") do set[tonumber(id)] = true; n = n + 1 end
            net.seed_locations = n > 0 and set or nil
        elseif kind == "death" then
            local tab = payload:find("\t", 1, true)
            events[#events + 1] = { kind = "death", source = tab and payload:sub(1, tab - 1) or payload,
                cause = tab and payload:sub(tab + 1) or "" }
        elseif kind == "print" then
            local tab = payload:find("\t", 1, true)
            events[#events + 1] = { kind = "print", type = tab and payload:sub(1, tab - 1) or "",
                text = tab and payload:sub(tab + 1) or payload }
        elseif kind == "hints" then
            local list = {}
            for r, f, l, i, found, flags in payload:gmatch("(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%d),(%-?%d+)") do
                list[#list + 1] = { receiving = tonumber(r), finding = tonumber(f), location = tonumber(l),
                    item = tonumber(i), found = found == "1", flags = tonumber(flags) }
            end
            events[#events + 1] = { kind = "hints", list = list }
        elseif kind == "connected" then
            local dl, diff, goal, missable = payload:match("^(%d)|([^|]*)|([^|]*)|([^|]*)$")
            events[#events + 1] = { kind = "connected", death_link = dl == "1", difficulty = diff or "",
                goal = goal or "", missable = missable or "" }
        else
            events[#events + 1] = { kind = kind, text = payload }
        end
    end
    return events
end

-- Envoi : la table passée à la DLL est neuve et jetée juste après (règle 2).
function net.location_checks(ids)
    if not net.is_connected() then return false end
    local fresh = {}
    for i = 1, #ids do fresh[i] = ids[i] end
    return pcall(function() client:LocationChecks(fresh) end)
end

-- Demande quels objets sont placés sur ces locations (sans créer d'indice).
function net.location_scouts(ids)
    if not net.is_connected() then return false end
    local fresh = {}
    for i = 1, #ids do fresh[i] = ids[i] end
    return pcall(function() client:LocationScouts(fresh, 0) end)
end

-- Envoie notre mort aux joueurs qui ont DeathLink.
function net.send_death(cause)
    if not net.is_connected() then return false end
    return pcall(function()
        local now = os.time()
        pcall(function() now = client:get_server_time() end)
        local source = client:get_player_alias(client:get_player_number())
        client:Bounce({ time = now, source = source, cause = cause or "" }, nil, nil, { "DeathLink" })
    end)
end

function net.goal()
    if not net.is_connected() then return false end
    return pcall(function() client:StatusUpdate(AP.ClientStatus.GOAL) end)
end

local function call(fn, default)
    if not client then return default end
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

-- Numéros AP de nos objets et checks, calculés par le client depuis ses données (2026-10-08,
-- apworld FR / EN) : le mod garde ses noms français en interne et passe par les numéros, qui
-- sont les mêmes dans les deux langues. Sans ces tables : noms du paquet de données du serveur.
net.location_id_by_name = {}
net.item_name_by_id = {}
function net.set_id_tables(location_ids, item_names)
    net.location_id_by_name, net.item_name_by_id = location_ids, item_names
end

function net.get_location_id(name)
    local id = net.location_id_by_name[name]
    if id then return id end
    return call(function() return client:get_location_id(name, net.game_name) end, nil)
end

-- game : jeu du joueur qui RECEVRA l'objet (par défaut le nôtre). Nos objets : nom français du
-- mod, quelle que soit la langue de l'apworld qui a généré la partie.
function net.get_item_name(id, game)
    if (game == nil or game == net.game_name) and net.item_name_by_id[id] then return net.item_name_by_id[id] end
    return call(function() return client:get_item_name(id, game or net.game_name) end, nil)
end

-- Nom d'objet tel que le serveur l'écrit (langue de l'apworld), pour les commandes (!hint).
function net.server_item_name(id, game)
    return call(function() return client:get_item_name(id, game or net.game_name) end, nil)
end

function net.get_location_name(id, game)
    return call(function() return client:get_location_name(id, game or net.game_name) end, nil)
end

-- Message ou commande Archipelago (!hint, !release, !collect...).
function net.say(text)
    if not net.is_connected() then return false end
    return pcall(function() client:Say(text) end)
end

-- Points de hint : (points, coût d'un hint), nil si inconnus.
function net.hint_points()
    if not client then return nil, nil end
    local ok_p, points = pcall(function() return client:get_hint_points() end)
    local ok_c, cost = pcall(function() return client:get_hint_cost_points() end)
    return ok_p and points or nil, ok_c and cost or nil
end

function net.get_player_game(slot)
    return call(function() return client:get_player_game(slot) end, nil)
end

function net.get_player_alias(slot)
    return call(function() return client:get_player_alias(slot) end, "?")
end

function net.get_player_number()
    return call(function() return client:get_player_number() end, -1)
end

function net.get_seed()
    return call(function() return client:get_seed() end, "")
end

function net.get_slot()
    return call(function() return client:get_slot() end, "")
end

return net
