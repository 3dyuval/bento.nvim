--- Bento menu state — a single class that owns the whole menu lifecycle.
---
--- Replaces ui.lua's scattered module-level locals (`is_expanded`, window
--- handles, `minimal_menu_active`, pagination, tabline flags) with one
--- `bento.State` instance. The menu is an ad-hoc state machine
--- (closed/collapsed/expanded) and every former upvalue is a field on `self`;
--- the former free helper functions are read-only methods on `self`.
---
---   closed  --open-->  collapsed  --expand-->  expanded
---      ^------close------- |  ^---collapse-------- |
---      '------------- close ---------------------- '
---
--- Config is resolved live via self:config() (so :Lazy reload / runtime opts
--- take effect); marks are owned by bento core, referenced not copied.
---
--- @class bento.State
--- @field current string current fsm state (closed | collapsed | expanded)
--- @field hooks table<string, fun()> on_enter_<state> / on_leave_<state>
--- @field win_id number|nil floating window handle
--- @field bufh number|nil floating buffer handle
--- @field last_editor_win number|nil window to return focus to
--- @field minimal_mode string|nil resolved collapsed render mode (latched)
--- @field current_action string|nil active action (expanded only)
--- @field page number floating pagination page (1-indexed)
--- @field tabline_active boolean whether the tabline UI is currently rendered
--- @field tabline_start number first buffer index shown in tabline (1-indexed)
--- @field tabline_end number last buffer index shown in tabline (1-indexed)
--- @field saved_tabline string|nil original &tabline, restored on close
--- @field saved_showtabline number|nil original &showtabline, restored on close
--- @field smart_labels table<number, string> cached per-buffer labels (tabline)
local M = {}
M.__index = M

--- event -> { from-state -> to-state }. An event is legal from a state only if
--- that state appears as a key here; firing an illegal event is a silent no-op.
local TRANSITIONS = {
  open = { closed = "collapsed" },
  expand = { collapsed = "expanded" },
  collapse = { expanded = "collapsed" },
  close = { collapsed = "closed", expanded = "closed" },
}

--- Create a bento menu state instance.
--- @param hooks? table<string, fun()> on_enter_<state>/on_leave_<state> callbacks
--- @return bento.State
function M.new(hooks)
  return setmetatable({
    current = "closed",
    hooks = hooks or {},
    win_id = nil,
    bufh = nil,
    last_editor_win = nil,
    minimal_mode = nil,
    current_action = nil,
    page = 1,
    tabline_active = false,
    tabline_start = 1,
    tabline_end = 1,
    saved_tabline = nil,
    saved_showtabline = nil,
    smart_labels = {},
  }, M)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Live config / marks accessors (owned elsewhere, read through self).
-- ─────────────────────────────────────────────────────────────────────────

--- Resolve the current plugin config fresh (never cached — see SPEC C-OWN2).
--- @return table
function M:config()
  return require("bento").get_config()
end

--- The bento core marks list (buffers). Referenced, not owned (SPEC C-OWN3).
--- @return table[]
function M:marks()
  return require("bento").marks
end

-- ─────────────────────────────────────────────────────────────────────────
-- State machine.
-- ─────────────────────────────────────────────────────────────────────────

--- Fire an event; no-op (false) if illegal from the current state. On a real
--- transition runs on_leave_<from> then on_enter_<to>.
--- @param event string
--- @return boolean transitioned
function M:fire(event)
  local to = TRANSITIONS[event] and TRANSITIONS[event][self.current]
  if not to then
    return false
  end
  local from = self.current
  require("bento.notify").debug(
    ("menu: %s --%s--> %s"):format(from, event, to)
  )
  local leave = self.hooks["on_leave_" .. from]
  local enter = self.hooks["on_enter_" .. to]
  if leave then
    leave(self)
  end
  self.current = to
  if enter then
    enter(self)
  end
  return true
end

function M:is_closed()
  return self.current == "closed"
end

function M:is_open()
  return self.current ~= "closed"
end

function M:is_expanded()
  return self.current == "expanded"
end

function M:open()
  return self:fire("open")
end

function M:expand()
  return self:fire("expand")
end

function M:collapse()
  return self:fire("collapse")
end

function M:close()
  return self:fire("close")
end

-- ─────────────────────────────────────────────────────────────────────────
-- Read-only query methods (formerly free "pure" helpers in ui.lua). They read
-- from self / the editor but never mutate self.
-- ─────────────────────────────────────────────────────────────────────────

--- Find the main (non-floating) content window.
--- @return number win_id
function M:find_main_window()
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

--- Whether a buffer is visible in any window of the current tabpage.
--- @param buf_id number
--- @return boolean
function M:is_buffer_visible_in_tab(buf_id)
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

--- Whether a buffer is visible in any window anywhere.
--- @param buf_id number
--- @return boolean
function M:is_buffer_active(buf_id)
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

--- Whether a buffer is the current buffer in the tracked last-editor window.
--- @param buf_id number
--- @return boolean
function M:is_current_buffer(buf_id)
  return self.last_editor_win ~= nil
    and vim.api.nvim_win_is_valid(self.last_editor_win)
    and vim.api.nvim_win_get_buf(self.last_editor_win) == buf_id
end

--- Index of a buffer within the marks list, or nil.
--- @param buf_id number
--- @return number|nil
function M:buffer_index(buf_id)
  for i, mark in ipairs(self:marks()) do
    if mark.buf_id == buf_id then
      return i
    end
  end
  return nil
end

--- Most-recently-used buffer in marks that is NOT currently visible, or nil.
--- @return number|nil buf_id
function M:last_accessed_buffer()
  local sorted = {}
  for _, mark in ipairs(self:marks()) do
    if vim.api.nvim_buf_is_valid(mark.buf_id) then
      local info = vim.fn.getbufinfo(mark.buf_id)[1]
      if info then
        table.insert(sorted, { buf_id = mark.buf_id, lastused = info.lastused })
      end
    end
  end
  table.sort(sorted, function(a, b)
    return a.lastused > b.lastused
  end)
  for _, info in ipairs(sorted) do
    if not self:is_buffer_visible_in_tab(info.buf_id) then
      return info.buf_id
    end
  end
  return nil
end

--- The dash-line string for a buffer (double dash if current, else padded).
--- @param buf_id number
--- @return string
function M:dash_line(buf_id)
  local dash_char = self:config().ui.floating.dash_char
  return self:is_current_buffer(buf_id) and dash_char:rep(2)
    or (" " .. dash_char)
end

--- Floating window position for the given size, honouring config.ui.floating
--- position/offset. @return row, col
function M:window_position(height, width)
  local ui = vim.api.nvim_list_uis()[1]
  local floating = self:config().ui.floating
  local position = floating.position or "middle-right"
  local offset_x = floating.offset_x or 0
  local offset_y = floating.offset_y or 0

  local row, col
  if position:match("^top") then
    row = 0
  elseif position:match("^bottom") then
    row = ui.height - height
  else
    row = math.floor((ui.height - height) / 2)
  end
  if position:match("left$") then
    col = 0
  else
    col = ui.width - width + 1
  end
  return row + offset_y, col + offset_x
end

--- Pagination math for the floating UI.
--- @return number max_per_page, number total_pages, boolean needs_pagination
function M:pagination_info()
  local marks = self:marks()
  local max_rendered = self:config().ui.floating.max_rendered_buffers
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
  return effective_max, math.ceil(#marks / effective_max), true
end

return M
