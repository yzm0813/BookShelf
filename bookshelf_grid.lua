local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FontChooser = require("ui/widget/fontchooser")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("bookshelf_i18n")

local Screen = Device.screen

-- FrameContainer paints its border before its child. On cover images that can
-- let the child overwrite anti-aliased corner pixels. CoverFrame deliberately
-- paints background, inset content, then the border as the final layer.
local CoverFrame = WidgetContainer:extend{
    width = 1,
    height = 1,
    bordersize = 1,
    radius = 0,
}

function CoverFrame:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function CoverFrame:paintTo(bb, x, y)
    self.dimen = self.dimen or Geom:new{}
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = self.width, self.height
    bb:paintRoundedRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE, self.radius)
    if self[1] then self[1]:paintTo(bb, x + self.bordersize, y + self.bordersize) end
    bb:paintBorder(x, y, self.width, self.height, self.bordersize,
        Blitbuffer.COLOR_BLACK, self.radius, G_reader_settings:nilOrTrue("anti_alias_ui"))
end

-- Category covers reserve a small strip above the real cover for three
-- perspective "book page" lines. The farthest line is shortest and every
-- following line grows toward the foreground cover.
local CategoryCover = WidgetContainer:extend{
    width = 1,
    height = 1,
    stack_height = 0,
    line_count = 3,
    line_thickness = 1,
    line_gap = 1,
}

function CategoryCover:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

-- A compact bookmark-shaped progress marker: rounded flat top, straight
-- body, and a gently rounded taper to the lower point. It is drawn by
-- scanlines so it works on KOReader's grayscale blitbuffer without SVG or
-- alpha-mask allocations for every card.
local RibbonBadge = WidgetContainer:extend{
    width = 1,
    height = 1,
    body_height = 1,
    radius = 1,
    bordersize = 1,
    background = Blitbuffer.COLOR_BLACK,
    color = Blitbuffer.COLOR_BLACK,
}

function RibbonBadge:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local function ribbonRowInset(row, width, height, body_height, radius)
    if row < radius then
        local dy = radius - row - 0.5
        return math.max(0, math.ceil(radius - math.sqrt(math.max(0, radius * radius - dy * dy))))
    end
    if row < body_height then return 0 end
    local tail_height = math.max(1, height - body_height)
    local t = math.min(1, math.max(0, (row - body_height + 0.5) / tail_height))
    -- Smoothstep rounds both the square-to-triangle shoulders and the tip.
    local eased = t * t * (3 - 2 * t)
    return math.min(math.floor((width - 1) / 2),
        math.floor((width - 1) * 0.5 * eased + 0.5))
end

local function paintRibbonShape(bb, x, y, width, height, body_height, radius, color)
    for row = 0, height - 1 do
        local inset = ribbonRowInset(row, width, height, body_height, radius)
        bb:paintRect(x + inset, y + row, math.max(1, width - 2 * inset), 1, color)
    end
end

function RibbonBadge:paintTo(bb, x, y)
    self.dimen = self.dimen or Geom:new{}
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = self.width, self.height
    paintRibbonShape(bb, x, y, self.width, self.height,
        self.body_height, self.radius, self.color)
    local border = self.bordersize
    if self.background ~= self.color and self.width > border * 2 and self.height > border * 2 then
        paintRibbonShape(bb, x + border, y + border,
            self.width - border * 2, self.height - border * 2,
            math.max(1, self.body_height - border),
            math.max(1, self.radius - border), self.background)
    end
    if self[1] then self[1]:paintTo(bb, x, y) end
end

local BadgeAnchor = WidgetContainer:extend{
    width = 1,
    height = 1,
    offset_x = 0,
    offset_y = 0,
}

function BadgeAnchor:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function BadgeAnchor:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x + self.offset_x, y + self.offset_y) end
end

