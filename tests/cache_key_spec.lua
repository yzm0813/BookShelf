local mtime = 100
package.preload["ffi/blitbuffer"] = function() return {} end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/data" end }
end
package.preload["ui/renderimage"] = function() return {} end
package.preload["ffi/util"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path) return path == "/books/a.epub" and { modification = mtime } or nil end,
        dir = function() return function() return nil end end,
    }
end
package.preload["logger"] = function() return { info = function() end } end
package.preload["ffi/sha2"] = function() return { md5 = function(value) return value end } end
package.preload["util"] = function() return { makePath = function() return true end } end

local Cache = require("bookshelf_covercache")
local cache = Cache:new({}, {})
local base = { w = 120, h = 180, mode = "crop", ratio = "2:3", radius = 8 }
local key = cache:key("/books/a.epub", base)

local variants = {
    { w = 121, h = 180, mode = "crop", ratio = "2:3", radius = 8 },
    { w = 120, h = 181, mode = "crop", ratio = "2:3", radius = 8 },
    { w = 120, h = 180, mode = "fit", ratio = "2:3", radius = 8 },
    { w = 120, h = 180, mode = "crop", ratio = "3:4", radius = 8 },
    { w = 120, h = 180, mode = "crop", ratio = "2:3", radius = 9 },
}
for _, spec in ipairs(variants) do assert(cache:key("/books/a.epub", spec) ~= key) end
mtime = 101
assert(cache:key("/books/a.epub", base) ~= key, "mtime must invalidate a thumbnail")
assert(cache:key("/books/b.epub", base) ~= key, "path must be part of the key")
print("PASS cache_key_spec: 7 invalidation checks")
