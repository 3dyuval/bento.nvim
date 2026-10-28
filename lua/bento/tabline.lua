--- Bento.nvim tabline render module.
---
--- Renders the menu as Neovim's `&tabline`. Mirrors `render.lua`: the pure core
--- (marks + state -> tabline string) reads everything from the passed `state`
--- instance and the ui helpers injected via `setup`; the thin effectful shell
--- writes `vim.o.tabline` / `vim.o.showtabline` and binds selection keys.
--- @module bento.tabline

local bento = require("bento")
local utils = require("bento.utils")

local M = {}

--- Injected ui helpers (marks refresh, label assignment, keymaps).
--- @type table
local ctx = {}

--- Wire the ui-side helpers this module depends on.
--- @param deps table
--- @return nil
function M.setup(deps)
    ctx = deps
end

--- Calculate segment widths for all marks (used for tabline pagination).
--- @param state bento.State
--- @return number[] Array of widths for each mark
local function segment_widths(state)
    local config = state:config()
    local marks = state:marks()
    local smart_labels = ctx.assign_smart_labels(marks, ctx.get_available_keys())
    local lock_char = config.lock_char or "🔒"

    local all_paths = {}
    for _, mark in ipairs(marks) do
        table.insert(all_paths, mark.filename)
    end
    local display_names = utils.get_display_names(all_paths)

    local widths = {}
    for i, mark in ipairs(marks) do
        local label = smart_labels[i] or " "
        local display_name = display_names[mark.filename]
            or utils.get_file_name(mark.filename)
        local is_locked = bento.is_locked(mark.buf_id)

        local width = 0
        if label and label ~= " " then
            width = width + 1 + vim.fn.strwidth(label) + 1
        end
        if is_locked then
            width = width + 1 + vim.fn.strwidth(lock_char)
        end
        width = width + 1 + vim.fn.strwidth(display_name)

        table.insert(widths, width)
    end

    return widths
end

--- Calculate the start index for the previous page in tabline.
--- @param state bento.State
--- @param current_start_idx number Current starting index
--- @return number Start index for previous page
function M.prev_page_start(state, current_start_idx)
    if current_start_idx <= 1 then
        return 1
    end

    local config = state:config()
    local ui = vim.api.nvim_list_uis()[1]
    local screen_width = ui and ui.width or 80
    local separator_symbol = config.ui.tabline.separator_symbol or "|"
    local separator_width = 1 + vim.fn.strwidth(separator_symbol) + 1 -- " symbol " between segments
    local left_symbol = config.ui.tabline.left_page_symbol or "❮"
    local right_symbol = config.ui.tabline.right_page_symbol or "❯"
    local left_symbol_width = vim.fn.strwidth(left_symbol)
    local right_symbol_width = vim.fn.strwidth(right_symbol)
    local left_symbol_with_spacing = 1 + left_symbol_width + 2 -- 1-space margin + symbol + 2-space gap
    local right_symbol_with_spacing = 2 + right_symbol_width + 1 -- 2-space gap + symbol + 1-space margin

    local widths = segment_widths(state)

    local target_end_idx = current_start_idx - 1

    local available_width = screen_width - right_symbol_with_spacing -- reserve for trailing symbol + gap

    local total_width = 0
    local start_idx = target_end_idx

    for i = target_end_idx, 1, -1 do
        local seg_width = widths[i]
        local needed_width = seg_width
        if i < target_end_idx then
            needed_width = needed_width + separator_width
        end

        local has_prev = i > 1
        local test_available = available_width
        if has_prev then
            test_available = test_available - left_symbol_with_spacing
        end

        if total_width + needed_width <= test_available then
            total_width = total_width + needed_width
            start_idx = i
        else
            break
        end
    end

    return start_idx
end

