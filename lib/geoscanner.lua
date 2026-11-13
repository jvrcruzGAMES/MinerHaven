--- MinerHaven Geo Scanner Library for CC: Tweaked & Advanced Peripherals
-- Reusable wrapper around the Advanced Peripherals Geo Scanner (`geoScanner` / `geo_scanner`).
-- Supports both AP 0.7 (`geoScanner`, `scan`, `cost`, `chunkAnalyze`, `getMaxFuelLevel`)
-- and AP 0.8 / 1.21.1+ (`geo_scanner`, `scanBlocks`, `getFuelLevel`, filtered `chunkAnalyze`).
--
-- @module geoscanner

local GeoScanner = {}
GeoScanner.__index = GeoScanner

GeoScanner.VERSION = "1.0.0"

--- Known peripheral type names across Advanced Peripherals / Minecraft versions.
GeoScanner.PERIPHERAL_TYPES = {
    "geoScanner",
    "geo_scanner",
}

--- Known End Automata / Automata peripheral type names across Advanced Peripherals versions.
GeoScanner.AUTOMATA_TYPES = {
    "endAutomata",
    "end_automata",
    "overpoweredEndAutomata",
    "overpowered_end_automata",
    "weakAutomata",
    "weak_automata",
}

--- Default patterns that identify a block as an ore when tags are missing or alongside tags.
GeoScanner.DEFAULT_ORE_PATTERNS = {
    "_ore$",
    "_ore_",
    "^minecraft:ancient_debris$",
    "^minecraft:gilded_blackstone$",
    "^minecraft:budding_amethyst$",
    "^minecraft:amethyst_cluster$",
    "^minecraft:raw_.*_block$",
}

