-- hs.settings --
    local json = require("hs.json")

    local settings = {}

    settings.bundleID = "org.hammerspoon.Hammerspoon"

    local DIR = (os.getenv("APPDATA") or (os.getenv("USERPROFILE") or ".") .. "\\AppData\\Roaming") .. "\\Hammerspoon"

    local FILE = DIR .. "\\settings.json"

    local store

    -- Store loading --
        local function load()
            if store then return store end

            store = {}

            local f = io.open(FILE, "rb")

            if not f then return store end

            local raw = f:read("*a")

            f:close()

            local ok, decoded = pcall(json.decode, raw)

            if ok and type(decoded) == "table" then store = decoded end

            return store
        end
    -- END Store loading --

    -- Store saving --
        local function save()
            local fs = require("hs.fs")

            if not fs.attributes(DIR) then fs.mkdir(DIR) end

            local tmp = FILE .. ".tmp"

            local f = io.open(tmp, "wb")

            if not f then return false end

            f:write(json.encode(store))

            f:close()

            os.remove(FILE)

            return os.rename(tmp, FILE) and true or false
        end
    -- END Store saving --

    function settings.get(key)
        return load()[key]
    end

    function settings.set(key, value)
        load()[key] = value

        return save()
    end

    function settings.clear(key)
        local s = load()

        if s[key] == nil then return false end

        s[key] = nil

        return save()
    end

    function settings.getKeys()
        local keys = {}

        for k in pairs(load()) do keys[#keys + 1] = k end

        return keys
    end

    function settings.setDate(key, value)
        return settings.set(key, tonumber(value) or os.time())
    end

    function settings.getDate(key)
        return tonumber(settings.get(key))
    end

    settings.setData = settings.set

    settings.getData = settings.get

    return settings
-- END hs.settings --
