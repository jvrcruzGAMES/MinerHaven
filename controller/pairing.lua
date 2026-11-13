--- controller/pairing.lua - Interactive Pairing Handler for Controller
-- Prompts operator for 6-digit pairing code displayed on the turtle screen and establishes session.

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Pairing = loadFile("controller/lib/pairing/main.lua")
local Workernet = loadFile("lib/workernet/main.lua")
local Crypto = loadFile("lib/crypto/main.lua")

local PairingHandler = {}

function PairingHandler.runInteractive(net)
    if not net then
        net = Workernet.new()
        net:open()
    end

    term.clear()
    term.setCursorPos(1, 2)
    print("========================================")
    print("   MinerHaven Controller - Pairing")
    print("========================================")
    print("")
    print("To pair a new Turtle Worker:")
    print(" 1. Ensure the Worker is powered on and")
    print("    displaying a 6-digit pairing code.")
    print(" 2. Enter the 6-digit numeric code below.")
    print("")
    write("Enter 6-digit Pair Code (or 'q' to cancel): ")

    local input = read()
    if not input or input:lower() == "q" or input:gsub("%s", "") == "" then
        print("Pairing cancelled.")
        if os.sleep then os.sleep(1) end
        return nil
    end

    local code, err = Crypto.normalizePairCode(input)
    if not code then
        print("")
        print("Error: " .. tostring(err))
        print("Press any key to return...")
        if os.pullEvent then os.pullEvent("key") end
        return nil
    end

    print("")
    print("Sending encrypted pairing handshake for [" .. Crypto.formatPairCode(code) .. "]...")
    print("Waiting for worker response...")

    local ok, res = Pairing.pair(net, code, 12)
    if ok then
        print("")
        print(">>> SUCCESS! <<<")
        print("Paired with Turtle Worker ID: " .. tostring(res))
        print("Cryptographic session key generated and saved.")
        print("Press any key to continue...")
        if os.pullEvent then os.pullEvent("key") end
        return res
    else
        print("")
        print(">>> PAIRING FAILED <<<")
        print(tostring(res))
        print("Check that turtle has Ender Modem attached and is in pairing mode.")
        print("Press any key to return...")
        if os.pullEvent then os.pullEvent("key") end
        return nil
    end
end

-- Allow running standalone: `controller/pairing.lua`
if shell and shell.getRunningProgram and shell.getRunningProgram():find("pairing.lua") then
    PairingHandler.runInteractive()
end

return PairingHandler
