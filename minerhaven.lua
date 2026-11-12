--- MinerHaven - Simple Interactive UI & CLI for the Advanced Peripherals Geo Scanner
-- Compatible with CC: Tweaked Computers, Pocket Computers, and Turtles.
--
-- Usage:
--   minerhaven                     Launch interactive UI
--   minerhaven scan [radius] [q]   Quick block/ore scan from CLI
--   minerhaven chunk [q]           Analyze ores in current chunk from CLI
--   minerhaven cost [radius]       Check FE scan cost and fuel capacity
--   minerhaven help                Show CLI help

-- Ensure local lib/ folder is on package.path regardless of working directory
local function setupPackagePath()
    local scriptDir = ""
    if shell and type(shell.getRunningProgram) == "function" then
        local running = shell.getRunningProgram()
        if fs and type(fs.getDir) == "function" then
            scriptDir = fs.getDir(running)
        end
    end
    local paths = {
        "?.lua",
        "?/init.lua",
        "lib/?.lua",
        "/lib/?.lua",
        "/minerhaven/lib/?.lua",
    }
    if scriptDir ~= "" then
        table.insert(paths, 1, "/" .. scriptDir .. "/lib/?.lua")
        table.insert(paths, 2, "/" .. scriptDir .. "/?.lua")
    end
    if package and package.path then
        package.path = table.concat(paths, ";") .. ";" .. package.path
    end
end

setupPackagePath()

local GeoScanner = require("geoscanner")

-- Color helper with monochrome fallback
local isColor = term and term.isColor and term.isColor() or false
local Palette = {
    bg = colors.black,
    fg = colors.white,
    headerBg = isColor and colors.blue or colors.white,
    headerFg = isColor and colors.white or colors.black,
    tabBg = isColor and colors.gray or colors.black,
    tabFg = isColor and colors.lightGray or colors.white,
    tabActiveBg = isColor and colors.cyan or colors.white,
    tabActiveFg = isColor and colors.black or colors.black,
    barBg = isColor and colors.gray or colors.black,
    barFg = isColor and colors.white or colors.white,
    accent = isColor and colors.yellow or colors.white,
    success = isColor and colors.lime or colors.white,
    warn = isColor and colors.orange or colors.white,
    err = isColor and colors.red or colors.white,
    muted = isColor and colors.lightGray or colors.white,
    selectedBg = isColor and colors.lightBlue or colors.white,
    selectedFg = isColor and colors.black or colors.black,
}

local function setColors(fg, bg)
    if term then
        if fg and term.setTextColor then term.setTextColor(fg) end
        if bg and term.setBackgroundColor then term.setBackgroundColor(bg) end
    end
end

