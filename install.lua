--- MinerHaven Installer for CC: Tweaked (Controller / Worker Architecture)
-- Run directly in CraftOS:
--   wget run https://raw.githubusercontent.com/jvrcruzGAMES/MinerHaven/main/install.lua
--
-- Options:
--   --controller     Install for the Base Controller Advanced Computer (Geo Scanner + Modem)
--   --worker         Install for the Mining Worker Turtle (End Automata + Modem)
--   --base           Alias for --controller
--   --turtle         Alias for --worker
--   --dir <folder>   Install into a custom directory (default: /)
--   --branch <name>  Git branch to download from (default: main)
--   --startup        Auto-launch on computer startup

local REPO_USER = "jvrcruzGAMES"
local REPO_NAME = "MinerHaven"

local args = { ... }
local targetDir = ""
local branch = "main"
local autoStartup = false
local installRole = nil -- "controller" | "worker" | nil (ask interactively)

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--startup" then
        autoStartup = true
    elseif a == "--worker" or a == "--turtle" then
        installRole = "worker"
    elseif a == "--controller" or a == "--base" then
        installRole = "controller"
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

--- Ask user which component is being installed: Controller or Worker.
local function askComputerRole()
    local defaultRole = (_G.turtle ~= nil) and "worker" or "controller"
    if type(_G.read) ~= "function" then
        return defaultRole
    end
    local defaultHint = (defaultRole == "worker") and " [w]" or " [c]"
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.yellow)
    end
    write("[?] Which component is this? (c = Controller, w = Worker Turtle)" .. defaultHint .. ": ")
    if term and term.isColor and term.isColor() then
        term.setTextColor(colors.white)
    end
    local input = read()
    if type(input) ~= "string" then
        return defaultRole
    end
    local trimmed = input:match("^%s*(.-)%s*$"):lower()
    if trimmed == "" then
        return defaultRole
    end
    if trimmed == "w" or trimmed == "worker" or trimmed == "turtle" or trimmed == "t" then
        return "worker"
    end
    if trimmed == "c" or trimmed == "controller" or trimmed == "base" or trimmed == "b" then
        return "controller"
    end
    return defaultRole
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
    local cacheBuster = (os and type(os.epoch) == "function") and tostring(os.epoch("utc")) or tostring(math.random(100000, 999999))
    local url = BASE_URL .. "/" .. remotePath .. "?v=" .. cacheBuster
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

if installRole == nil then
    installRole = askComputerRole()
end

local isWorker = (installRole == "worker")
local isController = (installRole == "controller")

-- Shared files needed by both
local files = {
    { remote = "lib/crypto/main.lua", dest = joinPath(targetDir, "lib/crypto/main.lua") },
    { remote = "lib/workernet/main.lua", dest = joinPath(targetDir, "lib/workernet/main.lua") },
    { remote = "startup.lua", dest = joinPath(targetDir, "startup.lua") },
}

if isController then
    table.insert(files, { remote = "controller/main.lua", dest = joinPath(targetDir, "controller/main.lua") })
    table.insert(files, { remote = "controller/dashboard.lua", dest = joinPath(targetDir, "controller/dashboard.lua") })
    table.insert(files, { remote = "controller/pairing.lua", dest = joinPath(targetDir, "controller/pairing.lua") })
    table.insert(files, { remote = "controller/controller.lua", dest = joinPath(targetDir, "controller/controller.lua") })
    table.insert(files, { remote = "controller/main.cfg", dest = joinPath(targetDir, "controller/main.cfg") })
    table.insert(files, { remote = "controller/lib/ores/main.lua", dest = joinPath(targetDir, "controller/lib/ores/main.lua") })
    table.insert(files, { remote = "controller/lib/pairing/main.lua", dest = joinPath(targetDir, "controller/lib/pairing/main.lua") })
elseif isWorker then
    table.insert(files, { remote = "worker/main.lua", dest = joinPath(targetDir, "worker/main.lua") })
    table.insert(files, { remote = "worker/pairing.lua", dest = joinPath(targetDir, "worker/pairing.lua") })
    table.insert(files, { remote = "worker/worker.lua", dest = joinPath(targetDir, "worker/worker.lua") })
    table.insert(files, { remote = "worker/lib/device/main.lua", dest = joinPath(targetDir, "worker/lib/device/main.lua") })
end

for _, f in ipairs(files) do
    if not downloadFile(f.remote, f.dest) then
        logError("Installation aborted.")
        return
    end
end

logSuccess("MinerHaven " .. (isController and "Controller" or "Worker") .. " installed successfully!")

-- Setup startup if requested
local shouldStartup = autoStartup
if not autoStartup then
    shouldStartup = askYesNo("Run MinerHaven automatically on boot (via startup.lua)?", true)
end

if shouldStartup then
    logSuccess("MinerHaven will automatically launch on boot via startup.lua")
end

logInfo("You can run MinerHaven immediately with:")
if isController then
    logInfo("  controller/main.lua")
else
    logInfo("  worker/main.lua")
end
