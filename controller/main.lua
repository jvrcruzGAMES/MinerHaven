--- controller/main.lua - Main Entrypoint for MinerHaven Base Computer Controller
-- Initializes controller subsystems, network, pairing, and starts the TUI dashboard.

local function setupPackagePath()
    local paths = {
        "?.lua",
        "?/init.lua",
        "lib/?.lua",
        "controller/?.lua",
        "controller/lib/?.lua",
        "/?.lua",
        "/lib/?.lua",
        "/controller/?.lua",
        "/controller/lib/?.lua",
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

local Controller = loadFile("controller/controller.lua")
local Dashboard = loadFile("controller/dashboard.lua")

local function main()
    local ctrl = Controller.new()
    ctrl:init()

    local dash = Dashboard.new(ctrl)
    dash:run()
end

local ok, err = pcall(main)
if not ok then
    term.clear()
    term.setCursorPos(1, 1)
    if term.setTextColor and colors then term.setTextColor(colors.red) end
    print("MinerHaven Controller crashed:")
    print(tostring(err))
    print("")
    print("Press any key to exit...")
    if os.pullEvent then os.pullEvent("key") end
end
