-- Host-side model test. KOReader dependencies are replaced with minimal fakes.
local persisted = {}
local existing = {
    ["/books/a.epub"] = true,
    ["/books/b.epub"] = true,
    ["/books"] = "directory",
}

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/settings" end }
end

package.preload["luasettings"] = function()
    local M = {}
    function M:open(path)
        local object = { data = persisted[path] or {} }
        function object:flush() persisted[path] = self.data return self end
        return object
    end
    return M
end

package.preload["ffi/util"] = function()
    return { realpath = function(path) return path end }
end

package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, key)
        if existing[path] then
            local attr = { mode = existing[path] == "directory" and "directory" or "file", modification = 100 }
            return key and attr[key] or attr
        end
    end }
end

package.preload["logger"] = function()
    return { err = function() end, warn = function() end, info = function() end }
end

local Store = require("bookshelf_store")
local store = Store:new("/settings/bookshelf.lua")

local science = assert(store:createCategory("Science"))
local fiction = assert(store:createCategory("Fiction"))
assert(science.id ~= fiction.id, "category IDs must be stable and unique")

assert(store:addBook(science.id, "/books/a.epub"))
assert(store:addBook(science.id, "/books/a.epub"))
assert(#science.books == 1, "duplicate paths in one category must be collapsed")
assert(store:addBook(fiction.id, "/books/a.epub"))
assert(store:categoryIdsForBook("/books/a.epub")[science.id])
assert(store:categoryIdsForBook("/books/a.epub")[fiction.id], "one book may be in many categories")

assert(store:addBook(science.id, "/books/b.epub"))
assert(store:moveBook(science.id, "/books/b.epub", -1))
assert(science.books[1] == "/books/b.epub", "book order must be explicit")
assert(store:moveCategory(fiction.id, -1))
assert(store.data.categories[1].id == fiction.id, "category order must be explicit")

assert(store:removeBook(science.id, "/books/a.epub"))
assert(not store:hasBook(science.id, "/books/a.epub"))
assert(existing["/books/a.epub"], "removing membership must not remove the original file")

store:addBook(science.id, "/books/missing.epub")
assert(store:cleanMissing("/books") == 1, "missing records must be cleanable")
assert(existing["/books/a.epub"] and existing["/books/b.epub"], "cleanup must preserve existing books")

store:setMetadata("/books/a.epub", { mtime = 100, title = "A" })
assert(store:getMetadata("/books/a.epub", 100).title == "A")
assert(store:getMetadata("/books/a.epub", 101) == nil, "mtime changes must invalidate metadata")

assert(store:deleteCategory(fiction.id))
assert(existing["/books/a.epub"], "deleting a category must not delete a book")

store:updateSetting({ "columns_landscape" }, 6)
assert(store:getSettings().columns_landscape == 6)
print("PASS store_spec: 17 assertions")
