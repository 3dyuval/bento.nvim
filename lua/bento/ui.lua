--- Bento.nvim UI module - Handles floating window and tabline rendering
--- @module bento.ui

local bento = require("bento")
local utils = require("bento.utils")
local notify = require("bento.notify")
local render = require("bento.render")
local tabline = require("bento.tabline")
local marks = require("bento").marks
local line_keys = require("bento").line_keys

local M = {}

--- Window ID of the bento floating window
--- @type number|nil
local bento_win_id = nil

--- Buffer handle of the bento floating window
--- @type number|nil
local bento_bufh = nil

--- Last editor window ID (non-floating window)
--- @type number|nil
local last_editor_win = nil

--- Current plugin configuration
--- @type table
local config = bento.get_config()

--- Whether the menu is in expanded state
--- @type boolean
local is_expanded = false

--- Keys we've overridden in selection mode
--- @type string[]
local selection_mode_keymaps = {}

--- Original keymaps to restore when exiting selection mode
--- @type table<string, table>
local saved_keymaps = {}

--- Currently active action mode (e.g., "open", "delete", "vsplit")
--- @type string|nil
local current_action = nil

--- Current state of minimal menu (nil | "dashed" | "filename" | "full")
--- @type string|nil
local minimal_menu_active = nil

--- Current page for floating UI pagination (1-indexed)
--- @type number
local current_page = 1

--- Registered key for expanding the menu (set via register_expand_key)
--- @type string|nil
local registered_expand_key = nil

--- Registered key for the last-accessed buffer (set via register_last_buffer_key)
--- @type string|nil
local registered_last_buffer_key = nil

--- Registered key for collapsing/closing the menu (set via register_collapse_key)
--- @type string|nil
local registered_collapse_key = nil

--- Registered key for next page (set via register_next_page_key)
--- @type string|nil
local registered_next_page_key = nil

--- Registered key for previous page (set via register_prev_page_key)
--- @type string|nil
local registered_prev_page_key = nil

--- Track which warnings have been shown to avoid repetition
--- @type table<string, boolean>
local warnings_shown = {}

--- Show a warning once per session
--- @param key string Unique key for this warning
--- @param message string Warning message to display
--- @return nil
local function warn_once(key, message)
    if warnings_shown[key] then
        return
    end
    warnings_shown[key] = true
    notify.warn(message)
end

--- Initialize UI state from configuration
--- @return nil
function M.setup_state()
    config = bento.get_config()
    if config.ui.mode == "tabline" then
        return
    end
    if minimal_menu_active == nil then
        minimal_menu_active = config.ui.floating.minimal_menu
    end
end

--- Set the last editor window ID
--- @param win_id number Window ID
--- @return nil
function M.set_last_editor_win(win_id)
    last_editor_win = win_id
end

vim.api.nvim_set_hl(0, "BentoNormal", { bg = "NONE", fg = "NONE" })

--- Check if using tabline UI mode
--- @return boolean
local function is_tabline_ui()
    config = bento.get_config()
    return config.ui.mode == "tabline"
end

--- Check if buffer is visible in current tab
--- @param buf_id number Buffer ID
--- @return boolean
local function is_buffer_visible_in_tab(buf_id)
    for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if
            vim.api.nvim_win_is_valid(win_id)
            and vim.api.nvim_win_get_buf(win_id) == buf_id
        then
            return true
        end
    end
    return false
end

--- Get the last accessed buffer not currently visible
--- @return number|nil Buffer ID or nil if none found
local function get_last_accessed_buffer()
    local sorted_buffers = {}
    for _, mark in ipairs(marks) do
        if vim.api.nvim_buf_is_valid(mark.buf_id) then
            local buf_info = vim.fn.getbufinfo(mark.buf_id)[1]
            if buf_info then
                table.insert(
                    sorted_buffers,
                    { buf_id = mark.buf_id, lastused = buf_info.lastused }
                )
            end
        end
    end

    table.sort(sorted_buffers, function(a, b)
        return a.lastused > b.lastused
    end)

    for _, buf_info in ipairs(sorted_buffers) do
        if not is_buffer_visible_in_tab(buf_info.buf_id) then
            return buf_info.buf_id
        end
    end
    return nil
end

--- Get the index of a buffer in the marks list
--- @param buf_id number Buffer ID
--- @return number|nil Index (1-indexed) or nil if not found
local function get_buffer_index(buf_id)
    for i, mark in ipairs(marks) do
        if mark.buf_id == buf_id then
            return i
        end
    end
    return nil