function CategoryCover:paintTo(bb, x, y)
    self.dimen = self.dimen or Geom:new{}
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = self.width, self.height
    local step = self.line_thickness + self.line_gap
    local max_inset = math.floor(self.width * 0.18)
    local min_inset = math.max(self.line_thickness, math.floor(self.width * 0.05))
    for i = 1, self.line_count do
        local progress = self.line_count > 1 and (i - 1) / (self.line_count - 1) or 1
        local inset = math.floor(max_inset - (max_inset - min_inset) * progress)
        bb:paintRect(x + inset, y + (i - 1) * step,
            math.max(1, self.width - 2 * inset), self.line_thickness,
            Blitbuffer.COLOR_DARK_GRAY)
    end
    if self[1] then self[1]:paintTo(bb, x, y + self.stack_height) end
end

local function safeFace(config)
    local name = config.font
    if name and not FontChooser.isFontRegistered(name) then name = nil end
    local ok, face = pcall(Font.getFace, Font, name or "cfont", config.size)
    if ok and face then return face end
    return Font:getFace("cfont", config.size)
end

local function textHeight(config)
    return math.max(1, Screen:scaleBySize(math.floor(config.size * 1.28))) * config.max_lines
end

local function makeText(text, config, width, bold, color)
    return TextBoxWidget:new{
        text = text or "",
        face = safeFace(config),
        bold = bold,
        width = width,
        height = textHeight(config),
        height_adjust = true,
        height_overflow_show_ellipsis = config.ellipsis,
        alignment = config.align,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
end

local Card = InputContainer:extend{
    entry = nil,
    menu = nil,
}

function Card:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local underline_h = Size.line.focus_indicator
    self.underline = UnderlineContainer:new{
        vertical_align = "top",
        padding = Size.padding.tiny,
        linesize = underline_h,
        dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height + underline_h },
        self:_build(),
    }
    self[1] = self.underline
end

function Card:_coverDimensions(cover_area_h, metadata)
    local settings = self.menu.settings
    local ratio
    if settings.cover_ratio == "original" then
        ratio = metadata and metadata.cover_ratio or 2 / 3
    else
        local rw, rh = settings.cover_ratio:match("^(%d+):(%d+)$")
        ratio = tonumber(rw) / tonumber(rh)
    end
    local max_w = math.max(1, self.width - 2 * Screen:scaleBySize(3))
    local max_h = math.max(1, cover_area_h)
    local w, h = max_w, math.floor(max_w / ratio)
    if h > max_h then h, w = max_h, math.floor(max_h * ratio) end
    local scale = settings.cover_scale_percent / 100
    return math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale))
end

function Card:_fakeCover(w, h, text, missing, radius, border)
    local config = self.entry.kind == "category" and self.menu.settings.category or self.menu.settings.title
    local inner_w = math.max(1, w - 2 * border)
    local inner_h = math.max(1, h - 2 * border)
    local label_w = math.max(1, inner_w - 2 * Screen:scaleBySize(6))
    local label = makeText(missing and (text .. "\n(文件失效)") or text, config, label_w, true)
    return CoverFrame:new{
        width = w,
        height = h,
        bordersize = border,
        radius = radius,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label },
    }
end

