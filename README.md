# Mochi

How much of your Claude, Codex, Antigravity and Cursor plans you've used, in your menu bar or around the notch, read straight from the tools you already have. Your coding agents alert you when they finish, fail or need you.

Turn on **Mochi** in Settings and a pixel pet lives on your screens too: it acts out what Claude or Codex is doing, wanders around, hops onto your windows, and nudges you to drink water, eat and get up.

![every pose](renders/_sheet.png)

## Download

1. Grab **Mochi.zip** from the [latest release](https://github.com/Joseph-Rus/mochi/releases/latest) (macOS 13 or newer, Apple Silicon or Intel).
2. Unzip it and drag **Mochi.app** into your Applications folder.
3. Open it. Mochi isn't notarized by Apple, so the first time macOS will say it can't verify the app. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Mochi. You only have to do this once.

   Or, from Terminal: `xattr -dr com.apple.quarantine /Applications/Mochi.app`

Mochi has no Dock icon. Its menu bar icon is your provider's logo with its usage beside it; click it for every provider's usage, **Settings…** and **Quit**. Opening the app again opens Settings.

AI Usage ([eli-manning/Ai-Usage](https://github.com/eli-manning/Ai-Usage)) is part of Mochi now: its usage sources, menu bar dropdown, notch view and agent hooks live here.

## Usage

Your plan's limits for Claude, Codex, Cursor and Antigravity: how much is used and when each resets. The menu bar shows the provider you picked; click it for all of them, each with its history over the last day or week. Prefer the notch? **Settings → General** moves it there: the logo and its % sit beside the notch, and resting the pointer on it opens an island with a ring for every limit and a tab for each provider. Right-click the island for Refresh, Settings and Quit.

Mochi reads each plan straight from the provider, with the sign-in its CLI already has on your Mac, and falls back if that doesn't answer:

| | First | Then | Last resort |
|---|---|---|---|
| Claude | Anthropic's usage API (Claude Code's sign-in, from the keychain) | Claude Code's status line, after every message, once connected | the `/usage` screen of `claude` |
| Codex | ChatGPT's usage API (`~/.codex/auth.json`) | Codex's own session logs | the `/status` screen of `codex` |
| Cursor | Cursor's usage API (cursor-agent's sign-in, or the editor's) | | the `/usage` screen of `cursor-agent` |
| Antigravity | Google Cloud Code's quota API (`agy`'s sign-in, from the keychain) | | the `/usage` screen of `agy` |

Every provider refreshes on its own, so a slow one never holds up the rest: the APIs every 2 minutes (Claude's every 5), a CLI screen at most every 15, and again whenever you open the dropdown or the island. When a provider says to slow down, Mochi waits 90 seconds, doubling up to 10 minutes. The last numbers you saw show straight away at launch and stay up, marked stale, if a check fails. Mochi never refreshes or stores a sign-in itself: an expired one waits for its CLI to renew it the next time you use it (for `agy`, Mochi runs `agy models`, which renews it and uses none of your plan). Reading a CLI's screen is a local command; it doesn't send a prompt or use any of your plan. Antigravity needs `agy`'s first-run setup finished once in a terminal before its usage can be read.

## Your agents

Connect each agent in **Settings → Agents** and restart its sessions. Finished, failed and waiting-on-you turns **wait for you**: a sound plays (and repeats, if you like) and a notification stays in Notification Center until you reply in that session or click the notification. Each kind has its own sound, and each can be turned off, in **Settings → Alerts**. Every connected agent alerts you.

## Mochi, the pet

Off until you turn it on in **Settings → Mochi** (or in setup). Pick whether it follows Claude or Codex. Drag it anywhere and let go (or throw it); click to boop it. Right-clicking it does nothing: its options are all in **Settings → Mochi**, with a **Dress up** menu for its costumes.

| You... | Mochi... |
|---|---|
| start or wake the computer (after 45+ min away) | is tired, yawns, sips a coffee, then asks if you want one |
| type | types on its laptop |
| type steadily for 6 min / 25 min | puts on headphones / becomes a coding wizard |
| only use the mouse | puts on a detective hat and investigates |
| stop touching anything for a bit | reads a book |
| step away (45 s+) | juggles or waters its plant |
| stay away (8 min+) | naps under a book (nightcap after 11pm) |
| come back from a break | waves, counts it as a break |
| have been at it 45 min without water | holds out a glass of water (turn off **drink water** in Settings) |
| have sat 55 min | puts on sneakers and asks you to walk with it |
| have sat way too long | turns into a TV |
| work 11:30–1:45 | puts on a chef hat: have you eaten? |
| hit a 2–4pm slump | offers coffee, an energy drink, or a walk (water after 3pm) |
| usually get coffee around now | reminds you, based on the last week |
| are up past 11pm | wears a nightcap and tells you to go to bed |

### Getting around

| You... | Mochi... |
|---|---|
| leave it be | strolls along the bottom of the screen now and then; when you step away it explores, hopping between windows |
| switch to an app | sometimes hops onto the top of that window (if there's room above it) |
| move the window it's sitting on | rides along. Yank it hard and Mochi gets knocked off |
| close or cover that window | falls to whatever is below |
| pick it up and let go | drops with gravity; toss it and it flies, bouncing off the screen edges |
| work on your other display for a while | follows you over |
| stop your pointer just above its head | jumps for it |
| wiggle your pointer right next to it | gets dizzy |

It sticks to the bottom of the screen and to windows with room above them: a window that reaches the menu bar has no top for it to stand on. When it's perched up high, its speech bubble shows up underneath it instead.

### Your Mac

| You... | Mochi... |
|---|---|
| join a call (camera or mic on) | shows a mute sign and holds every reminder until you're done |
| watch something fullscreen, or in VLC | eats popcorn, quietly |
| play music in Spotify or Music | puts on headphones and vibes (headphones + laptop if you're typing) |
| pause typing in VS Code, Cursor, Xcode, a terminal... | holds up a rubber duck |
| run the battery under 20% | looks drained and tells you; does a happy zap when you plug in |
| switch to dark / light mode | puts on a nightcap / sunglasses |

### Your agent

With its agent connected (say yes when Mochi offers, or use **Settings → Agents**), Mochi acts out what it's doing, in a terminal, an editor or a desktop app, and says a word about it:

| Your agent is... | Mochi... |
|---|---|
| thinking | looks up, thought dots over its head |
| reading files | reads a book: "reading App.tsx" |
| editing or writing code | types on its laptop: "editing pet.js" |
| searching the code / the web | puts on the detective hat / grabs binoculars |
| running a command | types into a green terminal |
| running tests, updating its plan | ticks off a checklist |
| committing or pushing | carries a parcel |
| running sub-agents | conducts, with two tiny helpers |
| compacting its memory | squishes |
| hitting an error | x eyes, a bead of sweat |
| waiting for your OK, or asking you something | hops over to your pointer with a "!" and asks; **show me** switches to the app that session is in |
| done | cheers, then holds a check mark: "done! your turn" |

A turn that's waiting for you also stays in Mochi's bubble until you reply, click **show me** or click **ok**.

The idea and the hook events come from [claude-desktop-pet](https://github.com/Harriszed/claude-desktop-pet) (MIT), rebuilt here natively with Mochi's own art.

With several sessions going, the most urgent one wins (anything that needs you first). Turn off **Say what it's doing** to only hear when your agent needs you or is done, or **Act out what it's doing** to ignore it altogether. Antigravity reports less than the others: no permission prompts.

It also cheers you on every 20–35 minutes, throws confetti on each hour you've worked, and gets heart eyes when you hover over it.

**Emoji** are off by default: Mochi's speech bubble uses little pixel icons instead. Turn on **Use Emoji** if you'd rather have them.

**Privacy:** with the pet on, Mochi reads macOS idle timers (seconds since the last key press or mouse move), the ID of the app in front (like `com.microsoft.VSCode`), where windows are on screen (positions only: no titles or contents), whether the camera, mic or speakers are in use (an on/off flag, never the audio or video), the battery level, and dark mode. It never sees what you type or what's in your windows. No permissions are needed and nothing leaves your Mac. Turn off **React to Apps & Calls** to stop it looking at apps, calls and music. State lives in `~/Library/Application Support/Mochi/state.json`.

**Your agents:** connecting Claude Code adds a hook script and a status line script (both in `~/Library/Application Support/Mochi/`) to `~/.claude/settings.json`, after backing it up to `settings.json.mochi-backup`. Your other settings, hooks and key order are kept, and a status line you already had keeps showing: Mochi's passes it through. Codex, Cursor and Antigravity get one small script (`hooks/mochi-hook.sh`) in their own config folder (`~/.codex`, `~/.cursor`, `~/.gemini/antigravity-cli`), added to their hooks file the same careful way. Codex runs new hooks only after you approve them with `/hooks`. The hooks run in the background, so they never slow anything down, and send each event (which tool, its file or command, the project folder) to Mochi over `127.0.0.1:47833`; nothing leaves your Mac. **Disconnect** takes it all back out.

## Settings

General (menu bar or notch, open at login, setup), Usage (each provider's status, sign in or install, turn one off), Agents (connect each CLI, its alerts), Alerts (sounds, repeats, notifications), Mochi (the pet: on or off, Claude or Codex, size, roaming, reminders, costumes) and About.

## Building

```sh
./build.sh           # → build/Mochi.app (universal)
./build.sh fast      # → build/Mochi.app for this Mac only, quicker
./build.sh install   # → ~/Applications/Mochi.app, and launches it
./build.sh release   # → build/Mochi.zip, ready to attach to a GitHub release
swift test           # MochiCore's tests: usage sources, hooks, sessions
```

Needs Xcode's Swift toolchain. Mochi is a Swift package: `MochiCore` (usage sources, agent hooks and sessions, settings; no AppKit, so it's tested headlessly), `ptydrive` (drives a CLI in a terminal, the last-resort usage source) and the `Mochi` app, whose windows are SwiftUI. The pet's page and the providers' logos live in `web/`. `web/preview.html` shows every pose in a browser (they follow your cursor).

To test reminders quickly: `MOCHI_SPEED=60 ~/Applications/Mochi.app/Contents/MacOS/Mochi` makes the reminder timers 60× faster. `MOCHI_ROAM=2` makes it explore as if you'd stepped away (`1` for the occasional stroll) and logs every move to the terminal. `MOCHI_TRACE=1` logs every pose and line.

To try the agent poses without an agent, post a hook event yourself (`/hook` is Claude Code's, `/hook/codex`, `/hook/cursor` and `/hook/antigravity` the others'):

```sh
curl -H 'X-Mochi: 1' --data '{"hook_event_name":"PreToolUse","session_id":"t","tool_name":"Edit","tool_input":{"file_path":"App.tsx"}}' http://127.0.0.1:47833/hook
```

Re-render the PNGs in `renders/`: `Mochi.app/Contents/MacOS/Mochi --render <folder>` (run it from a copy outside `~/Documents`).

## Files

- `Sources/Mochi/main.swift`: the pet: transparent always-on-top window, how Mochi gets around (screens and window tops become ledges; walking, hopping, falling, riding, being thrown), sensors (idle, sleep/wake, app in front, camera/mic, battery), its settings, saving.
- `Sources/Mochi/Agents.swift`: your agents: the local listener their hooks talk to, connecting each CLI, and the alerts that wait for you (`AlertCenter.swift`).
- `Sources/Mochi/UsageShell.swift`: where usage shows (the menu bar icon and dropdown in `Tray/`, or the notch in `Notch/`) and the Settings and setup windows (`Settings/`, `Wizard/`). `UsageDisplay.swift` is what each provider's numbers mean on screen, shared by all of them.
- `Sources/MochiCore/`: usage sources and `UsageService`, the hook payloads of every CLI (`AgentEvent.swift`) and what they add up to (`AgentSessions.swift`), installing hooks, settings.
- `web/pet.js`: Mochi. Every pose and prop is drawn as pixel strings on a 46×34 canvas. `web/looks.js` gives each provider its name and colour.
- `web/logos/`: each provider's logo (Gemini's as a PNG too: macOS leaves out its SVG's blurs).
- `web/brain.js`: decides what Mochi does and says, and how much it may roam right now (it stays put while you type).
- `web/icons.js`: pixel icons that stand in for emoji in the speech bubble.
- `web/pet.css`: Mochi's pixel speech bubble. Font: Jersey 15 (OFL, `web/fonts/OFL.txt`).

## Licenses

Mochi is MIT (`LICENSE`). The code that came from AI Usage (usage sources, agent hooks, the dropdown, notch, Settings and setup) is Apache 2.0, by Eli Manning (`LICENSES/AI-Usage-Apache-2.0.txt`).
