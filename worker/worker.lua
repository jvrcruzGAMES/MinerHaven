--- worker/worker.lua - Headless Mining Worker for MinerHaven
-- Remote-commanded by Base Controller over encrypted Workernet.
-- Features End Automata teleportation, native pickaxe auto-equip, fuel stack retention (64),
-- emergency return on 0 coal, waste placement, and Sophisticated Storage barrel unloading.

local GeoScanner = require("geoscanner")
local Workernet = dofile("lib/workernet/main.lua")
local Device = dofile("worker/lib/device/main.lua")

local Worker = {}
Worker.__index = Worker

local HOME_FILE = "worker/home.cfg"
local POS_FILE = "worker/pos.cfg"
local HOME_WARP_NAME = "home"

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
    for _, t in ipairs(GeoScanner.AUTOMATA_TYPES) do
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

function Worker:ensurePickaxeEquipped()
    if not turtle or not turtle.getItemDetail then return false end
    local _, automataSide = self:ensureAutomata()
    local toolSide = (automataSide == "left") and "right" or "left"

    -- Check if tool is already equipped
    local currentToolType = peripheral and peripheral.getType(toolSide)
    if currentToolType == nil or currentToolType == "tool" then
        -- Native CC tool does not register as peripheral
    end

    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name then
            local lower = detail.name:lower()
            if lower:find("pickaxe", 1, true) or lower:find("drill", 1, true) then
                turtle.select(slot)
                local equipped = false
                if toolSide == "right" and turtle.equipRight then
                    equipped = turtle.equipRight()
                elseif toolSide == "left" and turtle.equipLeft then
                    equipped = turtle.equipLeft()
                end
                turtle.select(prevSlot)
                if equipped then
                    self.pickaxeSide = toolSide
                    return true
                end
            end
        end
    end
    turtle.select(prevSlot)
    return false
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
    return self.energyItems[name] or GeoScanner.isEnergyItemName(name)
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
    if hasF and GeoScanner.isStorageBarrelName(fData.name) then
        dropFn = turtle.drop
    else
        local hasU, uData = turtle.inspectUp()
        if hasU and GeoScanner.isStorageBarrelName(uData.name) then
            dropFn = turtle.dropUp
        else
            local hasD, dData = turtle.inspectDown()
            if hasD and GeoScanner.isStorageBarrelName(dData.name) then
                dropFn = turtle.dropDown
            else
                -- Try sides
                local baseDir = self.home.dir or 0
                for _, d in ipairs({ (baseDir + 1) % 4, (baseDir + 3) % 4, (baseDir + 2) % 4 }) do
                    self:turnTo(d)
                    local okB, bData = turtle.inspect()
                    if okB and GeoScanner.isStorageBarrelName(bData.name) then
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
    return GeoScanner.isProtectedBlockName(name)
end

function Worker:selectWasteBlock()
    if not turtle or not turtle.getItemDetail then return false end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name and GeoScanner.isWasteName(detail.name) and not self:isCoalItem(detail) then
            turtle.select(slot)
            return true
        end
    end
    return false
end

function Worker:placeWasteBehind()
    if not turtle or not turtle.placeUp then return false end
    if self:selectWasteBlock() then
        -- Prefer placing down or up
        local okDown = turtle.placeDown()
        if not okDown then turtle.placeUp() end
        turtle.select(1)
        return true
    end
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

function Worker:nativeDig(dirStr)
    self:ensurePickaxeEquipped()
    if dirStr == "up" then
        return turtle.digUp()
    elseif dirStr == "down" then
        return turtle.digDown()
    else
        return turtle.dig()
    end
end

function Worker:moveForward()
    self:refuelIfNeeded()
    local vec = DIR_VECTORS[self.pos.dir or 0] or { x = 0, z = -1 }
    local nx, ny, nz = self.pos.x + vec.x, self.pos.y, self.pos.z + vec.z

    if self:isBlocked(nx, ny, nz) then return false, "blocked_coordinate" end

    local hasB, bData = turtle.inspect()
    if hasB then
        if self:isProtectedBlock(bData.name) then return false, "protected_block" end
        self:nativeDig("forward")
    end

    if turtle.forward() then
        self.pos.x, self.pos.z = nx, nz
        self:savePos()
        self:placeWasteBehind()
        return true
    end
    return false
end

