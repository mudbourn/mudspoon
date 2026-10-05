-- hs.processInfo: identity of the host process, presented as Hammerspoon --

local host = require("hs.foundation")

local function dirOf(path)
    return (path:gsub("[/\\][^/\\]*$", ""))
end

local exePath = "luajit.exe"

if arg and arg[-1] then
    exePath = arg[-1]
end

local scriptDir = dirOf((arg and arg[0]) or ".")

local info = {
    processID = host.pid,
    bundleID = "org.hammerspoon.Hammerspoon",
    bundlePath = dirOf(exePath),
    executablePath = exePath,
    resourcePath = scriptDir,
    version = "1.0.0",
    buildTime = "2026-01-01 00:00:00",
    buildNumber = "0",
    minimumOSVersion = "10.0.0",
    processName = "Hammerspoon"
}

return info
