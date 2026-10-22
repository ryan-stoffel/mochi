# Mochi

A pixel critter that lives on your Mac's screens: it wanders around, hops onto your windows, copies what you're doing, and nudges you to drink water, eat, and get up.

![every pose](renders/_sheet.png)

## Download

1. Grab **Mochi.zip** from the [latest release](https://github.com/Joseph-Rus/mochi/releases/latest) (macOS 13 or newer, Apple Silicon or Intel).
2. Unzip it and drag **Mochi.app** into your Applications folder.
3. Open it. Mochi isn't notarized by Apple, so the first time macOS will say it can't verify the app. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Mochi. You only have to do this once.

   Or, from Terminal: `xattr -dr com.apple.quarantine /Applications/Mochi.app`

Mochi has no Dock or menu bar icon. Right-click it for its panel; **Quit Mochi** is at the bottom of Settings. If you hide Mochi, open the app again to bring it back.

## What it does

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

### Claude Code

Connect it from the panel (**Settings → Claude Code → Connect**, or say yes when Mochi offers) and restart your Claude Code sessions. From then on Mochi acts out what Claude is doing, in a terminal, an editor or the Claude app, and says a word about it:

| Claude is... | Mochi... |
|---|---|
| thinking | looks up, thought dots over its head |
| reading files | reads a book: "reading App.tsx" |
| editing or writing code | types on its laptop: "editing pet.js" |
| searching the code / the web | puts on the detective hat / grabs binoculars |
| running a command | types into a green terminal |
| running tests, updating its plan | ticks off a checklist |
| committing or pushing | carries a parcel |
| running sub-agents | conducts, with two tiny helper Mochis |
| compacting its memory | squishes |
| hitting an error | x eyes, a bead of sweat |
| waiting for your OK, or asking you something | hops over to your pointer with a "!" and asks; **show me** switches to the app that session is in |
| done | cheers: "done! your turn" |

The idea and the hook events come from [claude-desktop-pet](https://github.com/Harriszed/claude-desktop-pet) (MIT), rebuilt here natively with Mochi's own art.

With several sessions going, the most urgent one wins (anything that needs you first). Turn off **Say What Claude Is Doing** to only hear when Claude needs you or is done, or **Act Out What Claude Is Doing** to ignore it altogether.

### Usage

The panel's Usage tab shows how much of your 5-hour and weekly limits you've used and when each resets, like [AI Usage](https://github.com/eli-manning/Ai-Usage). Pro and Max plans only. It stays current two ways:

- **as you work**: Claude Code's status line hands Mochi the new numbers after every message (once Claude Code is connected);
- **on a timer**: every 5 minutes, and when you open the panel with numbers more than a minute old, Mochi runs `claude /usage` out of sight and reads the screen, like AI Usage does. It's a local command, so it doesn't send a prompt or use up your plan. Turn it off in Settings with **Check usage every 5 minutes**.

It also cheers you on every 20–35 minutes, throws confetti on each hour you've worked, and gets heart eyes when you hover over it.

**Emoji** are off by default: Mochi's speech bubble uses little pixel icons instead. Turn on **Use Emoji** if you'd rather have them.

**Privacy:** Mochi reads macOS idle timers (seconds since the last key press or mouse move), the ID of the app in front (like `com.microsoft.VSCode`), where windows are on screen (positions only: no titles or contents), whether the camera, mic or speakers are in use (an on/off flag, never the audio or video), the battery level, and dark mode. It never sees what you type or what's in your windows. No permissions are needed and nothing leaves your Mac. Turn off **React to Apps & Calls** to stop it looking at apps, calls and music. State lives in `~/Library/Application Support/Mochi/state.json`.

**Claude Code:** connecting adds a hook script and a status line script (both in `~/Library/Application Support/Mochi/`) to `~/.claude/settings.json`, after backing it up to `settings.json.mochi-backup`. Your other settings, hooks and key order are kept, and a status line you already had keeps showing: Mochi's passes it through. The hooks run in the background, so they never slow Claude down, and send each event (which tool, its file or command, the project folder) to Mochi over `127.0.0.1:47833`; nothing leaves your Mac. The status line passes along your plan's usage percentages and context use. The 5-minute usage check runs Claude Code in `~/Library/Application Support/Mochi/`, so it shows up there in Claude Code's session history; Mochi ignores its own check's hooks. **Disconnect Claude Code** takes it all back out.

## Using it

- **Drag** Mochi anywhere and let go (or throw it). **Click** to boop it.
- **Right-click Mochi** for its panel: a big speech bubble over its head, while Mochi holds up a gear. Right-click again, click anywhere else or press Escape to close it. It has five tabs:
  - **Usage**: how much of your Claude plan's 5-hour and weekly limits you've used, and when each resets, and your Claude Code sessions (click one to jump to it). Connect Claude Code from here too.
  - **Today**: time at the computer, how long you've been sitting, water, coffee, energy drinks and breaks, and buttons to log them.
  - **Play**: cheer me on, how am I doing, play ball, water the plant, **Sit on My Window**, **Go Explore**.
  - **Dress up**: Mochi in every costume, live; click one and Mochi wears it for a little while, click it again to take it off.
  - **Settings** (the gear): size, roaming (off keeps it exactly where you put it, no gravity), reacting to apps and calls, emoji, open at login; a switch for each reminder (water, walks, stretches, lunch, coffee, bedtime, cheering) and the quiet hour; Claude Code, including whether the Usage tab lists your sessions.

## Building

```sh
./build.sh           # → build/Mochi.app
./build.sh install   # → ~/Applications/Mochi.app, and launches it
./build.sh release   # → build/Mochi.zip, ready to attach to a GitHub release
```

Needs Xcode's Swift toolchain. `web/preview.html` shows every pose in a browser (they follow your cursor).

To test reminders quickly: `MOCHI_SPEED=60 ~/Applications/Mochi.app/Contents/MacOS/Mochi` makes the reminder timers 60× faster. `MOCHI_ROAM=2` makes it explore as if you'd stepped away (`1` for the occasional stroll) and logs every move to the terminal. `MOCHI_TRACE=1` logs every pose and line.

To try the Claude Code poses without Claude, post a hook event yourself:

```sh
curl -H 'X-Mochi: 1' --data '{"hook_event_name":"PreToolUse","session_id":"t","tool_name":"Edit","tool_input":{"file_path":"App.tsx"}}' http://127.0.0.1:47833/hook
```

Re-render the PNGs in `renders/`: `Mochi.app/Contents/MacOS/Mochi --render <folder>` (run it from a copy outside `~/Documents`).

## Files

- `Sources/Claude.swift`: Claude Code: the local listener its hooks talk to, what each session is doing, usage limits, and connecting/disconnecting `~/.claude/settings.json`.
- `Sources/Panel.swift`: the panel's window, which points at Mochi, and the messages to and from its page.
- `Sources/main.swift`: the Mac app: transparent always-on-top window, how Mochi gets around (screens and window tops become ledges; walking, hopping, falling, riding), sensors (idle, sleep/wake, app in front, camera/mic, battery), the panel's actions, saving.
- `web/pet.js`: the critter. Every pose and prop is drawn as pixel strings on a 46×34 canvas.
- `web/brain.js`: decides what Mochi does and says, and how much it may roam right now (it stays put while you type).
- `web/icons.js`: pixel icons that stand in for emoji in the speech bubble.
- `web/pet.css`: pixel speech bubble. Font: Jersey 15 (OFL, `web/fonts/OFL.txt`).
- `web/panel.html`, `web/panel.js`: the panel, drawn as a big speech bubble. Open `panel.html` in a browser to work on it with sample data (`?tab=closet` and so on).
