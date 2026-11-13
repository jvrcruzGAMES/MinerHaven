--- startup.lua - Universal MinerHaven Startup Script
-- Detects installed component (controller or worker) and starts the appropriate entrypoint.

local function runProgram(path)
    if shell and shell.run then
        return shell.run(path)
    end
    local fn = loadfile(path)
    if fn then return fn() end
    error("Unable to execute " .. path)
end

if fs.exists("controller/main.lua") then
    runProgram("controller/main.lua")
elseif fs.exists("worker/main.lua") then
    runProgram("worker/main.lua")
else
    term.clear()
    term.setCursorPos(1, 1)
    if term.setTextColor and colors then term.setTextColor(colors.red) end
    print("MinerHaven: No component installed!")
    print("Run 'install.lua' to install either the Controller or Worker.")
end
