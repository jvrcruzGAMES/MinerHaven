--- MinerHaven Base Computer Controller
-- Runs on the Base Advanced Computer (placed alongside the Turtle, Geo Scanner, and Sophisticated Storage Barrel).
--
-- Responsibilities:
--   1. Scans for ores using the Base Computer's attached Geo Scanner.
--   2. Automatically calibrates the Turtle's Home offset relative to the Geo Scanner
--      (by detecting the Turtle block in the scan when at Home, and persisting it).
--   3. Passes the Ore locations (and forbidden Base block coordinates) to the Turtle
--      remotely over the Ender Modem.
--   4. Displays live status of both the Base Geo Scanner and the remote Turtle, and allows
--      starting/stopping the Turtle remotely.

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

local function loadOres()
    local ok, res = pcall(dofile, "controller/lib/ores/main.lua")
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/controller/lib/ores/main.lua")
    if ok2 then return res2 end
    local ok3, res3 = pcall(require, "geoscanner")
    if ok3 then return res3 end
    error("Could not load ores library")
end

local GeoScanner = loadOres()

local BASE_CONFIG_FILE = "/base_config.cfg"

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
-- BaseComputer Class
--------------------------------------------------------------------------------

local BaseComputer = {}
BaseComputer.__index = BaseComputer

function BaseComputer.new(opts)
    opts = opts or {}
    local self = setmetatable({}, BaseComputer)

    self.configFile = opts.configFile or BASE_CONFIG_FILE
    local saved = loadConfigFile(self.configFile) or {}

    self.running = saved.running ~= false
    self.keepProgramAlive = true
    self.scanRadius = tonumber(opts.scanRadius) or tonumber(saved.scanRadius) or 8
    self.turtleOffset = {
        x = tonumber(opts.turtleOffsetX or saved.turtleOffsetX) or 0,
        y = tonumber(opts.turtleOffsetY or saved.turtleOffsetY) or 0,
        z = tonumber(opts.turtleOffsetZ or saved.turtleOffsetZ) or 0,
        calibrated = (saved.turtleCalibrated == true) or (opts.turtleOffsetX ~= nil),
    }

    self.scanner = opts.scanner or nil
    self.modem = opts.modem or nil
    self.lastOreCount = 0
    self.lastScanTime = 0
    self.batchesSent = 0
    self.lastAction = "Ready. Waiting for Turtle ore requests..."
    self.commandBuffer = ""
    self.turtleStatus = {
        phase = "Unknown",
        x = 0,
        y = 0,
        z = 0,
        fuel = "?",
        usedSlots = 0,
        lastAction = "Waiting for Turtle telemetry...",
    }

    return self
end

function BaseComputer:saveConfig()
    saveConfigFile(self.configFile, {
        running = self.running,
        scanRadius = self.scanRadius,
        turtleOffsetX = self.turtleOffset.x,
        turtleOffsetY = self.turtleOffset.y,
        turtleOffsetZ = self.turtleOffset.z,
        turtleCalibrated = self.turtleOffset.calibrated,
    })
end

function BaseComputer:ensureScanner()
    if self.scanner then
        return self.scanner
    end
    local s, err = GeoScanner.find()
    if s then
        self.scanner = s
        return s
    end
    self.lastAction = err or "No Geo Scanner attached to Base Computer"
    return nil, err
end

function BaseComputer:ensureModem()
    if self.modem and GeoScanner.isModemPeripheral(self.modem) then
        return self.modem
    end
    local m, err = GeoScanner.findModem()
    if m then
        self.modem = m
        return m
    end
    self.lastAction = err or "No Ender Modem attached to Base Computer"
    return nil, err
end

