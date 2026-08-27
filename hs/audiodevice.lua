-- hs.audiodevice  (Windows Core Audio via LuaJIT FFI + COM) --
    -- A Hammerspoon-shaped hs.audiodevice backed by the Windows Core Audio MMDevice
    -- API (IMMDeviceEnumerator / IMMDevice / IAudioEndpointVolume), driven from
    -- LuaJIT over raw COM -- no C shim -- in the same spirit as hs/webview.lua.
    --
    -- The slice mudscript actually uses:
    --   hs.audiodevice.defaultOutputDevice()      -> device (identity + volume)
    --   hs.audiodevice.findOutputByName(name)      -> device | nil
    --   device:name()                              -> friendly name string
    --   device:volume()                            -> 0..100 | nil     (master scalar)
    --   device:setVolume(n)                        -> device           (n in 0..100)
    --   device:muted() / device:setMuted(bool)     -> bool / device
    --
    -- Depends on hs.foundation ONLY for shared Win32 TYPES (DWORD, BOOL, UINT) and the
    -- loaded kernel32 handle. Per the frozen cdef-ownership rule foundation owns every
    -- shared type; this file ffi.cdef's ONLY its own COM interface/vtable structs, the
    -- unique GUID/PROPERTYKEY/PROPVARIANT structs, and the ole32 functions it calls.
    --
    -- CROSS-MODULE TYPE HYGIENE: hs/webview.lua ALSO does COM and typedefs HRESULT /
    -- LPWSTR / LPCWSTR / ULONG. Either module may be the one loaded (or both). LuaJIT
    -- errors on a DUPLICATE typedef in the shared C namespace, so this file introduces
    -- NO named scalar typedef webview owns: it spells those inline (long, unsigned
    -- short*, unsigned long). Only GUID / PROPERTYKEY / MUDS_PROPVARIANT and the
    -- IMM*/IAudioEndpointVolume interface tags are declared here, and nothing else in
    -- the tree declares them. Redeclaring an IDENTICAL extern function (CoTaskMemFree,
    -- WideCharToMultiByte ...) is allowed by LuaJIT and harmless.
    --
    -- ============================ UNVERIFIED SCAFFOLD ============================
    -- PARSE-checked reasoning only. Never compiled against ole32 or run on Windows.
    -- The COM vtable slot orders (IMMDevice::Activate=3, IAudioEndpointVolume::
    -- GetMasterVolumeLevelScalar=9, ...) and the PROPVARIANT layout are transcribed
    -- from the MMDevice IDL by hand and MUST be validated on the rig. Riskiest points
    -- are flagged inline with "RISK:".
    -- ============================================================================
    --
    -- SINGLE THREAD: no hook, no loop, no thread. Every call is synchronous COM on the
    -- runloop thread. There is nothing to poll -- volume/name are immediate queries --
    -- so this module never touches host.schedule. It stays a leaf.
-- END --

local ffi = require("ffi")

-- Foundation: shared Win32 types + the loaded kernel32 (for the UTF-16 helpers). --
    local host = require("hs.foundation")
    local K    = (host.C and host.C.kernel32) or ffi.load("kernel32")
-- END --

-- ole32: COM apartment + object creation + task-memory free. --
    -- ole32 is a system DLL, effectively always present. Loading it twice (hs.webview
    -- may already have) is harmless in LuaJIT -- the C declarations are process-global.
    local Ole = ffi.load("ole32")
-- END --

