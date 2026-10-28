--- Bento.nvim floating render module.
---
--- Pure(-ish) rendering of the floating menu buffer. Each render function reads
--- everything it needs from the passed `state` instance (buffer handle, config,
--- per-buffer predicates) and from the ui machinery injected once via `setup`.
--- It owns no module state of its own, which is what keeps `ui.lua` tractable.
--- @module bento.render

local bento = require("bento")
local utils = require("bento.utils")

local M = {}

--- Injected ui helpers (pagination, window sizing, label assignment, keymaps).
--- Populated once by `ui.lua` through `M.setup`.
--- @type table
local ctx = {}

--- Wire the ui-side helpers this module depends on.
--- @param deps table
--- @return nil
function M.setup(deps)
    ctx = deps
end

--- Display menu in dashed collapsed state.
--- @param state bento.State
--- @return nil
function M.dashed(state)
    local bufh = state.bufh
    if not bufh or not vim.api.nvim_buf_is_valid(bufh) then
        return
    end

    local config = state:config()
    ctx.update_marks()
    local visible_marks, _ = ctx.get_page_marks()
    local _, _, needs_pagination = ctx.get_pagination_info()
    local contents = {}
    local padding = config.ui.floating.label_padding or 1
    local padding_str = string.rep(" ", padding)

    for i = 1, #visible_marks do
        contents[i] = padding_str
            .. state:dash_line(visible_marks[i].buf_id)
            .. padding_str
    end

    local dash_width = vim.fn.strwidth(
        state:dash_line(visible_marks[1] and visible_marks[1].buf_id or 0)
    )
    local total_width = dash_width + 2 * padding
    local total_height = #visible_marks

    if needs_pagination then
        -- Add empty line to maintain alignment with expanded mode
        -- (don't show indicator dots in dashed mode)
        table.insert(contents, string.rep(" ", total_width))
        total_height = total_height + 1
    end

    vim.api.nvim_buf_set_option(bufh, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufh, 0, -1, false, contents)
    vim.api.nvim_buf_set_option(bufh, "modifiable", false)

    ctx.update_window_size(total_width, total_height)

    local ns_id = vim.api.nvim_create_namespace("BentoDash")
    vim.api.nvim_buf_clear_namespace(bufh, ns_id, 0, -1)

    for i, mark in ipairs(visible_marks) do
        local is_modified = vim.api.nvim_buf_get_option(mark.buf_id, "modified")
        if is_modified then
            vim.api.nvim_buf_add_highlight(
                bufh,
                ns_id,
                config.highlights.modified,
                i - 1,
                0,
                -1
            )
        elseif not state:is_buffer_active(mark.buf_id) then
            vim.api.nvim_buf_add_highlight(
                bufh,
                ns_id,
                config.highlights.inactive_dash,
                i - 1,
                0,
                -1
            )
        end
    end

    ctx.clear_selection_keymaps()
end

--- Display menu in filename-only collapsed state.
--- @param state bento.State
--- @return nil
function M.filename_collapsed(state)
    local bufh = state.bufh
    if not bufh or not vim.api.nvim_buf_is_valid(bufh) then
        return
    end

    local config = state:config()
    ctx.update_marks()
    local marks = state:marks()
    local visible_marks, start_idx = ctx.get_page_marks()
    local _, _, needs_pagination = ctx.get_pagination_info()
    local contents = {}
    local padding = config.ui.floating.label_padding or 1
    local padding_str = string.rep(" ", padding)
    local lock_char = config.lock_char or "🔒"

    local all_paths = {}
    for _, mark in ipairs(marks) do
        table.insert(all_paths, mark.filename)
    end
    local display_names = utils.get_display_names(all_paths)

    local max_content_width = 0
    local all_line_data = {}
    for _, mark in ipairs(marks) do
        local display_name = display_names[mark.filename]
            or utils.get_file_name(mark.filename)
        local is_locked = bento.is_locked(mark.buf_id)
        local lock_prefix = is_locked and (lock_char .. " ") or ""
        local content_width = vim.fn.strwidth(lock_prefix .. display_name)
        max_content_width = math.max(max_content_width, content_width)
        table.insert(all_line_data, {
            display_name = display_name,
            lock_prefix = lock_prefix,
            is_locked = is_locked,
            content_width = content_width,
        })
    end

    local line_data = {}
    for i = start_idx, start_idx + #visible_marks - 1 do
        table.insert(line_data, all_line_data[i])
    end

    local total_width = padding + max_content_width + padding
    local total_height = #visible_marks

    for i, data in ipairs(line_data) do
        local left_space = max_content_width - data.content_width
        local line = padding_str
            .. string.rep(" ", left_space)
            .. data.lock_prefix
            .. data.display_name
            .. padding_str
        contents[i] = line
    end

    if needs_pagination then
        local indicator = ctx.generate_pagination_indicator(total_width)
        if indicator then
            table.insert(contents, indicator)
            total_height = total_height + 1
        end
    end

    vim.api.nvim_buf_set_option(bufh, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufh, 0, -1, false, contents)
    vim.api.nvim_buf_set_option(bufh, "modifiable", false)

    ctx.update_window_size(total_width, total_height)

    local ns_id = vim.api.nvim_create_namespace("BentoFilename")
    vim.api.nvim_buf_clear_namespace(bufh, ns_id, 0, -1)

    for i, mark in ipairs(visible_marks) do
        local is_current = state:is_current_buffer(mark.buf_id)
        local is_active = state:is_buffer_active(mark.buf_id)
        local is_modified = vim.api.nvim_buf_get_option(mark.buf_id, "modified")
        local data = line_data[i]

        local left_space = max_content_width - data.content_width
        local lock_prefix_bytes = #data.lock_prefix
        local display_name_bytes = #data.display_name
        local display_name_start = padding + left_space + lock_prefix_bytes
        local display_name_end = display_name_start + display_name_bytes

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

        if is_modified then
            vim.api.nvim_buf_add_highlight(
                bufh,
                ns_id,
                filename_hl,
                i - 1,
                0,
                -1
            )
        else
            vim.api.nvim_buf_add_highlight(
                bufh,
                ns_id,
                filename_hl,
                i - 1,
                display_name_start,
                display_name_end
            )
        end
    end

    if needs_pagination then
        vim.api.nvim_buf_add_highlight(
            bufh,
            ns_id,
            config.highlights.page_indicator,
            #visible_marks,
            0,
            -1
        )
    end

    ctx.clear_selection_keymaps()
end

--- Display menu in expanded state (labels + names).
--- @param state bento.State
--- @param is_minimal_full boolean|nil If true, uses minimal highlight for labels
--- @return nil
function M.expanded(state, is_minimal_full)
    local bufh = state.bufh
    if not bufh or not vim.api.nvim_buf_is_valid(bufh) then
        return
    end

    local config = state:config()
    ctx.update_marks()
    local marks = state:marks()
    local smart_labels = ctx.assign_smart_labels(marks, ctx.get_available_keys())
    local visible_marks, start_idx = ctx.get_page_marks()
    local _, _, needs_pagination = ctx.get_pagination_info()
    local contents = {}
    local padding = config.ui.floating.label_padding or 1
    local padding_str = string.rep(" ", padding)
    local lock_char = config.lock_char or "🔒"

    local all_paths = {}
    for _, mark in ipairs(marks) do
        table.insert(all_paths, mark.filename)
    end
    local display_names = utils.get_display_names(all_paths)

    local max_content_width = 0
    local all_line_data = {}
    for i, mark in ipairs(marks) do
        local label = smart_labels[i] or " "
        local display_name = display_names[mark.filename]
            or utils.get_file_name(mark.filename)
        local is_locked = bento.is_locked(mark.buf_id)
        local lock_prefix = is_locked and (lock_char .. " ") or ""
        -- Format: [lock_prefix][display_name] [space] [padding][label][padding]
        local content_width = vim.fn.strwidth(lock_prefix)
            + vim.fn.strwidth(display_name)
            + 1
            + padding
            + #label
            + padding
        max_content_width = math.max(max_content_width, content_width)
        table.insert(all_line_data, {
            label = label,
            display_name = display_name,
            lock_prefix = lock_prefix,
            is_locked = is_locked,
            content_width = content_width,
            global_idx = i,
        })
    end

    local line_data = {}
    for i = start_idx, start_idx + #visible_marks - 1 do
        table.insert(line_data, all_line_data[i])
    end

    local total_width = padding + max_content_width
    local total_height = #visible_marks

    for i, data in ipairs(line_data) do
        local left_space = max_content_width - data.content_width
        -- Format: [padding][left_space][lock_prefix][display_name] [space] [padding][label][padding]
        local line = padding_str
            .. string.rep(" ", left_space)
            .. data.lock_prefix
            .. data.display_name
            .. " "
            .. padding_str
            .. data.label
            .. padding_str
        contents[i] = line
    end

    if needs_pagination then
        local indicator = ctx.generate_pagination_indicator(total_width)
        if indicator then
            table.insert(contents, indicator)
            total_height = total_height + 1
        end
    end

    vim.api.nvim_buf_set_option(bufh, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufh, 0, -1, false, contents)
    vim.api.nvim_buf_set_option(bufh, "modifiable", false)

    ctx.update_window_size(total_width, total_height)

    local ns_id = vim.api.nvim_create_namespace("BentoLabel")
    vim.api.nvim_buf_clear_namespace(bufh, ns_id, 0, -1)

    local last_accessed_buf = state:last_accessed_buffer()
    for i, mark in ipairs(visible_marks) do
        local data = line_data[i]
        local label = data.label
        local is_current = state:is_current_buffer(mark.buf_id)
        local is_active = state:is_buffer_active(mark.buf_id)
        local is_modified = vim.api.nvim_buf_get_option(mark.buf_id, "modified")

        if label and label ~= " " then
            local left_space = max_content_width - data.content_width
            local lock_prefix_bytes = #data.lock_prefix
            local display_name_bytes = #data.display_name
            local display_name_start = padding + left_space + lock_prefix_bytes
            local display_name_end = display_name_start + display_name_bytes
            local label_start = display_name_end + 1 + padding
            local label_end = label_start + #label + padding

            local label_hl
            local is_previous_buffer = mark.buf_id == last_accessed_buf
            if is_minimal_full then
                label_hl = config.highlights.label_minimal
            elseif is_previous_buffer then
                label_hl = config.highlights.previous
            else
                local action_name = state.current_action
                    or config.default_action
                    or "open"
                label_hl = config.highlights.label

                if
                    config.actions[action_name]
                    and config.actions[action_name].hl
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

            if is_modified then
                vim.api.nvim_buf_add_highlight(
                    bufh,
                    ns_id,
                    filename_hl,
                    i - 1,
                    0,
                    display_name_end + 1
                )
            else
                vim.api.nvim_buf_add_highlight(
                    bufh,
                    ns_id,
                    filename_hl,
                    i - 1,
                    display_name_start,
                    display_name_end
                )
            end

            vim.api.nvim_buf_add_highlight(
                bufh,
                ns_id,
                label_hl,
                i - 1,
                label_start - padding,
                label_end
            )
        end
    end

    if needs_pagination then
        vim.api.nvim_buf_add_highlight(
            bufh,
            ns_id,
            config.highlights.page_indicator,
            #visible_marks,
            0,
            -1
        )
    end

    if is_minimal_full then
        ctx.clear_selection_keymaps()
    else
        ctx.set_selection_keybindings(smart_labels)
    end
end

return M
