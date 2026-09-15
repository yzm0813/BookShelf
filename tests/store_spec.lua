-- Host-side model test. KOReader dependencies are replaced with minimal fakes.
local persisted, flush_count, write_failure = {}, 0, false
local existing = {
    ["/books/a.epub"] = true,
    ["/books/b.epub"] = true,
    ["/books/c.epub"] = true,
    ["/books/d.epub"] = true,
    ["/books"] = "directory",
}

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/settings" end }
end

package.preload["luasettings"] = function()
    local M = {}
    function M:open(path)
        local object = { data = persisted[path] or {} }
        function object:flush() persisted[path] = self.data flush_count = flush_count + 1 return self end
        return object
    end
    return M
end

package.preload["ffi/util"] = function()
    return { realpath = function(path) return path end, fsyncDirectory = function() end }
end

package.preload["dump"] = function()
    return function() return "{}" end
end

package.preload["util"] = function()
    return { writeToFile = function()
        if write_failure then return nil, "disk_full" end
        flush_count = flush_count + 1
        return true
    end }
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
os.rename = function() return true end
os.remove = function() return true end
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
store:updateSetting({ "columns_portrait" }, 2)
assert(store:getSettings().columns_portrait == 2 and store:getSettings().columns_landscape == 6,
    "portrait and landscape column settings must remain independent")
for _, scale in ipairs({ 50, 75, 100 }) do
    assert(store:updateSetting({ "cover_scale_percent" }, scale))
    assert(store:getSettings().cover_scale_percent == scale)
end
assert(store:getSettings().confirm_category_assignment == true,
    "confirmed assignment must be the safe default")
assert(store:getSettings().book_sort == "manual",
    "existing installs must retain their saved manual category order")
assert(store:getSettings().smart_shelves_enabled == false,
    "legacy settings must gain Smart Shelf in the disabled state")

local before_batch = flush_count
assert(store:applyBookCategories("/books/a.epub", { [science.id] = true }, { "New shelf" }))
assert(flush_count == before_batch + 1, "confirmed changes must flush exactly once")
assert(store:hasBook(science.id, "/books/a.epub"))
assert(#store.data.categories == 2 and store.data.categories[2].name == "New shelf")
assert(store:hasBook(store.data.categories[2].id, "/books/a.epub"),
    "staged categories must be created with the book assigned")

before_batch = flush_count
assert(store:applyBookCategories("/books/a.epub", {}, {}))
assert(flush_count == before_batch + 1)
assert(not store:hasBook(science.id, "/books/a.epub"))
assert(not store:hasBook(store.data.categories[2].id, "/books/a.epub"))

local second_shelf = store.data.categories[2]
assert(store:addBook(science.id, "/books/a.epub"))
assert(store:addBook(second_shelf.id, "/books/a.epub"))
assert(store:addBook(science.id, "/books/c.epub"))
assert(store:setCategoryCover(science.id, "/books/a.epub"))
store:setMetadata("/books/a.epub", { mtime = 100, title = "Relocated A" })
before_batch = flush_count
assert(store:relocateBook("/books/a.epub", "/books/c.epub"))
assert(flush_count == before_batch + 1, "relocation must use one atomic write")
assert(store:hasBook(science.id, "/books/c.epub") and store:hasBook(second_shelf.id, "/books/c.epub"),
    "relocation must update every category")
local c_count = 0
for _, path in ipairs(science.books) do if path == "/books/c.epub" then c_count = c_count + 1 end end
assert(c_count == 1, "relocation must not duplicate an already present destination path")
assert(science.cover_path == "/books/c.epub", "custom category cover must follow relocation")
assert(store:moveBook(science.id, "/books/c.epub", -1))
assert(science.cover_path == "/books/c.epub", "manual reordering must not discard a custom category cover")
existing["/books/c.epub"] = nil
assert(store:firstValidBook(science) == "/books/b.epub", "an unavailable custom cover must fall back safely")
existing["/books/c.epub"] = true
assert(store:getMetadata("/books/c.epub").title == "Relocated A" and not store:getMetadata("/books/a.epub"),
    "relocation must migrate cached metadata")

write_failure = true
assert(not store:relocateBook("/books/c.epub", "/books/d.epub"))
write_failure = false
science = assert(store:getCategory(science.id))
assert(store:hasBook(science.id, "/books/c.epub") and not store:hasBook(science.id, "/books/d.epub"),
    "failed relocation must roll back in-memory category data")
assert(science.cover_path == "/books/c.epub", "failed relocation must roll back the custom cover")

assert(store:removeBook(science.id, "/books/c.epub"))
science = assert(store:getCategory(science.id))
assert(science.cover_path == nil, "removing the selected cover book must restore automatic cover selection")
store:setMetadata("/books/orphan.epub", { mtime = 1, title = "Orphan" })
assert(store:gcMetadata({ "/books/b.epub", "/books/c.epub" }, false) == 0)
assert(store:getMetadata("/books/orphan.epub"), "incomplete scans must never collect metadata")
assert(store:gcMetadata({ "/books/b.epub", "/books/c.epub" }, true) == 1)
assert(not store:getMetadata("/books/orphan.epub"), "complete scans must collect unreferenced metadata")
print("PASS store_spec: categories, relocation, custom covers, rollback, and metadata GC")