local function padRight(str, width)
    str = tostring(str or "")
    if #str >= width then
        return str:sub(1, width)
    end
    return str .. string.rep(" ", width - #str)
end

local function writeAt(x, y, text, fg, bg)
    if not term then return end
    setColors(fg, bg)
    term.setCursorPos(x, y)
    term.write(text)
end

local function fillLine(y, width, fg, bg, text)
    writeAt(1, y, padRight(text or "", width), fg, bg)
end

--------------------------------------------------------------------------------
-- CLI Mode Helpers
--------------------------------------------------------------------------------

local function printHelp()
    print("MinerHaven v" .. GeoScanner.VERSION .. " - Geo Scanner Tool")
    print("Usage:")
    print("  minerhaven                  Launch interactive TUI")
    print("  minerhaven scan [r] [query] Scan blocks (default r=8)")
    print("  minerhaven all  [r] [query] Scan all blocks (not just ores)")
    print("  minerhaven chunk [query]    Analyze ores in current chunk")
    print("  minerhaven cost [r]         Show FE cost & fuel info")
    print("  minerhaven help             Show this help")
end

local function runCli(args)
    local cmd = (args[1] or ""):lower()
    if cmd == "help" or cmd == "-h" or cmd == "--help" then
        printHelp()
        return 0
    end

    local scanner, err = GeoScanner.find()
    if not scanner then
        if _G.printError then
            printError(err)
        else
            print("Error: " .. tostring(err))
        end
        return 1
    end

    if cmd == "cost" or cmd == "fuel" then
        local radius = tonumber(args[2]) or 8
        local cost = scanner:getCost(radius)
        local fuel = scanner:getFuel()
        print(("Peripheral: %s"):format(scanner.name))
        print(("Scan Cost (r=%d): %d FE"):format(radius, cost))
        if fuel.level ~= nil then
            print(("Fuel: %d / %d FE"):format(fuel.level, fuel.max))
        else
            print(("Max Fuel Capacity: %d FE"):format(fuel.max))
        end
        return 0
    elseif cmd == "chunk" or cmd == "analyze" then
        local query = args[2]
        print("Analyzing current chunk...")
        local res, aErr = scanner:analyzeChunk({ query = query, retries = 4, retryDelay = 0.6 })
        if not res then
            if _G.printError then printError(aErr) else print("Error: " .. tostring(aErr)) end
            return 1
        end
        if #res.entries == 0 then
            print("No matching ores found in this chunk.")
            return 0
        end
        print(("Chunk Ores (%d total):"):format(res.total))
        for _, item in ipairs(res.entries) do
            print(("  %-24s x%d"):format(item.prettyName, item.count))
        end
        return 0
    elseif cmd == "scan" or cmd == "all" then
        local oresOnly = (cmd == "scan")
        local radius = tonumber(args[2]) or 8
        local query = args[3]
        if args[2] and not tonumber(args[2]) then
            radius = 8
            query = args[2]
        end
        print(("Scanning radius %d (cost %d FE)..."):format(radius, scanner:getCost(radius)))
        local blocks, sErr = scanner:scan(radius, {
            oresOnly = oresOnly,
            query = query,
            retries = 4,
            retryDelay = 0.6,
        })
        if not blocks then
            if _G.printError then printError(sErr) else print("Error: " .. tostring(sErr)) end
            return 1
        end
        if #blocks == 0 then
            print("No matching blocks found.")
            return 0
        end
        print(("Found %d block(s):"):format(#blocks))
        local limit = math.min(#blocks, 15)
        for i = 1, limit do
            local b = blocks[i]
            print(("  %-18s (%+d,%+d,%+d) d=%d [%s]"):format(
                b.prettyName:sub(1, 18), b.x, b.y, b.z, b.dist, b.direction
            ))
        end
        if #blocks > limit then
            print(("  ... and %d more (use TUI to browse all)"):format(#blocks - limit))
        end
        return 0
    else
        printHelp()
        return 1
    end
end

--------------------------------------------------------------------------------
-- Interactive TUI Application
--------------------------------------------------------------------------------

local App = {}
App.__index = App

function App.new(scanner, initErr)
    local self = setmetatable({}, App)
    self.scanner = scanner
    self.statusMsg = scanner and ("Ready (" .. scanner.name .. ")") or (initErr or "No Geo Scanner attached")
    self.statusIsError = (scanner == nil)
    self.tab = 1 -- 1 = Ores (Grouped), 2 = Radar (Block coords), 3 = Chunk Analyze
    self.radius = 8
    self.oresOnly = true
    self.searchQuery = ""
    self.rawScanned = {} -- Last raw enriched scan list (unfiltered by oresOnly/search so toggling is instant!)
    self.filteredBlocks = {}
    self.groups = {}
    self.chunkData = nil
    self.selectedIdx = { 1, 1, 1 }
    self.scrollOffset = { 0, 0, 0 }
    self.running = true
    return self
end

function App:ensureScanner()
    if self.scanner then
        return true
    end
    local s, err = GeoScanner.find()
    if s then
        self.scanner = s
        self.statusMsg = "Connected: " .. s.name
        self.statusIsError = false
        return true
    end
    self.statusMsg = err or "No Geo Scanner found"
    self.statusIsError = true
    return false
end

function App:recomputeFilters()
    local filterSpec = {
        oresOnly = self.oresOnly,
        query = self.searchQuery ~= "" and self.searchQuery or nil,
    }
    self.filteredBlocks = GeoScanner.filterBlocks(self.rawScanned, filterSpec, "dist")
    self.groups = GeoScanner.groupByBlock(self.filteredBlocks)

    -- Clamp selection indices
    local counts = {
        #self.groups,
        #self.filteredBlocks,
        self.chunkData and #self.chunkData.entries or 0,
    }
    for t = 1, 3 do
        local maxCount = math.max(1, counts[t])
        if self.selectedIdx[t] > maxCount then
            self.selectedIdx[t] = maxCount
        end
        if self.selectedIdx[t] < 1 then
            self.selectedIdx[t] = 1
        end
    end
end

function App:performScan()
    if not self:ensureScanner() then
        return
    end
    local cost = self.scanner:getCost(self.radius)
    self.statusMsg = ("Scanning r=%d (%d FE)..."):format(self.radius, cost)
    self.statusIsError = false
    self:draw()

    local blocks, err = self.scanner:scan(self.radius, {
        oresOnly = false, -- Fetch all in radius, filter locally so user can toggle Ores/All & Search without rescanning
        retries = 5,
        retryDelay = 0.5,
    })

    if not blocks then
        self.statusMsg = "Scan error: " .. tostring(err)
        self.statusIsError = true
        return
    end

    self.rawScanned = blocks
    self:recomputeFilters()
    self.selectedIdx[1] = 1
    self.selectedIdx[2] = 1
    self.scrollOffset[1] = 0
    self.scrollOffset[2] = 0
    self.statusMsg = ("Scanned r=%d: %d match (%d total)"):format(
        self.radius, #self.filteredBlocks, #self.rawScanned
    )
    self.statusIsError = false
end

function App:performChunkAnalyze()
    if not self:ensureScanner() then
        return
    end
    self.statusMsg = "Analyzing chunk ores..."
    self.statusIsError = false
    self:draw()

    local res, err = self.scanner:analyzeChunk({
        query = self.searchQuery,
        retries = 5,
        retryDelay = 0.5,
    })

    if not res then
        self.statusMsg = "Chunk error: " .. tostring(err)
        self.statusIsError = true
        return
    end

    self.chunkData = res
    self.selectedIdx[3] = 1
    self.scrollOffset[3] = 0
    self.statusMsg = ("Chunk analyzed: %d ores (%d types)"):format(res.total, #res.entries)
    self.statusIsError = false
end

function App:triggerActiveAction()
    if self.tab == 3 then
        self:performChunkAnalyze()
    else
        self:performScan()
    end
end

function App:getCurrentListLength()
    if self.tab == 1 then
        return #self.groups
    elseif self.tab == 2 then
        return #self.filteredBlocks
    else
        return self.chunkData and #self.chunkData.entries or 0
    end
end

function App:moveSelection(delta, pageHeight)
    local len = self:getCurrentListLength()
    if len == 0 then
        self.selectedIdx[self.tab] = 1
        self.scrollOffset[self.tab] = 0
        return
    end
    local idx = math.max(1, math.min(len, self.selectedIdx[self.tab] + delta))
    self.selectedIdx[self.tab] = idx

    local offset = self.scrollOffset[self.tab]
    if idx <= offset then
        offset = idx - 1
    elseif idx > offset + pageHeight then
        offset = idx - pageHeight
    end
    self.scrollOffset[self.tab] = math.max(0, offset)
end

function App:promptSearch()
    if not term then return end
    local w, h = term.getSize()
    fillLine(h, w, Palette.accent, Palette.barBg, "Filter (name/#tag, blank=clear): ")
    term.setCursorPos(1, h)
    fillLine(h, w, Palette.accent, Palette.barBg, "/ ")
    term.setCursorPos(3, h)
    if term.setCursorBlink then term.setCursorBlink(true) end
    local input = read()
    if term.setCursorBlink then term.setCursorBlink(false) end
    if type(input) == "string" then
        self.searchQuery = input:match("^%s*(.-)%s*$")
        self:recomputeFilters()
        if self.tab == 3 and self.chunkData then
            self:performChunkAnalyze()
        else
            self.statusMsg = self.searchQuery ~= "" and ("Filter: " .. self.searchQuery) or "Filter cleared"
            self.statusIsError = false
        end
    end
end

function App:draw()
    if not term then return end
    local w, h = term.getSize()
    setColors(Palette.fg, Palette.bg)
    term.clear()

    -- Row 1: Title & Fuel / Cost bar
    local cost = self.scanner and self.scanner:getCost(self.radius) or 0
    local rightInfo = ("r:%d (%dFE)"):format(self.radius, cost)
    local title = "MinerHaven"
    if w < 28 then
        title = "MH"
    end
    local headerLine = padRight(" " .. title, math.max(1, w - #rightInfo - 1)) .. rightInfo .. " "
    fillLine(1, w, Palette.headerFg, Palette.headerBg, headerLine)

    -- Row 2: Tabs (`1:Ores`, `2:Radar`, `3:Chunk`) + Quick Filter Badge
    fillLine(2, w, Palette.tabFg, Palette.tabBg, "")
    local tabs = {
        { id = 1, label = w >= 36 and " 1:Ores " or "1:Ore" },
        { id = 2, label = w >= 36 and " 2:Radar " or "2:Rad" },
        { id = 3, label = w >= 36 and " 3:Chunk " or "3:Chk" },
    }
    local xPos = 1
    self.tabHitboxes = {}
    for _, t in ipairs(tabs) do
        local active = (self.tab == t.id)
        local fg = active and Palette.tabActiveFg or Palette.tabFg
        local bg = active and Palette.tabActiveBg or Palette.tabBg
        writeAt(xPos, 2, t.label, fg, bg)
        table.insert(self.tabHitboxes, { id = t.id, x1 = xPos, x2 = xPos + #t.label - 1 })
        xPos = xPos + #t.label + 1
    end

    local modeBadge = self.oresOnly and "[F:Ores]" or "[F:All]"
    if w - xPos >= #modeBadge then
        local badgeX = w - #modeBadge + 1
        writeAt(badgeX, 2, modeBadge, Palette.accent, Palette.tabBg)
        self.filterHitbox = { x1 = badgeX, x2 = w }
    else
        self.filterHitbox = nil
    end

    -- Row 3: Toolbar (`[-][+] Radius`, `[S:Scan]`, `[/Search]`)
    local searchLabel = self.searchQuery ~= "" and ("/" .. self.searchQuery) or "/Find"
    local toolbar = (" [-] r:%2d [+]  [S:Scan]  [%s]"):format(self.radius, searchLabel)
    fillLine(3, w, Palette.barFg, Palette.barBg, toolbar)
    self.minusHitbox = { x1 = 2, x2 = 4 }
    self.plusHitbox = { x1 = 11, x2 = 13 }
    self.scanHitbox = { x1 = 16, x2 = 23 }
    self.searchHitbox = { x1 = 26, x2 = w }

    -- Content rows: 4 .. h-2
    local listStartY = 4
    local listEndY = h - 2
    local listHeight = math.max(1, listEndY - listStartY + 1)
    self.lastListHeight = listHeight
    self.listStartY = listStartY
    self.listEndY = listEndY

    self:moveSelection(0, listHeight)

    if self.tab == 1 then
        self:drawGroupsTab(w, listStartY, listHeight)
    elseif self.tab == 2 then
        self:drawRadarTab(w, listStartY, listHeight)
    else
        self:drawChunkTab(w, listStartY, listHeight)
    end

    -- Row h-1: Selected item detail / coordinate guidance bar
    self:drawDetailBar(w, h - 1)

    -- Row h: Status & Hotkey bar
    local statusFg = self.statusIsError and Palette.err or Palette.success
    local quitHint = w >= 32 and " [Q]uit" or " [Q]"
    local maxStatusLen = math.max(1, w - #quitHint - 1)
    local statusLine = " " .. padRight(self.statusMsg, maxStatusLen) .. quitHint
    fillLine(h, w, statusFg, Palette.barBg, statusLine)
end

function App:drawGroupsTab(w, startY, height)
    if #self.groups == 0 then
        local msg = #self.rawScanned == 0
            and "Press [S] or click [S:Scan] to scan"
            or "No blocks match current filter [F]"
        writeAt(2, startY + 1, msg:sub(1, w - 2), Palette.muted, Palette.bg)
        return
    end

    local offset = self.scrollOffset[1]
    local selected = self.selectedIdx[1]

    for row = 1, height do
        local idx = offset + row
        local y = startY + row - 1
        local g = self.groups[idx]
        if g then
            local isSel = (idx == selected)
            local fg = isSel and Palette.selectedFg or (g.isOre and Palette.accent or Palette.fg)
            local bg = isSel and Palette.selectedBg or Palette.bg

            local rightStr = ("x%-3d %2dm %s"):format(g.count, g.nearest.dist, g.nearest.direction)
            if w < 30 then
                rightStr = ("x%d %dm"):format(g.count, g.nearest.dist)
            end
            local nameWidth = math.max(6, w - #rightStr - 3)
            local line = " " .. padRight(g.prettyName, nameWidth) .. " " .. rightStr
            fillLine(y, w, fg, bg, line)
        end
    end
end

function App:drawRadarTab(w, startY, height)
    if #self.filteredBlocks == 0 then
        local msg = #self.rawScanned == 0
            and "Press [S] to scan nearby blocks"
            or "No blocks match current filter"
        writeAt(2, startY + 1, msg:sub(1, w - 2), Palette.muted, Palette.bg)
        return
    end

    local offset = self.scrollOffset[2]
    local selected = self.selectedIdx[2]

    for row = 1, height do
        local idx = offset + row
        local y = startY + row - 1
        local b = self.filteredBlocks[idx]
        if b then
            local isSel = (idx == selected)
            local fg = isSel and Palette.selectedFg or (b.isOre and Palette.accent or Palette.fg)
            local bg = isSel and Palette.selectedBg or Palette.bg

            local coordStr
            if w >= 38 then
                coordStr = ("%+3d,%+3d,%+3d (%2dm)"):format(b.x, b.y, b.z, b.dist)
            else
                coordStr = ("%+d,%+d,%+d %dm"):format(b.x, b.y, b.z, b.dist)
            end
            local nameWidth = math.max(5, w - #coordStr - 3)
            local line = " " .. padRight(b.prettyName, nameWidth) .. " " .. coordStr
            fillLine(y, w, fg, bg, line)
        end
    end
end

function App:drawChunkTab(w, startY, height)
    if not self.chunkData then
        writeAt(2, startY + 1, ("Press [S] to run chunkAnalyze()"):sub(1, w - 2), Palette.muted, Palette.bg)
        return
    end
    local entries = self.chunkData.entries
    if #entries == 0 then
        writeAt(2, startY + 1, ("No ores found in this chunk"):sub(1, w - 2), Palette.muted, Palette.bg)
        return
    end

    local offset = self.scrollOffset[3]
    local selected = self.selectedIdx[3]
    local total = math.max(1, self.chunkData.total)

    for row = 1, height do
        local idx = offset + row
        local y = startY + row - 1
        local item = entries[idx]
        if item then
            local isSel = (idx == selected)
            local fg = isSel and Palette.selectedFg or Palette.accent
            local bg = isSel and Palette.selectedBg or Palette.bg

            local pct = math.floor((item.count / total) * 100 + 0.5)
            local rightStr = ("x%-4d (%2d%%)"):format(item.count, pct)
            if w < 30 then
                rightStr = ("x%d"):format(item.count)
            end
            local nameWidth = math.max(6, w - #rightStr - 3)
            local line = " " .. padRight(item.prettyName, nameWidth) .. " " .. rightStr
            fillLine(y, w, fg, bg, line)
        end
    end
end

function App:drawDetailBar(w, y)
    local detail = "Keys: [S]can [-/+]Radius [F]ilter [/]Find [1-3]Tab"
    if self.tab == 1 and self.groups[self.selectedIdx[1]] then
        local g = self.groups[self.selectedIdx[1]]
        local n = g.nearest
        detail = ("Nearest: X:%+d Y:%+d Z:%+d (%s) [Enter->Radar]"):format(n.x, n.y, n.z, n.direction)
    elseif self.tab == 2 and self.filteredBlocks[self.selectedIdx[2]] then
        local b = self.filteredBlocks[self.selectedIdx[2]]
        detail = ("Pos: X:%+d Y:%+d Z:%+d | Go: %s (d:%d)"):format(b.x, b.y, b.z, b.direction, b.dist)
    elseif self.tab == 3 and self.chunkData and self.chunkData.entries[self.selectedIdx[3]] then
        local item = self.chunkData.entries[self.selectedIdx[3]]
        detail = ("%s: %d in chunk (Total ores: %d)"):format(item.shortName, item.count, self.chunkData.total)
    end
    fillLine(y, w, Palette.fg, Palette.tabBg, " " .. detail)
end

function App:AdjustRadius(delta)
    self.radius = math.max(1, math.min(32, self.radius + delta))
    local cost = self.scanner and self.scanner:getCost(self.radius) or 0
    self.statusMsg = ("Radius set to %d (Cost: %d FE)"):format(self.radius, cost)
    self.statusIsError = false
end

function App:handleKey(key)
    local h = self.lastListHeight or 10
    if key == keys.q then
        self.running = false
    elseif key == keys.one then
        self.tab = 1
    elseif key == keys.two then
        self.tab = 2
    elseif key == keys.three then
        self.tab = 3
    elseif key == keys.tab then
        self.tab = (self.tab % 3) + 1
    elseif key == keys.up or key == keys.w or key == keys.k then
        self:moveSelection(-1, h)
    elseif key == keys.down or key == keys.j then
        self:moveSelection(1, h)
    elseif key == keys.pageUp then
        self:moveSelection(-h, h)
    elseif key == keys.pageDown then
        self:moveSelection(h, h)
    elseif key == keys.s or key == keys.space then
        self:triggerActiveAction()
    elseif key == keys.f then
        self.oresOnly = not self.oresOnly
        self:recomputeFilters()
        self.statusMsg = self.oresOnly and "Showing Ores Only" or "Showing All Blocks"
        self.statusIsError = false
    elseif key == keys.minus or key == keys.leftBracket or key == keys.left then
        self:AdjustRadius(-1)
    elseif key == keys.equals or key == keys.rightBracket or key == keys.right then
        self:AdjustRadius(1)
    elseif key == keys.slash then
        self:promptSearch()
    elseif key == keys.c then
        self.searchQuery = ""
        self:recomputeFilters()
        self.statusMsg = "Filter cleared"
        self.statusIsError = false
    elseif key == keys.enter then
        if self.tab == 1 and self.groups[self.selectedIdx[1]] then
            local g = self.groups[self.selectedIdx[1]]
            self.searchQuery = g.shortName
            self:recomputeFilters()
            self.tab = 2
            self.selectedIdx[2] = 1
            self.scrollOffset[2] = 0
            self.statusMsg = "Tracking " .. g.prettyName .. " ([C]lear filter)"
            self.statusIsError = false
        else
            self:triggerActiveAction()
        end
    end
end

function App:handleClick(button, x, y)
    local _, h = term.getSize()
    if y == 2 then
        for _, box in ipairs(self.tabHitboxes or {}) do
            if x >= box.x1 and x <= box.x2 then
                self.tab = box.id
                return
            end
        end
        if self.filterHitbox and x >= self.filterHitbox.x1 and x <= self.filterHitbox.x2 then
            self.oresOnly = not self.oresOnly
            self:recomputeFilters()
            return
        end
    elseif y == 3 then
        if self.minusHitbox and x >= self.minusHitbox.x1 and x <= self.minusHitbox.x2 then
            self:AdjustRadius(-1)
        elseif self.plusHitbox and x >= self.plusHitbox.x1 and x <= self.plusHitbox.x2 then
            self:AdjustRadius(1)
        elseif self.scanHitbox and x >= self.scanHitbox.x1 and x <= self.scanHitbox.x2 then
            self:triggerActiveAction()
        elseif self.searchHitbox and x >= self.searchHitbox.x1 and x <= self.searchHitbox.x2 then
            self:promptSearch()
        end
    elseif y >= (self.listStartY or 4) and y <= (self.listEndY or (h - 2)) then
        local clickedRow = y - (self.listStartY or 4) + 1
        local idx = self.scrollOffset[self.tab] + clickedRow
        if idx >= 1 and idx <= self:getCurrentListLength() then
            if self.selectedIdx[self.tab] == idx and self.tab == 1 then
                -- Double-click / click selected group to jump to Radar for that block
                self:handleKey(keys.enter)
            else
                self.selectedIdx[self.tab] = idx
            end
        end
    elseif y == h and x >= ({ term.getSize() })[1] - 7 then
        self.running = false
    end
end

function App:run()
    if self.scanner then
        self:performScan()
    end

    while self.running do
        self:draw()
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "key" then
            self:handleKey(p1)
        elseif ev == "mouse_click" then
            self:handleClick(p1, p2, p3)
        elseif ev == "mouse_scroll" then
            self:moveSelection(p1, self.lastListHeight or 10)
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            self.scanner = nil
            self:ensureScanner()
        end
    end

    if term then
        setColors(colors.white, colors.black)
        term.clear()
        term.setCursorPos(1, 1)
    end
end

--------------------------------------------------------------------------------
-- Entry Point
--------------------------------------------------------------------------------

local args = { ... }

if #args > 0 and (args[1]):lower() ~= "ui" then
    return runCli(args)
end

local scanner, initErr = GeoScanner.find()
local app = App.new(scanner, initErr)
app:run()