--- Default tags that identify a block as an ore.
GeoScanner.DEFAULT_ORE_TAGS = {
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

--- Convert a registry name like `"minecraft:deepslate_diamond_ore"` into `"diamond_ore"`.
-- @tparam string name Block registry ID
-- @treturn string Short identifier
function GeoScanner.shortName(name)
    if type(name) ~= "string" then
        return tostring(name or "unknown")
    end
    local short = name:match("^[^:]+:(.+)$") or name
    return short
end

--- Convert a registry name into a human-readable label like `"Deepslate Diamond Ore"`.
-- @tparam string name Block registry ID
-- @treturn string Human-readable block name
function GeoScanner.prettyName(name)
    local short = GeoScanner.shortName(name)
    local words = {}
    for word in short:gmatch("[^_]+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2))
    end
    return table.concat(words, " ")
end

--- Normalize the `tags` field of a scanned block into a lookup map `{ [tag] = true }`
-- and a sorted array of tag strings.
-- Handles both array-style `{"forge:ores"}` and map-style `{["forge:ores"] = true}`.
-- @tparam table|nil rawTags Raw tags table from `scan()`
-- @treturn table tagMap, table tagList
function GeoScanner.normalizeTags(rawTags)
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

--- Check whether a block entry has a specific tag (with or without leading `#`).
-- @tparam table block Block table from `scan()`
-- @tparam string tag Tag name to check
-- @treturn boolean
function GeoScanner.hasTag(block, tag)
    if type(block) ~= "table" or type(tag) ~= "string" then
        return false
    end
    local clean = tag:gsub("^#", "")
    local tagMap = block.tagMap
    if not tagMap then
        tagMap = GeoScanner.normalizeTags(block.tags)
    end
    return tagMap[clean] == true
end

--- Check whether a block or item table has an ore tag (e.g. `forge:ores`, `c:ores`, `minecraft:*_ores`).
-- @tparam table block Block or item detail table with `.tags` or `.tagMap`
-- @treturn boolean
function GeoScanner.hasOreTag(block)
    if type(block) ~= "table" then
        return false
    end
    local tagMap = block.tagMap or GeoScanner.normalizeTags(block.tags)
    for tag, _ in pairs(tagMap) do
        local lower = tag:lower()
        if GeoScanner.DEFAULT_ORE_TAGS[lower] then
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

--- Common non-ore waste blocks that turtles may dig through to reach ores.
GeoScanner.WASTE_BLOCKS = {
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

--- Check whether an item registry name is a battery / energy capacitor / FE cell for `chargeTurtle()`.
-- @tparam string name Item registry ID
-- @treturn boolean
function GeoScanner.isEnergyItemName(name)
    if type(name) ~= "string" then
        return false
    end
    local lower = name:lower()
    if lower:find("_ore", 1, true) then
        return false
    end
    if lower:find("energy", 1, true)
        or lower:find("battery", 1, true)
        or lower:find("capacitor", 1, true)
        or lower:find("flux_", 1, true)
        or lower:find("_cell", 1, true)
        or lower:find("energy_tablet", 1, true)
        or lower:find("energy_cube", 1, true)
        or lower:find("accumulator", 1, true)
        or lower:find("power_cell", 1, true)
        or lower:find("charge_crystal", 1, true)
    then
        return true
    end
    return false
end

--- Check whether a block or item name is a common non-ore terrain/waste block.
-- @tparam string name Block or item registry name
-- @treturn boolean
function GeoScanner.isWasteName(name)
    if type(name) ~= "string" then
        return false
    end
    local lower = name:lower()
    if GeoScanner.isEnergyItemName(lower) then
        return false
    end
    if GeoScanner.WASTE_BLOCKS[lower] then
        return true
    end
    local short = GeoScanner.shortName(lower)
    if short:find("_ore", 1, true) or short:find("raw_", 1, true) or short == "redstone" or short == "gilded_blackstone" then
        return false
    end
    if short == "dirt"
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
    then
        return true
    end
    return false
end

--- Determine whether an inventory item detail (from `turtle.getItemDetail(slot, true)`)
-- represents a mined ore or raw ore drop.
-- @tparam table itemDetail Item detail table `{ name, count, tags }`
-- @tparam[opt] table trackedMinedItems Optional lookup `{ [itemName] = true }` of items collected when mining ores
-- @treturn boolean
function GeoScanner.isOreItem(itemDetail, trackedMinedItems)
    if type(itemDetail) ~= "table" or type(itemDetail.name) ~= "string" then
        return false
    end
    local name = itemDetail.name:lower()
    if GeoScanner.isWasteName(name) or GeoScanner.isEnergyItemName(name) then
        return false
    end
    if trackedMinedItems and trackedMinedItems[name] then
        return true
    end
    if GeoScanner.hasOreTag(itemDetail) or GeoScanner.isOre(itemDetail) then
        return true
    end
    local tagMap = itemDetail.tagMap or GeoScanner.normalizeTags(itemDetail.tags)
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

--- Determine whether a block table or block registry name represents an ore.
-- @tparam table|string blockOrName Block table (with `.name` and optional `.tags`) or block name string
-- @treturn boolean
function GeoScanner.isOre(blockOrName)
    local name
    if type(blockOrName) == "string" then
        name = blockOrName
    elseif type(blockOrName) == "table" then
        name = blockOrName.name
        if GeoScanner.hasOreTag(blockOrName) then
            return true
        end
    else
        return false
    end

    if type(name) == "string" then
        local lower = name:lower()
        for _, pattern in ipairs(GeoScanner.DEFAULT_ORE_PATTERNS) do
            if lower:match(pattern) then
                return true
            end
        end
    end

    return false
end

--- Format relative coordinates into a compact compass/direction hint.
-- In Minecraft: +X = East, -X = West, +Y = Up, -Y = Down, +Z = South, -Z = North.
-- @tparam number x Relative X
-- @tparam number y Relative Y
-- @tparam number z Relative Z
-- @treturn string Direction hint (e.g. `"3E 2D 5S"`)
function GeoScanner.formatDirection(x, y, z)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    z = tonumber(z) or 0
    local parts = {}
    if x > 0 then
        table.insert(parts, x .. "E")
    elseif x < 0 then
        table.insert(parts, math.abs(x) .. "W")
    end
    if y > 0 then
        table.insert(parts, y .. "U")
    elseif y < 0 then
        table.insert(parts, math.abs(y) .. "D")
    end
    if z > 0 then
        table.insert(parts, z .. "S")
    elseif z < 0 then
        table.insert(parts, math.abs(z) .. "N")
    end
    if #parts == 0 then
        return "Here"
    end
    return table.concat(parts, " ")
end

--- Enrich a raw block entry returned by `scan()` with distance, shortName, prettyName, tags, and ore status.
-- @tparam table raw Raw block entry `{ name, x, y, z, tags }`
-- @treturn table Enriched block entry
function GeoScanner.enrichBlock(raw)
    local x = tonumber(raw.x) or 0
    local y = tonumber(raw.y) or 0
    local z = tonumber(raw.z) or 0
    local manhattan = math.abs(x) + math.abs(y) + math.abs(z)
    local euclidean = math.sqrt(x * x + y * y + z * z)
    local tagMap, tagList = GeoScanner.normalizeTags(raw.tags)

    local enriched = {
        name = raw.name or "unknown",
        shortName = GeoScanner.shortName(raw.name),
        prettyName = GeoScanner.prettyName(raw.name),
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
        direction = GeoScanner.formatDirection(x, y, z),
    }
    enriched.hasOreTag = GeoScanner.hasOreTag(enriched)
    enriched.isOre = GeoScanner.isOre(enriched)
    return enriched
end

--- Check if a peripheral table looks like a Geo Scanner by inspecting its methods.
local function isGeoScannerPeripheral(p)
    if type(p) ~= "table" then
        return false
    end
    local hasScan = type(p.scan) == "function" or type(p.scanBlocks) == "function"
    local hasChunk = type(p.chunkAnalyze) == "function"
    return hasScan or hasChunk
end

--- Wrap an existing Geo Scanner peripheral table.
-- @tparam table peripheralObj Wrapped CC: Tweaked peripheral
-- @tparam[opt] string name Peripheral name or side
-- @treturn GeoScanner|nil, string|nil
function GeoScanner.new(peripheralObj, name)
    if not isGeoScannerPeripheral(peripheralObj) then
        return nil, "Provided object is not a valid Geo Scanner peripheral"
    end
    local self = setmetatable({}, GeoScanner)
    self.raw = peripheralObj
    self.name = name or (peripheral and peripheral.getName and pcall(peripheral.getName, peripheralObj) and peripheral.getName(peripheralObj)) or "geoScanner"
    return self
end

--- Find and wrap a connected Geo Scanner peripheral automatically.
-- Searches for `"geoScanner"`, `"geo_scanner"`, or any connected peripheral providing `scan`/`chunkAnalyze`.
-- @tparam[opt] string sideOrName Specific side or network name (e.g. `"back"`, `"left"`, `"geoScanner_0"`)
-- @treturn GeoScanner|nil, string|nil
function GeoScanner.find(sideOrName)
    if not peripheral then
        return nil, "CC: Tweaked peripheral API is not available"
    end

    if type(sideOrName) == "string" and sideOrName ~= "" then
        if peripheral.isPresent(sideOrName) then
            local p = peripheral.wrap(sideOrName)
            if isGeoScannerPeripheral(p) then
                return GeoScanner.new(p, sideOrName)
            end
            return nil, ("Peripheral on '%s' is not a Geo Scanner"):format(sideOrName)
        end
        return nil, ("No peripheral found on '%s'"):format(sideOrName)
    end

    -- Try standard peripheral types first
    for _, pType in ipairs(GeoScanner.PERIPHERAL_TYPES) do
        local p = peripheral.find(pType)
        if isGeoScannerPeripheral(p) then
            local foundName = pType
            if peripheral.getName then
                local ok, n = pcall(peripheral.getName, p)
                if ok and n then
                    foundName = n
                end
            end
            return GeoScanner.new(p, foundName)
        end
    end

    -- Fallback: scan all connected peripheral names by method signature
    if peripheral.getNames then
        for _, name in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(name)
            if isGeoScannerPeripheral(p) then
                return GeoScanner.new(p, name)
            end
        end
    end

    return nil, "No Geo Scanner found. Attach a Geo Scanner to your computer, turtle, or pocket computer."
end

--- Check if a peripheral table is an End Automata (or Automata Core) peripheral.
-- @tparam table p Peripheral table
-- @treturn boolean
function GeoScanner.isAutomataPeripheral(p)
    if type(p) ~= "table" then
        return false
    end
    return type(p.warpToPoint) == "function"
        or type(p.savePoint) == "function"
        or type(p.chargeTurtle) == "function"
        or type(p.digBlock) == "function"
end

--- Find a connected End Automata (or Automata Core) peripheral automatically.
-- @tparam[opt] string sideOrName Specific side or network name
-- @treturn table|nil, string|nil Peripheral table and its side/name (or `nil, err`)
function GeoScanner.findAutomata(sideOrName)
    if not peripheral then
        return nil, "CC: Tweaked peripheral API is not available"
    end

    if type(sideOrName) == "string" and sideOrName ~= "" then
        if peripheral.isPresent and peripheral.isPresent(sideOrName) then
            local p = peripheral.wrap and peripheral.wrap(sideOrName)
            if GeoScanner.isAutomataPeripheral(p) then
                return p, sideOrName
            end
        end
        return nil, ("No End Automata found on '%s'"):format(sideOrName)
    end

    if type(peripheral.find) == "function" then
        for _, aType in ipairs(GeoScanner.AUTOMATA_TYPES) do
            local p = peripheral.find(aType)
            if GeoScanner.isAutomataPeripheral(p) then
                local foundName = aType
                if peripheral.getName then
                    local ok, n = pcall(peripheral.getName, p)
                    if ok and n then
                        foundName = n
                    end
                end
                return p, foundName
            end
        end
    end

    if type(peripheral.getNames) == "function" and type(peripheral.wrap) == "function" then
        for _, name in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(name)
            if GeoScanner.isAutomataPeripheral(p) then
                return p, name
            end
        end
    end

    return nil, "No End Automata found"
end

--- Get the FE/fuel cost for scanning at the given radius.
-- @tparam number radius Scan radius (e.g. 1..16)
-- @treturn number Cost in FE (0 if free or unsupported)
function GeoScanner:getCost(radius)
    radius = tonumber(radius) or 8
    if type(self.raw.cost) == "function" then
        local ok, res = pcall(self.raw.cost, radius)
        if ok and type(res) == "number" then
            return res
        end
    end
    return 0
end

--- Get the current and maximum fuel/energy level of the Geo Scanner.
-- @treturn table `{ level = number|nil, max = number }`
function GeoScanner:getFuel()
    local level = nil
    local max = 0

    if type(self.raw.getFuelLevel) == "function" then
        local ok, val = pcall(self.raw.getFuelLevel)
        if ok and type(val) == "number" then
            level = val
        end
    end

    if type(self.raw.getMaxFuelLevel) == "function" then
        local ok, val = pcall(self.raw.getMaxFuelLevel)
        if ok and type(val) == "number" then
            max = val
        end
    end

    return {
        level = level,
        max = max,
    }
end

--- Build a predicate function from filter options.
-- @tparam table|function|string|nil filter
--   - `function(block) -> boolean`: custom predicate
--   - `string`: substring match on block name/prettyName, or `#tag` match if starts with `#`
--   - `table`: `{ oresOnly = bool, query = string, tag = string, minY = number, maxY = number, maxDist = number }`
-- @treturn function Predicate `function(block) -> boolean`
function GeoScanner.buildFilter(filter)
    if filter == nil then
        return function() return true end
    end
    if type(filter) == "function" then
        return filter
    end
    if type(filter) == "string" then
        local trimmed = filter:match("^%s*(.-)%s*$")
        if trimmed == "" then
            return function() return true end
        end
        if trimmed:sub(1, 1) == "#" then
            local targetTag = trimmed:sub(2):lower()
            return function(block)
                for tag, _ in pairs(block.tagMap or {}) do
                    if tag:lower():find(targetTag, 1, true) then
                        return true
                    end
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
        local queryFn = filter.query and GeoScanner.buildFilter(filter.query) or nil
        local tagFn = filter.tag and GeoScanner.buildFilter("#" .. filter.tag:gsub("^#", "")) or nil
        return function(block)
            if filter.oresOnly and not block.isOre then
                return false
            end
            if filter.minY and block.y < filter.minY then
                return false
            end
            if filter.maxY and block.y > filter.maxY then
                return false
            end
            if filter.maxDist and block.dist > filter.maxDist then
                return false
            end
            if queryFn and not queryFn(block) then
                return false
            end
            if tagFn and not tagFn(block) then
                return false
            end
            if type(filter.predicate) == "function" and not filter.predicate(block) then
                return false
            end
            return true
        end
    end
    return function() return true end
end

--- Filter and sort a list of enriched block entries.
-- @tparam table blocks List of enriched blocks
-- @tparam[opt] table|function|string filter Filter specification
-- @tparam[opt="dist"] string sortBy `"dist"` (Manhattan), `"euclidean"`, or `"name"`
-- @treturn table Filtered and sorted list of blocks
function GeoScanner.filterBlocks(blocks, filter, sortBy)
    local predicate = GeoScanner.buildFilter(filter)
    local out = {}
    for _, b in ipairs(blocks or {}) do
        local enriched = (b.dist ~= nil and b.tagMap ~= nil) and b or GeoScanner.enrichBlock(b)
        if predicate(enriched) then
            table.insert(out, enriched)
        end
    end

    sortBy = sortBy or "dist"
    table.sort(out, function(a, b)
        if sortBy == "name" then
            if a.shortName ~= b.shortName then
                return a.shortName < b.shortName
            end
            return a.dist < b.dist
        elseif sortBy == "euclidean" then
            if a.euclidean ~= b.euclidean then
                return a.euclidean < b.euclidean
            end
            return a.shortName < b.shortName
        else
            if a.dist ~= b.dist then
                return a.dist < b.dist
            end
            return a.shortName < b.shortName
        end
    end)

    return out
end

--- Group a list of enriched blocks by their registry name, calculating counts and nearest block.
-- @tparam table blocks List of enriched blocks
-- @treturn table Sorted array of groups `{ name, shortName, prettyName, isOre, count, nearest, blocks }`
function GeoScanner.groupByBlock(blocks)
    local groupsByName = {}
    local groups = {}

    for _, raw in ipairs(blocks or {}) do
        local b = (raw.dist ~= nil and raw.tagMap ~= nil) and raw or GeoScanner.enrichBlock(raw)
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
        if b.dist < g.nearest.dist then
            g.nearest = b
        end
    end

    for _, g in ipairs(groups) do
        table.sort(g.blocks, function(a, b)
            return a.dist < b.dist
        end)
    end

    table.sort(groups, function(a, b)
        if a.nearest.dist ~= b.nearest.dist then
            return a.nearest.dist < b.nearest.dist
        end
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.shortName < b.shortName
    end)

    return groups
end

--- Sleep helper that works inside CC: Tweaked (`os.sleep`) or falls back to a no-op in plain Lua tests.
local function sleepSeconds(sec)
    if os and type(os.sleep) == "function" then
        os.sleep(sec)
    elseif type(_G.sleep) == "function" then
        _G.sleep(sec)
    end
end

--- Scan blocks within `radius` around the Geo Scanner.
-- Supports AP 0.7 `scan(radius)` and AP 0.8 `scanBlocks(radius)`.
-- @tparam[opt=8] number radius Scan radius
-- @tparam[opt] table opts Options:
--   - `oresOnly` (boolean): only return ore blocks
--   - `query` (string): filter by block name/tag (`#tag`)
--   - `filter` (function|table|string): custom filter passed to `GeoScanner.filterBlocks`
--   - `sortBy` (string): `"dist"` (default), `"euclidean"`, or `"name"`
--   - `retries` (number): number of retries if the scanner is on cooldown (default 0)
--   - `retryDelay` (number): seconds to wait between cooldown retries (default 0.6)
-- @treturn table|nil Enriched, filtered, and sorted block list (or `nil` on error)
-- @treturn string|nil Error message when scan fails
function GeoScanner:scan(radius, opts)
    radius = math.max(1, math.floor(tonumber(radius) or 8))
    opts = opts or {}
    local retries = tonumber(opts.retries) or 0
    local retryDelay = tonumber(opts.retryDelay) or 0.6

    local scanFn = self.raw.scan or self.raw.scanBlocks
    if type(scanFn) ~= "function" then
        return nil, "Geo Scanner peripheral does not support scan()"
    end

    local rawResult, err
    for attempt = 0, retries do
        local ok, res, reason = pcall(scanFn, radius)
        if not ok then
            rawResult, err = nil, tostring(res)
        else
            rawResult, err = res, reason
        end

        if type(rawResult) == "table" then
            break
        end

        local errStr = tostring(err or "Scan failed")
        local isCooldown = errStr:lower():find("cooldown", 1, true)
            or errStr:lower():find("wait", 1, true)
            or errStr:lower():find("delay", 1, true)
        if attempt < retries and isCooldown then
            sleepSeconds(retryDelay)
        else
            return nil, errStr
        end
    end

    if type(rawResult) ~= "table" then
        return nil, tostring(err or "Unknown scan error")
    end

    local enriched = {}
    for _, rawBlock in ipairs(rawResult) do
        table.insert(enriched, GeoScanner.enrichBlock(rawBlock))
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

    return GeoScanner.filterBlocks(enriched, filterSpec, opts.sortBy)
end

--- Scan for ores by block tag (e.g. `#forge:ores`, `#c:ores`, `#minecraft:*_ores`) within `radius`.
-- @tparam[opt=8] number radius Scan radius
-- @tparam[opt] table opts Additional scan options
-- @treturn table|nil, string|nil
function GeoScanner:scanOresByTag(radius, opts)
    local merged = {}
    if type(opts) == "table" then
        for k, v in pairs(opts) do
            merged[k] = v
        end
    end
    merged.filter = function(block)
        return GeoScanner.hasOreTag(block)
    end
    return self:scan(radius, merged)
end

--- Scan for ores only within `radius` (convenience wrapper around `scan`).
-- @tparam[opt=8] number radius Scan radius
-- @tparam[opt] table opts Additional scan options
-- @treturn table|nil, string|nil
function GeoScanner:scanOres(radius, opts)
    local merged = {}
    if type(opts) == "table" then
        for k, v in pairs(opts) do
            merged[k] = v
        end
    end
    merged.oresOnly = true
    return self:scan(radius, merged)
end

--- Find the single nearest matching block within `radius`.
-- @tparam[opt=8] number radius Scan radius
-- @tparam[opt] string|table|function filter Filter query, `#tag`, options table, or predicate
-- @tparam[opt] table scanOpts Additional scan options (`retries`, etc.)
-- @treturn table|nil Nearest enriched block, or `nil` if none found / error
-- @treturn string|nil Error message if scan failed
function GeoScanner:findNearest(radius, filter, scanOpts)
    local opts = {}
    if type(scanOpts) == "table" then
        for k, v in pairs(scanOpts) do
            opts[k] = v
        end
    end
    opts.filter = filter
    opts.sortBy = "dist"

    local blocks, err = self:scan(radius, opts)
    if not blocks then
        return nil, err
    end
    return blocks[1], nil
end

--- Analyze ore counts in the current chunk using `chunkAnalyze()`.
-- @tparam[opt] table opts Options:
--   - `query` (string): filter returned entries by substring
--   - `retries` (number): number of retries on cooldown (default 0)
--   - `retryDelay` (number): delay between retries in seconds (default 0.6)
-- @treturn table|nil Result table `{ entries = { { name, shortName, prettyName, count }, ... }, raw = table, total = number }`
-- @treturn string|nil Error message if `chunkAnalyze()` fails
function GeoScanner:analyzeChunk(opts)
    opts = opts or {}
    local retries = tonumber(opts.retries) or 0
    local retryDelay = tonumber(opts.retryDelay) or 0.6

    if type(self.raw.chunkAnalyze) ~= "function" then
        return nil, "Geo Scanner peripheral does not support chunkAnalyze()"
    end

    local rawCounts, err
    for attempt = 0, retries do
        local ok, res, reason = pcall(self.raw.chunkAnalyze)
        if not ok then
            rawCounts, err = nil, tostring(res)
        else
            rawCounts, err = res, reason
        end

        if type(rawCounts) == "table" then
            break
        end

        local errStr = tostring(err or "Chunk analyze failed")
        local isCooldown = errStr:lower():find("cooldown", 1, true)
            or errStr:lower():find("wait", 1, true)
            or errStr:lower():find("delay", 1, true)
        if attempt < retries and isCooldown then
            sleepSeconds(retryDelay)
        else
            return nil, errStr
        end
    end

    if type(rawCounts) ~= "table" then
        return nil, tostring(err or "Unknown chunkAnalyze error")
    end

    local queryLower = type(opts.query) == "string" and opts.query:match("^%s*(.-)%s*$"):lower() or ""
    local entries = {}
    local total = 0

    for blockName, count in pairs(rawCounts) do
        local num = tonumber(count) or 0
        if num > 0 then
            local pretty = GeoScanner.prettyName(blockName)
            local short = GeoScanner.shortName(blockName)
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
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.shortName < b.shortName
    end)

    return {
        entries = entries,
        raw = rawCounts,
        total = total,
    }
end

return GeoScanner
