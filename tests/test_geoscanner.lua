-- Automated test suite for MinerHaven (lib/geoscanner.lua, minerhaven.lua, turtle_miner.lua, install.lua)
package.path = "./?.lua;./lib/?.lua;" .. package.path

local GeoScanner = require("geoscanner")

local passed = 0
local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
    passed = passed + 1
end

local function assertTrue(val, msg)
    if not val then
        error(msg or "Expected truthy value", 2)
    end
    passed = passed + 1
end

-- 1. Test static helpers
assertEq(GeoScanner.shortName("minecraft:deepslate_diamond_ore"), "deepslate_diamond_ore", "shortName")
assertEq(GeoScanner.prettyName("minecraft:deepslate_diamond_ore"), "Deepslate Diamond Ore", "prettyName")
assertEq(GeoScanner.formatDirection(3, -2, 5), "3E 2D 5S", "formatDirection +X -Y +Z")
assertEq(GeoScanner.formatDirection(-1, 4, -2), "1W 4U 2N", "formatDirection -X +Y -Z")
assertEq(GeoScanner.formatDirection(0, 0, 0), "Here", "formatDirection origin")

-- 2. Test normalizeTags (both array-style and map-style)
local mapTags, listTags = GeoScanner.normalizeTags({ "forge:ores", "#minecraft:diamond_ores" })
assertTrue(mapTags["forge:ores"], "array tag forge:ores")
assertTrue(mapTags["minecraft:diamond_ores"], "array tag stripped #")
assertEq(#listTags, 2, "tag list count")

local mapTags2 = GeoScanner.normalizeTags({ ["c:ores"] = true, ["minecraft:stone"] = false })
assertTrue(mapTags2["c:ores"], "map tag c:ores")
assertTrue(not mapTags2["minecraft:stone"], "false tag ignored")

-- 3. Test isOre, hasOreTag, isOreItem & enrichBlock
local diamondBlock = GeoScanner.enrichBlock({
    name = "minecraft:deepslate_diamond_ore",
    x = 3,
    y = -4,
    z = 0,
    tags = { "forge:ores", "minecraft:diamond_ores" },
})
assertTrue(diamondBlock.isOre, "diamond is ore")
assertTrue(diamondBlock.hasOreTag, "diamond has ore tag")
assertEq(diamondBlock.dist, 7, "manhattan dist 3+4+0")
assertEq(diamondBlock.euclidean, 5.0, "euclidean dist 3-4-5 triangle")
assertTrue(GeoScanner.hasTag(diamondBlock, "#forge:ores"), "hasTag with #")

local stoneBlock = GeoScanner.enrichBlock({
    name = "minecraft:stone",
    x = 1,
    y = 0,
    z = 0,
    tags = { "minecraft:stone_ore_replaceables" },
})
assertTrue(not stoneBlock.isOre, "stone is not ore")
assertTrue(not stoneBlock.hasOreTag, "stone does not have ore tag")
assertTrue(GeoScanner.isOreItem({ name = "minecraft:raw_iron", tags = { ["forge:raw_materials"] = true } }), "raw_iron is ore item")
assertTrue(not GeoScanner.isOreItem({ name = "minecraft:cobblestone", tags = {} }), "cobblestone is not ore item")

-- 4. Mock CC: Tweaked peripheral environment & test GeoScanner methods
local mockCooldown = 1
local mockPeripheral = {
    getMaxFuelLevel = function() return 200000 end,
    getFuelLevel = function() return 150000 end,
    cost = function(r) return r <= 8 and 0 or (r * 100) end,
    scan = function(r)
        if mockCooldown > 0 then
            mockCooldown = mockCooldown - 1
            return nil, "Scanner is on cooldown, please wait"
        end
        return {
            { name = "minecraft:stone", x = 1, y = 0, z = 0, tags = {} },
            { name = "minecraft:diamond_ore", x = 4, y = -2, z = 1, tags = { "forge:ores" } },
            { name = "minecraft:diamond_ore", x = 1, y = -1, z = 1, tags = { "forge:ores" } },
            { name = "minecraft:iron_ore", x = 2, y = 0, z = -3, tags = { "forge:ores" } },
        }
    end,
    chunkAnalyze = function()
        return {
            ["minecraft:iron_ore"] = 42,
            ["minecraft:diamond_ore"] = 6,
            ["minecraft:coal_ore"] = 80,
        }
    end,
}

_G.peripheral = {
    find = function(pType)
        if pType == "geoScanner" then
            return mockPeripheral
        end
        return nil
    end,
    getName = function() return "geoScanner_back" end,
    isPresent = function(side) return side == "back" end,
    wrap = function(side) return side == "back" and mockPeripheral or nil end,
}

local scanner, err = GeoScanner.find()
assertTrue(scanner ~= nil, "GeoScanner.find() succeeded: " .. tostring(err))
assertEq(scanner.name, "geoScanner_back", "scanner peripheral name")
assertEq(scanner:getCost(8), 0, "free scan at radius 8")
assertEq(scanner:getCost(12), 1200, "paid scan at radius 12")
assertEq(scanner:getFuel().max, 200000, "max fuel")
assertEq(scanner:getFuel().level, 150000, "current fuel")

-- Cooldown failure when retries = 0, then success when retries >= 1
mockCooldown = 1
local failScan, failErr = scanner:scan(8, { retries = 0 })
assertTrue(failScan == nil and failErr:find("cooldown") ~= nil, "cooldown returned error when retries=0")

mockCooldown = 2
local ores, scanErr = scanner:scanOresByTag(8, { retries = 3, retryDelay = 0 })
assertTrue(ores ~= nil, "scanOresByTag with retries succeeded: " .. tostring(scanErr))
assertEq(#ores, 3, "3 ore blocks returned by tag (stone filtered out)")
assertEq(ores[1].dist, 3, "sorted by nearest distance first (1,-1,1 -> dist 3)")

-- Grouping test
local groups = GeoScanner.groupByBlock(ores)
assertEq(#groups, 2, "2 distinct ore types (diamond_ore, iron_ore)")
assertEq(groups[1].name, "minecraft:diamond_ore", "diamond group nearest first")
assertEq(groups[1].count, 2, "2 diamond ores in group")

-- findNearest test
local nearestIron = scanner:findNearest(8, "iron")
assertTrue(nearestIron ~= nil, "findNearest iron")
assertEq(nearestIron.name, "minecraft:iron_ore", "nearest iron block name")

-- analyzeChunk test
local chunkRes, chunkErr = scanner:analyzeChunk()
assertTrue(chunkRes ~= nil, "analyzeChunk succeeded: " .. tostring(chunkErr))
assertEq(chunkRes.total, 128, "total ores in chunk (80+42+6)")
assertEq(chunkRes.entries[1].name, "minecraft:coal_ore", "most abundant ore first")

-- 5. Test minerhaven.lua CLI & TUI
_G.colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8,
    yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}
_G.keys = {
    one = 2, two = 3, three = 4, tab = 15, q = 16, w = 17, s = 31, f = 33,
    c = 46, j = 36, k = 37, enter = 28, backspace = 14, space = 57, up = 200, down = 208,
    left = 203, right = 205, minus = 12, equals = 13, leftBracket = 26,
    rightBracket = 27, slash = 53, pageUp = 201, pageDown = 209,
}

_G.term = {
    isColor = function() return true end,
    getSize = function() return 39, 13 end, -- Turtle screen dimensions!
    setTextColor = function() end,
    setBackgroundColor = function() end,
    setCursorPos = function() end,
    setCursorBlink = function() end,
    write = function() end,
    clear = function() end,
}

-- 5. Test startup.lua
local startupExecuted = nil
_G.shell = {
    run = function(path) startupExecuted = path; return true end,
    setAlias = function() end,
}
_G.fs = _G.fs or {}
local realFsExists = _G.fs.exists
_G.fs.exists = function(p)
    if p == "controller/main.lua" then return true end
    return false
end
local startupChunk = assert(loadfile("./startup.lua"))
startupChunk()
assertEq(startupExecuted, "controller/main.lua", "startup.lua ran controller/main.lua")

-- Test worker startup
_G.fs.exists = function(p)
    if p == "worker/main.lua" then return true end
    return false
end
startupChunk()
assertEq(startupExecuted, "worker/main.lua", "startup.lua ran worker/main.lua")

-- 6. Test install.lua (both non-turtle and interactive turtle install with Home saving)
local writtenFiles = {}
_G.http = {
    get = function(url)
        return {
            readAll = function() return "-- downloaded from " .. url end,
            close = function() end,
        }
    end,
}
_G.fs = {
    getDir = function(p) return p:match("^(.*)/[^/]+$") or "" end,
    exists = function(p) return writtenFiles[p] ~= nil end,
    isDir = function() return true end,
    makeDir = function() end,
    open = function(path, mode)
        if mode == "r" then
            local content = writtenFiles[path]
            if not content then return nil end
            return {
                readAll = function() return content end,
                close = function() end,
            }
        end
        local buf = {}
        return {
            write = function(s) table.insert(buf, s) end,
            writeLine = function(s) table.insert(buf, s .. "\n") end,
            close = function() writtenFiles[path] = table.concat(buf) end,
        }
    end,
}
_G.shell = {
    setAlias = function() end,
}
_G.write = io.write

-- Simulate interactive prompts in install.lua:
-- 1) "Which component is this? (c = Controller, w = Worker Turtle)" -> "c"
-- 2) "Run MinerHaven automatically on boot?" -> "y"
local promptAnswers = { "c", "y" }
_G.read = function()
    return table.remove(promptAnswers, 1) or ""
