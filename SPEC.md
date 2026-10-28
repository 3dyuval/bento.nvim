# Bento menu — state & config SPEC

Design contract for the menu lifecycle. Written before retiring `ui.lua`'s
scattered boolean state (`is_expanded`, window handles, `minimal_menu_active`,
pagination, tabline flags) in favour of a single ad-hoc state machine
(`state.lua` — transition table + `fire`, no generic engine). This is the
source of truth the rewrite must
preserve; it captures *current* behaviour (observed in `ui.lua`), not an
idealised one — divergences are called out as `[CHANGE]`.

## Vision

One encapsulated unit owns menu state and the actions that transition it.
Callers (`api.lua`, `actions.lua`, `init.lua`) speak only in **events**
(`open`, `expand`, `collapse`, `close`, `select`, `page`) and **getters**; they
never read or write raw state. Every transition is **guarded** — the guard
reads context, so illegal moves are no-ops by construction rather than by
ad-hoc `if` checks sprinkled through each function.

## Layer 1 — States

The menu is always in exactly one state. `is_expanded` is subsumed by the
state name; it is no longer a separate flag.

```
state        meaning                                         window?
───────────  ──────────────────────────────────────────────  ───────
closed       no menu shown                                    none
collapsed    minimal menu (dashed | filename | full)          open
expanded     full menu: labels + filenames, selection keys    open
```

```
S1: `closed` is the initial state and the only state with no window /
    no active tabline.                                                   [HOLDS]
S2: `collapsed` renders per the resolved minimal-menu mode (Layer 4).    [HOLDS]
S3: `expanded` additionally binds per-buffer selection keymaps and sets
    `current_action = default_action`.                                   [HOLDS]
S4: There are TWO parallel UIs — floating and tabline (config.ui.mode).
    The state names are shared; only the render/teardown actions differ.
    The machine must branch on mode inside the enter/leave actions, not
    duplicate the state graph.                                           [HOLDS]
```

## Layer 2 — Events & transitions

```
event      from                 to          guard (no-op unless true)
─────────  ───────────────────  ──────────  ───────────────────────────────
open       closed               collapsed   #marks > 0 AND (minimal_menu
                                            resolved OR force) (G1)
expand     collapsed            expanded    window valid (floating) OR
                                            tabline_active (tabline)
collapse   expanded             collapsed   window valid; if NO minimal mode
                                            -> close instead (G2)
close      collapsed|expanded   closed      always
select     expanded             (stays)     mark[idx] exists AND action set
page ±     collapsed|expanded   (stays)     needs_pagination (G3)
```

```
T1: `toggle` is not a primitive event — it is `close` if open, else `open`
    (observed in M.toggle_menu). Keep it as a caller-side convenience that
    dispatches one of the two primitives.                                [HOLDS]
T2: `open` then `expand` is the "open_menu" path (M.open_menu): open collapsed,
    then expand. With `toggle_on_reexpand`, re-invoking open_menu while open
    closes instead (Layer 4 C2).                                         [HOLDS]
T3: self-transitions (`select`, `page`) do NOT change state; they re-render
    in place. They must be modelled as guarded actions, not state changes.[HOLDS]
G2: collapse with `minimal_menu == nil` degrades to `close` — there is no
    minimal view to fall back to (M.collapse_menu L1825).                 [HOLDS]
```

## Layer 3 — Context (owned by the machine)

All of `ui.lua`'s module-level `local`s move into the machine's context. Guards
and actions read/write `ctx.*`; nothing lives as a free upvalue.

