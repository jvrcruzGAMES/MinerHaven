--- controller/dashboard.lua - TUI Dashboard for MinerHaven Controller
-- Renders real-time telemetry, buttons, logs, and accepts interactive commands / hotkeys.

local Dashboard = {}
Dashboard.__index = Dashboard

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local PairingHandler = loadFile("controller/pairing.lua")

function Dashboard.new(controller)
    local self = setmetatable({}, Dashboard)
    self.controller = controller
    self.commandBuffer = ""
    self.statusMessage = ""
    self.buttons = {
        { text = "[START]", action = "start", x1 = 2, x2 = 9 },
        { text = "[STOP]",  action = "stop",  x1 = 11, x2 = 17 },
        { text = "[SCAN]",  action = "scan",  x1 = 19, x2 = 25 },
        { text = "[RAD-]",  action = "rad-",  x1 = 27, x2 = 33 },
        { text = "[RAD+]",  action = "rad+",  x1 = 35, x2 = 41 },
        { text = "[PAIR]",  action = "pair",  x1 = 43, x2 = 49 },
    }
    return self
end

local function drawText(x, y, text, fg, bg)
    if not term then return end
    if fg and term.setTextColor then pcall(term.setTextColor, fg) end
    if bg and term.setBackgroundColor then pcall(term.setBackgroundColor, bg) end
    term.setCursorPos(x, y)
    term.write(text)
end

