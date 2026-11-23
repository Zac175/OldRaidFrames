# OldRaidFrames 1.1.0

Faithful recreation of the **pre-1.15.9 Classic Era compact raid frames** (the
Wrath-derived CUF look), with a full options panel, pullout-style Main Tank
target/ToT rows, pet frames, party frames, combined flow mode, incoming-heal
prediction, and burial of Blizzard's replacement raid and party frames.

**Game versions:** Classic Era, TBC Anniversary, WoW Forever and Retail — one
folder, the same files.

## Use

- **`/orf`** — options panel: every setting is clickable (checkboxes, sliders,
  cycling dropdowns, edit boxes), modeled on the old Raid Profiles config.
  ESC closes it.
- **Moving**: click **Unlock (move frames)** in the panel (or `/orf unlock`),
  drag the green overlay anywhere, then Lock. Position is saved.
- **Edit Mode (1.15.9)**: opening Blizzard's Edit Mode unlocks the frames
  automatically — drag the green overlay to move them, **right-click** it to
  open the options panel, and closing Edit Mode restores the lock. The frames
  themselves are not Edit Mode *systems* (custom secure headers can't be, and
  Edit Mode layout switching would fight the profile system), so they don't
  appear in its grid or snapping — position lives in your OldRaidFrames
  profile instead.
- **`/orf profile`** — profile manager (see below).
- `/orf help` — full slash command list (everything in the panel also has a
  slash command).

## Profiles

Settings live in named, **account-wide profiles** (AceDB-3.0). Every character
picks which one it uses, so one layout can serve all your toons — or each toon
can have its own.

- **Window**: `/orf profile`, or the **Profiles...** button at the bottom of
  the options panel. It lists every profile (with how many characters use
  each), and clicking one switches this character to it immediately — no
  reload.
- **Default**: fresh installs and upgrades both land on a profile called
  `Default`. If you already had OldRaidFrames settings, they *become*
  `Default` on first login, and every alt you log into afterwards picks it up
  automatically.
