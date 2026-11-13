--- libupdater - Controller Update, Worker Firmware Flashing & OTA Deployment
-- Manages checking GitHub Releases for updates, downloading Controller and Worker firmware,
-- flashing worker firmware to adjacent computers/disk drives, and pushing OTA updates over Workernet.

local function loadFile(path)
    local clean = path:gsub("^/+", "")
    local ok, res = pcall(dofile, clean)
    if ok then return res end
    local ok2, res2 = pcall(dofile, "/" .. clean)
    if ok2 then return res2 end
    error("Could not load file: " .. path)
end

local Workernet = loadFile("lib/workernet/main.lua")

local function combinePath(base, rel)
    if fs and fs.combine then return fs.combine(base, rel) end
    if not base or base == "" then return rel:gsub("^/+", "") end
    return (base:gsub("/+$", "") .. "/" .. rel:gsub("^/+", ""))
end

local function getDirPath(path)
    if fs and fs.getDir then return fs.getDir(path) end
    return path:match("^(.-)/[^/]+$") or ""
end

local Updater = {}
Updater.REPO_USER = "jvrcruzGAMES"
Updater.REPO_NAME = "MinerHaven"
Updater.DEFAULT_BRANCH = "main"
Updater.VERSION_FILE = "version.json"
Updater.FIRMWARE_DIR = "firmware/worker"

Updater.CONTROLLER_FILES = {
    "startup.lua",
    "lib/crypto/main.lua",
    "lib/workernet/main.lua",
    "controller/main.lua",
    "controller/dashboard.lua",
    "controller/pairing.lua",
    "controller/controller.lua",
    "controller/main.cfg",
    "controller/lib/ores/main.lua",
    "controller/lib/pairing/main.lua",
    "controller/lib/updater/main.lua",
    "version.json",
}

Updater.WORKER_FILES = {
    "startup.lua",
    "lib/crypto/main.lua",
    "lib/workernet/main.lua",
    "worker/main.lua",
    "worker/pairing.lua",
    "worker/worker.lua",
    "worker/lib/device/main.lua",
    "version.json",
}

--- Load local version info from version.json.
function Updater.getLocalVersion(path)
    path = path or Updater.VERSION_FILE
    if fs and fs.exists and fs.exists(path) then
        local f = fs.open(path, "r")
        if f then
            local raw = f.readAll()
            f.close()
            local ok, parsed = pcall(textutils.unserializeJSON or Workernet.unserialize, raw)
            if ok and type(parsed) == "table" and parsed.version then
                return parsed.version, parsed
            end
        end
    end
    return "1.0.0", { version = "1.0.0", tag = "v1.0.0" }
end

--- Parse semantic version string "1.2.3" -> {1, 2, 3}.
local function parseSemVer(vStr)
    if not vStr then return { 0, 0, 0 } end
    vStr = tostring(vStr):gsub("^v", "")
    local parts = {}
    for num in vStr:gmatch("%d+") do
        table.insert(parts, tonumber(num) or 0)
    end
    while #parts < 3 do table.insert(parts, 0) end
    return parts
end

