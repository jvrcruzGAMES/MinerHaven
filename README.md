# MinerHaven

A lightweight, reusable **CC: Tweaked** toolkit and interactive terminal interface (TUI + CLI) for the [Advanced Peripherals Geo Scanner](https://docs.advanced-peripherals.de/0.7/peripherals/geo_scanner/).

Works out of the box on **Pocket Computers**, **Turtles**, and **Standard / Advanced Computers** across both Advanced Peripherals `0.7` (`geoScanner`) and `0.8` / Minecraft `1.21.1+` (`geo_scanner`).

---

## Quick Install (In-Game)

Run the following one-liner on any CC: Tweaked computer, pocket computer, or turtle with an attached Geo Scanner (requires HTTP API enabled):

```lua
wget run https://raw.githubusercontent.com/jvrcruzGAMES/MinerHaven/main/install.lua
```

### Installer Prompts & Flags

When you run `install.lua`, it asks whether the installation is for a **Turtle** (auto-detecting if the `turtle` API is present):

1. **Standard Computer / Pocket Computer Install**:
   - Installs `/lib/geoscanner.lua` and `/minerhaven.lua`, and registers the `minerhaven` and `mh` aliases.
2. **Turtle Install** (`y` at prompt, or `--turtle` flag):
   - Installs `/lib/geoscanner.lua`, `/minerhaven.lua`, and the Turtle Auto-Miner `/turtle_miner.lua` (`miner` alias).
   - **Prompts to set the Turtle's current location as its Home** and saves it to `/home.cfg` (along with `/turtle_pos.cfg`).
   - Configures `/startup/99_minerhaven.lua` so the **Turtle Auto-Miner (`turtle_miner.lua`) loads automatically on startup**.

#### CLI Flags for `install.lua`
- `--turtle` / `--no-turtle`: Skip the prompt and force Turtle or non-Turtle installation.
- `--set-home` / `--facing <n|e|s|w>`: Automatically set the turtle's current location as Home without prompting.
- `--lib-only`: Install only `/lib/geoscanner.lua` for use in your own scripts.
- `--startup`: Auto-start the `minerhaven` radar UI on boot (for non-turtle computers).
- `--dir <path>`: Install files into a custom directory.

---

## Turtle Auto-Miner (`turtle_miner.lua` / `miner`) — End Automata Edition

When installed for a Turtle, **MinerHaven End Automata Auto-Miner** loads automatically on startup and stays running on the turtle screen. It is designed for an [Advanced Peripherals End Automata](https://docs.advanced-peripherals.de/0.7/turtles/metaphysics/end_automata/) + [Geo Scanner](https://docs.advanced-peripherals.de/0.7/peripherals/geo_scanner/) turtle.

### How It Works
- **`start` instruction**:
  1. **Chunk Ore Mining**: Uses `chunkAnalyze()` and `scan(8)` to systematically mine **all ores in the turtle's current chunk** (`#forge:ores`, `#c:ores`, `#minecraft:*_ores`), descending through the chunk column as each vertical slice is cleared until `0` ores remain in the chunk.
  2. **End Automata Digging & Movement**:
     - Breaks blocks using `automata.digBlock()` (holding a pickaxe in the turtle's inventory) or a side-equipped pickaxe.
     - **Down-first movement priority**: Prefers moving **down (`-Y`)** first before moving horizontally in the direction of the ore.
     - **Places Waste Blocks in Path**: Places non-ore waste blocks (`cobblestone`, `dirt`, `cobbled_deepslate`, `stone`, etc.) behind/around itself in its path (`placeUp`, `placeDown`, `place`) instead of dropping them on the ground.
     - **Obstacle breaking & Teleport Pad protection**: Breaks obstructing blocks along its path **except `allthemodium:teleport_pad`**. If an `allthemodium:teleport_pad` is detected, the turtle leaves it untouched and automatically pathfinds an alternative route around it.
  3. **Energy Charging (`chargeTurtle`)**:
     - Automatically charges the turtle from FE/RF energy items in its inventory (such as an Energy Tablet, Flux Capacitor, or Battery) via `automata.chargeTurtle()`, falling back to `turtle.refuel()` if standard burnable fuel is present.
  4. **Teleport to Home + Dig-to-Home Fallback**:
     - When its 16-slot inventory is full (or when the chunk is finished), the turtle **teleports back to Home** via `automata.warpToPoint("home")` and **aligns its facing direction with Home**.
     - **Dig-to-Home Fallback**: If the End Automata breaks or if the warp fuel cost (`estimateWarpCost("home")`) exceeds the turtle's available fuel, it automatically falls back to the 3D dig-to-home pathfinding system and aligns with Home upon arrival.
  5. **Waits at Home** until its inventory has **no more ores** (e.g., unloaded by a player or hopper), then automatically resumes mining the chunk!
- **`stop` instruction**:
  - Immediately stops mining, **teleports (or digs) back to its Home** (even if its inventory is not full), aligns with Home, and transitions to **`IDLE (Stopped)`**.
  - **Does not exit or terminate**—the program stays alive and idle at Home until you give the `start` instruction again.
- **`sethome` instruction**:
  - Sets the turtle's Home to the **current block it is in**, saves it to `/home.cfg`, and registers the `"home"` warp point on the End Automata via `automata.savePoint("home")`.

### Controlling the Turtle Auto-Miner
While the program is running on the Turtle screen, type a command and press **Enter** (or click the on-screen buttons on an Advanced Turtle):
- `start` — Start mining nearby ores by tag.
- `stop` — Pause/stop mining and stay idle until activated again.
- `sethome [n|e|s|w]` — Save the turtle's current location as its Home in `/home.cfg`.
- `return` (or `home`) — Stop mining and walk back to Home.
- `shell` (or `quit`) — Exit to the CraftOS shell.

You can also control it via CLI commands:
```lua
miner start           -- Start mining nearby ores
miner stop            -- Stop and stay idle
miner sethome n       -- Save current position (facing North) to /home.cfg
miner status          -- Print current state, Home coordinates, and inventory ore count
```

---

## Interactive Interface (TUI)

Launch the interactive interface by running:

```lua
minerhaven
-- or simply:
mh
```

### Three Built-in Views

1. **`1:Ores` (Grouped Summary)**:
   - Groups scanned blocks by type, showing total count, distance to the nearest block, and a compass direction hint (`E/W`, `U/D`, `S/N`).
   - Press **`Enter`** (or click a selected group) to lock onto that block type in the **Radar** tab.
2. **`2:Radar` (Block Coordinates & Compass)**:
   - Lists individual blocks sorted by nearest Manhattan distance with exact relative `(X, Y, Z)` coordinates and compass directions (`+X = East`, `-X = West`, `+Y = Up`, `-Y = Down`, `+Z = South`, `-Z = North`).
3. **`3:Chunk` (Chunk Ore Analyzer)**:
   - Calls `chunkAnalyze()` and displays all ores in the current chunk sorted by abundance with counts and percentages.

### Controls (Keyboard & Mouse/Touch)

| Key / Action | Description |
| :--- | :--- |
| **`S`** or **`Space`** (or click `[S:Scan]`) | Scan blocks (Tabs 1 & 2) or analyze current chunk (Tab 3). Automatically waits & retries if on cooldown. |
| **`1`**, **`2`**, **`3`** or **`Tab`** (or click tab) | Switch between **Ores**, **Radar**, and **Chunk** views. |
| **`Up` / `Down`** or **`W` / `J` / `K`** or **Scroll** | Navigate through the list. |
| **`Enter`** | On Tab 1, filter and jump to Tab 2 (**Radar**) for the selected block type. |
| **`-` / `+`** or **`[` / `]`** or **`Left` / `Right`** | Decrease / increase scan radius (`1`–`32`), showing live FE cost in the header. |
| **`F`** (or click `[F:Ores]`) | Toggle between **Ores Only** and **All Blocks** instantly without re-scanning. |
| **`/`** (or click `[/Find]`) | Filter by block name substring (e.g. `diamond`) or block tag (e.g. `#forge:ores`). |
| **`C`** | Clear active search filter. |
| **`Q`** (or click `[Q]uit`) | Exit to CraftOS shell. |

---

## Command-Line Interface (CLI)

You can also run quick one-off commands directly from the shell:

```lua
mh scan               -- Scan for ores within default radius (8)
mh scan 12 diamond    -- Scan for diamond ores within radius 12
mh all 6              -- Scan all blocks within radius 6
mh chunk              -- Run chunkAnalyze() and print ore counts in current chunk
mh chunk diamond      -- Check how many diamond ores are in the current chunk
mh cost 16            -- Show FE scan cost for radius 16 and current/max fuel
mh help               -- Show CLI usage
```

---

## Reusable Library API (`lib/geoscanner.lua`)

`lib/geoscanner.lua` is a standalone module with zero UI dependencies so you can `require` it in your own turtle mining scripts, HUDs, or monitor dashboards.

### Basic Usage

```lua
local GeoScanner = require("lib.geoscanner")

-- Automatically finds "geoScanner" (0.7) or "geo_scanner" (0.8 / 1.21.1+)
local scanner, err = GeoScanner.find()
if not scanner then
    error(err)
end

-- Check FE cost and fuel capacity
print("Cost for r=8:", scanner:getCost(8))
local fuel = scanner:getFuel()
print("Max fuel:", fuel.max)

-- Scan for ores within radius 8 (with automatic cooldown retry!)
local ores, scanErr = scanner:scanOres(8, {
    retries = 4,
    retryDelay = 0.6,
})

if ores then
    for _, block in ipairs(ores) do
        print(("%s at (%+d, %+d, %+d) dist=%d [%s]"):format(
            block.prettyName, block.x, block.y, block.z, block.dist, block.direction
        ))
    end
end
```

### Finding the Nearest Target (Great for Mining Turtles)

```lua
local GeoScanner = require("lib.geoscanner")
local scanner = assert(GeoScanner.find())

-- Find the closest diamond ore within radius 8
local target = scanner:findNearest(8, "diamond_ore", { retries = 3 })
if target then
    print("Nearest diamond:", target.x, target.y, target.z, target.direction)
end
```

### Grouping Blocks & Analyzing Chunks

```lua
local GeoScanner = require("lib.geoscanner")
local scanner = assert(GeoScanner.find())

-- Group scanned blocks by registry name with counts and nearest coordinates
local blocks = assert(scanner:scanOres(8, { retries = 3 }))
local groups = GeoScanner.groupByBlock(blocks)
for _, group in ipairs(groups) do
    print(group.prettyName, "x" .. group.count, "nearest dist:", group.nearest.dist)
end

-- Analyze the current chunk (chunkAnalyze)
local chunk = assert(scanner:analyzeChunk({ retries = 3 }))
print("Total ores in chunk:", chunk.total)
for _, entry in ipairs(chunk.entries) do
    print(entry.prettyName, entry.count)
end
```

### Enriched Block Fields

Every block returned by `scanner:scan()`, `scanner:scanOres()`, or `scanner:findNearest()` includes:
- `name` (`string`): Registry name (e.g. `"minecraft:deepslate_diamond_ore"`)
- `shortName` (`string`): Name without namespace (e.g. `"deepslate_diamond_ore"`)
- `prettyName` (`string`): Human-readable name (e.g. `"Deepslate Diamond Ore"`)
- `x`, `y`, `z` (`number`): Relative coordinates from the Geo Scanner
- `dist` (`number`): Manhattan distance (`|x| + |y| + |z|`)
- `euclidean` (`number`): Euclidean 3D distance rounded to 1 decimal place
- `direction` (`string`): Compact compass string (e.g. `"3E 2D 5S"`)
- `isOre` (`boolean`): `true` if identified as an ore via block tags or registry name
- `tags` (`table`): Sorted array of normalized tag strings
- `tagMap` (`table`): Lookup table `{ [tag] = true }`
