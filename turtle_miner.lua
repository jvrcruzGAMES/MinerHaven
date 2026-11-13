--- MinerHaven Turtle Auto-Miner (2-Computer + End Automata Edition)
-- Startup service & interactive controller for CC: Tweaked End Automata Turtles.
--
-- Features:
--   - 2-Computer Strategy via Ender Modem:
--       * Receives Ore locations (and forbidden Base block coordinates) from the Base Computer
--         (which has the Geo Scanner attached).
--       * Mines the passed ore locations until its 16-slot inventory is full or no ores are left.
--       * Teleports back to Home using the End Automata (`warpToPoint("home")`) and aligns with Home
--         (only digging the way back when there is no fuel to teleport or the End Automata breaks).
--       * Back at the base, places everything in its inventory into the Sophisticated Storage Barrel
--         to its side/front, EXCEPT any Energy Cube (which stays in the inventory for fuel).
--       * Repeats the cycle automatically!
--   - Base & Teleport Pad Protection:
--       * Never breaks any base blocks (`computercraft:*`, `advancedperipherals:*`,
--         `sophisticatedstorage:*`, `mekanism:*_energy_cube`, `minecraft:barrel`, `minecraft:chest`),
--         `allthemodium:teleport_pad`, or `minecraft:bedrock`.
--   - Down-first movement priority (`-Y` before `X/Z`) and places waste blocks in its path.
--   - Reprogrammable Home position and facing direction (`sethome [n|e|s|w]`).

local function setupPackagePath()
    local scriptDir = ""
    if shell and type(shell.getRunningProgram) == "function" then
        local running = shell.getRunningProgram()
        if fs and type(fs.getDir) == "function" then
            scriptDir = fs.getDir(running)
        end
    end
    local paths = {
        "?.lua",
        "?/init.lua",
        "lib/?.lua",
        "/lib/?.lua",
        "/minerhaven/lib/?.lua",
    }
    if scriptDir ~= "" then
        table.insert(paths, 1, "/" .. scriptDir .. "/lib/?.lua")
        table.insert(paths, 2, "/" .. scriptDir .. "/?.lua")
    end
    if package and package.path then
        package.path = table.concat(paths, ";") .. ";" .. package.path
    end
end

setupPackagePath()

local GeoScanner = require("geoscanner")

local HOME_FILE = "/home.cfg"
local POS_FILE = "/turtle_pos.cfg"
local STATE_FILE = "/minerhaven_state.cfg"
local HOME_WARP_NAME = "home"

-- Direction constants: 0 = North (-Z), 1 = East (+X), 2 = South (+Z), 3 = West (-X)
local DIR_NAMES = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
local DIR_VECTORS = {
    [0] = { x = 0, z = -1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = 1 },
    [3] = { x = -1, z = 0 },
}

local function parseDir(input)
    if type(input) == "number" then
        return input % 4
    end
    if type(input) == "string" then
        local c = input:match("^%s*(%a)")
        if c then
            c = c:lower()
            if c == "n" then return 0 end
            if c == "e" then return 1 end
            if c == "s" then return 2 end
            if c == "w" then return 3 end
        end
    end
    return 0
end

--------------------------------------------------------------------------------
-- Config & Persistence Helpers
--------------------------------------------------------------------------------

local function serializeTable(tbl)
    if textutils and type(textutils.serialize) == "function" then
        return textutils.serialize(tbl)
    end
    local parts = { "{\n" }
    for k, v in pairs(tbl) do
        local keyStr = type(k) == "string" and ("[%q]"):format(k) or ("[%d]"):format(k)
        local valStr
        if type(v) == "string" then
            valStr = ("%q"):format(v)
        elseif type(v) == "boolean" or type(v) == "number" then
            valStr = tostring(v)
        end
        if valStr then
            table.insert(parts, ("  %s = %s,\n"):format(keyStr, valStr))
        end
    end
    table.insert(parts, "}\n")
    return table.concat(parts)
end

local function unserializeTable(str)
    if not str or str == "" then return nil end
    if textutils and type(textutils.unserialize) == "function" then
        return textutils.unserialize(str)
    end
    local fn = loadstring("return " .. str)
    if fn then
        setfenv(fn, {})
        local ok, res = pcall(fn)
        if ok and type(res) == "table" then
            return res
        end
    end
    return nil
end

local function saveConfigFile(path, tbl)
    if not fs or not fs.open then return false end
    local h = fs.open(path, "w")
    if not h then return false end
    h.write(serializeTable(tbl))
    h.close()
    return true
end

local function loadConfigFile(path)
    if not fs or not fs.exists or not fs.exists(path) then
        return nil
    end
    local h = fs.open(path, "r")
    if not h then return nil end
    local content = h.readAll()
    h.close()
    return unserializeTable(content)
end

local function sleepSeconds(sec)
    if os and type(os.sleep) == "function" then
        os.sleep(sec)
    elseif type(_G.sleep) == "function" then
        _G.sleep(sec)
    end
end

--------------------------------------------------------------------------------
-- TurtleMiner Class
--------------------------------------------------------------------------------

local TurtleMiner = {}
TurtleMiner.__index = TurtleMiner

--- Forbidden blocks that the turtle must NEVER break and must pathfind around
-- (includes all Base blocks, Sophisticated Storage barrels, CC computers/modems, Geo Scanner, Energy Cubes, Teleport Pad, Bedrock).
TurtleMiner.PROTECTED_BLOCKS = GeoScanner.BASE_PROTECTED_BLOCKS

local function coordKey(x, y, z)
    return ("%d,%d,%d"):format(x, y, z)
end

function TurtleMiner.new(opts)
    opts = opts or {}
    local self = setmetatable({}, TurtleMiner)

    self.homeFile = opts.homeFile or HOME_FILE
    self.posFile = opts.posFile or POS_FILE
    self.stateFile = opts.stateFile or STATE_FILE

    self.home = loadConfigFile(self.homeFile) or { x = 0, y = 0, z = 0, dir = 0 }
    self.pos = loadConfigFile(self.posFile) or {
        x = self.home.x,
        y = self.home.y,
        z = self.home.z,
        dir = self.home.dir,
    }

    local savedState = loadConfigFile(self.stateFile)
    self.running = savedState and savedState.running == true or false
    self.keepProgramAlive = true
    self.phase = self.running and "MINING" or "IDLE (Stopped)"
    self.lastAction = self.running and "Resuming mining..." or "Waiting for 'start' instruction..."
    self.scanRadius = tonumber(opts.scanRadius) or 8
    self.maxExploreSteps = tonumber(opts.maxExploreSteps) or 16
    self.exploreCount = 0
    self.minedItems = {}
    self.energyItems = {}
    self.blockedCoords = {}
    self.oreQueue = {}
    self.oreBatchReceived = false
    self.lastMoveError = nil
    self.commandBuffer = ""
    self.scanner = opts.scanner or nil
    self.automata = opts.automata or nil
    self.automataSide = opts.automataSide or nil
    self.modem = opts.modem or nil
    self.automataBroken = false
    self.homeWarpSaved = false
    self.chunkOresRemaining = nil
    self.lastChunkMiningY = nil
    self.inWorkerStep = false
    self.pendingReturnOnStop = false

    return self
end

function TurtleMiner:isProtectedBlock(blockName)
    if type(blockName) ~= "string" then
        return false
    end
    if TurtleMiner.PROTECTED_BLOCKS[blockName:lower()] == true then
        return true
    end
    return GeoScanner.isProtectedBlockName(blockName)
end

function TurtleMiner:isHomeCoord(x, y, z)
    return self.home
        and x == self.home.x
        and y == self.home.y
        and z == self.home.z
end

function TurtleMiner:markBlocked(x, y, z)
    -- Never mark the Turtle's own Home parking spot as blocked
    if self:isHomeCoord(x, y, z) then
        return
    end
    self.blockedCoords[coordKey(x, y, z)] = true
end

function TurtleMiner:isBlocked(x, y, z)
    if self:isHomeCoord(x, y, z) then
        return false
    end
    return self.blockedCoords[coordKey(x, y, z)] == true
end

--------------------------------------------------------------------------------
-- End Automata, Ender Modem & Geo Scanner Peripheral Management
--------------------------------------------------------------------------------

--- Find and verify the End Automata peripheral is present and not broken.
function TurtleMiner:ensureAutomata()
    if self.automataBroken then
        self.automata = nil
        return nil, "End Automata is broken"
    end
    if self.automata and GeoScanner.isAutomataPeripheral(self.automata) then
        if self.automataSide and peripheral and type(peripheral.isPresent) == "function" then
            if self.automataSide == "left" or self.automataSide == "right" then
                if not peripheral.isPresent(self.automataSide) then
                    self.automata = nil
                    self.automataSide = nil
                end
            end
        end
        if self.automata then
            return self.automata, self.automataSide
        end
    end

    local found, sideOrErr = GeoScanner.findAutomata()
    if found then
        self.automata = found
        self.automataSide = sideOrErr
        return found, sideOrErr
    end
    self.automata = nil
    self.automataSide = nil
    return nil, sideOrErr
end

--- Find and open the attached Ender / Wireless Modem peripheral for talking to the Base Computer.
function TurtleMiner:ensureModem()
    if self.modem and GeoScanner.isModemPeripheral(self.modem) then
        return self.modem
    end
    local m, err = GeoScanner.findModem()
    if m then
        self.modem = m
        return m
    end
    if self:tryEquipModem() then
        m, err = GeoScanner.findModem()
        if m then
            self.modem = m
            return m
        end
    end
    self.modem = nil
    return nil, err
end

--- Transmit current Turtle status to the Base Computer over the Ender Modem.
function TurtleMiner:sendStatusToBase()
    local modem = self:ensureModem()
    if not modem then
        return false
    end
    local usedSlots, oreCount = self:getInventoryStats()
    local fuel = (turtle and turtle.getFuelLevel) and turtle.getFuelLevel() or 0
    return GeoScanner.transmitMessage(modem, {
        type = "turtle_status",
        phase = self.phase,
        x = self.pos.x,
        y = self.pos.y,
        z = self.pos.z,
        dir = self.pos.dir,
        fuel = fuel,
        usedSlots = usedSlots,
        oreCount = oreCount,
        lastAction = self.lastAction,
    })
end

