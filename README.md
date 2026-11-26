# WorldCodex

An in-game item database for World of Warcraft Forever, a bit like Wowhead inside the game. For every item it shows where it drops, how often, how sure that number is, who sells it, what it is crafted from and used for, which quests reward or need it, and what it sells for on the auction house. All of it is learned from play on this server: your own data, your guild's data and the community data shipped with the addon. Your own numbers are always shown next to everyone else's.

Farming features (goals, tracker, arrow, sessions, "best farm") are optional. They switch off automatically when [Blackthornes Farmer](https://www.curseforge.com/wow/addons/blackthornes-farmer) is installed, so the two addons complement each other: Blackthornes Farmer for where to farm right now, WorldCodex for what drops where and how reliably.

## Features

- **Item pages.** Open with `/worldcodex item <name>`, the key binding (Key Bindings > AddOns: open the page of the item or NPC under the mouse), the WorldCodex button under item links, a double-click in a list, or Alt-click on links (optional). Pages have back and forward history and a search box that finds any item, NPC or source from every page and list (the lists have their own filter box). Tabs, each shown only when it has entries:
  - *Dropped by*, *Gathered from*, *Contained in*, *Quests*, *Processing*: every source with level, zone, a rate bar and the number of observations;
  - *Sold by*: vendor, zone, price (also token costs), stack size, limited stock;
  - *Crafting*: what the item is made from, and what it is a reagent for;
  - *Objective of*: quests that need the item or start from it;
  - *Disenchants into* (also milling and prospecting);
  - *Prices*: a 60-day chart.
- **Drop-rate visualisation.** Rates are drawn on a log scale (0.1% to 100%) with the 95% interval as a band. The colour says how sure the rate is. The panel for the selected row shows:
  - "8 of 40 kills (95%: 10.5%-34.1%)";
  - the chance to get the item after N attempts (50/90/99%);
  - a stack-size histogram;
  - where the numbers come from (personal, guild, community);
  - your current dry streak.
- **NPC and object pages.** Every NPC gets a page, including vendors, trainers and quest givers that drop nothing. The header shows its portrait when it is near you, otherwise its 3D model (a Model tab shows it larger, drag to turn).
  - Drops: the full drop table, plus tabs for corpse gathering on the same mob (skinning, pickpocketing, ...).
  - Also: what the NPC sells and which quests it starts or ends.
  - Location: the zones, a small spawn map, and "Show on map" for the world map.
  - Coin per kill, level, classification, roles and whether it is hostile.
- **Advanced search.** A tab of its own: items by name, quality, item level, required level, type, slot, a stat (with a minimum) and where they come from (mobs, gathering, chests, quests, vendors, crafting); NPCs and sources by name, kind, level, classification, reaction, role, zone and the items they drop; quests by name, level, zone, quest giver, reward, repeat type and whether you have done them. Quest levels are recorded from the quest log and shared.
- **Chests, herbs and veins.** Hover one to see its drops in the tooltip. The page key opens its page there too.
- **Where NPCs stand.** Recorded whenever you talk to an NPC (vendor, quest, trainer, flight master, bank). Addons can't read other units' positions, so your own position is used, which is only close enough while you interact. NPCs you just see nearby (mouseover, target, nameplates) add their name, level and reaction, but no location. These locations are shared with the community data.
- **Your data vs everyone else's.** Every page has a switch: *All*, *Mine* or *Community*. Rate bars show your own rate as a second marker: green when it is clearly higher, red when clearly lower (two-proportion test, p < 0.01, at least 20 observations on both sides). Your own upload is never counted on the community side. "Luckier than 82% of players" is your position in the binomial distribution. `/worldcodex compare` lists every drop where your rate differs, which also catches loot tables that changed on this server.
- **Drop rates per source.** Covers mobs, herbs, ore, skinning, fishing (per zone), pickpocketing, chests, lockboxes and other containers, and disenchanting.
  - Every rate comes with its sample size and a 95% confidence interval (Wilson).
  - Kills are detected from the units you can see (target, mouseover, nameplates). A kill counts if you were on the mob's threat list and it wasn't tapped by someone else; any corpse you loot counts too. The combat log is not used by default, because some clients forbid addons from registering it; it can be enabled in the options where allowed.
  - In a group, a corpse counts when you loot it, so kills that others loot don't lower your rates.
  - Each corpse counts once, even if you reopen the loot window.
  - Mob drop rates are based on corpses that were looted or confirmed empty (`CanLootUnit`). A mob you kill but never loot is left out, so it doesn't count as "dropped nothing". It shows up as "not looted" in the source details.
  - Quest items only count attempts made while one of your quests still needed them, because they don't drop at any other time. Kills without the quest, or after the last one was collected, don't lower their rate.
  - Skinning, herbalism and mining on a corpse are separate sources with their own attempts, so killing without skinning doesn't affect skinning rates. Each gathering cast is one attempt, including repeated harvests of the same vein.
  - Interrupted or failed gathering casts (e.g. attacked while mining) are not attempts. They're counted separately and shown as "failed or interrupted".
  - Area loot is split by source GUID (`GetLootSourceInfo`).
  - Other players' loot messages are ignored.
- **Stack sizes per drop.** For every item and source, how many came from one kill, node or container, e.g. Copper Ore from a Copper Vein: `1-4 (Avg 2.0)`, `1× 30% · 2× 50% · 3× 10% · 4× 10%`. Shown in item and mob tooltips (Shift for the distribution), the item and source details, and the CSV export (`qty_min`, `qty_max`, `qty_distribution`).
- **Items and coin per kill.** For every source: average items and stacks per kill, average stack size per item, the most items from one loot, and coin per kill.
  - Coin is read from the loot window itself, so the full corpse amount is recorded even when coin is split in a group; area loot is split per corpse.
  - Also tracked: how often coin drops and the smallest and largest amount.
  - Shown in mob tooltips, the Sources tab (Items/kill, Coin/kill), source details and the CSV export.
- **Quest rewards.** Each quest is a source:
  - Fixed and choice rewards are read from the reward window. The turn-in counts as one attempt, and the quest's gold and reward items count as session income.
  - Where you accepted the quest is stored, so `goto <item>` leads to the quest giver.
  - One-time quests you have already finished are still listed as "(done)" but never suggested. Daily and weekly quests stay suggested.
- **Auction house prices.** Min, average and max, plus a market value (a weighted average leaning toward recent days).
  - Each scan is summarized with troll listings trimmed (IQR), and a daily history is kept for 60 days.
  - Uses the `C_AuctionHouse` API.
  - When the AH opens, a full scan (ReplicateItems) runs automatically if the last one is more than an hour old; otherwise items with prices older than an hour are searched one by one. Searches you run yourself in the AH window are recorded too.
  - "Scan AH" in the Items and Auction house lists searches the selected item immediately; `/worldcodex ah` shows scan statistics and the last error.
- **Tooltips.** Item tooltips show:
  - AH min/avg/max and market value;
  - the top sources, each with a small rate bar, rate ±CI and n;
  - with Shift: your rate vs the community's;
  - with farming on: the best farm and your goal progress.

  Mob tooltips show the most likely drops and coin, plus the value per kill when farming is on.
- **Vendors, recipes and quest NPCs** are recorded from the merchant, profession (including the classic enchanting window) and quest windows. Shared through export strings and the community data, not through guild sync.
- **Navigation** (part of the optional farming features). Sources are ranked by *expected time per drop*:
  - Formula: CI lower bound × your measured kills per hour at that source.
  - Recorded spawn positions are grouped into hotspots.
  - `/worldcodex goto <item>` sets a TomTom waypoint, a native map pin, or the built-in arrow, and marks the spawn cells on the world map.
- **Farming (optional).** Sessions track gold per hour (AH value plus coin). Goals (`/worldcodex goal <item> 20`) get an ETA and a tracker frame. Dry-streak alerts and a "chance of this bad luck" figure are included. When Blackthornes Farmer is loaded, these features start switched off. The options panel switches them on again, and that choice is kept.
- **Sharing** comes in three layers, shown side by side in the tooltip and details pane:
  - *Personal*: your own data.
  - *Guild/group*: automatic sync via addon messages, with an import/export share string.
  - *Community*: a dataset merged by `tools/merge.py` and shipped in `Data/Community.lua`.
  - No layer is ever counted twice.
- **Export everything** (`/worldcodex export`): drops, quests, items, auction prices and their daily history, vendors, recipes, NPCs, zones and your sessions and goals.
  - Formats: Lua or JSON, with a choice of sections; one CSV table per kind of data; or the compact share string for the website and `/worldcodex import`.
  - Details: [docs/export.md](docs/export.md).
- **KPIs** (`/worldcodex kpi` or the KPIs tab of the window): the targets below, measured in game. Each has a gauge (value against target) and a chart: calibration per rate range, prices by age, interval widths, slowest handlers, active days and more.

## Commands

| Command | |
|---|---|
| `/worldcodex` (`/wcx`) | The WorldCodex window: lists of items, sources, AH prices (and farming when switched on), and every page |
| `/worldcodex welcome` | Short guide: how to use the addon (opens by itself after the first login; also in the options) |
| `/worldcodex item <name\|id\|link>` | Item page; `print <item>` writes the same to chat |
| `/worldcodex mob <name\|id>` / `target` | Page of a mob or other source / of your target or mouseover |
| `/worldcodex compare` | Drops where your rate differs from everyone else's |
| `/worldcodex goto <item\|source>` / `goto stop` | Navigate to the best spot |
| `/worldcodex goal <item> <n>` / `goal clear [item]` | Farming goals (also: Remove goal button, right-click a goal in the tracker) |
| `/worldcodex ah [all\|scan\|stop\|auto on\|off\|<item>]` | AH scanning |
| `/worldcodex sync [on\|off\|now]` | Guild/group sharing |
| `/worldcodex export [string\|lua\|json\|csv [table]]` / `import` | Export everything (CSV tables: drops, quests, items, prices, history, vendors, recipes, npcs) or import a share string |
| `/worldcodex report \| top \| kinds \| status \| kpi \| options \| prune \| clear confirm` | Misc |

Optional addons and libraries, used if they are installed:
- TomTom (waypoints)
- LibDeflate (smaller share strings on clients without the built-in `C_EncodingUtil` compression)
- ChatThrottleLib (sync throttling)
- LibDataBroker and LibDBIcon (minimap button)

## How it compares

| | Wowhead | Blackthornes Farmer | Loot-table addons | WorldCodex |
|---|---|---|---|---|
| Drop rates | Global, mixed versions, out of game | Learned per mob (after 20 kills) | Static lists | Learned on this server, in game, every source type |
| Uncertainty | Raw % | – | – | n, 95% interval, visualised |
| You vs everyone | – | – | – | Side by side, significance, luck percentile |
| Sold by / crafting / quest items | Yes | – | Partly | Yes, recorded from play |
| Item and NPC pages | Website | – | – | In game, with history and search |
| Farming: gold per hour, goals, arrow | – | Yes (its focus) | – | Optional, off when Blackthornes Farmer is loaded |
| Data sharing | Central | Own accounts, friends | Static | Personal, guild, community (website) |

### KPIs (see `/worldcodex kpi`)

1. Time to answer: hovering gives the answer instantly, with no clicks (target under 1 s).
2. Coverage: share of looted items with n ≥ 30 and a price less than 24 h old (target ≥ 80%).
3. Farming uplift (only with farming on): gold per hour in sessions that followed a recommendation, compared with the others (target +20%).
4. Route usefulness (only with farming on): a kill at the target within 10 minutes of `goto` (target ≥ 70%).
5. Calibration: observed drop rate falls inside the predicted 95% CI (target ≥ 90% of rate ranges).
6. CI width: median half-width (target under ±5 percentage points).
7. Price freshness: median age (target under 24 h, under 6 h with the guild).
8. Attribution: duplicate corpses prevented; share of loot with an unknown source (target ≤ 1%).
9. Performance: slowest event handler (target under 16 ms).
10. Footprint: memory use and SavedVariables size (target under 5 MB).
11. Community: number of contributors and of source/item pairs.
12. Retention: days with recorded data out of the last 14.

## Community dataset

The community data ships inside the addon (`Data/Community.lua`), so players get new data through normal CurseForge or Wago updates. Addons can't access the internet.

1. Players upload their `WTF/Account/<account>/SavedVariables/WorldCodex.lua` or the share string from `/worldcodex export` on the WorldCodex website.
2. The website runs `tools/merge.py` on the uploads. Its JSON output feeds the online database; its Lua output is the next `Data/Community.lua`.
3. The weekly GitHub workflow `.github/workflows/data.yml` downloads that file, checks it against the manifest, runs the tests, bumps the patch version and publishes the release.
4. Guild members tell each other when a newer dataset exists.

The format and merge rules are in [docs/dataset.md](docs/dataset.md). To merge by hand:

```sh
python3 tools/merge.py uploads/ --out Data/Community.lua --json dataset.json --manifest manifest.json
```

- Uploads carry only a random installation id, never character names.
- The newest upload per id replaces older ones. An upload holds lifetime totals, not new kills, so uploading the same data twice, or an older file after a newer one, never counts anything twice.
- Once a player's upload is in the shipped dataset, their share string only carries the records that changed since (a delta); `merge.py` lays it over the earlier upload, so the website has to keep that one (see `docs/dataset.md`).
- A contribution whose rate is more than 5 standard deviations from everyone else's data for that source is rejected (binomial z-test).
- If a player's own data is already part of the shipped dataset, the addon only adds what they collected after that point.
- Names of mobs, objects and vendors are kept per client language; German clients see German names.

## Development

```sh
luajit tests/run.lua                          # addon tests (WoW API stubbed in tests/wowstub.lua)
python3 -m unittest discover -s tools         # merge tool tests
luacheck .                                    # lint
```

Code layout:
- `Core`: events, timers, helpers
- `Stats`: pure math
- `Codec`: safe serializer and base64
- `Store`: schema v3, migrations, data layers
- `Collector`: kills, loot, gathering
- `AH/`: history, scanner, `C_AuctionHouse` adapter
- `Quests`, `Vendors`, `Crafting`: quest, merchant and profession windows
- `Lookup`: read models for the pages (sections, ranking, you vs everyone, search); `Search`: the advanced search
- `UI/Page*`: the WorldCodex window, item, source, KPI and extra tabs; `UI/Browser`: its lists; `UI/Charts`: rate bars, columns, tables; `UI/Widgets`: building blocks in the client's own style (spellbook-like window and book, Blizzard fonts and templates); `UI/Portraits`: still NPC portraits for lists and pages
- `Nav`, `Farm`, `KPI` (optional farming), `Sync`, `Report`, other `UI/`

Data from older versions is migrated automatically:
- `ItemsDB` (this addon's earlier name): rename `WTF/Account/<account>/SavedVariables/ItemsDB.lua` to `WorldCodex.lua` once before the first login with WorldCodex; share strings starting with `IDB1:` still import
- the `MobLootDB` saved variable
- schema v1 and v2

CI runs lint and tests, and packages releases with the BigWigs packager when a tag is pushed.
