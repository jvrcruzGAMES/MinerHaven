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

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Device = loadFile("worker/lib/device/main.lua")
local Pairing = loadFile("worker/pairing.lua")
local Worker = loadFile("worker/worker.lua")

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
