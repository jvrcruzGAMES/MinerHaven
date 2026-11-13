--- libores - Controller-Side GeoScanner Management
-- Consolidates all GeoScanner peripheral management, scanning, ore identification,
-- tag normalization, chunk analysis, base protection, and turtle home coordinate calibration.

local Ores = {}
Ores.__index = Ores

Ores.VERSION = "1.0.0"

--- Known peripheral type names for Geo Scanner across Advanced Peripherals versions.
Ores.SCANNER_TYPES = {
    "geoScanner",
    "geo_scanner",
}
Ores.PERIPHERAL_TYPES = Ores.SCANNER_TYPES

--- Known End Automata / Automata peripheral type names.
Ores.AUTOMATA_TYPES = {
    "endAutomata",
    "end_automata",
    "overpoweredEndAutomata",
    "overpowered_end_automata",
    "weakAutomata",
    "weak_automata",
}

--- Default wireless channel and protocol.
Ores.MODEM_CHANNEL = 4821
Ores.PROTOCOL = "minerhaven"

--- Forbidden blocks that the turtle must NEVER break (base blocks, teleport pads, bedrock, etc.).
Ores.PROTECTED_BLOCKS = {
    ["allthemodium:teleport_pad"] = true,
    ["minecraft:bedrock"] = true,
    -- CC: Tweaked base computers, turtles, modems, peripherals
    ["computercraft:computer_normal"] = true,
    ["computercraft:computer_advanced"] = true,
    ["computercraft:computer_command"] = true,
    ["computercraft:turtle_normal"] = true,
    ["computercraft:turtle_advanced"] = true,
    ["computercraft:wireless_modem_normal"] = true,
    ["computercraft:wireless_modem_advanced"] = true,
    ["computercraft:wired_modem"] = true,
    ["computercraft:wired_modem_full"] = true,
    ["computercraft:cable"] = true,
    ["computercraft:monitor_normal"] = true,
    ["computercraft:monitor_advanced"] = true,
    ["computercraft:disk_drive"] = true,
    ["computercraft:printer"] = true,
    ["computercraft:speaker"] = true,
    ["computercraft:redstone_relay"] = true,
    -- Advanced Peripherals base blocks
    ["advancedperipherals:geo_scanner"] = true,
    ["advancedperipherals:environment_detector"] = true,
    ["advancedperipherals:player_detector"] = true,
    ["advancedperipherals:energy_detector"] = true,
    ["advancedperipherals:block_reader"] = true,
    ["advancedperipherals:nbt_storage"] = true,
    ["advancedperipherals:inventory_manager"] = true,
    ["advancedperipherals:redstone_integrator"] = true,
    ["advancedperipherals:chat_box"] = true,
    ["advancedperipherals:peripheral_casing"] = true,
    -- Sophisticated Storage barrels & chests at the base
    ["sophisticatedstorage:barrel"] = true,
    ["sophisticatedstorage:copper_barrel"] = true,
    ["sophisticatedstorage:iron_barrel"] = true,
    ["sophisticatedstorage:gold_barrel"] = true,
    ["sophisticatedstorage:diamond_barrel"] = true,
    ["sophisticatedstorage:netherite_barrel"] = true,
    ["sophisticatedstorage:limited_barrel_1"] = true,
    ["sophisticatedstorage:limited_barrel_2"] = true,
    ["sophisticatedstorage:limited_barrel_3"] = true,
    ["sophisticatedstorage:limited_barrel_4"] = true,
    ["sophisticatedstorage:chest"] = true,
    ["sophisticatedstorage:copper_chest"] = true,
    ["sophisticatedstorage:iron_chest"] = true,
    ["sophisticatedstorage:gold_chest"] = true,
    ["sophisticatedstorage:diamond_chest"] = true,
    ["sophisticatedstorage:netherite_chest"] = true,
    ["sophisticatedstorage:controller"] = true,
    -- Vanilla & Mekanism base storage/energy blocks
    ["minecraft:barrel"] = true,
    ["minecraft:chest"] = true,
    ["minecraft:trapped_chest"] = true,
    ["minecraft:ender_chest"] = true,
    ["mekanism:basic_energy_cube"] = true,
    ["mekanism:advanced_energy_cube"] = true,
    ["mekanism:elite_energy_cube"] = true,
    ["mekanism:ultimate_energy_cube"] = true,
    ["mekanism:creative_energy_cube"] = true,
    -- Flux Networks power blocks
    ["fluxnetworks:flux_plug"] = true,
    ["fluxnetworks:flux_point"] = true,
    ["fluxnetworks:flux_controller"] = true,
    ["fluxnetworks:basic_flux_storage"] = true,
    ["fluxnetworks:herculean_flux_storage"] = true,
    ["fluxnetworks:gargantuan_flux_storage"] = true,
}
Ores.BASE_PROTECTED_BLOCKS = Ores.PROTECTED_BLOCKS

