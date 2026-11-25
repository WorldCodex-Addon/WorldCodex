# WorldCodex community dataset

This file describes the data exchanged between the addon, `tools/merge.py` and the WorldCodex website.
The merge logic exists only once, in `tools/merge.py`. The website runs it; it does not reimplement it.

## Flow

```
player (in game)                       website (Laravel, own server)             this repository
------------------                     ------------------------------           ----------------
SavedVariables/WorldCodex.lua  ─┐
/worldcodex export string      ─┴─ upload ─> store raw upload per uid
                                          queued job: python3 tools/merge.py uploads/
                                              --out Community.lua --json dataset.json
                                              --manifest manifest.json
                                          dataset.json   -> website database / pages
                                          Community.lua + manifest.json  ─────────> data.yml (weekly):
                                                                                   verify, test, commit
                                                                                   Data/Community.lua,
                                                                                   tag, package ->
                                                                                   CurseForge / Wago
```

Addons cannot access the network, so players get new data with an addon update through CurseForge or Wago.
Guild members tell each other when a newer dataset exists: an addon message `G:<generated>` is sent with the
regular sync advertisement.

## Uploads

The website accepts two formats. `merge.py` parses both.

| Format | Where it comes from | Parser |
|---|---|---|
| SavedVariables file | `WTF/Account/<account>/SavedVariables/WorldCodex.lua` | `parse_saved_variables` + `snapshot_from_saved` |
| Share string `WCX1:R:…` / `WCX1:Z:…` | `/worldcodex export` (the default "Share string" view) | `decode_share_string` |

Every upload is checked with `validate()`. Anything that fails is skipped, and nothing is ever executed.

Privacy: an upload contains a random installation id (`meta.uid`) and no character or account names.
Auction prices carry the realm and faction they belong to.

### Uploading twice never counts twice

An upload is not a list of new kills. It holds the lifetime totals of one installation (one
SavedVariables file), plus the installation id `uid` and a revision `rev` that goes up with every
recorded event. Because of that:

- Uploading the same data twice, a minute or a week apart, in either format: the merge keeps one
  upload per `uid` (the highest `rev`). One kill stays one kill.
- Uploading again after playing: the newer totals replace the older ones. Nothing is added up.
- An older file uploaded after a newer one: it has a lower `rev` and is ignored.
- Data you imported from friends or got through guild sync is not part of your upload. Uploads only
  contain what the uploading installation recorded itself.
- When your own upload is in the shipped community data, the addon subtracts it in game
  (`contributors[uid]`), so it is not counted twice on your own screen either.

### Delta uploads

Once the shipped community data contains an installation's upload (`contributors[uid] = rev`), its share
string only carries what changed after that revision: a snapshot with `v = 2` and `base = <rev>`. It holds
whole records (lifetime totals of each changed source, vendor, NPC, recipe, item and price), never
increments. The addon knows what changed from the revision stored on each record (`rv`); a revision is
closed once a share string was built or the SavedVariables file written, so "changed after revision R" is
exact.

`merge.py` lays a delta over the newest state of the same `uid` whose `rev` is at least `base`: its records
replace the earlier ones, everything else is kept. Any later full upload works as the base too, because it
contains everything from before `base`. A delta whose base is missing is skipped and reported. Prices of a
delta from another realm or faction replace the earlier prices instead of adding to them. Deleted records
(`/worldcodex prune`) cannot be expressed in a delta; they leave with the next full upload.

Readers that only know `v = 1` (older addon versions, older `merge.py`) reject deltas instead of mistaking
them for full uploads. Update `merge.py` on the website before releasing an addon version that writes them.
`/worldcodex import` applies a delta on top of an earlier import from the same player and refuses it
otherwise.

What the website should do:

- Store the raw upload per `uid`. Keep the newest full upload and every delta that arrived after it; older
  uploads can go. A full upload with a lower `rev` than one already stored can be rejected (`merge.py`
  ignores it anyway). The merge can then always be rerun from scratch.
- If a delta arrives and no upload of that `uid` is stored at all, ask for a full upload (the export
  window has an option for it).
- Treat the `uid` as an id, not a proof. Someone could invent new ids to count fake data
  repeatedly. The z-test drops contributions far from everyone else's rates, but a plausible-looking
  fake can only be limited:
  - require a website login for uploads and remember which account uploaded which uid;
  - rate-limit uploads per account and IP;
  - show the number of contributors next to each rate, and hide pairs that only one contributor
    reported until a second one confirms them.

## Dataset (JSON, `schema` 2)

`merge.py --json` writes this structure. Numeric Lua keys become strings in JSON. The Lua file contains
the same data with numeric keys.