--- Compare two semantic version strings. Returns 1 if v1 > v2, -1 if v1 < v2, 0 if equal.
function Updater.compareVersions(v1, v2)
    local p1 = parseSemVer(v1)
    local p2 = parseSemVer(v2)
    for i = 1, math.max(#p1, #p2) do
        local n1 = p1[i] or 0
        local n2 = p2[i] or 0
        if n1 > n2 then return 1 end
        if n1 < n2 then return -1 end
    end
    return 0
end

--- Check GitHub Releases for the latest version.
-- @treturn boolean hasUpdate
-- @treturn string latestVersion
-- @treturn string currentVersion
-- @treturn table releaseData
function Updater.checkForUpdates()
    local currentVer, currentData = Updater.getLocalVersion()
    if not http then
        return false, currentVer, currentVer, { error = "HTTP API disabled" }
    end

    local latestVer = nil
    local releaseInfo = {}

    -- 1. Try GitHub Releases API
    local apiUrl = string.format("https://api.github.com/repos/%s/%s/releases/latest", Updater.REPO_USER, Updater.REPO_NAME)
    local h, err = http.get(apiUrl, { ["User-Agent"] = "MinerHaven-Updater" })
    if h then
        local body = h.readAll()
        h.close()
        local ok, data = pcall(textutils.unserializeJSON or Workernet.unserialize, body)
        if ok and type(data) == "table" and data.tag_name then
            latestVer = tostring(data.tag_name):gsub("^v", "")
            releaseInfo = data
        end
    end

    -- 2. Fallback to raw version.json if API is rate-limited or unavailable
    if not latestVer then
        local rawUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/version.json?_t=%s",
            Updater.REPO_USER, Updater.REPO_NAME, Updater.DEFAULT_BRANCH, tostring(os.time and os.time() or 1))
        local rh = http.get(rawUrl)
        if rh then
            local rbody = rh.readAll()
            rh.close()
            local ok, rdata = pcall(textutils.unserializeJSON or Workernet.unserialize, rbody)
            if ok and type(rdata) == "table" and rdata.version then
                latestVer = tostring(rdata.version):gsub("^v", "")
                releaseInfo = rdata
            end
        end
    end

    if not latestVer then
        return false, currentVer, currentVer, { error = "Could not fetch release info" }
    end

    local isNewer = Updater.compareVersions(latestVer, currentVer) > 0
    return isNewer, latestVer, currentVer, releaseInfo
end

--- Download a file from GitHub repository.
function Updater.downloadFile(remotePath, destPath, branch)
    branch = branch or Updater.DEFAULT_BRANCH
    local cacheBuster = (os and type(os.epoch) == "function") and tostring(os.epoch("utc")) or tostring(math.random(100000, 999999))
    local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s?v=%s",
        Updater.REPO_USER, Updater.REPO_NAME, branch, remotePath, cacheBuster)

    local resp, err = http.get(url)
    if not resp then
        return false, "Failed to download " .. url .. ": " .. tostring(err)
    end
    local content = resp.readAll()
    resp.close()

    if not content or content == "" then
        return false, "Downloaded empty content from " .. url
    end

    local dir = getDirPath(destPath)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local f = fs.open(destPath, "w")
    if not f then
        return false, "Cannot write to " .. destPath
    end
    f.write(content)
    f.close()
    return true
end

--- Download worker firmware files and stage them locally into firmware/worker/.
function Updater.downloadWorkerFirmware(targetDir, branch)
    targetDir = targetDir or Updater.FIRMWARE_DIR
    branch = branch or Updater.DEFAULT_BRANCH

    if not fs.exists(targetDir) then
        fs.makeDir(targetDir)
    end

    for _, rel in ipairs(Updater.WORKER_FILES) do
        local dest = combinePath(targetDir, rel)
        local ok, err = Updater.downloadFile(rel, dest, branch)
        if not ok then
            return false, "Worker firmware download failed on " .. rel .. ": " .. tostring(err)
        end
    end
    return true
end

--- Update controller software and worker firmware from GitHub.
function Updater.updateController(branch)
    branch = branch or Updater.DEFAULT_BRANCH
    if not http then return false, "HTTP API unavailable" end

    -- 1. Download controller files
    for _, rel in ipairs(Updater.CONTROLLER_FILES) do
        local ok, err = Updater.downloadFile(rel, rel, branch)
        if not ok then
            return false, "Controller update failed on " .. rel .. ": " .. tostring(err)
        end
    end

    -- 2. Download worker firmware into local firmware directory
    local fOk, fErr = Updater.downloadWorkerFirmware(Updater.FIRMWARE_DIR, branch)
    if not fOk then
        return false, fErr
    end

    return true
end

--- Load worker firmware files from local disk into a memory table `{ [path] = content, ... }`.
function Updater.loadWorkerFirmware(sourceDir)
    sourceDir = sourceDir or Updater.FIRMWARE_DIR
    local files = {}
    for _, rel in ipairs(Updater.WORKER_FILES) do
        local fullPath = combinePath(sourceDir, rel)
        if fs.exists(fullPath) then
            local f = fs.open(fullPath, "r")
            if f then
                files[rel] = f.readAll()
                f.close()
            end
        end
    end
    return files