--- Scan using the Base Computer's Geo Scanner and build the ore locations + forbidden base blocks
-- relative to the Turtle's Home position.
function BaseComputer:scanAndBuildOrePayload(requestedRadius)
    local scanner, err = self:ensureScanner()
    if not scanner then
        return nil, err
    end

    local radius = math.max(1, math.floor(tonumber(requestedRadius) or self.scanRadius or 8))
    local scannedBlocks, scanErr = scanner:scan(radius, {
        retries = 5,
        retryDelay = 0.5,
    })
    if not scannedBlocks then
        self.lastAction = "Scan error: " .. tostring(scanErr)
        return nil, scanErr
    end

    -- 1. Detect the Turtle's Home position relative to the Geo Scanner if the Turtle is at the base
    local closestTurtle = nil
    for _, b in ipairs(scannedBlocks) do
        if GeoScanner.isTurtleBlockName(b.name) and b.dist <= 6 then
            if not closestTurtle or b.dist < closestTurtle.dist then
                closestTurtle = b
            end
        end
    end
    if closestTurtle then
        self.turtleOffset.x = closestTurtle.x
        self.turtleOffset.y = closestTurtle.y
        self.turtleOffset.z = closestTurtle.z
        self.turtleOffset.calibrated = true
        self:saveConfig()
    end

    local offX = self.turtleOffset.x or 0
    local offY = self.turtleOffset.y or 0
    local offZ = self.turtleOffset.z or 0

    -- 2. Collect all forbidden base blocks and all ore locations adjusted to Turtle Home coordinates
    local baseBlocks = {
        -- The Geo Scanner itself is at (0,0,0) in scanner space -> (-offX, -offY, -offZ) from Turtle Home
        {
            name = "advancedperipherals:geo_scanner",
            x = -offX,
            y = -offY,
            z = -offZ,
        },
    }
    local ores = {}

    for _, b in ipairs(scannedBlocks) do
        local relX = b.x - offX
        local relY = b.y - offY
        local relZ = b.z - offZ
        local isTurtleHomeSpot = (relX == 0 and relY == 0 and relZ == 0)

        if GeoScanner.isProtectedBlockName(b.name) then
            if not isTurtleHomeSpot then
                table.insert(baseBlocks, {
                    name = b.name,
                    x = relX,
                    y = relY,
                    z = relZ,
                })
            end
        elseif GeoScanner.hasOreTag(b) or GeoScanner.isOre(b) then
            local distFromHome = math.abs(relX) + math.abs(relY) + math.abs(relZ)
            table.insert(ores, {
                name = b.name,
                shortName = b.shortName,
                prettyName = b.prettyName,
                x = relX,
                y = relY,
                z = relZ,
                dist = distFromHome,
                tags = b.tags,
            })
        end
    end

    table.sort(ores, function(a, b)
        if a.dist ~= b.dist then
            return a.dist < b.dist
        end
        return (a.shortName or "") < (b.shortName or "")
    end)

    self.lastOreCount = #ores
    return {
        protocol = GeoScanner.PROTOCOL,
        type = "ore_locations",
        ores = ores,
        baseBlocks = baseBlocks,
        turtleOffset = { x = offX, y = offY, z = offZ },
        scanRadius = radius,
        running = self.running,
    }
end