```jsonc
{
  "version": 1,               // read by old addon versions; always 1
  "schema": 2,                // format of this document; bumped on incompatible changes
  "generated": 1763600000,    // unix time of the merge
  "contributors": { "<uid>": <rev> },   // rev of each contributor's merged upload
  "sources": { "<key>": Source },
  "vendors": { "<npcId>": Vendor },
  "recipes": { "<productKey>": Recipe },
  "npcs":    { "<npcId | go:objectId>": Npc },
  "prices":  { "<realm>|<faction>": { "<itemId>": { "last": Price, "days": { "<day>": Day } } } },  // JSON only
  "items":   { "<itemId>": Item },                                                             // JSON only
  "names":   { "<locale>": { "<key>": "localized name" } }
}
```

### Source keys

| Key | Meaning |
|---|---|
| `1234` | Mob (npc id). Mobs without an id use `name:<name>` |
| `skin:1234`, `herb:1234`, `mine:1234`, `salvage:1234`, `pickpocket:1234` | Gathering on a mob's corpse, and pickpocketing |
| `go:1617` | Game object: herb, ore vein, chest |
| `fish:<mapId>` | Fishing in a zone |
| `item:<containerItemId>` | Opening a container item (lockbox, clam, bag) |
| `quest:<questId>` | Quest rewards |
| `kind:<kind>` | Pooled sources without a specific origin (e.g. `kind:disenchant`) |

### Source

| Field | Type | Meaning |
|---|---|---|
| `nm` | string | Default name. The English name if anyone uploaded one, otherwise the most common name |
| `k` | string | Kind: `mob herb mine skin fish pickpocket lockpick object container quest disenchant mill prospect salvage other` |
| `n` | int | Sample size. Mobs: corpses looted or confirmed empty (kills never looted are excluded). Everything else: attempts. Quests: turn-ins |
| `m` | int | Coin in copper, summed over all `n` |
| `l` | `{ itemId: [d, q, hist?] }` | `d` = attempts the item dropped in, `q` = total quantity, `hist` = `{stackSize: count}` |
| `qb` | `{ itemId: attempts }` | Sample size of quest items, in place of `n`: only attempts made while a quest in the log still needed the item (quest items drop at no other time). 0 = known to drop, no rate yet |
| `sp` | `{ mapId: { cell: count } }` | Spawn positions on a 1% grid: `cell = floor(x*100)*100 + floor(y*100)` |
| `zn` | `{ mapId: count }` | Zones where the source was recorded without a position. Instances give addons no coordinates and on WoW Forever not even a map id: there the key is the negative instance id (`-389` = instance 389). Summed in the merge |
| `cm` | `[coinDrops, attempts, min, max]` | How often coin dropped, the attempts since coin tracking began, and the smallest and largest amounts |
| `ch` | `{ itemId: true }` | Quest choice rewards |
| `rp` | `"daily"`/`"weekly"` | Repeatable quest |
| `lv` | `[min, max]` | Mob level range |
| `cl` | string | `elite rare rareelite worldboss` |
| `qg`, `qt` | npc id or `"go:<id>"` | Quest giver and turn-in |
| `rq` | `{ itemId: count }` | Items the quest requires |
| `si` | int | Item that starts the quest |

Drop rate = `d / n`, for items listed in `qb` `d / qb[itemId]`. The addon shows a 95% Wilson interval and never a bare percentage without `n`.

### Vendor

```jsonc
{ "nm": "Innkeeper Farley", "sp": { "1429": { "4040": 3 } },
  "i": { "<itemId>": { "p": 25, "st": 1, "lim": true, "x": { "<costItemId>": 2 }, "c": 4 } } }
```

| Field | Meaning |
|---|---|
| `p` | Price in copper. The highest price seen, because reputation discounts only lower it |
| `st` | Stack size per purchase |
| `lim` | Limited stock |
| `x` | Item costs, e.g. tokens |
| `c` | Number of uploads that saw the item |

### Recipe

Key: the created item id, or `enchant:<spellId>` for recipes that create no item.

```jsonc
{ "pf": "tailoring", "mn": 1, "mx": 1, "r": { "<reagentItemId>": 2 } }
```

`pf` is a profession key that does not depend on the client language: `alchemy blacksmithing enchanting
engineering leatherworking tailoring cooking firstaid smelting jewelcrafting inscription poisons`. The
reagents are the set most uploads agree on.

### Npc

Where NPCs (and quest objects) stand, also those that drop nothing: vendors, trainers, quest givers,
guards. Recorded when the player talks to them (exact) or sees them within about 28 yards out of combat.
The position is always the player's, because addons cannot read other units' positions.