-- Own FFI surface (COM structs + unique typedefs + ole32/kernel32 fns; no shared type re-declared) --
    ffi.cdef[[
/* --- Unique structs foundation/webview do not declare ------------------------- */
typedef struct { unsigned long Data1; unsigned short Data2; unsigned short Data3;
                 unsigned char Data4[8]; } GUID;

typedef struct { GUID fmtid; unsigned long pid; } PROPERTYKEY;

/* Minimal PROPVARIANT: we only ever read a VT_LPWSTR (vt==31). The union member of
 * interest (pwszVal) sits after the 8-byte {vt,r1,r2,r3} header on both ABIs. The
 * trailing pad guarantees we are at least as large as a real PROPVARIANT (16 B x86 /
 * 24 B x64) so PropVariantClear can safely walk it. */
typedef struct {
  unsigned short vt; unsigned short r1; unsigned short r2; unsigned short r3;
  unsigned short* pwszVal;
  unsigned long long pad;
} MUDS_PROPVARIANT;

/* --- COM interfaces WE CALL. Each vtable is IUnknown(0..2) then the interface's
 * methods in EXACT IDL order; slots we never call are void* padding. `this` and out
 * params are void* / concrete-tag* -- cast Lua-side. RISK: every slot index below is
 * hand-transcribed from the MMDevice IDL and must be verified on the rig. -------- */
typedef struct IMMDeviceEnumerator IMMDeviceEnumerator;
typedef struct IMMDevice           IMMDevice;
typedef struct IMMDeviceCollection IMMDeviceCollection;
typedef struct IPropertyStore      IPropertyStore;
typedef struct IAudioEndpointVolume IAudioEndpointVolume;

typedef struct IMMDeviceEnumeratorVtbl {
  long          (__stdcall *QueryInterface)(void*, const GUID*, void**);
  unsigned long (__stdcall *AddRef)(void*);
  unsigned long (__stdcall *Release)(void*);
  long (__stdcall *EnumAudioEndpoints)(void*, int, DWORD, IMMDeviceCollection**);      /* 3 */
  long (__stdcall *GetDefaultAudioEndpoint)(void*, int, int, IMMDevice**);             /* 4 */
  long (__stdcall *GetDevice)(void*, const unsigned short*, IMMDevice**);              /* 5 */
  /* Register/Unregister endpoint notification -- unused */
} IMMDeviceEnumeratorVtbl;
struct IMMDeviceEnumerator { IMMDeviceEnumeratorVtbl* lpVtbl; };

typedef struct IMMDeviceVtbl {
  long          (__stdcall *QueryInterface)(void*, const GUID*, void**);
  unsigned long (__stdcall *AddRef)(void*);
  unsigned long (__stdcall *Release)(void*);
  long (__stdcall *Activate)(void*, const GUID*, DWORD, void*, void**);                /* 3 */
  long (__stdcall *OpenPropertyStore)(void*, DWORD, IPropertyStore**);                 /* 4 */
  long (__stdcall *GetId)(void*, unsigned short**);                                    /* 5 */
  long (__stdcall *GetState)(void*, DWORD*);                                           /* 6 */
} IMMDeviceVtbl;
struct IMMDevice { IMMDeviceVtbl* lpVtbl; };

typedef struct IMMDeviceCollectionVtbl {
  long          (__stdcall *QueryInterface)(void*, const GUID*, void**);
  unsigned long (__stdcall *AddRef)(void*);
  unsigned long (__stdcall *Release)(void*);
  long (__stdcall *GetCount)(void*, UINT*);                                            /* 3 */
  long (__stdcall *Item)(void*, UINT, IMMDevice**);                                    /* 4 */
} IMMDeviceCollectionVtbl;
struct IMMDeviceCollection { IMMDeviceCollectionVtbl* lpVtbl; };

typedef struct IPropertyStoreVtbl {
  long          (__stdcall *QueryInterface)(void*, const GUID*, void**);
  unsigned long (__stdcall *AddRef)(void*);
  unsigned long (__stdcall *Release)(void*);
  long (__stdcall *GetCount)(void*, DWORD*);                                           /* 3 */
  long (__stdcall *GetAt)(void*, DWORD, PROPERTYKEY*);                                 /* 4 */
  long (__stdcall *GetValue)(void*, const PROPERTYKEY*, MUDS_PROPVARIANT*);            /* 5 */
  /* SetValue, Commit -- unused */
} IPropertyStoreVtbl;
struct IPropertyStore { IPropertyStoreVtbl* lpVtbl; };

typedef struct IAudioEndpointVolumeVtbl {
  long          (__stdcall *QueryInterface)(void*, const GUID*, void**);
  unsigned long (__stdcall *AddRef)(void*);
  unsigned long (__stdcall *Release)(void*);
  void* pad_RegisterControlChangeNotify;                                              /* 3 */
  void* pad_UnregisterControlChangeNotify;                                            /* 4 */
  void* pad_GetChannelCount;                                                          /* 5 */
  void* pad_SetMasterVolumeLevel;                                                     /* 6 */
  long (__stdcall *SetMasterVolumeLevelScalar)(void*, float, const GUID*);            /* 7 */
  void* pad_GetMasterVolumeLevel;                                                     /* 8 */
  long (__stdcall *GetMasterVolumeLevelScalar)(void*, float*);                        /* 9 */
  void* pad_SetChannelVolumeLevel;                                                    /* 10 */
  void* pad_SetChannelVolumeLevelScalar;                                             /* 11 */
  void* pad_GetChannelVolumeLevel;                                                    /* 12 */
  void* pad_GetChannelVolumeLevelScalar;                                             /* 13 */
  long (__stdcall *SetMute)(void*, BOOL, const GUID*);                                /* 14 */
  long (__stdcall *GetMute)(void*, BOOL*);                                            /* 15 */
  /* remaining slots unused */
} IAudioEndpointVolumeVtbl;
struct IAudioEndpointVolume { IAudioEndpointVolumeVtbl* lpVtbl; };

/* --- COM apartment + object creation + task-memory free (ole32) --- */
long CoInitializeEx(void*, unsigned long);
long CoCreateInstance(const GUID*, void*, unsigned long, const GUID*, void**);
void CoTaskMemFree(void*);
long PropVariantClear(MUDS_PROPVARIANT*);

/* --- UTF-16 -> UTF-8 (kernel32); identical redecl of webview's is allowed --- */
int WideCharToMultiByte(unsigned int, unsigned long, const unsigned short*, int,
                        char*, int, const char*, void*);
]]
-- END --