function Dashboard:render()
    if not term then return end
    local w, h = term.getSize()
    term.clear()

    local bgCol = colors and colors.black or 32768
    local bannerBg = colors and colors.blue or 2048
    local bannerFg = colors and colors.white or 1
    local titleFg = colors and colors.yellow or 16
    local labelFg = colors and colors.lightBlue or 8
    local valFg = colors and colors.white or 1
    local alertFg = colors and colors.red or 16384
    local greenFg = colors and colors.green or 8192
    local grayFg = colors and colors.gray or 128
    local btnBg = colors and colors.gray or 128
    local btnFg = colors and colors.black or 32768

    -- Header Banner
    drawText(1, 1, string.rep(" ", w), bannerFg, bannerBg)
    drawText(2, 1, "MinerHaven Controller (Geo Scanner)", bannerFg, bannerBg)

    -- Status Section
    local isRunning = self.controller.config.running
    local stateText = isRunning and "ACTIVE" or "PAUSED"
    local stateFg = isRunning and greenFg or alertFg

    drawText(2, 3, "Controller : ", labelFg, bgCol)
    drawText(15, 3, stateText, stateFg, bgCol)
    drawText(25, 3, string.format("| Authoritative Radius: %d", self.controller.config.scanRadius or 12), valFg, bgCol)

    drawText(2, 4, "Ores       : ", labelFg, bgCol)
    drawText(15, 4, string.format("%d in last scan | Batches sent: %d", self.controller.lastScanOres, self.controller.batchesSent), valFg, bgCol)

    local off = self.controller.ores.turtleOffset
    drawText(2, 5, "Offset     : ", labelFg, bgCol)
    local calibStr = off.calibrated and "Calibrated" or "Default"
    drawText(15, 5, string.format("Turtle at (%+d, %+d, %+d) [%s]", off.x or 0, off.y or 0, off.z or 0, calibStr), valFg, bgCol)

    -- Divider
    drawText(1, 6, string.rep("-", w), grayFg, bgCol)

    -- Paired Workers Telemetry Section
    local y = 7
    local hasWorkers = false
    for wId, wInfo in pairs(self.controller.workers) do
        hasWorkers = true
        local tel = wInfo.telemetry or {}
        local phase = tel.phase or "Idle"
        local phaseFg = (phase:lower():find("min") or phase:lower():find("run")) and greenFg or valFg

        drawText(2, y, string.format("Worker %d   : ", wId), titleFg, bgCol)
        drawText(15, y, phase, phaseFg, bgCol)
        drawText(28, y, string.format("| Fuel: %s | Inv: %s/16", tostring(tel.fuel or "?"), tostring(tel.usedSlots or 0)), valFg, bgCol)

        y = y + 1
        drawText(2, y, "Position   : ", labelFg, bgCol)
        drawText(15, y, string.format("(%+d, %+d, %+d)", tel.x or 0, tel.y or 0, tel.z or 0), valFg, bgCol)

        y = y + 1
        drawText(2, y, "Activity   : ", labelFg, bgCol)
        local act = tel.lastAction or "Idle"
        if #act > w - 16 then act = act:sub(1, w - 19) .. "..." end
        drawText(15, y, act, grayFg, bgCol)

        y = y + 1
        if y >= h - 4 then break end
    end

    if not hasWorkers then
        drawText(2, y, "No Paired Workers.", alertFg, bgCol)
        drawText(2, y + 1, "Click [PAIR] or type 'pair' to connect a Turtle Worker.", grayFg, bgCol)
        y = y + 2
    end

    -- Divider
    drawText(1, h - 3, string.rep("-", w), grayFg, bgCol)

    -- Log line
    local log = self.controller.lastLog or "Ready."
    if #log > w - 3 then log = log:sub(1, w - 6) .. "..." end
    drawText(2, h - 2, log, valFg, bgCol)

    -- Button Row
    for _, btn in ipairs(self.buttons) do
        if btn.x2 <= w then
            drawText(btn.x1, h - 1, btn.text, btnFg, btnBg)
        end
    end

    -- Command Prompt
    drawText(1, h, "> " .. self.commandBuffer, valFg, bgCol)
    term.setCursorPos(3 + #self.commandBuffer, h)
end

function Dashboard:executeAction(action)
    if action == "start" then
        self.controller:startWorkers()
    elseif action == "stop" then
        self.controller:stopWorkers()
    elseif action == "scan" then
        self.controller:sendOreLocations()
    elseif action == "rad+" then
        local r = self.controller:setScanRadius((self.controller.config.scanRadius or 12) + 1)
        self.controller:sendOreLocations()
    elseif action == "rad-" then
        local r = self.controller:setScanRadius((self.controller.config.scanRadius or 12) - 1)
        self.controller:sendOreLocations()
    elseif action == "pair" then
        PairingHandler.runInteractive(self.controller.net)
        -- Reload sessions after pairing
        self.controller:init()
    end
end

function Dashboard:handleCommand(cmd)
    cmd = cmd:gsub("^%s+", ""):gsub("%s+$", "")
    if cmd == "" then return end

    local parts = {}
    for word in cmd:gmatch("%S+") do
        table.insert(parts, word)
    end
    local root = parts[1]:lower()

    if root == "start" then
        self:executeAction("start")
    elseif root == "stop" then
        self:executeAction("stop")
    elseif root == "scan" then
        self:executeAction("scan")
    elseif root == "radius" or root == "rad" then
        local val = tonumber(parts[2])
        if val then
            self.controller:setScanRadius(val)
            self.controller:sendOreLocations()
        else
            self.controller.lastLog = "Usage: radius <number 1-32>"
        end
    elseif root == "pair" then
        self:executeAction("pair")
    elseif root == "workers" then
        local list = {}
        for id, _ in pairs(self.controller.workers) do table.insert(list, tostring(id)) end
        self.controller.lastLog = "Paired Workers: " .. (table.concat(list, ", ") or "None")
    elseif root == "quit" or root == "exit" then
        return "quit"
    else
        self.controller.lastLog = "Unknown command: " .. root .. " (start, stop, scan, radius <r>, pair, quit)"
    end
end

function Dashboard:handleMouseClick(button, x, y)
    local w, h = term.getSize()
    if y == h - 1 then
        for _, btn in ipairs(self.buttons) do
            if x >= btn.x1 and x <= btn.x2 then
                self:executeAction(btn.action)
                return
            end
        end
    end
end

function Dashboard:run()
    self:render()
    local refreshTimer = os.startTimer and os.startTimer(1.0) or nil

    while true do
        self:render()
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == refreshTimer then
            self.controller:step(0.01)
            refreshTimer = os.startTimer(1.0)
        elseif event == "modem_message" then
            -- Let controller process packet
            local side, channel, replyChannel, message = p1, p2, p3, select(4, event, p1, p2, p3)
            local payload, fromId = self.controller.net:unpackPacket(message)
            if payload then
                self.controller:handlePacket(payload, fromId)
            end
        elseif event == "char" then
            self.commandBuffer = self.commandBuffer .. p1
        elseif event == "key" then
            if p1 == keys.enter then
                local res = self:handleCommand(self.commandBuffer)
                self.commandBuffer = ""
                if res == "quit" then break end
            elseif p1 == keys.backspace then
                self.commandBuffer = self.commandBuffer:sub(1, -2)
            end
        elseif event == "mouse_click" then
            self:handleMouseClick(p1, p2, p3)
        end
    end
end

return Dashboard
