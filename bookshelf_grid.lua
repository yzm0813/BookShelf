local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FontChooser = require("ui/widget/fontchooser")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Screen = Device.screen

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

local function makeText(text, config, width, bold)
    return TextBoxWidget:new{
        text = text or "",
        face = safeFace(config),
        bold = bold,
        width = width,
        height = textHeight(config),
        height_adjust = true,
        height_overflow_show_ellipsis = config.ellipsis,
        alignment = config.align,
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

function Card:_fakeCover(w, h, text, missing)
    local config = self.entry.kind == "category" and self.menu.settings.category or self.menu.settings.title
    local inner_w = math.max(1, w - 2 * Screen:scaleBySize(6))
    local label = makeText(missing and (text .. "\n(文件失效)") or text, config, inner_w, true)
    return FrameContainer:new{
        width = w,
        height = h,
        padding = Screen:scaleBySize(4),
        margin = 0,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(self.menu.settings.corner_radius),
        color = missing and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = math.max(1, h - Screen:scaleBySize(8)) }, label },
    }
end

function Card:_progressBadge(percent, w, h)
    if percent == nil then return nil end
    local text = TextWidget:new{
        text = string.format("%d%%", math.max(0, math.min(100, math.floor(percent * 100 + 0.5)))),
        face = Font:getFace("smallinfofont", 13),
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    local badge = FrameContainer:new{
        padding = Screen:scaleBySize(3),
        margin = Screen:scaleBySize(2),
        bordersize = 0,
        radius = Screen:scaleBySize(5),
        background = Blitbuffer.COLOR_DARK_GRAY,
        text,
    }
    return RightContainer:new{
        dimen = Geom:new{ w = w, h = h },
        TopContainer:new{ dimen = Geom:new{ w = badge:getSize().w, h = h }, badge },
    }
end

function Card:_build()
    local settings, entry = self.menu.settings, self.entry
    local category_like = entry.kind ~= "book"
    local path = entry.path
    local attr = path and lfs.attributes(path) or nil
    local metadata = path and self.menu.store:getMetadata(path, attr and attr.modification) or nil
    local title_cfg = category_like and settings.category or settings.title
    local label_h = textHeight(title_cfg)
    local author_h = entry.kind == "book" and settings.author.show and textHeight(settings.author) or 0
    local text_gap = Screen:scaleBySize(2)
    local cover_area_h = math.max(Screen:scaleBySize(20), self.height - label_h - author_h - 2 * text_gap)
    local cover_w, cover_h = self:_coverDimensions(cover_area_h, metadata)
    local radius = math.min(Screen:scaleBySize(settings.corner_radius), math.floor(math.min(cover_w, cover_h) / 2))
    local spec = { w = cover_w, h = cover_h, mode = settings.crop_mode,
        ratio = settings.cover_ratio, radius = radius }
    local cached = path and attr and self.menu.cache:get(path, spec) or nil
    local visual
    if cached then
        visual = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            padding = 0,
            margin = 0,
            bordersize = Size.border.thin,
            radius = radius,
            ImageWidget:new{ file = cached, width = cover_w, height = cover_h },
        }
        self.menu._has_cover_images = true
    else
        visual = self:_fakeCover(cover_w, cover_h,
            category_like and entry.name or (metadata and metadata.title or entry.name),
            path and not attr)
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
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = cover_w, h = cover_h },
        visual,
        not category_like and self:_progressBadge(progress, cover_w, cover_h) or nil,
    }

    local text_w = math.max(1, self.width - 2 * Screen:scaleBySize(2))
    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, CenterContainer:new{ dimen = Geom:new{ w = self.width, h = cover_area_h }, cover })
    table.insert(group, VerticalSpan:new{ width = text_gap })
    local display_title = category_like and entry.name
        or (metadata and metadata.title or entry.name)
    table.insert(group, makeText(display_title, title_cfg, text_w, category_like))
    if entry.kind == "book" and settings.author.show then
        table.insert(group, makeText(metadata and metadata.authors or "", settings.author, text_w, false))
    end
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
