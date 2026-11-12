--- MinerHaven Turtle Auto-Miner
-- Startup service & interactive controller for CC: Tweaked Geo Scanner Turtles.
--
-- Features:
--   - Loads automatically on turtle startup (stays alive in IDLE mode when stopped).
--   - Accepts `start` and `stop` instructions (via typed command, hotkeys, mouse click, or CLI).
--   - When STARTED:
--       1. Scans for nearby ores by block tag (`#forge:ores`, `#c:ores`, `#minecraft:*_ores`)
--       2. Navigates to and mines the nearest ores until the turtle's inventory is full
--       3. Returns to the saved Home location (`/home.cfg`)
--       4. Waits at Home until its inventory has no more ores, then resumes mining automatically
--   - When STOPPED:
--       Does NOT terminate; stays idle waiting until `start` is given again.

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
        local c = input:match("^%s*(%a)"):lower()
        if c == "n" then return 0 end
        if c == "e" then return 1 end
        if c == "s" then return 2 end
        if c == "w" then return 3 end
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
    self.maxExploreSteps = tonumber(opts.maxExploreSteps) or 3
    self.exploreCount = 0
    self.minedItems = {}
    self.commandBuffer = ""
    self.scanner = opts.scanner or nil
    self.inWorkerStep = false
    self.pendingReturnOnStop = false

    return self
end

function TurtleMiner:ensureScanner()
    if self.scanner then
        return self.scanner
    end
    local s, err = GeoScanner.find()
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

--- Set the turtle's Home to the current block it is in and save to disk (`/home.cfg`).
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
    self.lastAction = ("Home set to current block (%d, %d, %d) [%s]"):format(
        self.home.x, self.home.y, self.home.z, DIR_NAMES[dir] or "N"
    )
    return self.home
end

-- Alias for backwards compatibility
TurtleMiner.setHomeHere = TurtleMiner.sethome

--- Start the auto-miner.
function TurtleMiner:start()
    self.running = true
    self.pendingReturnOnStop = false
    self.phase = "MINING"
    self.lastAction = "Started! Scanning for nearby ores..."
    self:saveState()
end

--- Stop the auto-miner without exiting the program.
-- If stopped while running (even when inventory is not full), returns to Home before staying idle.
function TurtleMiner:stop()
    local wasRunning = self.running
    self.running = false
    self:saveState()

    if wasRunning or not self:isAtHome() then
        if self.inWorkerStep then
            -- Worker coroutine is currently mid-step/movement; signal it to abort and return home immediately
            self.pendingReturnOnStop = true
            self.phase = "RETURNING HOME (Stopping)"
            self.lastAction = "Stopping... returning to Home..."
        else
            if not self:isAtHome() then
                self:returnToHome()
            end
            self.pendingReturnOnStop = false
            self.phase = "IDLE (Stopped)"
            self.lastAction = "Stopped at Home. Staying idle until 'start'..."
        end
    else
        self.phase = "IDLE (Stopped)"
        self.lastAction = "Stopped. Staying idle until 'start'..."
    end
end

--------------------------------------------------------------------------------
-- Inventory & Fuel Management
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
            if (detail.count or 1) > prev and not GeoScanner.WASTE_BLOCKS[name] then
                self.minedItems[name] = true
            end
        end
    end
end

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
    for slot = 1, 16 do
        local count = turtle.getItemCount(slot)
        if count > 0 then
            usedSlots = usedSlots + 1
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if detail and GeoScanner.isOreItem(detail, self.minedItems) then
                oreCount = oreCount + (detail.count or count)
            end
        end
    end
    return usedSlots, oreCount
end

--- Check whether the turtle's inventory currently contains any ores (by tag or mined ore item).
function TurtleMiner:hasOresInInventory()
    if not turtle or not turtle.getItemCount then
        return false
    end
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            if detail and GeoScanner.isOreItem(detail, self.minedItems) then
                return true
            end
        end
    end
    return false
end

--- Drop non-ore waste blocks (cobblestone, dirt, gravel, etc.) if needed to free up slots for ores.
function TurtleMiner:dropWasteBlocks()
    if not turtle or not turtle.getItemDetail or not turtle.drop then
        return 0
    end
    local droppedSlots = 0
    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot, true)
        if detail and detail.name and GeoScanner.WASTE_BLOCKS[detail.name:lower()] then
            turtle.select(slot)
            if turtle.dropDown then
                turtle.dropDown()
            else
                turtle.drop()
            end
            droppedSlots = droppedSlots + 1
        end
    end
    if turtle.select then
        turtle.select(prevSlot)
    end
    return droppedSlots
