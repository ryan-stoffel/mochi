/* Mochi's brain: watches how you use the computer (only idle timers, never what you type)
   and decides what Mochi does and says. Runs inside the desktop app; also works in a browser tab. */
(() => {
  'use strict';
  const ENV = window.MOCHI_ENV || {};
  const params = new URLSearchParams(location.search);
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mochi;
  const post = (m) => { try { if (native) native.postMessage(m); } catch (e) { /* app went away */ } };
  const log = (msg) => { post({ type: 'log', msg }); if (!native) console.log('[mochi]', msg); };
  addEventListener('error', (e) => log(`error: ${e.message} (line ${e.lineno})`));
  const trace = ENV.trace ? log : () => {};   // MOCHI_TRACE=1: log every pose and line to the terminal

  const petEl = document.getElementById('pet');
  const bubbleEl = document.getElementById('bubble');
  const wrapEl = document.getElementById('bubbleWrap');
  const view = new Critter(petEl, { scale: +(params.get('scale') || ENV.scale || 6) });

  // the window: Mochi at the bottom (above a strip kept free for a bubble below it), a bubble above
  const layout = { w: ENV.w || 320, h: ENV.h || 360, below: ENV.below || 0 };
  function applyLayout() {
    const st = document.getElementById('stage').style, k = view.scale;
    st.setProperty('--w', layout.w + 'px');
    st.setProperty('--h', layout.h + 'px');
    st.setProperty('--pet-left', (layout.w - 46 * k) / 2 + 'px');
    st.setProperty('--pet-bottom', layout.below + 'px');
    st.setProperty('--bubble-above', layout.below + 22 * k + 6 + 'px');
    st.setProperty('--bubble-below', layout.h - layout.below + 10 + 'px');
  }
  applyLayout();

  // ---------- render mode: the app snapshots each pose to PNG ----------
  if (params.has('render') || window.MOCHI_RENDER) {
    document.documentElement.classList.add('render');
    bubbleEl.hidden = true;
    window.renderPose = (name) => { view.parts = []; view.current = null; view.pose(name); return Critter.POSES; };
    window.renderList = () => Critter.POSES;
    return;
  }

  const SEC = 1000, MIN = 60 * SEC;
  const SPEED = Math.max(1, +(ENV.speed || params.get('speed') || 1)); // testing: compress reminder timers
  const CFG = {
    activeIdle: 60,              // s without input that still counts as "at the computer"
    awayIdle: 45,                // s idle → Mochi starts playing with its toys
    sleepIdle: 8 * 60,           // s idle → Mochi naps
    breakIdle: 5 * 60,           // s away that counts as a real break
    walkBreak: 2 * 60,           // s away that counts as the walk you agreed to
    freshGap: 45 * 60,           // s asleep / locked / away → treat it like the computer just started
    water: (45 * 60) / SPEED,    // active s between water nudges
    walk: (55 * 60) / SPEED,     // continuous sitting s before a walk nudge
    stretch: (25 * 60) / SPEED,  // continuous sitting s between stretch tips
    hour: 3600 / SPEED,          // "an hour" for milestones
    cheer: [(18 * 60) / SPEED, (35 * 60) / SPEED],
    night: (40 * 60) / SPEED,
    bubbleGap: 100 / Math.min(SPEED, 10),
  };

  // ---------- helpers ----------
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const pick = (xs) => xs[(Math.random() * xs.length) | 0];
  const avg = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
  const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[s.length >> 1]; };
  const hour = (t) => new Date(t).getHours();
  // minutes since midnight, with 00:00–03:59 counted as the end of the previous day
  const mod = (t) => { const d = new Date(t); const m = d.getHours() * 60 + d.getMinutes(); return m < 240 ? m + 1440 : m; };
  const dayKey = (t) => { const d = new Date(t - 4 * 3600 * SEC); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const isNight = (t) => { const h = hour(t); return h >= 23 || h < 4; };
  const clock = (t) => new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).toLowerCase().replace(' ', '');
  function fmt(sec) {
    const m = Math.round(sec / 60);
    if (m < 1) return 'a minute';
    if (m < 60) return m + ' min';
    const h = Math.floor(m / 60), mm = m % 60;
    return mm ? `${h}h ${mm}m` : `${h}h`;
  }

  // ---------- memory (saved by the app to ~/Library/Application Support/Mochi/state.json) ----------
  const newDay = (t) => ({ date: dayKey(t), active: 0, water: 0, coffee: 0, energy: 0, breaks: 0, walks: 0, milestones: 0, longestSit: 0, first: null, last: null, coffeeAt: [], flags: {} });
  const saved = window.MOCHI_SAVED && window.MOCHI_SAVED.v === 1 ? window.MOCHI_SAVED : null;
  const S = Object.assign({ v: 1, born: Date.now(), day: newDay(Date.now()), sit: 0, waterAt: 0, stretchAt: 0, lastTick: 0, energy: 0.5, quietUntil: 0, nightAt: 0, history: [] }, saved || {});

  const R = {
    now: Date.now(), scene: null, queue: [], typing: [], ti: 0, flowSince: 0,
    away: false, awayMax: 0, presentSince: Date.now(), hover: false, hoverSince: 0,
    lastBubble: 0, nextCheer: Date.now() + 8 * MIN / SPEED, cheerDefer: 0, snooze: {},
    walkPending: 0, walkNagged: false, ambient: '', ambientAt: 0, toyIdx: (Math.random() * 3) | 0, toyAt: 0,
    readAt: Date.now(), readUntil: 0, freshAt: 0, groggy: false, wakeSeq: 0, dragging: false,
    pokes: [], last: null, savedAt: 0, statsAt: 0, hotStr: '',
    move: null, landUntil: 0, dizzyUntil: 0, roam: -1, room: { above: 1e9, left: 1e9, right: 1e9 },
    sys: {}, sysSeen: false, callStart: 0, callCam: false, batt20: false, batt10: false, zapAt: 0, appLineAt: 0, rideAt: 0, blurtT: 0,
  };
  const IDLE = { idle: 0, kbIdle: 99, mouseIdle: 0 };

  function save() { R.savedAt = R.now; post({ type: 'save', data: JSON.stringify(S) }); }

  function rollDay(t) {
    if (dayKey(t) === S.day.date) return;
    const d = S.day;
    if (d.active > 300) S.history.push({ date: d.date, first: d.first, last: d.last, active: Math.round(d.active), water: d.water, coffee: d.coffee, coffeeAt: d.coffeeAt });
    S.history = S.history.slice(-14);
    S.day = newDay(t);
    S.waterAt = 0;
    S.nightAt = 0;
  }

  // ---------- your patterns ----------
  const recent = () => S.history.slice(-7);
  const usualStart = () => { const xs = recent().map((d) => d.first).filter((x) => x != null); return xs.length >= 3 ? median(xs) : null; };
  const usualEnd = () => { const xs = recent().map((d) => d.last).filter((x) => x != null && x > 15 * 60); return xs.length >= 3 ? median(xs) : null; };
  const coffeeHabitNow = (m) => recent().filter((d) => (d.coffeeAt || []).some((c) => Math.abs(c - m) <= 20)).length >= 2;
  const recentCoffee = (m) => S.day.coffeeAt.some((c) => m - c < 120);
  const isEarly = (t) => { const u = usualStart(); return u != null && mod(t) < u - 45; };

  // ---------- speech bubble ----------
  // emoji are off unless you turn them on: pixel icons stand in for them (icons.js)
  let emoji = ENV.emoji === true || params.get('emoji') === '1';
  // water reminders can be turned off in Settings; logging water from the panel still works
  let waterOn = ENV.water !== false;
  const bubble = {
    show(text, buttons, onChoose) {
      R.bubbleText = text;
      trace(`says: ${text}${buttons ? ' ' + JSON.stringify(buttons.map((b) => b[0])) : ''}`);
      R.bubbleButtons = buttons;
      MochiIcons.render(bubbleEl.querySelector('.b-text'), text, emoji);
      const box = bubbleEl.querySelector('.b-btns');
      box.innerHTML = '';
      (buttons || []).forEach(([label, id], i) => {
        const b = document.createElement('button');
        MochiIcons.render(b, label, emoji);
        if (i === 0) b.className = 'primary';
        b.addEventListener('click', (e) => { e.stopPropagation(); onChoose(id); });
        box.appendChild(b);
      });
      box.hidden = !(buttons && buttons.length);
      clearTimeout(R.blurtT);
      bubbleEl.hidden = false;
      placeBubble();
      bubbleEl.classList.remove('pop');
      void bubbleEl.offsetWidth;
      bubbleEl.classList.add('pop');
    },
    hide() { bubbleEl.hidden = true; },
  };
  // Above Mochi if it fits on the screen, below if Mochi is perched up high; nudged sideways near a screen edge.
  function placeBubble() {
    if (bubbleEl.hidden) return;
    const below = bubbleEl.offsetHeight + 16 > R.room.above;
    wrapEl.classList.toggle('below', below);
    const half = bubbleEl.offsetWidth / 2 + 8, max = Math.max(0, layout.w / 2 - half);
    const shift = clamp(R.room.left < half ? half - R.room.left : R.room.right < half ? R.room.right - half : 0, -max, max);
    bubbleEl.style.left = shift + 'px';
    bubbleEl.style.setProperty('--tail-x', -shift + 'px');
  }
  // a quick line that doesn't interrupt anything
  function blurt(text, ms = 2000) {
    if (R.scene || hush()) return;
    bubble.show(text, null, choose);
    R.blurtT = setTimeout(() => { if (!R.scene) bubble.hide(); }, ms);
  }

  // ---------- scenes: a pose + maybe a line + maybe a question ----------
  function play(sc) {
    if (R.scene) { const old = R.scene; R.scene = null; if (old.buttons && old.onChoose && !sc.fromChoice) old.onChoose('timeout'); }
    R.scene = Object.assign({ start: R.now }, sc);
    R.scene.until = R.now + (sc.dur || 5) * SEC;
    if (!R.move && !R.dragging) { view.pose(sc.pose || 'idle'); trace(`scene: ${sc.pose || 'idle'}`); }
    if (sc.fx) view.burst(sc.fx, sc.fxN || 5);
    if (sc.say) {
      bubble.show(sc.say, sc.buttons, choose);
      R.lastBubble = R.now;
      R.scene.bubbleUntil = sc.sayFor ? R.now + sc.sayFor * SEC : 0;
    } else bubble.hide();
    R.ambient = '';
    updateRoam();
  }
  function say(pose, text, dur = 6, fx, extra) { play(Object.assign({ pose, say: text, dur, fx }, extra || {})); }
  function ask(pose, text, buttons, onChoose, extra) { play(Object.assign({ pose, say: text, buttons, onChoose, dur: 90 }, extra || {})); }
  function choose(c) {
    const sc = R.scene;
    if (!sc) return;
    R.scene = null;
    bubble.hide();
    R.ambient = '';
    if (sc.onChoose) { R.choosing = true; sc.onChoose(c); R.choosing = false; }
    save();
  }
  function endScene() {
    const sc = R.scene;
    R.scene = null;
    bubble.hide();
    R.ambient = '';
    if (!sc) return;
    if (sc.buttons && sc.onChoose) sc.onChoose('timeout');
    else if (sc.after) sc.after();
  }
  const seq = (list) => { R.queue.push(...list); if (!R.scene) play(R.queue.shift()); };
  const snooze = (what, min, line) => { R.snooze[what] = R.now + (min * MIN) / SPEED; if (line) say('idle', line, 4); };
  const quiet = () => R.now < S.quietUntil;
  const hush = () => quiet() || R.sys.busy;   // quiet hour, a call, or something fullscreen
  // a side remark: skipped while a question is waiting or Mochi should be quiet
  const aside = (pose, text, dur) => { if (!hush() && !(R.scene && R.scene.buttons)) say(pose, text, dur); };

  // ---------- the things Mochi says ----------
  const CHEERS = [
    "you're doing great!", 'look at you go ✨', "one thing at a time. you've got this",
    'proud of you, just so you know 💜', 'small steps still count', 'keep going! i believe in you',
    "hey. you're doing better than you think", "i'm cheering for you! literally", 'you + focus = unstoppable 🔥',
  ];
  function cheerLine(t) {
    const d = new Date(t), h = d.getHours(), wd = d.getDay();
    const xs = [...CHEERS];
    if (h < 11) xs.push("let's make today a good one ☀️");
    if (wd === 5 && h >= 12) xs.push("it's friday! almost there 🎉");
    if (wd === 1 && h < 12) xs.push("monday, but make it cute");
    if (R.flowSince) xs.push("you're in the zone! i'll keep it short. go go go");
    if (S.day.water >= 4) xs.push(`${S.day.water} waters today. your cells are throwing a party 💧`);
    return pick(xs);
  }
  const POKES = ['hehe', 'boop!', 'that tickles!', 'hi hi!', '💜', 'yes? :3', 'i like you too'];
  const STRETCHES = [
    ['stretch', 'reach up high with me! ✨'],
    ['stretch', 'shoulders up to your ears... and drop. ahh'],
    ['lookfar', 'look at something far away for 20 seconds 👀 your eyes will thank you'],
    ['stretch', 'roll your neck a little. slooowly'],
    ['stretch', 'sit up tall for a sec. there you go'],
  ];

  function statsLine() {
    const D = S.day;
    const hrs = D.active / 3600;
    const note = D.water < Math.floor(hrs) ? 'maybe a little more water? 💧' : D.breaks === 0 && hrs > 1.5 ? 'no breaks yet... just saying 👀' : "you're taking good care of yourself ✨";
    return `today: ${fmt(D.active)} at the computer, sitting for ${fmt(S.sit)} right now. 💧${D.water}  ☕${D.coffee}${D.energy ? '  ⚡' + D.energy : ''}  🚶${D.breaks}. ${note}`;
  }

  // ---------- coffee / water / walks ----------
  function coffeeYes() {
    S.day.coffee++;
    S.day.coffeeAt.push(mod(R.now));
    S.energy = Math.min(1, S.energy + 0.45);
    R.groggy = false;
    say('cheer', pick(["coffee buddies! ✨ let's have a good one", "yay! okay, now we're awake", 'cheers ☕ to a good day']), 6, 'sparkle');
  }
  const caffeine = () => S.day.coffee + (S.day.energy || 0);
  function energyYes() {
    S.day.energy = (S.day.energy || 0) + 1;
    S.day.coffeeAt.push(mod(R.now));
    S.energy = Math.min(1, S.energy + 0.5);
    R.groggy = false;
    say('sipEnergy', pick(["*crack* *fssst* ⚡ ok LET'S GO", 'energy acquired ⚡ water chaser later, ok?', '*glug* i can hear colors now ⚡']), 6);
  }
  function waterYes() {
    S.day.water++;
    S.waterAt = S.day.active;
    R.snooze.water = 0;
    say('sipWater', pick(['*gulp gulp* ahh ✨', `hydrated! that's ${S.day.water} today 💧`, 'good job! i had some too 💧']), 5, 'drop');
  }
  function askWater() {
    const since = fmt(S.day.active - S.waterAt);
    ask('water', pick([`you've been going ${since}. sip of water? 💧`, "hydration check! i've got mine 💧", 'water break? a tiny sip counts 💧']),
      [['💧 done', 'yes'], ['in a bit', 'later']],
      (c) => (c === 'yes' ? waterYes() : snooze('water', 15, c === 'later' ? "okay! i'll hold it for you 💧" : null)));
  }
  function askWalk() {
    const t = fmt(S.sit);
    if (S.sit > CFG.walk * 1.4) {
      return ask('tv', `we've been sitting ${t}. i literally turned into a screen 📺 walk?`, [["🚶 let's go", 'yes'], ['10 more min', 'later']],
        (c) => (c === 'yes' ? startWalk() : snooze('walk', c === 'later' ? 10 : 15, c === 'later' ? 'okay... beep boop 📺' : null)));
    }
    ask('walkAsk', pick([`you've been sitting for ${t}. stand up and walk with me? 🚶`, `${t} in the chair! quick walk? i'll come too`, 'legs check! time to get up for a few minutes 🚶']),
      [["🚶 let's go", 'yes'], ['10 more min', 'later']],
      (c) => (c === 'yes' ? startWalk() : snooze('walk', c === 'later' ? 10 : 15, c === 'later' ? 'okay, 10 more minutes ⏰' : null)));
  }
  function startWalk() {
    R.walkPending = R.now;
    R.walkNagged = false;
    play({ pose: 'walk', say: pick(["yay! i'll keep your seat warm 🚶", 'walk walk walk ✨ see you in a bit']), sayFor: 6, dur: 6 * 60, kind: 'walk',
      after() { if (R.away) return; R.walkPending = 0; snooze('walk', 15); } });
  }

  // ---------- waking up (computer just started, woke from sleep, or you were gone for a long time) ----------
  function freshStart(why) {
    const t = R.now;
    if (t - R.freshAt < 10 * MIN) return;
    R.freshAt = t;
    R.queue = [];
    R.scene = null;
    bubble.hide();
    R.walkPending = 0;
    S.sit = 0;
    S.stretchAt = 0;
    const h = hour(t);
    S.energy = h >= 4 && h < 12 ? (isEarly(t) ? 0.1 : 0.18) : h < 18 ? 0.38 : 0.3;
    R.groggy = true;
    R.wakeSeq = t;
    R.ambient = '';
    log('fresh start: ' + why);
  }
  function wakeSequence() {
    const t = R.now, h = hour(t);
    const caffeine = h >= 4 && h < 15 && S.day.coffee < 3;
    const early = isEarly(t);
    const greet = h < 4 ? "it's so late... or is it early? *yawn*"
      : early ? "you're up early... *yaaawn*"
      : h < 11 ? pick(['*yaaawn* ...oh. morning already?', 'mmh... five more minutes...', '*yawn* good morning...'])
      : h < 17 ? "*yawn* oh hey, you're back" : '*yawn* evening already?';
    seq([
      { pose: 'yawn', say: greet, dur: 5 },
      caffeine
        ? { pose: 'sip', say: '*sip*... okay. coffee is helping.', dur: 7, after() { S.energy += 0.15; } }
        : { pose: 'sipWater', say: '*sip*... water. good.', dur: 6, after() { S.energy += 0.1; } },
      caffeine
        ? { pose: 'offerCoffee', say: 'you look sleepy too. get yourself a coffee? ☕', dur: 90, buttons: [['☕ getting one', 'yes'], ['not today', 'no']],
            onChoose: (c) => (c === 'yes' ? coffeeYes() : c === 'no' ? say('coffee', "fair! water then? i'll sip for both of us 💧", 6) : null) }
        : waterOn && { pose: 'water', say: 'grab some water too? 💧', dur: 90, buttons: [['💧 okay', 'yes'], ['later', 'no']],
            onChoose: (c) => (c === 'yes' ? waterYes() : snooze('water', 15)) },
    ].filter(Boolean));
  }

  function onReturn(was) {
    R.presentSince = R.now;
    if (was >= CFG.freshGap) return freshStart('back after ' + Math.round(was / 60) + ' min');
    const walked = R.walkPending && was >= CFG.walkBreak;
    if (was >= CFG.breakIdle || walked) {
      S.day.breaks++;
      S.sit = 0;
      S.stretchAt = 0;
      S.energy = Math.min(1, S.energy + 0.2);
    }
    if (walked) {
      S.day.walks++;
      R.walkPending = 0;
      R.scene = null;
      return say('wave', pick(['welcome back! feel better? 🌿', 'nice walk! legs: refreshed ✨', `you did it! walk #${S.day.walks} today 🚶`]), 7, 'sparkle');
    }
    if (R.scene && R.scene.buttons) return; // a question is still waiting for you
    if (hush()) return;
    if (was >= CFG.sleepIdle) return say('surprised', pick(["oh! you're back ✨", 'hi! i was napping a little', 'welcome back! missed you 💜']), 5, 'bang', { fxN: 1 });
    if (was >= CFG.breakIdle) return say('wave', pick(['welcome back!', 'there you are! good break?', "you're back ✨"]), 5);
  }

  // ---------- unprompted nudges, most important first ----------
  function maybeNudge(t, s) {
    if (s.idle > 20) return; // you're not looking
    if (hush()) return;
    if (R.wakeSeq && t - R.presentSince > 12 * SEC) { R.wakeSeq = 0; return wakeSequence(); }
    if ((t - R.lastBubble) / SEC < CFG.bubbleGap) return;
    const D = S.day, F = D.flags, h = hour(t), m = mod(t);
    const flow = R.flowSince && t - R.flowSince > 3 * MIN;

    if (isNight(t) && t - S.nightAt > CFG.night * SEC) {
      S.nightAt = t;
      return say('night', pick([`it's ${clock(t)}... the work will still be here tomorrow 🌙`, 'sleepy o\'clock. save your stuff and rest soon?', `${clock(t)}! your future self wants you asleep 💤`]), 10, 'z', { fxN: 2 });
    }
    if (S.sit >= CFG.walk && t >= (R.snooze.walk || 0)) return askWalk();
    if (waterOn && D.active - S.waterAt >= CFG.water && t >= (R.snooze.water || 0)) return askWater();
    if (!F.patternCoffee && h >= 6 && h < 15 && caffeine() < 3 && coffeeHabitNow(m) && !recentCoffee(m)) {
      F.patternCoffee = 1;
      return ask('offerCoffee', 'you usually grab a coffee around now ☕ want one?', [['☕ yes please', 'yes'], ['skip today', 'no']], (c) => (c === 'yes' ? coffeeYes() : null));
    }
    if (!F.lunch && m >= 11 * 60 + 30 && m <= 13 * 60 + 45 && D.active > 20 * 60 / SPEED && t >= (R.snooze.lunch || 0)) {
      return ask('chef', pick(["lunch time? i'm making pancakes 🥞 have you eaten?", "it's lunch o'clock 🍳 go eat something?"]),
        [['🍽 going to eat', 'yes'], ['already ate', 'ate'], ['later', 'later']], (c) => {
          if (c === 'yes') { F.lunch = 1; return say('wave', "enjoy! i'll guard the desk 🛡", 5); }
          if (c === 'ate') { F.lunch = 1; return say('content', 'nice. fueled up ✨', 4); }
          snooze('lunch', 30, c === 'later' ? "okay, i'll keep the pan warm 🍳" : null);
        });
    }
    if (!F.slump && h >= 14 && h < 16 && S.energy < 0.5 && S.sit > 20 * 60 / SPEED) {
      F.slump = 1;
      if (h < 15 && caffeine() < 3) return ask('energy', 'afternoon slump? coffee, energy drink, or a quick walk?', [['☕ coffee', 'coffee'], ['⚡ energy', 'energy'], ['🚶 walk', 'walk']],
        (c) => (c === 'coffee' ? coffeeYes() : c === 'energy' ? energyYes() : c === 'walk' ? startWalk() : null));
      if (waterOn) return ask('water', "afternoon slump? it's late for caffeine, so you sleep okay. water + a stretch? 💧", [['💧 okay', 'yes'], ['nah', 'no']], (c) => (c === 'yes' ? waterYes() : null));
    }
    const ue = usualEnd();
    if (!F.wrap && ue != null && m >= ue - 15 && m <= ue + 30 && D.active > 2 * CFG.hour) {
      F.wrap = 1;
      return say('proud', "this is usually around when you wrap up. almost there 🌙", 8);
    }
    const hrs = Math.floor(D.active / CFG.hour);
    if (hrs > D.milestones) {
      D.milestones = hrs;
      return say('party', hrs === 1 ? 'one whole hour today! 🎉' : `${hrs} hours today! 🎉 ${pick(['look at you', 'proud of you', 'what a day'])}`, 7);
    }
    if (!F.long && D.active >= 6 * CFG.hour) {
      F.long = 1;
      return say('proud', `${fmt(D.active)} today. proud of you, go easy 💜`, 8);
    }
    if (S.sit - S.stretchAt >= CFG.stretch && S.sit < CFG.walk - 5 * 60 / SPEED) {
      S.stretchAt = S.sit;
      const [pose, line] = pick(STRETCHES);
      return say(pose, line, 9);
    }
    if (t >= R.nextCheer) {
      if (flow && R.cheerDefer < 2) { R.cheerDefer++; R.nextCheer = t + 5 * MIN / SPEED; return; }
      R.cheerDefer = 0;
      R.nextCheer = t + (CFG.cheer[0] + Math.random() * (CFG.cheer[1] - CFG.cheer[0])) * SEC;
      return say('cheer', cheerLine(t), flow ? 3.5 : 5);
    }
  }

  // ---------- Claude Code: what it's up to (main.swift hears about it from Claude Code's hooks) ----------
  const CLAUDE_POSES = {
    waiting: 'needsYou', error: 'oops', compacting: 'squish', agents: 'conduct', reading: 'read', writing: 'type',
    searchCode: 'detective', searchWeb: 'binoculars', command: 'terminal', testing: 'clipboard', server: 'terminal',
    committing: 'ship', plan: 'clipboard', tool: 'terminal', thinking: 'think', contextFull: 'sweaty', done: 'cheer', hello: 'wave',
  };
  const C = { on: ENV.claude !== false, narrate: ENV.narrate !== false, state: '', d: {}, said: '', saidAt: 0 };
  const claudePose = () => (C.on && C.state ? CLAUDE_POSES[C.state] : null);
  // Claude's news still gets said in a fullscreen app (that's often where you code), just not on a call or in a quiet hour
  const claudeHush = () => quiet() || R.sys.call;
  function claudeSay(text, ms) {
    if (R.scene || claudeHush()) return;
    bubble.show(text, null, choose);
    R.blurtT = setTimeout(() => { if (!R.scene) bubble.hide(); }, ms);
  }
  function claudeLine(d) {
    const x = d.detail ? ' ' + d.detail : '';
    const where = d.sessions > 1 && d.project ? ` in ${d.project}` : '';
    switch (d.state) {
      case 'waiting': return d.need === 'question' ? `claude has a question for you${where}` : `claude needs your ok${d.needTool ? ' to use ' + d.needTool : ''}${where}`;
      case 'error': return `hmm, that didn't work${d.detail ? ': ' + d.detail : ''}`;
      case 'compacting': return 'claude is tidying up its memory...';
      case 'agents': return d.helpers > 1 ? `${d.helpers} helpers on it!` : 'sent a helper off to work';
      case 'reading': return 'reading' + x;
      case 'writing': return (d.tool === 'Write' ? 'writing' : 'editing') + x;
      case 'searchCode': return d.detail ? `looking for ${d.detail}` : 'searching the code';
      case 'searchWeb': return d.tool === 'WebFetch' ? 'reading' + (x || ' a page') : d.detail ? `looking up ${d.detail}` : 'searching the web';
      case 'testing': return 'running the tests...';
      case 'committing': return /push/i.test(d.detail) ? 'pushing it up!' : 'committing!';
      case 'server': return 'starting the server';
      case 'command': case 'tool': return d.detail || 'running a command';
      case 'plan': return d.todo ? `updating the plan: ${d.todo[0]} of ${d.todo[1]} done` : 'making a plan';
      case 'contextFull': return "claude's memory is almost full";
      case 'done': return pick(['all done! :check:', 'done! :check: your turn', 'finished! :check:']) + where;
      case 'hello': return `ooh, claude code${d.project ? ' in ' + d.project : ''}! i'll follow along`;
    }
    return '';
  }
  function onClaude(d) {
    const t = (R.now = Date.now());
    const was = C.state;
    C.d = d;
    C.state = d.state || '';
    if (!C.on) return;
    const sc = R.scene;
    if (C.state === 'waiting' && was !== 'waiting') {
      if (sc && sc.kind !== 'claude') endScene();
      if (!claudeHush()) {
        play({ pose: 'needsYou', say: claudeLine(d), dur: 30 * 60, kind: 'claude', buttons: [[':hand: show me', 'go'], ['ok', 'ok']],
          onChoose: (c) => { if (c === 'go') post({ type: 'claudeFocus' }); } });
      }
    } else if (was === 'waiting' && C.state !== 'waiting' && sc && sc.kind === 'claude') {
      R.scene = null;
      bubble.hide();
    }
    if (C.state && C.state !== 'waiting') {
      const line = claudeLine(d), key = C.state + '|' + (d.detail || '');
      // say when it's done; narrate the rest only if you want that, and never more than every few seconds
      const worth = C.state === 'done' || (C.narrate && C.state !== 'thinking' && (['error', 'hello'].includes(C.state) || t - C.saidAt > 7 * SEC));
      if (line && worth && key !== C.said) { C.said = key; C.saidAt = t; claudeSay(line, C.state === 'done' ? 3500 : 2600); }
      if (C.state === 'done' && was !== 'done') view.burst('sparkle', 6);
    }
    R.ambient = '';
    ambient(t, R.last || IDLE);
    updateRoam();
  }

  // ---------- what Mochi does when nothing's going on: mirror you ----------
  const TOYS = ['juggle', 'plant'];
  const MOVE_POSES = { walk: 'stroll', crouch: 'crouch', jump: 'jump', fall: 'fall' };
  const lowBattery = () => R.sys.battery != null && !R.sys.plugged && R.sys.battery <= 0.15;
  function ambient(t, s) {
    if (!s) return;
    let p;
    const cp = claudePose();
    const urgent = R.dragging || R.move || t < R.landUntil || t < R.dizzyUntil || !!cp;
    if (R.dragging) p = 'dangle';
    else if (R.move) p = MOVE_POSES[R.move] || 'stroll';
    else if (t < R.landUntil) p = 'land';
    else if (t < R.dizzyUntil) p = 'dizzy';
    else if (R.scene) return;
    else if (R.menu) p = 'tinker';                           // its panel is open
    else if (R.sys.call) p = 'shh';
    else if (cp) p = cp;                                     // acting out what Claude Code is doing
    else if (s.idle >= CFG.sleepIdle) p = isNight(t) ? 'nightSleep' : 'nap';
    else if (s.idle >= CFG.awayIdle) {
      if (t - R.toyAt > 50 * SEC) { R.toyIdx++; R.toyAt = t; }
      p = TOYS[R.toyIdx % TOYS.length];
    }
    else if (R.hover && t - R.hoverSince > 900) p = 'love';
    else if (lowBattery()) p = 'lowbatt';
    else if ((R.sys.fullscreen || R.sys.kind === 'video') && s.kbIdle > 15) p = 'popcorn'; // watching something
    else if (R.groggy && S.energy < 0.42) p = 'tired';
    else if (R.flowSince && t - R.flowSince > 25 * MIN) p = 'wizard';
    else if (R.flowSince && t - R.flowSince > 6 * MIN) p = 'focus';
    else if (R.ti > 0.22) p = R.sys.music ? 'focus' : 'type';
    else if (R.sys.music) p = 'jam';
    else if (R.sys.kind === 'code' && s.kbIdle >= 4 && s.idle < 90) p = 'duck';           // thinking it through
    else if (isNight(t)) p = 'night';
    else if (S.sit > CFG.walk * 1.4) p = 'tv';
    else if (S.sit > CFG.walk * 1.15) p = 'sweaty';
    else if (s.idle >= 12) p = 'read';                       // you're reading or watching something
    else if (R.browseSince && t - R.browseSince > 30 * SEC) p = 'detective'; // mouse only: you're looking for something
    else p = S.energy < 0.3 ? 'tired' : S.energy > 0.8 ? 'content' : 'idle';

    if (p === R.ambient) return;
    const sticky = ['type', 'focus', 'wizard', 'detective', 'duck'].includes(R.ambient) && !['love', 'dangle', 'juggle', 'plant', 'read', 'nap', 'nightSleep', 'shh', 'dizzy'].includes(p);
    if (sticky && !urgent && t - R.ambientAt < 8 * SEC) return; // don't flicker between typing and not typing
    R.ambient = p;
    R.ambientAt = t;
    trace(`pose: ${p}`);
    view.pose(p);
  }
  // back to whatever Mochi should be doing after a hop, a fall or a drag
  function restorePose() {
    if (R.dragging || R.move || Date.now() < R.landUntil || Date.now() < R.dizzyUntil) return;
    R.ambient = '';
    if (R.scene) view.pose(R.scene.pose || 'idle'); else ambient(Date.now(), R.last || IDLE);
  }

  // ---------- roaming: how much the app may walk Mochi around right now ----------
  function roamLevel(t, s) {
    if (!s || R.dragging || hush()) return 0;
    if (R.scene && !bubbleEl.hidden) return 0;            // mid-sentence
    if (C.on && C.state === 'waiting') return 0;          // Claude needs you: stay where you can see it
    if (s.idle >= CFG.sleepIdle) return 0;                // napping
    if (R.ti > 0.22 || (R.flowSince && t - R.flowSince > 2 * MIN)) return 0; // you're typing: stay put, keep you company
    return s.idle >= CFG.awayIdle ? 2 : 1;                // you stepped away: go play
  }
  function updateRoam(s = R.last) {
    const lv = roamLevel(R.now, s);
    if (lv !== R.roam) { R.roam = lv; post({ type: 'roam', level: lv }); }
  }

  // ---------- your Mac: the app you're in, calls, battery, dark mode ----------
  const APPS = [
    ['code', /^(com\.microsoft\.VSCode|com\.todesktop\.230313mzl4w4u92|com\.apple\.dt\.Xcode|com\.neovide\.|com\.google\.android\.studio|cc\.arduino\.|com\.jetbrains\.|com\.sublimetext\.|dev\.zed\.|com\.apple\.Terminal|com\.googlecode\.iterm2|dev\.warp\.|com\.mitchellh\.ghostty)/],
    ['music', /^(com\.spotify\.client|com\.apple\.Music|com\.apple\.podcasts)/],
    ['video', /^(org\.videolan\.vlc|com\.apple\.TV|com\.apple\.QuickTimePlayerX|com\.colliderli\.iina)/],
    ['study', /^(net\.ankiweb\.|com\.gingerlabs\.Notability|md\.obsidian|notion\.id|com\.microsoft\.onenote|com\.microsoft\.Word|com\.study-stash\.)/],
    ['game', /^(com\.valvesoftware\.steam)/],
  ];
  const appKind = (id) => (APPS.find(([, re]) => re.test(id || '')) || [''])[0];
  const APP_LINES = {
    code: ["code time! i'll be your rubber duck 🦆", 'ooh, coding. quack if you need me 🦆'],
    music: ['ooh, what are we listening to? 🎧'],
    study: ['study mode! you got this 📚', "flashcards? i'll quiz you 📚"],
    video: ['movie time? 🍿'],
    game: ['game time! have fun 🎮'],
  };
  function onSys(d) {
    const was = R.sys;
    const call = !!(d.camera || d.mic);
    R.sys = Object.assign({}, d, { call, kind: appKind(d.app), busy: call || !!d.fullscreen });
    if (!R.sysSeen) { R.sysSeen = true; return; }
    const t = (R.now = Date.now());
    if (call && !was.call) {
      R.callStart = t;
      R.callCam = false;
      if (R.scene) endScene(); // hush mid-sentence
    }
    if (d.camera) R.callCam = true;
    if (!call && was.call && R.callCam && t - R.callStart > 3 * MIN) aside('wave', pick(["call's over! you did great 💜", 'phew, call done ✨ sip of water?']), 6);
    if (d.battery != null && !d.plugged) {
      const pct = Math.round(d.battery * 100);
      if (pct <= 10 && !R.batt10) { R.batt10 = R.batt20 = true; aside('lowbatt', `battery's at ${pct}%! plug me in?? 🪫`, 8); }
      else if (pct <= 20 && !R.batt20) { R.batt20 = true; aside('lowbatt', `battery's at ${pct}%... i'm getting sleepy 🪫`, 7); }
    }
    if (d.plugged && was.plugged === false) {
      R.batt10 = R.batt20 = false;
      if (t - R.zapAt > 10 * MIN) { R.zapAt = t; aside('zap', pick(['ooh, power! ⚡', 'mmm, electricity ⚡ thank you', 'charging up! ⚡']), 4); }
    }
    if (d.dark !== was.dark) d.dark ? aside('night', pick(['lights off! cozy 🌙', 'ooh, dark mode 🌙']), 4) : aside('shades', pick(['whoa, bright! 😎', 'sunglasses on 😎']), 4);
    if (d.app !== was.app && APP_LINES[R.sys.kind] && t - R.appLineAt > 15 * MIN && Math.random() < 0.35) { R.appLineAt = t; blurt(pick(APP_LINES[R.sys.kind]), 3000); }
    R.ambient = '';
    ambient(t, R.last || IDLE);
    updateRoam();
  }

  // ---------- the heartbeat: the app calls this once a second ----------
  function tick(s) {
    const t = s.now || Date.now();
    R.now = t;
    const gap = S.lastTick ? (t - S.lastTick) / SEC : 0;
    S.lastTick = t;
    rollDay(t);
    if (gap > CFG.freshGap) freshStart('computer slept ' + Math.round(gap / 60) + ' min');
    const dt = Math.min(gap, 3);

    if (s.idle < CFG.activeIdle) {
      S.day.active += dt;
      S.sit += dt;
      S.day.longestSit = Math.max(S.day.longestSit, S.sit);
      const m = mod(t);
      if (S.day.first == null) S.day.first = m;
      S.day.last = m;
      // energy creeps up as you warm up, then slowly drains over a long sit
      S.energy += S.sit < 20 * 60 ? dt / 2400 : -dt / (3 * 3600);
    }
    S.energy = clamp(S.energy, 0.05, isNight(t) ? 0.45 : 1);
    if (R.groggy && S.energy >= 0.45) R.groggy = false;

    // typing rhythm: only *whether* a key was pressed in the last second
    R.typing.push(s.kbIdle < 1.5 ? 1 : 0);
    if (R.typing.length > 60) R.typing.shift();
    R.ti = avg(R.typing);
    if (R.ti > 0.3) R.flowSince = R.flowSince || t;
    else if (R.ti < 0.08) R.flowSince = 0;
    R.browsing = s.kbIdle > 20 && s.mouseIdle < 4;
    if (R.browsing) R.browseSince = R.browseSince || t; else if (s.kbIdle < 5 || s.mouseIdle > 12) R.browseSince = 0;

    if (s.idle >= CFG.awayIdle) {
      R.away = true;
      R.awayMax = Math.max(R.awayMax, s.idle);
    } else if (R.away && s.idle < 3) {
      const was = R.awayMax;
      R.away = false;
      R.awayMax = 0;
      onReturn(was);
    }
    if (s.idle > 20 && !R.away) R.presentSince = t;

    const sc = R.scene;
    if (sc) {
      if (sc.bubbleUntil && t >= sc.bubbleUntil) { bubble.hide(); sc.bubbleUntil = 0; }
      if (sc.kind === 'walk' && !R.walkNagged && s.idle < 5 && t - sc.start > 80 * SEC) {
        R.walkNagged = true;
        bubble.show("psst... you're still here 👀 go go!", null, choose);
        sc.bubbleUntil = t + 6 * SEC;
      }
      if (t >= sc.until) endScene();
    }
    if (!R.scene && R.queue.length) play(R.queue.shift());
    if (!R.scene) maybeNudge(t, s);
    ambient(t, s);
    updateRoam(s);

    // little signs of life
    if (!R.scene && ['idle', 'content'].includes(R.ambient) && Math.random() < 1 / 25) view.fidget(pick(['hop', 'look', 'hum', 'wiggle']));

    R.last = s;
    if (t - R.savedAt > 30 * SEC) save();
    if (t - R.statsAt > 3 * SEC) postStats();
  }

  const MOODS = {
    wizard: 'casting code spells', detective: 'investigating', chef: 'cooking lunch', nap: 'napping under a book', tv: 'turned into a screen',
    energy: 'holding an energy drink', sipEnergy: 'drinking an energy drink',
    idle: 'chilling', tinker: 'at your service', content: 'happy', tired: 'sleepy', yawn: 'yawning', sip: 'sipping coffee', coffee: 'having coffee',
    offerCoffee: 'offering you coffee', water: 'wants you to drink water', sipWater: 'drinking water', walkAsk: 'wants to go for a walk',
    walk: 'out for a walk', stretch: 'stretching', lookfar: 'resting its eyes', cheer: 'cheering you on', wave: 'waving',
    type: 'typing along with you', focus: 'in the zone with you', read: 'reading', juggle: 'playing ball', plant: 'watering its plant',
    sleep: 'napping', nightSleep: 'asleep', night: 'sleepy (it\'s late)', love: 'happy you\'re here', poke: 'giggling', party: 'celebrating',
    proud: 'proud of you', sweaty: 'needs a stretch', surprised: 'surprised', dangle: 'wheee',
    stroll: 'going for a stroll', crouch: 'about to jump', jump: 'jumping', fall: 'falling!', land: 'landing', dizzy: 'dizzy',
    shh: "being quiet (you're on a call)", popcorn: 'watching with you', jam: 'vibing to your music', duck: 'rubber-duck debugging',
    lowbatt: 'low on battery', zap: 'charging up', shades: 'too cool',
    think: 'thinking along with Claude', needsYou: 'waiting for you (Claude needs you)', terminal: 'running commands',
    clipboard: 'checking things off', binoculars: 'searching the web', ship: 'shipping it', conduct: 'directing helpers',
    squish: 'squishing its memory', oops: 'oops',
  };
  function postStats() {
    R.statsAt = R.now;
    post({
      type: 'stats',
      mood: MOODS[view.current] || 'chilling',
      quiet: quiet(),
      wearing: R.scene && COSTUMES[R.scene.pose] ? R.scene.pose : '',   // for the panel's Costumes tab
      stats: { active: fmt(S.day.active), sitting: fmt(S.sit), water: S.day.water, coffee: S.day.coffee, energy: S.day.energy || 0, breaks: S.day.breaks, walks: S.day.walks },
    });
  }

  // ---------- touching Mochi ----------
  function poke() {
    const t = Date.now();
    R.pokes = R.pokes.filter((x) => t - x < 4000);
    R.pokes.push(t);
    if (R.scene && R.scene.buttons) return view.flash('poke', 500);
    if (['sleep', 'nightSleep', 'nap'].includes(view.current)) return say('surprised', pick(['huh?! oh, hi!', "wasn't sleeping! just resting my eyes"]), 4, 'bang', { fxN: 1 });
    if (R.pokes.length >= 5) { R.pokes = []; return say('poke', pick(["okay okay i'm awake!!", 'hey! that tickles!! hehe']), 3); }
    view.flash('poke', 650);
    view.burst('heart', 2);
    if (Math.random() < 0.4) blurt(pick(POKES), 2200);
  }

  const ACTIONS = {
    cheer: () => say('cheer', cheerLine(R.now), 5),
    water: () => waterYes(),
    coffee: () => coffeeYes(),
    walk: () => startWalk(),
    energy: () => energyYes(),
    lunch: () => say('chef', "pancakes for everyone 🥞", 8),
    ball: () => play({ pose: 'juggle', say: 'wanna see a trick? ⚽', sayFor: 3, dur: 14 }),
    plant: () => play({ pose: 'plant', say: 'the plant is thirsty too 🌱', sayFor: 4, dur: 12 }),
    stats: () => say('proud', statsLine(), 11),
    hello: () => say('wave', "hi! i'm mochi 💜 i'll keep you company. pick me up and toss me around, right-click me for stuff", 9),
  };

  // ---------- the API the app talks to ----------
  const COSTUMES = { wizard: '✨ coding wizard mode', detective: '🔍 investigating...', chef: '🍳 chef mochi reporting', focus: '🎧 vibing', shades: '😎 too cool', tv: '📺 beep boop', party: '🎉 party!' };
  const EVENT_LINES = {
    knocked: [['whoa!!', 'hey! 😵', 'aaah!'], 0.6],
    gone: [["hey! where'd it go?", 'oop—', 'whoa!'], 0.35],
    ride: [['wheee 🚗', 'going for a ride!', 'beep beep'], 0.5],
    pounce: [['almost got it!', 'hehe, so close', 'mine!'], 0.5],
    arrive: [['found you! ✨', 'ta-da! ✨', 'hi again!'], 0.6],
    noroom: [['no room up there! 😅', "that window's too tall for me"], 1],
  };

  window.mochi = {
    tick,
    look(x, y, inside) {
      view.lookAtPoint(x, y);
      const t = Date.now();
      if (inside && !R.hover) R.hoverSince = t;
      R.hover = !!inside;
      if (!inside) R.hoverSince = 0;
      ambient(t, R.last);
    },
    dragging() { R.dragging = true; ambient(Date.now(), R.last || IDLE); updateRoam(); },
    dragEnd(moved, thrown) {
      if (!moved) return poke();
      R.dragging = false;
      R.ambient = '';
      if (!thrown) view.flash('poke', 500);
      if (Math.random() < 0.5) blurt(pick(thrown ? ['wheee!', 'weeee!', 'yeet!'] : ['wheee!', 'new spot! i like it', 'boing!']), 1800);
      ambient(Date.now(), R.last || IDLE);
      updateRoam();
    },
    // the app moved Mochi: walk / crouch / jump / fall, then land or still
    move(state, dir) {
      if (dir) view.facing = dir;
      R.move = state === 'land' || state === 'still' ? null : state;
      if (state === 'land') { R.landUntil = Date.now() + 260; setTimeout(restorePose, 280); }
      R.ambient = '';
      if (R.move || state === 'land') ambient(Date.now(), R.last || IDLE); else restorePose();
    },
    event(name) {
      if (name === 'poof' || name === 'arrive') view.burst('sparkle', 6);
      if (name === 'ride') { if (Date.now() - R.rideAt < 30 * SEC) return; R.rideAt = Date.now(); }
      const e = EVENT_LINES[name];
      if (name === 'noroom') return say('idle', pick(e[0]), 3); // you asked from the menu, so always answer
      if (e && Math.random() < e[1]) blurt(pick(e[0]), 2000);
    },
    room(above, left, right) { R.room = { above, left, right }; placeBubble(); },
    dizzy() {
      if (R.scene && R.scene.buttons) return;
      R.dizzyUntil = Date.now() + 3500;
      R.ambient = '';
      ambient(Date.now(), R.last || IDLE);
      if (Math.random() < 0.6) blurt(pick(['woahhh 💫', 'the room is spinning...', '@_@']), 2200);
      setTimeout(restorePose, 3600);
    },
    sys: onSys,
    claude: onClaude,
    setClaude(on, narrate) {
      C.on = !!on;
      C.narrate = !!narrate;
      if (!C.on && R.scene && R.scene.kind === 'claude') { R.scene = null; bubble.hide(); }
      R.ambient = '';
      ambient(Date.now(), R.last || IDLE);
      updateRoam();
    },
    // first run with Claude Code around: offer to follow along
    claudeHint() {
      R.now = Date.now();
      ask('wave', "psst! you use claude code. want me to act out what it's doing?", [['yes please', 'yes'], ['not now', 'no']],
        (c) => { if (c === 'yes') post({ type: 'claudeConnect' }); });
    },
    claudeConnected(ok, why) {
      R.now = Date.now();
      if (ok) say('cheer', "connected! restart your claude code sessions and i'll follow along :sparkle:", 8, 'sparkle');
      else say('sweaty', `couldn't connect to claude code: ${why}`, 8);
    },
    // the panel opened or closed: hold up a gear while it's open, and keep the bubble out of its way
    menu(open) {
      R.menu = !!open;
      document.body.classList.toggle('menu', R.menu);
      R.ambient = '';
      ambient(Date.now(), R.last || IDLE);
    },
    setWater(on) {
      waterOn = !!on;
      R.now = Date.now();
      if (!waterOn && R.scene && R.scene.pose === 'water') endScene();   // stop asking right away
    },
    setEmoji(on) {
      emoji = !!on;
      if (!bubbleEl.hidden && R.bubbleText != null) {   // redraw what's showing
        MochiIcons.render(bubbleEl.querySelector('.b-text'), R.bubbleText, emoji);
        bubbleEl.querySelectorAll('.b-btns button').forEach((b, i) => MochiIcons.render(b, R.bubbleButtons[i][0], emoji));
        placeBubble();
      }
    },
    setScale(s, w, h) { layout.w = w; layout.h = h; view.setScale(s); applyLayout(); placeBubble(); },
    action(name) {
      R.now = Date.now();
      if (name.startsWith('wear:')) {
        const c = name.slice(5);
        if (COSTUMES[c]) play({ pose: c, say: COSTUMES[c], sayFor: 3, dur: 40 });
        else if (c === 'none' && R.scene && COSTUMES[R.scene.pose]) endScene();   // take it off
        return postStats();
      }
      if (ACTIONS[name]) ACTIONS[name]();
      save();
    },
    onWake(seconds) { R.now = Date.now(); if (seconds >= CFG.freshGap) freshStart('woke after ' + Math.round(seconds / 60) + ' min'); },
    setQuiet(until) { S.quietUntil = until; if (until > Date.now()) { R.scene = null; bubble.hide(); R.ambient = ''; } save(); postStats(); },
    debug: () => ({ S, R, CFG }),
    pose: (p) => view.pose(p),
    play: (p, text) => say(p, text || p, 6),
  };

  // ---------- input from the page ----------
  petEl.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    if (native) post({ type: 'dragStart' });
  });
  petEl.addEventListener('click', () => { if (!native) poke(); });
  petEl.addEventListener('contextmenu', (e) => { e.preventDefault(); post({ type: 'menu' }); });

  // Clickable areas, so the rest of the window lets clicks through to whatever is behind it.
  function hotRects() {
    const out = [view.hitBox()];
    if (!bubbleEl.hidden && !R.menu) { const b = bubbleEl.getBoundingClientRect(); out.push([b.left - 4, b.top - 4, b.width + 8, b.height + 14]); }
    return out.map((a) => a.map(Math.round));
  }
  setInterval(() => { const h = JSON.stringify(hotRects()); if (h !== R.hotStr) { R.hotStr = h; post({ type: 'hot', rects: JSON.parse(h) }); } }, 150);

  // ---------- boot ----------
  const bootT = ENV.boot || 0;
  const now0 = Date.now();
  const gap0 = S.lastTick ? (now0 - S.lastTick) / SEC : Infinity;
  R.now = now0;
  rollDay(now0);
  if (!saved) { R.lastBubble = now0; setTimeout(() => ACTIONS.hello(), 1500); }
  else if ((bootT && now0 - bootT < 20 * MIN) || gap0 > CFG.freshGap) freshStart(bootT && now0 - bootT < 20 * MIN ? 'computer just started' : 'first time today');
  S.lastTick = now0;

  if (!native) {
    // Browser fallback: fake the app's sensors from this tab's own events.
    let lastKey = 0, lastMouse = Date.now();
    addEventListener('keydown', () => { lastKey = Date.now(); });
    addEventListener('pointermove', (e) => { lastMouse = Date.now(); window.mochi.look(e.clientX, e.clientY, petEl.contains(e.target)); });
    setInterval(() => { const n = Date.now(); const kb = (n - lastKey) / SEC, mo = (n - lastMouse) / SEC; tick({ now: n, idle: Math.min(kb, mo), kbIdle: kb, mouseIdle: mo }); }, SEC);
  }
  post({ type: 'ready' });
})();
