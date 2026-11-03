# Bento providers — entry source & vessel SPEC

Design contract for decoupling Bento along two axes: **what the entries are**
(the source) and **what they are rendered into** (the vessel). Written before
the rework, in the style of `SPEC.md`: it captures the *target* contract the
implementation must satisfy, labels invariants `[HOLDS]` (true today, must stay
true) / `[CHANGE]` (intentional divergence) / `[NEW]` (introduced here).

Prereq: the menu state machine (`state.lua`, see `SPEC.md`). The single
`State:marks()` accessor is the seam this spec generalises.

## Vision

Bento is a **presentation layer**: it renders a list of entries into a vessel
(scratch buffer / tabline / real buffer / file), assigns labels, and wires
labels to actions. It owns none of the data. A **provider** owns the data and
answers everything source-specific. The built-in buffer behaviour (open
buffers, locks, frecency, LRU enforcement) is itself a provider named `marks` —
not privileged core. `harpoon` is the reference provider and proves the
interface, but the UI must not hard-require it.

```
                 ┌─────────────────────────────────────────┐
   UI (vessel) ──┤  reads entries, paints labels, dispatches │
   state.lua     │  actions — knows nothing about buffers    │
                 └───────────────────┬─────────────────────┘
                                     │ provider interface
                 ┌───────────────────┼───────────────────┐
              ┌──┴──┐             ┌───┴───┐           ┌────┴────┐
              │marks│             │harpoon│           │commands │  (future)
              └─────┘             └───────┘           └─────────┘
          open buffers,       project-pinned       {label,payload}
          locks, frecency     paths + cursor        run on select
```

## Layer 0 — Entry shape

```
An entry is: { label, kind, payload }                                     [NEW]
  label    string   display text (provider-supplied; NOT derived from a path
                     by the UI — the UI no longer calls get_display_names)
  kind     string   the owning provider's name ("marks" | "harpoon" | ...)
  payload  table    provider-private; e.g. { path, buf_id } for marks,
                     { path, row, col } for harpoon, { cmd } for commands
```

```
E1: The UI reads only `label` and asks the provider for everything else
    (visual state, actions). It never inspects `payload`.                 [NEW]
E2: `kind` is the routing key: persistence, actions, and visual-state
    queries all dispatch on it to the owning provider.                    [NEW]
E3: Today every entry is {filename, buf_id} with a live buffer. Under the
    `marks` provider that becomes payload={path,buf_id}; buf_id may be
    absent (-1) for providers whose entries are not open buffers.         [CHANGE]
```

## Layer 1 — Provider interface

A provider is a table implementing:

```
entries()              -> entry[]      the current list (ordered)
state_for(entry)       -> {modified?, active?, current?, locked?} | nil
actions_for(entry)     -> { name -> fn(entry) }   what can be done to it
persist()              -> nil          save own durable state (may be no-op)
restore()              -> nil          load own durable state (may be no-op)
invalidate_on()        -> string[]     autocmd events that should refill;
                                       [] means "only on explicit mutation"
```

```
P1: `marks` provider = today's init.lua buffer logic, moved verbatim behind
    this interface. state_for reads modified/active/current/locked from the
    live buffer. invalidate_on = {BufAdd,BufDelete,BufEnter,WinEnter,...}.  [CHANGE]
P2: `harpoon` provider: entries() maps harpoon:list() paths to entries with
    buf_id = bufnr(path) (-1 if closed). state_for returns a buffer state
    only when open, else a plain inactive stub. invalidate_on = {} (refill
    on harpoon mutation + on vessel open). persist/restore delegate to
    harpoon's own stdpath JSON — Bento stores nothing.                     [NEW]
P3: Persistence is per-provider and the UI triggers none of it generically.
    "Which vessel / which durability" is the provider's choice, not core's.  [NEW]
P4: The UI depends on the provider INTERFACE, never on `harpoon` concretely.
    harpoon absent -> harpoon provider simply unavailable; marks still works. [NEW]
```

## Layer 2 — Vessel axis (deferred)

The vessel (scratch buffer today; real buffer / file later) is a second,
independent axis. This spec fixes the *entry/provider* axis first and keeps the
existing scratch-buffer vessel unchanged. Vessel-as-provider-concern is noted
as future work, not implemented here.

```
V1: Current vessel = ephemeral scratch buffer, rewritten each render
    (render.lua nvim_buf_set_lines 0,-1). Unchanged by this spec.          [HOLDS]
V2: A durable vessel (real buffer / project file) needs a reconcile contract
    instead of wholesale rewrite. OUT OF SCOPE here.                        [CHANGE-LATER]
```

## Layer 3 — Migration invariants (what must not regress)

```
M1: With only the `marks` provider active and default config, behaviour is
    byte-identical to pre-rework: same labels, same ordering, same locks,
    same frecency LRU enforcement, same tabline/floating render.           [HOLDS]
M2: `State:marks()` returns `active_provider():entries()`; no other module
    reaches `require("bento").marks` directly.                             [CHANGE]
M3: Actions (open/delete/vsplit/split/lock) are resolved via
    `active_provider():actions_for(entry)`, not the global actions table.
    `delete` differs by provider (wipe buffer vs unpin).                   [CHANGE]
M4: render.lua guards every buffer-API call behind state_for(); an entry
    with no live buffer renders as plain inactive, never errors.           [NEW]
```

## Open questions (resolve before coding each)

- Q1: Does `open` carry harpoon's cursor (row,col)? (harpoon payload has it;
  marks `open` ignores position today.)
- Q2: Provider switching UX — a toggle key? a command? config default?
- Q3: `marks` provider persistence stays on `vim.g`+session, or also moves to
  a stdpath file for parity with harpoon?