--- Default patterns identifying ores.
Ores.DEFAULT_ORE_PATTERNS = {
    "_ore$",
    "_ore_",
    ":.*_ore$",
    ":.*_ore_.*$",
    "^minecraft:ancient_debris$",
    "ancient_debris",
    "^minecraft:gilded_blackstone$",
    "^minecraft:budding_amethyst$",
    "^minecraft:amethyst_cluster$",
    "raw_.*_block$",
    ":raw_.*_block$",
}
Ores.ORE_PATTERNS = Ores.DEFAULT_ORE_PATTERNS

--- Default tags that identify a block as an ore.
Ores.DEFAULT_ORE_TAGS = {
    ["forge:ores"] = true,
    ["c:ores"] = true,
    ["balm:ores"] = true,
    ["minecraft:coal_ores"] = true,
    ["minecraft:iron_ores"] = true,
    ["minecraft:copper_ores"] = true,
    ["minecraft:gold_ores"] = true,
    ["minecraft:redstone_ores"] = true,
    ["minecraft:emerald_ores"] = true,
    ["minecraft:lapis_ores"] = true,
    ["minecraft:diamond_ores"] = true,
}

--- Common non-ore terrain waste blocks.
Ores.WASTE_BLOCKS = {
    ["minecraft:stone"] = true,
    ["minecraft:cobblestone"] = true,
    ["minecraft:mossy_cobblestone"] = true,
    ["minecraft:deepslate"] = true,
    ["minecraft:cobbled_deepslate"] = true,
    ["minecraft:dirt"] = true,
    ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true,
    ["minecraft:rooted_dirt"] = true,
    ["minecraft:podzol"] = true,
    ["minecraft:mycelium"] = true,
    ["minecraft:mud"] = true,
    ["minecraft:clay"] = true,
    ["minecraft:clay_ball"] = true,
    ["minecraft:gravel"] = true,
    ["minecraft:sand"] = true,
    ["minecraft:red_sand"] = true,
    ["minecraft:sandstone"] = true,
    ["minecraft:red_sandstone"] = true,
    ["minecraft:tuff"] = true,
    ["minecraft:andesite"] = true,
    ["minecraft:diorite"] = true,
    ["minecraft:granite"] = true,
    ["minecraft:calcite"] = true,
    ["minecraft:dripstone_block"] = true,
    ["minecraft:pointed_dripstone"] = true,
    ["minecraft:netherrack"] = true,
    ["minecraft:basalt"] = true,
    ["minecraft:smooth_basalt"] = true,
    ["minecraft:blackstone"] = true,
    ["minecraft:end_stone"] = true,
    ["minecraft:flint"] = true,
    ["minecraft:soul_sand"] = true,
    ["minecraft:soul_soil"] = true,
    ["minecraft:magma_block"] = true,
    ["minecraft:terracotta"] = true,
    ["minecraft:moss_block"] = true,
    ["minecraft:moss_carpet"] = true,
    ["allthemodium:ancient_stone"] = true,
    ["allthemodium:ancient_dirt"] = true,
    ["allthemodium:ancient_grass"] = true,
    ["allthemodium:ancient_moss"] = true,
}

--------------------------------------------------------------------------------
-- Static Utilities & Tag Inspection
--------------------------------------------------------------------------------

