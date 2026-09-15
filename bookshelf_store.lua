local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local dump = require("dump")
local util = require("util")

local Store = {}
Store.__index = Store

local DEFAULTS = {
    schema_version = 1,
    categories = {},
    metadata = {},
    settings = {
        startup_open = false,
        confirm_category_assignment = true,
        book_sort = "manual",
        smart_shelves_enabled = false,
        columns_portrait = 3,
        columns_landscape = 5,
        rows_per_page = 2,
        cover_scale_percent = 100,
        cover_ratio = "2:3",
        crop_mode = "crop",
        horizontal_gap = 10,
        vertical_gap = 12,
        corner_radius = 8,
        progress_badge_background = "gray",
        hide_missing = false,
        title = { font = nil, size = 18, max_lines = 2, align = "center", ellipsis = true },
        author = { font = nil, size = 14, max_lines = 1, align = "center", ellipsis = true, show = true },
        category = { font = nil, size = 18, max_lines = 2, align = "center", ellipsis = true },
    },
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = clone(v) end
    return copy
end

local function merge(dst, defaults)
    for k, v in pairs(defaults) do
        if dst[k] == nil then
            dst[k] = clone(v)
        elseif type(v) == "table" then
            if type(dst[k]) == "table" then merge(dst[k], v)
            else dst[k] = clone(v) end
        end
    end
end

local function normalized(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, real = pcall(ffiUtil.realpath, path)
    return ok and real or path
end

local function pathMode(path)
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode or nil
end

function Store:new(path)
    local o = setmetatable({}, self)
    o.path = path or (DataStorage:getSettingsDir() .. "/bookshelf.lua")
    o.db = LuaSettings:open(o.path)
    o.data = type(o.db.data) == "table" and o.db.data or {}
    o.data.categories = type(o.data.categories) == "table" and o.data.categories or {}
    o.data.metadata = type(o.data.metadata) == "table" and o.data.metadata or {}
    o.data.settings = type(o.data.settings) == "table" and o.data.settings or {}
    merge(o.data, DEFAULTS)
    o:_sanitize()
    return o
end

function Store:_sanitize()
    local settings = self.data.settings
    local numeric_ranges = {
        columns_portrait = { 2, 8, 3 }, columns_landscape = { 2, 10, 5 },
        rows_per_page = { 1, 6, 2 }, cover_scale_percent = { 40, 120, 100 },
        horizontal_gap = { 0, 40, 10 }, vertical_gap = { 0, 40, 12 },
        corner_radius = { 0, 30, 8 },
    }
    for key, range in pairs(numeric_ranges) do
        local value = tonumber(settings[key]) or range[3]
        settings[key] = math.floor(math.max(range[1], math.min(range[2], value)))
    end
    if not ({ ["2:3"] = true, ["3:4"] = true, ["4:5"] = true, original = true })[settings.cover_ratio] then
        settings.cover_ratio = "2:3"
    end
    if settings.crop_mode ~= "crop" and settings.crop_mode ~= "fit" then settings.crop_mode = "crop" end
    if not ({ white = true, gray = true, black = true })[settings.progress_badge_background] then
        settings.progress_badge_background = "gray"
    end
    for _, key in ipairs({ "title", "author", "category" }) do
        local config = settings[key]
        config.size = math.floor(math.max(10, math.min(36, tonumber(config.size) or (key == "author" and 14 or 18))))
        config.max_lines = math.floor(math.max(1, math.min(4, tonumber(config.max_lines) or (key == "author" and 1 or 2))))
        if config.align ~= "left" and config.align ~= "center" and config.align ~= "right" then config.align = "center" end
        if type(config.font) ~= "string" then config.font = nil end
        if type(config.ellipsis) ~= "boolean" then config.ellipsis = true end
    end
    if type(settings.author.show) ~= "boolean" then settings.author.show = true end
    if type(settings.confirm_category_assignment) ~= "boolean" then settings.confirm_category_assignment = true end
    if type(settings.smart_shelves_enabled) ~= "boolean" then settings.smart_shelves_enabled = false end
    if type(settings.startup_open) ~= "boolean" then settings.startup_open = false end
    if type(settings.hide_missing) ~= "boolean" then settings.hide_missing = false end
    local valid_book_sort = {
        manual = true,
        name = true,
        modification = true,
        last_read = true,
    }
    if not valid_book_sort[self.data.settings.book_sort] then
        self.data.settings.book_sort = "manual"
    end
    local seen_ids = {}
    for i = #self.data.categories, 1, -1 do
        local category = self.data.categories[i]
        if type(category) ~= "table" or type(category.id) ~= "string" or seen_ids[category.id] then
            table.remove(self.data.categories, i)
        else
            seen_ids[category.id] = true
            category.name = tostring(category.name or "")
            category.books = type(category.books) == "table" and category.books or {}
            local seen_paths = {}
            for j = #category.books, 1, -1 do
                local path = normalized(category.books[j])
                if not path or seen_paths[path] then
                    table.remove(category.books, j)
                else
                    category.books[j] = path
                    seen_paths[path] = true
                end
            end
            category.cover_path = normalized(category.cover_path)
            if category.cover_path and not seen_paths[category.cover_path] then
                category.cover_path = nil
            end
        end
    end
end

function Store:flush()
    self.db.data = self.data
    local temporary = self.path .. ".tmp"
    local content = "-- " .. temporary .. "\nreturn " .. dump(self.data, nil, true) .. "\n"
    local attr_ok, current_attr = pcall(lfs.attributes, self.path)
    current_attr = attr_ok and current_attr or nil
    if current_attr and current_attr.mode == "file"
            and (current_attr.modification or 0) < os.time() - 60 then
        local read_ok, old_content = pcall(util.readFromFile, self.path)
        if read_ok and old_content then
            local old_temporary = self.path .. ".old.tmp"
            pcall(os.remove, old_temporary)
            local backup_ok, backup_written = pcall(util.writeToFile, old_content, old_temporary, true)
            if backup_ok and backup_written then
                local replace_ok, replaced = pcall(os.rename, old_temporary, self.path .. ".old")
                if not replace_ok or not replaced then pcall(os.remove, old_temporary) end
            end
        end
    end
    pcall(os.remove, temporary)
    local write_ok, written, write_err = pcall(util.writeToFile, content, temporary, true)
    if not write_ok or not written then
        pcall(os.remove, temporary)
        local err = write_ok and write_err or written
        logger.err("Bookshelf: temporary settings write failed:", err)
        return nil, err or "temporary_write_failed"
    end
    local rename_ok, renamed, rename_err = pcall(os.rename, temporary, self.path)
    if not rename_ok or not renamed then
        pcall(os.remove, temporary)
        local err = rename_ok and rename_err or renamed
        logger.err("Bookshelf: atomic settings replace failed:", err)
        return nil, err or "atomic_replace_failed"
    end
    if ffiUtil.fsyncDirectory then pcall(ffiUtil.fsyncDirectory, self.path) end
    self._metadata_dirty = nil
    return true
end

function Store:getSettings()
    return self.data.settings
end

function Store:updateSetting(path, value)
    local target = self.data.settings
    for i = 1, #path - 1 do target = target[path[i]] end
    local key = path[#path]
    local previous = target[key]
    target[key] = value
    local ok, err = self:flush()
    if not ok then target[key] = previous end
    return ok, err
end

function Store:_newId()
    self._id_counter = (self._id_counter or 0) + 1
    local base = string.format("shelf-%08x-%04x", os.time(), self._id_counter)
    local candidate, suffix = base, 0
    while self:getCategory(candidate) do
        suffix = suffix + 1
        candidate = base .. "-" .. suffix
    end
    return candidate
end

function Store:getCategory(id)
    for index, category in ipairs(self.data.categories) do
        if category.id == id then return category, index end
    end
end

function Store:createCategory(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "empty_name" end
    local category = { id = self:_newId(), name = name, books = {} }
    table.insert(self.data.categories, category)
    local ok, err = self:flush()
    if not ok then
        table.remove(self.data.categories)
        return nil, err
    end
    return category
end

function Store:renameCategory(id, name)
    local category = self:getCategory(id)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if not category or name == "" then return nil end
    local previous = category.name
    category.name = name
    local ok, err = self:flush()
    if not ok then category.name = previous return nil, err end
    return true
end

function Store:deleteCategory(id)
    local _, index = self:getCategory(id)
    if not index then return nil end
    local removed = table.remove(self.data.categories, index)
    local ok, err = self:flush()
    if not ok then table.insert(self.data.categories, index, removed) return nil, err end
    return true
end

function Store:moveCategory(id, delta)
    local _, index = self:getCategory(id)
    if not index then return nil end
    local target = math.max(1, math.min(#self.data.categories, index + delta))
    if target == index then return true end
    table.insert(self.data.categories, target, table.remove(self.data.categories, index))
    local ok, err = self:flush()
    if not ok then
        table.insert(self.data.categories, index, table.remove(self.data.categories, target))
        return nil, err
    end
    return true
end

function Store:hasBook(category_id, path)
    local category = self:getCategory(category_id)
    path = normalized(path)
    if not category or not path then return false end
    for index, saved in ipairs(category.books) do
        if saved == path then return true, index end
    end
    return false
end

function Store:addBook(category_id, path)
    local category = self:getCategory(category_id)
    path = normalized(path)
    if not category or not path then return nil end
    if self:hasBook(category_id, path) then return true end
    table.insert(category.books, path)
    local ok, err = self:flush()
    if not ok then table.remove(category.books) return nil, err end
    return true
end

function Store:removeBook(category_id, path)
    local category = self:getCategory(category_id)
    local _, index = self:hasBook(category_id, path)
    if not category or not index then return nil end
    local previous_cover = category.cover_path
    table.remove(category.books, index)
    if category.cover_path == path then category.cover_path = nil end
    local ok, err = self:flush()
    if not ok then
        table.insert(category.books, index, normalized(path))
        category.cover_path = previous_cover
        return nil, err
    end
    return true
end

function Store:moveBook(category_id, path, delta)
    local category = self:getCategory(category_id)
    local _, index = self:hasBook(category_id, path)
    if not category or not index then return nil end
    local target = math.max(1, math.min(#category.books, index + delta))
    if target == index then return true end
    table.insert(category.books, target, table.remove(category.books, index))
    local ok, err = self:flush()
    if not ok then
        table.insert(category.books, index, table.remove(category.books, target))
        return nil, err
    end
    return true
end

function Store:categoryIdsForBook(path)
    local result = {}
    path = normalized(path)
    for _, category in ipairs(self.data.categories) do
        for _, saved in ipairs(category.books) do
            if saved == path then result[category.id] = true break end
        end
    end
    return result
end

-- Apply the complete category membership for one book in a single settings
-- write. New category names are committed as selected categories. This is the
-- transaction boundary used by the confirm-mode category picker.
function Store:applyBookCategories(path, selected_ids, new_category_names)
    path = normalized(path)
    if not path then return nil, "invalid_path" end
    selected_ids = type(selected_ids) == "table" and selected_ids or {}
    new_category_names = type(new_category_names) == "table" and new_category_names or {}

    local clean_names = {}
    for _, name in ipairs(new_category_names) do
        name = tostring(name or ""):match("^%s*(.-)%s*$")
        if name == "" then return nil, "empty_name" end
        clean_names[#clean_names + 1] = name
    end

    local before = clone(self.data.categories)
    for _, category in ipairs(self.data.categories) do
        local _, index = self:hasBook(category.id, path)
        if selected_ids[category.id] then
            if not index then category.books[#category.books + 1] = path end
        elseif index then
            table.remove(category.books, index)
            if category.cover_path == path then category.cover_path = nil end
        end
    end
    for _, name in ipairs(clean_names) do
        local category = { id = self:_newId(), name = name, books = { path } }
        self.data.categories[#self.data.categories + 1] = category
    end

    local ok, err = self:flush()
    if not ok then
        self.data.categories = before
        self.db.data = self.data
        return nil, err
    end
    return true
end

function Store:firstValidBook(category)
    if category.cover_path and pathMode(category.cover_path) == "file" then
        return category.cover_path
    end
    for _, path in ipairs(category.books) do
        if pathMode(path) == "file" then return path end
    end
end

function Store:setCategoryCover(category_id, path)
    local category = self:getCategory(category_id)
    if not category then return nil, "category_not_found" end
    path = normalized(path)
    if path and not self:hasBook(category_id, path) then return nil, "book_not_in_category" end
    local previous = category.cover_path
    category.cover_path = path
    local ok, err = self:flush()
    if not ok then category.cover_path = previous return nil, err end
    return true
end

function Store:relocateBook(old_path, new_path)
    old_path, new_path = normalized(old_path), normalized(new_path)
    if not old_path or not new_path then return nil, "invalid_path" end
    if old_path == new_path then return nil, "same_path" end

    local before_categories = clone(self.data.categories)
    local before_metadata = clone(self.data.metadata)
    local changed = false
    for _, category in ipairs(self.data.categories) do
        local old_index, new_index
        for index, path in ipairs(category.books) do
            if path == old_path then old_index = index end
            if path == new_path then new_index = index end
        end
        if old_index then
            changed = true
            category.books[old_index] = new_path
            if new_index then
                table.remove(category.books, new_index)
            end
            if category.cover_path == old_path then category.cover_path = new_path end
        end
    end
    if not changed then return nil, "book_not_referenced" end

    if self.data.metadata[old_path] then
        if not self.data.metadata[new_path] then self.data.metadata[new_path] = self.data.metadata[old_path] end
        self.data.metadata[old_path] = nil
    end
    local ok, err = self:flush()
    if not ok then
        self.data.categories = before_categories
        self.data.metadata = before_metadata
        self.db.data = self.data
        return nil, err
    end
    return true
end

function Store:cleanMissing(scan_root)
    if scan_root and pathMode(scan_root) ~= "directory" then
        return nil, "root_unavailable"
    end
    local before = clone(self.data.categories)
    local count, skipped = 0, 0
    for _, category in ipairs(self.data.categories) do
        for i = #category.books, 1, -1 do
            local path = category.books[i]
            local in_root = not scan_root or path == scan_root or path:sub(1, #scan_root + 1) == scan_root .. "/"
            if pathMode(path) ~= "file" and in_root then
                table.remove(category.books, i)
                if category.cover_path == path then category.cover_path = nil end
                count = count + 1
            elseif pathMode(path) ~= "file" then
                -- A missing path outside the currently mounted scan root may be
                -- on temporarily unavailable storage. Keep it conservatively.
                skipped = skipped + 1
            end
        end
    end
    local ok, err = self:flush()
    if not ok then self.data.categories = before self.db.data = self.data return nil, err end
    return count, skipped
end

function Store:gcMetadata(all_books, scan_complete)
    if not scan_complete then return 0, "scan_incomplete" end
    local live = {}
    for _, path in ipairs(all_books or {}) do live[normalized(path) or path] = true end
    for _, category in ipairs(self.data.categories) do
        for _, path in ipairs(category.books) do live[path] = true end
    end
    local removed = {}
    local count = 0
    for path, metadata in pairs(self.data.metadata) do
        if not live[path] then
            removed[path] = metadata
            self.data.metadata[path] = nil
            count = count + 1
        end
    end
    if count == 0 then return 0 end
    local ok, err = self:flush()
    if not ok then
        for path, metadata in pairs(removed) do self.data.metadata[path] = metadata end
        return nil, err
    end
    return count
end

function Store:getMetadata(path, mtime)
    local entry = self.data.metadata[path]
    if entry and (not mtime or entry.mtime == mtime) then return entry end
end

function Store:setMetadata(path, metadata)
    self.data.metadata[path] = metadata
    self._metadata_dirty = true
end

return Store