end

--- Refuel automatically from inventory if fuel is low.
function TurtleMiner:ensureFuel(minRequired)
    if not turtle or not turtle.getFuelLevel then
        return true
    end
    local level = turtle.getFuelLevel()
    if level == "unlimited" then
        return true
    end
    minRequired = minRequired or 100
    if level >= minRequired then
        return true
    end
    if not turtle.refuel then
        return level > 0
    end
    local prevSlot = turtle.getSelectedSlot and turtle.getSelectedSlot() or 1
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local detail = turtle.getItemDetail and turtle.getItemDetail(slot, true) or nil
            -- Avoid burning valuable ores like diamond/redstone/raw_iron (coal is okay if desperate, or non-ore fuels)
            local isCoal = detail and detail.name and detail.name:lower():find("coal", 1, true)
            if not detail or isCoal or not GeoScanner.isOreItem(detail, self.minedItems) then
                turtle.select(slot)
                turtle.refuel(16)
                if turtle.getFuelLevel() >= minRequired then
                    break
                end
            end
        end
    end
    if turtle.select then
        turtle.select(prevSlot)
    end
    return turtle.getFuelLevel() > 0
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

function TurtleMiner:stepForward(digIfBlocked)
    if not turtle then return false end
    self:ensureFuel(20)
    local attempts = 0
    while not turtle.forward() do
        attempts = attempts + 1
        if attempts > 10 then
            return false
        end
        if digIfBlocked and turtle.dig then
            local before = self:snapshotInventoryCounts()
            turtle.dig()
            self:recordNewlyMinedItems(before)
        end
        if turtle.attack then
            turtle.attack()
        end
        sleepSeconds(0.2)
    end
    local vec = DIR_VECTORS[self.pos.dir] or { x = 0, z = -1 }
    self.pos.x = self.pos.x + vec.x
    self.pos.z = self.pos.z + vec.z
    self:savePos()
    return true
end

function TurtleMiner:stepUp(digIfBlocked)
    if not turtle then return false end
    self:ensureFuel(20)
    local attempts = 0
    while not turtle.up() do
        attempts = attempts + 1
        if attempts > 10 then
            return false
        end
        if digIfBlocked and turtle.digUp then
            local before = self:snapshotInventoryCounts()
            turtle.digUp()
            self:recordNewlyMinedItems(before)
        end
        if turtle.attackUp then
            turtle.attackUp()
        end
        sleepSeconds(0.2)
    end
    self.pos.y = self.pos.y + 1
    self:savePos()
    return true
end

function TurtleMiner:stepDown(digIfBlocked)
    if not turtle then return false end
    self:ensureFuel(20)
    local attempts = 0
    while not turtle.down() do
        attempts = attempts + 1
        if attempts > 10 then
            return false
        end
        if digIfBlocked and turtle.digDown then
            local before = self:snapshotInventoryCounts()
            turtle.digDown()
            self:recordNewlyMinedItems(before)
        end
        if turtle.attackDown then
            turtle.attackDown()
        end
        sleepSeconds(0.2)
    end
    self.pos.y = self.pos.y - 1
    self:savePos()
    return true
end

--- Navigate to target coordinates `(tx, ty, tz)`.
-- @tparam number tx Target X
-- @tparam number ty Target Y
-- @tparam number tz Target Z
-- @tparam boolean stopAdjacent If true, stops 1 block adjacent to the target and digs it
-- @tparam boolean respectStop If true, aborts movement immediately if `self.running` becomes false
-- @treturn boolean success
function TurtleMiner:moveTo(tx, ty, tz, stopAdjacent, respectStop)
    while true do
        if respectStop and not self.running then
            return false
        end

        local dx = tx - self.pos.x
        local dy = ty - self.pos.y
        local dz = tz - self.pos.z
        local dist = math.abs(dx) + math.abs(dy) + math.abs(dz)

        if dist == 0 then
            return true
        end

        -- If we only need to reach an adjacent block to dig the target ore
        if stopAdjacent and dist == 1 then
            local before = self:snapshotInventoryCounts()
            if dy == 1 and turtle.digUp then
                turtle.digUp()
            elseif dy == -1 and turtle.digDown then
                turtle.digDown()
            elseif dx == 1 then
                self:turnTo(1)
                if turtle.dig then turtle.dig() end
            elseif dx == -1 then
                self:turnTo(3)
                if turtle.dig then turtle.dig() end
            elseif dz == 1 then
                self:turnTo(2)
                if turtle.dig then turtle.dig() end
            elseif dz == -1 then
                self:turnTo(0)
                if turtle.dig then turtle.dig() end
            end
            self:recordNewlyMinedItems(before)
            return true
        end

        -- Move vertically first, then X, then Z
        local moved = false
        if dy > 0 then
            moved = self:stepUp(true)
        elseif dy < 0 then
            moved = self:stepDown(true)
        end

        if not moved and dx ~= 0 then
            self:turnTo(dx > 0 and 1 or 3)
            moved = self:stepForward(true)
        end

        if not moved and dz ~= 0 then
            self:turnTo(dz > 0 and 2 or 0)
            moved = self:stepForward(true)
        end

        if not moved then
            return false
        end
    end
