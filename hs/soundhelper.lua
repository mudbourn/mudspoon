-- Plays one sound file in its own process: lua.exe -E soundhelper.lua <volume 0..100> <path>

package.path = ((arg[0] or ""):gsub("[^/\\]*$", "")) .. "../compat/?.lua;" .. package.path

local ffi = require("ffi")
local ok, WM = pcall(ffi.load, "winmm")
if not ok then os.exit(2) end

ffi.cdef[[
int          PlaySoundA(const char*, void*, unsigned int);
unsigned int waveOutSetVolume(void*, unsigned int);
unsigned int mciSendStringA(const char*, char*, unsigned int, void*);
]]

local vol  = tonumber(arg[1]) or 100
local path = arg[2]
if type(path) ~= "string" or path == "" then os.exit(2) end

-- Per-process wave-output volume (0..100 -> 0..0xFFFF per channel). This process plays
-- exactly one sound, so its process volume IS this sound's volume -- no cross-talk with
-- sounds playing in sibling children. Best-effort; a failure just plays unattenuated.
do
    local v  = math.max(0, math.min(1, vol / 100))
    local ch = math.floor(v * 0xFFFF + 0.5)
    WM.waveOutSetVolume(ffi.cast("void*", ffi.cast("intptr_t", 0)), ch + ch * 0x10000)
end

-- SND_SYNC(0) | SND_FILENAME(0x20000) | SND_NODEFAULT(2): block until done; pszSound is
-- a path; stay silent (not the system ding) on a bad file.
local SND_SYNC_FILE = 0x00020000 + 0x0002
if WM.PlaySoundA(path, nil, SND_SYNC_FILE) ~= 0 then os.exit(0) end

-- Non-WAV fallback: MCI opens with the OS codec for the type; `play ... wait` blocks.
local buf = ffi.new("char[?]", 256)
local function mci(cmd) return WM.mciSendStringA(cmd, buf, 256, nil) end
if mci(string.format('open "%s" alias s', path)) == 0 then
    mci("play s wait")
    mci("close s")
    os.exit(0)
end
os.exit(1)
