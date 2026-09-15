local tree = {
    ["/books"] = { "a.epub", "notes.txt", "novels", "locked", "a.sdr", "cache" },
    ["/books/novels"] = { "b.pdf" },
    ["/books/a.sdr"] = { "metadata.epub" },
    ["/books/cache"] = { "cached.epub" },
    ["/books/locked"] = {},
}
local directories = { ["/books"] = true, ["/books/novels"] = true,
    ["/books/a.sdr"] = true, ["/books/cache"] = true, ["/books/locked"] = true }
local fail_locked = true

package.preload["document/documentregistry"] = function()
    return { hasProvider = function(_, path) return path:match("%.epub$") or path:match("%.pdf$") end }
end
package.preload["ffi/util"] = function() return { realpath = function(path) return path end } end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local attr = directories[path] and { mode = "directory" } or nil
            return key and attr and attr[key] or attr
        end,
        symlinkattributes = function(path)
            return { mode = directories[path] and "directory" or "file" }
        end,
        dir = function(path)
            if path == "/books/locked" and fail_locked then error("storage unavailable") end
            local names, index = tree[path] or {}, 0
            return function()
                index = index + 1
                return names[index]
            end, {}
        end,
    }
end
package.preload["logger"] = function() return { warn = function() end } end

local Scanner = require("bookshelf_scanner")
local books, complete = Scanner.scan("/books")
assert(#books == 2)
assert(complete == false, "a failed nested directory must mark the scan incomplete")
assert(books[1] == "/books/a.epub")
assert(books[2] == "/books/novels/b.pdf")

local store = { data = { categories = { { books = { "/books/a.epub" } } } } }
local unclassified = Scanner.uncategorized(books, store)
assert(#unclassified == 1 and unclassified[1] == "/books/novels/b.pdf")
fail_locked = false
local _, complete_retry = Scanner.scan("/books")
assert(complete_retry == true, "a fully readable tree must permit conservative metadata cleanup")
print("PASS scanner_spec: supported recursion, exclusions, and uncategorized filter")
