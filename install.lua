--- MinerHaven Installer for CC: Tweaked
-- Run directly in CraftOS:
--   wget run https://raw.githubusercontent.com/jvrcruzGAMES/MinerHaven/main/install.lua
--
-- Options:
--   --turtle         Install with Turtle Auto-Miner & Home setup
--   --no-turtle      Install standard Computer/Pocket version without prompting
--   --set-home       Automatically save current turtle position as Home without prompting
--   --lib-only       Only install the reusable /lib/geoscanner.lua library
--   --dir <folder>   Install into a custom directory (default: /)
--   --branch <name>  Git branch to download from (default: main)
--   --startup        Auto-launch MinerHaven on computer startup

local REPO_USER = "jvrcruzGAMES"
local REPO_NAME = "MinerHaven"

local args = { ... }
local libOnly = false
local targetDir = ""
local branch = "main"
local autoStartup = false
local isTurtleInstall = nil -- nil = ask interactively
local setHomePref = nil     -- nil = ask interactively when turtle install is selected
local facingArg = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--lib-only" then
        libOnly = true
    elseif a == "--startup" then
        autoStartup = true
    elseif a == "--turtle" then
        isTurtleInstall = true
    elseif a == "--no-turtle" then
        isTurtleInstall = false
    elseif a == "--set-home" then
        setHomePref = true
    elseif a == "--no-set-home" then
        setHomePref = false
    elseif a == "--facing" and args[i + 1] then
        facingArg = args[i + 1]
        i = i + 1
    elseif a == "--dir" and args[i + 1] then
        targetDir = args[i + 1]
        i = i + 1
    elseif a == "--branch" and args[i + 1] then
        branch = args[i + 1]
        i = i + 1
    end
    i = i + 1
end

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO_USER, REPO_NAME, branch)

local function logInfo(msg)
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.cyan)
    end
    write("[MinerHaven] ")
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.white)
    end
    print(msg)
end

local function logSuccess(msg)
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.lime)
    end
    print("[OK] " .. msg)
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.white)
    end
end

local function logError(msg)
    if _G.printError then
        printError("[ERROR] " .. msg)
    else
        print("[ERROR] " .. msg)
    end
end

local function askYesNo(promptText, defaultYes)
    if type(_G.read) ~= "function" then
        return defaultYes
    end
    local hint = defaultYes and " (Y/n): " or " (y/N): "
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.yellow)
    end
    write("[?] " .. promptText .. hint)
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.white)
    end
    local input = read()
    if type(input) ~= "string" then
        return defaultYes
    end
    local trimmed = input:match("^%s*(.-)%s*$"):lower()
    if trimmed == "" then
        return defaultYes
    end
    if trimmed == "y" or trimmed == "yes" then
        return true
    end
    if trimmed == "n" or trimmed == "no" then
        return false
    end
    return defaultYes
end

local function parseDir(input)
    if type(input) == "string" then
        local c = input:match("^%s*(%a)")
        if c then
            c = c:lower()
            if c == "n" then return 0 end
            if c == "e" then return 1 end
            if c == "s" then return 2 end
            if c == "w" then return 3 end
        end
    end
    return 0
end

local function writeLuaConfig(path, tbl)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local h = fs.open(path, "w")
    if not h then
        return false
    end
    if textutils and type(textutils.serialize) == "function" then
        h.write(textutils.serialize(tbl))
    else
        h.writeLine("{")
        for k, v in pairs(tbl) do
            local valStr = type(v) == "string" and ("%q"):format(v) or tostring(v)
            h.writeLine(("  [%q] = %s,"):format(tostring(k), valStr))
        end
        h.writeLine("}")
    end
    h.close()
    return true
end

if not http then
    logError("The HTTP API is disabled in CC: Tweaked config.")
    logError("Please enable the HTTP API in computercraft-server.toml to use this installer.")
    return
end

local function joinPath(base, rel)
    if not base or base == "" or base == "/" then
        return "/" .. rel:gsub("^/+", "")
    end
    if fs and fs.combine then
        return "/" .. fs.combine(base, rel)
    end
    return base:gsub("/+$", "") .. "/" .. rel:gsub("^/+", "")
end

local function downloadFile(remotePath, localPath)
    local url = BASE_URL .. "/" .. remotePath
    logInfo("Downloading " .. remotePath .. " -> " .. localPath)

    local response, err = http.get(url)
    if not response then
        logError("Failed to download " .. url .. ": " .. tostring(err))
        return false
    end

    local content = response.readAll()
    response.close()

    if not content or content == "" then
        logError("Received empty file from " .. url)
        return false
    end

    local dir = fs.getDir(localPath)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local handle, openErr = fs.open(localPath, "w")
    if not handle then
        logError("Cannot write to " .. localPath .. ": " .. tostring(openErr))
        return false
    end
    handle.write(content)
    handle.close()
    return true
end

logInfo("Starting MinerHaven installation...")

