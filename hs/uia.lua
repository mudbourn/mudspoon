-- hs.uia  (shared UI Automation substrate; internal, not part of the hs.* API) --
    -- The single Windows UI-Automation (COM) bootstrap that BOTH hs.axuielement and
    -- hs.uielement hang off. It exists so the two public modules do not each spin up
    -- their own IUIAutomation instance or duplicate the (fiddly) COM vtable cdefs --
    -- exactly mirroring how every leaf module shares one hs.foundation substrate.
    --
    -- WHAT IT OWNS:
    --   * COM apartment init (CoInitializeEx) on the one foundation thread.
    --   * The process-wide CUIAutomation instance (uia.automation).
    --   * The COM interface vtable cdefs for IUIAutomation and IUIAutomationElement.
    --     These are UNIQUE to this module -- no other file declares a COM vtable, so
    --     there is no duplicate-typedef hazard with foundation. Base Win32 types
    --     (POINT, RECT, HWND, BOOL, DWORD ...) come from foundation and are NOT
    --     re-typedef'd here (LuaJIT errors on a duplicate typedef).
    --   * The element wrapper object shared by both public modules, including the
    --     poll-based :newWatcher (see WATCHER below) that rides the foundation timer
    --     scheduler rather than any private thread or message pump.
    --
    -- THREADING: UIA is called only from the foundation runloop thread. We initialise
    -- a single-threaded apartment (COINIT_APARTMENTTHREADED) there; the foundation
    -- message pump is exactly the pump an STA wants, so no extra pump is introduced.
    --
    -- CDEF OWNERSHIP: this module cdefs GUID, the two COM vtable/interface structs,
    -- CoInitializeEx/CoCreateInstance (ole32), SysStringLen/SysFreeString (oleaut32),
    -- and WideCharToMultiByte (kernel32). Nothing else declares these.
    --
    -- COM VTABLE LAYOUT NOTE: a COM object is a pointer to a struct whose first (and
    -- here only) member is lpVtbl, a pointer to a struct of __stdcall function
    -- pointers in a FROZEN order defined by the interface. We only need a handful of
    -- methods, but every slot BEFORE one we call must still occupy its exact position,
    -- so unused earlier slots are declared as plain void* placeholders (a pointer slot
    -- is 8 bytes whether we type it as a function pointer or not). The slot indices in
    -- the comments are the canonical uiautomationclient.h vtable indices -- do not
    -- reorder or the wrong function gets called.
    --
    -- GRACEFUL DEGRADATION: if ole32/oleaut32 are missing or CUIAutomation cannot be
    -- created, uia.available is false and every entry point returns nil rather than
    -- throwing, so a host without UIA still boots.
-- END --

local ffi = require("ffi")

local host     = require("hs.foundation")
local dpiscale = require("hs.dpiscale")

local K = host.C.kernel32

local okOle,  OLE  = pcall(ffi.load, "ole32")
local okOleA, OLEA = pcall(ffi.load, "oleaut32")
if not okOle  then OLE  = nil end
if not okOleA then OLEA = nil end