end

--- Return the turtle to its saved Home coordinates and face its home direction.
function TurtleMiner:returnToHome()
    self.phase = "RETURNING HOME"
    self.lastAction = ("Returning to Home (%d, %d, %d)..."):format(
        self.home.x, self.home.y, self.home.z
    )
    local ok = self:moveTo(self.home.x, self.home.y, self.home.z, false, false)
    if ok then
        self:turnTo(self.home.dir or 0)
        self.lastAction = "Arrived at Home."
    else
        self.lastAction = "Blocked while returning to Home!"
    end
    return ok
end

function TurtleMiner:isAtHome()
    return self.pos.x == self.home.x
        and self.pos.y == self.home.y
        and self.pos.z == self.home.z
end

--------------------------------------------------------------------------------
-- Single Step of the Worker State Machine
--------------------------------------------------------------------------------

function TurtleMiner:finishStopReturnHome()
    if not self:isAtHome() then
        self:returnToHome()
    end
    self.pendingReturnOnStop = false
    self.phase = "IDLE (Stopped)"
    self.lastAction = "Stopped at Home. Staying idle until 'start'..."
    return "idle"
end

--- Execute one logical step of the auto-miner state machine.
-- Separated so it can be driven both by the continuous daemon loop and by unit tests.
function TurtleMiner:stepWorker()
    if not self.running then
        if self.pendingReturnOnStop then
            return self:finishStopReturnHome()
        end
        self.phase = "IDLE (Stopped)"
        return "idle"
    end

    self.inWorkerStep = true

    -- 1. If we are waiting at Home for ores to be unloaded, check if ores are gone
    if self.phase == "WAITING AT HOME" then
        if self:hasOresInInventory() then
            local _, oreCount = self:getInventoryStats()
            self.lastAction = ("Waiting at Home: %d ore(s) still in inventory"):format(oreCount)
            self.inWorkerStep = false
            return "waiting_unload"
        else
            -- All ores have been removed! Clean up any leftover waste stone so inventory isn't full
            if self:isInventoryFull() then
                self:dropWasteBlocks()
            end
            self.phase = "MINING"
            self.lastAction = "Inventory cleared of ores! Resuming mining..."
        end
    end

    -- 2. Check if inventory is full
    if self:isInventoryFull() then
        -- Try dropping waste cobble/dirt first ONLY if we haven't collected any ores yet;
        -- otherwise return home with our full load!
        if not self:hasOresInInventory() then
            self:dropWasteBlocks()
        end
        if self:isInventoryFull() then
            self:returnToHome()
            self.inWorkerStep = false
            if not self.running then
                return self:finishStopReturnHome()
            end
            if self:hasOresInInventory() then
                self.phase = "WAITING AT HOME"
                local _, oreCount = self:getInventoryStats()
                self.lastAction = ("At Home (Full). Waiting for %d ore(s) to be unloaded..."):format(oreCount)
                return "waiting_unload"
            else
                self:dropWasteBlocks()
                return "returned_home"
            end
        end
    end

    -- 3. Scan for nearby ores by tag
    self.phase = "MINING"
    local scanner = self:ensureScanner()
    if not scanner then
        self.inWorkerStep = false
        return "no_scanner"
    end

    local ores, scanErr = scanner:scanOresByTag(self.scanRadius, {
        retries = 5,
        retryDelay = 0.5,
    })

    if not self.running then
        self.inWorkerStep = false
        return self:finishStopReturnHome()
    end

    if not ores then
        self.lastAction = "Scan wait: " .. tostring(scanErr)
        self.inWorkerStep = false
        return "scan_error"
    end

    if #ores == 0 then
        -- No ores in current radius; if we have ores and have explored enough, or can step forward
        if self.exploreCount < self.maxExploreSteps then
            self.exploreCount = self.exploreCount + 1
            self.lastAction = ("No ores in r=%d. Advancing (%d/%d)..."):format(
                self.scanRadius, self.exploreCount, self.maxExploreSteps
            )
            self:stepForward(true)
            self.inWorkerStep = false
            if not self.running then
                return self:finishStopReturnHome()
            end
            return "exploring"
        else
            self.lastAction = ("No nearby ores found in r=%d."):format(self.scanRadius)
            self.inWorkerStep = false
            return "no_ores"
        end
    end

    self.exploreCount = 0
    local target = ores[1]
    local targetX = self.pos.x + target.x
    local targetY = self.pos.y + target.y
    local targetZ = self.pos.z + target.z

    self.lastAction = ("Mining %s at (%+d,%+d,%+d)"):format(
        target.prettyName, target.x, target.y, target.z
    )

    local mined = self:moveTo(targetX, targetY, targetZ, true, true)
    self.inWorkerStep = false
    if not self.running then
        return self:finishStopReturnHome()
    end

    if mined then
        self.lastAction = ("Collected %s!"):format(target.prettyName)
    else
        self.lastAction = ("Could not reach %s"):format(target.prettyName)
    end

    -- Immediately check if inventory became full after mining this ore
    if self:isInventoryFull() then
        self:returnToHome()
        if not self.running then
            return self:finishStopReturnHome()
        end
        if self:hasOresInInventory() then
            self.phase = "WAITING AT HOME"
            local _, oreCount = self:getInventoryStats()
            self.lastAction = ("At Home (Full). Waiting for %d ore(s) to be unloaded..."):format(oreCount)
            return "waiting_unload"
        end
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

    line(1, " MinerHaven Turtle Auto-Miner", colors.white, isColor and colors.blue or colors.black)

    local stateColor = colors.yellow
    if self.running then
        stateColor = (self.phase == "WAITING AT HOME") and colors.orange or colors.lime
    end

    local usedSlots, oreItems = self:getInventoryStats()
    local fuel = (turtle and turtle.getFuelLevel) and tostring(turtle.getFuelLevel()) or "N/A"

    line(2, (" State : %s"):format(self.phase), stateColor, colors.black)
    line(3, (" Home  : (%d, %d, %d) [%s]"):format(
        self.home.x, self.home.y, self.home.z, DIR_NAMES[self.home.dir or 0] or "N"
    ), colors.lightGray, colors.black)
    line(4, (" Pos   : (%d, %d, %d) [%s]  Fuel: %s"):format(
        self.pos.x, self.pos.y, self.pos.z, DIR_NAMES[self.pos.dir or 0] or "N", fuel
    ), colors.white, colors.black)
    line(5, (" Inv   : %d/16 slots | Ores: %d"):format(usedSlots, oreItems), colors.cyan, colors.black)
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
        self.phase = "IDLE (At Home)"
    elseif cmd == "shell" or cmd == "exit" or cmd == "quit" then
        self.keepProgramAlive = false
    else
        self.lastAction = "Unknown cmd '" .. cmd .. "' (use: start / stop)"
    end
end

function TurtleMiner:runDaemon()
    self:drawUI()

    local function workerLoop()
        while self.keepProgramAlive do
            if self.running or self.pendingReturnOnStop then
                local status = self:stepWorker()
                self:drawUI()
                if status == "waiting_unload" or status == "no_ores" or status == "no_scanner" or status == "scan_error" then
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
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "char" then
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
        -- Pure Lua coroutine fallback when `parallel` is not in global scope
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
        -- Launch or stay in daemon mode unless --no-daemon is passed
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
        print("MinerHaven Turtle Auto-Miner")
        print("Usage:")
        print("  miner                  Run interactive startup daemon")
        print("  miner start            Start mining nearby ores by tag")
        print("  miner stop             Stop mining and stay idle")
        print("  miner sethome [n/e/s/w] Save current location as Home")
        print("  miner status           Show current status and home")
        return TurtleMiner
    end
end

miner:runDaemon()
return TurtleMiner