- **Manage**: Create & Use (new profile from defaults), Copy (pull another
  profile's settings into the active one), Delete, Reset active profile.
  Slash: `/orf profile list | set <name> | new <name> | copy <name> |
  delete <name> | reset`.
- **Share by string**: **Export active** fills the share box with a string
  (Ctrl+C to copy); paste someone else's in and press **Import**. Strings
  start with `!ORF1!` and are AceSerializer data.
- **Share in game**: type a character name into *Send active to* and press
  **Send**, or press **Raid** to offer it to the whole raid.
  Slash: `/orf profile send <player | raid | party | guild> [profile]`.
  The receiver gets a prompt with **Accept**, **Accept & Use** or **Decline**
  — nothing is written to their settings until they choose, and the incoming
  profile is imported under a non-clobbering name (`Healing (Zac)`).
- **Safety**: incoming profiles are rebuilt key-by-key against the addon's
  own defaults — unknown keys are dropped, wrong types replaced, anchors and
  enums validated, numbers clamped to slider ranges, and filter lists capped.
  A malformed or hostile string can't do more than give you odd (but legal)
  settings.

## Features

- **Party frames** — the same frames for a 5-player group, under a gold
  "Party" title where Group 1 stands in a raid (so nothing jumps when the
  party becomes a raid). **Display Party Frames** turns them on or off,
  **Show Yourself in Party** puts you among them or not; `/orf party`,
  `/orf partyplayer`. With Display Pets on, the party's pets get their column
  too. While they are on (and Hide Blizzard is ticked) Blizzard's own party
  frames are buried the same way the raid frames are.
  With **ZacUI**'s unit frames loaded and its party frames switched on, these
  stay off (one set of party frames, not two).

- **Heal prediction (comms-free)** — ships its own LibHealPredict-1.0, which
  derives incoming heals entirely from native Blizzard APIs
  (`UnitGetIncomingHeals`, aura data, the combat log, cast events). There is
  no addon-message protocol and no coordinator, so prediction works no matter
  what the rest of the raid is running — nobody else needs a compatible
  addon. Covers direct heals, heals over time (Renew, Rejuvenation,
  Regrowth), channels (Tranquility), and multi-target casts (Prayer of
  Healing, Chain Heal). Shown as a plain green segment after current health;
  only segments landing within the next 8 seconds count, so long HoTs don't
  lump in all at once. Toggles: Heal Prediction, Predict HoT Ticks and
  Predict Group Heals checkboxes, or `/orf healpredict`, `/orf healhots`,
  `/orf healaoe`.
- **Buffs and debuffs, independently controlled**:
  - Show/hide each type: Show Buffs / Show Debuffs checkboxes, or
    `/orf buffs` / `/orf debuffs`.
  - Size each type: Buff Size and Debuff Size sliders (0 = Auto, scales with
    the frame), or `/orf buffsize <5-30|auto>` / `/orf debuffsize <5-30|auto>`.
  - **Name filters**: per-type spell-name lists with three modes — Off,
    Hide Listed (blacklist), Only Listed (whitelist). Panel: Buff/Debuff
    Name Filter cycle buttons + add/remove edit boxes (type the exact spell
    name, press Enter). Slash: `/orf buffmode off|hide|only`,
    `/orf debuffmode off|hide|only`, `/orf buffname <spell>`,
    `/orf debuffname <spell>`, `/orf filters`, `/orf filterclear`.
    Stacks with the Buff Filter (mine/all) and Only Dispellable Debuffs
    options.
  - **Stack counts**: shown bottom-right on the icon whenever an aura has
    more than one application, layered above the duration spiral. The font
    scales with the icon size.
  - **Hover tooltips** (`/orf auratooltips`): mouse over a buff/debuff icon
    for its spell tooltip. Clicks pass straight through to the unit frame,
    so click-targeting and Clique bindings keep working.
  - **Duration spiral** (`/orf auraswipe`): each icon carries a real
    Cooldown widget with the classic reverse sweep.
  - **Countdown text** (`/orf cdtext off|small|omnicc`): defaults to
    **Small** — the addon's own countdown numbers, sized to the icon (white,
    red in the last 5s, `Nm` above a minute). In Small/Off modes our
    cooldowns carry `noCooldownCount`, the standard opt-out flag, so
    OmniCC-style addons don't paint their fixed-size text over tiny icons.
    Pick **OmniCC / external** to hand the numbers to OmniCC instead (size
    is then controlled in OmniCC's own settings). Blizzard's native
    countdown text is always suppressed — it can't scale down this far.
- **Tank target / ToT bars as stacked rows inside the MT/MA frame** (unit
  block → target bar → ToT bar), refreshed on the pullout's own 0.25s
  cadence. No target = empty dark row.
- Pet frames, combined (flow) mode, aggro highlight, range fade, ready
  checks, resurrection icons, class colors, health text modes.

## Options (panel + slash)

Checkboxes: Keep Groups Together, Use Class Colors, Show Realm on Names
(off = bare names, no `-Realm` suffix on cross-realm players), Display Power Bars,
Display Border, Display Main Tank / Assist, Tank Target Bars, Main Tank
Target of Target, Display Pets, Display Party Frames, Show Yourself in Party,
Display Aggro Highlight, Only Dispellable
Debuffs, Show Buffs, Show Debuffs, Fade Out of Range, Aura Tooltips, Aura
Duration Spiral, Shield Icons, Leader Crown, Heal Prediction, Hide Blizzard
Raid Frames.

Dropdowns: Health Text (None / Percentage / Health Remaining / Health Lost =
missing hp), Sort By (combined mode), Buff Filter (My Buffs Only = the old
frames' behavior / All = world buffs + boons), Buff Name Filter and Debuff
Name Filter (Off / Hide Listed / Only Listed, lists edited via the panel's
add/remove boxes or `/orf buffname` / `/orf debuffname`), Cooldown Text
(Off / Small / OmniCC-external).

Sliders (two columns): Frame Width, Frame Height, Frame Spacing, Group
Spacing, Groups per Column, Flow per Column, Buff Size, Debuff Size (aura
sizes: 0 = Auto).

Buttons: Unlock/Lock (move frames), Reset Position, Profiles... (opens the
profile manager, and shows which profile this character is on).

## Faithfulness answers

- **Selection border**: yes — old CUF showed the white `Raid-FrameHighlights`
  border on your current target. Recreated with the authentic texture.
- **Tank ToT**: old CUF MT/MA mini-frames had none; the old drag-out pullout
  MT frames did (1.15.8 source: MT = target + ToT, MA = target only).
  Recreated as stacked rows, selection-colored, 0.25s refresh (pullout's own
  cadence). Display-only; clicking still targets the tank.
- **World buffs / boons / consumables**: the old frames never showed them.
  Default Buff Filter `mine` shows only raid-relevant buffs you cast —
  things you can put on other people (Fortitude, blessings, Renew) — and
  filters out self-only effects like elixirs, food, and procs via the
  aura's `canApplyAura`/self-buff data. Set Buff Filter to All to see
  everything.
- **Missing HP**: the old "Health Text = Lost Health" — gray `-N` under the
  name, hidden at full.
- **Offline**: solid 0.5-gray health fill, gray name, gray "Offline".

Not included: automatic per-spec profile switching (profiles are manual —
`/orf profile`). Heal prediction is provided by the embedded
LibHealPredict-1.0, computed locally with no addon-message comms.

## WoW Forever and Retail

Those clients hide health, power and aura values from addons while you are in
combat. The frames keep working: bars, health text, aura icons, stacks and
duration spirals are drawn by the game from the hidden values. What can't be
worked out from a hidden value goes quiet until it reads again:

- **Health Lost** text shows nothing in combat (Percentage and Health
  Remaining still show).
- **My Buffs Only** uses the game's own "cast by you" flag; the self-only
  filter (food, elixirs, procs) and the name lists can't see a hidden name, so
  *Hide Listed* lets hidden auras through and *Only Listed* shows none.
- Debuff borders are the plain red while the debuff's type is hidden.
- The small countdown numbers are off for hidden auras (the spiral stays).
- Heal prediction is the game's own incoming-heal number drawn on the bar
  (LibHealPredict's HoT and group-heal options apply on Era and TBC only).
- Range fade does nothing while the game hides the range.

## Implementation notes (1.15.9 hardening)

- Edit Mode: the Blizzard raid container is a registered Edit Mode system on
  the Midnight UI, so burial now calls
  `EditModeManagerFrame:UnregisterSystemFrame` before re-parenting it — a
  system frame living under a hidden parent is what makes Edit Mode re-show
  it and error while laying its systems out. The manager's `OnShow`/`OnHide`
  are hooked for the auto-unlock, hooked at `PLAYER_LOGIN`,
  `PLAYER_ENTERING_WORLD` and on `Blizzard_EditMode` load, whichever lands
  first (idempotent).
- Secure headers: `OldRF_HeaderG1`-`G8`, `OldRF_HeaderAll` (flow),
  `OldRF_HeaderMT`/`MA` (role groupFilter), `OldRF_HeaderPets` (pet template),
  `OldRF_HeaderParty` (showParty only, so it shows nothing in a raid).
- Cardinal `point` attribute; negative `startingIndex` pre-instantiation (no
  combat-created children); unfiltered `RegisterEvent` + unit map; aura shim
  (`C_UnitAuras` → `UnitAura`); local dispel colors; deduped regen layout
  queue; `ClickCastFrames` (Clique); threat API presence-checked; Blizzard
  container/manager buried oUF-style with `SetParent` hook defense.
- `Compat.lua` polyfills `C_UnitAuras.GetAuraDataBySpellName` (missing on the
  1.15.9 Era client), which `AuraUtil.FindAuraByName` dispatches to — without
  it, any addon or library doing name-based aura lookups errors. Self-retires
  if a hotfix ships the real function.
- LibHealPredict deliberately does not register `UNIT_AURA` itself; HoT
  tracking runs off the consumer's aura pass, so the addon calls
  `HealPredict:ScanAuras(unit)` from its own `UNIT_AURA` handler (the library
  dedupes same-tick rescans). Overlay redraws are driven by the
  `HealPredict_SegmentsChanged` and `HealPredict_RosterChanged` callbacks.
- Embedded libs: LibStub, CallbackHandler-1.0, ChatThrottleLib,
  LibHealPredict-1.0, AceDB-3.0 (profiles), AceSerializer-3.0 (share strings).
  LibStub keeps only the newest copy of each active when several addons embed
  them.
- Profiles: the settings table is a single file-level upvalue (`db`), so a
  profile switch is a re-point (`ns.SetDB`) plus one full re-apply
  (`ns.ApplyAll`: button internals, layout, titles, lock state, options
  panel). No reload, and nothing is touched during combat that isn't already
  routed through the `PLAYER_REGEN_ENABLED` queue.
- Profile sending uses the `OldRF` addon-message prefix, 200-byte chunks
  through ChatThrottleLib's BULK queue, with a header/data/end framing, a
  30s expiry on half-finished transfers, an 80-chunk cap, and self-echo
  suppression so raid broadcasts don't prompt the sender.