end

--- Find main content window (non-floating)
--- @return number Window ID
local function find_main_window()
    local current_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_config(current_win).relative == "" then
        return current_win
    end
    for _, win_id in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win_id).relative == "" then
            return win_id
        end
    end
    return current_win
end

--- Update marks (buffer list) by removing invalid buffers and adding new ones
--- @return nil
local function update_marks()
    -- Remove invalid buffers
    for idx = #marks, 1, -1 do
        if
            not utils.buffer_is_valid(marks[idx].buf_id, marks[idx].filename)
        then
            table.remove(marks, idx)
        end
    end

    -- Sync filenames for existing marks (handles file renames)
    for _, mark in ipairs(marks) do
        local current_name = vim.api.nvim_buf_get_name(mark.buf_id)
        if current_name ~= "" and current_name ~= mark.filename then
            mark.filename = current_name
        end
    end

    -- Add new buffers
    for _, buf in pairs(vim.api.nvim_list_bufs()) do
        local bufname = utils.get_buffer_name(buf)
        if bufname and utils.buffer_is_valid(buf, bufname) then
            local found = false
            for _, mark in ipairs(marks) do
                if mark.buf_id == buf then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(marks, { filename = bufname, buf_id = buf })
            end
        end
    end

    config = bento.get_config()
    local ordering_metric = config.ordering_metric
    local locked_first = config.locked_first

    if ordering_metric then
        table.sort(marks, function(a, b)
            -- Sort locked buffers first if enabled
            if locked_first then
                local a_locked = bento.is_locked(a.buf_id)
                local b_locked = bento.is_locked(b.buf_id)
                if a_locked and not b_locked then
                    return true
                elseif b_locked and not a_locked then
                    return false
                end
            end

            local a_val = bento.get_ordering_value(a.buf_id)
            local b_val = bento.get_ordering_value(b.buf_id)

            if
                ordering_metric == "filename"
                or ordering_metric == "directory"
            then
                -- String comparison: ascending alphabetical
                if a_val == b_val then
                    return a.buf_id < b.buf_id
                end
                return a_val < b_val
            else
                -- Numeric comparison: descending (most recent first)
                if a_val == b_val then
                    return a.buf_id < b.buf_id
                end
                return a_val > b_val
            end
        end)
    elseif locked_first then
        -- Only sort by locked status if no ordering metric
        table.sort(marks, function(a, b)
            local a_locked = bento.is_locked(a.buf_id)
            local b_locked = bento.is_locked(b.buf_id)
            if a_locked and not b_locked then
                return true
            elseif b_locked and not a_locked then
                return false
            end
            return a.buf_id < b.buf_id
        end)
    end
end

