--- worker/pairing.lua - Interactive & Headless Pairing Handler for Worker Turtle
-- Generates and renders a 6-digit numeric pairing code on the turtle display, then establishes session.

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Device = loadFile("worker/lib/device/main.lua")
local Workernet = loadFile("lib/workernet/main.lua")
local Crypto = loadFile("lib/crypto/main.lua")

local WorkerPairing = {}

function WorkerPairing.run(net)
    if not net then
        net = Workernet.new()
        net:open()
    end

    local localId = net.localId
    local currentPairCode = ""

    local function draw(code, status)
        if not term then return end
        term.clear()
        term.setCursorPos(1, 1)

        local w, h = term.getSize()
        local function pCenter(y, text, fg)
            if term.setTextColor and fg and colors then pcall(term.setTextColor, fg) end
            local x = math.max(1, math.floor((w - #text) / 2) + 1)
            term.setCursorPos(x, y)
            term.write(text)
        end

        pCenter(2, "MinerHaven Worker", colors and colors.yellow or 16)
        pCenter(3, "=== PAIRING MODE ===", colors and colors.white or 1)

        pCenter(5, "Worker ID: " .. tostring(localId), colors and colors.lightBlue or 8)

        pCenter(7, "PAIRING CODE:", colors and colors.gray or 128)
        local formatted = Crypto.formatPairCode(code or currentPairCode or "------")
        pCenter(8, "[ " .. formatted .. " ]", colors and colors.green or 8192)

        pCenter(10, status or "Waiting for Controller...", colors and colors.yellow or 16)

        pCenter(12, "Enter this 6-digit code on the", colors and colors.gray or 128)
        pCenter(13, "Base Computer Dashboard [PAIR]", colors and colors.gray or 128)
    end

    local ok, res = Device.pair(net, function(code)
        currentPairCode = code
        draw(code, "Awaiting pairing handshake...")
    end, 300)

    if ok then
        draw(currentPairCode, "SUCCESSFULLY PAIRED!")
        if term and term.setCursorPos then
            term.setCursorPos(2, 11)
            print("Paired with Controller ID: " .. tostring(res.controller_id))
        end
        if os.sleep then os.sleep(2) end
        return res
    else
        draw(currentPairCode, "PAIRING TIMED OUT / FAILED")
        if os.sleep then os.sleep(2) end
        return nil, res
    end
end

if shell and shell.getRunningProgram and shell.getRunningProgram():find("pairing.lua") then
    WorkerPairing.run()
end

return WorkerPairing
