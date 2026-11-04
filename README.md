# PlaceholderSync

On CurseForge: https://www.curseforge.com/wow/addons/placeholdersync

The World of Warcraft addon half of the Placeholder guild tools. It records the guild bank and its transaction log
whenever the bank is opened, records your characters in full (gear, professions, talents, reputations, stats, bags, lockouts) for the roster and armory tabs, and copies loot council awards (RCLootCouncil
and ForeverLoot) for the sheet's Loot Log, so the officer running the bridge app can upload them for the guild's Discord
bot and sheet.

In game, `/psync` shows the status and `/psync help` the settings (`chat`, `autoscan`, `share`). It prints nothing by itself unless `/psync chat on`.

## Building

```
python3 build.py                       # dist/PlaceholderSync-<version>.zip
python3 build.py --install             # also copy into World of Warcraft\_retail_\Interface\AddOns
python3 build.py --install --flavor _forever_
```

Names and the version come from `brand.json`. Tag `v<addonVersion>` to publish a release.

Only your own guild's data is recorded: the addon refuses another guild's bank, and the server refuses anything from a
guild other than the one the bridge token belongs to.
