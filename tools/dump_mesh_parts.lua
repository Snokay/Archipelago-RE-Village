-- Relevé ponctuel (2026-09-27) : parties activées des modèles d'armes affichés (examen d'une
-- pièce d'arme dans l'inventaire). À copier dans reframework/autorun, puis "Reset scripts" avec
-- l'objet affiché. Résultat : reframework/data/re_village_ap_client/mesh_parts_dump.txt.
local lines = {}
local ok, err = pcall(function()
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh")):get_elements()
    for _, m in ipairs(comps) do
        local path = ""
        pcall(function() path = tostring(m:call("getMesh"):call("get_ResourcePath")) end)
        if path:find("it02", 1, true) then
            local parts = {}
            for pi = 0, 63 do
                local okp, v = pcall(function() return m:call("getPartsEnable", pi) end)
                if okp and v ~= nil then parts[#parts + 1] = pi .. "=" .. tostring(v) end
            end
            local name, draw = "?", "?"
            pcall(function() name = tostring(m:call("get_GameObject"):call("get_Name")) end)
            pcall(function() draw = tostring(m:call("get_DrawDefault")) end)
            lines[#lines + 1] = string.format("%s | %s | draw=%s | %s", name, path, draw, table.concat(parts, " "))
        end
    end
end)
if not ok then lines[#lines + 1] = "erreur : " .. tostring(err) end
if #lines == 0 then lines[1] = "aucun modèle it02 trouvé" end
local f = io.open("re_village_ap_client/mesh_parts_dump.txt", "w")
if f then
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end