--- Generate the tabline string for rendering.
--- @param state bento.State
--- @param is_minimal boolean If true, uses minimal highlight for labels
--- @return string tabline_string The formatted tabline string
--- @return number end_idx Last visible buffer index
local function generate_string(state, is_minimal)
    local config = state:config()
    ctx.update_marks()
    local marks = state:marks()

    if #marks == 0 then
        return "", 0
    end

    local smart_labels = ctx.assign_smart_labels(marks, ctx.get_available_keys())
    state.smart_labels = smart_labels
    local lock_char = config.lock_char or "🔒"
    local window_bg_hl = config.highlights.window_bg
    local page_indicator_hl = config.highlights.page_indicator

    local all_paths = {}
    for _, mark in ipairs(marks) do
        table.insert(all_paths, mark.filename)
    end
    local display_names = utils.get_display_names(all_paths)

    -- Creates a tabline-specific highlight group with window_bg background
    local function get_tabline_hl(base_hl)
        local tabline_hl_name = "BentoTabline_" .. base_hl
        local base_hl_info =
            vim.api.nvim_get_hl(0, { name = base_hl, link = false })
        local fg = base_hl_info.fg
        local bg_hl_info =
            vim.api.nvim_get_hl(0, { name = window_bg_hl, link = false })
        vim.api.nvim_set_hl(0, tabline_hl_name, {
            fg = fg,
            bg = bg_hl_info.bg,
            bold = base_hl_info.bold,
            italic = base_hl_info.italic,
            underline = base_hl_info.underline,
        })
        return tabline_hl_name
    end

    local tabline_page_indicator_hl = get_tabline_hl(page_indicator_hl)

    local separator_hl = config.highlights.separator or "Normal"
    local tabline_separator_hl = get_tabline_hl(separator_hl)
    local separator_symbol = config.ui.tabline.separator_symbol or "|"

    -- Calculates the display width of a buffer segment
    local function get_segment_width(label, display_name, is_locked)
        local width = 0
        if label and label ~= " " then
            width = width + 1 + vim.fn.strwidth(label) + 1
        end
        if is_locked then
            width = width + 1 + vim.fn.strwidth(lock_char)
        end
        width = width + 1 + vim.fn.strwidth(display_name)
        return width
    end

    local last_accessed_buf = state:last_accessed_buffer()
    local all_segments = {}
    for i, mark in ipairs(marks) do
        local label = smart_labels[i] or " "
        local display_name = display_names[mark.filename]
            or utils.get_file_name(mark.filename)
        local is_locked = bento.is_locked(mark.buf_id)
        local is_current = state:is_current_buffer(mark.buf_id)
        local is_active = state:is_buffer_active(mark.buf_id)
        local is_modified = vim.api.nvim_buf_get_option(mark.buf_id, "modified")

        local label_hl
        local is_previous_buffer = mark.buf_id == last_accessed_buf
        if is_minimal then
            label_hl = config.highlights.label_minimal
        elseif is_previous_buffer then
            label_hl = config.highlights.previous
        else
            local action_name = state.current_action
                or config.default_action
                or "open"
            label_hl = config.highlights.label
            if
                config.actions[action_name] and config.actions[action_name].hl
            then
                label_hl = config.actions[action_name].hl
            end
        end

        local filename_hl
        if is_modified then
            filename_hl = config.highlights.modified
        elseif is_current then
            filename_hl = config.highlights.current
        elseif is_active then
            filename_hl = config.highlights.active
        else
            filename_hl = config.highlights.inactive
        end

        local tabline_filename_hl = get_tabline_hl(filename_hl)

        local segment = ""
        if label and label ~= " " then
            segment = segment .. "%#" .. label_hl .. "#" .. " " .. label .. " "
        end
        if is_locked then
            segment = segment
                .. "%#"
                .. tabline_filename_hl
                .. "#"
                .. " "
                .. lock_char
        end
        segment = segment
            .. "%#"
            .. tabline_filename_hl
            .. "#"
            .. " "
            .. display_name

        table.insert(all_segments, {
            segment = segment,
            width = get_segment_width(label, display_name, is_locked),
        })
    end

    local ui = vim.api.nvim_list_uis()[1]
    local screen_width = ui and ui.width or 80
    local separator_width = 1 + vim.fn.strwidth(separator_symbol) + 1 -- " symbol " between segments
    local left_symbol = config.ui.tabline.left_page_symbol or "❮"
    local right_symbol = config.ui.tabline.right_page_symbol or "❯"
    local left_symbol_width = vim.fn.strwidth(left_symbol)
    local right_symbol_width = vim.fn.strwidth(right_symbol)
    local left_symbol_with_spacing = 1 + left_symbol_width + 2 -- 1-space margin + symbol + 2-space gap
    local right_symbol_with_spacing = 2 + right_symbol_width + 1 -- 2-space gap + symbol + 1-space margin

    if state.tabline_start < 1 then
        state.tabline_start = 1
    elseif state.tabline_start > #marks then
        state.tabline_start = #marks
    end

    local has_prev = state.tabline_start > 1
    local available_width = screen_width
    if has_prev then
        available_width = available_width - left_symbol_with_spacing
    end

    local visible_segments = {}
    local current_width = 0
    local end_idx = state.tabline_start

    for i = state.tabline_start, #all_segments do
        local seg = all_segments[i]
        local needed_width = seg.width
        if #visible_segments > 0 then
            needed_width = needed_width + separator_width
        end

        local remaining_buffers = #all_segments - i
        local need_trailing_symbol = remaining_buffers > 0
        local width_with_trailing = current_width + needed_width
        if need_trailing_symbol then
            width_with_trailing = width_with_trailing
                + right_symbol_with_spacing
        end

        if width_with_trailing <= available_width then
            table.insert(visible_segments, seg)
            current_width = current_width + needed_width
            end_idx = i
        else
            break
        end
    end

    local has_next = end_idx < #all_segments

    local parts = {}

    if has_prev then
        table.insert(
            parts,
            "%#"
                .. window_bg_hl
                .. "# "
                .. "%#"
                .. tabline_page_indicator_hl
                .. "#"
                .. left_symbol
                .. "%#"
                .. window_bg_hl
                .. "#  "
        )
    end

    local segment_strings = {}
    for _, seg in ipairs(visible_segments) do
        table.insert(segment_strings, seg.segment)
    end
    local separator = "%#"
        .. window_bg_hl
        .. "# "
        .. "%#"
        .. tabline_separator_hl
        .. "#"
        .. separator_symbol
        .. "%#"
        .. window_bg_hl
        .. "# "
    table.insert(parts, table.concat(segment_strings, separator))

    if has_next then
        table.insert(
            parts,
            "%#"
                .. window_bg_hl
                .. "#  %="
                .. "%#"
                .. tabline_page_indicator_hl
                .. "#"
                .. right_symbol
                .. "%#"
                .. window_bg_hl
                .. "# "
        )
    else
        table.insert(parts, "%#" .. window_bg_hl .. "#%=")
    end

    return table.concat(parts, ""), end_idx