--- Scan and transmit the ore locations to the Turtle over the Ender Modem.
function BaseComputer:sendOreLocations(requestedRadius)
    local modem, mErr = self:ensureModem()
    if not modem then
        return nil, mErr
    end

    local payload, sErr = self:scanAndBuildOrePayload(requestedRadius)
    if not payload then
        GeoScanner.transmitMessage(modem, {
            type = "ore_locations",
            ores = {},
            baseBlocks = {},
            error = tostring(sErr or "Scan failed"),
            running = self.running,
        })
        return nil, sErr
    end

    GeoScanner.transmitMessage(modem, payload)
    self.batchesSent = self.batchesSent + 1
    self.lastAction = ("Sent %d ore location(s) to Turtle (r=%d)"):format(#payload.ores, payload.scanRadius)
    return payload
end

--- Send a remote command (`"start"`, `"stop"`, `"return"`) to the Turtle.
function BaseComputer:sendTurtleCommand(cmd)
    local modem = self:ensureModem()
    if not modem then
        return false
    end
    return GeoScanner.transmitMessage(modem, {
        type = "command",
        command = cmd,
    })
end

--- Process an incoming MinerHaven modem packet from the Turtle.
function BaseComputer:handleModemMessage(msg)
    if type(msg) ~= "table" then
        return nil
    end

    if type(msg.turtleStatus) == "table" then
        for k, v in pairs(msg.turtleStatus) do
            self.turtleStatus[k] = v
        end
    end

    if msg.type == "request_ores" then
        self.lastAction = "Turtle requested ores! Scanning..."
        return self:sendOreLocations(msg.radius or self.scanRadius)
    elseif msg.type == "turtle_status" then
        if msg.phase then self.turtleStatus.phase = msg.phase end
        if msg.x then self.turtleStatus.x = msg.x end
        if msg.y then self.turtleStatus.y = msg.y end
        if msg.z then self.turtleStatus.z = msg.z end
        if msg.fuel then self.turtleStatus.fuel = msg.fuel end
        if msg.usedSlots then self.turtleStatus.usedSlots = msg.usedSlots end
        if msg.lastAction then self.turtleStatus.lastAction = msg.lastAction end
        return true
    end
    return nil
end

function BaseComputer:start()
    self.running = true
    self:saveConfig()
    self:sendTurtleCommand("start")
    self:sendOreLocations(self.scanRadius)
end

function BaseComputer:stop()
    self.running = false
    self:saveConfig()
    self:sendTurtleCommand("stop")
    self.lastAction = "Sent STOP to Turtle."
end

--------------------------------------------------------------------------------
-- TUI Display & Command Loop
--------------------------------------------------------------------------------

function BaseComputer:drawUI()
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

    line(1, " MinerHaven Base Computer (Geo Scanner)", colors.white, isColor and colors.blue or colors.black)
    local statusStr = self.running and "ACTIVE (Serving Ores)" or "PAUSED"
    line(2, (" Base   : %s | Radius: %d"):format(statusStr, self.scanRadius), self.running and colors.lime or colors.yellow, colors.black)
    line(3, (" Ores   : %d in last scan | Batches: %d"):format(self.lastOreCount, self.batchesSent), colors.cyan, colors.black)
    line(4, (" Offset : Turtle at (%+d, %+d, %+d) from Scanner"):format(
        self.turtleOffset.x, self.turtleOffset.y, self.turtleOffset.z
    ), colors.lightGray, colors.black)
    line(5, " " .. string.rep("-", math.max(1, w - 2)), colors.gray, colors.black)
    line(6, (" Turtle : %s | Fuel: %s | Inv: %s/16"):format(
        tostring(self.turtleStatus.phase or "Unknown"),
        tostring(self.turtleStatus.fuel or "?"),
        tostring(self.turtleStatus.usedSlots or 0)
    ), colors.white, colors.black)
    line(7, (" T-Pos  : (%d, %d, %d)"):format(
        tonumber(self.turtleStatus.x) or 0,
        tonumber(self.turtleStatus.y) or 0,
        tonumber(self.turtleStatus.z) or 0
    ), colors.lightGray, colors.black)
    line(8, " " .. tostring(self.turtleStatus.lastAction or ""), colors.orange, colors.black)
    line(9, " " .. string.rep("-", math.max(1, w - 2)), colors.gray, colors.black)
    line(10, " " .. tostring(self.lastAction or ""), colors.yellow, colors.black)
    line(11, " Commands: start | stop | scan | radius <r> | shell", colors.lightGray, colors.black)
    if h >= 13 then
        line(h - 1, " [START]   [STOP]   [SCAN]   [RAD -] [RAD +]", colors.black, isColor and colors.lightGray or colors.white)
    end
    line(h, " > " .. self.commandBuffer .. "_", colors.white, colors.black)
end

function BaseComputer:executeCommand(rawCmd)
    local cmd = tostring(rawCmd or ""):match("^%s*(.-)%s*$"):lower()
    if cmd == "" then
        return
    end
    if cmd == "start" or cmd == "run" or cmd == "go" then
        self:start()
    elseif cmd == "stop" or cmd == "pause" then
        self:stop()
    elseif cmd == "scan" then
        self:sendOreLocations(self.scanRadius)
    elseif cmd:match("^radius%s+(%d+)") then
        local r = tonumber(cmd:match("^radius%s+(%d+)"))
        if r and r >= 1 and r <= 32 then
            self.scanRadius = r
            self:saveConfig()
            self.lastAction = ("Scan radius set to %d"):format(r)
        end
    elseif cmd == "return" or cmd == "home" then
        self:sendTurtleCommand("return")
        self.lastAction = "Sent RETURN HOME to Turtle."
    elseif cmd == "shell" or cmd == "exit" or cmd == "quit" then
        self.keepProgramAlive = false
    else
        self.lastAction = "Unknown cmd '" .. cmd .. "' (start/stop/scan/radius)"
    end
end

function BaseComputer:runDaemon()
    self:ensureModem()
    self:ensureScanner()
    self:drawUI()

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
                elseif p2 >= 21 and p2 <= 26 then
                    self:sendOreLocations(self.scanRadius)
                elseif p2 >= 30 and p2 <= 36 then
                    self.scanRadius = math.max(1, self.scanRadius - 1)
                    self:saveConfig()
                elseif p2 >= 38 and p2 <= 44 then
                    self.scanRadius = math.min(32, self.scanRadius + 1)
                    self:saveConfig()
                end
                self:drawUI()
            end
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

if #args == 1 and args[1] == "base_computer" and package and package.loaded then
    return BaseComputer
end

local base = BaseComputer.new()

if #args > 0 then
    local sub = tostring(args[1]):lower()
    if sub == "start" then
        base:start()
        print("[MinerHaven] Base Computer STARTED & sent ore locations to Turtle.")
        if args[2] == "--bg" or args[2] == "--signal-only" then
            return BaseComputer
        end
        base:runDaemon()
        return BaseComputer
    elseif sub == "stop" then
        base:stop()
        print("[MinerHaven] Sent STOP command to Turtle.")
        if args[2] == "--bg" or args[2] == "--signal-only" then
            return BaseComputer
        end
        base:runDaemon()
        return BaseComputer
    elseif sub == "scan" then
        local payload, err = base:sendOreLocations(tonumber(args[2]) or base.scanRadius)
        if payload then
            print(("[MinerHaven] Sent %d ore location(s) to Turtle."):format(#payload.ores))
        else
            print("[MinerHaven] Scan failed: " .. tostring(err))
        end
        return BaseComputer
    elseif sub == "help" or sub == "-h" or sub == "--help" then
        print("MinerHaven Base Computer")
        print("Usage:")
        print("  base               Run Base Computer daemon")
        print("  base start         Start Turtle & send ore locations")
        print("  base stop          Stop Turtle and return it Home")
        print("  base scan [radius] Scan & send ore locations now")
        return BaseComputer
    end
end

base:runDaemon()
return BaseComputer