```
field                  was (ui.lua)            role
─────────────────────  ──────────────────────  ──────────────────────────────
ctx.win_id             bento_win_id            floating window handle
ctx.bufh               bento_bufh              floating buffer handle
ctx.last_editor_win    last_editor_win         window to return focus to
ctx.minimal_mode       minimal_menu_active     resolved collapsed render mode
ctx.current_action     current_action          active action (expanded only)
ctx.page               current_page            floating pagination (1-indexed)
ctx.tabline.*          tabline_active,         tabline mode runtime
                       saved_tabline,
                       saved_showtabline,
                       start_idx, end_idx
ctx.keys.*             registered_expand_key,  registered keymaps (set-once;
                       …_collapse_key, etc.    arguably config, see C3)
ctx.caches.*           smart_labels_cache,     render caches
                       warnings_shown
```

```
C-OWN1: `is_expanded` is DELETED — derive from `state == "expanded"`.    [CHANGE]
C-OWN2: `config` is not cached on ctx; it is resolved fresh via
        bento.get_config() at action time (ui.lua re-fetches it ~10x —
        preserve that liveness so :Lazy reload / runtime opts take effect).[HOLDS]
C-OWN3: `marks` stays owned by bento core (require("bento").marks); the
        machine reads it, does not own it.                               [HOLDS]
```

## Layer 4 — Config resolution (menu mode options)

Resolution precedence per the layered-config model: first defined source wins.
Sources, highest → lowest:

```
          A              R              D
          (api runtime)  (resolved cfg) (plugin default)
  --------+--------------+--------------+----------------
  minimal_menu          | —            | ui.floating.minimal_menu | nil
  toggle_on_reexpand    | —            | ui.floating.toggle_...   | true
  default_action        | set_default_action | config.default_action | nil
```

`R(x) = A(x) ?? D(x)` — today only `D` (static config) + `A` for
`default_action` (set via api). No env/file layer (not a CLI tool).

```
C1: `minimal_mode` is resolved ONCE on first open into ctx.minimal_mode
    (setup_state L119: only sets if nil), then mutated by `cycle_minimal_menu`.
    So after first open it is runtime state (A-tier), not re-read from config.
    The machine must honour this latch — don't re-resolve from config every
    open or cycling is lost.                                             [HOLDS]
C2: `toggle_on_reexpand` gates open_menu: if true and already open, the expand
    key closes the menu instead of re-expanding (M.open_menu L2013).     [HOLDS]
C3: registered_* keys are resolved at setup (api.register_*), never change at
    runtime. They are config-tier but stored in ctx for locality.        [HOLDS]
```

## Public API (must be preserved)

`state.lua` must expose every function `ui.lua` did, since `api.lua`,
`actions.lua`, `init.lua` call them. Grouped by kind:

```
lifecycle (events):  open_menu toggle_menu expand_menu collapse_menu
                     close_menu refresh_menu setup_state
actions (guarded):   select_buffer set_action_mode cycle_minimal_menu
                     next_page prev_page
getters/setters:     set_last_editor_win
                     {set,get}_registered_{expand,last_buffer,collapse,
                                           next_page,prev_page}_key
```

```
API1: signatures and names stay identical — this is a drop-in replacement so
      callers need no changes in step 1. Renaming is a later, separate step.[HOLDS]
API2: tabline mode must keep working through the same entry points.       [HOLDS]
```

## Migration (strangler, not big-bang)

```
M1: build state.lua as a drop-in with the full API; ui.lua delegates to it.
M2: move concerns one at a time (lifecycle → context → render actions →
    tabline), testing each via dev=true + :Lazy reload.
M3: when ui.lua is an empty shim, delete it and repoint requires.
```

## Files

| File | Role |
|---|---|
| `lua/bento/state.lua` | Bento menu machine (ad-hoc): states, events, guards, context, render/teardown actions. Target home for all of ui.lua |
| `lua/bento/ui.lua` | BEING RETIRED — current monolith; shrinks to a shim then deleted |
| `lua/bento/actions.lua` | Buffer actions (open/delete/split…); calls collapse/refresh |
| `lua/bento/api.lua` | Public API surface; registers keys, dispatches events |
| `lua/bento/init.lua` | Core: marks, metrics, config defaults, autocmds |
