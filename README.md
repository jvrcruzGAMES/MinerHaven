# MinerHaven

A modular, secure **CC: Tweaked** automated mining fleet and telemetry system for Minecraft with the [Advanced Peripherals Geo Scanner](https://docs.advanced-peripherals.de/0.7/peripherals/geo_scanner/) and [End Automata](https://docs.advanced-peripherals.de/0.7/turtles/metaphysics/end_automata/).

---

## Architecture Overview

MinerHaven is structured around a **Controller & Headless Worker** architecture communicating over an encrypted transport layer:

```
MinerHaven/
├── startup.lua                  # Universal startup script; launches installed component
├── install.lua                  # Automated remote installer
├── version.json                 # Semantic version & release manifests
├── firmware/                    # Bundled firmware cache
│   └── worker/                  # Bundled worker firmware for flashing & OTA
├── controller/                  # Base Advanced Computer (Home Base)
│   ├── main.lua                 # Controller entry point (runs startup update checks)
│   ├── dashboard.lua            # Real-time TUI dashboard, buttons & fleet terminal
│   ├── pairing.lua              # Controller-side pairing handler
│   ├── controller.lua           # Core controller logic & fleet coordinator
│   ├── main.cfg                 # Centralized configuration (authoritative radius, channels)
│   └── lib/
│       ├── ores/main.lua        # libores: GeoScanner management & base block protection
│       ├── pairing/main.lua     # libpairing: Fleet pairing & session key manager
│       └── updater/main.lua     # libupdater: GitHub updates, side flashing, & OTA dispatch
├── worker/                      # Mining Turtle (Worker)
│   ├── main.lua                 # Worker entry point (runs pairing or worker)
│   ├── pairing.lua              # Headless pairing display (shows 6-digit numeric code)
│   ├── worker.lua               # Headless worker logic, path-only filling, & OTA receiver
│   └── lib/
│       └── device/main.lua      # libdevice: Worker pairing handshake & device identity
└── lib/                         # Shared Core Libraries
    ├── crypto/main.lua          # libcrypto: SHA-256, HMAC-SHA256, CTR cipher, HKDF
    └── workernet/main.lua       # libworkernet: Encrypted transport, HMAC signatures, replay defense
```

---

## Key Features

1. **Authoritative Scan Radius**:
   - The scan radius configured on the Controller is the authoritative source of truth.
   - Turtle requests cannot override the controller's active radius.
2. **Cryptographic Transport Layer (`libworkernet`)**:
   - Every packet transmitted over wireless / Ender Modem is encrypted using an **HMAC-CTR stream cipher** and signed with **HMAC-SHA256**.
   - Built-in sequence numbers and replay-attack protection.
3. **6-Digit Numeric Pairing (`libpairing` & `libdevice`)**:
   - When unpaired, the Worker displays a randomly generated **6-digit numeric pair code** (e.g. `482 915`).
   - Entering this code in the Controller initiates a cryptographic challenge-response handshake deriving a shared 256-bit session key via HKDF.
4. **Headless Turtles**:
   - Once paired, turtles are fully headless: their screen shows a live status read-out, with all commands (`start`, `stop`, `scan`, `radius`) remotely controlled from the Controller dashboard.
5. **End Automata Warp & Navigation**:
   - Teleports directly to Home via `warpToPoint("home")` with alignment.
   - Falls back to native pickaxe digging pathfinding if the End Automata breaks or lacks fuel.
6. **Native Digging & Java NPE Workaround**:
   - Automatically equips pickaxes to bypass the Advanced Peripherals 0.8.2a `APFakePlayer.awardStat` null-pointer exception when breaking netherrack/blocks.
7. **Fuel Stack Retention & Emergency Return**:
   - Keeps up to a full stack (64) of coal/charcoal during barrel unloading, depositing only excess.
   - Retains Mekanism Energy Cubes in inventory for charging.
   - **Emergency Return**: If coal count drops to 0 while in the field, the turtle immediately teleports home.
8. **Protected Base Blocks**:
   - Strictly preserves base blocks: Computers, Modems, Geo Scanners, Sophisticated Storage Barrels, Energy Cubes, Flux Plugs/Points (`fluxnetworks:*`), Teleport Pads, and Bedrock.
9. **Path-Only Waste Placement**:
   - The worker tracks the exact coordinates it breaks open. When advancing along an excavation path, it turns around and fills only the vacated air space left behind with waste blocks (`cobblestone`, `netherrack`, `dirt`, `stone`).
   - Untouched cave walls, floors, ceilings, and home coordinates are never covered or obstructed.
10. **Device Architecture Upgrade - Flashing & OTA Updates (`libupdater`)**:
   - **Side Flashing (`flash <side>`)**: The controller can flash worker firmware directly to an adjacent disk drive (writes bootable floppy files to `/disk`) or power on and bootstrap an adjacent computer/turtle.
   - **Over-The-Air (OTA) Updates (`ota [workerId]` / `[OTA]` Button)**: The controller pushes the complete worker firmware payload over encrypted Workernet. The worker stages files into `.staging/`, replaces the local installation, and reboots cleanly.
   - **Controller GitHub Releases Update System**: On startup, the controller queries GitHub Releases (`/releases/latest` or `version.json`), notifying the operator if a newer version is available with a `(Y/n)` prompt. Manual updates can also be triggered at any time via the `update` command.
   - **Bundled Worker Firmware**: Installing or upgrading the controller automatically bundles the latest worker firmware in `firmware/worker/` for instant flashing and OTA deployment.

---

## Quick Install (In-Game)

Run on your CC: Tweaked computer or turtle (requires HTTP enabled):

```lua
wget run https://raw.githubusercontent.com/jvrcruzGAMES/MinerHaven/main/install.lua
```

### Installation Roles

The installer asks which component you are setting up:
- `c` (or `--controller`): Installs Controller software for the Base Computer.
- `w` (or `--worker`): Installs Worker software for the Mining Turtle.

CLI Options:
```bash
install.lua --controller    # Install Base Controller
install.lua --worker        # Install Mining Turtle
install.lua --startup       # Automatically configure boot launch via startup.lua
```

---

## Base Setup & Pairing Workflow

1. **Base Setup**:
   - Advanced Computer with an **Ender Modem** on top.
   - **Geo Scanner** placed behind the computer.
   - **Sophisticated Storage Barrel** adjacent to the turtle home spot.
   - **End Automata Turtle** placed at Home facing North, equipped with an Ender Modem, Pickaxe, and End Automata.
2. **Pairing**:
   - Turn on the Worker Turtle: it displays a **6-digit pairing code** on its screen (e.g., `482 915`).
   - On the Base Controller dashboard, click `[PAIR]` (or type `pair`).
   - Enter the 6-digit code.
   - Both devices complete the handshake, derive a 256-bit encryption key, and save the session.
3. **Operation**:
   - Click `[START]` or `[SCAN]` on the Controller dashboard.
   - The Controller scans using its authoritative radius, encrypts the ore locations, and commands the turtle.
   - The turtle mines the ores, teleports home when full, unloads into the barrel (keeping 64 fuel), and repeats!
