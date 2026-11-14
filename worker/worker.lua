--- worker/worker.lua - Headless Mining Worker for MinerHaven
-- Remote-commanded by Base Controller over encrypted Workernet.
-- Features End Automata teleportation, native pickaxe auto-equip, fuel stack retention (64),
-- emergency return on 0 coal, waste placement, and Sophisticated Storage barrel unloading.

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Workernet = loadFile("lib/workernet/main.lua")
local Device = loadFile("worker/lib/device/main.lua")

local Worker = {}
Worker.__index = Worker

local HOME_FILE = "worker/home.cfg"
local POS_FILE = "worker/pos.cfg"
local HOME_WARP_NAME = "home"

local AUTOMATA_TYPES = {
    "endAutomata",
    "end_automata",
    "overpoweredEndAutomata",
    "overpowered_end_automata",
    "weakAutomata",
    "weak_automata",
}

local PROTECTED_BLOCKS = {
    ["allthemodium:teleport_pad"] = true,
    ["minecraft:bedrock"] = true,
}

local DIR_NAMES = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
local DIR_VECTORS = {
    [0] = { x = 0, z = -1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = 1 },
    [3] = { x = -1, z = 0 },
}

local function coordKey(x, y, z)
    return string.format("%d,%d,%d", math.floor(x or 0), math.floor(y or 0), math.floor(z or 0))
end

local function combinePath(base, rel)
    if fs and fs.combine then return fs.combine(base, rel) end
    if not base or base == "" then return rel:gsub("^/+", "") end
    return (base:gsub("/+$", "") .. "/" .. rel:gsub("^/+", ""))
end

local function getDirPath(path)
    if fs and fs.getDir then return fs.getDir(path) end
    return path:match("^(.-)/[^/]+$") or ""
end

local function copyFile(src, dest)
    if fs and fs.copy then
        return pcall(fs.copy, src, dest)
    end
    local fIn = fs.open(src, "r")
    if not fIn then return false end
    local data = fIn.readAll()
    fIn.close()
    local fOut = fs.open(dest, "w")
    if not fOut then return false end
    fOut.write(data)
    fOut.close()
    return true
end

function Worker.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Worker)

    local isPaired, pCfg = Device.isPaired()
    self.pairingConfig = pCfg or {}
    self.controllerId = self.pairingConfig.controller_id

    self.net = Workernet.new()
    if self.controllerId and self.pairingConfig.session_key then
        self.net:setSessionKey(self.controllerId, self.pairingConfig.session_key)
    end

    self.running = false
    self.phase = "IDLE (Remote)"
    self.lastAction = "Waiting for Controller commands..."

    self.home = { x = 0, y = 0, z = 0, dir = 0 }
    self.pos = { x = 0, y = 0, z = 0, dir = 0 }

    self.oreQueue = {}
    self.blockedCoords = {}
    self.openedSpaces = {}
    self.minedItems = {}
    self.energyItems = {
        ["mekanism:basic_energy_cube"] = true,
        ["mekanism:advanced_energy_cube"] = true,
        ["mekanism:elite_energy_cube"] = true,
        ["mekanism:ultimate_energy_cube"] = true,
    }

    self.automata = nil
    self.automataSide = nil
    self.scanner = nil
    self.pickaxeSide = nil

    self:loadSavedData()
    return self
end

function Worker:loadSavedData()
    if fs.exists(HOME_FILE) then
        local f = fs.open(HOME_FILE, "r")
        if f then
            local data = Workernet.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then self.home = data end
        end
    end
    if fs.exists(POS_FILE) then
        local f = fs.open(POS_FILE, "r")
        if f then
            local data = Workernet.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then self.pos = data end
        end
    end
end

function Worker:savePos()
    local f = fs.open(POS_FILE, "w")
    if f then
        f.write(Workernet.serialize(self.pos))
        f.close()
    end
end

function Worker:saveHome()
    local f = fs.open(HOME_FILE, "w")
    if f then
        f.write(Workernet.serialize(self.home))
        f.close()
    end
end

--------------------------------------------------------------------------------
-- Headless UI Rendering (Live Status Display, No local controls)
--------------------------------------------------------------------------------

