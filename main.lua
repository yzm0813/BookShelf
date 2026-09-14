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
        if self.store:getSettings().startup_open and type(self.ui.registerPostInitCallback) == "function" then
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

function Bookshelf:_info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
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
    self.all_books = Scanner.scan(root)
    self.uncategorized = Scanner.uncategorized(self.all_books, self.store)
end

function Bookshelf:_rootEntries()
    local entries = {}
    for _, category in ipairs(self.store.data.categories) do
        entries[#entries + 1] = {
            kind = "category",
            category_id = category.id,
            name = category.name,
            path = self.store:firstValidBook(category),
        }
    end
    entries[#entries + 1] = {
        kind = "uncategorized",
        name = _("Uncategorized books"),
        path = self.uncategorized[1],
    }
    return entries
end

function Bookshelf:_bookEntries(paths, category_id)
    local entries = {}
    for _, path in ipairs(paths) do
        local exists = lfs.attributes(path, "mode") == "file"
        if exists or not self.store:getSettings().hide_missing then
            entries[#entries + 1] = {
                kind = "book",
                path = path,
                name = basename(path),
                category_id = category_id,
                missing = not exists,
            }
        end
    end
    return entries
end

function Bookshelf:_showGrid(title, entries, context, return_to_root)
    local grid = Grid:new{
        title = title,
        item_table = entries,
        plugin = self,
        store = self.store,
        cache = self.cache,
        context = context,
        close_callback = return_to_root and function()
            if not grid._skip_return and not self._stopped then self:showRoot() end
        end or nil,
    }
    self.active_grid = grid
    UIManager:show(grid)
    return grid
end

function Bookshelf:showRoot()
    self:_scan()
    return self:_showGrid(_("Bookshelf"), self:_rootEntries(), { kind = "root" }, false)
end

function Bookshelf:showCategory(category_id)
    local category = self.store:getCategory(category_id)
    if not category then return self:showRoot() end
    return self:_showGrid(category.name, self:_bookEntries(category.books, category.id),
        { kind = "category", category_id = category.id }, true)
end

function Bookshelf:showUncategorized()
    self:_scan()
    return self:_showGrid(_("Uncategorized books"), self:_bookEntries(self.uncategorized),
        { kind = "uncategorized" }, true)
end

function Bookshelf:_closeGrid(grid, skip_return)
    if grid then grid._skip_return = skip_return end
    if grid then UIManager:close(grid) end
end

function Bookshelf:onGridSelect(grid, entry)
    if entry.kind == "category" then
        self:_closeGrid(grid, true)
        self:showCategory(entry.category_id)
    elseif entry.kind == "uncategorized" then
        self:_closeGrid(grid, true)
        self:showUncategorized()
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
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        self:_closeGrid(grid, true)
        UIManager:nextTick(function()
            local ok, err = pcall(filemanagerutil.openFile, self.ui, book_path, nil, true)
            self._opening_book = nil
            if not ok then
                -- SetupShowReader only marks FileManager as tearing down. If
                -- opening fails before ShowingReader closes it, make the
                -- existing FileManager usable again and report the error.
                if self.ui then self.ui.tearing_down = nil end
                logger.err("Bookshelf: failed to open original book:", book_path, err)
                self:_info(_("Unable to open the original book file."))
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
    else
        self:_info(_("Long-press a book to add it to a category."))
    end
end

function Bookshelf:onGridHold(grid, entry)
    if entry.kind == "category" then
        local category = self.store:getCategory(entry.category_id)
        if category then self:showCategoryActions(grid, category) end
    elseif entry.kind == "uncategorized" then
        self:onGridSelect(grid, entry)
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
    if grid.context.kind == "category" then
        local category = self.store:getCategory(grid.context.category_id)
        grid.item_table = self:_bookEntries(category and category.books or {}, grid.context.category_id)
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
                            else self:_closeGrid(grid, true) self:showRoot() end
                        end,
                    }
                    UIManager:show(confirm)
                end },
            },
            {
                { text = _("Move earlier"), callback = function() UIManager:close(dialog) self.store:moveCategory(category.id, -1) refresh_after_move() end },
                { text = _("Move later"), callback = function() UIManager:close(dialog) self.store:moveCategory(category.id, 1) refresh_after_move() end },
            },
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
            { { text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:showCategoryPicker(file, done)
    if #self.store.data.categories == 0 then
        self:promptCreateCategory(function(category)
            self.store:addBook(category.id, file)
            if done then done() end
        end)
        return
    end
    local membership = self.store:categoryIdsForBook(file)
    local buttons = {}
    local dialog
    for _, category in ipairs(self.store.data.categories) do
        local category_id = category.id
        local category_name = category.name
        buttons[#buttons + 1] = {{
            text = (membership[category_id] and "☒ " or "☐ ") .. category_name,
            callback = function()
                UIManager:close(dialog)
                if membership[category_id] then self.store:removeBook(category_id, file)
                else self.store:addBook(category_id, file) end
                if done then done() end
                self:showCategoryPicker(file, done)
            end,
        }}
    end
    buttons[#buttons + 1] = {
        { text = _("New category"), callback = function()
            UIManager:close(dialog)
            self:promptCreateCategory(function(category)
                self.store:addBook(category.id, file)
                if done then done() end
            end)
        end },
        { text = _("Done"), id = "close", callback = function() UIManager:close(dialog) if done then done() end end },
    }
    dialog = ButtonDialog:new{ title = basename(file), buttons = buttons }
    UIManager:show(dialog)
end

function Bookshelf:_refreshActiveGrid()
    if self.active_grid then
        local ok, err = pcall(self.active_grid.refreshLayout, self.active_grid)
        if not ok then logger.err("Bookshelf: live layout refresh failed:", err) end
    end
end

function Bookshelf:_set(path, value)
    self.store:updateSetting(path, value)
    self:_refreshActiveGrid()
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
    if self._file_button_registered and self.ui and type(self.ui.removeFileDialogButtons) == "function" then
        pcall(self.ui.removeFileDialogButtons, self.ui, "bookshelf_add_to_shelf")
        self._file_button_registered = nil
    end
    if self.active_grid then
        self.active_grid._skip_return = true
        pcall(UIManager.close, UIManager, self.active_grid)
        self.active_grid = nil
    end
    self.store:flush()
    return true
end

function Bookshelf:onTeardown()
    return self:stopPlugin()
end

return Bookshelf
