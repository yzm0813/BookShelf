local function dummyModule()
    return { new = function(_, value) return value or {} end }
end

for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/fontchooser",
    "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/spinwidget",
}) do
    package.preload[name] = dummyModule
end

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/settings" end,
        getDataDir = function() return "/data" end,
    }
end
package.preload["document/documentregistry"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, event) return event end }
end
local ui_manager = {}
package.preload["ui/uimanager"] = function() return ui_manager end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local container = {}
    function container:extend(class)
        class.__index = class
        return class
    end
    return container
end
local filemanagerutil = {
        splitFileNameType = function(path)
            return (path:gsub("%.[^.]+$", ""))
        end,
    }
package.preload["apps/filemanager/filemanagerutil"] = function()
    return filemanagerutil
end
local file_attrs = {
    ["/books/alpha.epub"] = { mode = "file", modification = 10 },
    ["/books/beta.epub"] = { mode = "file", modification = 30 },
    ["/books/gamma.epub"] = { mode = "file", modification = 20 },
}
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, key)
        local attr = file_attrs[path]
        if not attr then return nil end
        return key and attr[key] or attr
    end }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["bookshelf_i18n"] = function() return function(text) return text end end
package.preload["bookshelf_covercache"] = function() return {} end
package.preload["bookshelf_grid"] = function() return {} end
package.preload["bookshelf_scanner"] = function() return {} end
package.preload["bookshelf_store"] = function() return {} end

local Bookshelf = require("bookshelf_main")
local first = "/books/alpha.epub"
local second = "/books/beta.epub"
local shelf = setmetatable({
    store = {
        data = { categories = {
            { id = "one", name = "One", books = { first } },
            { id = "two", name = "Two", books = {} },
        } },
        getSettings = function() return { hide_missing = false } end,
        firstValidBook = function(_, category) return category.books[1] end,
        flush = function() end,
    },
    uncategorized = { second },
}, Bookshelf)

