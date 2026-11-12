-- Automated test suite for MinerHaven (lib/geoscanner.lua, minerhaven.lua, install.lua)
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

-- 3. Test isOre & enrichBlock
local diamondBlock = GeoScanner.enrichBlock({
    name = "minecraft:deepslate_diamond_ore",
    x = 3,
    y = -4,
    z = 0,
    tags = { "forge:ores", "minecraft:diamond_ores" },
})
assertTrue(diamondBlock.isOre, "diamond is ore")
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
local ores, scanErr = scanner:scanOres(8, { retries = 3, retryDelay = 0 })
assertTrue(ores ~= nil, "scanOres with retries succeeded: " .. tostring(scanErr))
assertEq(#ores, 3, "3 ore blocks returned (stone filtered out)")
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
    c = 46, j = 36, k = 37, enter = 28, space = 57, up = 200, down = 208,
    left = 203, right = 205, minus = 12, equals = 13, leftBracket = 26,
    rightBracket = 27, slash = 53, pageUp = 201, pageDown = 209,
}

_G.term = {
    isColor = function() return true end,
    getSize = function() return 26, 20 end, -- Test compact Pocket Computer dimensions!
    setTextColor = function() end,
    setBackgroundColor = function() end,
    setCursorPos = function() end,
    setCursorBlink = function() end,
    write = function() end,
    clear = function() end,
}

-- Test CLI commands
local mhChunk = assert(loadfile("./minerhaven.lua"))
assertEq(mhChunk("cost", "8"), 0, "CLI cost command")
assertEq(mhChunk("scan", "8", "diamond"), 0, "CLI scan command")
assertEq(mhChunk("chunk"), 0, "CLI chunk command")
assertEq(mhChunk("help"), 0, "CLI help command")

-- Test TUI event sequence (Enter group -> switch to Chunk tab -> Scan chunk -> Quit)
local eventQueue = {
    { "key", keys.enter }, -- Select nearest group -> jumps to tab 2 (Radar)
    { "key", keys.c },     -- Clear filter
    { "key", keys.f },     -- Toggle Ores/All
    { "key", keys.three }, -- Switch to tab 3 (Chunk Analyze)
    { "key", keys.s },     -- Trigger chunkAnalyze()
    { "key", keys.q },     -- Quit TUI
}
_G.os.pullEvent = function()
    local ev = table.remove(eventQueue, 1)
    if not ev then return "key", keys.q end
    return unpack(ev)
end

mhChunk() -- Run interactive TUI until eventQueue finishes with 'q'

-- 6. Test install.lua with mocked http & fs
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
    exists = function() return false end,
    isDir = function() return true end,
    makeDir = function() end,
    open = function(path, mode)
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

local installChunk = assert(loadfile("./install.lua"))
installChunk()
assertTrue(writtenFiles["/lib/geoscanner.lua"] ~= nil, "installer wrote /lib/geoscanner.lua")
assertTrue(writtenFiles["/minerhaven.lua"] ~= nil, "installer wrote /minerhaven.lua")
assertTrue(writtenFiles["/startup/99_minerhaven.lua"] ~= nil, "installer wrote startup alias script")

print(("ALL %d ASSERTIONS PASSED!"):format(passed))
