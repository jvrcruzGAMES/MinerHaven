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
local Updater = loadFile("controller/lib/updater/main.lua")

local function checkStartupUpdate()
    if not http then return false end
    if term and term.clear then
        term.clear()
        term.setCursorPos(1, 1)
    end
    local currentVer = Updater.getLocalVersion()
    if term and term.setTextColor and colors then term.setTextColor(colors.cyan) end
    print(string.format("MinerHaven Controller v%s", tostring(currentVer)))
    if term and term.setTextColor and colors then term.setTextColor(colors.lightGray) end
    print("Checking for updates from GitHub...")

    local hasUpdate, latestVer, currVer, info = Updater.checkForUpdates()
    if hasUpdate then
        if term and term.setTextColor and colors then term.setTextColor(colors.yellow) end
        print("")
        print(string.format("--> Update available: v%s (Current: v%s)", tostring(latestVer), tostring(currVer)))
        if term and term.setTextColor and colors then term.setTextColor(colors.white) end
        write("Would you like to update now? (Y/n): ")
        local ans = (read and type(read) == "function") and read() or "n"
        ans = tostring(ans or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if ans == "" or ans:sub(1, 1) == "y" then
            if term and term.setTextColor and colors then term.setTextColor(colors.yellow) end
            print("Updating controller and worker firmware from GitHub...")
            local ok, err = Updater.updateController()
            if ok then
                if term and term.setTextColor and colors then term.setTextColor(colors.lime) end
                print("Update successful! Rebooting...")
                if os.sleep then os.sleep(1.5) end
                if os.reboot then os.reboot() end
                return true
            else
                if term and term.setTextColor and colors then term.setTextColor(colors.red) end
                print("Update failed: " .. tostring(err))
                print("Press any key to continue to dashboard...")
                if os.pullEvent then os.pullEvent("key") end
            end
        end
    else
        -- Ensure worker firmware is bundled locally in firmware/worker/
        local fw = Updater.loadWorkerFirmware()
        local fwCount = 0
        for _ in pairs(fw) do fwCount = fwCount + 1 end
        if fwCount == 0 and http then
            pcall(Updater.downloadWorkerFirmware)
        end
    end
    return false
end

local function main()
    pcall(checkStartupUpdate)

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
