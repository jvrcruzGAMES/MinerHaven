--- worker/main.lua - Main Entrypoint for MinerHaven Turtle Worker
-- Checks if paired: if paired, runs headless worker service; otherwise runs pairing mode.

local function setupPackagePath()
    local paths = {
        "?.lua",
        "?/init.lua",
        "lib/?.lua",
        "worker/?.lua",
        "worker/lib/?.lua",
        "/?.lua",
        "/lib/?.lua",
        "/worker/?.lua",
        "/worker/lib/?.lua",
    }
    if package and package.path then
        package.path = table.concat(paths, ";") .. ";" .. package.path
    end
end

setupPackagePath()

local Device = dofile("worker/lib/device/main.lua")
local Pairing = dofile("worker/pairing.lua")
local Worker = dofile("worker/worker.lua")

local function main()
    local isPaired, pCfg = Device.isPaired()
    if not isPaired then
        local pairedCfg, err = Pairing.run()
        if not pairedCfg then
            print("Pairing not completed. Worker cannot start.")
            return
        end
    end

    local worker = Worker.new()
    worker:run()
end

local ok, err = pcall(main)
if not ok then
    term.clear()
    term.setCursorPos(1, 1)
    if term.setTextColor and colors then term.setTextColor(colors.red) end
    print("MinerHaven Worker crashed:")
    print(tostring(err))
    print("")
    print("Press any key to exit...")
    if os.pullEvent then os.pullEvent("key") end
end