--- Handle an incoming modem message from the Base Computer.
function TurtleMiner:handleModemMessage(msg)
    if type(msg) ~= "table" then
        return false
    end

    if msg.type == "ore_locations" then
        -- 1. Mark all base blocks reported by the Base Computer in `self.blockedCoords`
        if type(msg.baseBlocks) == "table" then
            for _, b in ipairs(msg.baseBlocks) do
                local bx = self.home.x + (tonumber(b.x) or 0)
                local by = self.home.y + (tonumber(b.y) or 0)
                local bz = self.home.z + (tonumber(b.z) or 0)
                self:markBlocked(bx, by, bz)
            end
        end

        -- 2. Store the passed ore locations (relative to Home)
        self.oreQueue = {}
        if type(msg.ores) == "table" then
            for _, ore in ipairs(msg.ores) do
                local ox = tonumber(ore.x) or 0
                local oy = tonumber(ore.y) or 0
                local oz = tonumber(ore.z) or 0
                if not self:isBlocked(self.home.x + ox, self.home.y + oy, self.home.z + oz) then
                    table.insert(self.oreQueue, {
                        name = ore.name or "minecraft:iron_ore",
                        shortName = ore.shortName or GeoScanner.shortName(ore.name),
                        prettyName = ore.prettyName or GeoScanner.prettyName(ore.name),
                        x = ox,
                        y = oy,
                        z = oz,
                        dist = tonumber(ore.dist) or (math.abs(ox) + math.abs(oy) + math.abs(oz)),
                        fromHome = true,
                    })
                end
            end
        end

        self.chunkOresRemaining = #self.oreQueue
        self.oreBatchReceived = true
        self.lastAction = ("Received %d ore location(s) from Base Computer"):format(#self.oreQueue)
        return true
    elseif msg.type == "command" and type(msg.command) == "string" then
        self:executeCommand(msg.command)
        return true
    end

    return false
end

--- Request ore locations from the Base Computer over the Ender Modem and wait for the reply.
function TurtleMiner:requestOresFromBase(timeoutSec)
    local modem, err = self:ensureModem()
    if not modem then
        return false, err
    end

    self.oreBatchReceived = false
    self.lastAction = "Requesting ore locations from Base Computer..."
    local usedSlots, oreCount = self:getInventoryStats()
    local fuel = (turtle and turtle.getFuelLevel) and turtle.getFuelLevel() or 0

    GeoScanner.transmitMessage(modem, {
        type = "request_ores",
        radius = self.scanRadius,
        turtleStatus = {
            phase = self.phase,
            x = self.pos.x,
            y = self.pos.y,
            z = self.pos.z,
            fuel = fuel,
            usedSlots = usedSlots,
            oreCount = oreCount,
            lastAction = self.lastAction,
        },
    })

    -- If a synchronous mock modem already delivered the response inside `modem.transmit`:
    if self.oreBatchReceived then
        return true, self.oreQueue
    end

    if os and type(os.pullEvent) == "function" then
        local timerId = nil
        if type(os.startTimer) == "function" then
            timerId = os.startTimer(timeoutSec or 3.0)
        end
        for _ = 1, 32 do
            local ev, p1, p2, p3, p4 = os.pullEvent()
            if not ev then
                break
            end
            local modemMsg = GeoScanner.parseModemEvent(ev, p1, p2, p3, p4)
            if modemMsg then
                self:handleModemMessage(modemMsg)
                if self.oreBatchReceived then
                    return true, self.oreQueue
                end
            elseif ev == "timer" and timerId and p1 == timerId then
                break
            elseif ev == "minerhaven_command" then
                self:executeCommand(p1)
                if not self.running then
                    break
                end
            elseif ev == "char" then
                self.commandBuffer = self.commandBuffer .. p1
                self:drawUI()
            elseif ev == "key" then
                if p1 == (keys and keys.enter or 28) then
                    local cmd = self.commandBuffer
                    self.commandBuffer = ""
                    self:executeCommand(cmd)
                    self:drawUI()
                    if not self.running then
                        break
                    end
                elseif p1 == (keys and keys.backspace or 14) and #self.commandBuffer > 0 then
                    self.commandBuffer = self.commandBuffer:sub(1, -2)
                    self:drawUI()
                end
            end
        end
    end

    if self.oreBatchReceived then
        return true, self.oreQueue
    end
    return false, "Waiting for Base Computer response..."
end

--- Save the current turtle location as the `"home"` warp point on the End Automata.
function TurtleMiner:saveHomeWarpPoint()
    local automata = self:ensureAutomata()
    if not automata or type(automata.savePoint) ~= "function" then
        return false, "no_automata"
    end
    local ok, res, err = pcall(automata.savePoint, HOME_WARP_NAME)
    if ok and res == true then
        self.homeWarpSaved = true
        return true
    end
    return false, tostring(err or res or "savePoint failed")
end

--- Check whether the End Automata currently has `"home"` saved in its warp points list.
function TurtleMiner:hasHomeWarpPoint(automata)
    automata = automata or self:ensureAutomata()
    if not automata then
        return false
    end
    if type(automata.points) == "function" then
        local ok, pts = pcall(automata.points)
        if ok and type(pts) == "table" then
            for k, v in pairs(pts) do
                if v == HOME_WARP_NAME or k == HOME_WARP_NAME then
                    return true
                end
            end
            return false
        end
    end
    return true
end

--- Equip the Geo Scanner from inventory onto the non-Automata side if it was temporarily swapped out.
function TurtleMiner:tryEquipScanner()
    if not turtle or not turtle.getItemDetail then
        return false
    end
    local _, automataSide = self:ensureAutomata()
    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name and detail.name:lower():find("geo_scanner", 1, true) then
            turtle.select(slot)
            local equipped = false
            if automataSide == "left" and turtle.equipRight then
                equipped = turtle.equipRight()
            elseif automataSide == "right" and turtle.equipLeft then
                equipped = turtle.equipLeft()
            elseif turtle.equipLeft then
                equipped = turtle.equipLeft()
            elseif turtle.equipRight then
                equipped = turtle.equipRight()
            end
            if turtle.select then turtle.select(prevSlot) end
            return equipped
        end
    end
    if turtle.select then turtle.select(prevSlot) end
    return false
end

function TurtleMiner:ensureScanner()
    if self.scanner then
        return self.scanner
    end
    local s, err = GeoScanner.find()
    if not s then
        if self:tryEquipScanner() then
            s, err = GeoScanner.find()
        end
    end
    if s then
        self.scanner = s
        return s
    end
    self.lastAction = err or "No Geo Scanner attached"
    return nil
end

function TurtleMiner:savePos()
    saveConfigFile(self.posFile, self.pos)
end

function TurtleMiner:saveState()
    saveConfigFile(self.stateFile, { running = self.running })
end

--- Set the turtle's Home to the current block it is in, save to `/home.cfg`,
-- and save the `"home"` warp point in the End Automata if present.
function TurtleMiner:sethome(facingDir)
    local gx, gy, gz = nil, nil, nil
    if gps and type(gps.locate) == "function" then
        local ok, x, y, z = pcall(gps.locate, 1.5)
        if ok and x and y and z then
            gx, gy, gz = math.floor(x), math.floor(y), math.floor(z)
        end
    end

    local curX = gx or (self.pos and self.pos.x) or 0
    local curY = gy or (self.pos and self.pos.y) or 0
    local curZ = gz or (self.pos and self.pos.z) or 0
    local dir = facingDir ~= nil and parseDir(facingDir) or (self.pos and self.pos.dir) or 0

    self.pos = {
        x = curX,
        y = curY,
        z = curZ,
        dir = dir,
    }
    self.home = {
        x = curX,
        y = curY,
        z = curZ,
        dir = dir,
        useGps = (gx ~= nil),
    }
    saveConfigFile(self.homeFile, self.home)
    self:savePos()

    local warpSaved = self:saveHomeWarpPoint()
    local warpSuffix = warpSaved and " + Warp" or ""
    self.lastAction = ("Home set to (%d, %d, %d) [%s]%s"):format(
        self.home.x, self.home.y, self.home.z, DIR_NAMES[dir] or "N", warpSuffix
    )
    return self.home
end

-- Alias for backwards compatibility
TurtleMiner.setHomeHere = TurtleMiner.sethome

--- Start the auto-miner.
function TurtleMiner:start()
    self.running = true
    self.pendingReturnOnStop = false
    if not self:hasCoal() then
        self.phase = "WAITING FOR COAL"
        self.lastAction = "Started, but no coal in inventory! Add coal to turtle at Home..."
    else
        self.phase = "MINING"
        self.lastAction = "Started! Ready to mine..."
    end
    if self:isAtHome() then
        self:saveHomeWarpPoint()
    end
    self:saveState()
    self:sendStatusToBase()
end

--- Stop the auto-miner without exiting the program.
-- If stopped while running (even when inventory is not full), returns to Home before staying idle.
function TurtleMiner:stop()
    local wasRunning = self.running
    self.running = false
    self:saveState()

    if wasRunning or not self:isAtHome() then
        if self.inWorkerStep then
            self.pendingReturnOnStop = true
            self.phase = "RETURNING HOME (Stopping)"
            self.lastAction = "Stopping... returning to Home..."
        else
            if not self:isAtHome() then
                self:returnToHome()
            else
                self:turnTo(self.home.dir or 0)
            end
            self:unloadToBarrel()
            self.pendingReturnOnStop = false
            self.phase = "IDLE (Stopped)"
            self.lastAction = "Stopped at Home. Staying idle until 'start'..."
        end
    else
        self.phase = "IDLE (Stopped)"
        self.lastAction = "Stopped. Staying idle until 'start'..."
    end
    self:sendStatusToBase()
end

--------------------------------------------------------------------------------
-- Inventory, Barrel Unloading, Energy Charging & Waste Placement Management
--------------------------------------------------------------------------------

function TurtleMiner:snapshotInventoryCounts()
    local counts = {}
    if not turtle or not turtle.getItemDetail then
        return counts
    end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name then
            local name = detail.name:lower()
            counts[name] = (counts[name] or 0) + (detail.count or 1)
        end
    end
    return counts
end

function TurtleMiner:recordNewlyMinedItems(beforeCounts)
    if not turtle or not turtle.getItemDetail then
        return
    end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot, true)
        if detail and detail.name then
            local name = detail.name:lower()
            local prev = beforeCounts[name] or 0
            if (detail.count or 1) > prev and not GeoScanner.isWasteName(name) and not self:isFuelOrToolItem(detail) then
                self.minedItems[name] = true
            end
        end
    end
end

