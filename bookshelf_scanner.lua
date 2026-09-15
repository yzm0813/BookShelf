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

local function scanDir(path, result, seen, state_info)
    local ok, iterator, state = pcall(lfs.dir, path)
    if not ok or not iterator then
        state_info.complete = false
        logger.warn("Bookshelf: cannot scan directory:", path)
        return
    end
    local iterated, err = pcall(function()
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                local child = path .. "/" .. name
                local attr_ok, attr = pcall(lfs.symlinkattributes, child)
                if not attr_ok then state_info.complete = false attr = nil end
                if attr and attr.mode == "directory" and not EXCLUDED[name:lower()] and name:sub(-4):lower() ~= ".sdr" then
                    local real_ok, real = pcall(ffiUtil.realpath, child)
                    if not real_ok then state_info.complete = false real = nil end
                    if real and not seen[real] then
                        seen[real] = true
                        scanDir(real, result, seen, state_info)
                    end
                elseif attr and attr.mode == "file" then
                    local ok_provider, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, child)
                    if ok_provider and supported then
                        local real_ok, real = pcall(ffiUtil.realpath, child)
                        result[#result + 1] = real_ok and real or child
                    end
                end
            end
        end
    end)
    if not iterated then
        state_info.complete = false
        logger.warn("Bookshelf: directory scan interrupted:", path, err)
    end
end

function Scanner.scan(root)
    local result, seen, state_info = {}, {}, { complete = true }
    local real_ok, real = pcall(ffiUtil.realpath, root)
    local attr_ok, mode = false, nil
    if real_ok and real then attr_ok, mode = pcall(lfs.attributes, real, "mode") end
    if not real_ok or not real or mode ~= "directory" then
        logger.warn("Bookshelf: scan root is unavailable:", root)
        return result, false
    end
    seen[real] = true
    scanDir(real, result, seen, state_info)
    table.sort(result, function(a, b) return a:lower() < b:lower() end)
    return result, state_info.complete
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