-- Own FFI surface (COM vtables + the few flat APIs; nothing else declares these) --
    ffi.cdef[[
typedef struct { unsigned long Data1; unsigned short Data2; unsigned short Data3; unsigned char Data4[8]; } GUID;

/* --- IUIAutomation ---------------------------------------------------------- */
typedef struct IUIAutomationVtbl IUIAutomationVtbl;
typedef struct { IUIAutomationVtbl* lpVtbl; } IUIAutomation;
struct IUIAutomationVtbl {
    long          (__stdcall *QueryInterface)(void*, const GUID*, void**);   /* 0 */
    unsigned long (__stdcall *AddRef)(void*);                                /* 1 */
    unsigned long (__stdcall *Release)(void*);                               /* 2 */
    long          (__stdcall *CompareElements)(void*, void*, void*, int*);   /* 3 */
    void* CompareRuntimeIds;                                                 /* 4 */
    long          (__stdcall *GetRootElement)(void*, void**);                /* 5 */
    void* ElementFromHandle;                                                 /* 6 */
    long          (__stdcall *ElementFromPoint)(void*, POINT, void**);       /* 7 */
    long          (__stdcall *GetFocusedElement)(void*, void**);             /* 8 */
};

/* --- IUIAutomationElement ---------------------------------------------------- */
typedef struct IUIAutomationElementVtbl IUIAutomationElementVtbl;
typedef struct { IUIAutomationElementVtbl* lpVtbl; } IUIAutomationElement;
struct IUIAutomationElementVtbl {
    long          (__stdcall *QueryInterface)(void*, const GUID*, void**);   /* 0  */
    unsigned long (__stdcall *AddRef)(void*);                                /* 1  */
    unsigned long (__stdcall *Release)(void*);                               /* 2  */
    long          (__stdcall *SetFocus)(void*);                              /* 3  */
    void* GetRuntimeId;                                                      /* 4  */
    void* FindFirst;                                                         /* 5  */
    void* FindAll;                                                           /* 6  */
    void* FindFirstBuildCache;                                               /* 7  */
    void* FindAllBuildCache;                                                 /* 8  */
    void* BuildUpdatedCache;                                                 /* 9  */
    void* GetCurrentPropertyValue;                                           /* 10 */
    void* GetCurrentPropertyValueEx;                                         /* 11 */
    void* GetCachedPropertyValue;                                            /* 12 */
    void* GetCachedPropertyValueEx;                                          /* 13 */
    void* GetCurrentPatternAs;                                               /* 14 */
    void* GetCachedPatternAs;                                                /* 15 */
    void* GetCurrentPattern;                                                 /* 16 */
    void* GetCachedPattern;                                                  /* 17 */
    void* GetCachedParent;                                                   /* 18 */
    void* GetCachedChildren;                                                 /* 19 */
    long          (__stdcall *get_CurrentProcessId)(void*, int*);            /* 20 */
    long          (__stdcall *get_CurrentControlType)(void*, int*);          /* 21 */
    void* get_CurrentLocalizedControlType;                                   /* 22 */
    long          (__stdcall *get_CurrentName)(void*, wchar_t**);            /* 23 */
    void* get_CurrentAcceleratorKey;                                         /* 24 */
    void* get_CurrentAccessKey;                                              /* 25 */
    long          (__stdcall *get_CurrentHasKeyboardFocus)(void*, int*);     /* 26 */
    void* get_CurrentIsKeyboardFocusable;                                    /* 27 */
    void* get_CurrentIsEnabled;                                              /* 28 */
    void* get_CurrentAutomationId;                                           /* 29 */
    void* get_CurrentClassName;                                              /* 30 */
    void* get_CurrentHelpText;                                               /* 31 */
    void* get_CurrentCulture;                                                /* 32 */
    void* get_CurrentIsControlElement;                                       /* 33 */
    void* get_CurrentIsContentElement;                                       /* 34 */
    void* get_CurrentIsPassword;                                             /* 35 */
    long          (__stdcall *get_CurrentNativeWindowHandle)(void*, void**); /* 36 */
    void* get_CurrentItemType;                                              /* 37 */
    void* get_CurrentIsOffscreen;                                           /* 38 */
    void* get_CurrentOrientation;                                           /* 39 */
    void* get_CurrentFrameworkId;                                           /* 40 */
    void* get_CurrentIsRequiredForForm;                                     /* 41 */
    void* get_CurrentItemStatus;                                            /* 42 */
    long          (__stdcall *get_CurrentBoundingRectangle)(void*, RECT*);  /* 43 */
};

long CoInitializeEx(void*, unsigned long);
long CoCreateInstance(const GUID*, void*, unsigned long, const GUID*, void**);

unsigned int SysStringLen(wchar_t*);
void         SysFreeString(wchar_t*);

int WideCharToMultiByte(unsigned int, unsigned long, const wchar_t*, int,
                        char*, int, const char*, int*);
]]
-- END --