end

local installChunk = assert(loadfile("./install.lua"))
installChunk()
assertTrue(writtenFiles["/lib/geoscanner.lua"] ~= nil, "installer wrote /lib/geoscanner.lua")
assertTrue(writtenFiles["/lib/crypto/main.lua"] ~= nil, "installer wrote /lib/crypto/main.lua")
assertTrue(writtenFiles["/lib/workernet/main.lua"] ~= nil, "installer wrote /lib/workernet/main.lua")
assertTrue(writtenFiles["/controller/main.lua"] ~= nil, "installer wrote /controller/main.lua for controller install")
assertTrue(writtenFiles["/controller/lib/ores/main.lua"] ~= nil, "installer wrote /controller/lib/ores/main.lua")
assertTrue(writtenFiles["/startup.lua"] ~= nil, "installer wrote /startup.lua")

-- 7. Test turtle_miner.lua full lifecycle:
--    Idle -> Start -> Mine ores by tag until inventory full -> Return Home -> Wait until ores unloaded -> Resume -> Stop (stays idle, does not exit)
local mockInv = {}
for s = 1, 16 do mockInv[s] = nil end
mockInv[16] = { name = "minecraft:coal", count = 64, tags = {} }

local worldOres = {
    { name = "minecraft:diamond_ore", x = 2, y = 0, z = -1, tags = { "forge:ores" } },
    { name = "minecraft:iron_ore", x = 3, y = 1, z = -1, tags = { "forge:ores" } },
}

local turtleMinerMod = assert(loadfile("./turtle_miner.lua"))("turtle_miner")
local miner = turtleMinerMod.new()

-- Set home at (10, 64, 20) facing North (0)
_G.gps = {
    locate = function() return 10, 64, 20 end,
}
miner:setHomeHere("n")
assertEq(miner.home.x, 10, "home X saved as 10")
assertEq(miner.home.y, 64, "home Y saved as 64")
assertEq(miner.home.z, 20, "home Z saved as 20")
assertEq(miner.home.dir, 0, "home dir saved as North (0)")

local function fillInventoryWithOres()
    for s = 1, 15 do
        mockInv[s] = { name = "minecraft:diamond_ore", count = 1, tags = { ["forge:ores"] = true } }
    end
end

local function clearOresFromInventory()
    for s = 1, 15 do
        mockInv[s] = nil
    end
end

_G.turtle = {
    getFuelLevel = function() return 5000 end,
    getSelectedSlot = function() return 1 end,
    select = function() return true end,
    getItemCount = function(slot) return mockInv[slot] and mockInv[slot].count or 0 end,
    getItemDetail = function(slot) return mockInv[slot] end,
    forward = function() return true end,
    up = function() return true end,
    down = function() return true end,
    turnLeft = function() return true end,
    turnRight = function() return true end,
    dig = function()
        -- Simulate mining the ore and filling the inventory!
        fillInventoryWithOres()
        return true
    end,
    digUp = function()
        fillInventoryWithOres()
        return true
    end,
    digDown = function()
        fillInventoryWithOres()
        return true
    end,
    drop = function() return true end,
    dropDown = function() return true end,
}

mockPeripheral.scan = function()
    -- Return an ore relative to the turtle's current position
    return {
        { name = "minecraft:diamond_ore", x = 2, y = 0, z = -1, tags = { "forge:ores" } },
    }
end

-- Initially stopped (idle)
assertEq(miner.running, false, "miner starts idle (stopped)")
assertEq(miner:stepWorker(), "idle", "stepWorker returns idle when stopped")

-- Issue 'start' command
miner:executeCommand("start")
assertEq(miner.running, true, "miner is running after 'start'")

-- Step 1: Mines the nearby ore, inventory becomes full (16/16 slots), so it immediately returns Home and waits!
local stepRes = miner:stepWorker()
assertEq(stepRes, "waiting_unload", "after filling inventory, turtle returned home and is waiting for unload")
assertTrue(miner:isAtHome(), "turtle returned to Home coordinates (10, 64, 20)")
assertEq(miner.phase, "WAITING AT HOME", "phase is WAITING AT HOME")

-- Step 2: While ores are still in inventory, it stays at Home waiting
assertEq(miner:stepWorker(), "waiting_unload", "still waiting at home while ores remain in inventory")
assertTrue(miner:isAtHome(), "still at home")

-- Step 3: Unload ores from turtle's inventory -> next step automatically resumes mining!
clearOresFromInventory()
-- Don't fill all 16 slots on this dig so it stays in mining mode (only 1 slot used, not full, away from home!)
_G.turtle.dig = function()
    mockInv[1] = { name = "minecraft:iron_ore", count = 1, tags = { ["forge:ores"] = true } }
    return true
end
local resumeRes = miner:stepWorker()
assertEq(resumeRes, "mined", "once inventory has no more ores, turtle automatically goes back to mining")
assertTrue(not miner:isInventoryFull(), "inventory is NOT full (only 1/16 slots used)")
assertTrue(not miner:isAtHome(), "turtle moved away from home to mine the ore")

-- Step 4: Issue 'stop' instruction while running and NOT full -> returns to Home and stays idle!
miner:executeCommand("stop")
assertEq(miner.running, false, "miner running is false after stop")
assertTrue(miner:isAtHome(), "turtle returned to Home when stopped while running and not full")
assertEq(miner.keepProgramAlive, true, "miner program stays alive (idle) when stopped")
assertEq(miner:stepWorker(), "idle", "miner stays idle until activated again")

-- Step 5: Test 'sethome' instruction sets Home to the current block the turtle is in
_G.gps = nil -- Test dead-reckoning current block (without GPS override)
miner.pos.x = 25
miner.pos.y = 50
miner.pos.z = -12
miner.pos.dir = 2
miner:executeCommand("sethome")
assertEq(miner.home.x, 25, "sethome updated home.x to current block X (25)")
assertEq(miner.home.y, 50, "sethome updated home.y to current block Y (50)")
assertEq(miner.home.z, -12, "sethome updated home.z to current block Z (-12)")
assertEq(miner.home.dir, 2, "sethome updated home.dir to current facing (2)")
assertTrue(miner:isAtHome(), "turtle is now at its newly set Home")

-- Step 6: Issue 'start' instruction again -> activates again!
miner:executeCommand("start")
assertEq(miner.running, true, "miner reactivates when given start again")

-- 8. Test Movement Preference (Down before horizontal direction) & Obstacle Avoidance around allthemodium:teleport_pad
local miner2 = turtleMinerMod.new()
miner2.pos = { x = 0, y = 10, z = 0, dir = 0 }
miner2.home = { x = 0, y = 10, z = 0, dir = 0 }
miner2.running = true

local stepHistory = {}
local dugBlocks = {}
local worldMap = {
    ["0,9,0"] = "minecraft:stone",
    ["0,8,0"] = "minecraft:stone",
    ["1,8,0"] = "minecraft:stone",
    ["2,8,0"] = "minecraft:stone",
    ["2,8,-1"] = "minecraft:diamond_ore",
}

local function getFrontCoord(pos)
    local vecs = {
        [0] = { x = 0, z = -1 },
        [1] = { x = 1, z = 0 },
        [2] = { x = 0, z = 1 },
        [3] = { x = -1, z = 0 },
    }
    local v = vecs[pos.dir]
    return pos.x + v.x, pos.y, pos.z + v.z
