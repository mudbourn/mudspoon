-- hs.audiodevice  (Windows Core Audio / MMDevice binding via LuaJIT FFI + COM) --
    -- A Hammerspoon-shaped hs.audiodevice backed by the Windows Core Audio MMDevice
    -- API, driven from LuaJIT over raw COM (no C shim), in the same vtable-transcription
    -- style as hs/webview.lua.
    --
    -- ============================ UNVERIFIED SCAFFOLD ============================
    -- PARSE-checked only (luajit -bl). NEVER compiled against ole32 or run on Windows.
    -- Every COM vtable slot order, GUID, HRESULT path, and PROPVARIANT layout below is
    -- a REASONED TRANSCRIPTION from the Core Audio SDK (mmdeviceapi.h, endpointvolume.h,
    -- propidl.h / functiondiscoverykeys_devpkey.h) that the human must validate on the
    -- rig. The riskiest assumptions are flagged inline with "RISK:".
    -- ============================================================================
    --
    -- What mac/ actually consumes (the ENTIRE contract we must satisfy -- ms_core.lua):
    --   hs.audiodevice.defaultOutputDevice()          -> device or nil
    --   hs.audiodevice.findOutputByName(name)         -> device or nil   (matches :name())
    --   device:uid()                                  -> string  (endpoint id; sound uses it)
    --   device:name()                                 -> string  (friendly name)
    --   device:setVolume(level)                       -- level 0..100 (ms.setVolume contract)
    --   device:setMuted(bool)
    -- Real Hammerspoon spells the setters setOutputVolume/setOutputMuted; mac/ authored
    -- setVolume/setMuted, so THOSE are the load-bearing names. We provide the real-HS
    -- aliases too, harmlessly.
    --
    -- GRACEFUL DEGRADATION: every public entry pcall-wraps its COM work and returns nil
    -- on ANY failure. mac/ guards every call (`local dev = ...(); if dev then`), so a
    -- missing/failed audio stack costs volume control, never a crash. COM is inited
    -- LAZILY on first call (require() only cdefs) -- a session that never touches audio
    -- never loads ole32 or creates the enumerator.
    --
    -- Depends on hs.foundation only for host.C.kernel32 (UTF-16 conversion) and the
    -- keep()/ALIVE anchoring rule; owns all of its own COM cdefs per the ownership rule.
-- END --

local ffi  = require("ffi")
local bit  = require("bit")
local host = require("hs.foundation")
local K    = host.C.kernel32

local TRACE = os.getenv("MUDSPOON_AUDIO_TRACE") == "1"
local function trace(msg)
    if TRACE then io.stderr:write("[hs.audiodevice] " .. msg .. "\n") end
end

