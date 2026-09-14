local DocumentRegistry = require("document/documentregistry")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Scanner = {}

local EXCLUDED = {
    [".sdr"] = true,
    [".adds"] = true,
    ["cache"] = true,
    ["plugins"] = true,
}

local function scanDir(path, result, seen)
    local ok, iterator, state = pcall(lfs.dir, path)
    if not ok or not iterator then return end
    for name in iterator, state do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local attr = lfs.symlinkattributes(child)
            if attr and attr.mode == "directory" and not EXCLUDED[name:lower()] and name:sub(-4):lower() ~= ".sdr" then
                local real = ffiUtil.realpath(child)
                if real and not seen[real] then
                    seen[real] = true
                    scanDir(real, result, seen)
                end
            elseif attr and attr.mode == "file" then
                local ok_provider, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, child)
                if ok_provider and supported then result[#result + 1] = ffiUtil.realpath(child) or child end
            end
        end
    end
end

function Scanner.scan(root)
    local result, seen = {}, {}
    local real = ffiUtil.realpath(root)
    if not real or lfs.attributes(real, "mode") ~= "directory" then
        logger.warn("Bookshelf: scan root is unavailable:", root)
        return result
    end
    seen[real] = true
    scanDir(real, result, seen)
    table.sort(result, function(a, b) return a:lower() < b:lower() end)
    return result
end

function Scanner.uncategorized(all_books, store)
    local assigned, result = {}, {}
    for _, category in ipairs(store.data.categories) do
        for _, path in ipairs(category.books) do assigned[path] = true end
    end
    for _, path in ipairs(all_books) do
        if not assigned[path] then result[#result + 1] = path end
    end
    return result
end

return Scanner
