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
package.preload["ui/uimanager"] = function() return {} end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local container = {}
    function container:extend(class)
        class.__index = class
        return class
    end
    return container
end
package.preload["apps/filemanager/filemanagerutil"] = function()
    return {
        splitFileNameType = function(path)
            return (path:gsub("%.[^.]+$", ""))
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return "file" end }
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

local registered, unregistered
local simpleui_actions = {}
package.preload["infra/sui_config"] = function()
    return { ALL_ACTIONS = simpleui_actions }
end
local QA = {
    register = function(desc) registered = desc end,
    unregister = function(id) unregistered = id end,
}
package.loaded["features/sui_quickactions"] = QA
local bi_registered, bi_unregistered
local live_simpleui = { active_action = "home" }
package.loaded["infra/sui_core"] = {
    getLivePlugin = function() return live_simpleui end,
    BarInjection = {
        register = function(desc) bi_registered = desc end,
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
assert(shelf:_activateSimpleUIBookshelf())
assert(live_simpleui.active_action == "bookshelf_open",
    "bookshelf must seed the active tab before its grid is injected")
shelf:stopPlugin()
assert(unregistered == "bookshelf_open", "Simple UI action must be removed on plugin stop")
assert(bi_unregistered == "bookshelf_grid_nav", "Simple UI page registration must be removed")
assert(#simpleui_actions == 0, "Simple UI icon picker catalogue entry must be removed on stop")

print("PASS main_spec: flat root, prepaint tab activation, and Simple UI lifecycle")
