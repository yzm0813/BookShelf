local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")

local CoverCache = {}
CoverCache.__index = CoverCache
local RENDER_VERSION = 3

function CoverCache:new(ui, store)
    local o = setmetatable({}, self)
    o.ui, o.store = ui, store
    o.dir = DataStorage:getDataDir() .. "/cache/bookshelf/"
    util.makePath(o.dir)
    return o
end

function CoverCache:key(path, spec)
    local attr = lfs.attributes(path) or {}
    return table.concat({ RENDER_VERSION, path, attr.modification or 0, spec.w, spec.h, spec.mode,
        spec.ratio, spec.radius }, "\31")
end

function CoverCache:path(path, spec)
    return self.dir .. md5(self:key(path, spec)) .. ".png"
end

function CoverCache:get(path, spec)
    local cached = self:path(path, spec)
    return lfs.attributes(cached, "mode") == "file" and cached or nil
end

local function maskRoundedCorners(bb, radius)
    radius = math.min(radius or 0, math.floor(math.min(bb.w, bb.h) / 2))
    if radius <= 0 then return end
    for y = 0, radius - 1 do
        local dy = radius - y - 0.5
        local cut = math.max(0, math.ceil(radius - math.sqrt(radius * radius - dy * dy)))
        if cut > 0 then
            bb:paintRect(0, y, cut, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(bb.w - cut, y, cut, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(0, bb.h - y - 1, cut, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(bb.w - cut, bb.h - y - 1, cut, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

function CoverCache:generate(path, spec)
    local bookinfo = self.ui and self.ui.bookinfo
    if not bookinfo or type(bookinfo.getCoverImage) ~= "function" then return nil, "no_bookinfo" end
    local ok, source = pcall(bookinfo.getCoverImage, bookinfo, nil, path)
    if not ok or not source then return nil, "no_cover" end

    local sw, sh = source:getWidth(), source:getHeight()
    local scale = spec.mode == "crop" and math.max(spec.w / sw, spec.h / sh)
        or math.min(spec.w / sw, spec.h / sh)
    local scaled_w = math.max(1, math.floor(sw * scale + 0.5))
    local scaled_h = math.max(1, math.floor(sh * scale + 0.5))
    local scaled = RenderImage:scaleBlitBuffer(source, scaled_w, scaled_h, true)
    local target = Blitbuffer.new(spec.w, spec.h, scaled:getType())
    target:fill(Blitbuffer.COLOR_WHITE)

    if spec.mode == "crop" then
        local sx = math.max(0, math.floor((scaled_w - spec.w) / 2))
        local sy = math.max(0, math.floor((scaled_h - spec.h) / 2))
        target:blitFrom(scaled, 0, 0, sx, sy, spec.w, spec.h)
    else
        local dx = math.floor((spec.w - scaled_w) / 2)
        local dy = math.floor((spec.h - scaled_h) / 2)
        target:blitFrom(scaled, dx, dy, 0, 0, scaled_w, scaled_h)
    end
    scaled:free()
    maskRoundedCorners(target, spec.radius)

    local output = self:path(path, spec)
    local written = target:writeToFile(output, "png", 75, true)
    target:free()
    if not written then return nil, "write_failed" end
    return output, nil, sw / sh
end

function CoverCache:clear()
    local count = 0
    local ok, iterator, state = pcall(lfs.dir, self.dir)
    if not ok then return count end
    for name in iterator, state do
        if name:match("^[0-9a-f]+%.png$") and os.remove(self.dir .. name) then count = count + 1 end
    end
    return count
end

function CoverCache:prune(max_files)
    max_files = max_files or 400
    local files = {}
    for name in lfs.dir(self.dir) do
        if name:match("%.png$") then
            local path = self.dir .. name
            files[#files + 1] = { path = path, mtime = lfs.attributes(path, "modification") or 0 }
        end
    end
    if #files <= max_files then return 0 end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    local remove_count = #files - math.floor(max_files * 0.8)
    for i = 1, remove_count do os.remove(files[i].path) end
    logger.info("Bookshelf: pruned", remove_count, "thumbnail files")
    return remove_count
end

return CoverCache