-- Prompt whether this installation is for a Turtle (unless specified via CLI flag or --lib-only)
if not libOnly and isTurtleInstall == nil then
    local defaultTurtle = (_G.turtle ~= nil)
    isTurtleInstall = askYesNo("Is this installation for a Turtle?", defaultTurtle)
end

local files = {
    { remote = "lib/geoscanner.lua", dest = joinPath(targetDir, "lib/geoscanner.lua") },
}

if not libOnly then
    table.insert(files, { remote = "minerhaven.lua", dest = joinPath(targetDir, "minerhaven.lua") })
    if isTurtleInstall then
        table.insert(files, { remote = "turtle_miner.lua", dest = joinPath(targetDir, "turtle_miner.lua") })
    end
end

for _, f in ipairs(files) do
    if not downloadFile(f.remote, f.dest) then
        logError("Installation aborted.")
        return
    end
end

if not libOnly then
    local appPath = joinPath(targetDir, "minerhaven.lua")
    local turtleMinerPath = joinPath(targetDir, "turtle_miner.lua")

    -- If installing for a Turtle, ask to set current location as Home
    if isTurtleInstall then
        local shouldSetHome = setHomePref
        if shouldSetHome == nil then
            shouldSetHome = askYesNo("Set the turtle's current location as its Home?", true)
        end

        if shouldSetHome then
            local gx, gy, gz = nil, nil, nil
            if gps and type(gps.locate) == "function" then
                local ok, x, y, z = pcall(gps.locate, 1.5)
                if ok and x and y and z then
                    gx, gy, gz = math.floor(x), math.floor(y), math.floor(z)
                end
            end

            local dir = 0
            if facingArg then
                dir = parseDir(facingArg)
            elseif type(_G.read) == "function" then
                write("[?] Turtle facing direction (n/e/s/w) [n]: ")
                local dirInput = read()
                dir = parseDir(dirInput)
            end

            local homeData = {
                x = gx or 0,
                y = gy or 0,
                z = gz or 0,
                dir = dir,
                useGps = (gx ~= nil),
            }
            local homeFile = joinPath(targetDir, "home.cfg")
            local posFile = joinPath(targetDir, "turtle_pos.cfg")
            local stateFile = joinPath(targetDir, "minerhaven_state.cfg")

            writeLuaConfig(homeFile, homeData)
            writeLuaConfig(posFile, {
                x = homeData.x,
                y = homeData.y,
                z = homeData.z,
                dir = homeData.dir,
            })
            writeLuaConfig(stateFile, { running = false })

            logSuccess(("Turtle Home saved to %s (%d, %d, %d)"):format(
                homeFile, homeData.x, homeData.y, homeData.z
            ))
        end
    end

    -- Register shell aliases for the current session
    if shell and shell.setAlias then
        shell.setAlias("minerhaven", appPath)
        shell.setAlias("mh", appPath)
        if isTurtleInstall then
            shell.setAlias("miner", turtleMinerPath)
            shell.setAlias("turtle_miner", turtleMinerPath)
        end
    end

    -- Write /startup/99_minerhaven.lua script so aliases and turtle startup program load on boot
    if not fs.exists("/startup") or fs.isDir("/startup") then
        if not fs.exists("/startup") then
            fs.makeDir("/startup")
        end
        local startupScript = "/startup/99_minerhaven.lua"
        local h = fs.open(startupScript, "w")
        if h then
            h.writeLine("-- MinerHaven startup configuration")
            h.writeLine("if shell and shell.setAlias then")
            h.writeLine(("    shell.setAlias('minerhaven', %q)"):format(appPath))
            h.writeLine(("    shell.setAlias('mh', %q)"):format(appPath))
            if isTurtleInstall then
                h.writeLine(("    shell.setAlias('miner', %q)"):format(turtleMinerPath))
                h.writeLine(("    shell.setAlias('turtle_miner', %q)"):format(turtleMinerPath))
            end
            h.writeLine("end")
            if isTurtleInstall then
                h.writeLine(("shell.run(%q)"):format(turtleMinerPath))
            elseif autoStartup then
                h.writeLine(("shell.run(%q)"):format(appPath))
            end
            h.close()
        end
    end

    logSuccess("MinerHaven installed!")
    if isTurtleInstall then
        print("Turtle Auto-Miner installed and configured to load on startup.")
        print("Commands:")
        print("  miner          Launch Turtle Auto-Miner screen")
        print("  miner start    Start mining nearby ores by tag")
        print("  miner stop     Stop mining and stay idle")
        print("  miner sethome  Save current position as Home")
        print("  mh             Open Geo Scanner Radar UI")
    else
        print("Run 'minerhaven' or 'mh' to open the Geo Scanner interface.")
        print("Run 'mh help' for CLI commands, or require('lib.geoscanner') in your own scripts.")
    end
else
    logSuccess("GeoScanner library installed to " .. joinPath(targetDir, "lib/geoscanner.lua"))
    print("Use: local GeoScanner = require('lib.geoscanner')")
end
