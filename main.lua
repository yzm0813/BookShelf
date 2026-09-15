local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local FontChooser = require("ui/widget/fontchooser")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("bookshelf_i18n")

local CoverCache = require("bookshelf_covercache")
local Grid = require("bookshelf_grid")
local Scanner = require("bookshelf_scanner")
local Store = require("bookshelf_store")

local SIMPLEUI_ACTION_ID = "bookshelf_open"
local SIMPLEUI_BAR_INJECTION_ID = "bookshelf_grid_nav"
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_dir = source_path:match("^(.*)[/\\]main%.lua$")
    or (DataStorage:getDataDir() .. "/plugins/bookshelf.koplugin")
local SIMPLEUI_ICON = plugin_dir .. "/icons/bookshelf.svg"

local Bookshelf = WidgetContainer:extend{
    name = "bookshelf",
    is_doc_only = false,
}

local function basename(path)
    local name = path and path:match("([^/]+)$") or ""
    return filemanagerutil.splitFileNameType(name)
end

function Bookshelf:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/bookshelf.lua"
    self.store = Store:new(self.settings_file)
    self.cache = CoverCache:new(self.ui, self.store)
    if self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        self.ui.menu:registerToMainMenu(self)
    end
    if not self.ui.document then
        self:_registerFileDialogButton()
        self:_scheduleSimpleUIRegistration()
        local return_context = UIManager._bookshelf_reader_return
        if return_context then UIManager._bookshelf_reader_return = nil end
        if return_context and type(self.ui.registerPostInitCallback) == "function" then
            self.ui:registerPostInitCallback(function()
                -- Run on the first UI tick, before FileManager's pending paint
                -- is flushed. Delaying this made the native Library visible for
                -- one e-ink refresh before the bookshelf replaced it.
                UIManager:scheduleIn(0, function()
                    if self._stopped then return end
                    local category = return_context.category_id
                        and self.store:getCategory(return_context.category_id)
                    if category then self:showCategory(category.id, return_context.page)
                    elseif return_context.smart_id then self:showSmartShelf(return_context.smart_id, return_context.page)
                    else self:showRoot(return_context.page) end
                end)
            end)
        elseif self.store:getSettings().startup_open and type(self.ui.registerPostInitCallback) == "function" then
            self.ui:registerPostInitCallback(function()
                UIManager:scheduleIn(0.2, function()
                    if self._stopped then return end
                    local ok, err = pcall(self.showRoot, self)
                    if not ok then logger.err("Bookshelf: startup open failed; keeping FileManager:", err) end
                end)
            end)
        end
    end
end

function Bookshelf:_registerSimpleUIAction()
    local QA = package.loaded["features/sui_quickactions"]
    if not QA then
        local ok, module = pcall(require, "features/sui_quickactions")
        if ok then QA = module end
    end
    if not QA or type(QA.register) ~= "function" then return false end
    QA.register{
        id = SIMPLEUI_ACTION_ID,
        label = _("Bookshelf"),
        icon = SIMPLEUI_ICON,
        is_in_place = false,
        execute = function()
            local FileManager = package.loaded["apps/filemanager/filemanager"]
            local live_fm = FileManager and FileManager.instance
            local plugin = live_fm and live_fm.bookshelf or self
            if not plugin or plugin._stopped then return end
            plugin:showRoot()
        end,
    }
    self:_exposeSimpleUIIconPicker()
    self._simpleui_qa = QA
    local Core = package.loaded["infra/sui_core"]
    if not Core then
        local ok, module = pcall(require, "infra/sui_core")
        if ok then Core = module end
    end
    if Core and Core.BarInjection and type(Core.BarInjection.register) == "function" then
        Core.BarInjection.register{
            id = SIMPLEUI_BAR_INJECTION_ID,
            widget_name = "bookshelf_grid",
            active_action_id = SIMPLEUI_ACTION_ID,
            is_pageable = true,
            on_inject = function(widget)
                if widget and type(widget.positionSortButton) == "function" then
                    widget:positionSortButton()
                end
            end,
        }
        self._simpleui_core = Core
    end
    logger.info("Bookshelf: registered Simple UI bottom-bar candidate", SIMPLEUI_ACTION_ID)
    return true
end

-- Simple UI 2026.07.1 keeps external actions in QA's runtime registry, but
-- its icon settings page still builds the editable action list from
-- Config.ALL_ACTIONS. Add only a runtime catalogue entry (never a setting or
-- source-file change), and remove that exact entry when Bookshelf stops.
function Bookshelf:_exposeSimpleUIIconPicker()
    local ok, Config = pcall(require, "infra/sui_config")
    if not ok or type(Config) ~= "table" or type(Config.ALL_ACTIONS) ~= "table" then
        return false
    end
    for _, action in ipairs(Config.ALL_ACTIONS) do
        if action.id == SIMPLEUI_ACTION_ID then return true end
    end
    local entry = {
        id = SIMPLEUI_ACTION_ID,
        label = _("Bookshelf"),
        icon = SIMPLEUI_ICON,
    }
    table.insert(Config.ALL_ACTIONS, entry)
    self._simpleui_icon_catalogue = self._simpleui_icon_catalogue or {}
    self._simpleui_icon_catalogue[#self._simpleui_icon_catalogue + 1] = {
        actions = Config.ALL_ACTIONS,
        entry = entry,
    }
    logger.info("Bookshelf: exposed action in Simple UI icon picker", SIMPLEUI_ACTION_ID)
    return true