end

--- Render tabline in expanded state (labels visible, keymaps active).
--- @param state bento.State
--- @return nil
function M.expanded(state)
    state:config()
    ctx.update_marks()

    if #state:marks() == 0 then
        return
    end

    local tabline_str, end_idx = generate_string(state, false)
    state.tabline_end = end_idx
    vim.o.tabline = tabline_str
    vim.o.showtabline = 2

    ctx.set_selection_keybindings(state.smart_labels)
end

--- Render tabline in minimal state.
--- @param state bento.State
--- @return nil
function M.minimal(state)
    state:config()
    ctx.update_marks()

    if #state:marks() == 0 then
        return
    end

    local tabline_str, end_idx = generate_string(state, true)
    state.tabline_end = end_idx
    vim.o.tabline = tabline_str
    vim.o.showtabline = 2

    ctx.clear_selection_keymaps()
end

--- Save original tabline settings onto state.
--- @param state bento.State
--- @return nil
function M.save_settings(state)
    if state.saved_tabline == nil then
        state.saved_tabline = vim.o.tabline
        state.saved_showtabline = vim.o.showtabline
    end
end

--- Restore original tabline settings from state.
--- @param state bento.State
--- @return nil
function M.restore_settings(state)
    if state.saved_tabline ~= nil then
        vim.o.tabline = state.saved_tabline
        vim.o.showtabline = state.saved_showtabline
        state.saved_tabline = nil
        state.saved_showtabline = nil
    end
end

return M
