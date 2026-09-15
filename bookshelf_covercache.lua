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
    local ok, attr = pcall(lfs.attributes, path)
    attr = ok and attr or {}
    return table.concat({ RENDER_VERSION, path, attr.modification or 0, spec.w, spec.h, spec.mode,
        spec.ratio, spec.radius }, "\31")
end

function CoverCache:path(path, spec)
    return self.dir .. md5(self:key(path, spec)) .. ".png"
end

function CoverCache:get(path, spec)
    local cached = self:path(path, spec)
    local ok, attr = pcall(lfs.attributes, cached)
    attr = ok and attr or nil
    if attr and attr.mode == "file" and (attr.size or 0) > 0 then return cached end
    if attr and attr.mode == "file" then pcall(os.remove, cached) end
    return nil
end

local function safeFree(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
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

    local output = self:path(path, spec)
    local temporary = output .. ".tmp"
    local scaled, target, sw, sh
    pcall(os.remove, temporary)
    local render_ok, render_err = pcall(function()
        sw, sh = source:getWidth(), source:getHeight()
        if not sw or not sh or sw <= 0 or sh <= 0 then error("invalid_cover_size") end
        local scale = spec.mode == "crop" and math.max(spec.w / sw, spec.h / sh)
            or math.min(spec.w / sw, spec.h / sh)
        local scaled_w = math.max(1, math.floor(sw * scale + 0.5))
        local scaled_h = math.max(1, math.floor(sh * scale + 0.5))
        scaled = RenderImage:scaleBlitBuffer(source, scaled_w, scaled_h, false)
        if not scaled then error("scale_failed") end
        target = Blitbuffer.new(spec.w, spec.h, scaled:getType())
        if not target then error("allocation_failed") end
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
        maskRoundedCorners(target, spec.radius)
        if not target:writeToFile(temporary, "png", 75, true) then error("write_failed") end
    end)
    safeFree(target)
    if scaled ~= source then safeFree(scaled) end
    safeFree(source)
    if not render_ok then
        pcall(os.remove, temporary)
        logger.warn("Bookshelf: cover generation failed:", path, render_err)
        return nil, tostring(render_err)
    end

    local attr_ok, attr = pcall(lfs.attributes, temporary)
    attr = attr_ok and attr or nil
    if not attr or attr.mode ~= "file" or (attr.size or 0) <= 0 then
        pcall(os.remove, temporary)
        return nil, "invalid_cache_file"
    end
    local rename_ok, renamed, rename_err = pcall(os.rename, temporary, output)
    if not rename_ok or not renamed then
        pcall(os.remove, temporary)
        logger.warn("Bookshelf: cache replace failed:", rename_err or renamed)
        return nil, rename_err or "cache_replace_failed"
    end
    return output, nil, sw / sh
end

function CoverCache:clear()
    local count = 0
    local ok, iterator, state = pcall(lfs.dir, self.dir)
    if not ok or not iterator then return count end
    local iterated, err = pcall(function()
        for name in iterator, state do
            if name:match("^[0-9a-f]+%.png$") then
                local remove_ok, removed = pcall(os.remove, self.dir .. name)
                if remove_ok and removed then count = count + 1 end
            end
        end
    end)
    if not iterated then logger.warn("Bookshelf: thumbnail cache clear interrupted:", err) end
    return count
end

function CoverCache:prune(max_files)
    max_files = max_files or 400
    local files = {}
    local ok, iterator, state = pcall(lfs.dir, self.dir)
    if not ok or not iterator then
        logger.warn("Bookshelf: thumbnail cache is unavailable:", self.dir)
        return 0, "cache_unavailable"
    end
    local iterated, err = pcall(function()
        for name in iterator, state do
            if name:match("^[0-9a-f]+%.png$") then
                local path = self.dir .. name
                local attr_ok, mtime = pcall(lfs.attributes, path, "modification")
                files[#files + 1] = { path = path, mtime = attr_ok and mtime or 0 }
            end
        end
    end)
    if not iterated then
        logger.warn("Bookshelf: thumbnail cache scan interrupted:", err)
        return 0, "cache_scan_failed"
    end
    if #files <= max_files then return 0 end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    local remove_count = #files - math.floor(max_files * 0.8)
    local removed = 0
    for i = 1, remove_count do
        local remove_ok, result = pcall(os.remove, files[i].path)
        if remove_ok and result then removed = removed + 1 end
    end
    logger.info("Bookshelf: pruned", removed, "thumbnail files")
    return removed
end

return CoverCache
