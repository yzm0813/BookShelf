-- Geometry invariants for the 6-inch reference size and its landscape
-- rotation. Values are test fixtures only; production code reads Screen.
local function layout(screen_w, screen_h, columns, rows, scale, ratio, count, requested_page)
    local horizontal_gap, vertical_gap = 10, 12
    local title_h, footer_h = 64, 44
    local item_w = math.max(1, math.floor((screen_w - (columns + 1) * horizontal_gap) / columns))
    local item_h = math.max(1, math.floor((screen_h - title_h - footer_h - (rows + 1) * vertical_gap) / rows))
    local title_slot, author_slot, stack = 48, 22, 12
    local cover_area_h = math.max(20, item_h - title_slot - author_slot - 3)
    local max_w, max_h = math.max(1, item_w - 6), math.max(1, cover_area_h - stack)
    local cover_w, cover_h = max_w, math.floor(max_w / ratio)
    if cover_h > max_h then cover_h, cover_w = max_h, math.floor(max_h * ratio) end
    cover_w, cover_h = math.floor(cover_w * scale / 100), math.floor(cover_h * scale / 100)
    local perpage = columns * rows
    local pages = math.max(1, math.ceil(count / perpage))
    local page = math.min(math.max(1, requested_page), pages)
    local badge_w = math.max(20, math.floor(cover_w * 5 / 24 + 0.5))
    local badge_x = math.max(0, math.min(cover_w - badge_w,
        math.floor(cover_w * 0.8 + 0.5) - math.floor(badge_w / 2)))
    return {
        item_w = item_w, item_h = item_h, cover_w = cover_w, cover_h = cover_h,
        badge_w = badge_w, badge_x = badge_x, perpage = perpage, pages = pages, page = page,
        last_page_items = count - (pages - 1) * perpage,
    }
end

for _, screen in ipairs({ { 1072, 1448 }, { 1448, 1072 } }) do
    for _, columns in ipairs({ 2, 3, 4, 5 }) do
        for _, scale in ipairs({ 50, 75, 100 }) do
            for _, ratio in ipairs({ 2 / 3, 3 / 4, 4 / 5 }) do
                local g = layout(screen[1], screen[2], columns, 2, scale, ratio, 17, 9)
            assert(g.cover_w > 0 and g.cover_h > 0)
            assert(g.cover_w <= g.item_w and g.cover_h <= g.item_h,
                "cover must remain inside its fixed card slot")
            assert(g.badge_x >= 0 and g.badge_x + g.badge_w <= g.cover_w,
                "fixed-size progress badge must stay inside the cover width")
            assert(g.page == g.pages, "a vanished return page must clamp to the last page")
            end
        end
    end
end

local last = layout(1072, 1448, 3, 2, 100, 2 / 3, 7, 2)
assert(last.pages == 2 and last.last_page_items == 1,
    "an incomplete final row must remain a valid last page")
print("PASS grid_geometry_spec: orientation, scales, ratios, badge, and final page")