-- Constants + well-known GUIDs --
    local S_OK        = 0
    local CP_UTF8     = 65001
    local CLSCTX_ALL  = 23           -- INPROC_SERVER|INPROC_HANDLER|LOCAL|REMOTE
    local COINIT_APARTMENTTHREADED = 0x2

    local eRender             = 0    -- EDataFlow: output/playback endpoints
    local eConsole            = 0    -- ERole: the default multimedia console role
    local DEVICE_STATE_ACTIVE = 0x1
    local STGM_READ           = 0
    local VT_LPWSTR           = 31

    -- Parse a canonical GUID string into a kept GUID cdata. The returned cdata is
    -- passed BY POINTER to COM, so callers must anchor it for the call's lifetime;
    -- the module-scope GUIDs below live forever.
    local function guid(s)
        local g   = ffi.new("GUID")
        local hex = (s:gsub("%-", ""))
        g.Data1 = tonumber(hex:sub(1, 8), 16)
        g.Data2 = tonumber(hex:sub(9, 12), 16)
        g.Data3 = tonumber(hex:sub(13, 16), 16)
        for i = 0, 7 do g.Data4[i] = tonumber(hex:sub(17 + i * 2, 18 + i * 2), 16) end
        return g
    end

    local CLSID_MMDeviceEnumerator = guid("BCDE0395-E52F-467C-8E3D-C4579291692E")
    local IID_IMMDeviceEnumerator  = guid("A95664D2-9614-4F35-A746-DE8DB63617E6")
    local IID_IAudioEndpointVolume = guid("5CDF2C82-841E-4546-9722-0CF74078229A")

    -- PKEY_Device_FriendlyName = fmtid {a45c254e-...}, pid 14. Built once.
    local PKEY_Device_FriendlyName = ffi.new("PROPERTYKEY")
    PKEY_Device_FriendlyName.fmtid = guid("A45C254E-DF1C-4EFD-8020-67D146A850E0")
    PKEY_Device_FriendlyName.pid   = 14
-- END --

-- COM apartment init (once, on the runloop thread) --
    -- Every method here runs synchronous COM on this thread, so the apartment must be
    -- initialised before the first call. RPC_E_CHANGED_MODE (already inited another
    -- model, e.g. hs.webview picked STA) is benign; we only need SOME apartment.
    Ole.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
-- END --

