# PlaceholderSync

The World of Warcraft addon half of the Placeholder guild tools. It adds a **Sheet** column to the loot council window
(RCLootCouncil and ForeverLoot) showing who is in line for an item on the officers' sheet, records the guild bank and its
transaction log whenever the bank is opened, and copies loot council awards, so the officer running the bridge app can
upload them for the guild's Discord bot and sheet.

**Install guide for players and officers: https://tomtko.github.io/placeholder-sync/**

## Building

```
python3 build.py                       # dist/PlaceholderSync-<version>.zip
python3 build.py --install             # also copy into World of Warcraft\_retail_\Interface\AddOns
python3 build.py --install --flavor _forever_
```

Names and the version come from `brand.json`. Tag `v<addonVersion>` to publish a release.

Only your own guild's data is recorded: the addon refuses another guild's bank, and the server refuses anything from a
guild other than the one the bridge token belongs to.
