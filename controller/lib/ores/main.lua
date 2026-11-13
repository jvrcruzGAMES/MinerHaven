--- libores - Controller-Side GeoScanner Management
-- Wraps the Advanced Peripherals Geo Scanner, performs scans, enforces authoritative scan radius,
-- filters ores, protects base blocks, and calibrates coordinates relative to Turtle Home.

local Ores = {}

--- Known peripheral type names for Geo Scanner
Ores.SCANNER_TYPES = {
    "geoScanner",
    "geo_scanner",
}

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
    -- Advanced Peripherals base blocks
    ["advancedperipherals:geo_scanner"] = true,
    ["advancedperipherals:environment_detector"] = true,
    ["advancedperipherals:player_detector"] = true,
    ["advancedperipherals:energy_detector"] = true,
    ["advancedperipherals:block_reader"] = true,
    ["advancedperipherals:inventory_manager"] = true,
    ["advancedperipherals:redstone_integrator"] = true,
    ["advancedperipherals:chat_box"] = true,
    -- Sophisticated Storage barrels & chests
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

--- Default patterns identifying ores
Ores.ORE_PATTERNS = {
    "_ore$",
    ":.*_ore$",
    ":.*_ore_.*$",
    "ancient_debris",
    "raw_.*_block$",
    ":raw_.*_block$",
}

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

--- Check if block name indicates a CC Turtle.
function Ores.isTurtleBlock(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    return lower == "computercraft:turtle_normal"
        or lower == "computercraft:turtle_advanced"
        or lower:match("^computercraft:turtle") ~= nil
end

--- Check if block is an ore by name or tags.
function Ores.isOre(block)
    if type(block) == "string" then
        block = { name = block }
    end
    if not block or type(block.name) ~= "string" then return false end

    -- Check tags
    if type(block.tags) == "table" then
        for _, tag in ipairs(block.tags) do
            local tagLower = tostring(tag):lower()
            if tagLower:find("ores", 1, true) or tagLower:find("ore", 1, true) then
                return true
            end
        end
    end

    local lower = block.name:lower()
    for _, pat in ipairs(Ores.ORE_PATTERNS) do
        if lower:match(pat) then
            return true
        end
    end
    return false
end

--- Find GeoScanner peripheral on any side.
function Ores.findScanner()
    if not peripheral then return nil, "peripheral API unavailable" end
    for _, t in ipairs(Ores.SCANNER_TYPES) do
        local p = peripheral.find(t)
        if p then return p end
    end
    return nil, "No Geo Scanner peripheral detected"
end

--------------------------------------------------------------------------------
-- GeoScanner Manager Class
--------------------------------------------------------------------------------

local Manager = {}
Manager.__index = Manager

function Ores.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Manager)
    self.scanner = opts.scanner
    self.turtleOffset = opts.turtleOffset or { x = 0, y = 0, z = 0, calibrated = false }
    self.lastScanTime = 0
    self.lastOreCount = 0
    return self
end

function Manager:ensureScanner()
    if self.scanner then return self.scanner end
    local s, err = Ores.findScanner()
    if s then
        self.scanner = s
        return s
    end
    return nil, err
end

--- Perform scan with retry for cooldowns.
-- Advanced Peripherals scan method is scanBlocks (0.8) or scan (0.7).
function Manager:rawScan(radius)
    local scanner, err = self:ensureScanner()
    if not scanner then return nil, err end

    local scanFn = scanner.scanBlocks or scanner.scan
    if not scanFn then
        return nil, "Geo Scanner has no scan or scanBlocks method"
    end

    local maxRetries = 6
    for attempt = 1, maxRetries do
        local ok, res, extra = pcall(scanFn, radius)
        if ok and type(res) == "table" then
            return res
        end

        local errMsg = tostring(res or extra or "")
        -- Check if on cooldown
        if errMsg:lower():find("cooldown") or errMsg:lower():find("wait") then
            if os.sleep then os.sleep(0.5) end
        else
            -- Try waiting slightly anyway
            if os.sleep then os.sleep(0.3) end
        end
    end

    return nil, "Scan failed after retries (scanner possibly on cooldown)"
end

--- Scan around base, calibrate turtle home offset if detected, and return translated ore list.
-- @tparam number radius Authoritative radius configured on Controller
-- @treturn table|nil ores
-- @treturn table|nil baseBlocks
-- @treturn string|nil error
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
                tags = b.tags,
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
