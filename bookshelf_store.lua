local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Store = {}
Store.__index = Store

local DEFAULTS = {
    schema_version = 1,
    categories = {},
    metadata = {},
    settings = {
        startup_open = false,
        columns_portrait = 3,
        columns_landscape = 5,
        rows_per_page = 2,
        cover_scale_percent = 100,
        cover_ratio = "2:3",
        crop_mode = "crop",
        horizontal_gap = 10,
        vertical_gap = 12,
        corner_radius = 8,
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
        elseif type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        end
    end
end

local function normalized(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, real = pcall(ffiUtil.realpath, path)
    return ok and real or path
end

function Store:new(path)
    local o = setmetatable({}, self)
    o.path = path or (DataStorage:getSettingsDir() .. "/bookshelf.lua")
    o.db = LuaSettings:open(o.path)
    o.data = o.db.data
    merge(o.data, DEFAULTS)
    o:_sanitize()
    return o
end

function Store:_sanitize()
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
        end
    end
end

function Store:flush()
    self.db.data = self.data
    local ok, err = pcall(self.db.flush, self.db)
    if not ok then
        logger.err("Bookshelf: atomic settings write failed:", err)
        return nil, err
    end
    return true
end

function Store:getSettings()
    return self.data.settings
end

function Store:updateSetting(path, value)
    local target = self.data.settings
    for i = 1, #path - 1 do target = target[path[i]] end
    target[path[#path]] = value
    return self:flush()
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
    self:flush()
    return category
end

function Store:renameCategory(id, name)
    local category = self:getCategory(id)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if not category or name == "" then return nil end
    category.name = name
    self:flush()
    return true
end

function Store:deleteCategory(id)
    local _, index = self:getCategory(id)
    if not index then return nil end
    table.remove(self.data.categories, index)
    self:flush()
    return true
end

function Store:moveCategory(id, delta)
    local _, index = self:getCategory(id)
    if not index then return nil end
    local target = math.max(1, math.min(#self.data.categories, index + delta))
    if target ~= index then table.insert(self.data.categories, target, table.remove(self.data.categories, index)) end
    self:flush()
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
    if not self:hasBook(category_id, path) then table.insert(category.books, path) end
    self:flush()
    return true
end

function Store:removeBook(category_id, path)
    local category = self:getCategory(category_id)
    local _, index = self:hasBook(category_id, path)
    if not category or not index then return nil end
    table.remove(category.books, index)
    self:flush()
    return true
end

function Store:moveBook(category_id, path, delta)
    local category = self:getCategory(category_id)
    local _, index = self:hasBook(category_id, path)
    if not category or not index then return nil end
    local target = math.max(1, math.min(#category.books, index + delta))
    if target ~= index then table.insert(category.books, target, table.remove(category.books, index)) end
    self:flush()
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

function Store:firstValidBook(category)
    for _, path in ipairs(category.books) do
        if lfs.attributes(path, "mode") == "file" then return path end
    end
end

function Store:cleanMissing(scan_root)
    if scan_root and lfs.attributes(scan_root, "mode") ~= "directory" then
        return nil, "root_unavailable"
    end
    local count, skipped = 0, 0
    for _, category in ipairs(self.data.categories) do
        for i = #category.books, 1, -1 do
            local path = category.books[i]
            local in_root = not scan_root or path == scan_root or path:sub(1, #scan_root + 1) == scan_root .. "/"
            if lfs.attributes(path, "mode") ~= "file" and in_root then
                self.data.metadata[path] = nil
                table.remove(category.books, i)
                count = count + 1
            elseif lfs.attributes(path, "mode") ~= "file" then
                -- A missing path outside the currently mounted scan root may be
                -- on temporarily unavailable storage. Keep it conservatively.
                skipped = skipped + 1
            end
        end
    end
    self:flush()
    return count, skipped
end

function Store:getMetadata(path, mtime)
    local entry = self.data.metadata[path]
    if entry and (not mtime or entry.mtime == mtime) then return entry end
end

function Store:setMetadata(path, metadata)
    self.data.metadata[path] = metadata
end

return Store