--- Get pagination info for floating UI
--- @return number max_per_page Maximum buffers per page
--- @return number total_pages Total number of pages
--- @return boolean needs_pagination Whether pagination is needed
local function get_pagination_info()
    local max_rendered = config.ui.floating.max_rendered_buffers

    local ui = vim.api.nvim_list_uis()[1]
    local screen_height = ui and ui.height or 24
    local available_height = screen_height - 3

    local effective_max
    if max_rendered and max_rendered > 0 then
        effective_max = math.min(max_rendered, available_height)
    else
        effective_max = available_height
    end

    if effective_max < 1 then
        effective_max = 1
    end

    if #marks <= effective_max then
        return #marks, 1, false
    end

    local total_pages = math.ceil(#marks / effective_max)
    return effective_max, total_pages, true
end

--- Get the slice of marks for the current page
--- @return table[] visible_marks List of marks for current page
--- @return number start_index Starting index (1-indexed)
local function get_page_marks()
    local max_per_page, total_pages, needs_pagination = get_pagination_info()
    if not needs_pagination then
        return marks, 1
    end
    if current_page < 1 then
        current_page = 1
    elseif current_page > total_pages then
        current_page = total_pages
    end
    local start_idx = (current_page - 1) * max_per_page + 1
    local end_idx = math.min(start_idx + max_per_page - 1, #marks)
    local visible_marks = {}
    for i = start_idx, end_idx do
        table.insert(visible_marks, marks[i])
    end
    return visible_marks, start_idx
end

--- Generate pagination indicator string
--- @param width number Total width for the indicator
--- @return string|nil Formatted indicator string or nil if no pagination needed
local function generate_pagination_indicator(width)
    local _, total_pages, needs_pagination = get_pagination_info()
    if not needs_pagination then
        return nil
    end
    local dots = {}
    for i = 1, total_pages do
        if i == current_page then
            table.insert(dots, "●")
        else
            table.insert(dots, "○")
        end
    end
    local indicator = table.concat(dots, " ")
    local indicator_width = vim.fn.strwidth(indicator)
    local padding = math.floor((width - indicator_width) / 2)
    if padding < 0 then
        padding = 0
    end
    return string.rep(" ", padding)
        .. indicator
        .. string.rep(" ", width - padding - indicator_width)
end

--- Get available keys for label assignment (filters out registered keys)
--- @return string[]
local function get_available_keys()
    local available = {}
    for _, key in ipairs(line_keys) do
        if
            key ~= registered_expand_key
            and key ~= registered_last_buffer_key
        then
            table.insert(available, key)
        end
    end
    return available
end

--- Assign smart labels to buffers
--- @param buffers table[] List of buffer marks
--- @param available_keys string[] List of available keys for labels
--- @return table<number, string> Mapping of buffer index to label
local function assign_smart_labels(buffers, available_keys)
    local label_assignment = {}
    local used_labels = {}
    local last_accessed_buf = get_last_accessed_buffer()

    if
        registered_last_buffer_key
        and not config.map_last_accessed
        and last_accessed_buf
    then
        for i, mark in ipairs(buffers) do
            if mark.buf_id == last_accessed_buf then
                label_assignment[i] = registered_last_buffer_key
                used_labels[registered_last_buffer_key] = true
                break
            end
        end
    end

    local char_to_buffers = {}
    for i, mark in ipairs(buffers) do
        if not label_assignment[i] then
            local filename = utils.get_file_name(mark.filename)
            local first_alnum = filename:match("[%w]")
            if first_alnum then
                local char_lower = string.lower(first_alnum)
                if not char_to_buffers[char_lower] then
                    char_to_buffers[char_lower] = {}
                end
                table.insert(char_to_buffers[char_lower], i)
            end
        end
    end

    -- Assign labels to files uniquely identified by their first character
    -- Try lowercase first, then uppercase
    for char, buffer_indices in pairs(char_to_buffers) do
        if #buffer_indices == 1 then
            local i = buffer_indices[1]
            local key_lower = string.lower(char)
            local key_upper = string.upper(char)

            if
                vim.tbl_contains(available_keys, key_lower)
                and not used_labels[key_lower]
            then
                label_assignment[i] = key_lower
                used_labels[key_lower] = true
            elseif
                vim.tbl_contains(available_keys, key_upper)
                and not used_labels[key_upper]
            then
                label_assignment[i] = key_upper
                used_labels[key_upper] = true
            end
        end
    end

    -- For files sharing the same first char
    -- Also try lowercase first, then uppercase
    for char, buffer_indices in pairs(char_to_buffers) do
        if #buffer_indices > 1 then
            local key_lower = string.lower(char)
            local key_upper = string.upper(char)

            for _, i in ipairs(buffer_indices) do
                if not label_assignment[i] then
                    if
                        vim.tbl_contains(available_keys, key_lower)
                        and not used_labels[key_lower]
                    then
                        label_assignment[i] = key_lower
                        used_labels[key_lower] = true
                    elseif
                        vim.tbl_contains(available_keys, key_upper)
                        and not used_labels[key_upper]
                    then
                        label_assignment[i] = key_upper
                        used_labels[key_upper] = true
                    end
                end
            end
        end
    end

    -- Fill remaining buffers with single-character available keys
    local key_idx = 1
    for i = 1, #buffers do
        if not label_assignment[i] then
            while
                key_idx <= #available_keys
                and used_labels[available_keys[key_idx]]
            do
                key_idx = key_idx + 1
            end
            if key_idx <= #available_keys then
                label_assignment[i] = available_keys[key_idx]
                used_labels[available_keys[key_idx]] = true
                key_idx = key_idx + 1
            else
                break
            end
        end
    end

    -- If we run out of single-character keys, generate multi-character
    -- labels for remaining buffers
    if #buffers > #available_keys then
        local multi_char_idx = 1
        for i = 1, #buffers do
            if not label_assignment[i] then
                local label
                repeat
                    local first_idx = math.floor(
                        (multi_char_idx - 1) / #available_keys
                    ) + 1
                    local second_idx = ((multi_char_idx - 1) % #available_keys)
                        + 1
                    label = available_keys[first_idx]
                        .. available_keys[second_idx]
                    multi_char_idx = multi_char_idx + 1
                until not used_labels[label]

                label_assignment[i] = label
                used_labels[label] = true
            end
        end
    end

    return label_assignment
end

--- Calculate window position based on config.ui.floating.position
--- Supports: "top-left", "top-right", "middle-left", "middle-right", "bottom-left", "bottom-right"
--- @param height number Window height
--- @param width number Window width
--- @return number row Row position
--- @return number col Column position
local function calculate_position(height, width)
    local ui = vim.api.nvim_list_uis()[1]
    local floating = config.ui.floating
    local position = floating.position or "middle-right"
    local offset_x = floating.offset_x or 0
    local offset_y = floating.offset_y or 0

    local row, col

    -- Vertical positioning
    if position:match("^top") then
        row = 0
    elseif position:match("^bottom") then
        row = ui.height - height
    else
        row = math.floor((ui.height - height) / 2)
    end

    -- Horizontal positioning
    if position:match("left$") then
        col = 0
    else
        col = ui.width - width + 1
    end

    return row + offset_y, col + offset_x
end

--- Create a transparent floating window
--- @param height number Window height
--- @param width number Window width
--- @return {bufnr: number, win_id: number}
local function create_window(height, width)
    local row, col = calculate_position(height, width)

    local bufnr = vim.api.nvim_create_buf(false, true)
    local win_id = vim.api.nvim_open_win(bufnr, false, {
        relative = "editor",
        style = "minimal",
        width = width,
        height = height,
        row = row,
        col = col,
        border = config.ui.floating.border or "none",
        focusable = false,
    })

    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
    vim.api.nvim_win_set_option(win_id, "wrap", false)
    vim.api.nvim_win_set_option(win_id, "winblend", 0)
    vim.api.nvim_win_set_option(
        win_id,
        "winhighlight",
        "Normal:" .. config.highlights.window_bg
    )

    return { bufnr = bufnr, win_id = win_id }
end

--- Update window size dynamically
--- @param width number New width
--- @param height number New height
--- @return nil
local function update_window_size(width, height)
    if not bento_win_id or not vim.api.nvim_win_is_valid(bento_win_id) then
        return
    end

    local row, col = calculate_position(height, width)

    pcall(vim.api.nvim_win_set_config, bento_win_id, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
    })
end

--- Check if buffer is active (visible in any window)
--- @param buf_id number Buffer ID
--- @return boolean
local function is_buffer_active(buf_id)
    for _, win_id in ipairs(vim.api.nvim_list_wins()) do
        if
            vim.api.nvim_win_is_valid(win_id)
            and vim.api.nvim_win_get_buf(win_id) == buf_id
        then
            return true
        end
    end
    return false
end

--- Check if buffer is the current buffer in the last editor window
--- @param buf_id number Buffer ID
--- @return boolean
local function is_current_buffer(buf_id)
    return last_editor_win
        and vim.api.nvim_win_is_valid(last_editor_win)
        and vim.api.nvim_win_get_buf(last_editor_win) == buf_id
end

--- Generate dash line for a buffer
--- @param buf_id number Buffer ID
--- @return string Dash line string
local function generate_dash_line(buf_id)
    local dash_char = config.ui.floating.dash_char
    return is_current_buffer(buf_id) and (dash_char:rep(2))
        or (" " .. dash_char)
end

--- Save original keymap before overriding
--- @param mode string Vim mode (e.g., "n")
--- @param key string Key to save
--- @return nil
local function save_keymap(mode, key)
    local normalized_key = vim.api.nvim_replace_termcodes(key, true, true, true)

    local keymaps = vim.api.nvim_get_keymap(mode)
    for _, map in ipairs(keymaps) do
        local map_lhs =
            vim.api.nvim_replace_termcodes(map.lhs, true, true, true)
        if map_lhs == normalized_key then
            saved_keymaps[key] = {
                lhs = map.lhs,
                rhs = map.rhs,
                callback = map.callback,
                expr = map.expr == 1,
                noremap = map.noremap == 1,
                silent = map.silent == 1,
                nowait = map.nowait == 1,
                script = map.script == 1,
                buffer = map.buffer,
                desc = map.desc,
            }
            return
        end
    end
    saved_keymaps[key] = nil
end

--- Restore original keymap
--- @param mode string Vim mode (e.g., "n")
--- @param key string Key to restore
--- @return nil
local function restore_keymap(mode, key)
    local original = saved_keymaps[key]

    pcall(vim.keymap.del, mode, key)

    if original then
        local opts = {
            noremap = original.noremap,
            silent = original.silent,
            expr = original.expr,
            nowait = original.nowait,
            script = original.script,
            desc = original.desc,
        }

        if original.callback then
            vim.keymap.set(mode, key, original.callback, opts)
        elseif original.rhs then
            if original.noremap then
                vim.api.nvim_set_keymap(mode, original.lhs, original.rhs, opts)
            else
                opts.remap = true
                vim.keymap.set(mode, original.lhs, original.rhs, opts)
            end
        end
    end

    saved_keymaps[key] = nil
end

--- Clear all selection mode keymaps and restore originals
--- @return nil
local function clear_selection_keymaps()
    for _, key in ipairs(selection_mode_keymaps) do
        restore_keymap("n", key)
    end
    selection_mode_keymaps = {}
end

--- Set global keybindings for selection mode
--- @param smart_labels table<number, string> Mapping of buffer index to label
--- @return nil
local function set_selection_keybindings(smart_labels)
    clear_selection_keymaps()

    local last_accessed_buf = get_last_accessed_buffer()
    local last_accessed_idx = nil

    for i, label in pairs(smart_labels) do
        local mark = marks[i]
        if mark and mark.buf_id == last_accessed_buf then
            last_accessed_idx = i
        end

        -- Skip empty labels
        local is_expand_key = label == registered_expand_key
        local is_last_buffer_label = label == registered_last_buffer_key
        local should_skip = not label
            or label == " "
            or (is_expand_key and not is_last_buffer_label)

        if not should_skip then
            save_keymap("n", label)
            vim.keymap.set("n", label, function()
                require("bento.ui").select_buffer(i)
            end, {
                silent = true,
                desc = "Bento: Select buffer " .. i,
            })
            table.insert(selection_mode_keymaps, label)
        end
    end

    if
        registered_last_buffer_key
        and config.map_last_accessed
        and last_accessed_idx
        and not vim.tbl_contains(
            selection_mode_keymaps,
            registered_last_buffer_key
        )
    then
        save_keymap("n", registered_last_buffer_key)
        vim.keymap.set("n", registered_last_buffer_key, function()
            require("bento.ui").select_buffer(last_accessed_idx)
        end, {
            silent = true,
            desc = "Bento: Select last-accessed buffer",
        })
        table.insert(selection_mode_keymaps, registered_last_buffer_key)
    end

    for action_name, action_config in pairs(config.actions) do
        if action_config.key then
            save_keymap("n", action_config.key)
            vim.keymap.set("n", action_config.key, function()
                require("bento.ui").set_action_mode(action_name)
            end, {
                silent = true,
                desc = "Bento: " .. action_name .. " mode",
            })
            table.insert(selection_mode_keymaps, action_config.key)
        end
    end

    local _, _, needs_floating_pagination = get_pagination_info()
    local needs_tabline_pagination = is_tabline_ui() and #marks > 0
    if needs_floating_pagination or needs_tabline_pagination then
        if registered_prev_page_key then
            save_keymap("n", registered_prev_page_key)
            vim.keymap.set("n", registered_prev_page_key, function()
                require("bento.ui").prev_page()
            end, { silent = true, desc = "Bento: Previous page" })
            table.insert(selection_mode_keymaps, registered_prev_page_key)
        end

        if registered_next_page_key then
            save_keymap("n", registered_next_page_key)
            vim.keymap.set("n", registered_next_page_key, function()
                require("bento.ui").next_page()
            end, { silent = true, desc = "Bento: Next page" })
            table.insert(selection_mode_keymaps, registered_next_page_key)
        end
    end

    if registered_collapse_key then
        save_keymap("n", registered_collapse_key)
        vim.keymap.set("n", registered_collapse_key, function()
            require("bento.ui").collapse_menu()
        end, { silent = true, desc = "Bento: Collapse menu" })
        table.insert(selection_mode_keymaps, registered_collapse_key)
    end
end


--- Render the appropriate collapsed view based on minimal_menu mode
--- @return nil
local function render_collapsed(state)
    if minimal_menu_active == "dashed" then
        render.dashed(state)
    elseif minimal_menu_active == "filename" then
        render.filename_collapsed(state)
    elseif minimal_menu_active == "full" then
        render.expanded(state, true)
    end
end

-- Inject the ui-side helpers the floating render module depends on.
render.setup({
    update_marks = update_marks,
    get_page_marks = get_page_marks,
    get_pagination_info = get_pagination_info,
    update_window_size = update_window_size,
    clear_selection_keymaps = clear_selection_keymaps,
    generate_pagination_indicator = generate_pagination_indicator,
    assign_smart_labels = assign_smart_labels,
    get_available_keys = get_available_keys,
    set_selection_keybindings = set_selection_keybindings,
})

-- Inject the ui-side helpers the tabline render module depends on.
tabline.setup({
    update_marks = update_marks,
    assign_smart_labels = assign_smart_labels,
    get_available_keys = get_available_keys,
    set_selection_keybindings = set_selection_keybindings,
    clear_selection_keymaps = clear_selection_keymaps,
})

--- Menu state machine. Owns the closed/collapsed/expanded lifecycle; its
--- on_enter_* hooks dispatch the right render for the current UI mode. The
--- lifecycle functions below fire transitions instead of flipping is_expanded.
--- (This pass wires transitions only; the remaining module-level state vars
--- still live here and migrate to the instance in a follow-up.)
local State = require("bento.state")
local menu = State.new({
    on_enter_collapsed = function()
        is_expanded = false
        if is_tabline_ui() then
            tabline.minimal(menu)
        else
            render_collapsed(menu)
        end
    end,
    on_enter_expanded = function()
        is_expanded = true
        if is_tabline_ui() then
            tabline.expanded(menu)
        else
            render.expanded(menu)
        end
    end,
    on_enter_closed = function()
        is_expanded = false
    end,
})

--- Close the menu completely
--- @return nil
function M.close_menu()
    menu:close()
    if is_tabline_ui() then
        tabline.restore_settings(menu)
        menu.tabline_active = false
        menu.tabline_start = 1
        current_action = nil
        clear_selection_keymaps()
        return
    end

    -- Floating UI
    if bento_win_id and vim.api.nvim_win_is_valid(bento_win_id) then
        vim.api.nvim_win_close(bento_win_id, true)
    end
    bento_win_id = nil
    bento_bufh = nil
    current_action = nil
    current_page = 1
    clear_selection_keymaps()
end

--- Go to next page
--- @return nil
function M.next_page()
    if is_tabline_ui() then
        if not menu.tabline_active or not is_expanded then
            return
        end
        if menu.tabline_end < #marks then
            menu.tabline_start = menu.tabline_end + 1
            tabline.expanded(menu)
        end
        return
    end

    -- Floating UI
    local _, total_pages, needs_pagination = get_pagination_info()
    if not needs_pagination then
        return
    end
    if current_page < total_pages then
        current_page = current_page + 1
        if is_expanded then
            render.expanded(menu)
        else
            render_collapsed(menu)
        end
    end
end

--- Go to previous page
--- @return nil
function M.prev_page()
    if is_tabline_ui() then
        if not menu.tabline_active or not is_expanded then
            return
        end
        if menu.tabline_start > 1 then
            menu.tabline_start = tabline.prev_page_start(menu, menu.tabline_start)
            tabline.expanded(menu)
        end
        return
    end

    -- Floating UI
    local _, _, needs_pagination = get_pagination_info()
    if not needs_pagination then
        return
    end
    if current_page > 1 then
        current_page = current_page - 1
        if is_expanded then
            render.expanded(menu)
        else
            render_collapsed(menu)
        end
    end
end

--- Toggle menu (create or close)
--- @param force_create boolean|nil If true, force create menu even without minimal mode
--- @return nil
function M.toggle_menu(force_create)
    M.setup_state()

    if is_tabline_ui() then
        if menu.tabline_active then
            M.close_menu()
            return
        end

        local cur_win = vim.api.nvim_get_current_win()
        local cfg = vim.api.nvim_win_get_config(cur_win)
        if cfg.relative == "" then
            last_editor_win = cur_win
        else
            for _, w in ipairs(vim.api.nvim_list_wins()) do
                local c = vim.api.nvim_win_get_config(w)
                if c.relative == "" then
                    last_editor_win = w
                    break
                end
            end
        end

        update_marks()
        if #marks == 0 then
            notify.debug("No buffers to display")
            return
        end

        tabline.save_settings(menu)
        menu.tabline_active = true
        menu.tabline_start = 1
        menu:open()
        return
    end

    -- Floating UI
    if bento_win_id and vim.api.nvim_win_is_valid(bento_win_id) then
        M.close_menu()
        return
    end

    local cur_win = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(cur_win)
    if cfg.relative == "" then
        last_editor_win = cur_win
    else
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            local c = vim.api.nvim_win_get_config(w)
            if c.relative == "" then
                last_editor_win = w
                break
            end
        end
    end

    update_marks()
    local total_buffers = #marks

    if total_buffers == 0 then
        notify.debug("No buffers to display")
        return
    end

    if not minimal_menu_active and not force_create then
        return
    end

    local padding = config.ui.floating.label_padding or 1
    local initial_width = 2 + 2 * padding
    local win_info = create_window(total_buffers, initial_width)
    bento_win_id = win_info.win_id
    bento_bufh = win_info.bufnr

    current_page = 1
    -- menu:open() enters `collapsed`; the on_enter hook renders via
    -- render_collapsed(menu), which is a no-op when minimal_menu_active is nil,
    -- preserving the old "force_create with no minimal mode = window only".
    menu:open()
end

--- Expand menu to show labels and names
--- @return nil
function M.expand_menu()
    -- Warn if no actions are registered
    if vim.tbl_isempty(config.actions) then
        warn_once(
            "no_actions_registered",
            "No actions registered. Call api.register_action() to register actions."
        )
    end

    -- Warn if no collapse key is registered
    if not registered_collapse_key then
        warn_once(
            "no_collapse_key",
            "No collapse key registered. Call api.register_collapse_key() or use CursorMoved to collapse."
        )
    end

    if is_tabline_ui() then
        if not menu.tabline_active then
            return
        end
        current_action = config.default_action
        menu:expand()
        return
    end

    -- Floating UI
    if not bento_win_id or not vim.api.nvim_win_is_valid(bento_win_id) then
        return
    end

    current_action = config.default_action
    menu:expand()
end

--- Collapse menu back to minimal view
--- @return nil
function M.collapse_menu()
    M.setup_state()

    if is_tabline_ui() then
        if not menu.tabline_active then
            return
        end
        current_action = nil
        menu.tabline_start = 1
        menu:collapse()
        return
    end

    -- Floating UI
    if not bento_win_id or not vim.api.nvim_win_is_valid(bento_win_id) then
        return
    end

    if not minimal_menu_active then
        M.close_menu()
        return
    end

    current_action = nil
    current_page = 1
    menu:collapse()
end

--- Select buffer by index
--- @param idx number Buffer index in marks list (1-indexed)
--- @return nil
function M.select_buffer(idx)
    local mark = marks[idx]
    if not mark then
        return
    end

    local action_to_use = current_action or config.default_action
    if not action_to_use then
        warn_once(
            "no_default_action",
            "No default action set. Call api.set_default_action() after registering actions."
        )
        return
    end

    local action_config = config.actions[action_to_use]

    if not action_config or not action_config.action then
        warn_once(
            "action_not_registered_" .. action_to_use,
            "Action '"
                .. action_to_use
                .. "' is not registered. Call api.register_action() to register it."
        )
        return
    end

    if action_to_use == "open" then
        bento.record_access(mark.buf_id)

        local target_win = vim.api.nvim_get_current_win()

        if vim.api.nvim_win_get_config(target_win).relative ~= "" then
            target_win = last_editor_win
                    and vim.api.nvim_win_is_valid(last_editor_win)
                    and last_editor_win
                or find_main_window()
        end

        vim.api.nvim_set_current_win(target_win)
    end

    local success, err = pcall(action_config.action, mark.buf_id, mark.filename)
    if not success then
        notify.error("Action failed: " .. tostring(err))
    else
        current_page = 1
        menu.tabline_start = 1
    end
end

--- Set action mode
--- @param action_name string Name of the action (e.g., "open", "delete", "vsplit")
--- @return nil
function M.set_action_mode(action_name)
    if not config.actions[action_name] then
        notify.error("Unknown action: " .. action_name)
        return
    end

    current_action = action_name
    notify.info("Action mode: " .. action_name)

    if is_tabline_ui() then
        tabline.expanded(menu)
    else
        render.expanded(menu)
    end
end

--- Refresh menu if open
--- @return nil
function M.refresh_menu()
    M.setup_state()

    if is_tabline_ui() then
        if not menu.tabline_active then
            return
        end

        update_marks()

        if #marks == 0 then
            M.close_menu()
            return
        end

        if is_expanded then
            tabline.expanded(menu)
        else
            tabline.minimal(menu)
        end
        return
    end

    -- Floating UI
    if not bento_win_id or not vim.api.nvim_win_is_valid(bento_win_id) then
        -- Opinionated "always shown": when a minimal menu is configured, a
        -- refresh with no live window reopens it (rather than no-op'ing), so
        -- the dashed list reappears after close / buffer churn. Needs buffers.
        if minimal_menu_active then
            update_marks()
            if #marks > 0 then
                M.toggle_menu()
            end
        end
        return
    end

    update_marks()

    if #marks == 0 then
        M.close_menu()
        return
    end

    if is_expanded then
        render.expanded(menu)
    else
        if minimal_menu_active then
            render_collapsed(menu)
        end
    end
end

--- Cycle the minimal menu mode dynamically
--- Cycles through: nil -> "dashed" -> "filename" -> "full"
--- Note: This function is ignored when ui.mode = "tabline"
--- @return nil
function M.cycle_minimal_menu()
    M.setup_state()

    if is_tabline_ui() then
        notify.warn("Minimal menu toggle is not available for tabline UI")
        return
    end

    -- Cycle order: disabled -> "dashed" -> "filename" -> "full" -> disabled.
    -- `false` stands in for the disabled state so the list has no nil hole
    -- (a leading nil would make `#modes` unreliable).
    local modes = { false, "dashed", "filename", "full" }
    local current_idx = 1
    for i, mode in ipairs(modes) do
        if (minimal_menu_active or false) == mode then
            current_idx = i
            break
        end
    end

    local next_idx = (current_idx % #modes) + 1
    minimal_menu_active = modes[next_idx] or nil

    local mode_name = minimal_menu_active or "disabled"
    notify.debug("Minimal menu: " .. mode_name)

    if minimal_menu_active then
        if not bento_win_id or not vim.api.nvim_win_is_valid(bento_win_id) then
            M.toggle_menu()
        else
            if not is_expanded then
                render_collapsed(menu)
            end
        end
    else
        if
            bento_win_id
            and vim.api.nvim_win_is_valid(bento_win_id)
            and not is_expanded
        then
            M.close_menu()
        end
    end
end

--- Open and expand the menu (convenience function)
--- Always enters the active (expanded) state. If the menu is already open it
--- stays open and is re-expanded; it is never toggled closed by this call,
--- unless `ui.floating.toggle_on_reexpand` is set (legacy behaviour).
--- @return nil
function M.open_menu()
    M.setup_state()

    local menu_open = bento_win_id and vim.api.nvim_win_is_valid(bento_win_id)

    if menu_open and config.ui.floating.toggle_on_reexpand then
        M.close_menu()
        return
    end

    if not menu_open then
        M.toggle_menu(true)
    end
    M.expand_menu()
end

--- Set the registered expand menu key (internal setter, use bento.api for registration)
--- @param key string The key to set
--- @return nil
function M.set_registered_expand_key(key)
    registered_expand_key = key
end

--- Set the registered last buffer key (internal setter, use bento.api for registration)
--- @param key string The key to set
--- @return nil
function M.set_registered_last_buffer_key(key)
    registered_last_buffer_key = key
end

--- Get the registered expand menu key
--- @return string|nil
function M.get_registered_expand_key()
    return registered_expand_key
end

--- Get the registered last buffer key
--- @return string|nil
function M.get_registered_last_buffer_key()
    return registered_last_buffer_key
end

--- Set the registered collapse menu key (internal setter, use bento.api for registration)
--- @param key string The key to set
--- @return nil
function M.set_registered_collapse_key(key)
    registered_collapse_key = key
end

--- Get the registered collapse menu key
--- @return string|nil
function M.get_registered_collapse_key()
    return registered_collapse_key
end

--- Set the registered next page key (internal setter, use bento.api for registration)
--- @param key string The key to set
--- @return nil
function M.set_registered_next_page_key(key)
    registered_next_page_key = key
end

--- Get the registered next page key
--- @return string|nil
function M.get_registered_next_page_key()
    return registered_next_page_key
end

--- Set the registered prev page key (internal setter, use bento.api for registration)
--- @param key string The key to set
--- @return nil
function M.set_registered_prev_page_key(key)
    registered_prev_page_key = key
end

--- Get the registered prev page key
--- @return string|nil
function M.get_registered_prev_page_key()
    return registered_prev_page_key
end

return M
