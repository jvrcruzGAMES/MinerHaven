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

local mhChunk = assert(loadfile("./minerhaven.lua"))
assertEq(mhChunk("cost", "8"), 0, "CLI cost command")
assertEq(mhChunk("scan", "8", "diamond"), 0, "CLI scan command")
assertEq(mhChunk("chunk"), 0, "CLI chunk command")
assertEq(mhChunk("help"), 0, "CLI help command")

local eventQueue = {
    { "key", keys.enter },
    { "key", keys.c },
    { "key", keys.f },
    { "key", keys.three },
    { "key", keys.s },
    { "key", keys.q },
}
_G.os.pullEvent = function()
    local ev = table.remove(eventQueue, 1)
    if not ev then return "key", keys.q end
    return unpack(ev)
end

mhChunk()

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
-- 1) "Is this installation for a Turtle?" -> "y"
-- 2) "Set the turtle's current location as its Home?" -> "y"
-- 3) "Turtle facing direction (n/e/s/w) [n]:" -> "e"
local promptAnswers = { "y", "y", "e" }
_G.read = function()
    return table.remove(promptAnswers, 1) or ""
end

local installChunk = assert(loadfile("./install.lua"))
installChunk()
assertTrue(writtenFiles["/lib/geoscanner.lua"] ~= nil, "installer wrote /lib/geoscanner.lua")
assertTrue(writtenFiles["/minerhaven.lua"] ~= nil, "installer wrote /minerhaven.lua")
assertTrue(writtenFiles["/turtle_miner.lua"] ~= nil, "installer wrote /turtle_miner.lua for turtle install")
assertTrue(writtenFiles["/home.cfg"] ~= nil, "installer saved turtle's current location to /home.cfg")
assertTrue(writtenFiles["/startup/99_minerhaven.lua"]:find("turtle_miner.lua", 1, true) ~= nil, "startup launches turtle_miner.lua")

-- 7. Test turtle_miner.lua full lifecycle:
--    Idle -> Start -> Mine ores by tag until inventory full -> Return Home -> Wait until ores unloaded -> Resume -> Stop (stays idle, does not exit)
local mockInv = {}
for s = 1, 16 do mockInv[s] = nil end

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
    for s = 1, 16 do
        mockInv[s] = { name = "minecraft:diamond_ore", count = 1, tags = { ["forge:ores"] = true } }
    end
end

local function clearOresFromInventory()
    for s = 1, 16 do
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

_G.turtle = {
    getFuelLevel = function() return 5000 end,
    getSelectedSlot = function() return 1 end,
    select = function() return true end,
    getItemCount = function() return 0 end,
    getItemDetail = function() return nil end,
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

-- Test 8D: Discarding non-ore blocks (dirt, cobblestone, etc.) while keeping ores and fuel
local testInv = {
    [1] = { name = "minecraft:raw_iron", count = 8, tags = { ["forge:raw_materials"] = true } },
    [2] = { name = "minecraft:dirt", count = 32, tags = {} },
    [3] = { name = "minecraft:cobblestone", count = 64, tags = {} },
    [4] = { name = "minecraft:coal", count = 16, tags = {} },
    [5] = { name = "minecraft:cobbled_deepslate", count = 20, tags = {} },
}
local selectedSlot = 1
_G.turtle.select = function(s) selectedSlot = s; return true end
_G.turtle.getSelectedSlot = function() return selectedSlot end
_G.turtle.getItemCount = function(s) return testInv[s] and testInv[s].count or 0 end
_G.turtle.getItemDetail = function(s) return testInv[s] end
_G.turtle.dropDown = function()
    testInv[selectedSlot] = nil
    return true
end
_G.turtle.drop = _G.turtle.dropDown

local droppedCount = miner2:dropWasteBlocks()
assertEq(droppedCount, 3, "dropped 3 slots of non-ore blocks (dirt, cobblestone, cobbled_deepslate)")
assertTrue(testInv[1] ~= nil, "kept raw_iron ore in slot 1")
assertEq(testInv[2], nil, "discarded dirt in slot 2")
assertEq(testInv[3], nil, "discarded cobblestone in slot 3")
assertTrue(testInv[4] ~= nil, "kept coal fuel in slot 4")
assertEq(testInv[5], nil, "discarded cobbled_deepslate in slot 5")

print(("ALL %d ASSERTIONS PASSED!"):format(passed))
