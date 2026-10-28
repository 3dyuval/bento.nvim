--- Bento menu state machine.
---
--- Models the floating/tabline menu lifecycle as three states and the events
--- that move between them, replacing the scattered `is_expanded` boolean writes
--- in ui.lua. The FSM itself (vendored lua-fsm) is pure; rendering/teardown is
--- supplied by the caller as `on_enter_*` / `on_leave_*` hooks so this module
--- stays UI-agnostic and reusable.
---
---   closed  --open-->  collapsed  --expand-->  expanded
---      ^------close------- |  ^---collapse-------- |
---      '------------- close ---------------------- '
---
--- @class bento.State
--- @field fsm table underlying lua-fsm instance
local M = {}

local fsm = require("bento.fsm")

--- Event/transition table: from any open state you can close; collapsed can
--- expand; expanded can collapse; closed can open.
local EVENTS = {
  { name = "open", from = "closed", to = "collapsed" },
  { name = "expand", from = "collapsed", to = "expanded" },
  { name = "collapse", from = "expanded", to = "collapsed" },
  { name = "close", from = { "collapsed", "expanded" }, to = "closed" },
}

--- Create a bento menu state machine.
--- @param hooks? table<string, fun()> optional on_enter_<state>/on_leave_<state>
---   callbacks, e.g. { on_enter_collapsed = render_collapsed, ... }. lua-fsm
---   reads these from cfg.callbacks, so they are passed through there.
--- @return bento.State
function M.new(hooks)
  local cfg = { initial = "closed", events = EVENTS, callbacks = hooks or {} }
  return setmetatable({ fsm = fsm.create(cfg) }, { __index = M })
end

--- @return string current state name (closed | collapsed | expanded)
function M:current()
  return self.fsm.current
end

function M:is_closed()
  return self.fsm.current == "closed"
end

function M:is_open()
  return self.fsm.current ~= "closed"
end

function M:is_expanded()
  return self.fsm.current == "expanded"
end

--- Transition helpers. Each is a no-op (NO_TRANSITION) if the event is not
--- valid from the current state, mirroring the guards the old code did inline.
function M:open()
  if self.fsm.can("open") then
    self.fsm.open()
  end
end

function M:expand()
  if self.fsm.can("expand") then
    self.fsm.expand()
  end
end

function M:collapse()
  if self.fsm.can("collapse") then
    self.fsm.collapse()
  end
end

function M:close()
  if self.fsm.can("close") then
    self.fsm.close()
  end
end

return M