```jsonc
{ "nm": "Innkeeper Allison", "sp": { "1429": { "5050": 3 } }, "lv": [30, 30], "cl": "elite",
  "r": "friendly", "f": { "vendor": true, "gossip": true } }
```

| Field | Meaning |
|---|---|
| `sp` | Locations, same grid as sources (at most 24 cells per NPC from one player, the busiest 32 per map after the merge). Only from interactions: records without a role (`f`) are sightings and their locations are dropped by the merge |
| `lv`, `cl` | Level range and classification |
| `r` | `hostile`, `neutral` or `friendly` |
| `f` | Roles: `gossip vendor quest trainer taxi banker` |

### Prices and items (website only)

They are written to the JSON but not to the addon's Lua file. Prices change too fast for a weekly release, and
every client already knows its items.

- **Prices** are kept per realm and faction. Uploads that don't say where their prices come from are left out.
  - `last`: the newest scan, `{t, mi, md, mn, mx, q}`.
  - `days`: daily rollups `{mi, md, mn, mx, q, c}`. When several uploads cover the same day, medians and
    averages are weighted by the number of scans `c`; the minimum and maximum are the extremes.
  - The daily history comes only from SavedVariables uploads. Share strings carry the latest scan.
- **Items:** `{n, names: {locale: name}, ql, v, il, rq, cl, sc, eq, ic, sk, bd}`. `n` is the English name when
  one was uploaded. The other fields take the most common value (see [export.md](export.md)).

### Names

Uploads carry the client locale (`lc`). `names[locale][key]` holds a name only where it differs from
`nm`. Vendors use the key `vendor:<npcId>`. NPCs use their npc id, which is the same key as the mob source. Item names are never stored, because every client knows
them in its own language.

## Merge rules

- Quest items: uploads carry `qb[itemId]` for every quest item they know at a source, also for items
  that never dropped there. Once any upload has it for a (source, item) pair, uploads without it are left
  out of that pair's rate: they were made without the quest, or with an older addon version that counted
  every kill. Quest items that turned out to drop without a quest carry `qb[itemId] = n`.
- The newest upload per uid wins (highest `rev`). Deltas are laid over the upload they build on first
  (see [Delta uploads](#delta-uploads)).
- Outliers: a contribution whose rate for any item differs from everyone else's pooled rate by more
  than `--z` standard deviations (default 5) is dropped for that source. This only applies when the
  others have at least 20 attempts.
- Counts (`n`, `m`, `d`, `q`, histograms, coin) are summed.
- Level ranges are widened. Classification, quest npcs, start item and required items take the
  most common value.
- Size controls:
  - `--min-n` drops sources with few attempts in total.
  - `--min-d` drops source/item pairs seen fewer times.
  - Spawns keep the 32 busiest cells per map.

## Lua file (`Data/Community.lua`)

```lua
WorldCodex_CommunityData = { version = 1, schema = 2, generated = …,
                          contributors = {}, sources = {}, vendors = {}, recipes = {}, names = {} }
local function put(section, sub, part) … end
put("sources", nil, function() return { [1234] = {…}, … } end)
put("names", "deDE", function() return { [1234] = "…", … } end)
```

Every section is split into functions of at most about 20,000 values each, because Lua limits the
number of constants per function: LuaJIT allows 65,536 and Lua 5.1 more. `merge.read_lua()` reads the
file back.

As a rough guide, a synthetic dataset with 5,000 mobs × 40 items (200,000 pairs) and 1,500 vendors is
23 MB on disk. Under LuaJIT it loads and indexes in about 0.3 s and uses about 67 MB of memory. Keep
the shipped file well below that with `--min-n` and `--min-d`.

## Manifest

`--manifest manifest.json` writes `{schema, generated, sha256, bytes, contributors, sources, pairs,
vendors, recipes, npcs, items, markets}`. The release workflow (`.github/workflows/data.yml`) downloads `Community.lua`
and `manifest.json` from the website and checks four things before it publishes anything:
- the sha256 of the file matches the manifest;
- the schema is known;
- the dataset is newer than the one shipped;
- the addon tests pass with the file loaded.

## Compatibility

- Full snapshots stay `v = 1`. New fields are optional. Old addon versions drop unknown fields when they
  validate a snapshot, and old snapshots without the new fields merge fine.
- Deltas are `v = 2` with `base`, so readers that do not know them reject them.
- Old addon versions read `version`, `contributors` and `sources` and ignore everything else.
- If a change would break old readers, bump `schema` and update this document.