function Worker:moveDown()
    self:refuelIfNeeded()
    local nx, ny, nz = self.pos.x, self.pos.y - 1, self.pos.z
    if self:isBlocked(nx, ny, nz) then return false, "blocked_coordinate" end

    local hasB, bData = turtle.inspectDown()
    if hasB then
        if self:isProtectedBlock(bData.name) then return false, "protected_block" end
        self:nativeDig("down")
    end

    if turtle.down() then
        self.pos.y = ny
        self:savePos()
        self:placeWasteBehind()
        return true
    end
    return false
end

function Worker:moveUp()
    self:refuelIfNeeded()
    local nx, ny, nz = self.pos.x, self.pos.y + 1, self.pos.z
    if self:isBlocked(nx, ny, nz) then return false, "blocked_coordinate" end

    local hasB, bData = turtle.inspectUp()
    if hasB then
        if self:isProtectedBlock(bData.name) then return false, "protected_block" end
        self:nativeDig("up")
    end

    if turtle.up() then
        self.pos.y = ny
        self:savePos()
        self:placeWasteBehind()
        return true
    end
    return false
end

function Worker:refuelIfNeeded()
    if not turtle or not turtle.getFuelLevel then return end
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() < 300 then
        -- Refuel using coal if excess > 64 or emergency
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail and self:isCoalItem(detail) then
                turtle.select(slot)
                turtle.refuel(1)
                turtle.select(1)
                if turtle.getFuelLevel() >= 300 then break end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- End Automata Home Teleport & Fallback Pathfinding
--------------------------------------------------------------------------------

function Worker:saveHomeWarpPoint()
    local automata = self:ensureAutomata()
    if automata and automata.savePoint then
        pcall(automata.savePoint, HOME_WARP_NAME)
    end
end

function Worker:teleportHome()
    local automata = self:ensureAutomata()
    if not automata or not automata.warpToPoint then
        return false, "no_automata"
    end

    local ok, res = pcall(automata.warpToPoint, HOME_WARP_NAME)
    if ok and res == true then
        self.pos.x = self.home.x
        self.pos.y = self.home.y
        self.pos.z = self.home.z
        self:savePos()
        self:turnTo(self.home.dir or 0)
        return true
    end
    return false, tostring(res)
end

function Worker:returnToHome()
    self.phase = "RETURNING HOME"
    self.lastAction = "Attempting End Automata warp to Home..."
    self:renderHeadlessUI()
    self:sendTelemetry()

    local warped, err = self:teleportHome()
    if warped then
        self.lastAction = "Warped home via End Automata!"
        return true
    end

    -- Fallback: dig way back home
    self.lastAction = "Automata warp failed (" .. tostring(err) .. "). Digging back home..."
    self:renderHeadlessUI()

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

function Worker:sendTelemetry()
    if not self.controllerId then return end
    local fuel = turtle and turtle.getFuelLevel and turtle.getFuelLevel() or 0
    local payload = {
        type = "telemetry",
        phase = self.phase,
        x = self.pos.x,
        y = self.pos.y,
        z = self.pos.z,
        fuel = fuel,
        usedSlots = self:getUsedSlotCount(),
        lastAction = self.lastAction,
    }
    self.net:send(self.controllerId, payload)
end