-- Constants --
    local COINIT_APARTMENTTHREADED = 0x2
    local CLSCTX_INPROC_SERVER     = 0x1
    local CP_UTF8                  = 65001

    -- SUCCEEDED(hr): HRESULT is a signed 32-bit; the failure bit is the sign bit,
    -- so any negative value is a failure. S_OK == 0, S_FALSE == 1 both pass.
    local function ok(hr) return tonumber(hr) >= 0 end

    -- CLSID_CUIAutomation  {ff48dba4-60ef-4201-aa87-54103eef594e}
    -- IID_IUIAutomation    {30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}
    local function guid(d1, d2, d3, b0,b1,b2,b3,b4,b5,b6,b7)
        local g = ffi.new("GUID")
        g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
        local b = { b0,b1,b2,b3,b4,b5,b6,b7 }
        for i = 0, 7 do g.Data4[i] = b[i + 1] end
        return g
    end

    local CLSID_CUIAutomation = guid(0xff48dba4, 0x60ef, 0x4201, 0xaa,0x87,0x54,0x10,0x3e,0xef,0x59,0x4e)
    local IID_IUIAutomation   = guid(0x30cbe57d, 0xd9d0, 0x452a, 0xab,0x13,0x7a,0xc5,0xac,0x48,0x25,0xee)

    -- A small, pragmatic UIA-ControlTypeId -> Hammerspoon-ish AXRole map. UIA control
    -- types are 50000.. ; anything unmapped falls back to "AX"..id so callers still get
    -- a stable string. Not exhaustive -- extend as mudscript needs more roles.
    local CONTROL_TYPE_ROLE = {
        [50000] = "AXButton",     [50001] = "AXMenuBar",    [50002] = "AXRadioButton",
        [50003] = "AXCheckBox",   [50004] = "AXComboBox",   [50005] = "AXComboBox",
        [50008] = "AXTextField",  [50009] = "AXTextField",  [50011] = "AXStaticText",
        [50020] = "AXStaticText", [50021] = "AXTable",      [50023] = "AXMenu",
        [50024] = "AXMenuItem",   [50025] = "AXOutline",    [50026] = "AXTabGroup",
        [50032] = "AXWindow",     [50033] = "AXGroup",      [50034] = "AXImage",
    }
-- END --

local uia = { available = false }

-- BSTR (COM wide string) -> Lua UTF-8, then SysFreeString the BSTR. --
    -- get_Current* string getters hand back a BSTR the caller must free. nil/empty in,
    -- empty string out.
    local function bstrToUtf8(pw)
        if pw == nil then return "" end
        local n = tonumber(OLEA.SysStringLen(pw))
        if n <= 0 then OLEA.SysFreeString(pw); return "" end
        local need = K.WideCharToMultiByte(CP_UTF8, 0, pw, n, nil, 0, nil, nil)
        local out = ""
        if need > 0 then
            local buf = ffi.new("char[?]", need)
            K.WideCharToMultiByte(CP_UTF8, 0, pw, n, buf, need, nil, nil)
            out = ffi.string(buf, need)
        end
        OLEA.SysFreeString(pw)
        return out
    end
-- END --