end

function Bookshelf:_removeSimpleUIIconPickerEntries()
    for _, registration in ipairs(self._simpleui_icon_catalogue or {}) do
        for i = #registration.actions, 1, -1 do
            if registration.actions[i] == registration.entry then
                table.remove(registration.actions, i)
            end
        end
    end
    self._simpleui_icon_catalogue = nil
end

function Bookshelf:_scheduleSimpleUIRegistration()
    local function register()
        if self._stopped or self:_registerSimpleUIAction() then return end
        -- Simple UI may be initialized after Bookshelf. Retry once after all
        -- plugin init callbacks without requiring or modifying Simple UI.
        UIManager:scheduleIn(1, function()
            if not self._stopped then self:_registerSimpleUIAction() end
        end)
    end
    -- Register immediately when Simple UI is enabled so a previously selected
    -- bookshelf tab survives Simple UI's startup tab sanitization.
    if self:_registerSimpleUIAction() then return end
    if type(self.ui.registerPostInitCallback) == "function" then
        self.ui:registerPostInitCallback(register)
    else
        UIManager:nextTick(register)
    end
end

function Bookshelf:_info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
end

-- BarInjection determines the bar shown on a new widget from Simple UI's
-- active_action *before* it runs the descriptor's post-injection activation.
-- Seed that public live-plugin state first so the bookshelf widget itself is
-- born with the Bookshelf tab selected instead of briefly inheriting Library.
function Bookshelf:_activateSimpleUIBookshelf()
    local Core = self._simpleui_core or package.loaded["infra/sui_core"]
    if not (Core and type(Core.getLivePlugin) == "function") then return false end
    local ok, plugin = pcall(Core.getLivePlugin)
    if not ok or not plugin then return false end
    plugin.active_action = SIMPLEUI_ACTION_ID
    return true
end

function Bookshelf:_closeFileDialog()
    local chooser = self.ui and self.ui.file_chooser
    if chooser and chooser.file_dialog then
        UIManager:close(chooser.file_dialog)
        chooser.file_dialog = nil
    end
end

function Bookshelf:_registerFileDialogButton()
    if type(self.ui.addFileDialogButtons) ~= "function" then
        logger.warn("Bookshelf: FileManager.addFileDialogButtons is unavailable")
        return
    end
    self.ui:addFileDialogButtons("bookshelf_add_to_shelf", function(file, is_file)
        local ok, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, file)
        if not is_file or not ok or not supported then return nil end
        return {{
            text = _("Add to bookshelf"),
            callback = function()
                self:_closeFileDialog()
                self:showCategoryPicker(file)
            end,
        }}
    end)
    self._file_button_registered = true
end

function Bookshelf:_scan()
    local root = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()
    self.all_books, self._scan_complete = Scanner.scan(root)
    self.uncategorized = Scanner.uncategorized(self.all_books, self.store)
    local removed, err = self.store:gcMetadata(self.all_books, self._scan_complete)
    if not removed and err then logger.warn("Bookshelf: metadata cleanup skipped:", err) end
end