--- Check if an item is an Energy Cube / FE energy cell in the turtle's inventory (stays for fuel).
function TurtleMiner:isEnergyItem(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then
        return false
    end
    local name = detail.name:lower()
    return self.energyItems[name] == true or GeoScanner.isEnergyItemName(name)
end

--- Check whether an item is coal or charcoal.
function TurtleMiner:isCoalItem(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then
        return false
    end
    local name = detail.name:lower()
    if name:find("coal", 1, true) or name:find("charcoal", 1, true) then
        return true
    end
    if detail.tags then
        for _, tag in ipairs(detail.tags) do
            local t = tostring(tag):lower()
            if t:find("coal", 1, true) or t:find("charcoal", 1, true) then
                return true
            end
        end
    end
    return false
end

--- Count the total amount of coal/charcoal in the turtle's inventory.
function TurtleMiner:getCoalCount()
    if not turtle then
        return 0
    end
    local total = 0
    for slot = 1, 16 do
        local count = (turtle.getItemCount and turtle.getItemCount(slot)) or 0
        if count > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if detail and self:isCoalItem(detail) then
                total = total + (detail.count or count)
            end
        end
    end
    return total
end

--- Check whether the turtle has coal in its inventory.
function TurtleMiner:hasCoal()
    return self:getCoalCount() > 0
end

--- Check whether an item is any fuel item (coal, charcoal, blaze rod, lava bucket, or any refuelable item).
function TurtleMiner:isFuelItem(detail, slot)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then
        return false
    end
    if self:isCoalItem(detail) then
        return true
    end
    local name = detail.name:lower()
    if name:find("blaze_rod", 1, true)
        or name == "minecraft:lava_bucket"
        or name:find("fuel", 1, true)
        or name:find("bio_fuel", 1, true)
    then
        return true
    end
    if detail.tags then
        for _, tag in ipairs(detail.tags) do
            local t = tostring(tag):lower()
            if t:find("fuel", 1, true) or t:find("coal", 1, true) then
                return true
            end
        end
    end
    if slot and turtle and type(turtle.refuel) == "function" and type(turtle.select) == "function" then
        local prev = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
        turtle.select(slot)
        local ok, isFuel = pcall(turtle.refuel, 0)
        turtle.select(prev)
        if ok and isFuel == true then
            return true
        end
    end
    return false
end

--- Check if an item should be kept in the turtle's inventory when unloading into the Sophisticated Storage barrel at the base.
-- Keeps any Energy Cube / energy item for fuel (plus any unequipped pickaxe/tool/modem if present).
-- Note: Fuel items (coal, charcoal, etc.) are handled in unloadToBarrel() which always keeps a stack (64) in storage.
function TurtleMiner:shouldKeepInInventoryAtBase(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then
        return false
    end
    if self:isEnergyItem(detail) then
        return true
    end
    local name = detail.name:lower()
    if name:find("pickaxe", 1, true)
        or name:find("paxel", 1, true)
        or name:find("drill", 1, true)
        or name:find("automata", 1, true)
        or name:find("modem", 1, true)
        or name:find("scanner", 1, true)
    then
        return true
    end
    return false
end

--- Check if an item is an energy battery/cell, fuel, or tool/peripheral so it is never placed as waste in tunnels.
function TurtleMiner:isFuelOrToolItem(detail, slot)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then
        return false
    end
    if self:shouldKeepInInventoryAtBase(detail) then
        return true
    end
    if self:isFuelItem(detail, slot) then
        return true
    end
    local name = detail.name:lower()
    if name:find("scanner", 1, true)
        or name:find("modem", 1, true)
        or name:find("_core", 1, true)
        or name:find("coal", 1, true)
        or name:find("charcoal", 1, true)
        or name == "minecraft:lava_bucket"
        or name == "minecraft:bucket"
        or name == "minecraft:blaze_rod"
    then
        return true
    end
    return false
end

--- Check whether the turtle has any items in its inventory that should be unloaded into the Sophisticated Storage barrel.
-- Respects keeping up to a full stack (64) of any fuel item in storage.
function TurtleMiner:hasItemsToUnload()
    if not turtle or not turtle.getItemCount then
        return false
    end
    local keptFuelCounts = {}
    for slot = 1, 16 do
        local count = turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if self:shouldKeepInInventoryAtBase(detail) then
                -- Always kept (Energy Cube, tool, modem)
            elseif detail and self:isFuelItem(detail, slot) then
                local fuelKey = detail.name:lower()
                local alreadyKept = keptFuelCounts[fuelKey] or 0
                local needed = math.max(0, 64 - alreadyKept)
                if count > needed then
                    return true
                else
                    keptFuelCounts[fuelKey] = alreadyKept + count
                end
            else
                return true
            end
        end
    end
    return false
end

--- Unload everything in the turtle's inventory into the Sophisticated Storage barrel at the base,
-- with the exception of any Energy Cube (or energy item / tool / modem), and always keeping a stack (64)
-- of any fuel item (coal, charcoal, etc.) in the turtle's storage.
function TurtleMiner:unloadToBarrel()
    if not turtle or not turtle.getItemCount then
        return 0
    end
    if not self:hasItemsToUnload() then
        return 0
    end

    -- Align with Home direction first (in the standard setup facing North, the Barrel is directly in front)
    self:turnTo(self.home.dir or 0)

    local dropFn = nil

    -- 1. Check if the Sophisticated Storage Barrel is directly in front, above, below, or on another horizontal side
    local hasFront, frontData = self:inspectDirection(turtle.inspect)
    if hasFront and GeoScanner.isStorageBarrelName(frontData.name) and type(turtle.drop) == "function" then
        dropFn = turtle.drop
    else
        local hasUp, upData = self:inspectDirection(turtle.inspectUp)
        if hasUp and GeoScanner.isStorageBarrelName(upData.name) and type(turtle.dropUp) == "function" then
            dropFn = turtle.dropUp
        else
            local hasDown, downData = self:inspectDirection(turtle.inspectDown)
            if hasDown and GeoScanner.isStorageBarrelName(downData.name) and type(turtle.dropDown) == "function" then
                dropFn = turtle.dropDown
            elseif type(turtle.inspect) == "function" and type(turtle.drop) == "function" then
                -- Check the other 3 horizontal sides (right, left, back relative to Home facing)
                local baseDir = self.home.dir or 0
                local candidateDirs = {
                    (baseDir + 1) % 4,
                    (baseDir + 3) % 4,
                    (baseDir + 2) % 4,
                }
                for _, d in ipairs(candidateDirs) do
                    self:turnTo(d)
                    local okBlk, blkData = self:inspectDirection(turtle.inspect)
                    if okBlk and GeoScanner.isStorageBarrelName(blkData.name) then
                        dropFn = turtle.drop
                        break
                    end
                end
                if not dropFn then
                    self:turnTo(baseDir)
                end
            end
        end
    end

    -- Fallback if no barrel block was detected via `inspect` (e.g. only drop is available)
    if not dropFn then
        local hasFrontNow, frontNowData = self:inspectDirection(turtle.inspect)
        if not (hasFrontNow and self:isProtectedBlock(frontNowData.name) and not GeoScanner.isStorageBarrelName(frontNowData.name)) then
            dropFn = turtle.drop or turtle.dropDown or turtle.dropUp
        end
    end

    if type(dropFn) ~= "function" then
        self:turnTo(self.home.dir or 0)
        return 0
    end

    local unloadedSlots = 0
    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    local keptFuelCounts = {}

    for slot = 1, 16 do
        local count = turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if self:shouldKeepInInventoryAtBase(detail) then
                -- Always kept (Energy Cube, tool, modem)
            elseif detail and self:isFuelItem(detail, slot) then
                local fuelKey = detail.name:lower()
                local alreadyKept = keptFuelCounts[fuelKey] or 0
                local needed = math.max(0, 64 - alreadyKept)
                if count <= needed then
                    keptFuelCounts[fuelKey] = alreadyKept + count
                    -- Keep all items in this slot (part of the 64 fuel stack)
                else
                    keptFuelCounts[fuelKey] = alreadyKept + needed
                    local toDrop = count - needed
                    if toDrop > 0 then
                        if turtle.select then
                            turtle.select(slot)
                        end
                        if dropFn(toDrop) then
                            unloadedSlots = unloadedSlots + 1
                        end
                    end
                end
            else
                -- Non-fuel item (ore, stone, etc.): drop entire slot
                if turtle.select then
                    turtle.select(slot)
                end
                if dropFn() then
                    unloadedSlots = unloadedSlots + 1
                end
            end
        end
    end

    if turtle.select then
        turtle.select(prevSlot)
    end

    -- Always restore alignment with Home's facing direction
    self:turnTo(self.home.dir or 0)
    return unloadedSlots
end

--- Check if an inventory item detail is a placeable non-ore waste block (dirt, cobblestone, stone, deepslate, etc.).
function TurtleMiner:isWasteItem(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then
        return false
    end
    if self:isFuelOrToolItem(detail) then
        return false
    end
    if GeoScanner.isOreItem(detail, self.minedItems) then
        return false
    end
    return true
end

--- Find the first inventory slot containing a non-ore waste block.
function TurtleMiner:findWasteSlot()
    if not turtle or not turtle.getItemDetail then
        return nil
    end
    for slot = 1, 16 do
        local count = turtle.getItemCount and turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail(slot, true)
            if detail and self:isWasteItem(detail) then
                return slot
            end
        end
    end
    return nil
end

--- Attempt to place the currently selected block in `dirName` (`"up"`, `"down"`, `"forward"`),
-- never placing a block inside the saved Home coordinates or forbidden Base coordinates.
function TurtleMiner:tryPlaceInDirection(dirName)
    if not turtle then
        return false
    end
    if dirName == "up" then
        local tx, ty, tz = self.pos.x, self.pos.y + 1, self.pos.z
        if self:isHomeCoord(tx, ty, tz) or self:isBlocked(tx, ty, tz) then
            return false
        end
        if type(turtle.placeUp) == "function" then
            return turtle.placeUp() == true
        end
    elseif dirName == "down" then
        local tx, ty, tz = self.pos.x, self.pos.y - 1, self.pos.z
        if self:isHomeCoord(tx, ty, tz) or self:isBlocked(tx, ty, tz) then
            return false
        end
        if type(turtle.placeDown) == "function" then
            return turtle.placeDown() == true
        end
    elseif dirName == "forward" then
        local vec = DIR_VECTORS[self.pos.dir] or { x = 0, z = -1 }
        local tx, ty, tz = self.pos.x + vec.x, self.pos.y, self.pos.z + vec.z
        if self:isHomeCoord(tx, ty, tz) or self:isBlocked(tx, ty, tz) then
            return false
        end
        if type(turtle.place) == "function" then
            return turtle.place() == true
        end
    end
    return false
end

--- Place a waste block in the turtle's path behind/around it after moving or digging an ore.
-- @tparam[opt] string lastMove `"down"`, `"up"`, `"forward"`, `"target_up"`, `"target_down"`, `"target_forward"`
function TurtleMiner:placeWasteInPath(lastMove)
    if not turtle then
        return false
    end
    local slot = self:findWasteSlot()
    if not slot then
        return false
    end

    local dirs
    if lastMove == "down" then
        dirs = { "up", "down" }
    elseif lastMove == "up" then
        dirs = { "down", "up" }
    elseif lastMove == "forward" then
        dirs = { "down", "up" }
    elseif lastMove == "target_up" then
        dirs = { "up", "down", "forward" }
    elseif lastMove == "target_down" then
        dirs = { "down", "up", "forward" }
    elseif lastMove == "target_forward" then
        dirs = { "forward", "down", "up" }
    else
        dirs = { "down", "up", "forward" }
    end

    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    if turtle.select then
        turtle.select(slot)
    end

    local placed = false
    for _, d in ipairs(dirs) do
        if self:tryPlaceInDirection(d) then
            placed = true
            break
        end
    end

    if turtle.select then
        turtle.select(prevSlot)
    end
    return placed
end

--- Place non-ore waste blocks (such as dirt, cobblestone, stone, deepslate) into open spaces around the turtle's path.
function TurtleMiner:placeWasteBlocks()
    if not turtle or not turtle.getItemDetail then
        return 0
    end
    local hasPlaceApi = type(turtle.placeDown) == "function"
        or type(turtle.placeUp) == "function"
        or type(turtle.place) == "function"
    if not hasPlaceApi then
        return 0
    end

    local placedSlots = 0
    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local count = turtle.getItemCount and turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail(slot, true)
            if detail and self:isWasteItem(detail) then
                if turtle.select then
                    turtle.select(slot)
                end
                local placedAny = false
                if self:tryPlaceInDirection("down") then
                    placedAny = true
                end
                if (turtle.getItemCount and turtle.getItemCount(slot) or 0) > 0 and self:tryPlaceInDirection("up") then
                    placedAny = true
                end
                if (turtle.getItemCount and turtle.getItemCount(slot) or 0) > 0 and self:tryPlaceInDirection("forward") then
                    placedAny = true
                end
                if placedAny then
                    placedSlots = placedSlots + 1
                end
            end
        end
    end
    if turtle.select then
        turtle.select(prevSlot)
    end
    return placedSlots
end

--- Ensure the inventory is not clogged with unplaced waste blocks when all 16 slots are full:
-- First places as many waste blocks as possible in the turtle's path (`placeDown`/`placeUp`/`place`);
-- if all 16 slots remain occupied and adjacent spaces are solid walls, keeps 1 waste slot for path
-- placement and clears any excess waste slots so ore slots are not blocked.
function TurtleMiner:clearWasteIfFull()
    if not self:isInventoryFull() then
        return
    end
    self:placeWasteBlocks()
    if not self:isInventoryFull() then
        return
    end
    if not turtle or not turtle.getItemDetail or not turtle.drop then
        return
    end
    local keptWasteSlot = false
    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local count = turtle.getItemCount and turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail(slot, true)
            if detail and self:isWasteItem(detail) then
                if not keptWasteSlot then
                    keptWasteSlot = true
                else
                    if turtle.select then turtle.select(slot) end
                    if turtle.dropDown then turtle.dropDown() end
                    if (turtle.getItemCount(slot) or 0) > 0 and turtle.drop then turtle.drop() end
                end
            end
        end
    end
    if turtle.select then
        turtle.select(prevSlot)
    end
end

-- Alias so existing callers invoke waste placement
TurtleMiner.dropWasteBlocks = TurtleMiner.placeWasteBlocks

--- Check if all 16 turtle inventory slots are occupied.
function TurtleMiner:isInventoryFull()
    if not turtle or not turtle.getItemCount then
        return false
    end
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then
            return false
        end
    end
    return true
end

--- Count how many occupied slots and how many total ore items are in the turtle's inventory.
function TurtleMiner:getInventoryStats()
    local usedSlots = 0
    local oreCount = 0
    if not turtle or not turtle.getItemCount then
        return 0, 0
    end
    local keptFuelCounts = {}
    for slot = 1, 16 do
        local count = turtle.getItemCount(slot) or 0
        if count > 0 then
            usedSlots = usedSlots + 1
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if detail and self:isFuelItem(detail, slot) then
                local fuelKey = detail.name:lower()
                local alreadyKept = keptFuelCounts[fuelKey] or 0
                local needed = math.max(0, 64 - alreadyKept)
                if count > needed then
                    oreCount = oreCount + (count - needed)
                    keptFuelCounts[fuelKey] = 64
                else
                    keptFuelCounts[fuelKey] = alreadyKept + count
                end
            elseif detail and GeoScanner.isOreItem(detail, self.minedItems) and not self:isFuelOrToolItem(detail, slot) then
                oreCount = oreCount + (detail.count or count)
            end
        end
    end
    return usedSlots, oreCount
end

--- Check whether the turtle's inventory currently contains any ores (by tag or mined ore item) that need unloading.
function TurtleMiner:hasOresInInventory()
    if not turtle or not turtle.getItemCount then
        return false
    end
    local keptFuelCounts = {}
    for slot = 1, 16 do
        local count = turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if detail and self:isFuelItem(detail, slot) then
                local fuelKey = detail.name:lower()
                local alreadyKept = keptFuelCounts[fuelKey] or 0
                local needed = math.max(0, 64 - alreadyKept)
                if count > needed then
                    return true
                else
                    keptFuelCounts[fuelKey] = alreadyKept + count
                end
            elseif detail and GeoScanner.isOreItem(detail, self.minedItems) and not self:isFuelOrToolItem(detail, slot) then
                return true
            end
        end
    end
    return false
end

--- Charge the turtle using an Energy Cube / FE energy item in the inventory via End Automata `chargeTurtle()`.
function TurtleMiner:chargeWithEnergy(minRequired)
    if not turtle or not turtle.getFuelLevel then
        return true
    end
    local level = turtle.getFuelLevel()
    if level == "unlimited" then
        return true
    end
    minRequired = minRequired or 20
    if level >= minRequired then
        return true
    end

    local automata = self:ensureAutomata()
    if not automata or type(automata.chargeTurtle) ~= "function" then
        return false
    end

    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local count = turtle.getItemCount and turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            local isKnownWaste = detail and detail.name and GeoScanner.isWasteName(detail.name)
            local isKnownOre = detail and GeoScanner.isOreItem(detail, self.minedItems) and not GeoScanner.isEnergyItemName(detail.name)
            if not isKnownWaste and not isKnownOre then
                if turtle.select then
                    turtle.select(slot)
                end
                for _ = 1, 8 do
                    if type(automata.getChargeCooldown) == "function" then
                        local cdOk, cd = pcall(automata.getChargeCooldown)
                        if cdOk and type(cd) == "number" and cd > 0 then
                            sleepSeconds(math.min(cd / 1000, 1.0))
                        end
                    end
                    local beforeFuel = turtle.getFuelLevel()
                    local needed = math.max(1, minRequired - beforeFuel)
                    local ok, res, extra = pcall(automata.chargeTurtle, needed)
                    local afterFuel = turtle.getFuelLevel()
                    local charged = ok and (
                        res == true
                        or (type(res) == "number" and res > 0)
                        or (type(extra) == "number" and extra > 0)
                        or (afterFuel > beforeFuel)
                    )
                    if charged then
                        if detail and detail.name then
                            self.energyItems[detail.name:lower()] = true
                        end
                        if afterFuel >= minRequired or afterFuel <= beforeFuel then
                            break
                        end
                    else
                        local errMsg = tostring(extra or res or "")
                        if errMsg:lower():find("cooldown", 1, true) then
                            sleepSeconds(0.5)
                        else
                            break
                        end
                    end
                end
                if turtle.getFuelLevel() >= minRequired then
                    break
                end
            end
        end
    end

    if turtle.select then
        turtle.select(prevSlot)
    end
    return turtle.getFuelLevel() >= minRequired
end

--- Ensure the turtle has at least `minRequired` fuel:
-- 1) Charges from Energy Cube / energy items via `automata.chargeTurtle()`
-- 2) Falls back to `turtle.refuel()` using burnable fuel in the inventory
function TurtleMiner:ensureFuel(minRequired)
    if not turtle or not turtle.getFuelLevel then
        return true
    end
    local level = turtle.getFuelLevel()
    if level == "unlimited" then
        return true
    end
    minRequired = minRequired or 20
    if level >= minRequired then
        return true
    end

    -- 1. Try charging with FE/energy via End Automata `chargeTurtle()`
    if self:chargeWithEnergy(minRequired) then
        return true
    end

    -- 2. Fallback to standard burnable fuel via `turtle.refuel()`
    if type(turtle.refuel) == "function" then
        local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
        for slot = 1, 16 do
            if turtle.getItemCount and turtle.getItemCount(slot) > 0 then
                local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
                local isCoal = detail and detail.name and detail.name:lower():find("coal", 1, true)
                if not detail or isCoal or not GeoScanner.isOreItem(detail, self.minedItems) then
                    if turtle.select then turtle.select(slot) end
                    turtle.refuel(16)
                    if turtle.getFuelLevel() >= minRequired then
                        break
                    end
                end
            end
        end
        if turtle.getFuelLevel() <= 0 then
            for slot = 1, 16 do
                if turtle.getItemCount and turtle.getItemCount(slot) > 0 then
                    if turtle.select then turtle.select(slot) end
                    turtle.refuel(1)
                    if turtle.getFuelLevel() > 0 then
                        break
                    end
                end
            end
        end
        if turtle.select then
            turtle.select(prevSlot)
        end
    end

    local finalFuel = turtle.getFuelLevel()
    if minRequired > 1 then
        return finalFuel >= minRequired
    end
    return finalFuel > 0
end

--- Select the pickaxe / mining tool in the turtle's inventory for `automata.digBlock()`.
function TurtleMiner:selectToolSlot()
    if not turtle or not turtle.getItemDetail then
        return nil
    end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name then
            local name = detail.name:lower()
            if name:find("pickaxe", 1, true)
                or name:find("paxel", 1, true)
                or name:find("drill", 1, true)
            then
                if turtle.select then
                    turtle.select(slot)
                end
                return slot
            end
        end
    end
    return nil
end

--- Determine which side the End Automata is mounted on ("left" or "right").
function TurtleMiner:getAutomataSide()
    if peripheral and type(peripheral.getType) == "function" then
        local leftType = peripheral.getType("left")
        if leftType and leftType:lower():find("automata", 1, true) then
            self.automataSide = "left"
            return "left"
        end
        local rightType = peripheral.getType("right")
        if rightType and rightType:lower():find("automata", 1, true) then
            self.automataSide = "right"
            return "right"
        end
    end
    if self.automataSide == "left" or self.automataSide == "right" then
        return self.automataSide
    end
    return "left"
end

--- Determine the non-Automata side used for mining tools or Ender Modem.
function TurtleMiner:getToolSide()
    local autoSide = self:getAutomataSide()
    return (autoSide == "left") and "right" or "left"
end

--- If the turtle has a pickaxe in its inventory, equip it on the non-Automata side.
function TurtleMiner:tryEquipPickaxe()
    if not turtle or not turtle.getItemDetail then
        return false
    end
    local toolSide = self:getToolSide()
    local equipFn = (toolSide == "left") and turtle.equipLeft or turtle.equipRight
    if not equipFn then
        return false
    end

    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name and (
            detail.name:lower():find("pickaxe", 1, true)
            or detail.name:lower():find("paxel", 1, true)
            or detail.name:lower():find("drill", 1, true)
        ) then
            if turtle.select then turtle.select(slot) end
            if equipFn() then
                self.modem = nil
                self.scanner = nil
                if turtle.select then turtle.select(prevSlot) end
                return true
            end
        end
    end
    if turtle.select then
        turtle.select(prevSlot)
    end
    return false
end

--- If the turtle has an Ender Modem in its inventory, equip it on the non-Automata side.
function TurtleMiner:tryEquipModem()
    if not turtle or not turtle.getItemDetail then
        return false
    end
    local toolSide = self:getToolSide()
    local equipFn = (toolSide == "left") and turtle.equipLeft or turtle.equipRight
    if not equipFn then
        return false
    end

    if peripheral and type(peripheral.getType) == "function" then
        local curType = peripheral.getType(toolSide)
        if curType and curType:lower():find("modem", 1, true) then
            return true
        end
    end

    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name and detail.name:lower():find("modem", 1, true) then
            if turtle.select then turtle.select(slot) end
            if equipFn() then
                self.modem = nil
                if turtle.select then turtle.select(prevSlot) end
                return true
            end
        end
    end
    if turtle.select then
        turtle.select(prevSlot)
    end
    return false
end

--- Dig a block in `dirName` (`"forward"`, `"up"`, `"down"`) using the End Automata `digBlock()` API.
function TurtleMiner:digWithAutomata(dirName)
    local automata = self:ensureAutomata()
    if not automata or type(automata.digBlock) ~= "function" then
        return false, "no_automata_dig"
    end

    local prevSlot = (turtle and turtle.getSelectedSlot) and turtle.getSelectedSlot() or 1
    self:selectToolSlot()

    local rotOpts = { yaw = 0, pitch = 0 }
    local detectFn = turtle and turtle.detect or nil
    local suckFn = turtle and turtle.suck or nil
    if dirName == "up" then
        rotOpts = { yaw = 0, pitch = -90 }
        detectFn = turtle and turtle.detectUp or nil
        suckFn = turtle and turtle.suckUp or nil
    elseif dirName == "down" then
        rotOpts = { yaw = 0, pitch = 90 }
        detectFn = turtle and turtle.detectDown or nil
        suckFn = turtle and turtle.suckDown or nil
    end

    local lastErr = nil
    local dugSuccess = false
    for _ = 1, 12 do
        if type(automata.getDigCooldown) == "function" then
            local cdOk, cd = pcall(automata.getDigCooldown)
            if cdOk and type(cd) == "number" and cd > 0 then
                sleepSeconds(math.min(cd / 1000, 1.0))
            end
        end
        local ok, res, err = pcall(automata.digBlock, rotOpts)
        if ok and res == true then
            dugSuccess = true
            if type(automata.collectItems) == "function" then
                pcall(automata.collectItems)
            end
            if type(suckFn) == "function" then
                pcall(suckFn)
            end
            if not (type(detectFn) == "function" and detectFn()) then
                break
            end
            sleepSeconds(0.1)
        else
            lastErr = tostring(err or res or "digBlock failed")
            if lastErr:find("Java exception", 1, true) or lastErr:find("NullPointerException", 1, true) then
                -- Known AP 0.8.2a bug in APFakePlayer.awardStat when holding a damageable tool; abort immediately
                if turtle and turtle.select then
                    turtle.select(prevSlot)
                end
                return false, "java_exception"
            end
            if lastErr:lower():find("cooldown", 1, true) then
                sleepSeconds(0.5)
            else
                break
            end
        end
    end

    if turtle and turtle.select then
        turtle.select(prevSlot)
    end
    return dugSuccess, lastErr
end

--- Break a block in `dirName` (`"forward"`, `"up"`, `"down"`) using native `turtle.dig*` or `automata.digBlock`.
-- Always prioritizes native CC:Tweaked turtle.dig (auto-equipping a Pickaxe on the tool side if needed).
function TurtleMiner:tryDigDirection(dirName, isTargetOre)
    local digFn = turtle and turtle.dig or nil
    local detectFn = turtle and turtle.detect or nil
    if dirName == "up" then
        digFn = turtle and turtle.digUp or nil
        detectFn = turtle and turtle.detectUp or nil
    elseif dirName == "down" then
        digFn = turtle and turtle.digDown or nil
        detectFn = turtle and turtle.detectDown or nil
    end

    local before = isTargetOre and self:snapshotInventoryCounts() or nil
    local ok, err = false, "no_dig_fn"

    -- 1. Try native CC:Tweaked dig first
    if type(digFn) == "function" then
        ok, err = digFn()
    end

    -- 2. If native dig failed (e.g. modem is equipped or no tool on toolSide), auto-equip pickaxe and retry native dig!
    if not ok and type(digFn) == "function" then
        if self:tryEquipPickaxe() then
            ok, err = digFn()
        end
    end

    -- 3. Only fall back to automata dig if native dig is completely unavailable or pickaxe is missing
    if not ok then
        local autoOk, autoErr = self:digWithAutomata(dirName)
        if autoOk then
            ok, err = true, nil
        elseif autoErr and autoErr ~= "no_automata_dig" then
            err = autoErr
        end
    end

    if ok or (type(detectFn) == "function" and not detectFn()) then
        if isTargetOre and before then
            self:recordNewlyMinedItems(before)
        end
        return true, nil
    end

    return false, err
end

function TurtleMiner:tryDigWithToolCheck(digFn, isTargetOre)
    if digFn == (turtle and turtle.digUp) then
        return self:tryDigDirection("up", isTargetOre)
    elseif digFn == (turtle and turtle.digDown) then
        return self:tryDigDirection("down", isTargetOre)
    end
    return self:tryDigDirection("forward", isTargetOre)
end

--------------------------------------------------------------------------------
-- Dead-Reckoning Movement & Navigation
--------------------------------------------------------------------------------

function TurtleMiner:turnLeft()
    if not turtle or not turtle.turnLeft then return false end
    if turtle.turnLeft() then
        self.pos.dir = (self.pos.dir + 3) % 4
        self:savePos()
        return true
    end
    return false
end

function TurtleMiner:turnRight()
    if not turtle or not turtle.turnRight then return false end
    if turtle.turnRight() then
        self.pos.dir = (self.pos.dir + 1) % 4
        self:savePos()
        return true
    end
    return false
end

function TurtleMiner:turnTo(targetDir)
    targetDir = targetDir % 4
    local diff = (targetDir - self.pos.dir) % 4
    if diff == 1 then
        return self:turnRight()
    elseif diff == 2 then
        self:turnRight()
        return self:turnRight()
    elseif diff == 3 then
        return self:turnLeft()
    end
    return true
end

function TurtleMiner:inspectDirection(inspectFn)
    if not turtle or type(inspectFn) ~= "function" then
        return false, nil
    end
    local ok, data = inspectFn()
    if ok and type(data) == "table" then
        return true, data
    end
    return false, nil
end

function TurtleMiner:stepForward(digIfBlocked)
    if not turtle then return false end
    local vec = DIR_VECTORS[self.pos.dir] or { x = 0, z = -1 }
    local nx, ny, nz = self.pos.x + vec.x, self.pos.y, self.pos.z + vec.z
    if self:isBlocked(nx, ny, nz) then
        return false, "protected"
    end

    if not self:ensureFuel(1) then
        self.lastMoveError = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
        return false, "no_fuel"
    end

    if turtle.detect and turtle.detect() then
        local hasBlock, data = self:inspectDirection(turtle.inspect)
        if hasBlock and self:isProtectedBlock(data.name) then
            self:markBlocked(nx, ny, nz)
            return false, "protected"
        end
        if digIfBlocked then
            local digOk, digErr = self:tryDigDirection("forward")
            if not digOk and turtle.detect() then
                if type(digErr) == "string" and (digErr:lower():find("no tool", 1, true) or digErr:lower():find("without tool", 1, true)) then
                    self.lastMoveError = "No pickaxe available on turtle!"
                    return false, "no_tool"
                end
                local blkName = hasBlock and GeoScanner.shortName(data.name) or "block"
                self.lastMoveError = ("Cannot break %s (%s)"):format(blkName, tostring(digErr or "claimed chunk?"))
                return false, "unbreakable"
            end
        end
    end

    local attempts = 0
    while true do
        local moveOk, moveErr = turtle.forward()
        if moveOk then
            break
        end
        attempts = attempts + 1
        if type(moveErr) == "string" and moveErr:lower():find("fuel", 1, true) then
            if not self:ensureFuel(1) then
                self.lastMoveError = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
                return false, "no_fuel"
            end
        end
        local hasBlock, data = self:inspectDirection(turtle.inspect)
        if hasBlock and self:isProtectedBlock(data.name) then
            self:markBlocked(nx, ny, nz)
            return false, "protected"
        end
        if digIfBlocked then
            local digOk, digErr = self:tryDigDirection("forward")
            if not digOk and turtle.detect and turtle.detect() then
                if type(digErr) == "string" and (digErr:lower():find("no tool", 1, true) or digErr:lower():find("without tool", 1, true)) then
                    self.lastMoveError = "No pickaxe available on turtle!"
                    return false, "no_tool"
                end
                local blkName = hasBlock and GeoScanner.shortName(data.name) or "block"
                self.lastMoveError = ("Cannot break %s (%s)"):format(blkName, tostring(digErr or "claimed chunk?"))
                return false, "unbreakable"
            end
        end
        if attempts >= 6 then
            self.lastMoveError = tostring(moveErr or "Movement obstructed")
            return false, "blocked"
        end
        if turtle.attack then
            turtle.attack()
        end
        sleepSeconds(0.15)
    end
    self.pos.x = nx
    self.pos.z = nz
    self:savePos()
    self:placeWasteInPath("forward")
    return true
end

function TurtleMiner:stepUp(digIfBlocked)
    if not turtle then return false end
    local nx, ny, nz = self.pos.x, self.pos.y + 1, self.pos.z
    if self:isBlocked(nx, ny, nz) then
        return false, "protected"
    end

    if not self:ensureFuel(1) then
        self.lastMoveError = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
        return false, "no_fuel"
    end

    if turtle.detectUp and turtle.detectUp() then
        local hasBlock, data = self:inspectDirection(turtle.inspectUp)
        if hasBlock and self:isProtectedBlock(data.name) then
            self:markBlocked(nx, ny, nz)
            return false, "protected"
        end
        if digIfBlocked then
            local digOk, digErr = self:tryDigDirection("up")
            if not digOk and turtle.detectUp() then
                if type(digErr) == "string" and (digErr:lower():find("no tool", 1, true) or digErr:lower():find("without tool", 1, true)) then
                    self.lastMoveError = "No pickaxe available on turtle!"
                    return false, "no_tool"
                end
                local blkName = hasBlock and GeoScanner.shortName(data.name) or "block"
                self.lastMoveError = ("Cannot break %s (%s)"):format(blkName, tostring(digErr or "claimed chunk?"))
                return false, "unbreakable"
            end
        end
    end

    local attempts = 0
    while true do
        local moveOk, moveErr = turtle.up()
        if moveOk then
            break
        end
        attempts = attempts + 1
        if type(moveErr) == "string" and moveErr:lower():find("fuel", 1, true) then
            if not self:ensureFuel(1) then
                self.lastMoveError = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
                return false, "no_fuel"
            end
        end
        local hasBlock, data = self:inspectDirection(turtle.inspectUp)
        if hasBlock and self:isProtectedBlock(data.name) then
            self:markBlocked(nx, ny, nz)
            return false, "protected"
        end
        if digIfBlocked then
            local digOk, digErr = self:tryDigDirection("up")
            if not digOk and turtle.detectUp and turtle.detectUp() then
                if type(digErr) == "string" and (digErr:lower():find("no tool", 1, true) or digErr:lower():find("without tool", 1, true)) then
                    self.lastMoveError = "No pickaxe available on turtle!"
                    return false, "no_tool"
                end
                local blkName = hasBlock and GeoScanner.shortName(data.name) or "block"
                self.lastMoveError = ("Cannot break %s (%s)"):format(blkName, tostring(digErr or "claimed chunk?"))
                return false, "unbreakable"
            end
        end
        if attempts >= 6 then
            self.lastMoveError = tostring(moveErr or "Movement up obstructed")
            return false, "blocked"
        end
        if turtle.attackUp then
            turtle.attackUp()
        end
        sleepSeconds(0.15)
    end
    self.pos.y = ny
    self:savePos()
    self:placeWasteInPath("up")
    return true
end

function TurtleMiner:stepDown(digIfBlocked)
    if not turtle then return false end
    local nx, ny, nz = self.pos.x, self.pos.y - 1, self.pos.z
    if self:isBlocked(nx, ny, nz) then
        return false, "protected"
    end

    if not self:ensureFuel(1) then
        self.lastMoveError = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
        return false, "no_fuel"
    end

    if turtle.detectDown and turtle.detectDown() then
        local hasBlock, data = self:inspectDirection(turtle.inspectDown)
        if hasBlock and self:isProtectedBlock(data.name) then
            self:markBlocked(nx, ny, nz)
            return false, "protected"
        end
        if digIfBlocked then
            local digOk, digErr = self:tryDigDirection("down")
            if not digOk and turtle.detectDown() then
                if type(digErr) == "string" and (digErr:lower():find("no tool", 1, true) or digErr:lower():find("without tool", 1, true)) then
                    self.lastMoveError = "No pickaxe available on turtle!"
                    return false, "no_tool"
                end
                local blkName = hasBlock and GeoScanner.shortName(data.name) or "block"
                self.lastMoveError = ("Cannot break %s (%s)"):format(blkName, tostring(digErr or "claimed chunk?"))
                return false, "unbreakable"
            end
        end
    end

    local attempts = 0
    while true do
        local moveOk, moveErr = turtle.down()
        if moveOk then
            break
        end
        attempts = attempts + 1
        if type(moveErr) == "string" and moveErr:lower():find("fuel", 1, true) then
            if not self:ensureFuel(1) then
                self.lastMoveError = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
                return false, "no_fuel"
            end
        end
        local hasBlock, data = self:inspectDirection(turtle.inspectDown)
        if hasBlock and self:isProtectedBlock(data.name) then
            self:markBlocked(nx, ny, nz)
            return false, "protected"
        end
        if digIfBlocked then
            local digOk, digErr = self:tryDigDirection("down")
            if not digOk and turtle.detectDown and turtle.detectDown() then
                if type(digErr) == "string" and (digErr:lower():find("no tool", 1, true) or digErr:lower():find("without tool", 1, true)) then
                    self.lastMoveError = "No pickaxe available on turtle!"
                    return false, "no_tool"
                end
                local blkName = hasBlock and GeoScanner.shortName(data.name) or "block"
                self.lastMoveError = ("Cannot break %s (%s)"):format(blkName, tostring(digErr or "claimed chunk?"))
                return false, "unbreakable"
            end
        end
        if attempts >= 6 then
            self.lastMoveError = tostring(moveErr or "Movement down obstructed")
            return false, "blocked"
        end
        if turtle.attackDown then
            turtle.attackDown()
        end
        sleepSeconds(0.15)
    end
    self.pos.y = ny
    self:savePos()
    self:placeWasteInPath("down")
    return true
end

--- Find an alternative 3D path from `self.pos` to `(tx, ty, tz)` avoiding `self.blockedCoords`.
-- Prefers moving down (-Y) before horizontal movement (X/Z), and horizontal movement before up (+Y).
function TurtleMiner:findPath(tx, ty, tz, stopAdjacent)
    local sx, sy, sz = self.pos.x, self.pos.y, self.pos.z
    local startKey = coordKey(sx, sy, sz)

    local function isGoal(x, y, z)
        local d = math.abs(tx - x) + math.abs(ty - y) + math.abs(tz - z)
        if stopAdjacent then
            return d == 1
        end
        return d == 0
    end

    if isGoal(sx, sy, sz) then
        return {}
    end

    local openList = {
        { x = sx, y = sy, z = sz, g = 0, f = math.abs(tx - sx) + math.abs(ty - sy) + math.abs(tz - sz), order = 0 },
    }
    local cameFrom = {}
    local gScore = { [startKey] = 0 }
    local closed = {}
    local pushCounter = 0
    local maxIterations = 1500
    local iterations = 0

    local neighbors = {
        { dx = 0, dy = -1, dz = 0, bias = -0.002 }, -- Prefer moving down first
        { dx = 1, dy = 0, dz = 0, bias = 0 },
        { dx = -1, dy = 0, dz = 0, bias = 0 },
        { dx = 0, dy = 0, dz = 1, bias = 0 },
        { dx = 0, dy = 0, dz = -1, bias = 0 },
        { dx = 0, dy = 1, dz = 0, bias = 0.002 },   -- Move up last
    }

    while #openList > 0 and iterations < maxIterations do
        iterations = iterations + 1

        local bestIdx = 1
        for i = 2, #openList do
            if openList[i].f < openList[bestIdx].f
                or (openList[i].f == openList[bestIdx].f and openList[i].order < openList[bestIdx].order)
            then
                bestIdx = i
            end
        end
        local current = table.remove(openList, bestIdx)
        local cKey = coordKey(current.x, current.y, current.z)

        if isGoal(current.x, current.y, current.z) then
            local path = {}
            local traceKey = cKey
            local currNode = current
            while traceKey ~= startKey do
                table.insert(path, 1, { x = currNode.x, y = currNode.y, z = currNode.z })
                currNode = cameFrom[traceKey]
                if not currNode then break end
                traceKey = coordKey(currNode.x, currNode.y, currNode.z)
            end
            return path
        end

        closed[cKey] = true

        for _, nb in ipairs(neighbors) do
            local nx = current.x + nb.dx
            local ny = current.y + nb.dy
            local nz = current.z + nb.dz
            local nKey = coordKey(nx, ny, nz)

            local isTargetBlockItself = stopAdjacent and (nx == tx and ny == ty and nz == tz)
            if not closed[nKey] and not self:isBlocked(nx, ny, nz) and not isTargetBlockItself then
                local tentativeG = current.g + 1
                local prevG = gScore[nKey]
                if prevG == nil or tentativeG < prevG then
                    cameFrom[nKey] = current
                    gScore[nKey] = tentativeG
                    local h = math.abs(tx - nx) + math.abs(ty - ny) + math.abs(tz - nz)
                    pushCounter = pushCounter + 1
                    table.insert(openList, {
                        x = nx,
                        y = ny,
                        z = nz,
                        g = tentativeG,
                        f = tentativeG + h + nb.bias,
                        order = pushCounter,
                    })
                end
            end
        end
    end

    return nil
end

--- Step directly to a 1-block neighbor `(nx, ny, nz)`.
function TurtleMiner:stepToNeighbor(nx, ny, nz)
    local dx = nx - self.pos.x
    local dy = ny - self.pos.y
    local dz = nz - self.pos.z
    if dy == -1 and dx == 0 and dz == 0 then
        return self:stepDown(true)
    elseif dy == 1 and dx == 0 and dz == 0 then
        return self:stepUp(true)
    elseif dy == 0 and dx == 1 and dz == 0 then
        self:turnTo(1)
        return self:stepForward(true)
    elseif dy == 0 and dx == -1 and dz == 0 then
        self:turnTo(3)
        return self:stepForward(true)
    elseif dy == 0 and dx == 0 and dz == 1 then
        self:turnTo(2)
        return self:stepForward(true)
    elseif dy == 0 and dx == 0 and dz == -1 then
        self:turnTo(0)
        return self:stepForward(true)
    end
    return false, "invalid_neighbor"
end

local function isFatalMoveReason(reason)
    return reason == "no_fuel" or reason == "no_tool" or reason == "unbreakable"
end

--- Navigate to target coordinates `(tx, ty, tz)`.
-- Prefers moving down (-Y) before moving horizontally (X/Z) in the direction of the ore,
-- breaks blocks in the way (except forbidden base blocks and `allthemodium:teleport_pad`),
-- places waste blocks in its path, and finds an alternative path around protected blocks.
function TurtleMiner:moveTo(tx, ty, tz, stopAdjacent, respectStop)
    if self:isBlocked(tx, ty, tz) then
        return false
    end
    self.lastMoveError = nil

    while true do
        if respectStop and not self.running then
            return false
        end
        if respectStop and not self:hasCoal() then
            self.lastMoveError = "No coal in inventory!"
            return false
        end

        local dx = tx - self.pos.x
        local dy = ty - self.pos.y
        local dz = tz - self.pos.z
        local dist = math.abs(dx) + math.abs(dy) + math.abs(dz)

        if dist == 0 then
            return true
        end

        if stopAdjacent and dist == 1 then
            if dy == 1 then
                local hasBlock, data = self:inspectDirection(turtle.inspectUp)
                if hasBlock and self:isProtectedBlock(data.name) then
                    self:markBlocked(tx, ty, tz)
                    return false
                end
                local digOk, digErr = self:tryDigDirection("up", true)
                if not digOk and turtle.detectUp and turtle.detectUp() then
                    self.lastMoveError = tostring(digErr or "Cannot dig target above")
                    return false
                end
                self:placeWasteInPath("target_up")
            elseif dy == -1 then
                local hasBlock, data = self:inspectDirection(turtle.inspectDown)
                if hasBlock and self:isProtectedBlock(data.name) then
                    self:markBlocked(tx, ty, tz)
                    return false
                end
                local digOk, digErr = self:tryDigDirection("down", true)
                if not digOk and turtle.detectDown and turtle.detectDown() then
                    self.lastMoveError = tostring(digErr or "Cannot dig target below")
                    return false
                end
                self:placeWasteInPath("target_down")
            elseif dx == 1 then
                self:turnTo(1)
                local hasBlock, data = self:inspectDirection(turtle.inspect)
                if hasBlock and self:isProtectedBlock(data.name) then
                    self:markBlocked(tx, ty, tz)
                    return false
                end
                local digOk, digErr = self:tryDigDirection("forward", true)
                if not digOk and turtle.detect and turtle.detect() then
                    self.lastMoveError = tostring(digErr or "Cannot dig target")
                    return false
                end
                self:placeWasteInPath("target_forward")
            elseif dx == -1 then
                self:turnTo(3)
                local hasBlock, data = self:inspectDirection(turtle.inspect)
                if hasBlock and self:isProtectedBlock(data.name) then
                    self:markBlocked(tx, ty, tz)
                    return false
                end
                local digOk, digErr = self:tryDigDirection("forward", true)
                if not digOk and turtle.detect and turtle.detect() then
                    self.lastMoveError = tostring(digErr or "Cannot dig target")
                    return false
                end
                self:placeWasteInPath("target_forward")
            elseif dz == 1 then
                self:turnTo(2)
                local hasBlock, data = self:inspectDirection(turtle.inspect)
                if hasBlock and self:isProtectedBlock(data.name) then
                    self:markBlocked(tx, ty, tz)
                    return false
                end
                local digOk, digErr = self:tryDigDirection("forward", true)
                if not digOk and turtle.detect and turtle.detect() then
                    self.lastMoveError = tostring(digErr or "Cannot dig target")
                    return false
                end
                self:placeWasteInPath("target_forward")
            elseif dz == -1 then
                self:turnTo(0)
                local hasBlock, data = self:inspectDirection(turtle.inspect)
                if hasBlock and self:isProtectedBlock(data.name) then
                    self:markBlocked(tx, ty, tz)
                    return false
                end
                local digOk, digErr = self:tryDigDirection("forward", true)
                if not digOk and turtle.detect and turtle.detect() then
                    self.lastMoveError = tostring(digErr or "Cannot dig target")
                    return false
                end
                self:placeWasteInPath("target_forward")
            end
            return true
        end

        -- Movement priority:
        -- 1. Move DOWN first (dy < 0) before moving to the direction the ore is in
        -- 2. Move in the horizontal direction the ore is in (X, then Z)
        -- 3. Move UP (dy > 0)
        local moved = false
        local moveReason = nil

        if dy < 0 and not self:isBlocked(self.pos.x, self.pos.y - 1, self.pos.z) then
            moved, moveReason = self:stepDown(true)
            if isFatalMoveReason(moveReason) then
                return false
            end
        end

        if not moved and dx ~= 0 then
            local stepX = dx > 0 and 1 or -1
            if not self:isBlocked(self.pos.x + stepX, self.pos.y, self.pos.z) then
                self:turnTo(dx > 0 and 1 or 3)
                moved, moveReason = self:stepForward(true)
                if isFatalMoveReason(moveReason) then
                    return false
                end
            end
        end

        if not moved and dz ~= 0 then
            local stepZ = dz > 0 and 1 or -1
            if not self:isBlocked(self.pos.x, self.pos.y, self.pos.z + stepZ) then
                self:turnTo(dz > 0 and 2 or 0)
                moved, moveReason = self:stepForward(true)
                if isFatalMoveReason(moveReason) then
                    return false
                end
            end
        end

        if not moved and dy > 0 and not self:isBlocked(self.pos.x, self.pos.y + 1, self.pos.z) then
            moved, moveReason = self:stepUp(true)
            if isFatalMoveReason(moveReason) then
                return false
            end
        end

        if not moved then
            local path = self:findPath(tx, ty, tz, stopAdjacent)
            if not path or #path == 0 then
                return false
            end
            local stepOk = false
            for _, node in ipairs(path) do
                if respectStop and not self.running then
                    return false
                end
                if respectStop and not self:hasCoal() then
                    self.lastMoveError = "No coal in inventory!"
                    return false
                end
                local nOk, nReason = self:stepToNeighbor(node.x, node.y, node.z)
                if not nOk then
                    if isFatalMoveReason(nReason) then
                        return false
                    end
                    break
                end
                stepOk = true
            end
            if not stepOk then
                return false
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Teleport to Home (End Automata) + Dig-to-Home Fallback
--------------------------------------------------------------------------------

--- Return the turtle to its saved Home coordinates and ensure it is aligned with Home's direction.
-- Primary: Teleports to `"home"` using the End Automata (`warpToPoint("home")`) and aligns with `home.dir`.
-- Fallback: Only digs the way back (`moveTo`) when there is no fuel to teleport or the End Automata is broken.
function TurtleMiner:returnToHome()
    self.phase = "RETURNING HOME"
    if self.pos.y < self.home.y then
        self.lastChunkMiningY = math.min(self.lastChunkMiningY or self.pos.y, self.pos.y)
    end

    if self:isAtHome() then
        self:turnTo(self.home.dir or 0)
        self:saveHomeWarpPoint()
        self.lastAction = "At Home and aligned."
        return true, "at_home"
    end

    -- 1. Try End Automata teleport (`warpToPoint("home")`) if intact and fuel is sufficient
    local automata = self:ensureAutomata()
    if automata and type(automata.warpToPoint) == "function" and self:hasHomeWarpPoint(automata) then
        local warpCost = 1
        local pointValid = true
        if type(automata.estimateWarpCost) == "function" then
            local okCost, estCost = pcall(automata.estimateWarpCost, HOME_WARP_NAME)
            if okCost and type(estCost) == "number" then
                warpCost = estCost
            elseif okCost and estCost == nil then
                pointValid = false
            end
        end

        if pointValid then
            if warpCost > 0 then
                self:ensureFuel(warpCost)
            end
            local curFuel = (turtle and turtle.getFuelLevel) and turtle.getFuelLevel() or 0
            local enoughFuel = (curFuel == "unlimited") or (type(curFuel) == "number" and curFuel >= warpCost)

            if enoughFuel then
                if type(automata.getWarpCooldown) == "function" then
                    local cdOk, cd = pcall(automata.getWarpCooldown)
                    if cdOk and type(cd) == "number" and cd > 0 then
                        sleepSeconds(math.min(cd / 1000, 1.5))
                    end
                end

                local okWarp, warpRes, warpErr = pcall(automata.warpToPoint, HOME_WARP_NAME)
                if not (okWarp and warpRes == true) and type(warpErr) == "string" and warpErr:lower():find("cooldown", 1, true) then
                    sleepSeconds(0.6)
                    okWarp, warpRes, warpErr = pcall(automata.warpToPoint, HOME_WARP_NAME)
                end

                if okWarp and warpRes == true then
                    self.pos.x = self.home.x
                    self.pos.y = self.home.y
                    self.pos.z = self.home.z
                    self:savePos()
                    self:turnTo(self.home.dir or 0)
                    self.lastAction = "Teleported to Home and aligned."
                    return true, "teleported"
                end
            end
        end
    end

    -- 2. Fallback: Only dig to Home when there is no fuel to teleport or End Automata is broken/missing
    self.lastAction = ("Digging to Home (%d, %d, %d)..."):format(
        self.home.x, self.home.y, self.home.z
    )
    local ok = self:moveTo(self.home.x, self.home.y, self.home.z, false, false)
    if ok then
        self:turnTo(self.home.dir or 0)
        self:saveHomeWarpPoint()
        self.lastAction = "Arrived at Home and aligned (dug path)."
    else
        self.lastAction = "Blocked while digging to Home!"
    end
    return ok, "dug"
end

function TurtleMiner:isAtHome()
    return self.pos.x == self.home.x
        and self.pos.y == self.home.y
        and self.pos.z == self.home.z
end

--------------------------------------------------------------------------------
-- Chunk Boundaries & Vertical Chunk Sweep (Standalone Geo Scanner Fallback)
--------------------------------------------------------------------------------

function TurtleMiner:getChunkBounds()
    if self.home and self.home.useGps then
        local minX = math.floor(self.home.x / 16) * 16
        local maxX = minX + 15
        local minZ = math.floor(self.home.z / 16) * 16
        local maxZ = minZ + 15
        return minX, maxX, minZ, maxZ, minX + 7, minZ + 7
    end
    local r = self.scanRadius or 8
    local hx = (self.home and self.home.x) or 0
    local hz = (self.home and self.home.z) or 0
    return hx - r, hx + r, hz - r, hz + r, hx, hz
end

function TurtleMiner:isInTargetChunk(worldX, worldZ)
    local minX, maxX, minZ, maxZ = self:getChunkBounds()
    return worldX >= minX and worldX <= maxX and worldZ >= minZ and worldZ <= maxZ
end

function TurtleMiner:advanceInChunk()
    local _, _, _, _, centerX, centerZ = self:getChunkBounds()

    if self.home and self.home.useGps then
        if math.abs(self.pos.x - centerX) > 2 or math.abs(self.pos.z - centerZ) > 2 then
            self:moveTo(centerX, self.pos.y, centerZ, false, true)
            if not self.running then
                return false, "stopped"
            end
        end
    end

    local targetY = self.pos.y - self.scanRadius
    if self.lastChunkMiningY and self.lastChunkMiningY < self.pos.y then
        targetY = math.min(targetY, self.lastChunkMiningY)
    end

    local stepsToDescend = math.max(1, math.min(self.scanRadius, self.pos.y - targetY))
    local stepsMoved = 0
    local lastReason = nil

    for _ = 1, stepsToDescend do
        if not self.running then
            return stepsMoved > 0, "stopped"
        end
        local ok, reason = self:stepDown(true)
        if ok then
            stepsMoved = stepsMoved + 1
            self.lastChunkMiningY = math.min(self.lastChunkMiningY or self.pos.y, self.pos.y)
        else
            lastReason = reason
            break
        end
    end

    if stepsMoved > 0 then
        return true, nil
    end
    return false, lastReason or "blocked"
end

--------------------------------------------------------------------------------
-- Single Step of the Worker State Machine
--------------------------------------------------------------------------------

function TurtleMiner:finishStopReturnHome()
    if not self:isAtHome() then
        self:returnToHome()
    else
        self:turnTo(self.home.dir or 0)
    end
    self:unloadToBarrel()
    self.pendingReturnOnStop = false
    self.phase = "IDLE (Stopped)"
    self.lastAction = "Stopped at Home. Staying idle until 'start'..."
    self:sendStatusToBase()
    return "idle"
end

--- Return to Home, unload everything (except Energy Cube) into the Sophisticated Storage Barrel,
-- and transition to waiting only if ores remain in inventory (e.g. barrel full or manual unload).
function TurtleMiner:returnAndUnloadAtBase(reasonMsg)
    self.oreQueue = {}
    self:returnToHome()
    if not self.running then
        return self:finishStopReturnHome()
    end
    local unloaded = self:unloadToBarrel()
    self:chargeWithEnergy(1000)

    if self:hasOresInInventory() then
        self.phase = "WAITING AT HOME"
        local _, oreCount = self:getInventoryStats()
        self.lastAction = ("At Home. Waiting for %d ore(s) to be unloaded..."):format(oreCount)
        self:sendStatusToBase()
        return "waiting_unload"
    end

    self.phase = "MINING"
    if unloaded > 0 then
        self.lastAction = ("%s Stored %d slot(s) in Barrel!"):format(reasonMsg or "At Base.", unloaded)
    else
        self.lastAction = reasonMsg or "Returned to Base."
    end
    self:sendStatusToBase()
    return "returned_home"
end

--- Execute one logical step of the auto-miner state machine.
function TurtleMiner:stepWorker()
    if not self.running then
        if self.pendingReturnOnStop then
            return self:finishStopReturnHome()
        end
        self.phase = "IDLE (Stopped)"
        return "idle"
    end

    self.inWorkerStep = true

    if self:isAtHome() and not self.homeWarpSaved then
        self:saveHomeWarpPoint()
    end

    -- 1. If we are waiting for coal, stay idle at Home until coal is placed into inventory
    if self.phase == "WAITING FOR COAL" then
        if not self:hasCoal() then
            self.lastAction = "Waiting at Home: No coal in inventory. Please add coal..."
            self.inWorkerStep = false
            return "no_coal"
        else
            self.phase = "MINING"
            self.lastAction = "Coal detected in inventory! Resuming mining..."
        end
    end

    -- 2. If turtle has NO coal in inventory, immediately return to Home and wait for coal!
    if not self:hasCoal() then
        if not self:isAtHome() then
            local res = self:returnAndUnloadAtBase("No coal in inventory! Returning to Home immediately...")
            self.phase = "WAITING FOR COAL"
            self.lastAction = "No coal in inventory! Add coal to turtle at Home..."
            self.inWorkerStep = false
            return res
        else
            self:unloadToBarrel()
            self.phase = "WAITING FOR COAL"
            self.lastAction = "No coal in inventory! Add coal to turtle at Home..."
            self.inWorkerStep = false
            self:sendStatusToBase()
            return "no_coal"
        end
    end

    -- 3. If we are waiting at Home for ores to be unloaded, try unloading to the Barrel first
    if self.phase == "WAITING AT HOME" then
        self:unloadToBarrel()
        if self:hasOresInInventory() then
            local _, oreCount = self:getInventoryStats()
            self.lastAction = ("Waiting at Home: %d ore(s) still in inventory"):format(oreCount)
            self.inWorkerStep = false
            return "waiting_unload"
        else
            if self:isInventoryFull() then
                self:placeWasteBlocks()
            end
            self.phase = "MINING"
            self.lastAction = "Inventory cleared into Barrel! Resuming cycle..."
        end
    end

    -- 4. Place any waste blocks if inventory is full, then return Home & unload to Barrel if full
    self:clearWasteIfFull()
    if self:isInventoryFull() then
        local res = self:returnAndUnloadAtBase("Inventory full!")
        self.inWorkerStep = false
        return res
    end

    -- 3. Ensure fuel (charges from Energy Cube via End Automata first, then refuels)
    if not self:ensureFuel(1) then
        self.lastAction = "OUT OF FUEL (0)! Add Energy Cube or fuel to turtle"
        self.inWorkerStep = false
        self:sendStatusToBase()
        return "no_fuel"
    end

    self.phase = "MINING"

    -- 4. 2-Computer Strategy: If we have an Ender Modem (or queued ore locations from Base Computer),
    --    request ore locations from the Base Computer and mine them!
    local modem = self:ensureModem()
    if modem or #self.oreQueue > 0 then
        if #self.oreQueue == 0 then
            if not self:isAtHome() then
                self:returnToHome()
                if not self.running then
                    self.inWorkerStep = false
                    return self:finishStopReturnHome()
                end
                self:unloadToBarrel()
            end
            local okReq, reqErr = self:requestOresFromBase(3.0)
            if not self.running then
                self.inWorkerStep = false
                return self:finishStopReturnHome()
            end
            if not okReq then
                self.lastAction = tostring(reqErr or "Waiting for Base Computer...")
                self.inWorkerStep = false
                return "waiting_base"
            end
        end

        if #self.oreQueue == 0 then
            -- No ores left in the Base Computer's Geo Scanner scan!
            if not self:isAtHome() then
                self:returnToHome()
            else
                self:turnTo(self.home.dir or 0)
            end
            self:unloadToBarrel()
            self.inWorkerStep = false
            if not self.running then
                return self:finishStopReturnHome()
            end
            if self:hasOresInInventory() then
                self.phase = "WAITING AT HOME"
                local _, oreCount = self:getInventoryStats()
                self.lastAction = ("No ores left! Waiting for %d ore(s) to unload..."):format(oreCount)
                return "waiting_unload"
            end
            self.lastAction = "No ores left in scan. Waiting at Base..."
            self:sendStatusToBase()
            return "no_ores"
        end

        -- Mine the next ore location passed by the Base Computer
        self:tryEquipPickaxe()
        local mined = false
        local minedTarget = nil
        while #self.oreQueue > 0 do
            if not self:hasCoal() then
                local res = self:returnAndUnloadAtBase("No coal in inventory! Returning to Home immediately...")
                self.phase = "WAITING FOR COAL"
                self.lastAction = "No coal in inventory! Add coal to turtle at Home..."
                self.inWorkerStep = false
                return "no_coal"
            end
            local target = table.remove(self.oreQueue, 1)
            self.chunkOresRemaining = #self.oreQueue
            local refX = (target.fromHome ~= false) and self.home.x or self.pos.x
            local refY = (target.fromHome ~= false) and self.home.y or self.pos.y
            local refZ = (target.fromHome ~= false) and self.home.z or self.pos.z
            local targetX = refX + target.x
            local targetY = refY + target.y
            local targetZ = refZ + target.z

            self.lastAction = ("Mining %s at (%+d,%+d,%+d) [%d left]"):format(
                target.prettyName or "Ore", target.x, target.y, target.z, #self.oreQueue
            )
            self:sendStatusToBase()

            mined = self:moveTo(targetX, targetY, targetZ, true, true)
            if not self.running then
                self.inWorkerStep = false
                return self:finishStopReturnHome()
            end
            if not self:hasCoal() then
                local res = self:returnAndUnloadAtBase("No coal in inventory! Returning to Home immediately...")
                self.phase = "WAITING FOR COAL"
                self.lastAction = "No coal in inventory! Add coal to turtle at Home..."
                self.inWorkerStep = false
                return "no_coal"
            end
            if mined then
                minedTarget = target
                break
            end
            if self.lastMoveError then
                break
            end
        end

        self.inWorkerStep = false

        if not mined then
            if self.lastMoveError then
                self.lastAction = self.lastMoveError
            else
                self.lastAction = "Could not reach passed ore location"
            end
            self:sendStatusToBase()
            if #self.oreQueue == 0 and not self:isAtHome() then
                self:returnAndUnloadAtBase("No reachable ores left.")
            end
            return "move_blocked"
        end

        self.lastAction = ("Collected %s!"):format(minedTarget.prettyName or "Ore")

        -- Teleport back to Home & unload to Sophisticated Storage Barrel when inventory is full OR when no ores are left!
        self:clearWasteIfFull()
        if self:isInventoryFull() then
            return self:returnAndUnloadAtBase("Inventory full!")
        elseif #self.oreQueue == 0 then
            self:returnAndUnloadAtBase("All passed ores mined!")
            return "mined"
        end

        self:sendStatusToBase()
        return "mined"
    end

    -- 5. Standalone Fallback (when no Ender Modem is present and Geo Scanner is directly on the Turtle)
    local scanner = self:ensureScanner()
    if not scanner then
        self.inWorkerStep = false
        return "no_scanner"
    end

    local scannedBlocks, scanErr = scanner:scan(self.scanRadius, {
        retries = 5,
        retryDelay = 0.5,
    })

    if not self.running then
        self.inWorkerStep = false
        return self:finishStopReturnHome()
    end

    if not scannedBlocks then
        self.lastAction = "Scan wait: " .. tostring(scanErr)
        self.inWorkerStep = false
        return "scan_error"
    end

    local ores = {}
    for _, b in ipairs(scannedBlocks) do
        local wx = self.pos.x + b.x
        local wy = self.pos.y + b.y
        local wz = self.pos.z + b.z
        if self:isProtectedBlock(b.name) then
            self:markBlocked(wx, wy, wz)
        elseif GeoScanner.hasOreTag(b) and self:isInTargetChunk(wx, wz) then
            table.insert(ores, b)
        end
    end

    if #ores == 0 then
        local chunkInfo = scanner:analyzeChunk({
            retries = 5,
            retryDelay = 0.5,
        })
        if chunkInfo and type(chunkInfo.total) == "number" then
            self.chunkOresRemaining = chunkInfo.total
            if chunkInfo.total == 0 then
                if not self:isAtHome() then
                    self:returnToHome()
                else
                    self:turnTo(self.home.dir or 0)
                end
                self:unloadToBarrel()
                self.inWorkerStep = false
                if not self.running then
                    return self:finishStopReturnHome()
                end
                if self:hasOresInInventory() then
                    self.phase = "WAITING AT HOME"
                    local _, oreCount = self:getInventoryStats()
                    self.lastAction = ("Chunk mined! Waiting for %d ore(s) to unload..."):format(oreCount)
                    return "waiting_unload"
                end
                self.lastAction = "Chunk mining complete! 0 ores left in chunk."
                return "no_ores"
            end
        end

        if self.exploreCount < self.maxExploreSteps then
            self.exploreCount = self.exploreCount + 1
            local movedDown = self:advanceInChunk()
            self.inWorkerStep = false
            if not self.running then
                return self:finishStopReturnHome()
            end
            if movedDown then
                local remStr = self.chunkOresRemaining and ("%d chunk ores left"):format(self.chunkOresRemaining) or "scanning chunk"
                self.lastAction = ("Descending in chunk to Y=%d (%s)..."):format(self.pos.y, remStr)
                return "exploring"
            end
        end

        self.lastAction = "No more reachable ores in chunk."
        self.inWorkerStep = false
        return "no_ores"
    end

    self.exploreCount = 0
    local mined = false
    local minedTarget = nil

    for _, target in ipairs(ores) do
        if not self:hasCoal() then
            local res = self:returnAndUnloadAtBase("No coal in inventory! Returning to Home immediately...")
            self.phase = "WAITING FOR COAL"
            self.lastAction = "No coal in inventory! Add coal to turtle at Home..."
            self.inWorkerStep = false
            return "no_coal"
        end
        local targetX = self.pos.x + target.x
        local targetY = self.pos.y + target.y
        local targetZ = self.pos.z + target.z

        self.lastAction = ("Mining %s at (%+d,%+d,%+d)"):format(
            target.prettyName, target.x, target.y, target.z
        )

        mined = self:moveTo(targetX, targetY, targetZ, true, true)
        if not self.running then
            self.inWorkerStep = false
            return self:finishStopReturnHome()
        end
        if not self:hasCoal() then
            local res = self:returnAndUnloadAtBase("No coal in inventory! Returning to Home immediately...")
            self.phase = "WAITING FOR COAL"
            self.lastAction = "No coal in inventory! Add coal to turtle at Home..."
            self.inWorkerStep = false
            return "no_coal"
        end
        if mined then
            minedTarget = target
            if self.chunkOresRemaining and self.chunkOresRemaining > 0 then
                self.chunkOresRemaining = self.chunkOresRemaining - 1
            end
            break
        end
        if self.lastMoveError then
            break
        end
    end

    self.inWorkerStep = false

    if mined and minedTarget then
        self.lastAction = ("Collected %s!"):format(minedTarget.prettyName)
    elseif self.lastMoveError then
        self.lastAction = self.lastMoveError
        return "move_blocked"
    else
        self.lastAction = ("Could not reach %s"):format(ores[1].prettyName)
        return "move_blocked"
    end

    self:clearWasteIfFull()
    if self:isInventoryFull() then
        return self:returnAndUnloadAtBase("Inventory full!")
    end

    return "mined"
end

--------------------------------------------------------------------------------
-- TUI Display & Command Handling
--------------------------------------------------------------------------------

function TurtleMiner:drawUI()
    if not term or not term.clear then return end
    local w, h = term.getSize()
    local isColor = term.isColor and term.isColor()

    local function setCol(fg, bg)
        if isColor then
            if fg and term.setTextColor then term.setTextColor(fg) end
            if bg and term.setBackgroundColor then term.setBackgroundColor(bg) end
        end
    end

    local function line(y, text, fg, bg)
        if y < 1 or y > h then return end
        setCol(fg or colors.white, bg or colors.black)
        term.setCursorPos(1, y)
        local str = tostring(text or "")
        if #str < w then
            str = str .. string.rep(" ", w - #str)
        else
            str = str:sub(1, w)
        end
        term.write(str)
    end

    setCol(colors.white, colors.black)
    term.clear()

    line(1, " MinerHaven End Automata Miner", colors.white, isColor and colors.blue or colors.black)

    local stateColor = colors.yellow
    if self.running then
        stateColor = (self.phase == "WAITING AT HOME") and colors.orange or colors.lime
    end

    local usedSlots, oreItems = self:getInventoryStats()
    local fuel = (turtle and turtle.getFuelLevel) and tostring(turtle.getFuelLevel()) or "N/A"
    local queueStr = (#self.oreQueue > 0) and (" | Queue: %d"):format(#self.oreQueue)
        or (self.chunkOresRemaining ~= nil and (" | Ores: %d"):format(self.chunkOresRemaining) or "")

    line(2, (" State : %s"):format(self.phase), stateColor, colors.black)
    line(3, (" Home  : (%d, %d, %d) [%s]"):format(
        self.home.x, self.home.y, self.home.z, DIR_NAMES[self.home.dir or 0] or "N"
    ), colors.lightGray, colors.black)
    line(4, (" Pos   : (%d, %d, %d) [%s]  Fuel: %s"):format(
        self.pos.x, self.pos.y, self.pos.z, DIR_NAMES[self.pos.dir or 0] or "N", fuel
    ), colors.white, colors.black)
    line(5, (" Inv   : %d/16 | Mined: %d%s"):format(usedSlots, oreItems, queueStr), colors.cyan, colors.black)
    line(6, " " .. string.rep("-", math.max(1, w - 2)), colors.gray, colors.black)
    line(7, " " .. tostring(self.lastAction or ""), colors.yellow, colors.black)
    line(8, " " .. string.rep("-", math.max(1, w - 2)), colors.gray, colors.black)
    line(9, " Commands: start | stop | sethome", colors.lightGray, colors.black)
    line(10, "           return | status | shell", colors.lightGray, colors.black)
    if h >= 12 then
        line(h - 1, " [START]   [STOP]   [SETHOME]  [HOME]", colors.black, isColor and colors.lightGray or colors.white)
    end
    line(h, " > " .. self.commandBuffer .. "_", colors.white, colors.black)
end

function TurtleMiner:executeCommand(rawCmd)
    local cmd = tostring(rawCmd or ""):match("^%s*(.-)%s*$"):lower()
    if cmd == "" then
        return
    end
    if cmd == "start" or cmd == "run" or cmd == "go" or cmd == "s" then
        self:start()
    elseif cmd == "stop" or cmd == "pause" or cmd == "idle" or cmd == "p" or cmd == "t" then
        self:stop()
    elseif cmd == "sethome" or cmd:match("^sethome%s+") then
        local dirArg = cmd:match("^sethome%s+(%S+)")
        self:sethome(dirArg)
    elseif cmd == "return" or cmd == "home" then
        self:stop()
        self:returnToHome()
        self:unloadToBarrel()
        self.phase = "IDLE (At Home)"
    elseif cmd == "shell" or cmd == "exit" or cmd == "quit" then
        self.keepProgramAlive = false
    else
        self.lastAction = "Unknown cmd '" .. cmd .. "' (use: start / stop)"
    end
end

function TurtleMiner:runDaemon()
    self:ensureModem()
    self:drawUI()

    local function workerLoop()
        while self.keepProgramAlive do
            if self.running or self.pendingReturnOnStop then
                local status = self:stepWorker()
                self:drawUI()
                if status == "waiting_unload" or status == "no_ores" or status == "waiting_base" or status == "no_scanner" or status == "scan_error" or status == "no_fuel" or status == "move_blocked" then
                    sleepSeconds(1.0)
                else
                    sleepSeconds(0.2)
                end
            else
                sleepSeconds(0.3)
            end
        end
    end

    local function inputLoop()
        while self.keepProgramAlive do
            local ev, p1, p2, p3, p4 = os.pullEvent()
            local modemMsg = GeoScanner.parseModemEvent(ev, p1, p2, p3, p4)
            if modemMsg then
                self:handleModemMessage(modemMsg)
                self:drawUI()
            elseif ev == "char" then
                self.commandBuffer = self.commandBuffer .. p1
                self:drawUI()
            elseif ev == "key" then
                if p1 == (keys and keys.enter or 28) then
                    local cmd = self.commandBuffer
                    self.commandBuffer = ""
                    self:executeCommand(cmd)
                    self:drawUI()
                elseif p1 == (keys and keys.backspace or 14) then
                    if #self.commandBuffer > 0 then
                        self.commandBuffer = self.commandBuffer:sub(1, -2)
                        self:drawUI()
                    end
                end
            elseif ev == "mouse_click" and term then
                local _, h = term.getSize()
                if p3 == h - 1 then
                    if p2 >= 2 and p2 <= 8 then
                        self:start()
                    elseif p2 >= 12 and p2 <= 17 then
                        self:stop()
                    elseif p2 >= 21 and p2 <= 29 then
                        self:sethome()
                    elseif p2 >= 32 and p2 <= 37 then
                        self:executeCommand("return")
                    end
                    self:drawUI()
                end
            elseif ev == "minerhaven_command" then
                self:executeCommand(p1)
                self:drawUI()
            elseif ev == "inventory" or ev == "turtle_inventory" then
                self:drawUI()
            end
        end
    end

    if parallel and type(parallel.waitForAny) == "function" then
        parallel.waitForAny(workerLoop, inputLoop)
    else
        local coWorker = coroutine.create(workerLoop)
        local coInput = coroutine.create(inputLoop)
        coroutine.resume(coWorker)
        coroutine.resume(coInput)
        while self.keepProgramAlive
            and coroutine.status(coWorker) ~= "dead"
            and coroutine.status(coInput) ~= "dead"
        do
            local ev = { os.pullEvent() }
            coroutine.resume(coInput, unpack(ev))
            coroutine.resume(coWorker, unpack(ev))
        end
    end

    if term and term.clear then
        if term.isColor and term.isColor() then
            term.setTextColor(colors.white)
            term.setBackgroundColor(colors.black)
        end
        term.clear()
        term.setCursorPos(1, 1)
    end
end

--------------------------------------------------------------------------------
-- CLI / Module Entry Point
--------------------------------------------------------------------------------

local args = { ... }

-- Allow `require("turtle_miner")` in tests or other scripts
if #args == 1 and args[1] == "turtle_miner" and package and package.loaded then
    return TurtleMiner
end

local miner = TurtleMiner.new()

if #args > 0 then
    local sub = tostring(args[1]):lower()
    if sub == "start" then
        miner:start()
        if os and os.queueEvent then
            os.queueEvent("minerhaven_command", "start")
        end
        print("[MinerHaven] Turtle Miner STARTED.")
        if args[2] == "--bg" or args[2] == "--signal-only" then
            return TurtleMiner
        end
        miner:runDaemon()
        return TurtleMiner
    elseif sub == "stop" then
        miner:stop()
        if os and os.queueEvent then
            os.queueEvent("minerhaven_command", "stop")
        end
        print("[MinerHaven] Turtle Miner STOPPED (idle).")
        if args[2] == "--bg" or args[2] == "--signal-only" then
            return TurtleMiner
        end
        miner:runDaemon()
        return TurtleMiner
    elseif sub == "sethome" then
        local h = miner:sethome(args[2])
        if os and os.queueEvent then
            os.queueEvent("minerhaven_command", args[2] and ("sethome " .. tostring(args[2])) or "sethome")
        end
        print(("[MinerHaven] Turtle Home set to current block in %s: (%d, %d, %d) Facing %s"):format(
            HOME_FILE, h.x, h.y, h.z, DIR_NAMES[h.dir or 0] or "N"
        ))
        return TurtleMiner
    elseif sub == "status" then
        local usedSlots, oreItems = miner:getInventoryStats()
        print("MinerHaven Turtle Status: " .. (miner.running and "RUNNING" or "STOPPED (Idle)"))
        print(("Home: (%d, %d, %d) Facing %s"):format(
            miner.home.x, miner.home.y, miner.home.z, DIR_NAMES[miner.home.dir or 0] or "N"
        ))
        print(("Pos : (%d, %d, %d) Facing %s"):format(
            miner.pos.x, miner.pos.y, miner.pos.z, DIR_NAMES[miner.pos.dir or 0] or "N"
        ))
        print(("Inventory: %d/16 slots (%d ores)"):format(usedSlots, oreItems))
        return TurtleMiner
    elseif sub == "help" or sub == "-h" or sub == "--help" then
        print("MinerHaven End Automata Auto-Miner")
        print("Usage:")
        print("  miner                  Run interactive startup daemon")
        print("  miner start            Start mining ores from Base Computer")
        print("  miner stop             Stop mining, return Home, and stay idle")
        print("  miner sethome [n/e/s/w] Save current location & warp point as Home")
        print("  miner status           Show current status and home")
        return TurtleMiner
    end
end

miner:runDaemon()
return TurtleMiner
