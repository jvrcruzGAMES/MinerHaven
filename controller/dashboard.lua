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
local Updater = loadFile("controller/lib/updater/main.lua")

function Dashboard.new(controller)
    local self = setmetatable({}, Dashboard)
    self.controller = controller
    self.commandBuffer = ""
    self.statusMessage = ""
    self.dynamicButtons = {}
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
    local verStr = tostring(self.controller and self.controller.version or "1.3.0"):gsub("^v", "")
    drawText(2, 1, string.format("MinerHaven Controller (v%s)", verStr), bannerFg, bannerBg)

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
    self.dynamicButtons = {}
    for wId, wInfo in pairs(self.controller.workers) do
        hasWorkers = true
        local tel = wInfo.telemetry or {}
        local phase = tel.phase or "Idle"
        local phaseFg = (phase:lower():find("min") or phase:lower():find("run")) and greenFg or valFg

        drawText(2, y, string.format("Worker %s   : ", tostring(wId)), titleFg, bgCol)
        drawText(15, y, phase, phaseFg, bgCol)
        drawText(28, y, string.format("| Fuel: %s | Inv: %s/16", tostring(tel.fuel or "?"), tostring(tel.usedSlots or 0)), valFg, bgCol)

        y = y + 1
        drawText(2, y, "Position   : ", labelFg, bgCol)
        drawText(15, y, string.format("(%+d, %+d, %+d)", tel.x or 0, tel.y or 0, tel.z or 0), valFg, bgCol)

        -- Dynamic per-worker buttons: [SET HOME] [UNPAIR] [OTA]
        local btnHomeText = "[SET HOME]"
        local btnUnpairText = "[UNPAIR]"
        local btnOtaText = "[OTA]"
        if w >= 50 then
            local btnHomeX = 25
            local btnUnpairX = 36
            local btnOtaX = 45
            drawText(btnHomeX, y, btnHomeText, btnFg, btnBg)
            table.insert(self.dynamicButtons, {
                x1 = btnHomeX,
                x2 = btnHomeX + #btnHomeText - 1,
                y = y,
                action = "sethome",
                workerId = wId,
            })
            drawText(btnUnpairX, y, btnUnpairText, alertFg, btnBg)
            table.insert(self.dynamicButtons, {
                x1 = btnUnpairX,
                x2 = btnUnpairX + #btnUnpairText - 1,
                y = y,
                action = "unpair",
                workerId = wId,
            })
            drawText(btnOtaX, y, btnOtaText, colors and colors.lime or 32, btnBg)
            table.insert(self.dynamicButtons, {
                x1 = btnOtaX,
                x2 = btnOtaX + #btnOtaText - 1,
                y = y,
                action = "ota",
                workerId = wId,
            })
        else
            y = y + 1
            local btnHomeX = 2
            local btnUnpairX = 13
            local btnOtaX = 22
            drawText(btnHomeX, y, btnHomeText, btnFg, btnBg)
            table.insert(self.dynamicButtons, {
                x1 = btnHomeX,
                x2 = btnHomeX + #btnHomeText - 1,
                y = y,
                action = "sethome",
                workerId = wId,
            })
            drawText(btnUnpairX, y, btnUnpairText, alertFg, btnBg)
            table.insert(self.dynamicButtons, {
                x1 = btnUnpairX,
                x2 = btnUnpairX + #btnUnpairText - 1,
                y = y,
                action = "unpair",
                workerId = wId,
            })
            drawText(btnOtaX, y, btnOtaText, colors and colors.lime or 32, btnBg)
            table.insert(self.dynamicButtons, {
                x1 = btnOtaX,
                x2 = btnOtaX + #btnOtaText - 1,
                y = y,
                action = "ota",
                workerId = wId,
            })
        end

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
        local targetId = tonumber(parts[2]) or parts[2]
        if targetId then
            self.controller:setWorkerDesiredState(targetId, "MINING")
        else
            self:executeAction("start")
        end
    elseif root == "stop" then
        local targetId = tonumber(parts[2]) or parts[2]
        if targetId then
            self.controller:setWorkerDesiredState(targetId, "STOPPED")
        else
            self:executeAction("stop")
        end
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
    elseif root == "sethome" then
        local targetId = tonumber(parts[2]) or parts[2]
        if not targetId then
            local count = 0
            local onlyId = nil
            for id, _ in pairs(self.controller.workers) do
                count = count + 1
                onlyId = id
            end
            if count == 1 then
                targetId = onlyId
            end
        end
        if targetId then
            self.controller:setWorkerHome(targetId)
        else
            self.controller.lastLog = "Usage: sethome <workerId>"
        end
    elseif root == "unpair" then
        local targetId = tonumber(parts[2]) or parts[2]
        if not targetId then
            local count = 0
            local onlyId = nil
            for id, _ in pairs(self.controller.workers) do
                count = count + 1
                onlyId = id
            end
            if count == 1 then
                targetId = onlyId
            end
        end
        if targetId then
            self.controller:unpairWorker(targetId)
        else
            self.controller.lastLog = "Usage: unpair <workerId>"
        end
    elseif root == "ota" then
        local targetId = tonumber(parts[2]) or parts[2]
        if not targetId then
            local count = 0
            local onlyId = nil
            for id, _ in pairs(self.controller.workers) do
                count = count + 1
                onlyId = id
            end
            if count == 1 then targetId = onlyId end
        end
        if targetId then
            self.controller.lastLog = "Initiating OTA update for Worker " .. tostring(targetId) .. "..."
            self:render()
            local function onProgress(fIdx, totalF, path, cIdx, totalC)
                local pct = math.floor((((fIdx - 1) + (cIdx / totalC)) / totalF) * 100)
                self.controller.lastLog = string.format("OTA -> Worker %s: [%d%%] %s (%d/%d)", tostring(targetId), pct, path, cIdx, totalC)
                self:render()
            end
            local ok, msg = Updater.sendOTAUpdate(self.controller.net, targetId, nil, onProgress)
            self.controller.lastLog = msg
        else
            local sent = 0
            for id, _ in pairs(self.controller.workers) do
                local function onProgress(fIdx, totalF, path, cIdx, totalC)
                    local pct = math.floor((((fIdx - 1) + (cIdx / totalC)) / totalF) * 100)
                    self.controller.lastLog = string.format("OTA -> Worker %s: [%d%%] %s", tostring(id), pct, path)
                    self:render()
                end
                Updater.sendOTAUpdate(self.controller.net, id, nil, onProgress)
                sent = sent + 1
            end
            self.controller.lastLog = string.format("Broadcasted OTA update to %d worker(s).", sent)
        end
    elseif root == "flash" then
        local side = parts[2] or "right"
        self.controller.lastLog = "Flashing worker firmware to " .. side .. "..."
        self:render()
        local ok, msg = Updater.flashSide(side)
        self.controller.lastLog = msg
    elseif root == "update" then
        self.controller.lastLog = "Checking GitHub Releases for updates..."
        self:render()
        local hasUpdate, latestVer, currVer = Updater.checkForUpdates()
        if hasUpdate then
            self.controller.lastLog = "Updating to v" .. tostring(latestVer) .. "..."
            self:render()
            local ok, err = Updater.updateController()
            if ok then
                self.controller.lastLog = "Update succeeded! Rebooting in 2s..."
                self:render()
                if os.sleep then os.sleep(2) end
                if os.reboot then os.reboot() end
            else
                self.controller.lastLog = "Update failed: " .. tostring(err)
            end
        else
            self.controller.lastLog = "System is already on latest version (v" .. tostring(currVer) .. ")"
        end
    elseif root == "quit" or root == "exit" then
        return "quit"
    else
        self.controller.lastLog = "Commands: start, stop, scan, rad <r>, sethome [id], unpair [id], ota [id], flash <side>, update, quit"
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

    -- Check dynamic per-worker buttons
    for _, btn in ipairs(self.dynamicButtons or {}) do
        if y == btn.y and x >= btn.x1 and x <= btn.x2 then
            if btn.action == "sethome" then
                self.controller:setWorkerHome(btn.workerId)
            elseif btn.action == "unpair" then
                self.controller:unpairWorker(btn.workerId)
            elseif btn.action == "ota" then
                self.controller.lastLog = "Initiating OTA update for Worker " .. tostring(btn.workerId) .. "..."
                self:render()
                local function onProgress(fIdx, totalF, path, cIdx, totalC)
                    local pct = math.floor((((fIdx - 1) + (cIdx / totalC)) / totalF) * 100)
                    self.controller.lastLog = string.format("OTA -> Worker %s: [%d%%] %s (%d/%d)", tostring(btn.workerId), pct, path, cIdx, totalC)
                    self:render()
                end
                local ok, msg = Updater.sendOTAUpdate(self.controller.net, btn.workerId, nil, onProgress)
                self.controller.lastLog = msg
            end
            return
        end
    end
end

function Dashboard:run()
    self:render()
    local refreshTimer = os.startTimer and os.startTimer(1.0) or nil

    while true do
        self:render()
        local event, p1, p2, p3, p4, p5 = os.pullEvent()

        if event == "timer" and p1 == refreshTimer then
            refreshTimer = os.startTimer(1.0)
        elseif event == "modem_message" then
            local side, channel, replyChannel, message, distance = p1, p2, p3, p4, p5
            if channel == self.controller.net.channel then
                local payload, fromId, err = self.controller.net:unpackPacket(message)
                if payload then
                    self.controller:handlePacket(payload, fromId)
                end
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