function Bookshelf:_allKnownBookPaths()
    local result, seen = {}, {}
    local function add(path)
        if type(path) == "string" and not seen[path] then
            seen[path] = true
            result[#result + 1] = path
        end
    end
    for _, path in ipairs(self.all_books or {}) do add(path) end
    for _, category in ipairs(self.store.data.categories) do
        for _, path in ipairs(category.books) do add(path) end
    end
    return result
end

function Bookshelf:_smartShelfGroups()
    local paths = self:_allKnownBookPaths()
    local groups = { recent = {}, reading = {}, unread = {}, read = {} }
    local ok_booklist, BookList = pcall(require, "ui/widget/booklist")
    if not ok_booklist then return groups end
    do
        local known, result = {}, {}
        for _, path in ipairs(paths) do known[path] = true end
        local ok_history, history = pcall(require, "readhistory")
        if ok_history and history and type(history.hist) == "table" then
            for _, item in ipairs(history.hist) do
                if known[item.file] and lfs.attributes(item.file, "mode") == "file" then
                    result[#result + 1] = item.file
                    known[item.file] = nil
                end
            end
        end
        groups.recent = result
    end
    for _, path in ipairs(paths) do
        if lfs.attributes(path, "mode") == "file" then
            local ok, info = pcall(BookList.getBookInfo, path)
            info = ok and info or {}
            local percent = tonumber(info.percent_finished) or 0
            local complete = info.status == "complete" or percent >= 1
            if info.been_opened and percent > 0 and not complete then
                groups.reading[#groups.reading + 1] = path
            elseif complete then
                groups.read[#groups.read + 1] = path
            elseif not info.been_opened or percent <= 0 then
                groups.unread[#groups.unread + 1] = path
            end
        end
    end
    return groups
end

function Bookshelf:_smartShelfPaths(smart_id)
    return self:_smartShelfGroups()[smart_id] or {}
end

function Bookshelf:_smartShelfEntries()
    if not self.store:getSettings().smart_shelves_enabled then return {} end
    local definitions = {
        { "recent", _("Recently read") },
        { "reading", _("Reading") },
        { "unread", _("Unread") },
        { "read", _("Read") },
    }
    local entries = {}
    local groups = self:_smartShelfGroups()
    for _, definition in ipairs(definitions) do
        local paths = groups[definition[1]]
        entries[#entries + 1] = {
            kind = "smart_category",
            smart_id = definition[1],
            name = definition[2],
            path = paths[1],
            book_count = #paths,
        }
    end
    return entries
end

function Bookshelf:_rootEntries()
    local entries = self:_smartShelfEntries()
    for _, category in ipairs(self.store.data.categories) do
        entries[#entries + 1] = {
            kind = "category",
            category_id = category.id,
            name = category.name,
            path = self.store:firstValidBook(category),
            book_count = #category.books,
        }
    end
    for _, entry in ipairs(self:_bookEntries(self.uncategorized)) do
        entries[#entries + 1] = entry
    end
    return entries
end

function Bookshelf:_bookEntries(paths, category_id, sort_override)
    local entries = {}
    local sort_mode = sort_override or self.store:getSettings().book_sort or "manual"
    local last_read = {}
    if sort_mode == "last_read" then
        local ok, history = pcall(require, "readhistory")
        if ok and history and type(history.hist) == "table" then
            for _, item in ipairs(history.hist) do
                if type(item.file) == "string" then
                    last_read[item.file] = tonumber(item.time) or 0
                end
            end
        end
    end
    for _, path in ipairs(paths) do
        local attr = lfs.attributes(path) or {}
        local exists = attr.mode == "file"
        if exists or not self.store:getSettings().hide_missing then
            entries[#entries + 1] = {
                kind = "book",
                path = path,
                name = basename(path),
                category_id = category_id,
                missing = not exists,
                sort_modification = tonumber(attr.modification) or 0,
                sort_last_read = last_read[path] or 0,
            }
        end
    end
    if sort_mode ~= "manual" then
        table.sort(entries, function(a, b)
            if sort_mode == "modification" and a.sort_modification ~= b.sort_modification then
                return a.sort_modification > b.sort_modification
            elseif sort_mode == "last_read" and a.sort_last_read ~= b.sort_last_read then
                return a.sort_last_read > b.sort_last_read
            end
            local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
            if an ~= bn then return an < bn end
            return (a.path or "") < (b.path or "")
        end)
    end
    return entries
end

function Bookshelf:_showGrid(title, entries, context, return_to_root, initial_page)
    self:_activateSimpleUIBookshelf()
    if self.active_grid and not self.active_grid._closed then
        self:_closeGrid(self.active_grid, true, true)
    end
    local grid
    local function return_to_parent()
        if not grid or grid._bookshelf_returning then return true end
        grid._bookshelf_returning = true
        self:_closeGrid(grid, true, true)
        self:_restoreContext(context.return_context or { kind = "root" })
        return true
    end
    grid = Grid:new{
        title = title,
        item_table = entries,
        plugin = self,
        store = self.store,
        cache = self.cache,
        context = context,
        page = math.max(1, tonumber(initial_page) or 1),
        onReturn = return_to_root and return_to_parent or nil,
        close_callback = return_to_root and function()
            if not grid._skip_return and not self._stopped then
                self:_restoreContext(context.return_context or { kind = "root" })
            end
        end or nil,
    }
    self.active_grid = grid
    UIManager:show(grid)
    return grid
end

function Bookshelf:_restoreContext(context)
    context = context or { kind = "root" }
    if context.kind == "category" and self.store:getCategory(context.category_id) then
        return self:showCategory(context.category_id, context.page)
    elseif context.kind == "smart" and self.store:getSettings().smart_shelves_enabled then
        return self:showSmartShelf(context.smart_id, context.page)
    end
    return self:showRoot(context.page)
end

function Bookshelf:showRoot(page)
    self:_scan()
    return self:_showGrid(_("Bookshelf"), self:_rootEntries(), { kind = "root" }, false, page)
end

function Bookshelf:showCategory(category_id, page)
    local category = self.store:getCategory(category_id)
    if not category then return self:showRoot() end
    return self:_showGrid(category.name, self:_bookEntries(category.books, category.id),
        { kind = "category", category_id = category.id }, true, page)
end

function Bookshelf:showSmartShelf(smart_id, page)
    self:_scan()
    local names = {
        recent = _("Recently read"), reading = _("Reading"),
        unread = _("Unread"), read = _("Read"),
    }
    if not names[smart_id] then return self:showRoot() end
    local sort_override = smart_id == "recent" and "manual" or nil
    return self:_showGrid(names[smart_id], self:_bookEntries(self:_smartShelfPaths(smart_id), nil, sort_override),
        { kind = "smart", smart_id = smart_id }, true, page)
end

function Bookshelf:_closeGrid(grid, skip_return, keep_nav)
    if grid then grid._skip_return = skip_return end
    if grid and keep_nav then grid._navbar_closing_intentionally = true end
    if grid then UIManager:close(grid) end
end

function Bookshelf:onGridSelect(grid, entry)
    if entry.kind == "category" then
        self:_closeGrid(grid, true, true)
        self:showCategory(entry.category_id)
    elseif entry.kind == "smart_category" then
        self:_closeGrid(grid, true, true)
        self:showSmartShelf(entry.smart_id)
    elseif entry.kind == "book" then
        if self._opening_book then return end
        if lfs.attributes(entry.path, "mode") ~= "file" then
            self:_info(_("This book file is unavailable. Its bookshelf record was not deleted."))
            return
        end

        -- KOReader expects custom full-screen menus to prepare the current UI
        -- before they close and hand control to ReaderUI. In particular,
        -- Simple UI listens for SetupShowReader and tears down its screen state
        -- in the right order. Opening synchronously from the tap handler can
        -- otherwise race the menu close/refresh path.
        local book_path = entry.path
        self._opening_book = true
        local return_context = {
            category_id = grid.context.kind == "category" and grid.context.category_id or nil,
            smart_id = grid.context.kind == "smart" and grid.context.smart_id or nil,
            page = grid.page or 1,
        }
        UIManager._bookshelf_reader_return = return_context
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        self:_closeGrid(grid, true, true)
        UIManager:nextTick(function()
            if self._stopped then
                self._opening_book = nil
                if UIManager._bookshelf_reader_return == return_context then
                    UIManager._bookshelf_reader_return = nil
                end
                return
            end
            local ok, err = pcall(filemanagerutil.openFile, self.ui, book_path, nil, true)
            self._opening_book = nil
            if not ok then
                if UIManager._bookshelf_reader_return == return_context then
                    UIManager._bookshelf_reader_return = nil
                end
                -- SetupShowReader only marks FileManager as tearing down. If
                -- opening fails before ShowingReader closes it, make the
                -- existing FileManager usable again and report the error.
                if self.ui then self.ui.tearing_down = nil end
                logger.err("Bookshelf: failed to open original book:", book_path, err)
                self:_info(_("Unable to open the original book file."))
                local category = return_context.category_id
                    and self.store:getCategory(return_context.category_id)
                if category then self:showCategory(category.id, return_context.page)
                elseif return_context.smart_id then self:showSmartShelf(return_context.smart_id, return_context.page)
                else self:showRoot(return_context.page) end
            end
        end)
    end
end

function Bookshelf:onGridAction(grid)
    if grid.context.kind == "root" then
        self:promptCreateCategory(function() self:_refreshRoot(grid) end)
    elseif grid.context.kind == "category" then
        local category = self.store:getCategory(grid.context.category_id)
        if category then self:showCategoryActions(grid, category) end
    elseif grid.context.kind ~= "smart" then
        self:_info(_("Long-press a book to add it to a category."))
    end
end

function Bookshelf:showSortDialog(grid)
    local dialog
    local choices = {
        { _("Manual order"), "manual" },
        { _("Name"), "name" },
        { _("File modification time (newest first)"), "modification" },
        { _("Last read time (newest first)"), "last_read" },
    }
    local buttons = {}
    local current = self.store:getSettings().book_sort or "manual"
    for _, choice in ipairs(choices) do
        local label, value = choice[1], choice[2]
        buttons[#buttons + 1] = {{
            text = (current == value and "✓ " or "") .. label,
            callback = function()
                UIManager:close(dialog)
                if current == value then return end
                self.store:updateSetting({ "book_sort" }, value)
                grid.page = 1
                self:_refreshBookGrid(grid)
            end,
        }}
    end
    dialog = ButtonDialog:new{
        title = _("Sort books"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Bookshelf:onGridHold(grid, entry)
    if entry.kind == "category" then
        local category = self.store:getCategory(entry.category_id)
        if category then self:showCategoryActions(grid, category) end
    elseif entry.kind == "book" then
        self:showBookActions(grid, entry)
    end
end

function Bookshelf:_refreshRoot(grid)
    self:_scan()
    grid.item_table = self:_rootEntries()
    grid.page = 1
    grid:updateItems(1, false)
end

function Bookshelf:_refreshBookGrid(grid)
    if grid.context.kind == "root" then
        return self:_refreshRoot(grid)
    elseif grid.context.kind == "category" then
        local category = self.store:getCategory(grid.context.category_id)
        grid.item_table = self:_bookEntries(category and category.books or {}, grid.context.category_id)
    elseif grid.context.kind == "smart" then
        local sort_override = grid.context.smart_id == "recent" and "manual" or nil
        grid.item_table = self:_bookEntries(self:_smartShelfPaths(grid.context.smart_id), nil, sort_override)
    elseif grid.context.kind == "search" then
        grid.item_table = self:_searchEntries(grid.context.query)
    else
        self:_scan()
        grid.item_table = self:_bookEntries(self.uncategorized)
    end
    grid:updateItems(1, false)
end

function Bookshelf:promptCreateCategory(done)
    local dialog
    dialog = InputDialog:new{
        title = _("Create category"),
        input_hint = _("Category name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Create"), is_enter_default = true, callback = function()
                local category = self.store:createCategory(dialog:getInputText())
                if not category then self:_info(_("Category name cannot be empty.")) return end
                UIManager:close(dialog)
                if done then done(category) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bookshelf:promptStagedCategory(done)
    local dialog
    dialog = InputDialog:new{
        title = _("Create category"),
        input_hint = _("Category name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Create"), is_enter_default = true, callback = function()
                local name = tostring(dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                if name == "" then self:_info(_("Category name cannot be empty.")) return end
                UIManager:close(dialog)
                done(name)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bookshelf:promptRenameCategory(grid, category)
    local dialog
    dialog = InputDialog:new{
        title = _("Rename category"),
        input = category.name,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                if not self.store:renameCategory(category.id, dialog:getInputText()) then
                    self:_info(_("Category name cannot be empty.")) return
                end
                UIManager:close(dialog)
                grid.title = category.name
                if grid.title_bar then grid.title_bar:setTitle(category.name) end
                if grid.context.kind == "root" then self:_refreshRoot(grid) else grid:updateItems(1, false) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bookshelf:showCategoryActions(grid, category)
    local function refresh_after_move()
        if grid.context.kind == "root" then self:_refreshRoot(grid)
        else grid:updateItems(1, false) end
    end
    local dialog
    dialog = ButtonDialog:new{
        title = category.name,
        buttons = {
            {
                { text = _("Rename"), callback = function() UIManager:close(dialog) self:promptRenameCategory(grid, category) end },
                { text = _("Delete category"), callback = function()
                    UIManager:close(dialog)
                    local confirm
                    confirm = ConfirmBox:new{
                        text = _("Delete this category record? Original book files will not be deleted."),
                        ok_text = _("Delete category"),
                        ok_callback = function()
                            self.store:deleteCategory(category.id)
                            if grid.context.kind == "root" then self:_refreshRoot(grid)
                            else self:_closeGrid(grid, true, true) self:showRoot() end
                        end,
                    }
                    UIManager:show(confirm)
                end },
            },
            {
                { text = _("Move earlier"), callback = function() UIManager:close(dialog) self.store:moveCategory(category.id, -1) refresh_after_move() end },
                { text = _("Move later"), callback = function() UIManager:close(dialog) self.store:moveCategory(category.id, 1) refresh_after_move() end },
            },
            { { text = _("Set category cover"), callback = function()
                UIManager:close(dialog)
                self:showCategoryCoverPicker(grid, category)
            end } },
            { { text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:showBookActions(grid, entry)
    local dialog
    local in_category = grid.context.kind == "category"
    dialog = ButtonDialog:new{
        title = entry.name,
        buttons = {
            {
                { text = _("Add to categories"), enabled = not entry.missing, callback = function()
                    UIManager:close(dialog) self:showCategoryPicker(entry.path, function() self:_refreshBookGrid(grid) end)
                end },
                { text = _("Remove from this category"), enabled = in_category, callback = function()
                    UIManager:close(dialog)
                    self.store:removeBook(grid.context.category_id, entry.path)
                    self:_refreshBookGrid(grid)
                end },
            },
            {
                { text = _("Move earlier"), enabled = in_category, callback = function()
                    UIManager:close(dialog) self.store:moveBook(grid.context.category_id, entry.path, -1) self:_refreshBookGrid(grid)
                end },
                { text = _("Move later"), enabled = in_category, callback = function()
                    UIManager:close(dialog) self.store:moveBook(grid.context.category_id, entry.path, 1) self:_refreshBookGrid(grid)
                end },
            },
            { { text = _("Relocate book"), enabled = entry.missing, callback = function()
                UIManager:close(dialog)
                self:showRelocateBook(grid, entry.path)
            end } },
            { { text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:showCategoryCoverPicker(grid, category)
    local ok_menu, Menu = pcall(require, "ui/widget/menu")
    if not ok_menu then self:_info(_("Category cover picker is unavailable.")) return end
    local picker
    local items = {{
        text = (not category.cover_path and "✓ " or "") .. _("Use first available book"),
        callback = function()
            UIManager:close(picker)
            local saved = self.store:setCategoryCover(category.id, nil)
            if not saved then self:_info(_("Unable to save category cover.")) return end
            if grid.context.kind == "root" then self:_refreshRoot(grid) else grid:updateItems(1, false) end
        end,
    }}
    for _, path in ipairs(category.books) do
        if lfs.attributes(path, "mode") == "file" then
            local cover_path, book_name = path, basename(path)
            items[#items + 1] = {
                text = (category.cover_path == cover_path and "✓ " or "") .. book_name,
                callback = function()
                    UIManager:close(picker)
                    local ok = self.store:setCategoryCover(category.id, cover_path)
                    if not ok then self:_info(_("Unable to save category cover.")) return end
                    if grid.context.kind == "root" then self:_refreshRoot(grid) else grid:updateItems(1, false) end
                end,
            }
        end
    end
    picker = Menu:new{ title = _("Set category cover"), item_table = items }
    UIManager:show(picker)
end

function Bookshelf:showRelocateBook(grid, old_path)
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    local ok_ffi, ffiUtil = pcall(require, "ffi/util")
    if not ok or not ok_ffi then self:_info(_("File chooser is unavailable.")) return end
    local start_path = ffiUtil.dirname(old_path)
    if lfs.attributes(start_path, "mode") ~= "directory" then
        start_path = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()
    end
    local chooser
    chooser = PathChooser:new{
        title = _("Long-press the relocated book file"),
        path = start_path,
        select_directory = false,
        select_file = true,
        show_files = true,
        file_filter = function(filename)
            local supported_ok, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, filename)
            return supported_ok and supported
        end,
        onConfirm = function(new_path)
            -- PathChooser closes itself after onConfirm returns. Show the
            -- replacement confirmation on the next tick so its saved underlay
            -- cannot repaint over the confirmation on an e-ink screen.
            UIManager:nextTick(function()
                if self._stopped then return end
                if lfs.attributes(new_path, "mode") ~= "file" then
                    self:_info(_("The selected book file is unavailable."))
                    return
                end
                local supported_ok, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, new_path)
                if not supported_ok or not supported then
                    self:_info(_("The selected file is not a supported book."))
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text = _("Replace this missing path in every category? Original book files will not be moved or deleted."),
                    ok_text = _("Relocate"),
                    ok_callback = function()
                        if self._stopped then return end
                        local relocated, err = self.store:relocateBook(old_path, new_path)
                        if not relocated then
                            logger.warn("Bookshelf: relocate failed:", err)
                            self:_info(_("Unable to update the bookshelf path."))
                            return
                        end
                        self:_scan()
                        local target_grid = grid and not grid._closed and grid or self.active_grid
                        if target_grid and not target_grid._closed then self:_refreshBookGrid(target_grid) end
                    end,
                })
            end)
        end,
    }
    UIManager:show(chooser)
end

local function searchableText(value)
    if type(value) == "table" then value = table.concat(value, " ") end
    return string.lower(tostring(value or ""))
end

function Bookshelf:_searchCategoryEntries(query)
    local entries = {}
    for _, category in ipairs(self.store.data.categories) do
        if searchableText(category.name):find(query, 1, true) then
            entries[#entries + 1] = {
                kind = "category", category_id = category.id, name = category.name,
                path = self.store:firstValidBook(category), book_count = #category.books,
            }
        end
    end
    return entries
end

function Bookshelf:_bookMatchesSearch(entry, query)
    local attr = lfs.attributes(entry.path) or {}
    local metadata = self.store:getMetadata(entry.path, attr.modification)
    local metadata_changed = false
    if not metadata and attr.mode == "file" then
        local bookinfo = self.ui and self.ui.bookinfo
        if bookinfo and type(bookinfo.getDocProps) == "function" then
            local props_ok, props = pcall(bookinfo.getDocProps, bookinfo, entry.path)
            if props_ok and props then
                metadata = {
                    mtime = attr.modification,
                    title = props.display_title or props.title or entry.name,
                    authors = props.authors,
                }
                self.store:setMetadata(entry.path, metadata)
                metadata_changed = true
            end
        end
    end
    metadata = metadata or {}
    local haystack = table.concat({
        searchableText(entry.name), searchableText(metadata.title), searchableText(metadata.authors),
    }, "\n")
    return haystack:find(query, 1, true) ~= nil, metadata_changed
end

function Bookshelf:_searchEntries(query)
    query = searchableText(query)
    local entries = self:_searchCategoryEntries(query)
    local metadata_changed = false
    for _, entry in ipairs(self:_bookEntries(self:_allKnownBookPaths())) do
        local matches, changed = self:_bookMatchesSearch(entry, query)
        if matches then entries[#entries + 1] = entry end
        metadata_changed = metadata_changed or changed
    end
    if metadata_changed then self.store:flush() end
    return entries
end

function Bookshelf:_startSearch(query, return_context, grid)
    local display_query = query
    query = searchableText(query)
    local results = self:_searchCategoryEntries(query)
    local books = self:_bookEntries(self:_allKnownBookPaths())
    local index, metadata_changed = 1, false
    local message = InfoMessage:new{ text = _("Searching bookshelf…") }
    self._search_message = message
    UIManager:show(message)
    self._search_action = function()
        if self._stopped then return end
        local last = math.min(#books, index + 2)
        while index <= last do
            local entry = books[index]
            local matches, changed = self:_bookMatchesSearch(entry, query)
            if matches then results[#results + 1] = entry end
            metadata_changed = metadata_changed or changed
            index = index + 1
        end
        if index <= #books then
            UIManager:scheduleIn(0.01, self._search_action)
            return
        end
        self._search_action = nil
        if metadata_changed then self.store:flush() end
        if self._search_message then UIManager:close(self._search_message) self._search_message = nil end
        if grid and not grid._closed then self:_closeGrid(grid, true, true) end
        self:_showGrid(string.format(_("Search: %s"), display_query), results, {
            kind = "search", query = display_query, return_context = return_context,
        }, true, 1)
    end
    UIManager:nextTick(self._search_action)
end

function Bookshelf:showSearchDialog(grid)
    grid = grid or self.active_grid
    local return_context = grid and {
        kind = grid.context.kind,
        category_id = grid.context.category_id,
        smart_id = grid.context.smart_id,
        page = grid.page or 1,
    } or { kind = "root", page = 1 }
    local dialog
    dialog = InputDialog:new{
        title = _("Search bookshelf"),
        input_hint = _("Title, author, filename, or category"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = tostring(dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                if query == "" then return end
                UIManager:close(dialog)
                self:_scan()
                self:_startSearch(query, return_context, grid)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bookshelf:showCategoryPicker(file, done)
    if #self.store.data.categories == 0
            and not self.store:getSettings().confirm_category_assignment then
        self:promptCreateCategory(function(category)
            self.store:addBook(category.id, file)
            if done then done() end
        end)
        return
    end
    if not self.store:getSettings().confirm_category_assignment then
        local membership = self.store:categoryIdsForBook(file)
        local buttons, dialog = {}, nil
        for _, category in ipairs(self.store.data.categories) do
            local category_id, category_name = category.id, category.name
            buttons[#buttons + 1] = {{
                text = (membership[category_id] and "☒ " or "☐ ") .. category_name,
                callback = function()
                    UIManager:close(dialog)
                    if membership[category_id] then self.store:removeBook(category_id, file)
                    else self.store:addBook(category_id, file) end
                    if done then done() end
                end,
            }}
        end
        buttons[#buttons + 1] = {{ text = _("New category"), callback = function()
            UIManager:close(dialog)
            self:promptCreateCategory(function(category)
                self.store:addBook(category.id, file)
                if done then done() end
            end)
        end }}
        dialog = ButtonDialog:new{ title = basename(file), buttons = buttons }
        UIManager:show(dialog)
        return
    end

    local membership = self.store:categoryIdsForBook(file)
    local staged = {}
    local function show_confirm_picker()
    local buttons = {}
    local dialog
    for _, category in ipairs(self.store.data.categories) do
        local category_id = category.id
        local category_name = category.name
        buttons[#buttons + 1] = {{
            text = (membership[category_id] and "☒ " or "☐ ") .. category_name,
            callback = function()
                UIManager:close(dialog)
                membership[category_id] = not membership[category_id]
                show_confirm_picker()
            end,
        }}
    end
    for index, name in ipairs(staged) do
        local staged_index = index
        buttons[#buttons + 1] = {{
            text = "☒ " .. name,
            callback = function()
                UIManager:close(dialog)
                table.remove(staged, staged_index)
                show_confirm_picker()
            end,
        }}
    end
    buttons[#buttons + 1] = {
        { text = _("New category"), callback = function()
            UIManager:close(dialog)
            self:promptStagedCategory(function(name)
                staged[#staged + 1] = name
                show_confirm_picker()
            end)
        end },
        { text = _("Done"), callback = function()
            local ok = self.store:applyBookCategories(file, membership, staged)
            if not ok then self:_info(_("Unable to save category changes.")) return end
            UIManager:close(dialog)
            if done then done() end
        end },
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
    }
    dialog = ButtonDialog:new{ title = basename(file), buttons = buttons }
    UIManager:show(dialog)
    end
    show_confirm_picker()
end

function Bookshelf:_refreshActiveGrid()
    if self.active_grid then
        local ok, err = pcall(self.active_grid.refreshLayout, self.active_grid)
        if not ok then logger.err("Bookshelf: live layout refresh failed:", err) end
    end
end

function Bookshelf:_set(path, value)
    local ok = self.store:updateSetting(path, value)
    if not ok then self:_info(_("Unable to save bookshelf settings.")) return end
    if path[1] == "smart_shelves_enabled" and self.active_grid then
        self:_refreshBookGrid(self.active_grid)
    else
        self:_refreshActiveGrid()
    end
    if path[1] == "progress_badge_background" then
        -- The KOReader main menu may cover the bookshelf while this setting
        -- changes. Mark every stacked widget dirty so closing/collapsing the
        -- menu reveals the newly painted palette instead of its saved underlay.
        UIManager:setDirty("all", "ui")
    end
end

function Bookshelf:_spinItem(label, path, min, max, default, suffix)
    return {
        text_func = function()
            local value = self.store:getSettings()
            for _, key in ipairs(path) do value = value[key] end
            return string.format("%s: %d%s", label, value, suffix or "")
        end,
        callback = function()
            local value = self.store:getSettings()
            for _, key in ipairs(path) do value = value[key] end
            local spin
            spin = SpinWidget:new{
                title_text = label,
                value = value,
                value_min = min,
                value_max = max,
                default_value = default,
                keep_shown_on_apply = true,
                callback = function(widget) self:_set(path, widget.value) end,
            }
            UIManager:show(spin)
        end,
    }
end

function Bookshelf:_radioItems(path, choices)
    local result = {}
    for _, choice in ipairs(choices) do
        local choice_text, choice_value = choice[1], choice[2]
        result[#result + 1] = {
            text = choice_text, radio = true,
            checked_func = function()
                local value = self.store:getSettings()
                for _, key in ipairs(path) do value = value[key] end
                return value == choice_value
            end,
            callback = function() self:_set(path, choice_value) end,
        }
    end
    return result
end

function Bookshelf:_fontTextSettings(key, label, allow_show)
    local path = { key }
    local items = {
        {
            text_func = function()
                local font = self.store:getSettings()[key].font
                local name = font and FontChooser.getFontNameText(font)
                return _("Font") .. ": " .. (name or _("KOReader default"))
            end,
            callback = function()
                local config = self.store:getSettings()[key]
                UIManager:show(FontChooser:new{
                    title = label .. " - " .. _("Font"),
                    font_file = FontChooser.isFontRegistered(config.font) and config.font or nil,
                    default_font_file = "NotoSans-Regular.ttf",
                    callback = function(font) self:_set({ key, "font" }, font) end,
                })
            end,
        },
        self:_spinItem(_("Font size"), { key, "size" }, 10, 36, key == "author" and 14 or 18),
        self:_spinItem(_("Maximum lines"), { key, "max_lines" }, 1, 4, key == "author" and 1 or 2),
        { text = _("Alignment"), sub_item_table = self:_radioItems({ key, "align" }, {
            { _("Left"), "left" }, { _("Center"), "center" }, { _("Right"), "right" },
        }) },
        {
            text = _("Ellipsis when truncated"),
            checked_func = function() return self.store:getSettings()[key].ellipsis end,
            callback = function() self:_set({ key, "ellipsis" }, not self.store:getSettings()[key].ellipsis) end,
        },
    }
    if allow_show then
        table.insert(items, 1, {
            text = _("Show author"),
            checked_func = function() return self.store:getSettings().author.show end,
            callback = function() self:_set({ "author", "show" }, not self.store:getSettings().author.show) end,
        })
    end
    return { text = label, sub_item_table = items }
end

function Bookshelf:_settingsMenu()
    return {
        {
            text = _("Smart Shelf"),
            checked_func = function() return self.store:getSettings().smart_shelves_enabled end,
            callback = function()
                self:_set({ "smart_shelves_enabled" }, not self.store:getSettings().smart_shelves_enabled)
            end,
        },
        { text = _("Category assignment"), sub_item_table = {
            {
                text = _("Apply after confirmation"), radio = true,
                checked_func = function() return self.store:getSettings().confirm_category_assignment end,
                callback = function() self:_set({ "confirm_category_assignment" }, true) end,
            },
            {
                text = _("Apply immediately after selection"), radio = true,
                checked_func = function() return not self.store:getSettings().confirm_category_assignment end,
                callback = function() self:_set({ "confirm_category_assignment" }, false) end,
            },
        } },
        { text = _("Cover scale presets"), sub_item_table = self:_radioItems({ "cover_scale_percent" }, {
            { "50%", 50 }, { "75%", 75 }, { "100%", 100 },
        }) },
        self:_spinItem(_("Cover scale"), { "cover_scale_percent" }, 40, 120, 100, "%"),
        self:_spinItem(_("Portrait columns"), { "columns_portrait" }, 2, 8, 3),
        self:_spinItem(_("Landscape columns"), { "columns_landscape" }, 2, 10, 5),
        self:_spinItem(_("Rows per page"), { "rows_per_page" }, 1, 6, 2),
        { text = _("Cover ratio"), sub_item_table = self:_radioItems({ "cover_ratio" }, {
            { "2:3", "2:3" }, { "3:4", "3:4" }, { "4:5", "4:5" }, { _("Original ratio"), "original" },
        }) },
        { text = _("Cover treatment"), sub_item_table = self:_radioItems({ "crop_mode" }, {
            { _("Center crop"), "crop" }, { _("Fit entire cover"), "fit" },
        }) },
        self:_spinItem(_("Horizontal spacing"), { "horizontal_gap" }, 0, 40, 10),
        self:_spinItem(_("Vertical spacing"), { "vertical_gap" }, 0, 40, 12),
        self:_spinItem(_("Corner radius"), { "corner_radius" }, 0, 30, 8),
        { text = _("Progress badge background"), sub_item_table = self:_radioItems({ "progress_badge_background" }, {
            { _("White"), "white" }, { _("Gray"), "gray" }, { _("Black"), "black" },
        }) },
        self:_fontTextSettings("title", _("Book title"), false),
        self:_fontTextSettings("author", _("Author"), true),
        self:_fontTextSettings("category", _("Category name"), false),
        {
            text = _("Hide unavailable books"),
            checked_func = function() return self.store:getSettings().hide_missing end,
            callback = function() self:_set({ "hide_missing" }, not self.store:getSettings().hide_missing) end,
        },
    }
end

function Bookshelf:addToMainMenu(menu_items)
    menu_items.bookshelf = {
        text = _("Bookshelf"),
        sub_item_table = {
            { text = _("Open bookshelf"), callback = function() self:showRoot() end },
            { text = _("Search bookshelf"), callback = function() self:showSearchDialog(self.active_grid) end },
            {
                text = _("Open bookshelf at startup"),
                checked_func = function() return self.store:getSettings().startup_open end,
                callback = function() self:_set({ "startup_open" }, not self.store:getSettings().startup_open) end,
                separator = true,
            },
            { text = _("Layout and text settings"), sub_item_table = self:_settingsMenu() },
            {
                text = _("Clean unavailable records"),
                callback = function()
                    local root = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()
                    local count, skipped = self.store:cleanMissing(root)
                    if not count then
                        self:_info(_("The library storage is unavailable. No bookshelf records were changed."))
                        return
                    end
                    local message = string.format(_("Removed %d unavailable bookshelf records."), count)
                    if skipped and skipped > 0 then
                        message = message .. "\n" .. string.format(_("Kept %d records outside the active library root."), skipped)
                    end
                    self:_info(message)
                    self:_scan()
                    if self.active_grid then self:_refreshBookGrid(self.active_grid) end
                end,
            },
            {
                text = _("Clear bookshelf thumbnail cache"),
                callback = function()
                    local count = self.cache:clear()
                    self:_info(string.format(_("Removed %d cached thumbnails."), count))
                    self:_refreshActiveGrid()
                end,
            },
        },
    }
end

function Bookshelf:stopPlugin()
    self._stopped = true
    if self._search_action then UIManager:unschedule(self._search_action) self._search_action = nil end
    if self._search_message then pcall(UIManager.close, UIManager, self._search_message) self._search_message = nil end
    -- FileManager teardown is part of opening a reader. Keep the one-shot
    -- return context in that case; clear it for a real disable/exit.
    if not (self.ui and self.ui.tearing_down) then
        UIManager._bookshelf_reader_return = nil
    end
    if self._simpleui_qa and type(self._simpleui_qa.unregister) == "function" then
        pcall(self._simpleui_qa.unregister, SIMPLEUI_ACTION_ID)
        self._simpleui_qa = nil
    end
    self:_removeSimpleUIIconPickerEntries()
    if self._simpleui_core and self._simpleui_core.BarInjection
            and type(self._simpleui_core.BarInjection.unregister) == "function" then
        pcall(self._simpleui_core.BarInjection.unregister, SIMPLEUI_BAR_INJECTION_ID)
        self._simpleui_core = nil
    end
    if self._file_button_registered and self.ui and type(self.ui.removeFileDialogButtons) == "function" then
        pcall(self.ui.removeFileDialogButtons, self.ui, "bookshelf_add_to_shelf")
        self._file_button_registered = nil
    end
    if self.active_grid then
        self.active_grid._skip_return = true
        pcall(UIManager.close, UIManager, self.active_grid)
        self.active_grid = nil
    end
    if self.store._metadata_dirty then self.store:flush() end
    return true
end

function Bookshelf:onTeardown()
    return self:stopPlugin()
end

return Bookshelf