function Card:_progressBadge(percent, w, h, top_offset)
    if percent == nil then return nil end
    local style = self.menu.settings.progress_badge_background or "gray"
    local background, foreground, border_color
    if style == "white" then
        background = Blitbuffer.COLOR_WHITE
        foreground = Blitbuffer.COLOR_BLACK
        border_color = Blitbuffer.COLOR_BLACK
    elseif style == "black" then
        background = Blitbuffer.COLOR_BLACK
        foreground = Blitbuffer.COLOR_WHITE
        border_color = Blitbuffer.COLOR_BLACK
    else
        background = Blitbuffer.COLOR_LIGHT_GRAY
        foreground = Blitbuffer.COLOR_BLACK
        border_color = Blitbuffer.COLOR_DARK_GRAY
    end
    -- The approved 50 x 45 mock-up maps to a 240 px cover. Keep those
    -- proportions on every screen and orientation instead of fixing pixels.
    local badge_w = math.max(Screen:scaleBySize(20), math.floor(w * 5 / 24 + 0.5))
    local body_h = math.max(1, math.floor(badge_w * 3 / 5 + 0.5))
    local tail_h = math.max(1, math.floor(badge_w * 3 / 10 + 0.5))
    local badge_h = body_h + tail_h
    local badge_face = Font:getFace("smallinfofont", math.max(8, math.floor(13 * 0.8 + 0.5)))
    local text = TextWidget:new{
        text = string.format("%d%%", math.max(0, math.min(100, math.floor(percent * 100 + 0.5)))),
        face = badge_face,
        fgcolor = foreground,
    }
    -- Every percentage shares the same cover-relative box. The text is
    -- centered over the complete ribbon, matching the approved preview.
    local border = math.max(1, Size.border.thin)
    local fixed_text = CenterContainer:new{
        dimen = Geom:new{ w = badge_w, h = badge_h },
        text,
    }
    local badge = RibbonBadge:new{
        width = badge_w,
        height = badge_h,
        body_height = body_h,
        bordersize = border,
        color = border_color,
        radius = math.max(1, math.floor(badge_w * 0.14 + 0.5)),
        background = background,
        fixed_text,
    }
    local center_x = math.floor(w * 0.8 + 0.5)
    local offset_x = math.max(0, math.min(w - badge_w,
        center_x - math.floor(badge_w / 2)))
    local protrusion = math.max(1, math.floor(badge_h / 4 + 0.5))
    local offset_y = math.max(0, (top_offset or 0) - protrusion)
    return BadgeAnchor:new{
        width = w,
        height = h,
        offset_x = offset_x,
        offset_y = offset_y,
        badge,
    }
end

function Card:_build()
    local settings, entry = self.menu.settings, self.entry
    local category_like = entry.kind ~= "book"
    local path = entry.path
    local attr = path and lfs.attributes(path) or nil
    local metadata = path and self.menu.store:getMetadata(path, attr and attr.modification) or nil
    local title_cfg = category_like and settings.category or settings.title
    -- Mixed root pages need one geometry model for categories and books.
    -- Reserve the larger title slot and an author slot for every card so the
    -- cover tops and text baselines do not move with content or font choice.
    local title_slot_h = math.max(textHeight(settings.title), textHeight(settings.category))
    -- The second text row is permanent: it contains a grey category book
    -- count, a grey author, or an empty placeholder when authors are hidden.
    local author_slot_h = textHeight(settings.author)
    local cover_text_gap = Screen:scaleBySize(2)
    local metadata_gap = math.max(1, Size.margin.tiny)
    local cover_area_h = math.max(Screen:scaleBySize(20),
        self.height - title_slot_h - author_slot_h - cover_text_gap - metadata_gap)
    local stack_line_count = 3
    local stack_line_thickness = math.max(1, Size.line.medium)
    local stack_line_gap = math.max(1,
        math.floor(Screen:scaleBySize(2) * settings.cover_scale_percent / 100))
    -- Reserve the same stack strip on every card. Category cards fill it with
    -- perspective lines while book cards leave it blank, so both cover bodies
    -- are calculated from exactly the same area and start on the same baseline.
    local stack_height = stack_line_count * (stack_line_thickness + stack_line_gap)
    local cover_w, cover_h = self:_coverDimensions(
        math.max(1, cover_area_h - stack_height), metadata)
    local radius = math.min(Screen:scaleBySize(settings.corner_radius), math.floor(math.min(cover_w, cover_h) / 2))
    local border = math.max(1, Size.border.default)
    local inner_w = math.max(1, cover_w - 2 * border)
    local inner_h = math.max(1, cover_h - 2 * border)
    local inner_radius = math.max(0, radius - border)
    local spec = { w = inner_w, h = inner_h, mode = settings.crop_mode,
        ratio = settings.cover_ratio, radius = inner_radius }
    local cached = path and attr and self.menu.cache:get(path, spec) or nil
    local visual
    if cached then
        visual = CoverFrame:new{
            width = cover_w,
            height = cover_h,
            bordersize = border,
            radius = radius,
            ImageWidget:new{ file = cached, width = inner_w, height = inner_h },
        }
        self.menu._has_cover_images = true
    else
        visual = self:_fakeCover(cover_w, cover_h,
            category_like and entry.name or (metadata and metadata.title or entry.name),
            path and not attr, radius, border)
        if path and attr and not (metadata and metadata.cover_missing) then
            self.menu:_queueExtraction(path, spec)
        end
    end

    local progress
    if entry.kind == "book" and attr then
        local ok, info = pcall(BookList.getBookInfo, path)
        if ok and info and info.been_opened then
            if info.status == "complete" then progress = 1
            elseif info.percent_finished and info.percent_finished > 0 then progress = info.percent_finished end
        end
    end
    local visual_h = cover_h + stack_height
    visual = CategoryCover:new{
        width = cover_w,
        height = visual_h,
        stack_height = stack_height,
        line_count = category_like and stack_line_count or 0,
        line_thickness = stack_line_thickness,
        line_gap = stack_line_gap,
        visual,
    }
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = cover_w, h = visual_h },
        visual,
        not category_like and self:_progressBadge(progress, cover_w, visual_h, stack_height) or nil,
    }

    local text_w = math.max(1, self.width - 2 * Screen:scaleBySize(2))
    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, TopContainer:new{
        dimen = Geom:new{ w = self.width, h = cover_area_h },
        CenterContainer:new{ dimen = Geom:new{ w = self.width, h = visual_h }, cover },
    })
    table.insert(group, VerticalSpan:new{ width = cover_text_gap })
    local display_title = category_like and entry.name
        or (metadata and metadata.title or entry.name)
    table.insert(group, BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = title_slot_h },
        makeText(display_title, title_cfg, text_w, category_like),
    })
    table.insert(group, VerticalSpan:new{ width = metadata_gap })
    local secondary_text
    if category_like then
        secondary_text = string.format(_("%d books"), entry.book_count or 0)
    elseif settings.author.show then
        secondary_text = metadata and metadata.authors or ""
    else
        secondary_text = ""
    end
    table.insert(group, TopContainer:new{
        dimen = Geom:new{ w = self.width, h = author_slot_h },
        makeText(secondary_text, settings.author, text_w, false,
            Blitbuffer.COLOR_DARK_GRAY),
    })
    return CenterContainer:new{ dimen = self.dimen:copy(), group }
