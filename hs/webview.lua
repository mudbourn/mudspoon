-- hs.webview  (WebView2 binding via LuaJIT FFI + COM) --
    -- A Hammerspoon-shaped hs.webview backed by the Microsoft Edge WebView2 runtime,
    -- driven from LuaJIT over raw COM (no C shim). This is the largest module in the
    -- port: it owns a layered top-most host window (modelled on hs/alert/window.lua),
    -- the async WebView2 environment/controller bring-up, the JS<->Lua message bridge,
    -- and the full webview object surface mudscript consumes.
    --
    -- ============================ UNVERIFIED SCAFFOLD ============================
    -- This has been PARSE-checked only (luajit -bl). It has NEVER been compiled
    -- against user32/WebView2Loader or run on Windows. Everything below about COM
    -- vtable slot orders, HRESULT handling, async pump timing, and the presence of
    -- the WebView2 runtime is a REASONED ASSUMPTION the human must validate on the
    -- rig. The riskiest assumptions are called out inline with "RISK:".
    -- ============================================================================
    --
    -- Depends on hs.foundation for: shared Win32 typedefs (HWND, RECT, DWORD, BOOL,
    -- WNDPROC, WNDCLASSEXA, MSG ...), the loaded libs (host.C.user32/.kernel32/.gdi32),
    -- host.moduleHandle, and -- critically -- the ONE runloop (host.run) that pumps the
    -- message loop WebView2's async completion handlers are delivered on. This module
    -- installs NO hook and runs NO loop of its own (frozen shared rule).
    --
    -- Per the frozen cdef-ownership rule, foundation owns every shared TYPE. This file
    -- ffi.cdef's ONLY: its own COM interface/vtable structs, the WebView2Loader export,
    -- the COM/string/window FUNCTIONS it calls that foundation does not declare, and
    -- unique typedefs (HRESULT, ULONG, LPCWSTR, EventRegistrationToken). It never
    -- re-typedef's a foundation type.
    --
    -- NOTE: hs/init.lua is FROZEN and does NOT wire hs.webview (it was not an A-G
    -- packet). Consumers require("hs.webview") directly.
    --
    -- -------------------------- The async bring-up shape --------------------------
    -- WebView2 creation is asynchronous and multi-step. new() returns a usable object
    -- SYNCHRONOUSLY, but the underlying CoreWebView2 is not ready until two round trips
    -- through the runloop complete:
    --
    --   1. new() creates the host HWND immediately, then calls
    --      CreateCoreWebView2EnvironmentWithOptions(NULL, NULL, NULL, envHandler).
    --   2. The runloop pumps; envHandler:Invoke(hr, environment) fires. We call
    --      environment->CreateCoreWebView2Controller(hwnd, ctrlHandler).
    --   3. The runloop pumps; ctrlHandler:Invoke(hr, controller) fires. We call
    --      controller->get_CoreWebView2(&core), wire the WebMessageReceived handler,
    --      set bounds/visibility, and FLUSH the deferred-op queue.
    --
    -- Any html()/url()/evaluateJavaScript()/show()/frame() call made before step 3 is
    -- QUEUED (self._queue) and replayed in order once the core is live. Calls after
    -- step 3 run immediately. delete() is idempotent and safe at any stage.
-- END --

local ffi = require("ffi")
local bit = require("bit")

-- Foundation: shared types + loaded libs + module handle + the one runloop. --
    local host = require("hs.foundation")
    local U     = host.C.user32
    local K     = host.C.kernel32
    local hInst = host.moduleHandle
-- END --

-- Submodule: the user-content controller (JS -> Lua callback holder). --
    local usercontent = require("hs.webview.usercontent")
-- END --

-- DPI: consumers pass LOGICAL rects (mac-like points); the host window + WebView2
-- bounds are physical device pixels. WebView2 auto-scales its CSS by the monitor DPI
-- when the process is DPI-aware, so a physically-sized host renders the page at the
-- right logical size and sharp. logi() maps logical -> physical; with the process
-- DPI-unaware scale is 1.0 and this is a no-op (old behaviour). See [[hs.dpiscale]].
    local dpiscale = require("hs.dpiscale")
    local function logi(v) return math.floor(v * dpiscale.get() + 0.5) end
-- END --

-- Bring-up trace (first-light diagnostics; defined early -- ensureLibs uses it) --
    -- WebView2 has never actually run under this host. Each COM boundary in the async
    -- bring-up logs a line (tees to hammerspoon.log), so if the rig crashes, the LAST
    -- line names the exact step that faulted -- pair it with the SEH exception-code
    -- capture in run_mudscript.lua. Bring-up is solid now, so this is OFF by default;
    -- set MUDSPOON_WEBVIEW_TRACE=1 to re-enable the per-COM-boundary log.
    local TRACE = os.getenv("MUDSPOON_WEBVIEW_TRACE") == "1"
    local function trace(msg)
        if TRACE then io.stderr:write("[hs.webview] " .. msg .. "\n") end
    end

    -- Bisection switch: MUDSPOON_WEBVIEW_NOHTML=1 makes html()/url() no-op, so the
    -- view comes up blank. If the process then SURVIVES (heartbeats tick), the fault
    -- is in the navigation / page / WebMessageReceived path; if it still dies, it is
    -- the bare controller/visibility path. Diagnostic only.
    local NO_HTML = os.getenv("MUDSPOON_WEBVIEW_NOHTML") == "1"

    -- Deeper bisection: MUDSPOON_WEBVIEW_MINIMAL=1 stops the controller Invoke right
    -- after get_CoreWebView2 -- skips add_WebMessageReceived, put_Bounds (by-value
    -- RECT), put_IsVisible, and the queue flush. If the process then SURVIVES, one of
    -- those three post-core calls is the corrupting call; if it STILL dies, merely
    -- having a live controller pump messages is fatal. Diagnostic only.
    local MINIMAL = os.getenv("MUDSPOON_WEBVIEW_MINIMAL") == "1"
-- END --

-- External libs unique to this module (loaded LAZILY, not at require time). --
    -- WebView2Loader.dll must be on the DLL search path (shipped next to the app, or
    -- the Evergreen runtime installed). Loading it at module scope would make a
    -- missing DLL abort the WHOLE host at require("hs.webview") -- even for a session
    -- that never opens a webview. So defer: require() only cdefs; the DLLs load on
    -- the first webview.new(), and a missing one raises a clear, contained error
    -- there instead of taking down boot. ole32 (COM apartment + CoTaskMemFree) is a
    -- system DLL and effectively always present, but is loaded on the same path.
    local Loader, Ole  -- populated by ensureLibs()

    local function ensureLibs()
        if Loader and Ole then return end
        local ok, l = pcall(ffi.load, "WebView2Loader")
        if not ok then
            error("hs.webview: WebView2Loader.dll not found on the DLL search path -- "
                .. "ship it next to the app or install the WebView2 Evergreen runtime "
                .. "(" .. tostring(l) .. ")", 2)
        end
        Loader = l
        Ole    = ffi.load("ole32")

        -- COM must be initialized on the thread that pumps WebView2's messages.
        -- new() is called from mac/ on the runloop thread, so init here (once).
        -- RPC_E_CHANGED_MODE (already inited with another model) is benign, ignored.
        Ole.CoInitializeEx(nil, 0x2)  -- COINIT_APARTMENTTHREADED
        trace("ensureLibs: WebView2Loader + ole32 loaded, CoInitializeEx(STA) done"
              .. " [LuaJIT " .. (ffi.abi("64bit") and "64-bit" or "32-bit")
              .. ", win=" .. tostring(ffi.abi("win")) .. "]")
    end
