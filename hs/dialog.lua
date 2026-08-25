-- hs.dialog  (Win32 message box + file/folder picker) --
    -- Hammerspoon's hs.dialog wraps NSAlert / NSOpenPanel. This covers the two pieces
    -- mudscript uses, with FLAT C APIs only (no COM vtables -- deliberately avoiding the
    -- webview COM class of risk):
    --
    --   hs.dialog.blockAlert(message, informativeText, button1[, button2][, style])
    --       -> the label string of the button the user clicked.
    --       Backed by MessageBoxA. LIMITATION: MessageBoxA cannot show custom button
    --       labels, so a two-button alert renders as OK / Cancel while still RETURNING
    --       button1 / button2 (the return value -- what callers switch on -- is faithful;
    --       only the visible glyphs differ). A future faithful upgrade is TaskDialog.
    --
    --   hs.dialog.chooseFileOrFolder(title, defaultPath, canChooseFiles, canChooseDirs,
    --                                allowMultiple[, allowedFileTypes])
    --       -> an ARRAY of selected path strings, or nil if cancelled.
    --       Folders (canChooseDirs and not canChooseFiles) use SHBrowseForFolder; files
    --       use GetOpenFileNameA (OFN_ALLOWMULTISELECT when allowMultiple). Callers read
    --       it via pairs()+type=="string", so the array shape is what they expect.
    --
    -- CDEF OWNERSHIP: base types + HWND come from foundation. This module owns
    -- MessageBoxA (user32), the OPENFILENAMEA/BROWSEINFOA structs + GetOpenFileNameA
    -- (comdlg32), SHBrowseForFolderA/SHGetPathFromIDListA/ILFree (shell32), and
    -- CoInitialize (ole32) -- none declared elsewhere. char* is used in place of LPSTR to
    -- avoid a duplicate typedef.
    --
    -- THREADING: modal -- MessageBoxA / the pickers pump their own message loop and block
    -- the calling (runloop) thread until dismissed. mudscript calls these off UI actions
    -- where blocking is intended; note ms_shell wraps chooseFileOrFolder in a "finder
    -- interlude" that hides the shell first so the native dialog is not occluded.
-- END --

local ffi = require("ffi")
local bit = require("bit")

local host = require("hs.foundation")

local okC,  CD = pcall(ffi.load, "comdlg32")   -- GetOpenFileName
local okSh, SH = pcall(ffi.load, "shell32")    -- SHBrowseForFolder / paths
local okOle, OLE = pcall(ffi.load, "ole32")    -- CoInitialize (for the new folder dialog)
if not okC  then CD  = nil end
if not okSh then SH  = nil end
if not okOle then OLE = nil end

local U = host.C.user32

-- Own FFI surface (only symbols nothing else declares) --
    ffi.cdef[[
int  MessageBoxA(HWND, LPCSTR, LPCSTR, UINT);

typedef struct {
    DWORD     lStructSize;
    HWND      hwndOwner;
    HINSTANCE hInstance;
    LPCSTR    lpstrFilter;
    char*     lpstrCustomFilter;
    DWORD     nMaxCustFilter;
    DWORD     nFilterIndex;
    char*     lpstrFile;
    DWORD     nMaxFile;
    char*     lpstrFileTitle;
    DWORD     nMaxFileTitle;
    LPCSTR    lpstrInitialDir;
    LPCSTR    lpstrTitle;
    DWORD     Flags;
    WORD      nFileOffset;
    WORD      nFileExtension;
    LPCSTR    lpstrDefExt;
    LPARAM    lCustData;
    void*     lpfnHook;
    LPCSTR    lpTemplateName;
    void*     pvReserved;
    DWORD     dwReserved;
    DWORD     FlagsEx;
} OPENFILENAMEA;
BOOL GetOpenFileNameA(OPENFILENAMEA*);

typedef struct {
    HWND   hwndOwner;
    void*  pidlRoot;
    char*  pszDisplayName;
    LPCSTR lpszTitle;
    UINT   ulFlags;
    void*  lpfn;
    LPARAM lParam;
    int    iImage;
} BROWSEINFOA;
void* SHBrowseForFolderA(BROWSEINFOA*);
BOOL  SHGetPathFromIDListA(void*, char*);
void  ILFree(void*);

long  CoInitialize(void*);
]]
-- END --

-- Constants --
    local MB_OK           = 0x0
    local MB_OKCANCEL     = 0x1
    local MB_ICONWARNING  = 0x30
    local MB_SETFOREGROUND = 0x10000
    local IDOK            = 1

    local OFN_FILEMUSTEXIST   = 0x00001000
    local OFN_PATHMUSTEXIST   = 0x00000800
    local OFN_EXPLORER        = 0x00080000
    local OFN_ALLOWMULTISELECT = 0x00000200
    local OFN_NOCHANGEDIR     = 0x00000008

    local BIF_RETURNONLYFSDIRS = 0x0001
    local BIF_NEWDIALOGSTYLE   = 0x0040

    local MAX_PATH   = 260
    local MULTI_BUF  = 32768   -- room for many paths in the multiselect double-NUL list
-- END --