local entries = shelf:_rootEntries()
assert(#entries == 3, "root must contain categories plus individual uncategorized books")
assert(entries[1].kind == "category" and entries[1].category_id == "one")
assert(entries[1].book_count == 1, "category card must expose its current book count")
assert(entries[2].kind == "category" and entries[2].category_id == "two")
assert(entries[2].book_count == 0)
assert(entries[3].kind == "book" and entries[3].path == second)
for _, entry in ipairs(entries) do
    assert(entry.kind ~= "uncategorized", "uncategorized grouping card must not return")
end

local sort_settings = { hide_missing = false, book_sort = "name" }
local sort_shelf = setmetatable({
    store = { getSettings = function() return sort_settings end },
}, Bookshelf)
local sorted = sort_shelf:_bookEntries({
    "/books/gamma.epub", "/books/beta.epub", "/books/alpha.epub",
})
assert(sorted[1].path == "/books/alpha.epub" and sorted[3].path == "/books/gamma.epub",
    "name sorting must be ascending")

sort_settings.book_sort = "modification"
sorted = sort_shelf:_bookEntries({
    "/books/alpha.epub", "/books/gamma.epub", "/books/beta.epub",
})
assert(sorted[1].path == "/books/beta.epub" and sorted[3].path == "/books/alpha.epub",
    "file modification sorting must put newest first")

package.preload["readhistory"] = function()
    return { hist = {
        { file = "/books/alpha.epub", time = 200 },
        { file = "/books/beta.epub", time = 100 },
    } }
end
sort_settings.book_sort = "last_read"
sorted = sort_shelf:_bookEntries({
    "/books/gamma.epub", "/books/beta.epub", "/books/alpha.epub",
})
assert(sorted[1].path == "/books/alpha.epub" and sorted[3].path == "/books/gamma.epub",
    "last-read sorting must use KOReader history and put unread books last")

sort_settings.book_sort = "manual"
sorted = sort_shelf:_bookEntries({
    "/books/gamma.epub", "/books/alpha.epub", "/books/beta.epub",
})
assert(sorted[1].path == "/books/gamma.epub" and sorted[3].path == "/books/beta.epub",
    "manual mode must preserve stored category order")

package.preload["ui/widget/booklist"] = function()
    local info = {
        ["/books/alpha.epub"] = { been_opened = true, percent_finished = 0.5, status = "reading" },
        ["/books/beta.epub"] = { been_opened = false, percent_finished = 0 },
        ["/books/gamma.epub"] = { been_opened = true, percent_finished = 1, status = "complete" },
    }
    return { getBookInfo = function(path) return info[path] or {} end }
end
local smart_shelf = setmetatable({
    all_books = { first, second, "/books/gamma.epub" },
    store = { data = { categories = {} }, getSettings = function()
        return { hide_missing = false, book_sort = "manual", smart_shelves_enabled = true }
    end },
}, Bookshelf)
assert(smart_shelf:_smartShelfPaths("reading")[1] == first)
assert(smart_shelf:_smartShelfPaths("unread")[1] == second)
assert(smart_shelf:_smartShelfPaths("read")[1] == "/books/gamma.epub")
assert(smart_shelf:_smartShelfPaths("recent")[1] == first,
    "recent shelf must use KOReader history order")

local search_metadata = {
    [first] = { mtime = 10, title = "Being and Time", authors = "Alice" },
    [second] = { mtime = 30, title = "中文书名", authors = "张三" },
}
local search_shelf = setmetatable({
    all_books = { first, second },
    store = {
        data = { categories = { { id = "philosophy", name = "哲学", books = { first } } } },
        getSettings = function() return { hide_missing = false, book_sort = "manual" } end,
        getMetadata = function(_, path) return search_metadata[path] end,
        firstValidBook = function(_, category) return category.books[1] end,
        setMetadata = function() end, flush = function() return true end,
    },
}, Bookshelf)
local results = search_shelf:_searchEntries("ALICE")
assert(#results == 1 and results[1].path == first,
    "author search must be case-insensitive and include categorized books")
results = search_shelf:_searchEntries("中文")
assert(#results == 1 and results[1].path == second, "Chinese title search must use literal containment")
results = search_shelf:_searchEntries("哲")
assert(#results == 1 and results[1].kind == "category", "category names must be searchable")

local pending, open_count, close_count = nil, 0, 0
ui_manager.broadcastEvent = function() end
ui_manager.close = function() close_count = close_count + 1 end
ui_manager.nextTick = function(_, callback) pending = callback end
filemanagerutil.openFile = function() open_count = open_count + 1 end
local open_shelf = setmetatable({
    ui = {}, store = { getCategory = function() end },
    _info = function() end,
}, Bookshelf)
local open_grid = { context = { kind = "root" }, page = 1 }
open_shelf:onGridSelect(open_grid, { kind = "book", path = first })
open_shelf:onGridSelect(open_grid, { kind = "book", path = second })
assert(close_count == 1 and open_count == 0 and pending,
    "rapid repeated taps must schedule exactly one reader open")
pending()
assert(open_count == 1, "the selected book must open once")
open_shelf:onGridSelect(open_grid, { kind = "book", path = second })
open_shelf._stopped = true
pending()
assert(open_count == 1, "teardown must neutralize a pending reader callback")

local fallback_page
local restore_shelf = setmetatable({
    store = { getCategory = function() end, getSettings = function() return {} end },
    showRoot = function(_, page) fallback_page = page end,
}, Bookshelf)
restore_shelf:_restoreContext({ kind = "category", category_id = "deleted", page = 4 })
assert(fallback_page == 4, "a deleted return category must fall back to the bookshelf root")

local registered, unregistered, register_count = nil, nil, 0
local simpleui_actions = {}
package.preload["infra/sui_config"] = function()
    return { ALL_ACTIONS = simpleui_actions }
end
local QA = {
    register = function(desc) registered = desc register_count = register_count + 1 end,
    unregister = function(id) unregistered = id end,
}
package.loaded["features/sui_quickactions"] = QA
local bi_registered, bi_unregistered, bi_register_count = nil, nil, 0
local live_simpleui = { active_action = "home" }
package.loaded["infra/sui_core"] = {
    getLivePlugin = function() return live_simpleui end,
    BarInjection = {
        register = function(desc) bi_registered = desc bi_register_count = bi_register_count + 1 end,
        unregister = function(id) bi_unregistered = id end,
    },
}
assert(shelf:_registerSimpleUIAction())
assert(registered.id == "bookshelf_open")
assert(registered.label == "Bookshelf")
assert(registered.is_in_place == false)
assert(type(registered.execute) == "function")
assert(#simpleui_actions == 1 and simpleui_actions[1].id == "bookshelf_open",
    "external bookshelf action must appear in Simple UI's icon picker catalogue")
assert(bi_registered.id == "bookshelf_grid_nav")
assert(bi_registered.widget_name == "bookshelf_grid")
assert(bi_registered.active_action_id == "bookshelf_open")
assert(type(bi_registered.on_inject) == "function",
    "Simple UI injection must reposition the neighboring sort button")
assert(shelf:_registerSimpleUIAction())
assert(register_count == 2 and bi_register_count == 2 and #simpleui_actions == 1,
    "repeat registration must replace keyed actions without duplicating the icon catalogue")
assert(shelf:_activateSimpleUIBookshelf())
assert(live_simpleui.active_action == "bookshelf_open",
    "bookshelf must seed the active tab before its grid is injected")
shelf:stopPlugin()
assert(unregistered == "bookshelf_open", "Simple UI action must be removed on plugin stop")
assert(bi_unregistered == "bookshelf_grid_nav", "Simple UI page registration must be removed")
assert(#simpleui_actions == 0, "Simple UI icon picker catalogue entry must be removed on stop")

print("PASS main_spec: layout, sorting, search, Smart Shelf, reader guard, and Simple UI lifecycle")
