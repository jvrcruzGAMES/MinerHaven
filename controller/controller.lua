--- Controller Core Logic - MinerHaven
-- Manages paired workers, authoritative GeoScanner scanning, telemetry, and encrypted dispatch.

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Workernet = loadFile("lib/workernet/main.lua")
local Pairing = loadFile("controller/lib/pairing/main.lua")
local Ores = loadFile("controller/lib/ores/main.lua")

local Controller = {}
Controller.__index = Controller
Controller.CONFIG_PATH = "controller/main.cfg"

--- Load configuration file.
function Controller.loadConfig(path)
    path = path or Controller.CONFIG_PATH
    if not fs.exists(path) then
        return {
            channel = 4821,
            pairChannel = 4820,
            scanRadius = 12,
            running = true,
            turtleOffsetX = 1,
            turtleOffsetY = 0,
            turtleOffsetZ = 1,
            turtleCalibrated = false,
        }
    end
    local f = fs.open(path, "r")
    if not f then return {} end
    local content = f.readAll()
    f.close()
    local cfg = Workernet.unserialize(content)
    if type(cfg) == "table" then return cfg end
    return {}
end

--- Save configuration file.
function Controller.saveConfig(cfg, path)
    path = path or Controller.CONFIG_PATH
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(Workernet.serialize(cfg))
    f.close()
    return true
end

--- Create a new Controller instance.
function Controller.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Controller)

    self.config = Controller.loadConfig(opts.configPath)
    if opts.scanRadius then self.config.scanRadius = tonumber(opts.scanRadius) end

    self.net = Workernet.new({
        channel = self.config.channel or 4821,
        pairChannel = self.config.pairChannel or 4820,
    })

    self.ores = Ores.new({
        turtleOffset = {
            x = self.config.turtleOffsetX or 0,
            y = self.config.turtleOffsetY or 0,
            z = self.config.turtleOffsetZ or 0,
            calibrated = self.config.turtleCalibrated or false,
        }
    })

    self.workers = {} -- workerId -> { telemetry = {}, lastSeen = 0 }
    self.lastScanOres = 0
    self.batchesSent = 0
    self.lastLog = "Controller initialized. Authoritative radius: " .. tostring(self.config.scanRadius)

    return self
end

--- Initialize network and restore paired sessions.
function Controller:init()
    local ok, err = self.net:open()
    if not ok then
        self.lastLog = "Net warning: " .. tostring(err)
    end
    local loaded = Pairing.loadSessionsIntoNode(self.net)
    local cfg = Pairing.loadConfig()
    for wId, info in pairs(cfg.workers) do
        local idNum = tonumber(wId)
        self.workers[idNum] = {
            name = info.name or ("Turtle " .. tostring(wId)),
            telemetry = {
                phase = "Paired",
                x = 0, y = 0, z = 0,
                fuel = "?",
                usedSlots = 0,
                lastAction = "Waiting for worker to connect...",
            },
            lastSeen = 0,
        }
    end
    return true
end

--- Save persistent configuration.
function Controller:persist()
    self.config.turtleOffsetX = self.ores.turtleOffset.x
    self.config.turtleOffsetY = self.ores.turtleOffset.y
    self.config.turtleOffsetZ = self.ores.turtleOffset.z
    self.config.turtleCalibrated = self.ores.turtleOffset.calibrated
    Controller.saveConfig(self.config)
end

--- Set authoritative scan radius.
function Controller:setScanRadius(r)
    r = math.max(1, math.min(32, math.floor(tonumber(r) or 12)))
    self.config.scanRadius = r
    self:persist()
    self.lastLog = "Authoritative scan radius set to " .. r
    return r
end

--- Scan and send ore locations to a target worker using AUTHORITATIVE scan radius.
-- Note: requestedRadius from turtles is intentionally ignored to prevent overriding the controller.
function Controller:sendOreLocations(targetWorkerId)
    local radius = self.config.scanRadius or 12
    local ores, baseBlocks, err = self.ores:scanAuthoritative(radius)
    if not ores then
        self.lastLog = "Scan failed: " .. tostring(err)
        return false, err
    end

    self:persist() -- Persist updated turtle calibration if detected
    self.lastScanOres = #ores

    local payload = {
        type = "ore_locations",
        ores = ores,
        baseBlocks = baseBlocks,
        scanRadius = radius,
        running = self.config.running,
        turtleOffset = self.ores.turtleOffset,
    }

    if targetWorkerId then
        local ok, sErr = self.net:send(targetWorkerId, payload)
        if ok then
            self.batchesSent = self.batchesSent + 1
            self.lastLog = string.format("Sent %d ore(s) to Worker %d (r=%d)", #ores, targetWorkerId, radius)
            return true
        else
            self.lastLog = "Send to " .. targetWorkerId .. " failed: " .. tostring(sErr)
            return false, sErr
        end
    else
        -- Send to all paired workers
        local count = 0
        for wId, _ in pairs(self.workers) do
            local ok = self.net:send(wId, payload)
            if ok then count = count + 1 end
        end
        self.batchesSent = self.batchesSent + count
        self.lastLog = string.format("Broadcast %d ore(s) to %d worker(s) (r=%d)", #ores, count, radius)
        return true
    end
end

--- Broadcast command to workers (start, stop, return_home).
function Controller:broadcastCommand(action)
    local payload = {
        type = "command",
        action = action,
        running = self.config.running,
    }
    local count = 0
    for wId, _ in pairs(self.workers) do
        local ok = self.net:send(wId, payload)
        if ok then count = count + 1 end
    end
    self.lastLog = string.format("Command '%s' sent to %d worker(s)", action, count)
    return count
end

--- Start workers.
function Controller:startWorkers()
    self.config.running = true
    self:persist()
    self:broadcastCommand("start")
    self:sendOreLocations()
end

--- Stop workers.
function Controller:stopWorkers()
    self.config.running = false
    self:persist()
    self:broadcastCommand("stop")
end

--- Handle an incoming packet from a worker.
function Controller:handlePacket(payload, fromId)
    if not payload or type(payload) ~= "table" then return end

    if not self.workers[fromId] then
        self.workers[fromId] = {
            name = "Turtle " .. fromId,
            telemetry = {},
            lastSeen = 0,
        }
    end
    self.workers[fromId].lastSeen = os.clock and os.clock() or os.time()

    local pType = payload.type
    if pType == "telemetry" then
        self.workers[fromId].telemetry = {
            phase = payload.phase or "Active",
            x = payload.x or 0,
            y = payload.y or 0,
            z = payload.z or 0,
            fuel = payload.fuel or "?",
            usedSlots = payload.usedSlots or 0,
            lastAction = payload.lastAction or "Working...",
            inventory = payload.inventory or {},
        }
    elseif pType == "request_ores" then
        -- Turtle requested ores. Authoritative radius: ALWAYS use self.config.scanRadius!
        self:sendOreLocations(fromId)
    elseif pType == "status_update" then
        if payload.status then
            self.workers[fromId].telemetry.phase = payload.status
        end
    end
end

--- Step message loop once (non-blocking or short timeout).
function Controller:step(timeout)
    local payload, fromId, channel = self.net:pullMessage(timeout or 0.1)
    if payload and channel == self.net.channel then
        self:handlePacket(payload, fromId)
        return true
    end
    return false
end

return Controller