end

local miner2Inv = {
    [1] = { name = "minecraft:coal", count = 64, tags = {} },
}

_G.turtle = {
    getFuelLevel = function() return 5000 end,
    getSelectedSlot = function() return 1 end,
    select = function() return true end,
    getItemCount = function(s) return miner2Inv[s] and miner2Inv[s].count or 0 end,
    getItemDetail = function(s) return miner2Inv[s] end,
    turnLeft = function() return true end,
    turnRight = function() return true end,
    detect = function()
        local fx, fy, fz = getFrontCoord(miner2.pos)
        return worldMap[("%d,%d,%d"):format(fx, fy, fz)] ~= nil
    end,
    detectUp = function()
        return worldMap[("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y + 1, miner2.pos.z)] ~= nil
    end,
    detectDown = function()
        return worldMap[("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y - 1, miner2.pos.z)] ~= nil
    end,
    inspect = function()
        local fx, fy, fz = getFrontCoord(miner2.pos)
        local b = worldMap[("%d,%d,%d"):format(fx, fy, fz)]
        if b then return true, { name = b } end
        return false, "No block"
    end,
    inspectUp = function()
        local b = worldMap[("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y + 1, miner2.pos.z)]
        if b then return true, { name = b } end
        return false, "No block"
    end,
    inspectDown = function()
        local b = worldMap[("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y - 1, miner2.pos.z)]
        if b then return true, { name = b } end
        return false, "No block"
    end,
    dig = function()
        local fx, fy, fz = getFrontCoord(miner2.pos)
        local k = ("%d,%d,%d"):format(fx, fy, fz)
        table.insert(dugBlocks, { key = k, name = worldMap[k] })
        worldMap[k] = nil
        return true
    end,
    digUp = function()
        local k = ("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y + 1, miner2.pos.z)
        table.insert(dugBlocks, { key = k, name = worldMap[k] })
        worldMap[k] = nil
        return true
    end,
    digDown = function()
        local k = ("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y - 1, miner2.pos.z)
        table.insert(dugBlocks, { key = k, name = worldMap[k] })
        worldMap[k] = nil
        return true
    end,
    forward = function()
        local fx, fy, fz = getFrontCoord(miner2.pos)
        local k = ("%d,%d,%d"):format(fx, fy, fz)
        if worldMap[k] ~= nil then return false end
        table.insert(stepHistory, { x = fx, y = fy, z = fz })
        return true
    end,
    up = function()
        local k = ("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y + 1, miner2.pos.z)
        if worldMap[k] ~= nil then return false end
        table.insert(stepHistory, { x = miner2.pos.x, y = miner2.pos.y + 1, z = miner2.pos.z })
        return true
    end,
    down = function()
        local k = ("%d,%d,%d"):format(miner2.pos.x, miner2.pos.y - 1, miner2.pos.z)
        if worldMap[k] ~= nil then return false end
        table.insert(stepHistory, { x = miner2.pos.x, y = miner2.pos.y - 1, z = miner2.pos.z })
        return true
    end,
}

-- Test 8A: Prefer moving down first before moving in the horizontal direction of the ore at (2, 8, -1)
local reached = miner2:moveTo(2, 8, -1, true, true)
assertTrue(reached, "miner2 reached and mined ore at (2, 8, -1)")
assertEq(stepHistory[1].x, 0, "Step 1 X is 0 (moved straight down first)")
assertEq(stepHistory[1].y, 9, "Step 1 Y is 9 (moved down first)")
assertEq(stepHistory[2].x, 0, "Step 2 X is 0 (moved straight down second)")
assertEq(stepHistory[2].y, 8, "Step 2 Y is 8 (reached ore Y level before moving horizontally)")
assertEq(worldMap["2,8,-1"], nil, "target ore at (2, 8, -1) was dug")

-- Test 8B: Encountering allthemodium:teleport_pad in the way -> must NOT break it, and must find another way around it!
miner2.pos = { x = 0, y = 0, z = 0, dir = 0 }
miner2.blockedCoords = {}
stepHistory = {}
dugBlocks = {}
worldMap = {
    ["0,-1,0"] = "allthemodium:teleport_pad", -- Directly below the turtle!
    ["1,0,0"] = "minecraft:stone",            -- Breakable stone to the East
    ["1,-1,0"] = "minecraft:stone",           -- Breakable stone along detour
    ["1,-2,0"] = "minecraft:stone",           -- Breakable stone adjacent to target ore
    ["0,-2,0"] = "minecraft:allthemodium_ore", -- Target ore below the teleport pad!
}

local reachedDetour = miner2:moveTo(0, -2, 0, true, true)
assertTrue(reachedDetour, "miner2 found an alternative path around allthemodium:teleport_pad to mine the ore at (0, -2, 0)")
assertEq(worldMap["0,-1,0"], "allthemodium:teleport_pad", "allthemodium:teleport_pad was NOT broken!")
assertEq(worldMap["0,-2,0"], nil, "target ore below the teleport pad WAS mined via alternative path!")
for _, d in ipairs(dugBlocks) do
    assertTrue(d.name ~= "allthemodium:teleport_pad", "never dug allthemodium:teleport_pad")
end

-- Test 8C: When fuel is 0 (or block cannot be broken due to missing tool / claim), do NOT rotate or permanently block coordinates!
local rotations = 0
_G.turtle.getFuelLevel = function() return 0 end
_G.turtle.turnLeft = function() rotations = rotations + 1; return true end
_G.turtle.turnRight = function() rotations = rotations + 1; return true end

local noFuelStatus = miner2:stepWorker()
assertEq(noFuelStatus, "no_fuel", "stepWorker returns no_fuel immediately when fuel is 0")
assertEq(rotations, 0, "turtle does NOT rotate when out of fuel")
assertTrue(miner2.lastAction:find("OUT OF FUEL", 1, true) ~= nil, "displays clear OUT OF FUEL message instead of Could not reach Iron Ore")

-- Test 8D: Placing non-ore waste blocks (dirt, cobblestone, etc.) in the turtle's path while keeping ores, tools, and energy items
local testInv = {
    [1] = { name = "minecraft:raw_iron", count = 8, tags = { ["forge:raw_materials"] = true } },
    [2] = { name = "minecraft:dirt", count = 1, tags = {} },
    [3] = { name = "minecraft:cobblestone", count = 1, tags = {} },
    [4] = { name = "mekanism:energy_tablet", count = 1, tags = {} },
    [5] = { name = "minecraft:cobbled_deepslate", count = 1, tags = {} },
}
local selectedSlot = 1
local placedDirs = {}
miner2.pos = { x = 5, y = 10, z = 5, dir = 0 }
miner2.home = { x = 0, y = 64, z = 0, dir = 0 }
_G.turtle.select = function(s) selectedSlot = s; return true end
_G.turtle.getSelectedSlot = function() return selectedSlot end
_G.turtle.getItemCount = function(s) return testInv[s] and testInv[s].count or 0 end
_G.turtle.getItemDetail = function(s) return testInv[s] end
_G.turtle.placeDown = function()
    if testInv[selectedSlot] then
        table.insert(placedDirs, { dir = "down", item = testInv[selectedSlot].name })
        testInv[selectedSlot] = nil
        return true
    end
    return false
end
_G.turtle.placeUp = function()
    if testInv[selectedSlot] then
        table.insert(placedDirs, { dir = "up", item = testInv[selectedSlot].name })
        testInv[selectedSlot] = nil
        return true
    end
    return false
end
_G.turtle.place = function()
    if testInv[selectedSlot] then
        table.insert(placedDirs, { dir = "forward", item = testInv[selectedSlot].name })
        testInv[selectedSlot] = nil
        return true
    end
    return false
end

-- Place waste block in path after stepping down (places Up into vacated block)
local placedPath = miner2:placeWasteInPath("down")
assertTrue(placedPath, "placed waste block in path after stepDown")
assertEq(placedDirs[1].dir, "up", "stepDown places waste block UP into the vacated shaft")
assertEq(placedDirs[1].item, "minecraft:dirt", "placed dirt from slot 2")
assertEq(testInv[2], nil, "slot 2 dirt was consumed by placing")

-- Place remaining waste blocks via placeWasteBlocks()
local placedCount = miner2:placeWasteBlocks()
assertEq(placedCount, 2, "placed remaining 2 slots of waste blocks (cobblestone, cobbled_deepslate)")
assertTrue(testInv[1] ~= nil, "kept raw_iron ore in slot 1")
assertEq(testInv[3], nil, "placed cobblestone from slot 3")
assertTrue(testInv[4] ~= nil, "kept mekanism:energy_tablet in slot 4")
assertEq(testInv[5], nil, "placed cobbled_deepslate from slot 5")

-- 9. Test End Automata Upgrade:
--    9A: Save Home warp point (`savePoint("home")`) & Teleport to Home (`warpToPoint("home")`) + Alignment with Home (`home.dir`)
--    9B: Energy charging via `automata.chargeTurtle()`
--    9C: Fallback to dig-to-home when warp fuel cost > available fuel OR when End Automata breaks
--    9D: Digging blocks via `automata.digBlock()` when no side pickaxe is equipped
--    9E: Mining the chunk's ores via `chunkAnalyze()` + vertical chunk descent
local savedWarpPoints = {}
local warpCount = 0
local currentFuelLevel = 50
local mockWarpCost = 200
local automataIntact = true
local chargeCalls = 0
local automataDigCalls = 0

local mockEndAutomata = {
    savePoint = function(name)
        savedWarpPoints[name] = { x = 10, y = 64, z = 20 }
        return true
    end,
    points = function()
        local list = {}
        for k, _ in pairs(savedWarpPoints) do
            table.insert(list, k)
        end
        return list
    end,
    estimateWarpCost = function(name)
        if not savedWarpPoints[name] then
            return nil, "Cannot find point to teleport"
        end
        return mockWarpCost
    end,
    getWarpCooldown = function() return 0 end,
    warpToPoint = function(name)
        if not savedWarpPoints[name] then
            return nil, "Cannot find point to teleport"
        end
        if currentFuelLevel < mockWarpCost then
            return nil, "Not enough fuel"
        end
        currentFuelLevel = currentFuelLevel - mockWarpCost
        warpCount = warpCount + 1
        return true
    end,
    getChargeCooldown = function() return 0 end,
    chargeTurtle = function()
        local detail = _G.turtle.getItemDetail(_G.turtle.getSelectedSlot())
        if detail and detail.name == "mekanism:energy_tablet" and (detail.energy or 0) > 0 then
            local add = math.min(500, detail.energy)
            detail.energy = detail.energy - add
            currentFuelLevel = currentFuelLevel + add
            chargeCalls = chargeCalls + 1
            return true, add
        end
        return nil, "Item cannot provide energy"
    end,
    getDigCooldown = function() return 0 end,
    digBlock = function(opts)
        automataDigCalls = automataDigCalls + 1
        return true
    end,
    collectItems = function()
        return true, 1
    end,
}

_G.peripheral = {
    find = function(pType)
        if pType == "geoScanner" then
            return mockPeripheral
        end
        if automataIntact and (pType == "endAutomata" or pType == "end_automata") then
            return mockEndAutomata
        end
        return nil
    end,
    getName = function(p)
        if p == mockEndAutomata then return "right" end
        return "left"
    end,
    isPresent = function(side)
        if side == "right" then return automataIntact end
        return side == "left"
    end,
    wrap = function(side)
        if side == "right" and automataIntact then return mockEndAutomata end
        if side == "left" then return mockPeripheral end
        return nil
    end,
}

local automataInv = {
    [1] = { name = "minecraft:diamond_pickaxe", count = 1, tags = {} },
    [2] = { name = "mekanism:energy_tablet", count = 1, energy = 1000, tags = {} },
    [16] = { name = "minecraft:coal", count = 64, tags = {} },
}
local autoSelectedSlot = 1

_G.turtle = {
    getFuelLevel = function() return currentFuelLevel end,
    getSelectedSlot = function() return autoSelectedSlot end,
    select = function(s) autoSelectedSlot = s; return true end,
    getItemCount = function(s) return automataInv[s] and automataInv[s].count or 0 end,
    getItemDetail = function(s) return automataInv[s] end,
    forward = function()
        currentFuelLevel = math.max(0, currentFuelLevel - 1)
        return true
    end,
    up = function()
        currentFuelLevel = math.max(0, currentFuelLevel - 1)
        return true
    end,
    down = function()
        currentFuelLevel = math.max(0, currentFuelLevel - 1)
        return true
    end,
    turnLeft = function() return true end,
    turnRight = function() return true end,
    detect = function() return false end,
    detectUp = function() return false end,
    detectDown = function() return false end,
    -- Simulate an End Automata Turtle that has NO permanent side pickaxe (`turtle.dig` returns false),
    -- so it must use `automata.digBlock()` with the pickaxe in slot 1!
    dig = function() return false, "No tool to dig with" end,
    digUp = function() return false, "No tool to dig with" end,
    digDown = function() return false, "No tool to dig with" end,
    placeDown = function() return true end,
    placeUp = function() return true end,
    place = function() return true end,
}

_G.gps = {
    locate = function() return 10, 64, 20 end,
}

local miner3 = turtleMinerMod.new()
miner3:sethome("e") -- Home at (10, 64, 20) facing East (dir = 1)
assertTrue(savedWarpPoints["home"] ~= nil, "sethome saved 'home' warp point on End Automata")
assertEq(miner3.home.dir, 1, "home facing direction is East (1)")

-- Move miner3 away from Home to (14, 30, 22) facing West (dir = 3)
miner3.pos = { x = 14, y = 30, z = 22, dir = 3 }

-- Test 9A & 9B: `returnToHome()` sees currentFuelLevel (50) < mockWarpCost (200),
-- automatically charges the turtle from `mekanism:energy_tablet` via `automata.chargeTurtle()`,
-- then teleports to `"home"` via `automata.warpToPoint("home")` and aligns with Home (`dir = 1`)!
local retOk, retMode = miner3:returnToHome()
assertTrue(retOk, "returnToHome succeeded via End Automata")
assertEq(retMode, "teleported", "returnToHome used End Automata warpToPoint('home')")
assertTrue(chargeCalls >= 1, "charged turtle using energy item via automata.chargeTurtle()")
assertEq(warpCount, 1, "warpToPoint('home') was called once")
assertTrue(miner3:isAtHome(), "turtle coordinates updated to Home (10, 64, 20)")
assertEq(miner3.pos.dir, 1, "turtle aligned its facing direction with Home (East = 1)")

-- Test 9C-1: Fallback to dig-to-home when warp fuel cost is MORE than available fuel (and energy tablet is empty)
automataInv[2].energy = 0 -- Energy tablet depleted
currentFuelLevel = 50     -- Enough fuel to walk/dig 6 blocks, but LESS than mockWarpCost (200)
miner3.pos = { x = 12, y = 62, z = 21, dir = 0 }
local fallbackOk1, fallbackMode1 = miner3:returnToHome()
assertTrue(fallbackOk1, "fallback dig-to-home succeeded when warp fuel cost > available fuel")
assertEq(fallbackMode1, "dug", "used dig-to-home fallback when fuel < estimateWarpCost('home')")
assertEq(warpCount, 1, "did NOT call warpToPoint when fuel < warpCost")
assertTrue(miner3:isAtHome(), "arrived at Home (10, 64, 20) via dig-to-home fallback")
assertEq(miner3.pos.dir, 1, "aligned with Home facing direction (East = 1) after dig-to-home")

-- Test 9C-2: Fallback to dig-to-home when the End Automata breaks (`automataIntact = false`)
automataIntact = false
currentFuelLevel = 500
miner3.pos = { x = 11, y = 60, z = 20, dir = 2 }
local fallbackOk2, fallbackMode2 = miner3:returnToHome()
assertTrue(fallbackOk2, "fallback dig-to-home succeeded when End Automata broke")
assertEq(fallbackMode2, "dug", "used dig-to-home fallback when End Automata is broken")
assertTrue(miner3:isAtHome(), "arrived at Home (10, 64, 20) when End Automata is broken")
assertEq(miner3.pos.dir, 1, "aligned with Home facing direction (East = 1)")

-- Test 9D & 9E: Restore End Automata, test digging with `automata.digBlock()` and mining the chunk's ores across Y levels
automataIntact = true
currentFuelLevel = 1000
miner3:sethome("n")
miner3:start()

-- Set up a chunk where there are 0 ores at surface Y=64, and 1 deep diamond ore at Y=56 (8 blocks down)
local deepOreMined = false
mockPeripheral.chunkAnalyze = function()
    if deepOreMined then
        return {}
    end
    return { ["minecraft:deepslate_diamond_ore"] = 1 }
end
mockPeripheral.scan = function()
    if not deepOreMined and miner3.pos.y <= 56 then
        return {
            { name = "minecraft:deepslate_diamond_ore", x = 1, y = 0, z = 0, tags = { "forge:ores" } },
        }
    end
    return {}
end
mockEndAutomata.digBlock = function(opts)
    automataDigCalls = automataDigCalls + 1
    if miner3.pos.y <= 56 then
        deepOreMined = true
        automataInv[3] = { name = "minecraft:diamond", count = 1, tags = { ["forge:gems"] = true } }
    end
    return true
end

-- Worker step 1 at Y=64: local scan(8) finds 0 ores, chunkAnalyze() reports 1 ore in chunk -> descends to Y=56!
local chunkStep1 = miner3:stepWorker()
assertEq(chunkStep1, "exploring", "stepWorker descends into chunk when chunkAnalyze() reports remaining ores")
assertEq(miner3.pos.y, 56, "turtle descended 8 blocks into the chunk to Y=56")

-- Worker step 2 at Y=56: local scan(8) finds the deep diamond ore in the chunk and mines it using `automata.digBlock()`!
local chunkStep2 = miner3:stepWorker()
assertEq(chunkStep2, "mined", "stepWorker mined the deep chunk ore at Y=56")
assertTrue(deepOreMined, "deep chunk ore was mined via End Automata digBlock()")
assertTrue(automataDigCalls >= 1, "automata.digBlock() was used to mine the ore")

-- Worker step 3: chunkAnalyze() now reports 0 ores left in the chunk -> teleports Home and waits for the mined diamond to unload!
local chunkStep3 = miner3:stepWorker()
assertEq(chunkStep3, "waiting_unload", "once chunk has 0 ores left, turtle teleports Home and waits for ore unload")
assertTrue(miner3:isAtHome(), "turtle teleported back to Home after finishing chunk")
assertEq(miner3.chunkOresRemaining, 0, "chunkOresRemaining is 0")

-- 10. Test 2-Computer Strategy (Controller Advanced Computer + End Automata Turtle + Sophisticated Storage Barrel + Ender Modems):
--     10A: Installer asks which computer it is ("c" for Controller) and installs controller files
writtenFiles = {}
promptAnswers = { "c", "y" }
installChunk()
assertTrue(writtenFiles["/controller/main.lua"] ~= nil, "installer wrote /controller/main.lua when 'c' (Controller) is chosen")
assertTrue(writtenFiles["/controller/main.cfg"] ~= nil, "installer wrote /controller/main.cfg for Controller")
assertTrue(writtenFiles["/controller/lib/ores/main.lua"] ~= nil, "installer wrote /controller/lib/ores/main.lua")
assertTrue(writtenFiles["/startup.lua"] ~= nil, "installer wrote /startup.lua")

--     10B: Verify all Base blocks are in the forbidden blocks list so the Turtle will never break its base
assertTrue(miner3:isProtectedBlock("computercraft:computer_advanced"), "Base Advanced Computer is forbidden")
assertTrue(miner3:isProtectedBlock("computercraft:wireless_modem_advanced"), "Ender Modem is forbidden")
assertTrue(miner3:isProtectedBlock("advancedperipherals:geo_scanner"), "Geo Scanner is forbidden")
assertTrue(miner3:isProtectedBlock("sophisticatedstorage:barrel"), "Sophisticated Storage Barrel is forbidden")
assertTrue(miner3:isProtectedBlock("sophisticatedstorage:gold_barrel"), "Sophisticated Storage Gold Barrel is forbidden")
assertTrue(miner3:isProtectedBlock("mekanism:ultimate_energy_cube"), "Energy Cube is forbidden")
assertTrue(miner3:isProtectedBlock("fluxnetworks:flux_plug"), "Flux Plug is forbidden")
assertTrue(miner3:isProtectedBlock("fluxnetworks:flux_point"), "Flux Point is forbidden")
assertTrue(miner3:isProtectedBlock("allthemodium:teleport_pad"), "Teleport Pad is forbidden")
assertTrue(miner3:isProtectedBlock("minecraft:bedrock"), "Bedrock is forbidden")

--     10C: Full 2-Computer Mining Cycle over Ender Modem + Unloading into Sophisticated Storage Barrel (keeping Energy Cube)
local baseComputerMod = assert(loadfile("./base_computer.lua"))("base_computer")

-- Simulate the exact 2x2 Base setup from the screenshot:
-- Geo Scanner at (0, 0, 0) in scanner-space:
--   - Advanced Computer at (0, 0, 1)
--   - Ender Modem on top of Advanced Computer at (0, 1, 1)
--   - Sophisticated Storage Barrel at (1, 0, 0)
--   - Advanced Turtle at Home at (1, 0, 1), facing North (dir = 0, so Barrel at (1, 0, 0) is directly North/in front of the Turtle!)
--   - Two ores in the chunk:
--       1) Iron Ore at scanner (1, -2, 1) -> relative to Turtle Home (1, 0, 1) this is (0, -2, 0) (2 blocks straight down!)
--       2) Diamond Ore at scanner (2, -2, 1) -> relative to Turtle Home (1, 0, 1) this is (+1, -2, 0) (2 down, 1 East!)
local baseScanCycle = 0
local baseScannerPeripheral = {
    scan = function(r)
        baseScanCycle = baseScanCycle + 1
        if baseScanCycle == 1 then
            return {
                { name = "advancedperipherals:geo_scanner", x = 0, y = 0, z = 0, tags = {} },
                { name = "computercraft:computer_advanced", x = 0, y = 0, z = 1, tags = {} },
                { name = "computercraft:wireless_modem_advanced", x = 0, y = 1, z = 1, tags = {} },
                { name = "sophisticatedstorage:barrel", x = 1, y = 0, z = 0, tags = {} },
                { name = "computercraft:turtle_advanced", x = 1, y = 0, z = 1, tags = {} },
                { name = "minecraft:iron_ore", x = 1, y = -2, z = 1, tags = { "forge:ores" } },
                { name = "minecraft:diamond_ore", x = 2, y = -2, z = 1, tags = { "forge:ores" } },
            }
        else
            -- Second cycle: all ores in first batch were mined, now 1 gold ore appears
            return {
                { name = "advancedperipherals:geo_scanner", x = 0, y = 0, z = 0, tags = {} },
                { name = "computercraft:computer_advanced", x = 0, y = 0, z = 1, tags = {} },
                { name = "sophisticatedstorage:barrel", x = 1, y = 0, z = 0, tags = {} },
                { name = "computercraft:turtle_advanced", x = 1, y = 0, z = 1, tags = {} },
                { name = "minecraft:gold_ore", x = 1, y = -3, z = 1, tags = { "forge:ores" } },
            }
        end
    end,
}

local baseScannerObj = GeoScanner.new(baseScannerPeripheral, "back")
local baseComp = nil
local turtleMiner4 = nil

-- Linked mock Ender Modems: when Turtle transmits on channel 4821, Base Computer receives it and transmits back!
local openChannels = {}
local baseModem = {
    isWireless = function() return true end,
    open = function(ch) openChannels[ch] = true end,
    isOpen = function(ch) return openChannels[ch] == true end,
    transmit = function(ch, replyCh, payload)
        if turtleMiner4 and ch == GeoScanner.MODEM_CHANNEL then
            turtleMiner4:handleModemMessage(payload)
        end
    end,
}
local turtleModem = {
    isWireless = function() return true end,
    open = function(ch) openChannels[ch] = true end,
    isOpen = function(ch) return openChannels[ch] == true end,
    transmit = function(ch, replyCh, payload)
        if baseComp and ch == GeoScanner.MODEM_CHANNEL then
            baseComp:handleModemMessage(payload)
        end
    end,
}

baseComp = baseComputerMod.new({
    scanner = baseScannerObj,
    modem = baseModem,
})

-- Set up Turtle inventory: Slot 1 has an Energy Cube (`mekanism:ultimate_energy_cube`), which MUST stay in the turtle for fuel!
-- Slot 16 has a full stack of coal (`minecraft:coal`), which MUST stay in the turtle as fuel!
local barrelStoredItems = {}
local turtle4Inv = {
    [1] = { name = "mekanism:ultimate_energy_cube", count = 1, energy = 5000, tags = {} },
    [16] = { name = "minecraft:coal", count = 64, tags = {} },
}
local t4Slot = 1
local t4WarpCalls = 0
local t4Fuel = 1000

local t4Automata = {
    savePoint = function(name)
        savedWarpPoints[name] = true
        return true
    end,
    points = function() return { "home" } end,
    estimateWarpCost = function() return 10 end,
    getWarpCooldown = function() return 0 end,
    warpToPoint = function(name)
        if name == "home" and t4Fuel >= 10 then
            t4Fuel = t4Fuel - 10
            t4WarpCalls = t4WarpCalls + 1
            return true
        end
        return nil, "Not enough fuel"
    end,
    chargeTurtle = function()
        local item = turtle4Inv[t4Slot]
        if item and item.name:find("energy_cube", 1, true) then
            t4Fuel = t4Fuel + 500
            return true, 500
        end
        return nil, "Not an energy item"
    end,
}

turtleMiner4 = turtleMinerMod.new({
    automata = t4Automata,
    modem = turtleModem,
})
_G.gps = nil
turtleMiner4.pos = { x = 0, y = 0, z = 0, dir = 0 }
turtleMiner4:sethome("n") -- Turtle at Home (0,0,0) facing North (0)

_G.turtle = {
    getFuelLevel = function() return t4Fuel end,
    getSelectedSlot = function() return t4Slot end,
    select = function(s) t4Slot = s; return true end,
    getItemCount = function(s) return turtle4Inv[s] and turtle4Inv[s].count or 0 end,
    getItemDetail = function(s) return turtle4Inv[s] end,
    forward = function() t4Fuel = t4Fuel - 1; return true end,
    up = function() t4Fuel = t4Fuel - 1; return true end,
    down = function() t4Fuel = t4Fuel - 1; return true end,
    turnLeft = function() return true end,
    turnRight = function() return true end,
    detect = function() return false end,
    detectUp = function() return false end,
    detectDown = function() return false end,
    inspect = function()
        -- When Turtle is at Home (0,0,0) and facing North (dir = 0), the Sophisticated Storage Barrel is directly in front!
        if turtleMiner4:isAtHome() and turtleMiner4.pos.dir == 0 then
            return true, { name = "sophisticatedstorage:barrel" }
        end
        -- When facing West (dir = 3) at Home, the Base Advanced Computer is to its left
        if turtleMiner4:isAtHome() and turtleMiner4.pos.dir == 3 then
            return true, { name = "computercraft:computer_advanced" }
        end
        return false, "No block"
    end,
    inspectUp = function() return false, "No block" end,
    inspectDown = function() return false, "No block" end,
    dig = function()
        -- Simulate mining diamond ore + picking up cobbled deepslate
        turtle4Inv[2] = { name = "minecraft:diamond", count = 2, tags = { ["forge:gems"] = true } }
        turtle4Inv[3] = { name = "minecraft:cobbled_deepslate", count = 4, tags = {} }
        return true
    end,
    digUp = function() return true end,
    digDown = function()
        -- Simulate mining iron ore
        turtle4Inv[4] = { name = "minecraft:raw_iron", count = 3, tags = { ["forge:raw_materials"] = true } }
        return true
    end,
    placeDown = function() return false end,
    placeUp = function() return false end,
    place = function() return false end,
    drop = function(dropCount)
        -- Only allow dropping into the Sophisticated Storage Barrel at Home facing North (0)!
        assertTrue(turtleMiner4:isAtHome(), "turtle only drops items when back at Home")
        assertEq(turtleMiner4.pos.dir, 0, "turtle faces the Sophisticated Storage Barrel when unloading")
        local item = turtle4Inv[t4Slot]
        if item then
            local toDrop = (dropCount and dropCount > 0 and dropCount < item.count) and dropCount or item.count
            table.insert(barrelStoredItems, { name = item.name, count = toDrop })
            item.count = item.count - toDrop
            if item.count <= 0 then
                turtle4Inv[t4Slot] = nil
            end
            return true
        end
        return false
    end,
}

-- Start the Turtle
turtleMiner4:start()

-- Step 1: Turtle has empty oreQueue -> requests ore locations from Base Computer over Ender Modem!
-- Base Computer scans, calibrates Turtle offset (1, 0, 1), marks Base blocks as forbidden, and sends 2 ores:
--   Ore 1: Iron Ore at (0, -2, 0)
--   Ore 2: Diamond Ore at (1, -2, 0)
-- Turtle mines Ore 1 (Iron Ore at (0, -2, 0)), leaving 1 ore in queue!
local s1 = turtleMiner4:stepWorker()
assertEq(s1, "mined", "Step 1: Turtle received ore locations from Base Computer and mined first ore")
assertEq(baseComp.turtleOffset.x, 1, "Base Computer auto-calibrated Turtle Home offset X = 1")
assertEq(baseComp.turtleOffset.y, 0, "Base Computer auto-calibrated Turtle Home offset Y = 0")
assertEq(baseComp.turtleOffset.z, 1, "Base Computer auto-calibrated Turtle Home offset Z = 1")
assertTrue(turtleMiner4:isBlocked(-1, 0, 0), "Base Advanced Computer at (-1,0,0) is marked forbidden in blockedCoords")
assertTrue(turtleMiner4:isBlocked(-1, 0, -1), "Base Geo Scanner at (-1,0,-1) is marked forbidden in blockedCoords")
assertTrue(turtleMiner4:isBlocked(0, 0, -1), "Sophisticated Storage Barrel at (0,0,-1) is marked forbidden in blockedCoords")
assertEq(#turtleMiner4.oreQueue, 1, "1 ore location remaining in Turtle's queue")

-- Step 2: Turtle mines the last passed ore (Diamond Ore at (1, -2, 0)).
-- Because no ores are left in the passed list (#oreQueue == 0), the Turtle immediately:
--   1) Teleports back to Home via End Automata (`warpToPoint("home")`) and aligns with Home (dir = 0)
--   2) Unloads EVERYTHING in its inventory (raw_iron, diamond, cobbled_deepslate) into the Sophisticated Storage Barrel
--   3) Keeps the Energy Cube (`mekanism:ultimate_energy_cube`) in slot 1 for fuel!
local s2 = turtleMiner4:stepWorker()
assertEq(s2, "mined", "Step 2: Turtle mined final passed ore, teleported Home, and unloaded to Barrel")
assertEq(t4WarpCalls, 1, "Turtle teleported back to Home using End Automata when no ores were left")
assertTrue(turtleMiner4:isAtHome(), "Turtle is back at Home (0,0,0)")
assertEq(turtleMiner4.pos.dir, 0, "Turtle is aligned with Home facing North (0)")
assertTrue(turtle4Inv[1] ~= nil and turtle4Inv[1].name == "mekanism:ultimate_energy_cube", "Energy Cube stayed in Turtle's inventory for fuel")
assertTrue(turtle4Inv[16] ~= nil and turtle4Inv[16].name == "minecraft:coal" and turtle4Inv[16].count == 64, "Coal stack of 64 stayed in Turtle's storage")
assertEq(turtle4Inv[2], nil, "Diamonds were placed into the Sophisticated Storage Barrel")
assertEq(turtle4Inv[3], nil, "Leftover cobbled_deepslate was placed into the Sophisticated Storage Barrel")
assertEq(turtle4Inv[4], nil, "Raw iron was placed into the Sophisticated Storage Barrel")
assertEq(#barrelStoredItems, 3, "All 3 non-Energy-Cube inventory slots were deposited into the Sophisticated Storage Barrel")

-- Step 3: The cycle repeats! Next worker step automatically requests the next batch of ores from the Base Computer!
local s3 = turtleMiner4:stepWorker()
assertEq(s3, "mined", "Step 3: Cycle repeated automatically — requested new scan from Base Computer, mined gold ore, teleported Home, and unloaded to Barrel")
assertEq(baseScanCycle, 2, "Base Computer performed second Geo Scanner scan for the new cycle")
assertEq(t4WarpCalls, 2, "Turtle teleported Home again at the end of the second cycle")
assertTrue(turtle4Inv[1] ~= nil and turtle4Inv[1].name == "mekanism:ultimate_energy_cube", "Energy Cube still kept in Turtle's inventory")
assertTrue(turtle4Inv[16] ~= nil and turtle4Inv[16].name == "minecraft:coal" and turtle4Inv[16].count == 64, "Coal stack of 64 still kept in Turtle's storage")

-- 11. Test Pickaxe Auto-Equip, Netherrack Breaking, and Java Exception Protection:
--     11A: Inventory keeps pickaxe, modem, and energy items so they are never unloaded into the barrel or placed as waste
assertTrue(turtleMiner4:shouldKeepInInventoryAtBase({ name = "computercraft:wireless_modem_advanced" }), "Ender Modem is kept in turtle inventory at base")
assertTrue(turtleMiner4:shouldKeepInInventoryAtBase({ name = "minecraft:diamond_pickaxe" }), "Diamond Pickaxe is kept in turtle inventory at base")
assertTrue(turtleMiner4:isFuelOrToolItem({ name = "computercraft:wireless_modem_advanced" }), "Ender Modem is recognized as tool/peripheral")
assertTrue(turtleMiner4:isFuelOrToolItem({ name = "minecraft:diamond_pickaxe" }), "Pickaxe is recognized as tool/peripheral")

--     11B: Turtle detects tool side vs automata side correctly
assertEq(turtleMiner4:getAutomataSide(), "left", "Automata is on left side")
assertEq(turtleMiner4:getToolSide(), "right", "Tool side is right side")

--     11C: When digging a block (like netherrack) while a modem is on the tool side,
--          the turtle automatically swaps its Pickaxe from inventory onto the tool side and digs natively via CC:Tweaked!
local toolEquippedOnRight = "computercraft:wireless_modem_advanced"
turtle4Inv[2] = { name = "minecraft:diamond_pickaxe", count = 1 }
local mockWorldBlock = "minecraft:netherrack"
local netherrackDugNatively = false

_G.turtle.equipRight = function()
    local prevEquipped = toolEquippedOnRight
    local selSlot = _G.turtle.getSelectedSlot()
    local itemInSlot = turtle4Inv[selSlot]
    toolEquippedOnRight = itemInSlot and itemInSlot.name or nil
    if prevEquipped then
        turtle4Inv[selSlot] = { name = prevEquipped, count = 1 }
    else
        turtle4Inv[selSlot] = nil
    end
    return true
end

_G.turtle.dig = function()
    if toolEquippedOnRight and toolEquippedOnRight:find("pickaxe", 1, true) then
        netherrackDugNatively = true
        mockWorldBlock = nil
        return true
    end
    return false, "No tool to dig with"
end

_G.turtle.detect = function()
    return mockWorldBlock ~= nil
end

local digSuccess, digErr = turtleMiner4:tryDigDirection("forward")
assertTrue(digSuccess, "tryDigDirection succeeded in breaking netherrack")
assertTrue(netherrackDugNatively, "Netherrack was broken natively via turtle.dig with auto-equipped pickaxe")
assertEq(toolEquippedOnRight, "minecraft:diamond_pickaxe", "Pickaxe was auto-equipped onto the right side")
assertEq(turtle4Inv[2].name, "computercraft:wireless_modem_advanced", "Ender Modem was placed into inventory slot")

-- 12. Test Keeping a Stack (64) of Any Fuel Item & Emergency Return When No Coal:
--     12A: Unloading into barrel keeps up to a full stack (64) of fuel items, depositing excess fuel and all ores
local test12Inv = {
    [1] = { name = "minecraft:coal", count = 64 },      -- Full stack of coal: MUST be kept
    [2] = { name = "minecraft:coal", count = 16 },      -- Excess 16 coal: MUST be deposited
    [3] = { name = "minecraft:charcoal", count = 64 },  -- Full stack of charcoal: MUST be kept
    [4] = { name = "minecraft:charcoal", count = 20 },  -- Excess 20 charcoal: MUST be deposited
    [5] = { name = "minecraft:raw_iron", count = 32 },  -- Mined ore: MUST be deposited
    [6] = { name = "mekanism:ultimate_energy_cube", count = 1 }, -- Energy Cube: MUST be kept
}
local test12Barrel = {}
local test12Selected = 1

local miner5 = turtleMinerMod.new({
    automata = t4Automata,
})
miner5.pos = { x = 0, y = 0, z = 0, dir = 0 }
miner5:sethome("n")

_G.turtle = {
    getFuelLevel = function() return 1000 end,
    getSelectedSlot = function() return test12Selected end,
    select = function(s) test12Selected = s; return true end,
    getItemCount = function(s) return test12Inv[s] and test12Inv[s].count or 0 end,
    getItemDetail = function(s) return test12Inv[s] end,
    inspect = function() return true, { name = "sophisticatedstorage:barrel" } end,
    inspectUp = function() return false end,
    inspectDown = function() return false end,
    turnLeft = function() return true end,
    turnRight = function() return true end,
    forward = function() return true end,
    up = function() return true end,
    down = function() return true end,
    drop = function(dropCount)
        local item = test12Inv[test12Selected]
        if item then
            local toDrop = (dropCount and dropCount > 0 and dropCount < item.count) and dropCount or item.count
            table.insert(test12Barrel, { name = item.name, count = toDrop })
            item.count = item.count - toDrop
            if item.count <= 0 then
                test12Inv[test12Selected] = nil
            end
            return true
        end
        return false
    end,
}

assertTrue(miner5:hasItemsToUnload(), "miner5 detects excess fuel and ores that must be unloaded")
local unloadedCount = miner5:unloadToBarrel()
assertTrue(unloadedCount >= 3, "unloaded excess coal, excess charcoal, and raw iron")

-- Verify inventory contents after depositing:
assertEq(test12Inv[1].count, 64, "Kept exactly a stack of 64 coal in slot 1")
assertEq(test12Inv[2], nil, "Excess 16 coal was unloaded from slot 2 into barrel")
assertEq(test12Inv[3].count, 64, "Kept exactly a stack of 64 charcoal in slot 3")
assertEq(test12Inv[4], nil, "Excess 20 charcoal was unloaded from slot 4 into barrel")
assertEq(test12Inv[5], nil, "All 32 raw iron was unloaded from slot 5 into barrel")
assertEq(test12Inv[6].name, "mekanism:ultimate_energy_cube", "Energy Cube stayed in slot 6")

-- Verify barrel received the expected items:
local totalCoalInBarrel = 0
local totalCharcoalInBarrel = 0
local totalIronInBarrel = 0
for _, deposited in ipairs(test12Barrel) do
    if deposited.name == "minecraft:coal" then
        totalCoalInBarrel = totalCoalInBarrel + deposited.count
    elseif deposited.name == "minecraft:charcoal" then
        totalCharcoalInBarrel = totalCharcoalInBarrel + deposited.count
    elseif deposited.name == "minecraft:raw_iron" then
        totalIronInBarrel = totalIronInBarrel + deposited.count
    end
end
assertEq(totalCoalInBarrel, 16, "Barrel received exactly 16 excess coal")
assertEq(totalCharcoalInBarrel, 20, "Barrel received exactly 20 excess charcoal")
assertEq(totalIronInBarrel, 32, "Barrel received all 32 raw iron")
assertEq(miner5:hasItemsToUnload(), false, "No more items to unload once only 64 fuel and Energy Cube remain")
assertEq(miner5:hasOresInInventory(), false, "Kept fuel stacks are not considered undeposited ores")

--     12B: Turtle immediately returns to Home when there is no coal in inventory:
-- Simulate turtle out in the field at (5, -3, 7) with 0 coal in inventory!
test12Inv[1] = nil -- remove coal
test12Inv[3] = nil -- remove charcoal
miner5.pos = { x = 5, y = -3, z = 7, dir = 2 }
miner5.running = true
assertEq(miner5:hasCoal(), false, "Turtle has 0 coal in inventory")

local emergencyStep = miner5:stepWorker()
assertEq(emergencyStep, "returned_home", "Turtle immediately returned to Home when out of coal")
assertTrue(miner5:isAtHome(), "Turtle is back at Home (0, 0, 0)")
assertEq(miner5.phase, "WAITING FOR COAL", "Phase transitioned to WAITING FOR COAL")

-- If stepWorker is called again while still having 0 coal at Home, it stays idle:
local idleStep = miner5:stepWorker()
assertEq(idleStep, "no_coal", "Turtle stays idle at Home when coal is 0")
assertTrue(miner5:isAtHome(), "Turtle stays at Home")

-- Once coal is added to inventory, it resumes:
test12Inv[1] = { name = "minecraft:coal", count = 64 }
miner5.oreQueue = { { name = "minecraft:diamond_ore", x = 1, y = 0, z = 0, fromHome = true } }
local resumeStep = miner5:stepWorker()
assertEq(miner5.phase, "MINING", "Turtle resumes mining once coal is placed in inventory")

-- 13. Test New Architecture: libcrypto, libworkernet, Pairing, Controller & Headless Worker
local Crypto = dofile("lib/crypto/main.lua")
local Workernet = dofile("lib/workernet/main.lua")
local Device = dofile("worker/lib/device/main.lua")
local Pairing = dofile("controller/lib/pairing/main.lua")
local Controller = dofile("controller/controller.lua")
local Ores = dofile("controller/lib/ores/main.lua")
local Worker = dofile("worker/worker.lua")

-- 13.1 libcrypto verification
assertEq(Crypto.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 empty string")
assertEq(Crypto.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 'abc'")
assertEq(Crypto.hmacSha256("key", "The quick brown fox jumps over the lazy dog"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8", "HMAC-SHA256 test vector")

local pairCode = Crypto.generatePairCode()
assertEq(#pairCode, 6, "Pair code is 6 digits")
assertTrue(pairCode:match("^%d%d%d%d%d%d$") ~= nil, "Pair code is numeric")
local normCode, normErr = Crypto.normalizePairCode(" 482 - 915 ")
assertEq(normCode, "482915", "Pair code normalization strips spaces and dashes")

local kdfKey = Crypto.kdf("secret", "salt", "info", 32)
local enc = Crypto.encrypt(kdfKey, "Hello CC:Tweaked Worker", "nonce123")
local dec = Crypto.decrypt(kdfKey, enc, "nonce123")
assertEq(dec, "Hello CC:Tweaked Worker", "CTR mode encrypt/decrypt")

-- 13.2 libworkernet secure transport & replay protection
local testNetBus = {}
local mockNetModemA = {
    isOpen = function() return true end,
    open = function() end,
    close = function() end,
    transmit = function(ch, rep, pkt) table.insert(testNetBus, { ch = ch, pkt = pkt }) end,
}
local nodeA = Workernet.new({ modem = mockNetModemA, localId = 100 })
local nodeB = Workernet.new({ modem = mockNetModemA, localId = 200 })
nodeA:setSessionKey(200, kdfKey)
nodeB:setSessionKey(100, kdfKey)

assertTrue(nodeA:send(200, { type = "status", text = "secure payload" }), "NodeA send encrypted")
assertEq(#testNetBus, 1, "packet sent to bus")
local pkt = testNetBus[1].pkt
assertEq(pkt.from, 100, "pkt from")
assertEq(pkt.to, 200, "pkt to")
assertTrue(pkt.sig ~= nil, "pkt has HMAC signature")

local unpacked, sender, unErr = nodeB:unpackPacket(pkt)
assertEq(unErr, nil, "no unpack error")
assertEq(sender, 100, "sender is node 100")
assertEq(unpacked.text, "secure payload", "decrypted payload match")

-- Replay check
local _, _, repErr = nodeB:unpackPacket(pkt)
assertTrue(repErr and repErr:match("Replay"), "detected replay attack on duplicate sequence")

-- Repeated table serialization test (ensures CC textutils repeated entries does not crash)
local sharedTag = { "forge:ores" }
local repeatedPayload = {
    type = "ore_batch",
    ores = {
        { name = "iron", tags = sharedTag },
        { name = "gold", tags = sharedTag },
    }
}
local serStr = Workernet.serialize(repeatedPayload)
assertTrue(type(serStr) == "string" and #serStr > 0, "Workernet.serialize succeeds with repeated entries")
local deser = Workernet.unserialize(serStr)
assertEq(#deser.ores, 2, "Workernet.unserialize recovers repeated entries")

-- 13.3 6-Digit Numeric Pairing Handshake
local testPairBus = {}
local makePairModem = function(id)
    return {
        isOpen = function() return true end,
        open = function() end,
        close = function() end,
        transmit = function(ch, rep, pkt) table.insert(testPairBus, { ch = ch, pkt = pkt }) end,
    }
end
local netCtrl = Workernet.new({ modem = makePairModem(1), localId = 1 })
local netWork = Workernet.new({ modem = makePairModem(5), localId = 5 })

netCtrl.pullMessage = function(self)
    for i, m in ipairs(testPairBus) do
        if m.ch == self.pairChannel or m.ch == self.channel then
            table.remove(testPairBus, i)
            return m.pkt, m.pkt and m.pkt.from or nil, m.ch
        end
    end
    return nil
end
netWork.pullMessage = function(self)
    for i, m in ipairs(testPairBus) do
        if m.ch == self.pairChannel or m.ch == self.channel then
            table.remove(testPairBus, i)
            return m.pkt, m.pkt and m.pkt.from or nil, m.ch
        end
    end
    return nil
end

local workerPairCode = "654321"
-- Controller initiates pairing with code 654321
local cNonce = "11223344"
local pairReq = {
    type = "pair_req",
    controller_id = 1,
    nonce = cNonce,
    sig = Crypto.hmacSha256(workerPairCode, "pair_req:1:" .. cNonce)
}
table.insert(testPairBus, { ch = netWork.pairChannel, pkt = pairReq })

-- Worker receives pair_req
local wMsg = netWork:pullMessage()
assertTrue(Crypto.verifySignature(workerPairCode, "pair_req:1:" .. cNonce, wMsg.sig), "Worker verified pair_req signature")
local wNonce = "55667788"
local derivedKeyWorker = Crypto.kdf(workerPairCode, cNonce .. wNonce, "minerhaven_session_v1", 32)
local pairAck = {
    type = "pair_ack",
    worker_id = 5,
    nonce = wNonce,
    c_nonce = cNonce,
    sig = Crypto.hmacSha256(workerPairCode, "pair_ack:5:" .. wNonce .. ":" .. cNonce)
}
table.insert(testPairBus, { ch = netCtrl.pairChannel, pkt = pairAck })

-- Controller receives pair_ack
local cAck = netCtrl:pullMessage()
assertTrue(Crypto.verifySignature(workerPairCode, "pair_ack:5:" .. wNonce .. ":" .. cNonce, cAck.sig), "Controller verified pair_ack signature")
local derivedKeyController = Crypto.kdf(workerPairCode, cNonce .. wNonce, "minerhaven_session_v1", 32)
assertEq(derivedKeyWorker, derivedKeyController, "Controller and Worker derived identical cryptographic session key")

-- 13.4 Authoritative Scan Radius Enforcement
-- Create Controller with scanRadius = 12
local testCtrl = Controller.new({ scanRadius = 12 })
assertEq(testCtrl.config.scanRadius, 12, "Controller initialized with radius 12")

-- Protected blocks check in Ores
assertTrue(Ores.isProtectedBlock("computercraft:turtle_advanced"), "Turtle is protected")
assertTrue(Ores.isProtectedBlock("advancedperipherals:geo_scanner"), "GeoScanner is protected")
assertTrue(Ores.isProtectedBlock("fluxnetworks:flux_plug"), "Flux Plug is protected")
assertTrue(Ores.isProtectedBlock("fluxnetworks:flux_point"), "Flux Point is protected")
assertTrue(Ores.isProtectedBlock("sophisticatedstorage:diamond_barrel"), "Sophisticated barrel is protected")
assertTrue(Ores.isProtectedBlock("mekanism:basic_energy_cube"), "Energy cube is protected")

-- Mock scanner returning blocks
local scanMockBlocks = {
    { name = "minecraft:stone", x = 1, y = 0, z = 0 },
    { name = "computercraft:turtle_advanced", x = 1, y = 0, z = 1 }, -- turtle home spot
    { name = "minecraft:diamond_ore", x = 3, y = -5, z = 2 },
    { name = "minecraft:iron_ore", x = -2, y = 1, z = 4 },
}
testCtrl.ores.rawScan = function(self, r)
    assertEq(r, 12, "AUTHORITATIVE: Scanner was called with Controller's configured radius (12), not overridden!")
    return scanMockBlocks
end

testCtrl.net.send = function(self, targetId, payload)
    assertEq(payload.type, "ore_locations", "Payload is ore_locations")
    assertEq(payload.scanRadius, 12, "Authoritative radius 12 sent in payload")
    assertEq(#payload.ores, 2, "2 ores found")
    return true
end

-- Simulate turtle sending request_ores (which previously had requestedRadius = 8)
testCtrl:handlePacket({ type = "request_ores", radius = 8 }, 5)
assertEq(testCtrl.lastScanOres, 2, "Controller scanned and sent 2 ores using authoritative radius 12")
assertEq(testCtrl.ores.turtleOffset.x, 1, "Turtle offset X calibrated from scan")
assertEq(testCtrl.ores.turtleOffset.z, 1, "Turtle offset Z calibrated from scan")

print(("ALL %d ASSERTIONS PASSED!"):format(passed))
