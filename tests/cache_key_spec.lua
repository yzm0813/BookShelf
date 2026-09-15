local mtime, dir_failure = 100, false
local cache_files = { "a.png", "b.png", "c.png", "d.png", "e.png" }
local blitbuffer_module, render_module = {}, {}
package.preload["ffi/blitbuffer"] = function() return blitbuffer_module end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/data" end }
end
package.preload["ui/renderimage"] = function() return render_module end
package.preload["ffi/util"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local attr
            if path == "/books/a.epub" then attr = { mode = "file", modification = mtime, size = 100 }
            elseif path:match("/cache/bookshelf/[a-e]%.png$") then attr = { mode = "file", modification = path:byte(-5), size = 100 } end
            return key and attr and attr[key] or attr
        end,
        dir = function()
            if dir_failure then error("cache unavailable") end
            local index = 0
            return function() index = index + 1 return cache_files[index] end, {}
        end,
    }
end
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["ffi/sha2"] = function() return { md5 = function(value) return value end } end
package.preload["util"] = function() return { makePath = function() return true end } end

local Cache = require("bookshelf_covercache")
local cache = Cache:new({}, {})
local base = { w = 120, h = 180, mode = "crop", ratio = "2:3", radius = 8 }
local key = cache:key("/books/a.epub", base)
assert(key:match("^3\31"), "render version must invalidate thumbnails from the old border geometry")

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

local source = { free_count = 0 }
function source:getWidth() return 600 end
function source:getHeight() return 900 end
function source:free() self.free_count = self.free_count + 1 end
render_module.scaleBlitBuffer = function() error("injected scaling failure") end
cache.ui = { bookinfo = { getCoverImage = function() return source end } }
local output = cache:generate("/books/a.epub", base)
assert(output == nil and source.free_count == 1,
    "cover buffers must be released when rendering throws")

local source2, scaled, target = { free_count = 0 }, { free_count = 0 }, { free_count = 0 }
function source2:getWidth() return 600 end
function source2:getHeight() return 900 end
function source2:free() self.free_count = self.free_count + 1 end
function scaled:getType() return 1 end
function scaled:free() self.free_count = self.free_count + 1 end
function target:fill() end
function target:blitFrom() end
function target:paintRect() end
function target:writeToFile() return false end
function target:free() self.free_count = self.free_count + 1 end
blitbuffer_module.COLOR_WHITE = 255
blitbuffer_module.new = function(w, h) target.w, target.h = w, h return target end
render_module.scaleBlitBuffer = function() return scaled end
cache.ui.bookinfo.getCoverImage = function() return source2 end
output = cache:generate("/books/a.epub", base)
assert(output == nil and source2.free_count == 1 and scaled.free_count == 1 and target.free_count == 1,
    "write failures must release source, scaled, and target buffers")

dir_failure = true
assert(cache:prune(2) == 0, "an unavailable cache directory must not crash pruning")
dir_failure = false
local remove_attempts = 0
os.remove = function()
    remove_attempts = remove_attempts + 1
    return remove_attempts ~= 1
end
assert(cache:prune(2) == 3, "one failed deletion must not stop the remaining cache pruning")
print("PASS cache_key_spec: invalidation, failure cleanup, and safe pruning")
