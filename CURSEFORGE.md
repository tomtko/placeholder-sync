PlaceholderSync is the in-game half of the Placeholder guild tools. It links what happens in the game to the guild's Discord bot and officer sheet. On its own it makes no network calls: addons cannot. It writes what it sees to its saved variables, and one officer's desktop bridge app uploads that file.

## What it does

**Sheet column in the loot council window.** When an item drops, RCLootCouncil and ForeverLoot show an extra Sheet column with who is in line for it on the officers' loot sheet. The data arrives through the bridge, and anyone who runs the addon receives a copy in game from a guildmate who has it, so only one person needs the bridge installed.

**Guild bank records.** Open the guild bank and the addon copies every tab, the gold and the transaction log. The bridge uploads it, and the guild gets a live stock board and bank history in Discord and on the sheet. Officers can see what is in the bank without logging in.

**Loot award copies.** Awards made through RCLootCouncil or ForeverLoot are recorded so the sheet's Loot Log fills itself. Test sessions are ignored.

## Who it is for

Members of a guild that runs the Placeholder bot and bridge. Raiders install the addon and get the Sheet column. One officer also installs the bridge app and links it to the guild's server. Without a server to talk to, the addon loads but has nothing to show.

## Install

1. Install the addon from CurseForge, or drop the zip into `Interface\AddOns`.
2. Officers: install the bridge from the guide at https://tomtko.github.io/placeholder-sync/ and click Link this PC.
3. Type `/psync` in game to see the status: which guild the data is for, when the bank was last scanned, and whether the loot sheet is current.

The addon is silent in chat by default. `/psync chat on` shows a line when a bank scan is saved or loot data arrives; `/psync help` lists the other settings.

## Privacy

Only your own guild's data is recorded. The addon refuses another guild's bank and awards, and the server refuses uploads from any guild other than the one a bridge token belongs to. Nothing leaves your machine unless you run the bridge yourself.

## Compatibility

Retail (Midnight) and WoW Forever. RCLootCouncil and ForeverLoot are optional: without a council addon you still get the bank and award features.

MIT licence. Source and issues: https://github.com/tomtko/placeholder-sync