-- UTF-16 -> UTF-8 (LPWSTR out-params from GetValue / GetId) --
    local function fromWide(ptr)
        if ptr == nil then return nil end
        local need = K.WideCharToMultiByte(CP_UTF8, 0, ptr, -1, nil, 0, nil, nil)
        if need <= 0 then return nil end
        local buf = ffi.new("char[?]", need)
        K.WideCharToMultiByte(CP_UTF8, 0, ptr, -1, buf, need, nil, nil)
        return ffi.string(buf)  -- stops at the NUL WideCharToMultiByte counted
    end
-- END --

-- The single shared IMMDeviceEnumerator (created lazily, kept for the process) --
    -- One enumerator serves every query. Anchored at module scope so its COM object is
    -- never released while the module lives. Returns nil if Core Audio is unavailable.
    local enumerator  -- IMMDeviceEnumerator*

    local function getEnumerator()
        if enumerator then return enumerator end
        local out = ffi.new("void*[1]")
        local hr  = Ole.CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
                                         IID_IMMDeviceEnumerator, out)
        if hr ~= S_OK or out[0] == nil then
            io.stderr:write("hs.audiodevice: CoCreateInstance(MMDeviceEnumerator) failed"
                .. " (hr=" .. tostring(hr) .. ")\n")
            return nil
        end
        enumerator = ffi.cast("IMMDeviceEnumerator*", out[0])
        return enumerator
    end
-- END --

-- Device object --
    -- Wraps a live IMMDevice*. The IAudioEndpointVolume is activated lazily on the
    -- first volume/mute call and cached. The wrapped COM pointers are AddRef'd out-
    -- params (GetDefaultAudioEndpoint / Item both return owning references), anchored
    -- on the Lua object; we do not proactively Release -- these device handles live for
    -- the session, matching Hammerspoon's long-lived device objects.
    local Device = {}
    Device.__index = Device

    local function newDevice(immPtr)
        return setmetatable({ _dev = ffi.cast("IMMDevice*", immPtr), _vol = nil }, Device)
    end

    -- Activate (and cache) the endpoint-volume interface. nil if unsupported.
    local function endpointVolume(self)
        if self._vol then return self._vol end
        if self._dev == nil then return nil end
        local out = ffi.new("void*[1]")
        -- RISK: Activate slot 3; IID_IAudioEndpointVolume; CLSCTX_ALL; NULL params.
        local hr  = self._dev.lpVtbl.Activate(self._dev, IID_IAudioEndpointVolume,
                                              CLSCTX_ALL, nil, out)
        if hr ~= S_OK or out[0] == nil then return nil end
        self._vol = ffi.cast("IAudioEndpointVolume*", out[0])
        return self._vol
    end

    -- :name() -> the device's friendly name (PKEY_Device_FriendlyName), or nil.
    function Device:name()
        if self._name then return self._name end
        if self._dev == nil then return nil end
        local store = ffi.new("void*[1]")
        if self._dev.lpVtbl.OpenPropertyStore(self._dev, STGM_READ, ffi.cast("IPropertyStore**", store)) ~= S_OK
           or store[0] == nil then
            return nil
        end
        local ps = ffi.cast("IPropertyStore*", store[0])
        local pv = ffi.new("MUDS_PROPVARIANT")
        local name
        if ps.lpVtbl.GetValue(ps, PKEY_Device_FriendlyName, pv) == S_OK and pv.vt == VT_LPWSTR then
            name = fromWide(pv.pwszVal)
        end
        Ole.PropVariantClear(pv)       -- frees pv.pwszVal (COM-allocated)
        ps.lpVtbl.Release(ps)          -- OpenPropertyStore returned an owning ref
        self._name = name
        return name
    end

    -- :volume() -> master output volume as 0..100, or nil if the endpoint has no
    -- volume control. Core Audio's scalar is 0.0..1.0; Hammerspoon reports 0..100.
    function Device:volume()
        local v = endpointVolume(self)
        if not v then return nil end
        local out = ffi.new("float[1]")
        if v.lpVtbl.GetMasterVolumeLevelScalar(v, out) ~= S_OK then return nil end
        return tonumber(out[0]) * 100.0
    end

    -- :setVolume(n) -> self. n is 0..100 (clamped); mapped to the 0.0..1.0 scalar.
    -- NULL event-context GUID (we are not a change-notification client).
    function Device:setVolume(n)
        local v = endpointVolume(self)
        if not v then return self end
        n = tonumber(n) or 0
        if n < 0 then n = 0 elseif n > 100 then n = 100 end
        v.lpVtbl.SetMasterVolumeLevelScalar(v, n / 100.0, nil)
        return self
    end

    -- :muted() -> boolean, or nil if unsupported.
    function Device:muted()
        local v = endpointVolume(self)
        if not v then return nil end
        local out = ffi.new("BOOL[1]")
        if v.lpVtbl.GetMute(v, out) ~= S_OK then return nil end
        return out[0] ~= 0
    end

    -- :setMuted(bool) -> self.
    function Device:setMuted(b)
        local v = endpointVolume(self)
        if not v then return self end
        v.lpVtbl.SetMute(v, b and 1 or 0, nil)
        return self
    end