function Worker:requestOresFromController()
    if not self.controllerId then return false end
    self.phase = "WAITING FOR ORES"
    self.lastAction = "Requesting ores from Controller..."
    self:renderHeadlessUI()

    -- Notice: We do NOT send any scan radius, so the Controller uses its authoritative radius!
    local payload = {
        type = "request_ores",
    }
    self.net:send(self.controllerId, payload)

    -- Wait for ore_locations reply
    local timeout = 5.0
    local deadline = os.clock and (os.clock() + timeout) or (os.time() + timeout)

    while true do
        local now = os.clock and os.clock() or os.time()
        if now >= deadline then break end

        local raw, fromId = self.net:pullMessage(0.5)
        if raw and fromId == self.controllerId then
            if raw.type == "ore_locations" then
                self:handleOreBatch(raw)
                return true
            elseif raw.type == "command" then
                self:handleCommand(raw)
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
    end

    self.lastAction = string.format("Received %d ore(s) from Controller (r=%d)", #self.oreQueue, payload.scanRadius or 0)
    self:renderHeadlessUI()
end

function Worker:handleCommand(payload)
    local action = payload.action
    if action == "start" then
        self.running = true
        self.phase = "MINING"
        self.lastAction = "Started by Controller."
    elseif action == "stop" then
        self.running = false
        self.phase = "STOPPED"
        self.lastAction = "Stopped by Controller. Returning home..."
        self:returnToHome()
        self:unloadToBarrel()
    elseif action == "return_home" then
        self:returnToHome()
        self:unloadToBarrel()
    end
    self:renderHeadlessUI()
    self:sendTelemetry()
end

--------------------------------------------------------------------------------
-- Main Mining Execution Cycle
--------------------------------------------------------------------------------

function Worker:mineToTarget(target)
    self.lastAction = string.format("Moving to ore (%+d, %+d, %+d)...", target.x, target.y, target.z)
    self:renderHeadlessUI()

    -- 1. Priority -Y: Move down to target Y first!
    while self.pos.y > target.y do
        if not self:hasCoal() then return false, "no_coal" end
        if not self:moveDown() then break end
    end

    -- 2. Move X
    if self.pos.x < target.x then
        self:turnTo(1)
        while self.pos.x < target.x do
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then break end
        end
    elseif self.pos.x > target.x then
        self:turnTo(3)
        while self.pos.x > target.x do
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then break end
        end
    end

    -- 3. Move Z
    if self.pos.z < target.z then
        self:turnTo(2)
        while self.pos.z < target.z do
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then break end
        end
    elseif self.pos.z > target.z then
        self:turnTo(0)
        while self.pos.z > target.z do
            if not self:hasCoal() then return false, "no_coal" end
            if not self:moveForward() then break end
        end
    end

    -- 4. Move Y up if target is higher
    while self.pos.y < target.y do
        if not self:hasCoal() then return false, "no_coal" end
        if not self:moveUp() then break end
    end

    -- Dig surrounding block if adjacent
    local isAtTarget = (self.pos.x == target.x and self.pos.y == target.y and self.pos.z == target.z)
    if isAtTarget then
        self.lastAction = "Arrived at ore location " .. tostring(target.name)
        return true
    end

    return false
end

function Worker:run()
    self.net:open()
    self:saveHomeWarpPoint()
    self:saveHome()
    self:savePos()

    self:renderHeadlessUI()
    self:sendTelemetry()

    local telemetryTimer = os.startTimer and os.startTimer(2.0) or nil

    while true do
        self:renderHeadlessUI()

        -- Emergency check: If running and NO coal in inventory -> immediately return to home!
        if self.running and not self:hasCoal() then
            self.phase = "EMERGENCY: NO COAL"
            self.lastAction = "No coal in inventory! Teleporting home immediately..."
            self:renderHeadlessUI()
            self:sendTelemetry()
            self:returnToHome()
            self:unloadToBarrel()
            self.running = false
            self.phase = "IDLE (Needs Coal)"
            self:renderHeadlessUI()
            self:sendTelemetry()
        end

        -- Check for incoming remote messages
        local msg, fromId = self.net:pullMessage(0.2)
        if msg and fromId == self.controllerId then
            if msg.type == "command" then
                self:handleCommand(msg)
            elseif msg.type == "ore_locations" then
                self:handleOreBatch(msg)
            end
        end

        if self.running then
            if self:isInventoryFull() then
                self.phase = "INVENTORY FULL"
                self.lastAction = "Inventory full (16/16). Returning home to deposit ores..."
                self:renderHeadlessUI()
                self:sendTelemetry()
                self:returnToHome()
                self:unloadToBarrel()
                self:requestOresFromController()
            elseif #self.oreQueue == 0 then
                -- Ask controller for more ores
                local ok = self:requestOresFromController()
                if not ok or #self.oreQueue == 0 then
                    self.phase = "IDLE (No Ores)"
                    self.lastAction = "No ores in scan. Waiting at base..."
                    self:returnToHome()
                    self:unloadToBarrel()
                    if os.sleep then os.sleep(3.0) end
                end
            else
                -- Mine next ore in queue
                local target = table.remove(self.oreQueue, 1)
                self.phase = "MINING"
                local ok, err = self:mineToTarget(target)
                if err == "no_coal" then
                    self.phase = "EMERGENCY: NO COAL"
                    self:returnToHome()
                    self:unloadToBarrel()
                    self.running = false
                end
                self:sendTelemetry()
            end
        else
            self.phase = "IDLE (Remote)"
            if os.sleep then os.sleep(1.0) end
        end
    end
end

return Worker
