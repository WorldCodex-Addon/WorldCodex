# WorldCodex export

Open the export window with `/worldcodex export` (or `export lua|json|csv [table]`). It has four formats.

| Format | Contents | Use |
|---|---|---|
| Share string (`WCX1:…`) | Everything that can be merged: drops, quests, vendors, recipes, trainers, spells, NPCs, item facts, current auction prices with realm and faction | Website upload; `/worldcodex import` for friends and alts |
| Lua | The full export below, as `WorldCodex_Export = {…}` | Backup, your own scripts |
| JSON | The full export below | Website, spreadsheets, other tools |
| CSV | One table per kind of data (see below) | Spreadsheets |

Only your own data is exported. Guild and community data belong to other players and stay out. The share string
contains no character names; the full export doesn't either, but it does contain your goals and farming sessions.

Once the shipped community data contains your upload, the share string only carries what changed after that upload
(a delta, see [dataset.md](dataset.md#delta-uploads)): the mobs, nodes, quests, vendors, NPCs, items and prices with
new data, each as a whole record. After long play times this is a small part of everything, so it is built and
uploaded quickly. Untick "Only what is new since your upload in the community data" to get everything, for example
when the website no longer has your earlier upload. The share string is built in the background over a few frames and
kept until something changes; it is compressed with the client's own DEFLATE when it has one (`C_EncodingUtil`),
else with LibDeflate when another addon provides it.

The SavedVariables file (`WTF/Account/<account>/SavedVariables/WorldCodex.lua`) holds the same data and is also
accepted by the website. Because it includes the full price history, it is the most complete upload.

## Full export (Lua / JSON), format 1

```jsonc
{
  "format": 1, "addon": "3.0.0", "exported": 1763600000,
  "uid": "…", "rev": 1234, "locale": "deDE", "realm": "…", "faction": "Alliance",
  "sources":  { "<key>": Source },        // drop sources except quests
  "quests":   { "<questId>": Quest },
  "items":    { "<itemId>": Item },
  "prices":   { "<itemId>": Price },      // latest scan
  "history":  { "<itemId>": { "<day>": Day } },
  "vendors":  { "<npcId>": Vendor },
  "recipes":  { "<itemId | enchant:spellId>": Recipe },
  "trainers": { "<npcId>": Trainer },     // own record: also `t` (last seen)
  "spells":   { "<spellId>": { "n", "rk", "ic", "ds", "t" } },  // name, rank, icon, description, last read
  "npcs":     { "<npcId | go:objectId>": Npc },
  "maps":     { "<mapId>": "zone name" },
  "personal": { "totals", "sessions", "currentSession", "goals", "activeDays", "calibration", "created" }
}
```

Untick sections in the window to leave them out.

- **Source:** the full personal record.
  - `n`: rate denominator (looted corpses for mobs, attempts otherwise).
  - `kills`, `lb` (looted or confirmed empty), `ek` (empty), `ul` (never looted), `attempts`, `fails`.
  - `loot = {itemId: {d, q, h = {stackSize: count}, g, n}}`. `n` is only there for quest items: their own rate
    denominator (attempts made while a quest needed the item). `d`, `q` and `h` then count only those attempts.
  - Coin: `money`, `mc`, `ca`, `mmin`, `mmax`.
  - Spawns: `spawns = {mapId: {cell: count}}`.
  - Mob details: `lmin`, `lmax`, `cls`. Quests keep their quest level in `lmin`/`lmax`.
  - Dry streaks: `streak`.
  - Farming pace: `pk`/`ps` (kills and seconds).
  - Timestamps: `first`, `last`.
- **Quest:**
  - `title`, `repeats` (daily/weekly).
  - `giver` (name), `giverKey` and `turnInKey` (npc id or `go:<id>`).
  - `startItem`, `required = {itemId: count}`.
  - `turnIns`, `money`.
  - `rewards = {itemId: {perTurnIn, times, total, choice}}`.
  - `accepted = {map, zone, x, y}`.
  - `inProgress` for quests that were accepted but not yet turned in.
- **Item:**
  - `n`: name in your language.
  - `ql` quality, `v` vendor sell price, `il` item level, `rq` required level.
  - `cl`/`sc`: class and subclass ids.
  - `eq` slot token, `ic` icon, `sk` stack size, `bd` bind type.
  - Details, for weapons, armour and items with a use spell (read once per item by `Items.lua`, from
    bags, equipped gear, items received, chat links, auction house results and inspected players):
    - `st = {KEY: value}`: stats as `C_Item.GetItemStats` names them, e.g. `ITEM_MOD_STRENGTH_SHORT`,
      `RESISTANCE0_NAME` (armour), `RESISTANCE2_NAME` (fire resistance), `ITEM_MOD_DAMAGE_PER_SECOND_SHORT`
      (DPS, one decimal). The keys are the names of the client's global strings, the same in every language.
      Base stats only: random suffixes ("of the Bear") are not included.
    - `wd = {min, max, speedMs}`: weapon damage and speed in milliseconds (from the tooltip).
    - `du` durability, `iv` inventory type (`Enum.InventoryType`), `set` item set id, `un` how many may be
      equipped (unique), `us` use spell id.
    - `fx = {{trigger, text}}`: effect lines in your language, trigger `use`, `equip`, `proc` (chance on hit)
      or `learn`.
- **Price:** `t` (scan time), `mi` min, `md` median, `mn` average with outliers trimmed, `mx` max, `q` listed quantity, `market`.
- **Day:** `day` = unix time / 86400. Fields `mi`, `md`, `mn`, `mx`, `q`, plus `c` (number of scans that day).
- **Vendor, recipe, trainer, NPC:** as described in [dataset.md](dataset.md).

Cells: `cell = floor(x * 100) * 100 + floor(y * 100)`, with x and y in 0..1 on the map. The CSV tables write
them as zone, x and y in percent.

## CSV tables

| Table | One row per |
|---|---|
| drops | Source and item, with rate, 95% interval, stack sizes, prices and expected value |
| quests | Quest and reward / required item / start item |
| items | Item |
| prices | Item: latest scan |
| history | Item and day |
| vendors | Vendor and item sold |
| recipes | Recipe and reagent |
| trainers | Trainer and service (spell or recipe) with cost and requirements |
| spells | Spell, with rank, description and the item a recipe creates |
| npcs | NPC and map cell |
