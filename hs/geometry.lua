-- hs.geometry --
    -- Hammerspoon's unified point/size/rect type, as pure Lua (no FFI, no host).
    -- One object carries .x .y .w .h; whether it "is" a point, size, or rect is just
    -- which of those are present. Derived fields (.x1 .y1 .x2 .y2 .center .area
    -- .aspect) are computed on read via __index, and .x .y .w .h are settable via
    -- __newindex, matching Hammerspoon's live-field behaviour.
    --
    -- Leaf module: requires nothing else. mac/ uses hs.geometry.rect(...) to build a
    -- snapshot region and then reads .x .y .w .h back off it.
-- END --

local geometry = {}

-- Object plumbing --
    -- Raw fields live in an inner table keyed off the proxy via `store`, so the
    -- metatable can intercept every get/set. A geometry object IS the proxy.
    local store = setmetatable({}, { __mode = "k" })   -- proxy -> {x,y,w,h}
    local Geo = {}

    local function isGeo(v)
        return type(v) == "table" and store[v] ~= nil
    end
    geometry.isGeometry = isGeo

    -- Forward decl; defined after the metatable exists.
    local wrap
-- END --

-- Parse the many constructor forms into x,y,w,h (any may be nil) --
    -- Strings:  "x,y"  |  "wxh"  |  "x,y wxh"
    -- Tables:   {x=,y=,w=,h=}  |  {x,y,w,h} (positional)  |  another geometry
    -- Numbers:  (x)  (x,y)  (x,y,w,h)
    local function parseString(s)
        -- "x,y wxh" -- both halves present
        local x, y, w, h = s:match("^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s+(-?[%d%.]+)%s*[xX]%s*(-?[%d%.]+)%s*$")
        if x then return tonumber(x), tonumber(y), tonumber(w), tonumber(h) end
        -- "wxh" -- size only
        w, h = s:match("^%s*(-?[%d%.]+)%s*[xX]%s*(-?[%d%.]+)%s*$")
        if w then return nil, nil, tonumber(w), tonumber(h) end
        -- "x,y" -- point only
        x, y = s:match("^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
        if x then return tonumber(x), tonumber(y), nil, nil end
        error("hs.geometry: cannot parse string '" .. s .. "'", 3)
    end

    local function parse(a, b, c, d)
        local ta = type(a)
        if ta == "string" then
            return parseString(a)
        elseif isGeo(a) then
            local r = store[a]
            return r.x, r.y, r.w, r.h
        elseif ta == "table" then
            -- Named fields take precedence; fall back to positional {x,y,w,h}.
            local x = a.x or a[1]
            local y = a.y or a[2]
            local w = a.w or a[3]
            local h = a.h or a[4]
            return x, y, w, h
        elseif ta == "number" then
            return a, b, c, d
        elseif a == nil then
            return nil, nil, nil, nil
        end
        error("hs.geometry: bad constructor argument (" .. ta .. ")", 3)
    end
-- END --

-- Derived (read-only) getters, keyed by field name --
    local getters = {
        x1 = function(r) return r.x end,
        y1 = function(r) return r.y end,
        x2 = function(r) return (r.x or 0) + (r.w or 0) end,
        y2 = function(r) return (r.y or 0) + (r.h or 0) end,
        center = function(r)
            return wrap((r.x or 0) + (r.w or 0) / 2, (r.y or 0) + (r.h or 0) / 2)
        end,
        area = function(r) return (r.w or 0) * (r.h or 0) end,
        aspect = function(r)
            local h = r.h or 0
            if h == 0 then return nil end
            return (r.w or 0) / h
        end,
    }
-- END --

-- Metatable: live get/set + operators --
    local mt = {}

    mt.__index = function(self, k)
        if Geo[k] then return Geo[k] end            -- a method
        local r = store[self]
        if k == "x" or k == "y" or k == "w" or k == "h" then return r[k] end
        local g = getters[k]
        if g then return g(r) end
        return nil
    end

    mt.__newindex = function(self, k, v)
        local r = store[self]
        if k == "x" or k == "y" or k == "w" or k == "h" then
            r[k] = v
        elseif k == "x1" then r.x = v
        elseif k == "y1" then r.y = v
        elseif k == "x2" then r.w = (v or 0) - (r.x or 0)
        elseif k == "y2" then r.h = (v or 0) - (r.y or 0)
        else
            error("hs.geometry: cannot set field '" .. tostring(k) .. "'", 2)
        end
    end

    mt.__tostring = function(self)
        local r = store[self]
        local hasPos  = r.x ~= nil and r.y ~= nil
        local hasSize = r.w ~= nil and r.h ~= nil
        if hasPos and hasSize then
            return string.format("hs.geometry.rect(%g,%g,%g,%g)", r.x, r.y, r.w, r.h)
        elseif hasSize then
            return string.format("hs.geometry.size(%g,%g)", r.w, r.h)
        elseif hasPos then
            return string.format("hs.geometry.point(%g,%g)", r.x, r.y)
        end
        return "hs.geometry(<empty>)"
    end

    mt.__eq = function(a, b)
        if not (isGeo(a) and isGeo(b)) then return false end
        local ra, rb = store[a], store[b]
        return ra.x == rb.x and ra.y == rb.y and ra.w == rb.w and ra.h == rb.h
    end

    -- Build a proxy from explicit fields. Missing values stay nil.
    wrap = function(x, y, w, h)
        local self = setmetatable({}, mt)
        store[self] = { x = x, y = y, w = w, h = h }
        return self
    end
-- END --

-- Constructors --
    function geometry.new(a, b, c, d)
        return wrap(parse(a, b, c, d))
    end

    function geometry.rect(x, y, w, h)
        return wrap(x, y, w, h)
    end

    function geometry.point(x, y)
        return wrap(x, y, nil, nil)
    end

    function geometry.size(w, h)
        return wrap(nil, nil, w, h)
    end

    function geometry.copy(g)
        local r = store[g]
        if not r then error("hs.geometry.copy: not a geometry object", 2) end
        return wrap(r.x, r.y, r.w, r.h)
    end
-- END --

-- Methods --
    -- Translate in place by dx,dy (or by a point/table).
    function Geo:move(dx, dy)
        if isGeo(dx) or type(dx) == "table" or type(dx) == "string" then
            local px, py = parse(dx)
            dx, dy = px, py
        end
        local r = store[self]
        r.x = (r.x or 0) + (dx or 0)
        r.y = (r.y or 0) + (dy or 0)
        return self
    end

    -- Scale size (and origin) in place. One factor, or separate x/y factors.
    function Geo:scale(fx, fy)
        fy = fy or fx
        local r = store[self]
        if r.x then r.x = r.x * fx end
        if r.y then r.y = r.y * fy end
        if r.w then r.w = r.w * fx end
        if r.h then r.h = r.h * fy end
        return self
    end

    -- Rectangle equality (same as ==), accepts any constructor form.
    function Geo:equals(other)
        if not isGeo(other) then other = geometry.new(other) end
        return self == other
    end

    -- True if self lies entirely within rect.
    function Geo:inside(rect)
        if not isGeo(rect) then rect = geometry.new(rect) end
        local a, b = store[self], store[rect]
        return (a.x or 0) >= (b.x or 0)
           and (a.y or 0) >= (b.y or 0)
           and (a.x or 0) + (a.w or 0) <= (b.x or 0) + (b.w or 0)
           and (a.y or 0) + (a.h or 0) <= (b.y or 0) + (b.h or 0)
    end

    -- Overlap of self and rect (a new rect; zero-size if disjoint).
    function Geo:intersect(rect)
        if not isGeo(rect) then rect = geometry.new(rect) end
        local a, b = store[self], store[rect]
        local x1 = math.max(a.x or 0, b.x or 0)
        local y1 = math.max(a.y or 0, b.y or 0)
        local x2 = math.min((a.x or 0) + (a.w or 0), (b.x or 0) + (b.w or 0))
        local y2 = math.min((a.y or 0) + (a.h or 0), (b.y or 0) + (b.h or 0))
        return wrap(x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1))
    end

    -- Smallest rect containing both self and rect.
    function Geo:union(rect)
        if not isGeo(rect) then rect = geometry.new(rect) end
        local a, b = store[self], store[rect]
        local x1 = math.min(a.x or 0, b.x or 0)
        local y1 = math.min(a.y or 0, b.y or 0)
        local x2 = math.max((a.x or 0) + (a.w or 0), (b.x or 0) + (b.w or 0))
        local y2 = math.max((a.y or 0) + (a.h or 0), (b.y or 0) + (b.h or 0))
        return wrap(x1, y1, x2 - x1, y2 - y1)
    end

    -- Shrink/reposition self in place to sit inside rect, preserving aspect.
    function Geo:fit(rect)
        if not isGeo(rect) then rect = geometry.new(rect) end
        local a, b = store[self], store[rect]
        local bw, bh = b.w or 0, b.h or 0
        local scale = 1
        if (a.w or 0) > bw then scale = math.min(scale, bw / (a.w or 1)) end
        if (a.h or 0) > bh then scale = math.min(scale, bh / (a.h or 1)) end
        a.w = (a.w or 0) * scale
        a.h = (a.h or 0) * scale
        -- Clamp origin into the target rect.
        a.x = math.max(b.x or 0, math.min(a.x or 0, (b.x or 0) + bw - a.w))
        a.y = math.max(b.y or 0, math.min(a.y or 0, (b.y or 0) + bh - a.h))
        return self
    end

    -- Normalize self against frame -> unit rect (0..1). Returns a new geometry.
    function Geo:toUnitRect(frame)
        if not isGeo(frame) then frame = geometry.new(frame) end
        local a, f = store[self], store[frame]
        local fw, fh = f.w or 1, f.h or 1
        return wrap(((a.x or 0) - (f.x or 0)) / fw, ((a.y or 0) - (f.y or 0)) / fh,
                    (a.w or 0) / fw, (a.h or 0) / fh)
    end

    -- Expand a unit rect back into frame coordinates. Returns a new geometry.
    function Geo:fromUnitRect(frame)
        if not isGeo(frame) then frame = geometry.new(frame) end
        local a, f = store[self], store[frame]
        local fw, fh = f.w or 1, f.h or 1
        return wrap((f.x or 0) + (a.x or 0) * fw, (f.y or 0) + (a.y or 0) * fh,
                    (a.w or 0) * fw, (a.h or 0) * fh)
    end

    -- Plain {x,y,w,h} snapshot (nils omitted). Handy for host/FFI hand-off.
    function Geo:table()
        local r = store[self]
        return { x = r.x, y = r.y, w = r.w, h = r.h }
    end
-- END --

-- Make the module itself callable: hs.geometry(...) == hs.geometry.new(...) --
    setmetatable(geometry, { __call = function(_, ...) return geometry.new(...) end })
-- END --

return geometry