function Worker:renderHeadlessUI()
    if not term then return end
    term.clear()
    local w, h = term.getSize()

    local function pText(x, y, text, fg)
        if term.setTextColor and fg and colors then pcall(term.setTextColor, fg) end
        term.setCursorPos(x, y)
        term.write(text)
    end

    -- Title Bar
    pText(1, 1, string.rep("=", w), colors and colors.cyan or 512)
    pText(2, 2, "MinerHaven Worker [HEADLESS]", colors and colors.yellow or 16)
    pText(1, 3, string.rep("=", w), colors and colors.cyan or 512)

    -- Status details
    pText(2, 5, "Worker ID    : " .. tostring(self.net.localId), colors and colors.white or 1)
    pText(2, 6, "Controller ID: " .. tostring(self.controllerId or "UNPAIRED"), colors and colors.lightBlue or 8)

    local phaseFg = self.running and (colors and colors.green or 8192) or (colors and colors.red or 16384)
    pText(2, 8, "Status       : " .. tostring(self.phase), phaseFg)

    local dirStr = DIR_NAMES[self.pos.dir or 0] or "N"
    pText(2, 9, string.format("Position     : (%+d, %+d, %+d) [%s]", self.pos.x, self.pos.y, self.pos.z, dirStr), colors and colors.white or 1)

    local fuel = turtle and turtle.getFuelLevel and turtle.getFuelLevel() or 0
    local coal = self:getCoalCount()
    pText(2, 10, string.format("Fuel / Coal  : %s / %d coal", tostring(fuel), coal), colors and colors.yellow or 16)

    local usedSlots = self:getUsedSlotCount()
    pText(2, 11, string.format("Inventory    : %d/16 slots | Ores queued: %d", usedSlots, #self.oreQueue), colors and colors.white or 1)

    pText(2, 13, "Activity:", colors and colors.lightBlue or 8)
    local act = self.lastAction or "Idle"
    if #act > w - 3 then act = act:sub(1, w - 6) .. "..." end
    pText(2, 14, act, colors and colors.gray or 128)

    -- Remote-controlled banner
    pText(1, h, "[REMOTE-CONTROLLED BY CONTROLLER]", colors and colors.cyan or 512)
end

--------------------------------------------------------------------------------
-- Hardware & Peripheral Detection
--------------------------------------------------------------------------------

function Worker:findAutomata()
    if not peripheral then return nil end
    for _, t in ipairs(AUTOMATA_TYPES) do
        local p = peripheral.find(t)
        if p then
            for _, side in ipairs(peripheral.getNames()) do
                if peripheral.getType(side) == t then
                    return p, side
                end
            end
            return p, "unknown"
        end
    end
    return nil
end

function Worker:ensureAutomata()
    if self.automata then return self.automata, self.automataSide end
    local a, side = self:findAutomata()
    if a then
        self.automata = a
        self.automataSide = side
        return a, side
    end
    return nil
end

function Worker:isSenderController(fromId)
    if not self.controllerId or not fromId then return false end
    return (fromId == self.controllerId)
        or (tonumber(fromId) and tonumber(fromId) == tonumber(self.controllerId))
        or (tostring(fromId) == tostring(self.controllerId))
end

function Worker:selectToolSlot()
    if not turtle or not turtle.getItemDetail then return end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name then
            local lower = detail.name:lower()
            if lower:find("pickaxe", 1, true) or lower:find("drill", 1, true) then
                turtle.select(slot)
                return slot
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Inventory, Coal Fuel Stack (64) & Barrel Management
--------------------------------------------------------------------------------

function Worker:getUsedSlotCount()
    if not turtle or not turtle.getItemCount then return 0 end
    local count = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then count = count + 1 end
    end
    return count
end

function Worker:isInventoryFull()
    return self:getUsedSlotCount() >= 16
end

function Worker:isCoalItem(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then return false end
    local name = detail.name:lower()
    return name:find("coal", 1, true) or name:find("charcoal", 1, true)
end

function Worker:getCoalCount()
    if not turtle or not turtle.getItemDetail then return 0 end
    local total = 0
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and self:isCoalItem(detail) then
            total = total + (detail.count or 0)
        end
    end
    return total
end

function Worker:hasCoal()
    return self:getCoalCount() > 0
end

function Worker:isEnergyItem(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then return false end
    local name = detail.name:lower()
    if self.energyItems[name] then return true end
    if name:find("_ore", 1, true) then return false end
    return name:find("energy", 1, true)
        or name:find("battery", 1, true)
        or name:find("capacitor", 1, true)
        or name:find("flux_", 1, true)
        or name:find("_cell", 1, true)
        or name:find("energy_tablet", 1, true)
        or name:find("energy_cube", 1, true)
        or name:find("power_cell", 1, true)
end

function Worker.isStorageBarrel(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    return lower:match("^sophisticatedstorage:")
        or lower:find("barrel", 1, true)
        or lower:find("chest", 1, true)
end

function Worker:shouldKeepInInventory(detail)
    if not detail or not detail.name then return false end
    local name = detail.name:lower()
    if self:isEnergyItem(detail) then return true end
    if name:find("pickaxe", 1, true) or name:find("drill", 1, true) then return true end
    if name:find("modem", 1, true) or name:find("scanner", 1, true) then return true end
    return false
end

--- Unload mined ores to the Sophisticated Storage barrel at Home,
-- keeping Energy Cubes and retaining up to 64 fuel items (coal).
function Worker:unloadToBarrel()
    if not turtle or not turtle.getItemCount then return 0 end
    self:turnTo(self.home.dir or 0)

    -- Locate barrel
    local dropFn = nil
    local hasF, fData = turtle.inspect()
    if hasF and Worker.isStorageBarrel(fData.name) then
        dropFn = turtle.drop
    else
        local hasU, uData = turtle.inspectUp()
        if hasU and Worker.isStorageBarrel(uData.name) then
            dropFn = turtle.dropUp
        else
            local hasD, dData = turtle.inspectDown()
            if hasD and Worker.isStorageBarrel(dData.name) then
                dropFn = turtle.dropDown
            else
                -- Try sides
                local baseDir = self.home.dir or 0
                for _, d in ipairs({ (baseDir + 1) % 4, (baseDir + 3) % 4, (baseDir + 2) % 4 }) do
                    self:turnTo(d)
                    local okB, bData = turtle.inspect()
                    if okB and Worker.isStorageBarrel(bData.name) then
                        dropFn = turtle.drop
                        break
                    end
                end
                if not dropFn then self:turnTo(baseDir) end
            end
        end
    end

    if not dropFn then
        dropFn = turtle.drop or turtle.dropDown
    end

    local unloadedSlots = 0
    local keptFuelCounts = {}

    for slot = 1, 16 do
        local count = turtle.getItemCount(slot) or 0
        if count > 0 then
            local detail = turtle.getItemDetail(slot, true)
            if self:shouldKeepInInventory(detail) then
                -- Always kept (Energy Cube, tools)
            elseif detail and (self:isCoalItem(detail) or turtle.refuel(0)) then
                local fuelKey = detail.name:lower()
                local alreadyKept = keptFuelCounts[fuelKey] or 0
                local needed = math.max(0, 64 - alreadyKept)
                if count <= needed then
                    keptFuelCounts[fuelKey] = alreadyKept + count
                else
                    keptFuelCounts[fuelKey] = alreadyKept + needed
                    local toDrop = count - needed
                    if toDrop > 0 then
                        turtle.select(slot)
                        if dropFn(toDrop) then unloadedSlots = unloadedSlots + 1 end
                    end
                end
            else
                -- Mined ore or regular block: dump entire slot
                turtle.select(slot)
                if dropFn() then unloadedSlots = unloadedSlots + 1 end
            end
        end
    end

    turtle.select(1)
    self:turnTo(self.home.dir or 0)
    return unloadedSlots
end

--------------------------------------------------------------------------------
-- Movement, Pickaxe Digging & Waste Placement
--------------------------------------------------------------------------------

function Worker:markBlocked(x, y, z)
    self.blockedCoords[coordKey(x, y, z)] = true
end

function Worker:isBlocked(x, y, z)
    return self.blockedCoords[coordKey(x, y, z)] == true
end

function Worker:isProtectedBlock(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if PROTECTED_BLOCKS[lower] then return true end
    return lower:match("^computercraft:")
        or lower:match("^advancedperipherals:")
        or lower:match("^sophisticatedstorage:")
        or lower:match("^fluxnetworks:")
        or lower:find("teleport_pad", 1, true)
        or lower:find("energy_cube", 1, true)
        or lower:find("wireless_modem", 1, true)
        or lower:find("wired_modem", 1, true)
        or lower:find("geo_scanner", 1, true)
end

function Worker:isWasteName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if self:isEnergyItem({ name = lower }) then return false end
    local short = lower:match("^[^:]+:(.+)$") or lower
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
        or short:match("_dirt$")
        or short:match("_cobblestone$")
        or short:match("^cobbled_")
        or short:match("_grass$")
        or short:match("_stone$")
end

function Worker:selectWasteBlock()
    if not turtle or not turtle.getItemDetail then return false end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name and self:isWasteName(detail.name) and not self:isCoalItem(detail) then
            turtle.select(slot)
            return true
        end
    end
    return false
end

function Worker:fillOpenedSpaceBehind(prevX, prevY, prevZ, moveType)
    if not turtle then return false end
    if not prevX or not prevY or not prevZ then return false end

    local key = coordKey(prevX, prevY, prevZ)
    -- Only fill space that was explicitly opened by the turtle's dig path!
    if not self.openedSpaces or not self.openedSpaces[key] then
        return false
    end

    -- Never fill base / home coordinate (0,0,0) or configured home
    if (prevX == 0 and prevY == 0 and prevZ == 0) or
       (prevX == self.home.x and prevY == self.home.y and prevZ == self.home.z) then
        self.openedSpaces[key] = nil
        return false
    end

    if not self:selectWasteBlock() then
        return false
    end

    local placed = false
    if moveType == "forward" then
        -- Turned around to fill the vacated space behind
        if turtle.turnRight and turtle.place then
            self:turnRight()
            self:turnRight()
            placed = turtle.place()
            self:turnRight()
            self:turnRight()
        end
    elseif moveType == "up" then
        -- Moved up (+Y), vacated space is directly below (-Y)
        if turtle.placeDown then
            placed = turtle.placeDown()
        end
    elseif moveType == "down" then
        -- Moved down (-Y), vacated space is directly above (+Y)
        if turtle.placeUp then
            placed = turtle.placeUp()
        end
    end

    if turtle.select then turtle.select(1) end
    if placed then
        self.openedSpaces[key] = nil
        return true
    end
    return false
end

function Worker:placeWasteBehind()
    return false
end

function Worker:turnLeft()
    if turtle and turtle.turnLeft and turtle.turnLeft() then
        self.pos.dir = (self.pos.dir + 3) % 4
        self:savePos()
        return true
    end
    return false
end

function Worker:turnRight()
    if turtle and turtle.turnRight and turtle.turnRight() then
        self.pos.dir = (self.pos.dir + 1) % 4
        self:savePos()
        return true
    end
    return false
end

function Worker:turnTo(targetDir)
    targetDir = targetDir % 4
    local diff = (targetDir - self.pos.dir) % 4
    if diff == 1 then
        self:turnRight()
    elseif diff == 2 then
        self:turnRight()
        self:turnRight()
    elseif diff == 3 then
        self:turnLeft()
    end
    return self.pos.dir == targetDir
end

function Worker:digBlock(dirStr)
    local detectFn = (dirStr == "up" and turtle.detectUp) or (dirStr == "down" and turtle.detectDown) or turtle.detect
    local suckFn = (dirStr == "up" and turtle.suckUp) or (dirStr == "down" and turtle.suckDown) or turtle.suck
    local inspectFn = (dirStr == "up" and turtle.inspectUp) or (dirStr == "down" and turtle.inspectDown) or turtle.inspect

    -- Target block coordinate
    local bx, by, bz = self.pos.x, self.pos.y, self.pos.z
    if dirStr == "up" then
        by = by + 1
    elseif dirStr == "down" then
        by = by - 1
    else
        local vec = DIR_VECTORS[self.pos.dir or 0] or { x = 0, z = -1 }
        bx = bx + vec.x
        bz = bz + vec.z
    end

    -- If no block is present in that direction, nothing to dig!
    if detectFn and not detectFn() then
        return true
    end

    -- Protection check: NEVER break base blocks!
    if inspectFn then
        local hasB, bData = inspectFn()
        if hasB and self:isProtectedBlock(bData.name) then
            return false, "protected_block"
        end
    end

    -- Helper to record opened space on successful destruction of a solid block
    local function recordOpenedSpace()
        if self.openedSpaces then
            self.openedSpaces[coordKey(bx, by, bz)] = true
        end
    end

    -- 1. Try native CC dig if turtle tool happens to be available
    local nativeDigFn = (dirStr == "up" and turtle.digUp) or (dirStr == "down" and turtle.digDown) or turtle.dig
    if nativeDigFn then
        local ok = nativeDigFn()
        if ok or (detectFn and not detectFn()) then
            recordOpenedSpace()
            if suckFn then pcall(suckFn) end
            return true
        end
    end

    -- 2. Use End Automata digBlock
    local automata = self:ensureAutomata()
    if not automata or type(automata.digBlock) ~= "function" then
        return false, "no_automata"
    end

    local rotOpts = { yaw = 0, pitch = 0 }
    if dirStr == "up" then
        rotOpts = { yaw = 0, pitch = -90 }
    elseif dirStr == "down" then
        rotOpts = { yaw = 0, pitch = 90 }
    end

    local prevSlot = turtle and turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    self:selectToolSlot()

    local maxTries = 8
    for _ = 1, maxTries do
        -- Handle End Automata dig cooldown
        if type(automata.getDigCooldown) == "function" then
            local cdOk, cd = pcall(automata.getDigCooldown)
            if cdOk and type(cd) == "number" and cd > 0 then
                if os.sleep then os.sleep(math.min(cd / 1000, 0.4)) end
            end
        end

        local ok, res = pcall(automata.digBlock, rotOpts)

        -- Collect dropped items
        if type(automata.collectItems) == "function" then
            pcall(automata.collectItems)
        end
        if suckFn then
            pcall(suckFn)
        end

        -- Check if block was destroyed (handles AP 0.8.2a awardStat NPE where block was destroyed before exception)
        if detectFn and not detectFn() then
            recordOpenedSpace()
            if turtle and turtle.select then turtle.select(prevSlot) end
            return true
        end

        if ok and res == true then
            recordOpenedSpace()
            if turtle and turtle.select then turtle.select(prevSlot) end
            return true
        end

        local errStr = tostring(res or "")
        if errStr:lower():find("cooldown") then
            if os.sleep then os.sleep(0.3) end
        elseif errStr:find("Java exception", 1, true) or errStr:find("NullPointerException", 1, true) then
            -- In AP 0.8.2a, awardStat throws NPE if holding a tool that awards stats;
            -- switch to an empty slot or non-tool slot to break it
            for s = 1, 16 do
                if turtle.getItemCount(s) == 0 then
                    turtle.select(s)
                    break
                end
            end
            if os.sleep then os.sleep(0.1) end
        else
            if os.sleep then os.sleep(0.1) end
        end
    end

    if turtle and turtle.select then turtle.select(prevSlot) end
    if detectFn and not detectFn() then
        recordOpenedSpace()
        return true
    end
    return false
end

function Worker:moveForward()
    self:refuelIfNeeded()
    local vec = DIR_VECTORS[self.pos.dir or 0] or { x = 0, z = -1 }
    local prevX, prevY, prevZ = self.pos.x, self.pos.y, self.pos.z
    local nx, ny, nz = prevX + vec.x, prevY, prevZ + vec.z

    if self:isBlocked(nx, ny, nz) then return false, "blocked_coordinate" end

    if turtle.detect and turtle.detect() then
        local ok, err = self:digBlock("forward")
        if not ok then return false, err end
    end

    if turtle.forward() then
        self.pos.x, self.pos.z = nx, nz
        self:savePos()
        self:fillOpenedSpaceBehind(prevX, prevY, prevZ, "forward")
        return true
    end

    -- If forward failed, retry dig (e.g. fallen sand/gravel)
    if turtle.detect and turtle.detect() then
        self:digBlock("forward")
        if turtle.forward() then
            self.pos.x, self.pos.z = nx, nz
            self:savePos()
            self:fillOpenedSpaceBehind(prevX, prevY, prevZ, "forward")
            return true
        end
    end
    return false
end

function Worker:moveDown()
    self:refuelIfNeeded()
    local prevX, prevY, prevZ = self.pos.x, self.pos.y, self.pos.z
    local nx, ny, nz = prevX, prevY - 1, prevZ
    if self:isBlocked(nx, ny, nz) then return false, "blocked_coordinate" end

    if turtle.detectDown and turtle.detectDown() then
        local ok, err = self:digBlock("down")
        if not ok then return false, err end
    end

    if turtle.down() then
        self.pos.y = ny
        self:savePos()
        self:fillOpenedSpaceBehind(prevX, prevY, prevZ, "down")
        return true
    end

    if turtle.detectDown and turtle.detectDown() then
        self:digBlock("down")
        if turtle.down() then
            self.pos.y = ny
            self:savePos()
            self:fillOpenedSpaceBehind(prevX, prevY, prevZ, "down")
            return true
        end
    end
    return false
end

function Worker:moveUp()
    self:refuelIfNeeded()
    local prevX, prevY, prevZ = self.pos.x, self.pos.y, self.pos.z
    local nx, ny, nz = prevX, prevY + 1, prevZ
    if self:isBlocked(nx, ny, nz) then return false, "blocked_coordinate" end

    if turtle.detectUp and turtle.detectUp() then
        local ok, err = self:digBlock("up")
        if not ok then return false, err end
    end

    if turtle.up() then
        self.pos.y = ny
        self:savePos()
        self:fillOpenedSpaceBehind(prevX, prevY, prevZ, "up")
        return true
    end

    if turtle.detectUp and turtle.detectUp() then
        self:digBlock("up")
        if turtle.up() then
            self.pos.y = ny
            self:savePos()
            self:fillOpenedSpaceBehind(prevX, prevY, prevZ, "up")
            return true
        end
    end
    return false
end

function Worker:refuelTo(targetFuel)
    if not turtle or not turtle.getFuelLevel then return end
    if turtle.getFuelLevel() == "unlimited" then return end
    targetFuel = targetFuel or 500

    while turtle.getFuelLevel() < targetFuel do
        local refueledAny = false
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail and self:isCoalItem(detail) then
                turtle.select(slot)
                local curFuel = turtle.getFuelLevel()
                local needed = math.ceil((targetFuel - curFuel) / 80)
                local toConsume = math.max(1, math.min(needed, detail.count or 1))
                if turtle.refuel(toConsume) then
                    refueledAny = true
                    if turtle.getFuelLevel() >= targetFuel then break end
                end
            end
        end
        if not refueledAny then break end
    end
    turtle.select(1)
end

function Worker:refuelIfNeeded()
    if not turtle or not turtle.getFuelLevel then return end
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() < 300 then
        self:refuelTo(500)
    end
end

---------------------------------------------------------------------------------
-- End Automata Home Teleport & Fallback Pathfinding
---------------------------------------------------------------------------------

function Worker:saveHomeWarpPoint()
    local automata = self:ensureAutomata()
    if automata and automata.savePoint then
        if automata.deletePoint then
            pcall(automata.deletePoint, HOME_WARP_NAME)
        end
        local ok, res, err = pcall(automata.savePoint, HOME_WARP_NAME)
        if ok and res == true then
            return true
        end
        return false, err or res
    end
    return false, "no_automata"
end

function Worker:teleportHome()
    local automata = self:ensureAutomata()
    if not automata or not automata.warpToPoint then
        return false, "no_automata"
    end

    -- 1. Ensure sufficient fuel for warping
    self:refuelIfNeeded()
    if automata.estimateWarpCost then
        local costOk, cost = pcall(automata.estimateWarpCost, HOME_WARP_NAME)
        if costOk and type(cost) == "number" then
            local curFuel = turtle and turtle.getFuelLevel and turtle.getFuelLevel() or 0
            if curFuel < cost then
                self:refuelTo(cost + 50)
            end
        end
    end

    -- 2. Check warp cooldown
    if automata.getWarpCooldown then
        local cdOk, cd = pcall(automata.getWarpCooldown)
        if cdOk and type(cd) == "number" and cd > 0 then
            self.lastAction = string.format("Warp cooldown (%.1fs). Waiting...", cd)
            self:renderHeadlessUI()
            if os.sleep then os.sleep(cd + 0.1) end
        end
    end

    -- 3. Execute warp
    local ok, res, resMsg = pcall(automata.warpToPoint, HOME_WARP_NAME)
    if ok and res == true then
        self.pos.x = self.home.x
        self.pos.y = self.home.y
        self.pos.z = self.home.z
        self:savePos()
        self:turnTo(self.home.dir or 0)
        return true
    end

    local errMsg = (ok and res == nil and resMsg) or (not ok and res) or res or "unknown_warp_error"
    return false, tostring(errMsg)
end

function Worker:returnToHome()
    self.phase = "RETURNING HOME"
    self.lastAction = "Attempting End Automata warp to Home..."
    self:renderHeadlessUI()
    self:sendTelemetry()

    local warped, err = self:teleportHome()
    if warped then
        self.lastAction = "Warped home via End Automata!"
        self:renderHeadlessUI()
        self:sendTelemetry()
        return true
    end

    -- Fallback: dig way back home if automata warp failed
    self.lastAction = string.format("Automata warp failed (%s). Digging back home...", tostring(err))
    self:renderHeadlessUI()
    self:sendTelemetry()

    -- 1. Y movement (up to home.y)
    while self.pos.y < self.home.y do
        if not self:moveUp() then break end
    end
    while self.pos.y > self.home.y do
        if not self:moveDown() then break end
    end

    -- 2. X movement
    if self.pos.x < self.home.x then
        self:turnTo(1) -- East (+X)
        while self.pos.x < self.home.x do
            if not self:moveForward() then break end
        end
    elseif self.pos.x > self.home.x then
        self:turnTo(3) -- West (-X)
        while self.pos.x > self.home.x do
            if not self:moveForward() then break end
        end
    end

    -- 3. Z movement
    if self.pos.z < self.home.z then
        self:turnTo(2) -- South (+Z)
        while self.pos.z < self.home.z do
            if not self:moveForward() then break end
        end
    elseif self.pos.z > self.home.z then
        self:turnTo(0) -- North (-Z)
        while self.pos.z > self.home.z do
            if not self:moveForward() then break end
        end
    end

    self:turnTo(self.home.dir or 0)
    return (self.pos.x == self.home.x and self.pos.y == self.home.y and self.pos.z == self.home.z)
end

--------------------------------------------------------------------------------
-- Encrypted Communications with Paired Controller
--------------------------------------------------------------------------------

function Worker:queryStateFromController()
    if not self.controllerId then return false end
    local fuel = turtle and turtle.getFuelLevel and turtle.getFuelLevel() or 0
    local payload = {
        type = "state_query",
        workerId = os.getComputerID and os.getComputerID() or 0,
        phase = self.phase,
        running = self.running,
        x = self.pos.x,
        y = self.pos.y,
        z = self.pos.z,
        dir = self.pos.dir,
        fuel = fuel,
        coal = self:getCoalCount(),
        usedSlots = self:getUsedSlotCount(),
        lastAction = self.lastAction,
        currentTarget = self.currentTarget,
        hasOres = (#self.oreQueue > 0),
        oreCount = #self.oreQueue,
    }
    return self.net:send(self.controllerId, payload)
end

function Worker:sendTelemetry()
    return self:queryStateFromController()
end

function Worker:handleStateResponse(payload)
    if not payload or type(payload) ~= "table" then return end
    local desired = payload.desiredState
    if not desired and payload.running ~= nil then
        desired = payload.running and "MINING" or "STOPPED"
    end

    if payload.scanRadius and self.lastScanRadius ~= payload.scanRadius then
        self.lastScanRadius = payload.scanRadius
    end

    if desired == "MINING" then
        if not self.running then
            if self:hasCoal() then
                self.running = true
                self.phase = "MINING"
                self.lastAction = "State synchronized: MINING (Controller)"
                self:renderHeadlessUI()
                if #self.oreQueue == 0 then
                    self:requestOresFromController()
                end
            else
                self.phase = "IDLE (Needs Coal)"
                self.lastAction = "Controller requested MINING but turtle has no coal."
                self:renderHeadlessUI()
            end
        end
    elseif desired == "STOPPED" or desired == "IDLE" then
        if self.running then
            self.running = false
            self.oreQueue = {}
            self.phase = "STOPPED"
            self.lastAction = "State synchronized: STOPPED by Controller. Teleporting home..."
            self:renderHeadlessUI()
            self:returnToHome()
            self:unloadToBarrel()
            self.phase = "IDLE (Remote)"
            self.lastAction = "Stopped at Base by Controller."
            self:renderHeadlessUI()
        end
    elseif desired == "RETURN_HOME" then
        if self.running or self.pos.x ~= self.home.x or self.pos.y ~= self.home.y or self.pos.z ~= self.home.z then
            self.running = false
            self.oreQueue = {}
            self.phase = "RETURNING HOME"
            self.lastAction = "Returning home by Controller sync..."
            self:renderHeadlessUI()
            self:returnToHome()
            self:unloadToBarrel()
            self.phase = "IDLE (Remote)"
            self.lastAction = "Returned Home by Controller."
            self:renderHeadlessUI()
        end
    end
end

function Worker:requestOresFromController()
    if not self.controllerId then return false end
    self.phase = "WAITING FOR ORES"
    self.lastAction = "Requesting ores from Controller..."
    self:renderHeadlessUI()
    self:queryStateFromController()

    -- Notice: We do NOT send any scan radius, so the Controller uses its authoritative radius!
    local payload = {
        type = "request_ores",
    }
    self.net:send(self.controllerId, payload)

    -- Wait for ore_locations or state_response reply
    local timeout = 5.0
    local deadline = os.clock and (os.clock() + timeout) or (os.time() + timeout)

    while true do
        local now = os.clock and os.clock() or os.time()
        if now >= deadline then break end

        local raw, fromId = self.net:pullMessage(0.5)
        if raw and self:isSenderController(fromId) then
            if raw.type == "ore_locations" then
                self:handleOreBatch(raw)
                return true
            elseif raw.type == "state_response" then
                self:handleStateResponse(raw)
                if not self.running then
                    return false
                end
            elseif raw.type == "command" then
                self:handleCommand(raw)
                if not self.running then
                    return false
                end
            end
        end
    end
    return false
end

function Worker:handleOreBatch(payload)
    if type(payload.baseBlocks) == "table" then
        for _, b in ipairs(payload.baseBlocks) do
            local bx = self.home.x + (b.x or 0)
            local by = self.home.y + (b.y or 0)
            local bz = self.home.z + (b.z or 0)
            self:markBlocked(bx, by, bz)
        end
    end

    self.oreQueue = {}
    if type(payload.ores) == "table" then
        for _, o in ipairs(payload.ores) do
            local ox = self.home.x + (o.x or 0)
            local oy = self.home.y + (o.y or 0)
            local oz = self.home.z + (o.z or 0)
            if not self:isBlocked(ox, oy, oz) then
                table.insert(self.oreQueue, {
                    name = o.name,
                    x = ox, y = oy, z = oz,
                    dist = o.dist or (math.abs(ox) + math.abs(oy) + math.abs(oz))
                })
            end
        end
    end

    if payload.running ~= nil then
        self.running = payload.running
        if self.running and (self.phase:find("STOP") or self.phase:find("IDLE") or self.phase:find("WAIT")) then
            self.phase = "MINING"
        end
    end

    self.lastAction = string.format("Received %d ore(s) from Controller (r=%d)", #self.oreQueue, payload.scanRadius or 0)
    self:renderHeadlessUI()
    self:sendTelemetry()
end

function Worker:handleCommand(payload)
    local action = payload.action
    if action == "start" then
        self.running = true
        self.phase = "MINING"
        self.lastAction = "Started by Controller."
    elseif action == "stop" then
        self.running = false
        self.oreQueue = {}
        self.phase = "STOPPED"
        self.lastAction = "Stopped by Controller. Teleporting home..."
        self:renderHeadlessUI()
        self:sendTelemetry()
        self:returnToHome()
        self:unloadToBarrel()
        self.phase = "IDLE (Remote)"
        self.lastAction = "Stopped at Base by Controller."
    elseif action == "return_home" then
        self.running = false
        self.oreQueue = {}
        self.phase = "RETURNING HOME"
        self.lastAction = "Returning home by Controller command..."
        self:renderHeadlessUI()
        self:sendTelemetry()
        self:returnToHome()
        self:unloadToBarrel()
        self.phase = "IDLE (Remote)"
        self.lastAction = "Returned Home by Controller."
    elseif action == "sethome" then
        self.home = {
            x = self.pos.x,
            y = self.pos.y,
            z = self.pos.z,
            dir = self.pos.dir,
        }
        self:saveHome()
        self:saveHomeWarpPoint()
        self.lastAction = string.format("Home set to (%+d, %+d, %+d) [%s] by Controller",
            self.home.x, self.home.y, self.home.z, DIR_NAMES[self.home.dir or 0] or "N")
    elseif action == "unpair" then
        self.running = false
        self.oreQueue = {}
        self.phase = "UNPAIRED"
        self.lastAction = "Unpaired by Controller."
        Device.unpair()
        self.controllerId = nil
        self.unpairedRequested = true
    elseif action == "ota_start" then
        self.running = false
        self.oreQueue = {}
        self.phase = "UPDATING (OTA)"
        self.lastAction = string.format("OTA start (v%s, %d files)", tostring(payload.version or ""), payload.totalFiles or 0)
        self.otaStagedFiles = {}
        local stagingDir = ".staging"
        if fs.exists(stagingDir) and fs.delete then pcall(fs.delete, stagingDir) end
        if fs.makeDir then fs.makeDir(stagingDir) end
        self:renderHeadlessUI()
        self:queryStateFromController()
    elseif action == "ota_chunk" then
        self.running = false
        self.phase = "UPDATING (OTA)"
        local stagingDir = ".staging"
        local stagedPath = combinePath(stagingDir, payload.path)
        local sDir = getDirPath(stagedPath)
        if sDir and sDir ~= "" and not fs.exists(sDir) and fs.makeDir then fs.makeDir(sDir) end

        local mode = (payload.chunkIndex == 1) and "w" or "a"
        local f = fs.open(stagedPath, mode)
        if f then
            f.write(payload.chunk or "")
            f.close()
        end

        self.otaStagedFiles = self.otaStagedFiles or {}
        if payload.isLastChunk then
            self.otaStagedFiles[payload.path] = true
        end

        self.lastAction = string.format("OTA [%d/%d]: %s (%d/%d)",
            payload.fileIndex or 0, payload.totalFiles or 0,
            payload.path or "",
            payload.chunkIndex or 0, payload.totalChunks or 0)
        self:renderHeadlessUI()
    elseif action == "ota_commit" then
        self.running = false
        self.phase = "UPDATING (OTA)"
        self.lastAction = "Applying staged OTA update..."
        self:renderHeadlessUI()
        self:queryStateFromController()

        local stagingDir = ".staging"
        local count = 0
        for relPath, _ in pairs(self.otaStagedFiles or {}) do
            local destPath = relPath
            local destDir = getDirPath(destPath)
            if destDir and destDir ~= "" and not fs.exists(destDir) and fs.makeDir then fs.makeDir(destDir) end
            local stagedPath = combinePath(stagingDir, relPath)
            if fs.exists(destPath) and fs.delete then pcall(fs.delete, destPath) end
            copyFile(stagedPath, destPath)
            count = count + 1
        end
        if fs.delete then pcall(fs.delete, stagingDir) end

        self.lastAction = string.format("OTA update complete (%d files). Rebooting...", count)
        self:renderHeadlessUI()
        self:queryStateFromController()
        if os and os.sleep then pcall(os.sleep, 1) end
        if os and os.reboot then pcall(os.reboot) end
        return
    elseif action == "ota_update" then
        self.running = false
        self.oreQueue = {}
        self.phase = "UPDATING (OTA)"
        self.lastAction = "Applying OTA firmware update..."
        self:renderHeadlessUI()
        self:queryStateFromController()

        local files = payload.files or {}
        local stagingDir = ".staging"
        if fs.exists(stagingDir) and fs.delete then pcall(fs.delete, stagingDir) end
        if fs.makeDir then fs.makeDir(stagingDir) end

        local fileCount = 0
        local writeErr = nil
        for relPath, content in pairs(files) do
            local stagedPath = combinePath(stagingDir, relPath)
            local sDir = getDirPath(stagedPath)
            if sDir and sDir ~= "" and not fs.exists(sDir) and fs.makeDir then fs.makeDir(sDir) end
            local f = fs.open(stagedPath, "w")
            if f then
                f.write(content)
                f.close()
                fileCount = fileCount + 1
            else
                writeErr = "Failed to write staged file: " .. tostring(relPath)
                break
            end
        end

        if writeErr or fileCount == 0 then
            self.lastAction = "OTA update failed: " .. tostring(writeErr or "no files received")
            self.phase = "IDLE (Remote)"
            self:renderHeadlessUI()
            self:queryStateFromController()
            return
        end

        -- Staging succeeded: replace files
        for relPath, _ in pairs(files) do
            local destPath = relPath
            local destDir = getDirPath(destPath)
            if destDir and destDir ~= "" and not fs.exists(destDir) and fs.makeDir then fs.makeDir(destDir) end
            local stagedPath = combinePath(stagingDir, relPath)
            if fs.exists(destPath) and fs.delete then pcall(fs.delete, destPath) end
            copyFile(stagedPath, destPath)
        end
        if fs.delete then pcall(fs.delete, stagingDir) end

        self.lastAction = string.format("OTA update complete (%d files). Rebooting...", fileCount)
        self:renderHeadlessUI()
        self:queryStateFromController()
        if os and os.sleep then pcall(os.sleep, 1) end
        if os and os.reboot then pcall(os.reboot) end
        return
    end
    self:renderHeadlessUI()
    self:sendTelemetry()
end

--------------------------------------------------------------------------------
-- Main Mining Execution Cycle
--------------------------------------------------------------------------------

function Worker:mineToTarget(target)
    self.currentTarget = target.name
    self.lastAction = string.format("Mining %s at (%+d, %+d, %+d)...", tostring(target.name or "ore"), target.x, target.y, target.z)
    self:renderHeadlessUI()
    self:sendTelemetry()

    local maxSteps = 120
    local steps = 0

    while steps < maxSteps do
        steps = steps + 1

        -- Responsive remote control: check network at every movement step
        local msg, fromId = self.net:pullMessage(0.05)
        if msg and self:isSenderController(fromId) then
            if msg.type == "command" then
                self:handleCommand(msg)
                if not self.running then
                    return false, "stopped"
                end
            elseif msg.type == "state_response" then
                self:handleStateResponse(msg)
                if not self.running then
                    return false, "stopped"
                end
            elseif msg.type == "ore_locations" then
                self:handleOreBatch(msg)
            end
        end

        if not self.running then
            return false, "stopped"
        end

        -- Query controller state periodically during mining navigation
        if steps % 4 == 0 then
            self:queryStateFromController()
        end

        local dx = target.x - self.pos.x
        local dy = target.y - self.pos.y
        local dz = target.z - self.pos.z
        local dist = math.abs(dx) + math.abs(dy) + math.abs(dz)

        -- If inside or adjacent (dist <= 1), mine the target with End Automata!
        if dist == 0 then
            self.lastAction = "Mined " .. tostring(target.name)
            return true
        elseif dist == 1 then
            if dy == 1 then
                self:digBlock("up")
            elseif dy == -1 then
                self:digBlock("down")
            else
                for d, vec in pairs(DIR_VECTORS) do
                    if vec.x == dx and vec.z == dz then
                        self:turnTo(d)
                        self:digBlock("forward")
                        break
                    end
                end
            end
            self.lastAction = "Mined " .. tostring(target.name)
            return true
        end

        -- Down-first movement priority (-Y before X/Z)
        if self.pos.y > target.y then
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveDown() then
                if dx ~= 0 or dz ~= 0 then
                    -- If down blocked, move horizontally toward target
                    if dx > 0 then self:turnTo(1); self:moveForward()
                    elseif dx < 0 then self:turnTo(3); self:moveForward()
                    elseif dz > 0 then self:turnTo(2); self:moveForward()
                    elseif dz < 0 then self:turnTo(0); self:moveForward() end
                else
                    break
                end
            end
        elseif self.pos.x < target.x then
            self:turnTo(1)
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then
                if self.pos.y < target.y then self:moveUp() else break end
            end
        elseif self.pos.x > target.x then
            self:turnTo(3)
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then
                if self.pos.y < target.y then self:moveUp() else break end
            end
        elseif self.pos.z < target.z then
            self:turnTo(2)
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then
                if self.pos.y < target.y then self:moveUp() else break end
            end
        elseif self.pos.z > target.z then
            self:turnTo(0)
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then
                if self.pos.y < target.y then self:moveUp() else break end
            end
        elseif self.pos.y < target.y then
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveUp() then break end
        else
            break
        end
    end

    local finalDist = math.abs(target.x - self.pos.x) + math.abs(target.y - self.pos.y) + math.abs(target.z - self.pos.z)
    return finalDist <= 1
end

function Worker:run()
    self.net:open()

    -- Only record home warp point when truly at base or on initial boot
    local atHome = (self.pos.x == self.home.x and self.pos.y == self.home.y and self.pos.z == self.home.z)
    if atHome then
        self:saveHomeWarpPoint()
        self:saveHome()
        self:savePos()
    end

    self:renderHeadlessUI()
    self:queryStateFromController()

    local lastStateQueryTime = 0

    while true do
        self:renderHeadlessUI()

        -- Emergency check: If running and NO coal in inventory -> immediately return to home!
        if self.running and not self:hasCoal() then
            self.phase = "EMERGENCY: NO COAL"
            self.lastAction = "No coal in inventory! Teleporting home immediately..."
            self:renderHeadlessUI()
            self:queryStateFromController()
            self:returnToHome()
            self:unloadToBarrel()
            self.running = false
            self.phase = "IDLE (Needs Coal)"
            self:renderHeadlessUI()
            self:queryStateFromController()
        end

        -- Constant communication model: query state from controller every 1.0s
        local now = os.clock and os.clock() or os.time()
        if now - lastStateQueryTime >= 1.0 then
            self:queryStateFromController()
            lastStateQueryTime = now
        end

        -- Check for incoming remote messages
        local msg, fromId = self.net:pullMessage(0.2)
        if msg and self:isSenderController(fromId) then
            if msg.type == "command" then
                self:handleCommand(msg)
            elseif msg.type == "state_response" then
                self:handleStateResponse(msg)
            elseif msg.type == "ore_locations" then
                self:handleOreBatch(msg)
            end
        end

        if self.running then
            if self:isInventoryFull() then
                self.phase = "INVENTORY FULL"
                self.lastAction = "Inventory full (16/16). Returning home to deposit ores..."
                self:renderHeadlessUI()
                self:queryStateFromController()
                self:returnToHome()
                self:unloadToBarrel()
                self:requestOresFromController()
            elseif #self.oreQueue == 0 then
                -- Ask controller for more ores
                local ok = self:requestOresFromController()
                if not ok or #self.oreQueue == 0 then
                    self.phase = "WAITING FOR ORES (At Base)"
                    self.lastAction = "No ores in scan. Waiting at base for Controller..."
                    self:returnToHome()
                    self:unloadToBarrel()
                    -- Do not permanently kill self.running; query controller
                    if os.sleep then os.sleep(0.5) end
                end
            else
                -- Mine next ore in queue
                local target = table.remove(self.oreQueue, 1)
                self.phase = "MINING"
                local ok, err = self:mineToTarget(target)
                if err == "stopped" then
                    -- Worker was stopped by controller and already teleported home
                elseif err == "no_coal" then
                    self.phase = "EMERGENCY: NO COAL"
                    self:returnToHome()
                    self:unloadToBarrel()
                    self.running = false
                end
                self:queryStateFromController()
            end
        else
            self.phase = "IDLE (Remote)"
        end
    end
end

return Worker