end

function Card:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function Card:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

function Card:onFocus() self.underline.color = Blitbuffer.COLOR_BLACK return true end
function Card:onUnfocus() self.underline.color = Blitbuffer.COLOR_WHITE return true end

local Grid = BookList:extend{
    name = "bookshelf_grid",
    is_borderless = true,
    is_popout = false,
    covers_fullscreen = true,
    title_bar_left_icon = "plus",
}

function Grid:init()
    self.settings = self.store:getSettings()
    self._pending, self._pending_keys = {}, {}
    BookList.init(self)
end

function Grid:_recalculateDimen()
    local portrait = Screen:getWidth() <= Screen:getHeight()
    self.nb_cols = portrait and self.settings.columns_portrait or self.settings.columns_landscape
    self.nb_rows = self.settings.rows_per_page
    self.perpage = self.nb_cols * self.nb_rows
    self.page_num = math.max(1, math.ceil(#self.item_table / self.perpage))
    if self.page > self.page_num then self.page = self.page_num end
    local top_h = self.title_bar and self.title_bar.dimen.h or 0
    local footer_h = self.page_info and self.page_info:getSize().h or Screen:scaleBySize(36)
    local hgap = Screen:scaleBySize(self.settings.horizontal_gap)
    local vgap = Screen:scaleBySize(self.settings.vertical_gap)
    self.item_width = math.max(1, math.floor((self.inner_dimen.w - (self.nb_cols + 1) * hgap) / self.nb_cols))
    self.item_height = math.max(1, math.floor((self.inner_dimen.h - top_h - footer_h - (self.nb_rows + 1) * vgap) / self.nb_rows))
    self.item_dimen = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
    self._hgap, self._vgap = hgap, vgap
end

function Grid:_queueExtraction(path, spec)
    local key = self.cache:key(path, spec)
    if not self._pending_keys[key] then
        self._pending_keys[key] = true
        self._pending[#self._pending + 1] = { path = path, spec = spec }
    end
end

function Grid:_updateItemsBuildUI()
    self._pending, self._pending_keys = {}, {}
    local offset = (self.page - 1) * self.perpage
    local row, row_layout
    for slot = 1, self.perpage do
        local index = offset + slot
        local entry = self.item_table[index]
        if not entry then break end
        entry.idx = index
        if slot % self.nb_cols == 1 then
            if slot > 1 then self.layout[#self.layout + 1] = row_layout end
            row, row_layout = HorizontalGroup:new{}, {}
            table.insert(self.item_group, VerticalSpan:new{ width = self._vgap })
            table.insert(self.item_group, LeftContainer:new{
                dimen = Geom:new{ w = self.inner_dimen.w, h = self.item_height }, row,
            })
            table.insert(row, HorizontalSpan:new{ width = self._hgap })
        end
        local card = Card:new{
            width = self.item_width,
            height = self.item_height,
            dimen = self.item_dimen:copy(),
            entry = entry,
            menu = self,
        }
        table.insert(row, card)
        table.insert(row, HorizontalSpan:new{ width = self._hgap })
        row_layout[#row_layout + 1] = card
    end
    if row_layout then self.layout[#self.layout + 1] = row_layout end
    table.insert(self.item_group, VerticalSpan:new{ width = self._vgap })
end

function Grid:_startExtraction()
    if self.extract_action or #self._pending == 0 then return end
    local queue = self._pending
    self.extract_action = function()
        if self._closed then return end
        local job = table.remove(queue, 1)
        if not job then
            self.extract_action = nil
            self.store:flush()
            self.cache:prune(400)
            self:updateItems(1, true)
            return
        end
        local attr = lfs.attributes(job.path) or {}
        local metadata = { mtime = attr.modification }
        local bookinfo = self.plugin.ui and self.plugin.ui.bookinfo
        if bookinfo and type(bookinfo.getDocProps) == "function" then
            local ok, props = pcall(bookinfo.getDocProps, bookinfo, job.path)
            if ok and props then metadata.title, metadata.authors = props.display_title or props.title, props.authors end
        end
        metadata.title = metadata.title or filemanagerutil.splitFileNameType(job.path:match("([^/]+)$"))
        local output, reason, cover_ratio = self.cache:generate(job.path, job.spec)
        metadata.cover_missing = not output
        metadata.cover_ratio = cover_ratio
        self.store:setMetadata(job.path, metadata)
        if reason and reason ~= "no_cover" then logger.warn("Bookshelf: thumbnail generation failed:", job.path, reason) end
        UIManager:scheduleIn(0.05, self.extract_action)
    end
    UIManager:nextTick(self.extract_action)
end

function Grid:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    if not no_recalculate_dimen then self:_recalculateDimen() end
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self._has_cover_images = false
    self:_updateItemsBuildUI()
    self:updatePageInfo(select_number)
    Menu.mergeTitleBarIntoLayout(self)
    self.dithered = self._has_cover_images
    UIManager:setDirty(self, function() return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen, self.dithered end)
    self:_startExtraction()
end

function Grid:refreshLayout()
    self.settings = self.store:getSettings()
    self:updateItems(1, false)
end

function Grid:onLeftButtonTap()
    self.plugin:onGridAction(self)
    return true
end

function Grid:onMenuSelect(entry)
    self.plugin:onGridSelect(self, entry)
    return true
end

function Grid:onMenuHold(entry)
    self.plugin:onGridHold(self, entry)
    return true
end

function Grid:onCloseWidget()
    if self._bookshelf_close_done then return end
    self._bookshelf_close_done = true
    self._closed = true
    if self.extract_action then UIManager:unschedule(self.extract_action) self.extract_action = nil end
    if self.plugin.active_grid == self then self.plugin.active_grid = nil end
    self.item_group:free()
    Menu.onCloseWidget(self)
end

return Grid