-- Module-level keepalive (same LuaJIT footgun as webview): any cdata a live COM
-- object may reference -- GUIDs handed to COM by pointer, PROPVARIANTs -- is anchored
-- for the call's duration by locals; nothing here outlives a single synchronous call,
-- so ALIVE is only for the interface-pointer boxes we hold across a device's lifetime.
local ALIVE = {}
local function keep(x) ALIVE[#ALIVE + 1] = x; return x end

-- COM + Core Audio typedefs (ours to own) --
    -- OWNERSHIP: foundation already declares BOOL/UINT/DWORD/WORD/LPCSTR process-wide
    -- (ffi's C namespace is global), and webview owns HRESULT/ULONG/LPWSTR/LPCWSTR/LPSTR
    -- WHEN it is loaded (opt-in, and it may load AFTER us). To collide with NEITHER, we
    -- redefine NO primitive: we reuse foundation's types by name and inline the rest as
    -- raw C (long for HRESULT, `unsigned short*` for LPWSTR, `char*` for LPSTR ...). We
    -- own ONLY the Core Audio-specific aggregates + interfaces below.
    ffi.cdef([[
typedef struct _GUID {
    unsigned long  Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char  Data4[8];
} GUID;

/* PROPERTYKEY = { fmtid GUID; DWORD pid } -- used to fetch the friendly name. */
typedef struct _PROPERTYKEY { GUID fmtid; DWORD pid; } PROPERTYKEY;

/* PROPVARIANT: 16 bytes on 64-bit. We only ever read vt==VT_LPWSTR(31), whose
 * union member (pwszVal) sits at offset 8 after the {vt, 3x reserved WORD} header. */
typedef struct _PROPVARIANT {
    unsigned short vt;
    unsigned short wReserved1;
    unsigned short wReserved2;
    unsigned short wReserved3;
    union { LPWSTR pwszVal; void* ptr; } val;
} PROPVARIANT;

/* --- ole32 --- */
long CoInitializeEx(void*, unsigned long);
long CoCreateInstance(const GUID*, void*, unsigned long, const GUID*, void**);
void CoTaskMemFree(void*);
long PropVariantClear(PROPVARIANT*);

/* --- kernel32: UTF-16 endpoint id / friendly name -> UTF-8 --- */
int WideCharToMultiByte(unsigned int, unsigned long, LPCWSTR, int, LPSTR, int, LPCSTR, void*);

/* --- COM interfaces WE CALL. Each vtable is IUnknown(0..2) then the interface's
 * methods in EXACT SDK order; slots we never call are void* pad_* placeholders to
 * hold the offsets of the ones we do. RISK: every slot order hand-transcribed. --- */

typedef struct IMMDeviceEnumerator IMMDeviceEnumerator;
typedef struct IMMDeviceCollection IMMDeviceCollection;
typedef struct IMMDevice           IMMDevice;
typedef struct IPropertyStore      IPropertyStore;
typedef struct IAudioEndpointVolume IAudioEndpointVolume;

typedef struct IMMDeviceEnumeratorVtbl {
    HRESULT (__stdcall *QueryInterface)(IMMDeviceEnumerator*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IMMDeviceEnumerator*);
    ULONG   (__stdcall *Release)(IMMDeviceEnumerator*);
    HRESULT (__stdcall *EnumAudioEndpoints)(IMMDeviceEnumerator*, int, DWORD, IMMDeviceCollection**); /* 3 */
    HRESULT (__stdcall *GetDefaultAudioEndpoint)(IMMDeviceEnumerator*, int, int, IMMDevice**);        /* 4 */
    /* GetDevice(5), RegisterEndpointNotificationCallback(6), Unregister(7) unused */
} IMMDeviceEnumeratorVtbl;
struct IMMDeviceEnumerator { IMMDeviceEnumeratorVtbl* lpVtbl; };

typedef struct IMMDeviceCollectionVtbl {
    HRESULT (__stdcall *QueryInterface)(IMMDeviceCollection*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IMMDeviceCollection*);
    ULONG   (__stdcall *Release)(IMMDeviceCollection*);
    HRESULT (__stdcall *GetCount)(IMMDeviceCollection*, UINT*);            /* 3 */
    HRESULT (__stdcall *Item)(IMMDeviceCollection*, UINT, IMMDevice**);    /* 4 */
} IMMDeviceCollectionVtbl;
struct IMMDeviceCollection { IMMDeviceCollectionVtbl* lpVtbl; };

typedef struct IMMDeviceVtbl {
    HRESULT (__stdcall *QueryInterface)(IMMDevice*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IMMDevice*);
    ULONG   (__stdcall *Release)(IMMDevice*);
    HRESULT (__stdcall *Activate)(IMMDevice*, const GUID*, DWORD, PROPVARIANT*, void**); /* 3 */
    HRESULT (__stdcall *OpenPropertyStore)(IMMDevice*, DWORD, IPropertyStore**);          /* 4 */
    HRESULT (__stdcall *GetId)(IMMDevice*, LPWSTR*);                                       /* 5 */
    HRESULT (__stdcall *GetState)(IMMDevice*, DWORD*);                                     /* 6 */
} IMMDeviceVtbl;
struct IMMDevice { IMMDeviceVtbl* lpVtbl; };

typedef struct IPropertyStoreVtbl {
    HRESULT (__stdcall *QueryInterface)(IPropertyStore*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IPropertyStore*);
    ULONG   (__stdcall *Release)(IPropertyStore*);
    HRESULT (__stdcall *GetCount)(IPropertyStore*, DWORD*);                       /* 3 */
    HRESULT (__stdcall *GetAt)(IPropertyStore*, DWORD, PROPERTYKEY*);             /* 4 */
    HRESULT (__stdcall *GetValue)(IPropertyStore*, const PROPERTYKEY*, PROPVARIANT*); /* 5 */
} IPropertyStoreVtbl;
struct IPropertyStore { IPropertyStoreVtbl* lpVtbl; };

typedef struct IAudioEndpointVolumeVtbl {
    HRESULT (__stdcall *QueryInterface)(IAudioEndpointVolume*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IAudioEndpointVolume*);
    ULONG   (__stdcall *Release)(IAudioEndpointVolume*);
    void* pad_RegisterControlChangeNotify;                                        /* 3 */
    void* pad_UnregisterControlChangeNotify;                                      /* 4 */
    void* pad_GetChannelCount;                                                    /* 5 */
    void* pad_SetMasterVolumeLevel;                                               /* 6 */
    HRESULT (__stdcall *SetMasterVolumeLevelScalar)(IAudioEndpointVolume*, float, const GUID*); /* 7 */
    void* pad_GetMasterVolumeLevel;                                               /* 8 */
    HRESULT (__stdcall *GetMasterVolumeLevelScalar)(IAudioEndpointVolume*, float*); /* 9 */
    void* pad_SetChannelVolumeLevel;                                              /* 10 */
    void* pad_SetChannelVolumeLevelScalar;                                        /* 11 */
    void* pad_GetChannelVolumeLevel;                                              /* 12 */
    void* pad_GetChannelVolumeLevelScalar;                                        /* 13 */
    HRESULT (__stdcall *SetMute)(IAudioEndpointVolume*, BOOL, const GUID*);       /* 14 */
    HRESULT (__stdcall *GetMute)(IAudioEndpointVolume*, BOOL*);                   /* 15 */
} IAudioEndpointVolumeVtbl;
struct IAudioEndpointVolume { IAudioEndpointVolumeVtbl* lpVtbl; };
]])
-- END --

-- Constants --
    local CP_UTF8          = 65001
    local S_OK             = 0
    local COINIT_APARTMENTTHREADED = 0x2
    local RPC_E_CHANGED_MODE = ffi.cast("long", 0x80010106)

    local CLSCTX_ALL       = 23      -- INPROC_SERVER|INPROC_HANDLER|LOCAL|REMOTE
    local eRender          = 0       -- EDataFlow
    local eConsole         = 0       -- ERole
    local DEVICE_STATE_ACTIVE = 0x1
    local STGM_READ        = 0
    local VT_LPWSTR        = 31
-- END --

-- GUID helper: build a const GUID* from the SDK's textual form. --
    -- {Data1-Data2-Data3-Data4hi-Data4lo}. Data4 is the LAST 8 bytes, big-endian in
    -- text: the two after the 3rd dash then the final six. Kept alive by the caller.
    local function guid(d1, d2, d3, b0, b1, b2, b3, b4, b5, b6, b7)
        local g = ffi.new("GUID")
        g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
        local b = { b0, b1, b2, b3, b4, b5, b6, b7 }
        for i = 0, 7 do g.Data4[i] = b[i + 1] end
        return g
    end

    -- CLSID_MMDeviceEnumerator {BCDE0395-E52F-467C-8E3D-C4579291692E}
    local CLSID_MMDeviceEnumerator = guid(0xBCDE0395, 0xE52F, 0x467C,
        0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E)
    -- IID_IMMDeviceEnumerator {A95664D2-9614-4F35-A746-DE8DB63617E6}
    local IID_IMMDeviceEnumerator = guid(0xA95664D2, 0x9614, 0x4F35,
        0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6)
    -- IID_IAudioEndpointVolume {5CDF2C82-841E-4546-9722-0CF74078229A}
    local IID_IAudioEndpointVolume = guid(0x5CDF2C82, 0x841E, 0x4546,
        0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A)

    -- PKEY_Device_FriendlyName = fmtid {a45c254e-df1c-4efd-8020-67d146a850e0}, pid 14.
    local PKEY_Device_FriendlyName = ffi.new("PROPERTYKEY")
    PKEY_Device_FriendlyName.fmtid = guid(0xA45C254E, 0xDF1C, 0x4EFD,
        0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0)
    PKEY_Device_FriendlyName.pid = 14
-- END --

-- fromWide(LPCWSTR) -> Lua string (UTF-8). Does NOT free ptr. --
    local function fromWide(ptr)
        if ptr == nil then return "" end
        local need = K.WideCharToMultiByte(CP_UTF8, 0, ptr, -1, nil, 0, nil, nil)
        if need <= 0 then return "" end
        local buf = ffi.new("char[?]", need)
        K.WideCharToMultiByte(CP_UTF8, 0, ptr, -1, buf, need, nil, nil)
        return ffi.string(buf)
    end
-- END --

-- Lazy COM init + enumerator (created once, held for the process). --
    local Ole
    local enumerator      -- IMMDeviceEnumerator* (kept in ALIVE once obtained)
    local comFailed = false

    local function ensureEnumerator()
        if enumerator ~= nil then return enumerator end
        if comFailed then return nil end
        local ok, e = pcall(function()
            Ole = Ole or ffi.load("ole32")
            -- Init COM on this (the runloop) thread; benign if already inited.
            local hr = Ole.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
            if hr ~= S_OK and hr ~= RPC_E_CHANGED_MODE and hr ~= 1 then
                -- hr==1 is S_FALSE (already inited on this thread) -- also fine.
                trace("CoInitializeEx hr=" .. tostring(hr))
            end
            local pp = ffi.new("void*[1]")
            local hr2 = Ole.CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
                IID_IMMDeviceEnumerator, pp)
            if hr2 ~= S_OK or pp[0] == nil then
                error("CoCreateInstance(MMDeviceEnumerator) hr=" .. tostring(hr2))
            end
            return ffi.cast("IMMDeviceEnumerator*", pp[0])
        end)
        if not ok then
            comFailed = true
            trace("ensureEnumerator failed: " .. tostring(e))
            return nil
        end
        enumerator = keep(e)
        trace("enumerator live")
        return enumerator
    end
-- END --

-- Device object: wraps a live IMMDevice*. Methods pcall their COM so a single bad
-- call never escapes to mac/ (which only checks the device is non-nil). --
    local Device = {}
    Device.__index = Device

    -- Fetch (and cache) the IAudioEndpointVolume* for volume/mute control.
    local function endpointVolume(self)
        if self._vol ~= nil then return self._vol end
        local ok, v = pcall(function()
            local pp = ffi.new("void*[1]")
            local hr = self._dev.lpVtbl.Activate(self._dev, IID_IAudioEndpointVolume,
                CLSCTX_ALL, nil, pp)
            if hr ~= S_OK or pp[0] == nil then error("Activate(EndpointVolume) hr=" .. tostring(hr)) end
            return ffi.cast("IAudioEndpointVolume*", pp[0])
        end)
        if not ok then trace("endpointVolume: " .. tostring(v)); return nil end
        self._vol = keep(v)
        return self._vol
    end

    -- :uid() -> endpoint id string (GetId). mac/ feeds it to hs.sound s:device().
    function Device:uid()
        if self._uid then return self._uid end
        local ok, id = pcall(function()
            local pp = ffi.new("LPWSTR[1]")
            local hr = self._dev.lpVtbl.GetId(self._dev, pp)
            if hr ~= S_OK or pp[0] == nil then error("GetId hr=" .. tostring(hr)) end
            local s = fromWide(pp[0])
            Ole.CoTaskMemFree(pp[0])   -- GetId allocates with CoTaskMemAlloc
            return s
        end)
        self._uid = ok and id or ""
        return self._uid
    end

    -- :name() -> friendly name (property store PKEY_Device_FriendlyName).
    function Device:name()
        if self._name then return self._name end
        local ok, nm = pcall(function()
            local sp = ffi.new("IPropertyStore*[1]")
            local hr = self._dev.lpVtbl.OpenPropertyStore(self._dev, STGM_READ, sp)
            if hr ~= S_OK or sp[0] == nil then error("OpenPropertyStore hr=" .. tostring(hr)) end
            local store = sp[0]
            local pv = ffi.new("PROPVARIANT")
            local hr2 = store.lpVtbl.GetValue(store, PKEY_Device_FriendlyName, pv)
            local s = ""
            -- RISK: PROPVARIANT union offset -- friendly name is VT_LPWSTR; read pwszVal.
            if hr2 == S_OK and pv.vt == VT_LPWSTR then s = fromWide(pv.val.pwszVal) end
            Ole.PropVariantClear(pv)
            store.lpVtbl.Release(store)
            return s
        end)
        self._name = ok and nm or ""
        return self._name
    end

    -- :setVolume(level) -- level is 0..100 (ms.setVolume contract), NOT a 0..1 scalar.
    -- SetMasterVolumeLevelScalar wants 0..1, so divide + clamp. Returns self.
    function Device:setVolume(level)
        local vol = endpointVolume(self)
        if not vol then return self end
        local scalar = (tonumber(level) or 0) / 100
        if scalar < 0 then scalar = 0 elseif scalar > 1 then scalar = 1 end
        pcall(function() vol.lpVtbl.SetMasterVolumeLevelScalar(vol, scalar, nil) end)
        return self
    end
    Device.setOutputVolume = Device.setVolume   -- real-HS spelling, harmless alias

    -- :volume() -> current output volume 0..100, or nil. (Symmetry; unused by mac/.)
    function Device:volume()
        local vol = endpointVolume(self)
        if not vol then return nil end
        local ok, v = pcall(function()
            local out = ffi.new("float[1]")
            local hr = vol.lpVtbl.GetMasterVolumeLevelScalar(vol, out)
            if hr ~= S_OK then error("GetMasterVolumeLevelScalar hr=" .. tostring(hr)) end
            return out[0] * 100
        end)
        return ok and v or nil
    end
    Device.outputVolume = Device.volume

    -- :setMuted(bool) -> self. SetMute takes a BOOL.
    function Device:setMuted(state)
        local vol = endpointVolume(self)
        if not vol then return self end
        pcall(function() vol.lpVtbl.SetMute(vol, state and 1 or 0, nil) end)
        return self
    end
    Device.setOutputMuted = Device.setMuted

    -- :muted() -> boolean or nil.
    function Device:muted()
        local vol = endpointVolume(self)
        if not vol then return nil end
        local ok, m = pcall(function()
            local out = ffi.new("BOOL[1]")
            local hr = vol.lpVtbl.GetMute(vol, out)
            if hr ~= S_OK then error("GetMute hr=" .. tostring(hr)) end
            return out[0] ~= 0
        end)
        if not ok then return nil end
        return m
    end

    local function wrapDevice(immDevPtr)
        if immDevPtr == nil then return nil end
        return setmetatable({ _dev = keep(immDevPtr) }, Device)
    end
-- END --

local M = {}

-- hs.audiodevice.defaultOutputDevice() -> device or nil (eRender/eConsole default). --
    function M.defaultOutputDevice()
        local e = ensureEnumerator()
        if not e then return nil end
        local ok, dev = pcall(function()
            local pp = ffi.new("IMMDevice*[1]")
            local hr = e.lpVtbl.GetDefaultAudioEndpoint(e, eRender, eConsole, pp)
            if hr ~= S_OK or pp[0] == nil then error("GetDefaultAudioEndpoint hr=" .. tostring(hr)) end
            return pp[0]
        end)
        if not ok then trace("defaultOutputDevice: " .. tostring(dev)); return nil end
        return wrapDevice(dev)
    end
-- END --

-- hs.audiodevice.allOutputDevices() -> { device, ... } (active render endpoints). --
    function M.allOutputDevices()
        local e = ensureEnumerator()
        if not e then return {} end
        local ok, list = pcall(function()
            local cp = ffi.new("IMMDeviceCollection*[1]")
            local hr = e.lpVtbl.EnumAudioEndpoints(e, eRender, DEVICE_STATE_ACTIVE, cp)
            if hr ~= S_OK or cp[0] == nil then error("EnumAudioEndpoints hr=" .. tostring(hr)) end
            local coll = cp[0]
            local cnt = ffi.new("UINT[1]")
            coll.lpVtbl.GetCount(coll, cnt)
            local out = {}
            for i = 0, tonumber(cnt[0]) - 1 do
                local dp = ffi.new("IMMDevice*[1]")
                if coll.lpVtbl.Item(coll, i, dp) == S_OK and dp[0] ~= nil then
                    out[#out + 1] = wrapDevice(dp[0])
                end
            end
            coll.lpVtbl.Release(coll)
            return out
        end)
        if not ok then trace("allOutputDevices: " .. tostring(list)); return {} end
        return list
    end
-- END --

-- hs.audiodevice.findOutputByName(name) -> device or nil (matches :name(), like HS). --
    function M.findOutputByName(name)
        if not name then return nil end
        for _, dev in ipairs(M.allOutputDevices()) do
            if dev:name() == name then return dev end
        end
        return nil
    end
-- END --

return M
