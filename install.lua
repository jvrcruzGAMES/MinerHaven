--- MinerHaven Installer for CC: Tweaked
-- Run directly in CraftOS:
--   wget run https://raw.githubusercontent.com/jvrcruzGAMES/MinerHaven/main/install.lua
--
-- Options:
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

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--lib-only" then
        libOnly = true
    elseif a == "--startup" then
        autoStartup = true
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

local files = {
    { remote = "lib/geoscanner.lua", dest = joinPath(targetDir, "lib/geoscanner.lua") },
}

if not libOnly then
    table.insert(files, { remote = "minerhaven.lua", dest = joinPath(targetDir, "minerhaven.lua") })
end

for _, f in ipairs(files) do
    if not downloadFile(f.remote, f.dest) then
        logError("Installation aborted.")
        return
    end
end

if not libOnly then
    local appPath = joinPath(targetDir, "minerhaven.lua")

    -- Register shell aliases for the current session
    if shell and shell.setAlias then
        shell.setAlias("minerhaven", appPath)
        shell.setAlias("mh", appPath)
    end

    -- Write a non-intrusive /startup/99_minerhaven.lua script so aliases persist across reboots
    if not fs.exists("/startup") or fs.isDir("/startup") then
        if not fs.exists("/startup") then
            fs.makeDir("/startup")
        end
        local startupScript = "/startup/99_minerhaven.lua"
        local h = fs.open(startupScript, "w")
        if h then
            h.writeLine("-- MinerHaven shell aliases")
            h.writeLine(("if shell and shell.setAlias then"))
            h.writeLine(("    shell.setAlias('minerhaven', %q)"):format(appPath))
            h.writeLine(("    shell.setAlias('mh', %q)"):format(appPath))
            h.writeLine("end")
            if autoStartup then
                h.writeLine(("shell.run(%q)"):format(appPath))
            end
            h.close()
        end
    end

    logSuccess("MinerHaven installed!")
    print("Run 'minerhaven' or 'mh' to open the Geo Scanner interface.")
    print("Run 'mh help' for CLI commands, or require('lib.geoscanner') in your own scripts.")
else
    logSuccess("GeoScanner library installed to " .. joinPath(targetDir, "lib/geoscanner.lua"))
    print("Use: local GeoScanner = require('lib.geoscanner')")
end