-- END --

-- Own FFI surface (functions + COM structs + unique typedefs; no shared type re-declared) --
    ffi.cdef[[
/* --- Unique scalar typedefs (foundation does not declare these) --- */
typedef long           HRESULT;
typedef unsigned long  ULONG;
typedef const unsigned short* LPCWSTR;   /* UTF-16, NUL-terminated */
typedef unsigned short*       LPWSTR;
typedef char*                 LPSTR;      /* foundation declares LPCSTR, not LPSTR */
typedef struct { long long value; } EventRegistrationToken;
/* COREWEBVIEW2_COLOR: BYTE A,R,G,B, passed BY VALUE to put_DefaultBackgroundColor.
 * A=0 => fully transparent default background (no opaque white first frame). */
typedef struct { unsigned char A, R, G, B; } COREWEBVIEW2_COLOR;

/* --- COM callback objects WE IMPLEMENT ---------------------------------------
 * We build these Lua-side. QueryInterface/AddRef/Release take a void* `this` so
 * one set of shared casts serves every handler; Invoke params are void* and are
 * cast to concrete interfaces inside the Lua body (keeps the cdef minimal and
 * decoupled). Slot order is IUnknown(3) then Invoke -- fixed by the WebView2 IDL.
 * RISK: these three IIDs/slot layouts must match the runtime's expectations. */
typedef struct EnvHandler EnvHandler;
typedef struct EnvHandlerVtbl {
  HRESULT (__stdcall *QueryInterface)(void*, void*, void**);
  ULONG   (__stdcall *AddRef)(void*);
  ULONG   (__stdcall *Release)(void*);
  HRESULT (__stdcall *Invoke)(void*, HRESULT, void* /*ICoreWebView2Environment* */);
} EnvHandlerVtbl;
struct EnvHandler { EnvHandlerVtbl* lpVtbl; };

typedef struct CtrlHandler CtrlHandler;
typedef struct CtrlHandlerVtbl {
  HRESULT (__stdcall *QueryInterface)(void*, void*, void**);
  ULONG   (__stdcall *AddRef)(void*);
  ULONG   (__stdcall *Release)(void*);
  HRESULT (__stdcall *Invoke)(void*, HRESULT, void* /*ICoreWebView2Controller* */);
} CtrlHandlerVtbl;
struct CtrlHandler { CtrlHandlerVtbl* lpVtbl; };

typedef struct MsgHandler MsgHandler;
typedef struct MsgHandlerVtbl {
  HRESULT (__stdcall *QueryInterface)(void*, void*, void**);
  ULONG   (__stdcall *AddRef)(void*);
  ULONG   (__stdcall *Release)(void*);
  HRESULT (__stdcall *Invoke)(void*, void* /*ICoreWebView2* */, void* /*args*/);
} MsgHandlerVtbl;
struct MsgHandler { MsgHandlerVtbl* lpVtbl; };

/* NavigationCompleted handler: same shape as MsgHandler (IUnknown + a two-arg
 * Invoke(sender, args)). Invoke's args is an ICoreWebView2NavigationCompletedEventArgs. */
typedef struct NavHandler NavHandler;
typedef struct NavHandlerVtbl {
  HRESULT (__stdcall *QueryInterface)(void*, void*, void**);
  ULONG   (__stdcall *AddRef)(void*);
  ULONG   (__stdcall *Release)(void*);
  HRESULT (__stdcall *Invoke)(void*, void* /*ICoreWebView2* */, void* /*args*/);
} NavHandlerVtbl;
struct NavHandler { NavHandlerVtbl* lpVtbl; };

/* --- COM interfaces WE CALL --------------------------------------------------
 * Each vtable is IUnknown(3) then the interface's methods in EXACT IDL order.
 * Methods we never call are declared as void* placeholders (`pad*`) purely to
 * keep the slots we DO call at the correct offset. RISK: every one of these slot
 * orders is transcribed from the WebView2 IDL by hand and must be verified. */
typedef struct ICoreWebView2Environment ICoreWebView2Environment;
typedef struct ICoreWebView2Controller  ICoreWebView2Controller;
typedef struct ICoreWebView2            ICoreWebView2;
typedef struct ICoreWebView2WebMessageReceivedEventArgs ICoreWebView2WebMessageReceivedEventArgs;

/* ICoreWebView2Environment: CreateCoreWebView2Controller is slot 3 (first after IUnknown). */
typedef struct ICoreWebView2EnvironmentVtbl {
  HRESULT (__stdcall *QueryInterface)(ICoreWebView2Environment*, void*, void**);
  ULONG   (__stdcall *AddRef)(ICoreWebView2Environment*);
  ULONG   (__stdcall *Release)(ICoreWebView2Environment*);
  HRESULT (__stdcall *CreateCoreWebView2Controller)(ICoreWebView2Environment*, HWND, CtrlHandler*);
  /* remaining slots (CreateWebResourceResponse, get_BrowserVersionString, ...) unused */
} ICoreWebView2EnvironmentVtbl;
struct ICoreWebView2Environment { ICoreWebView2EnvironmentVtbl* lpVtbl; };

/* ICoreWebView2Controller: get_CoreWebView2 is slot 25, so the full leading run
 * of slots must be laid out. Only put_IsVisible(4), put_Bounds(6), Close(24),
 * get_CoreWebView2(25) are called; the rest are void* padding. */
typedef struct ICoreWebView2ControllerVtbl {
  HRESULT (__stdcall *QueryInterface)(ICoreWebView2Controller*, void*, void**);
  ULONG   (__stdcall *AddRef)(ICoreWebView2Controller*);
  ULONG   (__stdcall *Release)(ICoreWebView2Controller*);
  void* pad_get_IsVisible;                                                   /* 3 */
  HRESULT (__stdcall *put_IsVisible)(ICoreWebView2Controller*, BOOL);        /* 4 */
  void* pad_get_Bounds;                                                      /* 5 */
  HRESULT (__stdcall *put_Bounds)(ICoreWebView2Controller*, RECT);           /* 6 */
  void* pad_get_ZoomFactor;                                                  /* 7 */
  void* pad_put_ZoomFactor;                                                  /* 8 */
  void* pad_add_ZoomFactorChanged;                                           /* 9 */
  void* pad_remove_ZoomFactorChanged;                                        /* 10 */
  void* pad_SetBoundsAndZoomFactor;                                          /* 11 */
  void* pad_MoveFocus;                                                       /* 12 */
  void* pad_add_MoveFocusRequested;                                          /* 13 */
  void* pad_remove_MoveFocusRequested;                                       /* 14 */
  void* pad_add_GotFocus;                                                    /* 15 */
  void* pad_remove_GotFocus;                                                 /* 16 */
  void* pad_add_LostFocus;                                                   /* 17 */
  void* pad_remove_LostFocus;                                                /* 18 */
  void* pad_add_AcceleratorKeyPressed;                                       /* 19 */
  void* pad_remove_AcceleratorKeyPressed;                                    /* 20 */
  void* pad_get_ParentWindow;                                                /* 21 */
  void* pad_put_ParentWindow;                                                /* 22 */
  void* pad_NotifyParentWindowPositionChanged;                              /* 23 */
  HRESULT (__stdcall *Close)(ICoreWebView2Controller*);                      /* 24 */
  HRESULT (__stdcall *get_CoreWebView2)(ICoreWebView2Controller*, ICoreWebView2**); /* 25 */
  /* --- ICoreWebView2Controller2 additions (the runtime's controller object
   * implements Controller2, whose vtable extends Controller's; these two slots
   * follow get_CoreWebView2). Only put_DefaultBackgroundColor is called -- setting
   * a transparent (A=0) default kills the opaque WHITE first-frame the control
   * otherwise paints before the page's transparent-background CSS lands (the brief
   * white flash on fade-in). RISK: valid only on Controller2-capable runtimes
   * (Evergreen >= 1.0.774, ~2020); guarded by pcall at the call site. */
  void*   pad_get_DefaultBackgroundColor;                                    /* 26 */
  HRESULT (__stdcall *put_DefaultBackgroundColor)(ICoreWebView2Controller*, COREWEBVIEW2_COLOR); /* 27 */
} ICoreWebView2ControllerVtbl;
struct ICoreWebView2Controller { ICoreWebView2ControllerVtbl* lpVtbl; };

/* ICoreWebView2: Navigate(5), NavigateToString(6), ExecuteScript(27),
 * add_WebMessageReceived(32) are called; everything else is void* padding. */
typedef struct ICoreWebView2Vtbl {
  HRESULT (__stdcall *QueryInterface)(ICoreWebView2*, void*, void**);
  ULONG   (__stdcall *AddRef)(ICoreWebView2*);
  ULONG   (__stdcall *Release)(ICoreWebView2*);
  void* pad_get_Settings;                                                    /* 3 */
  void* pad_get_Source;                                                      /* 4 */
  HRESULT (__stdcall *Navigate)(ICoreWebView2*, LPCWSTR);                    /* 5 */
  HRESULT (__stdcall *NavigateToString)(ICoreWebView2*, LPCWSTR);           /* 6 */
  void* pad_add_NavigationStarting;                                          /* 7 */
  void* pad_remove_NavigationStarting;                                       /* 8 */
  void* pad_add_ContentLoading;                                              /* 9 */
  void* pad_remove_ContentLoading;                                           /* 10 */
  void* pad_add_SourceChanged;                                               /* 11 */
  void* pad_remove_SourceChanged;                                            /* 12 */
  void* pad_add_HistoryChanged;                                              /* 13 */
  void* pad_remove_HistoryChanged;                                           /* 14 */
  HRESULT (__stdcall *add_NavigationCompleted)(ICoreWebView2*, NavHandler*, EventRegistrationToken*); /* 15 */
  void* pad_remove_NavigationCompleted;                                      /* 16 */
  void* pad_add_FrameNavigationStarting;                                     /* 17 */
  void* pad_remove_FrameNavigationStarting;                                  /* 18 */
  void* pad_add_FrameNavigationCompleted;                                    /* 19 */
  void* pad_remove_FrameNavigationCompleted;                                 /* 20 */
  void* pad_add_ScriptDialogOpening;                                         /* 21 */
  void* pad_remove_ScriptDialogOpening;                                      /* 22 */
  void* pad_add_PermissionRequested;                                         /* 23 */
  void* pad_remove_PermissionRequested;                                      /* 24 */
  void* pad_add_ProcessFailed;                                               /* 25 */
  void* pad_remove_ProcessFailed;                                            /* 26 */
  void* pad_AddScriptToExecuteOnDocumentCreated;                            /* 27... wait: see note */
  void* pad_RemoveScriptToExecuteOnDocumentCreated;                        /* 28 */
  HRESULT (__stdcall *ExecuteScript)(ICoreWebView2*, LPCWSTR, void* /*handler,NULL*/); /* 29 */
  void* pad_CapturePreview;                                                  /* 30 */
  void* pad_Reload;                                                          /* 31 */
  void* pad_PostWebMessageAsJson;                                            /* 32 */
  void* pad_PostWebMessageAsString;                                          /* 33 */
  HRESULT (__stdcall *add_WebMessageReceived)(ICoreWebView2*, MsgHandler*, EventRegistrationToken*); /* 34 */
  /* remaining slots unused */
} ICoreWebView2Vtbl;
struct ICoreWebView2 { ICoreWebView2Vtbl* lpVtbl; };

/* ICoreWebView2WebMessageReceivedEventArgs: TryGetWebMessageAsString is slot 5. */
typedef struct ICoreWebView2WebMessageReceivedEventArgsVtbl {
  HRESULT (__stdcall *QueryInterface)(ICoreWebView2WebMessageReceivedEventArgs*, void*, void**);
  ULONG   (__stdcall *AddRef)(ICoreWebView2WebMessageReceivedEventArgs*);
  ULONG   (__stdcall *Release)(ICoreWebView2WebMessageReceivedEventArgs*);
  void* pad_get_Source;                                                      /* 3 */
  void* pad_get_WebMessageAsJson;                                            /* 4 */
  HRESULT (__stdcall *TryGetWebMessageAsString)(ICoreWebView2WebMessageReceivedEventArgs*, LPWSTR*); /* 5 */
} ICoreWebView2WebMessageReceivedEventArgsVtbl;
struct ICoreWebView2WebMessageReceivedEventArgs { ICoreWebView2WebMessageReceivedEventArgsVtbl* lpVtbl; };

/* ICoreWebView2NavigationCompletedEventArgs: get_IsSuccess(3), get_WebErrorStatus(4,
 * COREWEBVIEW2_WEB_ERROR_STATUS is an int enum), get_NavigationId(5, UINT64). */
typedef struct ICoreWebView2NavigationCompletedEventArgs ICoreWebView2NavigationCompletedEventArgs;
typedef struct ICoreWebView2NavigationCompletedEventArgsVtbl {
  HRESULT (__stdcall *QueryInterface)(ICoreWebView2NavigationCompletedEventArgs*, void*, void**);
  ULONG   (__stdcall *AddRef)(ICoreWebView2NavigationCompletedEventArgs*);
  ULONG   (__stdcall *Release)(ICoreWebView2NavigationCompletedEventArgs*);
  HRESULT (__stdcall *get_IsSuccess)(ICoreWebView2NavigationCompletedEventArgs*, BOOL*);              /* 3 */
  HRESULT (__stdcall *get_WebErrorStatus)(ICoreWebView2NavigationCompletedEventArgs*, int*);          /* 4 */
  HRESULT (__stdcall *get_NavigationId)(ICoreWebView2NavigationCompletedEventArgs*, unsigned long long*); /* 5 */
} ICoreWebView2NavigationCompletedEventArgsVtbl;
struct ICoreWebView2NavigationCompletedEventArgs { ICoreWebView2NavigationCompletedEventArgsVtbl* lpVtbl; };

/* --- The WebView2Loader export --- */
HRESULT CreateCoreWebView2EnvironmentWithOptions(LPCWSTR, LPCWSTR, void*, EnvHandler*);

/* --- COM apartment + task-memory free (ole32) --- */
long CoInitializeEx(void*, unsigned long);
void CoTaskMemFree(void*);

/* --- UTF-8 <-> UTF-16 (kernel32) --- */
int MultiByteToWideChar(unsigned int, unsigned long, LPCSTR, int, LPWSTR, int);
int WideCharToMultiByte(unsigned int, unsigned long, LPCWSTR, int, LPSTR, int, LPCSTR, void*);

/* --- Host window management (user32; not declared by foundation) --- */
WORD    RegisterClassExA(const WNDCLASSEXA*);
HWND    CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, void*);
BOOL    DestroyWindow(HWND);
BOOL    ShowWindow(HWND, int);
LRESULT DefWindowProcA(HWND, UINT, WPARAM, LPARAM);
BOOL    GetClientRect(HWND, RECT*);
BOOL    SetLayeredWindowAttributes(HWND, DWORD, BYTE, DWORD);
BOOL    SetWindowPos(HWND, HWND, int, int, int, int, UINT);
BOOL    MoveWindow(HWND, int, int, int, int, BOOL);
long    GetWindowLongA(HWND, int);
long    SetWindowLongA(HWND, int, long);
BOOL    SetForegroundWindow(HWND);
BOOL    BringWindowToTop(HWND);
]]
-- END --
-- NOTE re ICoreWebView2 slot comments above: the trailing numeric comments drift
-- by the void* pads; the ANCHORS that matter are Navigate/NavigateToString right
-- after get_Source, add_NavigationCompleted right after remove_HistoryChanged
-- (slot 15), ExecuteScript after the two ScriptToExecute slots, and
-- add_WebMessageReceived after the two PostWebMessage slots. RISK: verify these
-- positions against Microsoft's WebView2.h on the rig before trusting a call.