end

--- Flash worker firmware to a computer, turtle, or disk drive to its side.
-- @tparam string side "left", "right", "top", "bottom", "front", "back"
-- @treturn boolean Success
-- @treturn string Message
function Updater.flashSide(side, sourceDir)
    if not peripheral then return false, "Peripheral API unavailable" end
    if not peripheral.isPresent(side) then
        return false, "No peripheral detected on side: " .. tostring(side)
    end

    local pType = peripheral.getType(side)
    local firmwareFiles = Updater.loadWorkerFirmware(sourceDir)
    local fileCount = 0
    for _ in pairs(firmwareFiles) do fileCount = fileCount + 1 end
    if fileCount == 0 then
        return false, "No worker firmware files found in " .. tostring(sourceDir or Updater.FIRMWARE_DIR)
    end

    -- Option A: Disk Drive attached to side
    if pType == "drive" or pType == "disk_drive" then
        local drive = peripheral.wrap(side)
        if not drive or not drive.isDiskPresent or not drive.isDiskPresent() then
            return false, "Disk drive on " .. side .. " does not have a floppy disk inserted."
        end
        local mountPath = drive.getMountPath and drive.getMountPath() or "disk"
        if not fs.exists(mountPath) then
            if fs.makeDir then fs.makeDir(mountPath) end
        end

        for relPath, content in pairs(firmwareFiles) do
            local dest = combinePath(mountPath, relPath)
            local dir = getDirPath(dest)
            if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            local f = fs.open(dest, "w")
            if f then
                f.write(content)
                f.close()
            end
        end
        return true, string.format("Flashed %d worker firmware file(s) to floppy disk on %s.", fileCount, side)
    end

    -- Option B: Computer / Turtle placed adjacent on side
    if pType == "computer" or pType == "turtle" then
        local comp = peripheral.wrap(side)
        local compId = comp.getID and comp.getID() or "unknown"

        -- Turn on or reboot the computer on the side
        if comp.turnOn then pcall(comp.turnOn) end

        -- Send flash bootstrap payload over modem if open
        local modem = peripheral.find("modem")
        if modem then
            local flashPacket = {
                type = "firmware_flash",
                targetId = compId,
                files = firmwareFiles,
                version = Updater.getLocalVersion(),
            }
            if modem.isOpen and not modem.isOpen(4820) then pcall(modem.open, 4820) end
            if modem.transmit then
                pcall(modem.transmit, 4820, 4821, flashPacket)
            end
        end

        return true, string.format("Turned on adjacent %s on %s (ID: %s) and staged firmware flash.", pType, side, tostring(compId))
    end

    return false, "Peripheral on " .. side .. " is " .. tostring(pType) .. " (expected computer, turtle, or disk drive)."
end

--- Send OTA (Over-The-Air) firmware update to a paired worker over Workernet.
-- @tparam table net Workernet Node instance
-- @tparam number|string targetWorkerId Worker ID
-- @tparam[opt] string sourceDir Local firmware folder
-- @treturn boolean Success
-- @treturn string Message
function Updater.sendOTAUpdate(net, targetWorkerId, sourceDir)
    local firmwareFiles = Updater.loadWorkerFirmware(sourceDir)
    local fileCount = 0
    for _ in pairs(firmwareFiles) do fileCount = fileCount + 1 end
    if fileCount == 0 then
        return false, "No worker firmware files available in local firmware storage."
    end

    local localVer = Updater.getLocalVersion()
    local payload = {
        type = "command",
        action = "ota_update",
        version = localVer,
        files = firmwareFiles,
    }

    local targetNum = tonumber(targetWorkerId) or targetWorkerId
    local ok, err = net:send(targetNum, payload)
    if ok then
        return true, string.format("OTA update payload (v%s, %d files) sent to Worker %s", localVer, fileCount, tostring(targetWorkerId))
    else
        return false, string.format("Failed to send OTA update to Worker %s: %s", tostring(targetWorkerId), tostring(err))
    end
end

return Updater