-- END --

local audiodevice = {}

-- hs.audiodevice.defaultOutputDevice() -> device | nil --
    -- The system default (eConsole) render endpoint. nil if Core Audio is unavailable
    -- or there is no active output device.
    function audiodevice.defaultOutputDevice()
        local e = getEnumerator()
        if not e then return nil end
        local out = ffi.new("void*[1]")
        local hr  = e.lpVtbl.GetDefaultAudioEndpoint(e, eRender, eConsole,
                                                     ffi.cast("IMMDevice**", out))
        if hr ~= S_OK or out[0] == nil then return nil end
        return newDevice(out[0])
    end
-- END --

-- hs.audiodevice.findOutputByName(name) -> device | nil --
    -- Enumerate active render endpoints and return the first whose friendly name
    -- matches `name` exactly. Returns nil when none match.
    function audiodevice.findOutputByName(name)
        if type(name) ~= "string" then return nil end
        local e = getEnumerator()
        if not e then return nil end

        local coll = ffi.new("void*[1]")
        if e.lpVtbl.EnumAudioEndpoints(e, eRender, DEVICE_STATE_ACTIVE,
                                       ffi.cast("IMMDeviceCollection**", coll)) ~= S_OK
           or coll[0] == nil then
            return nil
        end
        local collection = ffi.cast("IMMDeviceCollection*", coll[0])

        local count = ffi.new("UINT[1]")
        collection.lpVtbl.GetCount(collection, count)

        local found
        for i = 0, tonumber(count[0]) - 1 do
            local devOut = ffi.new("void*[1]")
            if collection.lpVtbl.Item(collection, i, ffi.cast("IMMDevice**", devOut)) == S_OK
               and devOut[0] ~= nil then
                local d = newDevice(devOut[0])
                if d:name() == name then found = d; break end
                -- Non-match: drop our owning ref so the collection's devices don't leak.
                d._dev.lpVtbl.Release(d._dev)
            end
        end
        collection.lpVtbl.Release(collection)   -- EnumAudioEndpoints returned an owning ref
        return found
    end
-- END --

-- hs.audiodevice.allOutputDevices() -> array of devices (supporting/parity helper) --
    -- Not on the strict demand list, but a natural companion to findOutputByName and
    -- cheap to provide off the same enumeration. Returns {} when unavailable.
    function audiodevice.allOutputDevices()
        local e = getEnumerator()
        if not e then return {} end
        local coll = ffi.new("void*[1]")
        if e.lpVtbl.EnumAudioEndpoints(e, eRender, DEVICE_STATE_ACTIVE,
                                       ffi.cast("IMMDeviceCollection**", coll)) ~= S_OK
           or coll[0] == nil then
            return {}
        end
        local collection = ffi.cast("IMMDeviceCollection*", coll[0])
        local count = ffi.new("UINT[1]")
        collection.lpVtbl.GetCount(collection, count)
        local list = {}
        for i = 0, tonumber(count[0]) - 1 do
            local devOut = ffi.new("void*[1]")
            if collection.lpVtbl.Item(collection, i, ffi.cast("IMMDevice**", devOut)) == S_OK
               and devOut[0] ~= nil then
                list[#list + 1] = newDevice(devOut[0])
            end
        end
        collection.lpVtbl.Release(collection)
        return list
    end
-- END --

return audiodevice