-- Constants --
    local CP_UTF8           = 65001

    local COINIT_APARTMENTTHREADED = 0x2

    -- Window styles (mirrors hs/alert/window.lua's layered top-most popup).
    local WS_POPUP          = 0x80000000
    local WS_VISIBLE        = 0x10000000
    local EX_LAYERED        = 0x00080000
    local EX_TOPMOST        = 0x00000008
    local EX_TOOLWINDOW     = 0x00000080  -- keep out of taskbar / alt-tab
    local EX_NOACTIVATE     = 0x08000000  -- do not steal focus (text entry OFF)

    local GWL_STYLE         = -16
    local GWL_EXSTYLE       = -20

    local SW_HIDE           = 0
    local SW_SHOW           = 5
    local SW_SHOWNOACTIVATE = 4

    local LWA_ALPHA         = 0x02

    local WM_DESTROY        = 0x0002
    local WM_ERASEBKGND     = 0x0014

    -- SetWindowPos flags + special HWND z-order sentinels.
    local SWP_NOMOVE        = 0x0002
    local SWP_NOSIZE        = 0x0001
    local SWP_NOACTIVATE    = 0x0010
    local SWP_SHOWWINDOW    = 0x0040
    local HWND_TOP          = ffi.cast("HWND", 0)
    local HWND_TOPMOST      = ffi.cast("HWND", ffi.cast("intptr_t", -1))
    local HWND_NOTOPMOST    = ffi.cast("HWND", ffi.cast("intptr_t", -2))

    local S_OK              = 0
    local E_NOINTERFACE     = ffi.cast("long", 0x80004002)

    local CLASS             = "HammerspoonWebView"
-- END --

-- windowMasks (public constants; bit-flag integers) --
    -- Consumer reads M.borderless and M.nonactivating, defensively via (windowMasks
    -- or {}). Values are our own bit flags interpreted by :windowStyle(); they are
    -- NOT raw Win32 styles (those are applied internally in applyStyleMask).
    local windowMasks = {
        borderless    = 1,   -- no frame/title bar (WS_POPUP) -- default for this port
        titled        = 2,   -- (reserved) a normal caption
        closable      = 4,   -- (reserved)
        resizable     = 8,   -- (reserved)
        nonactivating = 16,  -- WS_EX_NOACTIVATE: window never takes keyboard focus
        utility       = 32,  -- (reserved)
    }
-- END --

-- Module-level keepalive for EVERY COM callback + backing cdata --
    -- THE #1 LuaJIT FFI FOOTGUN (foundation + screen.lua both note it): a collected
    -- ffi.cast callback, or a collected vtable/struct a live COM object still points
    -- at, is a hard crash. Everything a WebView2 object may call back into is anchored
    -- here for the whole process lifetime. We never remove entries.
    local ALIVE = {}
    local function keep(x) ALIVE[#ALIVE + 1] = x; return x end
-- END --

-- COM apartment init now happens in ensureLibs() (first webview.new), so a session
-- that never opens a webview neither loads the DLL nor touches COM. --

-- UTF-8 <-> UTF-16 helpers --
    -- toWide(s) -> uint16_t[] NUL-terminated. Kept by the CALLER for the duration of
    -- the COM call (LPCWSTR is borrowed, not copied by the callee synchronously... but
    -- Navigate/NavigateToString copy internally, so a local lifetime is fine).
    local function toWide(s)
        s = tostring(s or "")
        local need = K.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
        local buf  = ffi.new("unsigned short[?]", need + 1)  -- +1 for the NUL
        K.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, need)
        buf[need] = 0
        return buf
    end

    -- fromWide(ptr) -> Lua string. ptr is a NUL-terminated LPWSTR. Does NOT free ptr.
    local function fromWide(ptr)
        if ptr == nil then return "" end
        local need = K.WideCharToMultiByte(CP_UTF8, 0, ptr, -1, nil, 0, nil, nil)
        if need <= 0 then return "" end
        local buf = ffi.new("char[?]", need)
        K.WideCharToMultiByte(CP_UTF8, 0, ptr, -1, buf, need, nil, nil)
        return ffi.string(buf)  -- includes up to (need-1) bytes; -1 counted the NUL
    end
-- END --

-- Shared IUnknown callbacks for the objects WE IMPLEMENT --
    -- QueryInterface: hand back the same pointer for anything and report S_OK. A COM
    -- purist returns E_NOINTERFACE for unknown IIDs, but WebView2 only ever QIs these
    -- handlers for IUnknown / their own IID, and the caller merely holds the pointer.
    -- RISK: if the runtime QIs for an unexpected IID and USES the result as a
    -- different vtable, this is wrong -- revisit if bring-up misbehaves.
    -- AddRef/Release return a constant refcount: the objects live forever in ALIVE,
    -- so real refcounting is unnecessary (and never triggers our own teardown).
    local qiCast = keep(ffi.cast("HRESULT (__stdcall *)(void*, void*, void**)",
        function(this, riid, ppv)
            if ppv ~= nil then ppv[0] = this end
            return S_OK
        end))
    local addRefCast = keep(ffi.cast("ULONG (__stdcall *)(void*)", function(_) return 1 end))
    local relCast    = keep(ffi.cast("ULONG (__stdcall *)(void*)", function(_) return 1 end))
-- END --

-- Host window class (one shared WndProc, registered lazily once) --
    -- Modelled on hs/alert/window.lua. The WebView2 controller paints the whole client
    -- area, so this window itself does no WM_PAINT work -- it just hosts and sizes.
    local classBuf = ffi.new("char[?]", #CLASS + 1)
    ffi.copy(classBuf, CLASS)

    -- A Lua error must NEVER unwind through DispatchMessage (FFI boundary) -- guard it.
    local wndProc = keep(ffi.cast("WNDPROC", function(hwnd, msg, wp, lp)
        if msg == WM_DESTROY then
            return 0
        elseif msg == WM_ERASEBKGND then
            -- Claim the erase so Windows never blanks the host between frames. The
            -- WebView2 child fully covers and paints the client, so a host-side erase
            -- only adds a flash on invalidate/alpha-change/front -- the same flicker the
            -- canvas alerts had. (Same fix as hs/canvas.lua's WM_ERASEBKGND.)
            return 1
        end
        return U.DefWindowProcA(hwnd, msg, wp, lp)
    end))

    local classRegistered = false
    local function ensureClass()
        if classRegistered then return end
        local wc = ffi.new("WNDCLASSEXA")
        wc.cbSize        = ffi.sizeof("WNDCLASSEXA")
        wc.lpfnWndProc   = wndProc
        wc.hInstance     = hInst
        wc.lpszClassName = classBuf
        if U.RegisterClassExA(wc) == 0 then
            error("hs.webview: RegisterClassExA failed")
        end
        classRegistered = true
    end
-- END --

-- Style-mask -> Win32 style application --
    -- Applies our windowMasks bit flags onto the live HWND. borderless -> WS_POPUP,
    -- nonactivating -> WS_EX_NOACTIVATE. Kept small: the consumer only exercises
    -- borderless + nonactivating.
    local function applyStyleMask(hwnd, mask)
        mask = mask or windowMasks.borderless
        -- Base window style: popup (borderless) is the only shape mudscript uses.
        local style = WS_POPUP
        U.SetWindowLongA(hwnd, GWL_STYLE, ffi.cast("long", style))

        -- Extended style: always layered+topmost+toolwindow; NOACTIVATE if requested.
        local ex = bit.bor(EX_LAYERED, EX_TOPMOST, EX_TOOLWINDOW)
        if bit.band(mask, windowMasks.nonactivating) ~= 0 then
            ex = bit.bor(ex, EX_NOACTIVATE)
        end
        U.SetWindowLongA(hwnd, GWL_EXSTYLE, ffi.cast("long", ex))
    end
-- END --

local webview = {}
webview.windowMasks = windowMasks
webview.usercontent = usercontent

-- The webview object --
    local Webview = {}
    Webview.__index = Webview

    -- Run fn now if the CoreWebView2 is live, otherwise queue it for the flush that
    -- happens in the controller-ready Invoke. Ops replay in FIFO order.
    local function whenReady(self, fn)
        if self._deleted then return end
        if self._core then
            fn()
        else
            self._queue[#self._queue + 1] = fn
        end
    end

    -- Push the current self._rect to both the host window and the controller bounds.
    local function pushBounds(self)
        local r = self._rect
        U.MoveWindow(self._hwnd, logi(r.x), logi(r.y), logi(r.w), logi(r.h), 1)
        if self._controller ~= nil then
            local rc = ffi.new("RECT")
            rc.left, rc.top, rc.right, rc.bottom = 0, 0, logi(r.w), logi(r.h)  -- physical client px
            self._controller.lpVtbl.put_Bounds(self._controller, rc)
        end
    end

    -- :frame([rect]) -- getter with no arg, setter with a rect. Returns rect (getter)
    -- or self (setter, for chaining), matching Hammerspoon's mixed convention.
    function Webview:frame(rect)
        if rect == nil then
            local r = self._rect
            return { x = r.x, y = r.y, w = r.w, h = r.h }
        end
        self._rect = {
            x = rect.x or self._rect.x, y = rect.y or self._rect.y,
            w = rect.w or self._rect.w, h = rect.h or self._rect.h,
        }
        if not self._deleted then pushBounds(self) end
        return self
    end

    -- :setFrame(rect) -- explicit setter alias.
    function Webview:setFrame(rect)
        self:frame(rect)
        return self
    end

    -- JS<->Lua bridge shim. The shared mudscript UI posts to Lua with the WKWebView
    -- API `window.webkit.messageHandlers.<name>.postMessage(s)` (see ui/ms_shell.html
    -- shellDispatch). WebView2 has no `window.webkit`, so that call THREW and was
    -- swallowed by the page's try/catch -- the shell's `ready` message never arrived,
    -- `_shellReady` stayed false, and the window sat at alpha 0 (invisible). WebView2's
    -- own page->host channel is `window.chrome.webview.postMessage`, which our
    -- WebMessageReceived handler delivers to the usercontent callback. This shim maps
    -- the former onto the latter. Guarded: it is a no-op where a real `window.webkit`
    -- bridge exists (macOS), and where neither channel exists it leaves the page as-is.
    local BRIDGE_SHIM = table.concat({
        "<script>(function(){",
        "if(window.webkit&&window.webkit.messageHandlers)return;",
        "var cw=window.chrome&&window.chrome.webview;if(!cw)return;",
        "var H={},mk=function(){return{postMessage:function(s){cw.postMessage(String(s));}};};",
        "window.webkit={messageHandlers:new Proxy({},{get:function(_,n){",
        "return H[n]||(H[n]=mk());}})};",
        "})();</script>",
    })

    -- Normalise a baseURL argument to a document base URL for <base href>. Hammerspoon's
    -- :html(html, baseURL) sets the WKWebView base URL so a page's relative asset refs
    -- (e.g. url("./fonts/x.ttf")) resolve against it. WebView2's NavigateToString has NO
    -- base-URL parameter -- the reason the 2nd arg was silently dropped -- so we replicate
    -- the semantics by injecting <base href> (below). baseURL may arrive as a real URL
    -- (file://..., https://...), used verbatim, or a bare Windows path (C:\...\ui\), which
    -- a browser base href cannot use, so it is converted to a file:/// URL.
    --
    -- RISK (rig-verify): a <base href> makes relative refs RESOLVE, but WebView2/Chromium
    -- only permits file:// SUBRESOURCE loads from a document whose own origin is file://.
    -- NavigateToString gives the document an opaque origin, so a file:// base may still
    -- have its ./asset fetches BLOCKED by the security model -- exactly why the sibling
    -- AHK app Navigate()s to a file:// URL for its UIs instead of stringifying. This works
    -- as-is for http(s)/virtual-host baseURLs; if file:// assets do not load on the rig,
    -- the fix is ICoreWebView2_3::SetVirtualHostNameToFolderMapping (map the folder to a
    -- virtual https host, then set <base href> to that host) -- a new COM slot, not wired.
    local function toBaseURL(baseURL)
        if type(baseURL) ~= "string" or baseURL == "" then return nil end
        if baseURL:find("^%a[%w+.-]*://") then return baseURL end  -- already scheme://...
        local p = baseURL:gsub("\\", "/")                          -- path -> forward slashes
        if p:find("^/") then return "file://" .. p end             -- already rooted / UNC
        return "file:///" .. p                                     -- drive path: C:/...
    end

    -- The <base href> tag for a baseURL, or "" when none. Escapes the two attribute-
    -- breaking chars; the value is otherwise emitted verbatim.
    local function baseTag(baseURL)
        local u = toBaseURL(baseURL)
        if not u then return "" end
        u = u:gsub("&", "&amp;"):gsub('"', "&quot;")
        return '<base href="' .. u .. '">'
    end

    -- Insert our head content (a <base> for relative-asset resolution, then the bridge
    -- shim) so it runs before the page's own scripts and refs: right after the opening
    -- <head> if present, else prepended. <base> goes first so it governs every later
    -- relative URL in the document.
    local function injectHead(str, baseURL)
        if type(str) ~= "string" then return str end
        local inject = baseTag(baseURL) .. BRIDGE_SHIM
        if str:find("<head", 1, true) then
            return (str:gsub("(<head[^>]*>)", function(h) return h .. inject end, 1))
        end
        return inject .. str
    end

    -- :html(str [, baseURL]) -- load an HTML string (NavigateToString). baseURL, when
    -- given, sets the document base so relative asset refs resolve (see toBaseURL).
    -- Deferred until ready.
    function Webview:html(str, baseURL)
        if NO_HTML then trace(":html() suppressed (MUDSPOON_WEBVIEW_NOHTML)"); return self end
        local w = toWide(injectHead(str, baseURL))
        whenReady(self, function()
            self._html_keep = w  -- hold the wide buffer across the (sync-copying) call
            trace(":html flush -> NavigateToString")
            self._core.lpVtbl.NavigateToString(self._core, ffi.cast("LPCWSTR", w))
            trace(":html flush -> NavigateToString returned")
        end)
        return self
    end

    -- :url(str) -- navigate to a URL (Navigate). Deferred until ready.
    function Webview:url(str)
        if NO_HTML then trace(":url() suppressed (MUDSPOON_WEBVIEW_NOHTML)"); return self end
        local w = toWide(str)
        whenReady(self, function()
            self._url_keep = w
            self._core.lpVtbl.Navigate(self._core, ffi.cast("LPCWSTR", w))
        end)
        return self
    end

    -- :evaluateJavaScript(js) -- fire-and-forget ExecuteScript (NULL completion
    -- handler; the consumer never reads a result). Deferred until ready.
    function Webview:evaluateJavaScript(js)
        local w = toWide(js)
        whenReady(self, function()
            self._core.lpVtbl.ExecuteScript(self._core, ffi.cast("LPCWSTR", w), nil)
        end)
        return self
    end

    -- :navigationCallback(fn) -- register a page-navigation callback, Hammerspoon
    -- shape: fn(action, webView, navID[, errorTable]). WebView2 exposes only a single
    -- post-hoc NavigationCompleted event (no per-phase provisional/commit callbacks),
    -- so we emit the two actions it can actually distinguish:
    --   "didFinishNavigation"                on success
    --   "didFailNavigation", <errorTable>    on failure ({code, description})
    -- The NavigationCompleted handler is registered once during bring-up (see
    -- startBringUp) and reads self._navCallback live, so calling this before OR after
    -- the core is ready both work, and passing nil disables the callback. Returns self.
    function Webview:navigationCallback(fn)
        self._navCallback = fn
        return self
    end

    -- :show() -- reveal the host window (no activation) and the controller.
    function Webview:show()
        if self._deleted then return self end
        U.ShowWindow(self._hwnd, SW_SHOWNOACTIVATE)
        self._visible = true
        whenReady(self, function()
            self._controller.lpVtbl.put_IsVisible(self._controller, 1)
        end)
        return self
    end

    -- :hide() -- hide the host window and the controller.
    function Webview:hide()
        if self._deleted then return self end
        U.ShowWindow(self._hwnd, SW_HIDE)
        self._visible = false
        whenReady(self, function()
            self._controller.lpVtbl.put_IsVisible(self._controller, 0)
        end)
        return self
    end

    -- :bringToFront() -- raise above other top-most windows without stealing focus.
    function Webview:bringToFront()
        if self._deleted then return self end
        U.SetWindowPos(self._hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                       bit.bor(SWP_NOMOVE, SWP_NOSIZE, SWP_NOACTIVATE, SWP_SHOWWINDOW))
        return self
    end

    -- :alpha([n]) -- window opacity 0.0..1.0. Getter returns current; setter applies
    -- via SetLayeredWindowAttributes (window is WS_EX_LAYERED).
    function Webview:alpha(n)
        if n == nil then return self._alpha end
        if n < 0 then n = 0 elseif n > 1 then n = 1 end
        self._alpha = n
        if not self._deleted then
            U.SetLayeredWindowAttributes(self._hwnd, 0, math.floor(n * 255 + 0.5), LWA_ALPHA)
        end
        return self
    end

    -- :level([n]) -- z-order. Getter returns stored level; setter maps to topmost
    -- (n >= 0) vs normal (n < 0), the only distinction mudscript needs.
    function Webview:level(n)
        if n == nil then return self._level end
        self._level = n
        if not self._deleted then
            local z = (n >= 0) and HWND_TOPMOST or HWND_NOTOPMOST
            U.SetWindowPos(self._hwnd, z, 0, 0, 0, 0,
                           bit.bor(SWP_NOMOVE, SWP_NOSIZE, SWP_NOACTIVATE))
        end
        return self
    end

    -- :shadow([bool]) -- stored only. A borderless layered popup draws no OS shadow;
    -- kept for API parity so consumer chaining does not break. Getter/setter.
    function Webview:shadow(b)
        if b == nil then return self._shadow end
        self._shadow = b and true or false
        return self
    end

    -- :transparent([bool]) -- stored intent. True transparency needs per-pixel alpha
    -- (UpdateLayeredWindow) which WebView2's own compositing does not expose here;
    -- treated as a no-op flag for parity. Getter/setter.
    function Webview:transparent(b)
        if b == nil then return self._transparent end
        self._transparent = b and true or false
        return self
    end

    -- :allowTextEntry([bool]) -- whether the window accepts keyboard focus. Toggles
    -- WS_EX_NOACTIVATE: allowed => clear it, disallowed => set it. Getter/setter.
    function Webview:allowTextEntry(b)
        if b == nil then return self._allowTextEntry end
        self._allowTextEntry = b and true or false
        if not self._deleted then
            local ex = U.GetWindowLongA(self._hwnd, GWL_EXSTYLE)
            if self._allowTextEntry then
                ex = bit.band(tonumber(ex), bit.bnot(EX_NOACTIVATE))
            else
                ex = bit.bor(tonumber(ex), EX_NOACTIVATE)
            end
            U.SetWindowLongA(self._hwnd, GWL_EXSTYLE, ffi.cast("long", ex))
        end
        return self
    end

    -- :windowStyle(mask) -- apply a windowMasks bit-flag mask to the live window.
    function Webview:windowStyle(mask)
        self._mask = mask
        if not self._deleted then applyStyleMask(self._hwnd, mask) end
        return self
    end

    -- :delete() -- destroy the view and window. Idempotent. Closes the controller
    -- (which releases the CoreWebView2), destroys the HWND, and drops the queue.
    function Webview:delete()
        if self._deleted then return self end
        self._deleted = true
        self._queue = {}
        if self._controller ~= nil then
            -- RISK: Close() must be safe to call exactly once; double-close is UB.
            pcall(function() self._controller.lpVtbl.Close(self._controller) end)
            -- Release our retaining AddRef (taken in the ctrl Invoke). Close() first,
            -- then drop our reference so the controller can be destroyed.
            pcall(function() self._controller.lpVtbl.Release(self._controller) end)
        end
        self._controller = nil
        self._core       = nil
        if self._hwnd ~= nil then
            U.DestroyWindow(self._hwnd)
            self._hwnd = nil
        end
        -- Note: the COM handler cdata for this view stays in ALIVE forever. We cannot
        -- safely reclaim it -- a late runtime callback into a freed handler crashes.
        return self
    end
-- END --

-- Async bring-up: env -> controller -> core, then flush the queue --
    -- Build the three per-view COM handler objects, kick off environment creation, and
    -- chain the completions. Each handler's struct+vtbl+Invoke cast is keep()'d.
    local function startBringUp(self)
        -- WebMessageReceived handler: page -> Lua. Routes to the attached controller.
        local msgObj = ffi.new("MsgHandler")
        local msgVt  = ffi.new("MsgHandlerVtbl")
        msgVt.QueryInterface = qiCast
        msgVt.AddRef         = addRefCast
        msgVt.Release        = relCast
        msgVt.Invoke = keep(ffi.cast("HRESULT (__stdcall *)(void*, void*, void*)",
            function(_this, _sender, argsPtr)
                trace("msg Invoke: entered")
                -- Guarded: never throw across the FFI boundary out of a COM callback.
                pcall(function()
                    if self._ucc == nil then return end
                    local args = ffi.cast("ICoreWebView2WebMessageReceivedEventArgs*", argsPtr)
                    local out  = ffi.new("LPWSTR[1]")
                    -- RISK: for non-string web messages this returns an error HRESULT
                    -- and out[0] is untouched; the page always postMessage's a string.
                    trace("msg Invoke: TryGetWebMessageAsString (slot 5)")
                    local hr = args.lpVtbl.TryGetWebMessageAsString(args, out)
                    if hr == S_OK and out[0] ~= nil then
                        local s = fromWide(out[0])
                        trace("msg Invoke: got string len=" .. #s .. ", CoTaskMemFree")
                        Ole.CoTaskMemFree(out[0])       -- we own the returned buffer
                        trace("msg Invoke: delivering to ucc")
                        self._ucc:_deliver(s)
                        trace("msg Invoke: delivered")
                    end
                end)
                return S_OK
            end))
        keep(msgObj); keep(msgVt)
        msgObj.lpVtbl = msgVt
        self._msgObj = msgObj  -- also anchored on the object for clarity

        -- NavigationCompleted handler: page-navigation -> Lua. Reads self._navCallback
        -- live, so it is a no-op until :navigationCallback(fn) sets one.
        local navObj = ffi.new("NavHandler")
        local navVt  = ffi.new("NavHandlerVtbl")
        navVt.QueryInterface = qiCast
        navVt.AddRef         = addRefCast
        navVt.Release        = relCast
        navVt.Invoke = keep(ffi.cast("HRESULT (__stdcall *)(void*, void*, void*)",
            function(_this, _sender, argsPtr)
                trace("nav Invoke: entered")
                -- Guarded: never throw across the FFI boundary out of a COM callback.
                pcall(function()
                    local fn = self._navCallback
                    if fn == nil or argsPtr == nil then return end
                    local args = ffi.cast("ICoreWebView2NavigationCompletedEventArgs*", argsPtr)

                    local okBuf = ffi.new("BOOL[1]")
                    args.lpVtbl.get_IsSuccess(args, okBuf)

                    -- NavigationId is a UINT64; Hammerspoon reports navID as a string.
                    local idBuf = ffi.new("unsigned long long[1]")
                    args.lpVtbl.get_NavigationId(args, idBuf)
                    local navID = (tostring(idBuf[0]):gsub("[uUlL]+$", ""))

                    if okBuf[0] ~= 0 then
                        trace("nav Invoke: didFinishNavigation navID=" .. navID)
                        fn("didFinishNavigation", self, navID)
                    else
                        local errBuf = ffi.new("int[1]")
                        args.lpVtbl.get_WebErrorStatus(args, errBuf)
                        local code = tonumber(errBuf[0])
                        trace("nav Invoke: didFailNavigation navID=" .. navID .. " status=" .. tostring(code))
                        fn("didFailNavigation", self, navID, {
                            code        = code,
                            description = "WebView2 navigation failed (WebErrorStatus " .. tostring(code) .. ")",
                        })
                    end
                end)
                return S_OK
            end))
        keep(navObj); keep(navVt)
        navObj.lpVtbl = navVt
        self._navObj = navObj

        -- Controller-completed handler: gives us the ICoreWebView2Controller.
        local ctrlObj = ffi.new("CtrlHandler")
        local ctrlVt  = ffi.new("CtrlHandlerVtbl")
        ctrlVt.QueryInterface = qiCast
        ctrlVt.AddRef         = addRefCast
        ctrlVt.Release        = relCast
        ctrlVt.Invoke = keep(ffi.cast("HRESULT (__stdcall *)(void*, HRESULT, void*)",
            function(_this, hr, controllerPtr)
                trace("ctrl Invoke: entered, hr=" .. tostring(tonumber(hr)))
                pcall(function()
                    if self._deleted then return end
                    if hr ~= S_OK or controllerPtr == nil then
                        io.stderr:write("hs.webview: controller creation failed (hr=" ..
                                        tostring(tonumber(hr)) .. ")\n")
                        return
                    end
                    local controller = ffi.cast("ICoreWebView2Controller*", controllerPtr)
                    self._controller = controller

                    -- RETAIN it. The interface passed to a completion handler is valid
                    -- only for the duration of Invoke; WebView2 releases its transient
                    -- reference once Invoke returns. Without our own AddRef the
                    -- controller's refcount hits 0 and it is destroyed under us -- and
                    -- the very next message pump touches freed memory (a silent
                    -- fail-fast, below SEH). Keeping the Lua-side pointer is NOT enough;
                    -- the COM refcount is what keeps the C++ object alive. (get_ methods
                    -- like get_CoreWebView2 already return an AddRef'd out-param, so the
                    -- core needs no extra AddRef -- only this borrowed callback arg does.)
                    controller.lpVtbl.AddRef(controller)
                    trace("ctrl Invoke: controller AddRef'd (retained past Invoke)")

                    -- Transparent default background: without this the control paints an
                    -- opaque WHITE first frame before the page's background:transparent CSS
                    -- applies -- the brief white flash seen on fade-in. Guarded: a runtime
                    -- too old for ICoreWebView2Controller2 just keeps the white default.
                    pcall(function()
                        local c = ffi.new("COREWEBVIEW2_COLOR")
                        c.A, c.R, c.G, c.B = 0, 0, 0, 0
                        controller.lpVtbl.put_DefaultBackgroundColor(controller, c)
                        trace("ctrl Invoke: put_DefaultBackgroundColor(transparent) ok")
                    end)

                    -- Fetch the CoreWebView2 we actually drive.
                    trace("ctrl Invoke: get_CoreWebView2 (vtbl slot 25)")
                    local corePtr = ffi.new("ICoreWebView2*[1]")
                    controller.lpVtbl.get_CoreWebView2(controller, corePtr)
                    self._core = corePtr[0]
                    trace("ctrl Invoke: core = " .. tostring(self._core))

                    if MINIMAL then
                        trace("ctrl Invoke: MINIMAL -- skipping add_WebMessageReceived/"
                              .. "put_Bounds/put_IsVisible/flush; controller left idle")
                        return
                    end

                    -- Wire the page->Lua message stream (only if a controller was given).
                    if self._core ~= nil then
                        trace("ctrl Invoke: add_WebMessageReceived (vtbl slot 34)")
                        local token = ffi.new("EventRegistrationToken")
                        self._core.lpVtbl.add_WebMessageReceived(self._core, self._msgObj, token)

                        -- Wire NavigationCompleted -> :navigationCallback. Registered
                        -- unconditionally; the handler no-ops until a callback is set.
                        trace("ctrl Invoke: add_NavigationCompleted (vtbl slot 15)")
                        local navToken = ffi.new("EventRegistrationToken")
                        self._core.lpVtbl.add_NavigationCompleted(self._core, self._navObj, navToken)
                    end

                    -- Size + visibility now that the controller exists.
                    trace("ctrl Invoke: pushBounds (put_Bounds slot 6, RECT by value)")
                    pushBounds(self)
                    trace("ctrl Invoke: put_IsVisible (slot 4)")
                    controller.lpVtbl.put_IsVisible(controller, self._visible and 1 or 0)

                    -- FLUSH: replay every op queued before the core went live, in order.
                    trace("ctrl Invoke: flushing " .. #self._queue .. " queued op(s)")
                    local q = self._queue
                    self._queue = {}
                    for i = 1, #q do
                        local ok, err = pcall(q[i])
                        if not ok then
                            io.stderr:write("hs.webview: queued op error: " .. tostring(err) .. "\n")
                        end
                    end
                    trace("ctrl Invoke: bring-up COMPLETE, core is live")
                end)
                return S_OK
            end))
        keep(ctrlObj); keep(ctrlVt)
        ctrlObj.lpVtbl = ctrlVt
        self._ctrlObj = ctrlObj

        -- Environment-completed handler: gives us the environment; we then ask it to
        -- create the controller parented to our HWND.
        local envObj = ffi.new("EnvHandler")
        local envVt  = ffi.new("EnvHandlerVtbl")
        envVt.QueryInterface = qiCast
        envVt.AddRef         = addRefCast
        envVt.Release        = relCast
        envVt.Invoke = keep(ffi.cast("HRESULT (__stdcall *)(void*, HRESULT, void*)",
            function(_this, hr, envPtr)
                trace("env Invoke: entered, hr=" .. tostring(tonumber(hr)))
                pcall(function()
                    if self._deleted then return end
                    if hr ~= S_OK or envPtr == nil then
                        io.stderr:write("hs.webview: environment creation failed (hr=" ..
                                        tostring(tonumber(hr)) .. ")\n")
                        return
                    end
                    local env = ffi.cast("ICoreWebView2Environment*", envPtr)
                    trace("env Invoke: calling CreateCoreWebView2Controller (vtbl slot 3)")
                    env.lpVtbl.CreateCoreWebView2Controller(env, self._hwnd, self._ctrlObj)
                    trace("env Invoke: CreateCoreWebView2Controller returned")
                end)
                return S_OK
            end))
        keep(envObj); keep(envVt)
        envObj.lpVtbl = envVt
        self._envObj = envObj

        -- Kick it off. NULL browserExecutableFolder + NULL userDataFolder => the
        -- Evergreen runtime with a default per-user data folder. RISK: if the app
        -- has no write access to the default folder, creation fails asynchronously
        -- (surfaced as hr != S_OK above); pass an explicit temp folder if so.
        trace("startBringUp: CreateCoreWebView2EnvironmentWithOptions (async kickoff)")
        local hr = Loader.CreateCoreWebView2EnvironmentWithOptions(nil, nil, nil, envObj)
        trace("startBringUp: kickoff returned hr=" .. tostring(tonumber(hr))
              .. " (waiting for env Invoke on the runloop)")
        if tonumber(hr) < 0 then
            error("hs.webview: CreateCoreWebView2EnvironmentWithOptions failed (hr=" ..
                  tostring(tonumber(hr)) .. ")")
        end
    end
-- END --

-- hs.webview.new(rect [, prefs] [, usercontentController]) -> webview --
    -- Creates the host window synchronously and starts async WebView2 bring-up. Any
    -- html/url/evaluateJavaScript/show call before the core is ready is queued.
    --
    -- prefs: table; only developer-tools intent is meaningful, everything else is
    -- ignored (the consumer passes {} or a small table). We stash it; enabling dev
    -- tools requires ICoreWebView2Settings (not scaffolded -- not on the demand list).
    function webview.new(rect, prefs, usercontentController)
        ensureLibs()   -- load WebView2Loader/ole32 now; clear error if the DLL is absent
        ensureClass()
        rect = rect or {}
        local r = { x = rect.x or 0, y = rect.y or 0, w = rect.w or 800, h = rect.h or 600 }

        -- Extended style: layered + topmost + toolwindow, NOACTIVATE by default (text
        -- entry off until allowTextEntry(true)). Consumer flips it as needed.
        local exStyle = bit.bor(EX_LAYERED, EX_TOPMOST, EX_TOOLWINDOW, EX_NOACTIVATE)

        local hwnd = U.CreateWindowExA(exStyle, classBuf, "", WS_POPUP,
                                       logi(r.x), logi(r.y), logi(r.w), logi(r.h),
                                       nil, nil, hInst, nil)
        if hwnd == nil then
            error("hs.webview: CreateWindowExA failed")
        end
        trace("new(): host window created (hwnd ok)")
        -- Start fully TRANSPARENT (alpha 0), not opaque. A layered window hosting a
        -- WebView2 child can composite ONE opaque frame when the child first paints,
        -- before a subsequent alpha() lands -- seen as a flash/stutter right before the
        -- fade-in. Beginning at 0 means there is never an opaque value to flash.
        -- Consumers set their alpha before showing (mudscript always fades in from 0);
        -- _alpha keeps the logical 1.0 default until then, and the window is hidden at
        -- birth, so the physical/logical gap is never visible.
        U.SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA)

        local self = setmetatable({
            _hwnd           = hwnd,
            _rect           = r,
            _prefs          = prefs or {},
            _ucc            = usercontentController,  -- may be nil
            _navCallback    = nil,                    -- set by :navigationCallback(fn)
            _queue          = {},                     -- deferred ops until core ready
            _controller     = nil,
            _core           = nil,
            _visible        = false,
            _deleted        = false,
            _alpha          = 1.0,
            _level          = 0,
            _shadow         = false,
            _transparent    = false,
            _allowTextEntry = false,
            _mask           = windowMasks.borderless,
        }, Webview)

        startBringUp(self)
        return self
    end
-- END --

return webview