-- Element wrapper (shared object shape for both public modules) --
    -- Wraps a raw IUIAutomationElement*. Lifetime: the raw pointer is handed to
    -- ffi.gc so COM Release runs when the Lua wrapper is collected -- no manual
    -- refcounting for callers, matching Hammerspoon's GC-managed userdata feel.
    local Element = {}
    Element.__index = Element

    -- Two wrappers are equal iff UIA says the underlying elements are the same, via
    -- IUIAutomation::CompareElements. Cheaper and more correct than runtime-id arrays.
    Element.__eq = function(a, b)
        if type(a) ~= "table" or type(b) ~= "table" then return false end
        if not (a._ptr and b._ptr and uia.automation) then return false end
        local same = ffi.new("int[1]")
        local hr = uia.automation.lpVtbl.CompareElements(uia.automation, a._ptr, b._ptr, same)
        return ok(hr) and same[0] ~= 0
    end

    -- Build a wrapper from a raw pointer (already AddRef'd by the call that produced
    -- it, per COM out-param rules). Returns nil for a NULL pointer.
    local function wrap(rawPtr)
        if rawPtr == nil then return nil end
        local p = ffi.cast("IUIAutomationElement*", rawPtr)
        p = ffi.gc(p, function(x) x.lpVtbl.Release(x) end)
        return setmetatable({ _ptr = p }, Element)
    end
    uia.wrap = wrap

    -- Raw typed getters (each returns nil on any COM failure). --
        function Element:_name()
            local out = ffi.new("wchar_t*[1]")
            if not ok(self._ptr.lpVtbl.get_CurrentName(self._ptr, out)) then return nil end
            return bstrToUtf8(out[0])
        end
        function Element:_controlType()
            local out = ffi.new("int[1]")
            if not ok(self._ptr.lpVtbl.get_CurrentControlType(self._ptr, out)) then return nil end
            return out[0]
        end
        function Element:_pid()
            local out = ffi.new("int[1]")
            if not ok(self._ptr.lpVtbl.get_CurrentProcessId(self._ptr, out)) then return nil end
            return out[0]
        end
        function Element:_hasFocus()
            local out = ffi.new("int[1]")
            if not ok(self._ptr.lpVtbl.get_CurrentHasKeyboardFocus(self._ptr, out)) then return nil end
            return out[0] ~= 0
        end
        function Element:_nativeWindow()
            local out = ffi.new("void*[1]")
            if not ok(self._ptr.lpVtbl.get_CurrentNativeWindowHandle(self._ptr, out)) then return nil end
            return tonumber(ffi.cast("intptr_t", out[0]))
        end
        function Element:_rect()
            local r = ffi.new("RECT")
            if not ok(self._ptr.lpVtbl.get_CurrentBoundingRectangle(self._ptr, r)) then return nil end
            local s = dpiscale.get()   -- UIA returns physical px; report logical (see hs.screen)
            return { x = r.left/s, y = r.top/s, w = (r.right - r.left)/s, h = (r.bottom - r.top)/s }
        end
    -- END --

    -- :role() -> AXRole-style string for the element's control type.
    function Element:role()
        local ct = self:_controlType()
        if not ct then return nil end
        return CONTROL_TYPE_ROLE[ct] or ("AX" .. tostring(ct))
    end

    -- :title() -> the element's UIA Name (its accessible title/label).
    function Element:title() return self:_name() end

    -- :attributeValue(attr) -> the value of a Hammerspoon AX attribute, mapped onto the
    -- nearest UIA property. Supports the handful mudscript actually reads; unknown
    -- attributes return nil (Hammerspoon's own behaviour for an absent attribute).
    function Element:attributeValue(attr)
        if     attr == "AXRole"                then return self:role()
        elseif attr == "AXTitle"               then return self:_name()
        elseif attr == "AXValue"               then return self:_name()
        elseif attr == "AXFocused"             then return self:_hasFocus()
        elseif attr == "AXProcessIdentifier" or attr == "AXPID" then return self:_pid()
        elseif attr == "AXWindow"              then return self:_nativeWindow()
        elseif attr == "AXFrame"               then return self:_rect()
        elseif attr == "AXPosition" then
            local r = self:_rect(); if r then return { x = r.x, y = r.y } end
        elseif attr == "AXSize" then
            local r = self:_rect(); if r then return { w = r.w, h = r.h } end
        end
        return nil
    end

    -- :isValid() -> is this still a usable element? A destroyed element makes its
    -- getters fail; we probe the cheapest one (ProcessId).
    function Element:isValid()
        return self:_pid() ~= nil
    end

    -- :pid() convenience (Hammerspoon uielement exposes the owning process id).
    function Element:pid() return self:_pid() end
-- END --

-- WATCHER (poll-based, on the foundation timer scheduler) --
    -- Hammerspoon: element:newWatcher(fn[, userdata]):start({events}):stop().
    -- fn is called fn(element, event, watcher, userdata) on a change.
    --
    -- WHY POLLING, NOT A COM EVENT SINK: a real UIA focus-changed handler
    -- (AddFocusChangedEventHandler) needs a fully-formed COM callback object -- our own
    -- IUIAutomationFocusChangedEventHandler with a correct QueryInterface/AddRef/Release
    -- + HandleFocusChangedEvent vtable that UIA calls back on ITS OWN threadpool
    -- thread, which then has to marshal onto the foundation thread. That is a lot of
    -- fragile hand-rolled COM for one event, and it violates the "no private thread"
    -- house rule the moment UIA calls us off-thread. Instead we poll the focused
    -- element on host.schedule (the same one timer pump everything else rides) and fire
    -- when it changes. Trade-off: up to POLL_MS latency and no sub-focus events -- fine
    -- for focus/app-activation watching, which is all the consumer needs. The event
    -- sink can be swapped in later behind this same :newWatcher seam without touching
    -- callers. THIS PATH IS UNVERIFIED on hardware (see module summary).
    local POLL_MS = 150

    local Watcher = {}
    Watcher.__index = Watcher

    function Element:newWatcher(fn, userdata)
        return setmetatable({
            _element  = self,
            _fn       = fn,
            _userdata = userdata,
            _timer    = nil,
            _last     = nil,   -- last-seen focused element (for change detection)
        }, Watcher)
    end

    -- :start(events) -> self. events is an array of Hammerspoon event names; we treat
    -- any focus/activation-flavoured request as "watch the focused element". The exact
    -- event string we emit is the first requested event, defaulting to the Hammerspoon
    -- focused-element event name.
    function Watcher:start(events)
        if self._timer then return self end
        local eventName = (type(events) == "table" and events[1]) or "AXFocusedUIElementChanged"
        -- Seed with the current focus so we only fire on an actual subsequent change.
        self._last = uia.getFocused()
        self._timer = host.schedule(POLL_MS, function()
            local cur = uia.getFocused()
            local changed
            if cur == nil then
                changed = (self._last ~= nil)
            elseif self._last == nil then
                changed = true
            else
                changed = not (cur == self._last)   -- Element.__eq (UIA CompareElements)
            end
            if changed then
                self._last = cur
                if self._fn then
                    local okc, err = pcall(self._fn, cur, eventName, self, self._userdata)
                    if not okc then
                        io.stderr:write("mudspoon uielement watcher error: " .. tostring(err) .. "\n")
                    end
                end
            end
        end, POLL_MS)
        return self
    end

    -- :stop() -> self. Cancels the poll timer (releasing it back to the scheduler).
    function Watcher:stop()
        if self._timer then self._timer:cancel(); self._timer = nil end
        return self
    end

    uia.Watcher = Watcher
-- END --

-- COM bootstrap + entry points --
    -- Initialise the apartment and create the one CUIAutomation instance. Any failure
    -- leaves uia.available false and the entry points returning nil.
    local function bootstrap()
        if not (OLE and OLEA) then return end
        -- CoInitializeEx may report S_FALSE (already inited) or RPC_E_CHANGED_MODE
        -- (0x80010106, apartment already set another way) -- both are acceptable; we
        -- only bail on a genuinely failed init that is neither of those.
        local RPC_E_CHANGED_MODE = -2147417850  -- 0x80010106 as signed
        local hr = OLE.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
        if not ok(hr) and tonumber(hr) ~= RPC_E_CHANGED_MODE then return end

        local pp = ffi.new("void*[1]")
        hr = OLE.CoCreateInstance(CLSID_CUIAutomation, nil, CLSCTX_INPROC_SERVER,
                                  IID_IUIAutomation, pp)
        if not ok(hr) or pp[0] == nil then return end

        uia.automation = ffi.cast("IUIAutomation*", pp[0])
        uia.available  = true
    end

    pcall(bootstrap)

    -- The systemwide root element (the desktop). Hammerspoon's systemWideElement.
    function uia.getRoot()
        if not uia.available then return nil end
        local out = ffi.new("void*[1]")
        if not ok(uia.automation.lpVtbl.GetRootElement(uia.automation, out)) then return nil end
        return wrap(out[0])
    end

    -- The element under a SCREEN point. x,y are logical coords (the space hs.screen /
    -- hs.mouse speak); UIA wants physical pixels, so scale up by the DPI factor.
    function uia.fromPoint(x, y)
        if not uia.available then return nil end
        local s = dpiscale.get()
        local pt = ffi.new("POINT")
        pt.x = math.floor((x or 0) * s + 0.5)
        pt.y = math.floor((y or 0) * s + 0.5)
        local out = ffi.new("void*[1]")
        if not ok(uia.automation.lpVtbl.ElementFromPoint(uia.automation, pt, out)) then return nil end
        return wrap(out[0])
    end

    -- The element that currently has keyboard focus. Hammerspoon's focusedElement.
    function uia.getFocused()
        if not uia.available then return nil end
        local out = ffi.new("void*[1]")
        if not ok(uia.automation.lpVtbl.GetFocusedElement(uia.automation, out)) then return nil end
        return wrap(out[0])
    end
-- END --

return uia