-- Helpers --
    -- A NUL-terminated char[] from a Lua string (for LPCSTR params).
    local function cstr(s)
        s = tostring(s or "")
        local b = ffi.new("char[?]", #s + 1)
        ffi.copy(b, s)
        return b
    end

    -- Build a GetOpenFileName filter block from a list of bare extensions:
    --   {"wav","mp3"} -> "Supported Files\0*.wav;*.mp3\0All Files\0*.*\0\0"
    -- nil/empty -> just an All-Files entry. The block is double-NUL terminated.
    local function filterBlock(types)
        local pats = {}
        if type(types) == "table" then
            for _, t in ipairs(types) do pats[#pats + 1] = "*." .. tostring(t) end
        end
        local parts
        if #pats > 0 then
            parts = { "Supported Files", table.concat(pats, ";"), "All Files", "*.*" }
        else
            parts = { "All Files", "*.*" }
        end
        local s = table.concat(parts, "\0") .. "\0\0"
        local b = ffi.new("char[?]", #s)
        ffi.copy(b, s, #s)   -- copy WITH the embedded/trailing NULs (no string truncation)
        return b
    end
-- END --

local dialog = {}

-- blockAlert --
    function dialog.blockAlert(message, informativeText, button1, button2, _style)
        local text = tostring(message or "")
        if informativeText and #tostring(informativeText) > 0 then
            text = text .. "\n\n" .. tostring(informativeText)
        end
        local kind = button2 and MB_OKCANCEL or MB_OK
        local flags = bit.bor(kind, MB_ICONWARNING, MB_SETFOREGROUND)
        local ret = U.MessageBoxA(nil, cstr(text), cstr("mudscript"), flags)
        if not button2 then return button1 end
        return (ret == IDOK) and button1 or button2
    end
-- END --

-- chooseFileOrFolder --
    local function chooseFolder(title)
        if not SH then return nil end
        if OLE then pcall(function() OLE.CoInitialize(nil) end) end
        local bi = ffi.new("BROWSEINFOA")
        local disp = ffi.new("char[?]", MAX_PATH)
        bi.pszDisplayName = disp
        bi.lpszTitle      = ffi.cast("LPCSTR", cstr(title or "Choose a folder"))
        bi.ulFlags        = bit.bor(BIF_RETURNONLYFSDIRS, BIF_NEWDIALOGSTYLE)
        local pidl = SH.SHBrowseForFolderA(bi)
        if pidl == nil then return nil end
        local out = ffi.new("char[?]", MAX_PATH)
        local ok  = SH.SHGetPathFromIDListA(pidl, out) ~= 0
        pcall(function() SH.ILFree(pidl) end)
        if not ok then return nil end
        local p = ffi.string(out)
        return (#p > 0) and { p } or nil
    end

    local function chooseFiles(title, defaultPath, allowMultiple, types)
        if not CD then return nil end
        local buf = ffi.new("char[?]", MULTI_BUF)   -- zero-filled by ffi.new
        local ofn = ffi.new("OPENFILENAMEA")
        ofn.lStructSize     = ffi.sizeof("OPENFILENAMEA")
        ofn.lpstrFile       = buf
        ofn.nMaxFile        = MULTI_BUF
        ofn.lpstrFilter     = ffi.cast("LPCSTR", filterBlock(types))
        ofn.nFilterIndex    = 1
        ofn.lpstrTitle      = ffi.cast("LPCSTR", cstr(title or "Choose a file"))
        if defaultPath and #tostring(defaultPath) > 0 then
            ofn.lpstrInitialDir = ffi.cast("LPCSTR", cstr(defaultPath))
        end
        local flags = bit.bor(OFN_FILEMUSTEXIST, OFN_PATHMUSTEXIST, OFN_EXPLORER, OFN_NOCHANGEDIR)
        if allowMultiple then flags = bit.bor(flags, OFN_ALLOWMULTISELECT) end
        ofn.Flags = flags

        if CD.GetOpenFileNameA(ofn) == 0 then return nil end   -- cancelled or error

        -- Single select: buf is one full path. Multiselect (EXPLORER): a directory,
        -- then each file name, each NUL-separated, ending in a double NUL. If only one
        -- file was picked the list is just that single full path (no directory prefix).
        local parts, i = {}, 0
        while i < MULTI_BUF do
            local s = ffi.string(buf + i)
            if #s == 0 then break end
            parts[#parts + 1] = s
            i = i + #s + 1
        end
        if #parts == 0 then return nil end
        if #parts == 1 then return { parts[1] } end
        local dir, out = parts[1], {}
        local sep = dir:sub(-1) == "\\" and "" or "\\"
        for k = 2, #parts do out[#out + 1] = dir .. sep .. parts[k] end
        return out
    end

    function dialog.chooseFileOrFolder(title, defaultPath, canChooseFiles, canChooseDirs,
                                       allowMultiple, allowedFileTypes)
        if canChooseDirs and not canChooseFiles then
            return chooseFolder(title)
        end
        return chooseFiles(title, defaultPath, allowMultiple, allowedFileTypes)
    end
-- END --

-- Other hs.dialog entry points mudscript does not use -- present as safe fallbacks --
    function dialog.textPrompt(_msg, _info, _default, b1, _b2)
        return b1 or "OK", ""   -- no native input box; return the default button, empty text
    end
    function dialog.alert(...) return dialog.blockAlert(...) end
-- END --

return dialog