--- Check if block name is a protected base block.
function Ores.isProtectedBlock(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if Ores.PROTECTED_BLOCKS[lower] then return true end
    if lower:match("^computercraft:")
        or lower:match("^advancedperipherals:")
        or lower:match("^sophisticatedstorage:")
        or lower:match("^fluxnetworks:")
        or lower:find("teleport_pad", 1, true)
        or lower:find("energy_cube", 1, true)
        or lower:find("wireless_modem", 1, true)
        or lower:find("wired_modem", 1, true)
        or lower:find("geo_scanner", 1, true)
    then
        return true
    end
    return false
end
Ores.isProtectedBlockName = Ores.isProtectedBlock

--- Check whether a block registry name is a Sophisticated Storage barrel or base storage container.
function Ores.isStorageBarrelName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if lower:match("^sophisticatedstorage:")
        or lower:find("barrel", 1, true)
        or lower:find("chest", 1, true)
    then
        return true
    end
    return false
end

--- Check if block name indicates a CC Turtle.
function Ores.isTurtleBlock(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    return lower == "computercraft:turtle_normal"
        or lower == "computercraft:turtle_advanced"
        or lower:match("^computercraft:turtle") ~= nil
end
Ores.isTurtleBlockName = Ores.isTurtleBlock

--- Convert a registry name like `"minecraft:deepslate_diamond_ore"` into `"diamond_ore"`.
function Ores.shortName(name)
    if type(name) ~= "string" then
        return tostring(name or "unknown")
    end
    local short = name:match("^[^:]+:(.+)$") or name
    return short
end

--- Convert a registry name into a human-readable label like `"Deepslate Diamond Ore"`.
function Ores.prettyName(name)
    local short = Ores.shortName(name)
    local words = {}
    for word in short:gmatch("[^_]+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2))
    end
    return table.concat(words, " ")
end

--- Normalize tags table from `scan()` into `{ [tag] = true }` map and sorted list.
function Ores.normalizeTags(rawTags)
    local tagMap = {}
    local tagList = {}
    if type(rawTags) ~= "table" then
        return tagMap, tagList
    end
    for k, v in pairs(rawTags) do
        if type(k) == "number" and type(v) == "string" then
            local clean = v:gsub("^#", "")
            if not tagMap[clean] then
                tagMap[clean] = true
                table.insert(tagList, clean)
            end
        elseif type(k) == "string" and v then
            local clean = k:gsub("^#", "")
            if not tagMap[clean] then
                tagMap[clean] = true
                table.insert(tagList, clean)
            end
        end
    end
    table.sort(tagList)
    return tagMap, tagList
end

--- Check whether a block entry has a specific tag.
function Ores.hasTag(block, tag)
    if type(block) ~= "table" or type(tag) ~= "string" then
        return false
    end
    local clean = tag:gsub("^#", "")
    local tagMap = block.tagMap
    if not tagMap then
        tagMap = Ores.normalizeTags(block.tags)
    end
    return tagMap[clean] == true
end

--- Check whether a block or item table has an ore tag.
function Ores.hasOreTag(block)
    if type(block) ~= "table" then
        return false
    end
    local tagMap = block.tagMap or Ores.normalizeTags(block.tags)
    for tag, _ in pairs(tagMap) do
        local lower = tag:lower()
        if Ores.DEFAULT_ORE_TAGS[lower] then
            return true
        end
        if lower:match("^forge:ores/")
            or lower:match("^c:ores/")
            or lower:match(":ores$")
            or lower:match(":ores/")
            or lower:match("_ores$")
        then
            return true
        end
    end
    return false
end

--- Check whether an item registry name is an energy storage item.
function Ores.isEnergyItemName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if lower:find("_ore", 1, true) then return false end
    return lower:find("energy", 1, true)
        or lower:find("battery", 1, true)
        or lower:find("capacitor", 1, true)
        or lower:find("flux_", 1, true)
        or lower:find("_cell", 1, true)
        or lower:find("energy_tablet", 1, true)
        or lower:find("energy_cube", 1, true)
        or lower:find("accumulator", 1, true)
        or lower:find("power_cell", 1, true)
        or lower:find("charge_crystal", 1, true)
end

--- Check whether a block or item name is a terrain waste block.
function Ores.isWasteName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if Ores.isEnergyItemName(lower) then return false end
    if Ores.WASTE_BLOCKS[lower] then return true end
    local short = Ores.shortName(lower)
    if short:find("_ore", 1, true) or short:find("raw_", 1, true) or short == "redstone" or short == "gilded_blackstone" then
        return false
    end
    return short == "dirt"
        or short == "cobblestone"
        or short == "stone"
        or short == "deepslate"
        or short == "cobbled_deepslate"
        or short == "gravel"
        or short == "sand"
        or short == "sandstone"
        or short == "tuff"
        or short == "andesite"
        or short == "diorite"
        or short == "granite"
        or short == "netherrack"
        or short == "basalt"
        or short == "blackstone"
        or short == "end_stone"
        or short == "limestone"
        or short == "marble"
        or short == "scoria"
        or short == "slate"
        or short == "gabbro"
        or short == "dolomite"
        or short:match("_dirt$")
        or short:match("_cobblestone$")
        or short:match("^cobbled_")
        or short:match("_grass$")
        or short:match("_stone$")
end

--- Determine whether an item detail represents a mined ore.
function Ores.isOreItem(itemDetail, trackedMinedItems)
    if type(itemDetail) ~= "table" or type(itemDetail.name) ~= "string" then
        return false
    end
    local name = itemDetail.name:lower()
    if Ores.isWasteName(name) or Ores.isEnergyItemName(name) then
        return false
    end
    if trackedMinedItems and trackedMinedItems[name] then
        return true
    end
    if Ores.hasOreTag(itemDetail) or Ores.isOre(itemDetail) then
        return true
    end
    local tagMap = itemDetail.tagMap or Ores.normalizeTags(itemDetail.tags)
    for tag, _ in pairs(tagMap) do
        local lower = tag:lower()
        if lower == "forge:raw_materials"
            or lower == "c:raw_materials"
            or lower:match("^forge:raw_materials/")
            or lower:match("^c:raw_materials/")
            or lower == "forge:gems"
            or lower == "c:gems"
            or lower:match("^forge:gems/")
            or lower:match("^c:gems/")
            or lower:match("^forge:dusts/")
            or lower:match("^c:dusts/")
            or lower:match("^forge:nuggets/")
            or lower:match("^c:nuggets/")
        then
            return true
        end
    end
    if name:match(":raw_")
        or name == "minecraft:diamond"
        or name == "minecraft:emerald"
        or name == "minecraft:coal"
        or name == "minecraft:redstone"
        or name == "minecraft:lapis_lazuli"
        or name == "minecraft:quartz"
        or name == "minecraft:ancient_debris"
        or name == "minecraft:gold_nugget"
        or name == "minecraft:iron_nugget"
    then
        return true
    end
    return false
end

--- Check if block is an ore by name or tags.
function Ores.isOre(blockOrName)
    local name
    if type(blockOrName) == "string" then
        name = blockOrName
    elseif type(blockOrName) == "table" then
        name = blockOrName.name
        if Ores.hasOreTag(blockOrName) then
            return true
        end
    else
        return false
    end

    if type(name) == "string" then
        local lower = name:lower()
        for _, pat in ipairs(Ores.ORE_PATTERNS) do
            if lower:match(pat) then
                return true
            end
        end
    end
    return false
end

--- Format relative coordinates into a compact compass direction string.
function Ores.formatDirection(x, y, z)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    z = tonumber(z) or 0
    local parts = {}
    if x > 0 then table.insert(parts, x .. "E")
    elseif x < 0 then table.insert(parts, math.abs(x) .. "W") end
    if y > 0 then table.insert(parts, y .. "U")
    elseif y < 0 then table.insert(parts, math.abs(y) .. "D") end
    if z > 0 then table.insert(parts, z .. "S")
    elseif z < 0 then table.insert(parts, math.abs(z) .. "N") end
    if #parts == 0 then return "Here" end
    return table.concat(parts, " ")
end

--- Enrich raw scanned block with parsed details.
function Ores.enrichBlock(raw)
    local x = tonumber(raw.x) or 0
    local y = tonumber(raw.y) or 0
    local z = tonumber(raw.z) or 0
    local manhattan = math.abs(x) + math.abs(y) + math.abs(z)
    local euclidean = math.sqrt(x * x + y * y + z * z)
    local tagMap, tagList = Ores.normalizeTags(raw.tags)

    local enriched = {
        name = raw.name or "unknown",
        shortName = Ores.shortName(raw.name),
        prettyName = Ores.prettyName(raw.name),
        x = x,
        y = y,
        z = z,
        f = raw.f,
        r = raw.r,
        u = raw.u,
        state = raw.state,
        tags = tagList,
        tagMap = tagMap,
        dist = manhattan,
        euclidean = math.floor(euclidean * 10 + 0.5) / 10,
        direction = Ores.formatDirection(x, y, z),
    }
    enriched.hasOreTag = Ores.hasOreTag(enriched)
    enriched.isOre = Ores.isOre(enriched)
    return enriched
end

--------------------------------------------------------------------------------
-- Peripheral Detection & Inspection
--------------------------------------------------------------------------------

local function isGeoScannerPeripheral(p)
    if type(p) ~= "table" then return false end
    return type(p.scan) == "function" or type(p.scanBlocks) == "function" or type(p.chunkAnalyze) == "function"
end

function Ores.isAutomataPeripheral(p)
    if type(p) ~= "table" then return false end
    return type(p.warpToPoint) == "function"
        or type(p.savePoint) == "function"
        or type(p.chargeTurtle) == "function"
        or type(p.digBlock) == "function"
end

function Ores.findAutomata(sideOrName)
    if not peripheral then return nil, "peripheral API unavailable" end
    if type(sideOrName) == "string" and sideOrName ~= "" then
        if peripheral.isPresent and peripheral.isPresent(sideOrName) then
            local p = peripheral.wrap and peripheral.wrap(sideOrName)
            if Ores.isAutomataPeripheral(p) then return p, sideOrName end
        end
        return nil, ("No End Automata found on '%s'"):format(sideOrName)
    end
    if type(peripheral.find) == "function" then
        for _, aType in ipairs(Ores.AUTOMATA_TYPES) do
            local p = peripheral.find(aType)
            if Ores.isAutomataPeripheral(p) then
                local foundName = aType
                if peripheral.getName then
                    local ok, n = pcall(peripheral.getName, p)
                    if ok and n then foundName = n end
                end
                return p, foundName
            end
        end
    end
    if type(peripheral.getNames) == "function" and type(peripheral.wrap) == "function" then
        for _, name in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(name)
            if Ores.isAutomataPeripheral(p) then return p, name end
        end
    end
    return nil, "No End Automata found"
end

function Ores.isModemPeripheral(p)
    if type(p) ~= "table" then return false end
    return type(p.open) == "function" and type(p.transmit) == "function"
end

function Ores.findModem(sideOrName)
    if not peripheral then return nil, "peripheral API unavailable" end
    local function prepareModem(p, name)
        if type(p.isOpen) == "function" then
            local ok, opened = pcall(p.isOpen, Ores.MODEM_CHANNEL)
            if not (ok and opened) then pcall(p.open, Ores.MODEM_CHANNEL) end
        else
            pcall(p.open, Ores.MODEM_CHANNEL)
        end
        return p, name
    end

    if type(sideOrName) == "string" and sideOrName ~= "" then
        if peripheral.isPresent and peripheral.isPresent(sideOrName) then
            local p = peripheral.wrap and peripheral.wrap(sideOrName)
            if Ores.isModemPeripheral(p) then return prepareModem(p, sideOrName) end
        end
        return nil, ("No Modem found on '%s'"):format(sideOrName)
    end
    if type(peripheral.getNames) == "function" and type(peripheral.wrap) == "function" then
        local fallbackModem, fallbackName = nil, nil
        for _, name in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(name)
            if Ores.isModemPeripheral(p) then
                local isWireless = (type(p.isWireless) == "function") and p.isWireless() or false
                if isWireless then return prepareModem(p, name)
                elseif not fallbackModem then fallbackModem, fallbackName = p, name end
            end
        end
        if fallbackModem then return prepareModem(fallbackModem, fallbackName) end
    end
    if type(peripheral.find) == "function" then
        local p = peripheral.find("modem")
        if Ores.isModemPeripheral(p) then
            local foundName = "modem"
            if peripheral.getName then
                local ok, n = pcall(peripheral.getName, p)
                if ok and n then foundName = n end
            end
            return prepareModem(p, foundName)
        end
    end
    return nil, "No Ender/Wireless Modem found"
end

function Ores.transmitMessage(modem, payload)
    if not Ores.isModemPeripheral(modem) or type(payload) ~= "table" then return false end
    payload.protocol = Ores.PROTOCOL
    if type(modem.isOpen) == "function" then
        local ok, opened = pcall(modem.isOpen, Ores.MODEM_CHANNEL)
        if not (ok and opened) then pcall(modem.open, Ores.MODEM_CHANNEL) end
    else
        pcall(modem.open, Ores.MODEM_CHANNEL)
    end
    return pcall(modem.transmit, Ores.MODEM_CHANNEL, Ores.MODEM_CHANNEL, payload)
end

function Ores.parseModemEvent(ev, p1, p2, p3, p4)
    if ev == "modem_message" and p2 == Ores.MODEM_CHANNEL and type(p4) == "table" and p4.protocol == Ores.PROTOCOL then
        return p4
    elseif ev == "rednet_message" and type(p2) == "table" and p2.protocol == Ores.PROTOCOL then
        return p2
    end
    return nil
end

--- Find GeoScanner peripheral on any side.
function Ores.findScanner(sideOrName)
    if not peripheral then return nil, "peripheral API unavailable" end
    if type(sideOrName) == "string" and sideOrName ~= "" then
        if peripheral.isPresent and peripheral.isPresent(sideOrName) then
            local p = peripheral.wrap and peripheral.wrap(sideOrName)
            if isGeoScannerPeripheral(p) then return p, sideOrName end
        end
        return nil, ("No Geo Scanner found on '%s'"):format(sideOrName)
    end
    for _, t in ipairs(Ores.SCANNER_TYPES) do
        local p = peripheral.find(t)
        if p and isGeoScannerPeripheral(p) then
            local foundName = t
            if peripheral.getName then
                local ok, n = pcall(peripheral.getName, p)
                if ok and n then foundName = n end
            end
            return p, foundName
        end
    end
    if peripheral.getNames then
        for _, name in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(name)
            if isGeoScannerPeripheral(p) then return p, name end
        end
    end
    return nil, "No Geo Scanner peripheral detected"
end

--- Find and wrap GeoScanner as an Ores instance.
function Ores.find(sideOrName)
    local p, name = Ores.findScanner(sideOrName)
    if not p then return nil, name end
    return Ores.new(p, name)
end

--- Build a filter predicate.
function Ores.buildFilter(filter)
    if filter == nil then return function() return true end end
    if type(filter) == "function" then return filter end
    if type(filter) == "string" then
        local trimmed = filter:match("^%s*(.-)%s*$")
        if trimmed == "" then return function() return true end end
        if trimmed:sub(1, 1) == "#" then
            local targetTag = trimmed:sub(2):lower()
            return function(block)
                for tag, _ in pairs(block.tagMap or {}) do
                    if tag:lower():find(targetTag, 1, true) then return true end
                end
                return false
            end
        end
        local q = trimmed:lower()
        return function(block)
            return (block.name and block.name:lower():find(q, 1, true) ~= nil)
                or (block.prettyName and block.prettyName:lower():find(q, 1, true) ~= nil)
        end
    end
    if type(filter) == "table" then
        local queryFn = filter.query and Ores.buildFilter(filter.query) or nil
        local tagFn = filter.tag and Ores.buildFilter("#" .. filter.tag:gsub("^#", "")) or nil
        return function(block)
            if filter.oresOnly and not block.isOre then return false end
            if filter.minY and block.y < filter.minY then return false end
            if filter.maxY and block.y > filter.maxY then return false end
            if filter.maxDist and block.dist > filter.maxDist then return false end
            if queryFn and not queryFn(block) then return false end
            if tagFn and not tagFn(block) then return false end
            if type(filter.predicate) == "function" and not filter.predicate(block) then return false end
            return true
        end
    end
    return function() return true end
end

--- Filter and sort scanned blocks.
function Ores.filterBlocks(blocks, filter, sortBy)
    local predicate = Ores.buildFilter(filter)
    local out = {}
    for _, b in ipairs(blocks or {}) do
        local enriched = (b.dist ~= nil and b.tagMap ~= nil) and b or Ores.enrichBlock(b)
        if predicate(enriched) then table.insert(out, enriched) end
    end

    sortBy = sortBy or "dist"
    table.sort(out, function(a, b)
        if sortBy == "name" then
            if a.shortName ~= b.shortName then return a.shortName < b.shortName end
            return a.dist < b.dist
        elseif sortBy == "euclidean" then
            if a.euclidean ~= b.euclidean then return a.euclidean < b.euclidean end
            return a.shortName < b.shortName
        else
            if a.dist ~= b.dist then return a.dist < b.dist end
            return a.shortName < b.shortName
        end
    end)
    return out
end

--- Group scanned blocks by name.
function Ores.groupByBlock(blocks)
    local groupsByName = {}
    local groups = {}
    for _, raw in ipairs(blocks or {}) do
        local b = (raw.dist ~= nil and raw.tagMap ~= nil) and raw or Ores.enrichBlock(raw)
        local g = groupsByName[b.name]
        if not g then
            g = {
                name = b.name,
                shortName = b.shortName,
                prettyName = b.prettyName,
                isOre = b.isOre,
                count = 0,
                nearest = b,
                blocks = {},
            }
            groupsByName[b.name] = g
            table.insert(groups, g)
        end
        g.count = g.count + 1
        table.insert(g.blocks, b)
        if b.dist < g.nearest.dist then g.nearest = b end
    end
    for _, g in ipairs(groups) do
        table.sort(g.blocks, function(a, b) return a.dist < b.dist end)
    end
    table.sort(groups, function(a, b)
        if a.nearest.dist ~= b.nearest.dist then return a.nearest.dist < b.nearest.dist end
        if a.count ~= b.count then return a.count > b.count end
        return a.shortName < b.shortName
    end)
    return groups
end

--------------------------------------------------------------------------------
-- GeoScanner Manager Class
--------------------------------------------------------------------------------

local Manager = {}
Manager.__index = Manager

--- Create an Ores manager instance or wrap a GeoScanner peripheral.
function Ores.new(optsOrPeripheral, name)
    local self = setmetatable({}, Manager)
    if isGeoScannerPeripheral(optsOrPeripheral) then
        self.raw = optsOrPeripheral
        self.scanner = optsOrPeripheral
        local detectedName = nil
        if peripheral and peripheral.getName then
            local ok, n = pcall(peripheral.getName, optsOrPeripheral)
            if ok and n then detectedName = n end
        end
        self.name = name or detectedName or "geoScanner"
        self.turtleOffset = { x = 0, y = 0, z = 0, calibrated = false }
    else
        local opts = type(optsOrPeripheral) == "table" and optsOrPeripheral or {}
        self.scanner = opts.scanner
        self.raw = opts.scanner
        self.name = name or "geoScanner"
        self.turtleOffset = opts.turtleOffset or { x = 0, y = 0, z = 0, calibrated = false }
    end
    self.lastScanTime = 0
    self.lastOreCount = 0
    return self
end

function Manager:ensureScanner()
    if self.scanner then return self.scanner end
    local s, err = Ores.findScanner()
    if s then
        self.scanner = s
        self.raw = s
        return s
    end
    return nil, err
end

--- Get FE / fuel cost for scanning at radius.
function Manager:getCost(radius)
    radius = tonumber(radius) or 8
    local scanner = self:ensureScanner()
    if scanner and type(scanner.cost) == "function" then
        local ok, res = pcall(scanner.cost, radius)
        if ok and type(res) == "number" then return res end
    end
    return 0
end

--- Get current and maximum fuel level.
function Manager:getFuel()
    local scanner = self:ensureScanner()
    local level, max = nil, 0
    if scanner then
        if type(scanner.getFuelLevel) == "function" then
            local ok, val = pcall(scanner.getFuelLevel)
            if ok and type(val) == "number" then level = val end
        end
        if type(scanner.getMaxFuelLevel) == "function" then
            local ok, val = pcall(scanner.getMaxFuelLevel)
            if ok and type(val) == "number" then max = val end
        end
    end
    return { level = level, max = max }
end

--- Perform scan with retry for cooldowns.
function Manager:rawScan(radius, retries, retryDelay)
    retries = tonumber(retries) or 6
    retryDelay = tonumber(retryDelay) or 0.5
    local scanner, err = self:ensureScanner()
    if not scanner then return nil, err end

    local scanFn = scanner.scanBlocks or scanner.scan
    if not scanFn then
        return nil, "Geo Scanner has no scan or scanBlocks method"
    end

    local lastErr = nil
    for attempt = 0, retries do
        local ok, res, reason = pcall(scanFn, radius)
        if ok and type(res) == "table" then
            return res
        end

        lastErr = tostring(reason or res or "Scan failed")
        local isCooldown = lastErr:lower():find("cooldown", 1, true)
            or lastErr:lower():find("wait", 1, true)
            or lastErr:lower():find("delay", 1, true)
        if attempt < retries and isCooldown then
            if os.sleep then os.sleep(retryDelay) end
        else
            return nil, lastErr
        end
    end

    return nil, lastErr or "Scan failed after retries (scanner possibly on cooldown)"
end

--- Scan blocks within radius, returning enriched, filtered and sorted blocks.
function Manager:scan(radius, opts)
    radius = math.max(1, math.floor(tonumber(radius) or 8))
    opts = opts or {}
    local rawResult, err = self:rawScan(radius, opts.retries, opts.retryDelay)
    if not rawResult then return nil, err end

    local enriched = {}
    for _, rawBlock in ipairs(rawResult) do
        table.insert(enriched, Ores.enrichBlock(rawBlock))
    end

    local filterSpec = opts.filter
    if not filterSpec and (opts.oresOnly or opts.query or opts.tag or opts.minY or opts.maxY or opts.maxDist) then
        filterSpec = {
            oresOnly = opts.oresOnly,
            query = opts.query,
            tag = opts.tag,
            minY = opts.minY,
            maxY = opts.maxY,
            maxDist = opts.maxDist,
        }
    end

    return Ores.filterBlocks(enriched, filterSpec, opts.sortBy)
end

function Manager:scanOresByTag(radius, opts)
    local merged = {}
    if type(opts) == "table" then
        for k, v in pairs(opts) do merged[k] = v end
    end
    merged.filter = function(block) return Ores.hasOreTag(block) end
    return self:scan(radius, merged)
end

function Manager:scanOres(radius, opts)
    local merged = {}
    if type(opts) == "table" then
        for k, v in pairs(opts) do merged[k] = v end
    end
    merged.oresOnly = true
    return self:scan(radius, merged)
end

function Manager:findNearest(radius, filter, scanOpts)
    local opts = {}
    if type(scanOpts) == "table" then
        for k, v in pairs(scanOpts) do opts[k] = v end
    end
    opts.filter = filter
    opts.sortBy = "dist"
    local blocks, err = self:scan(radius, opts)
    if not blocks then return nil, err end
    return blocks[1], nil
end

function Manager:analyzeChunk(opts)
    opts = opts or {}
    local scanner, err = self:ensureScanner()
    if not scanner then return nil, err end
    if type(scanner.chunkAnalyze) ~= "function" then
        return nil, "Geo Scanner peripheral does not support chunkAnalyze()"
    end

    local rawCounts, rawErr
    for attempt = 1, 6 do
        local ok, res = pcall(scanner.chunkAnalyze)
        if ok and type(res) == "table" then
            rawCounts = res
            break
        end
        rawErr = res
        if os.sleep then os.sleep(0.5) end
    end

    if type(rawCounts) ~= "table" then
        return nil, tostring(rawErr or "chunkAnalyze failed")
    end

    local queryLower = type(opts.query) == "string" and opts.query:match("^%s*(.-)%s*$"):lower() or ""
    local entries = {}
    local total = 0

    for blockName, count in pairs(rawCounts) do
        local num = tonumber(count) or 0
        if num > 0 then
            local pretty = Ores.prettyName(blockName)
            local short = Ores.shortName(blockName)
            local matches = (queryLower == "")
                or blockName:lower():find(queryLower, 1, true) ~= nil
                or pretty:lower():find(queryLower, 1, true) ~= nil
            if matches then
                table.insert(entries, {
                    name = blockName,
                    shortName = short,
                    prettyName = pretty,
                    count = num,
                })
                total = total + num
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.shortName < b.shortName
    end)

    return {
        entries = entries,
        raw = rawCounts,
        total = total,
    }
end

--- Scan around base, calibrate turtle home offset if detected, and return translated ore list.
function Manager:scanAuthoritative(radius)
    radius = math.max(1, math.floor(tonumber(radius) or 8))
    local rawBlocks, err = self:rawScan(radius)
    if not rawBlocks then
        return nil, nil, err
    end

    self.lastScanTime = os.time and os.time() or 0

    -- Auto-detect turtle at base (within 6 blocks) to calibrate offset
    local closestTurtle = nil
    for _, b in ipairs(rawBlocks) do
        local dist = math.abs(b.x or 0) + math.abs(b.y or 0) + math.abs(b.z or 0)
        b.dist = dist
        if Ores.isTurtleBlock(b.name) and dist <= 6 then
            if not closestTurtle or dist < closestTurtle.dist then
                closestTurtle = b
            end
        end
    end

    if closestTurtle then
        self.turtleOffset.x = closestTurtle.x
        self.turtleOffset.y = closestTurtle.y
        self.turtleOffset.z = closestTurtle.z
        self.turtleOffset.calibrated = true
    end

    local offX = self.turtleOffset.x or 0
    local offY = self.turtleOffset.y or 0
    local offZ = self.turtleOffset.z or 0

    local baseBlocks = {
        {
            name = "advancedperipherals:geo_scanner",
            x = -offX,
            y = -offY,
            z = -offZ,
        }
    }
    local ores = {}

    for _, b in ipairs(rawBlocks) do
        local relX = (b.x or 0) - offX
        local relY = (b.y or 0) - offY
        local relZ = (b.z or 0) - offZ
        local isTurtleHome = (relX == 0 and relY == 0 and relZ == 0)

        if Ores.isProtectedBlock(b.name) then
            if not isTurtleHome then
                table.insert(baseBlocks, {
                    name = b.name,
                    x = relX,
                    y = relY,
                    z = relZ,
                })
            end
        elseif Ores.isOre(b) then
            local distFromHome = math.abs(relX) + math.abs(relY) + math.abs(relZ)
            table.insert(ores, {
                name = b.name,
                x = relX,
                y = relY,
                z = relZ,
                dist = distFromHome,
            })
        end
    end

    table.sort(ores, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return tostring(a.name) < tostring(b.name)
    end)

    self.lastOreCount = #ores
    return ores, baseBlocks, nil
end

return Ores
