/* Settings (settings.html): the pane the window's toolbar has picked, drawn on Mochi's paper. The app hands it
   everything as one state object with page.update(state) (every second while open; it only redraws when something
   changed) and gets back {type: 'act', name, arg} per click, arg being a provider id or key=value. page.update
   returns the pane's height, and {type: 'size', h} follows any change, so the window fits each pane.
   Opened in a browser it shows sample data; ?pane=general|mochi|usage|agents|alerts|about picks the pane. */
(() => {
  'use strict';
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.page;
  const post = (m) => { if (native) native.postMessage(m); };
  const act = (name, arg) => post({ type: 'act', name, arg: arg == null ? null : String(arg) });
  const $ = (id) => document.getElementById(id);

  // tiny element builder: h('div', {class: 'x', onclick}, child, 'text', ...)
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (v !== false && v != null) el.setAttribute(k, v === true ? '' : v);
    }
    for (const k of kids.flat(Infinity)) if (k != null && k !== false) el.append(k.nodeType ? k : document.createTextNode(k));
    return el;
  }

  const IDS = Object.keys(MINI_LOOKS);
  const PANES = ['general', 'mochi', 'usage', 'agents', 'alerts', 'about'];
  let S = null, drawn = '';

  // ---------- pieces ----------
  const sw = (on, name, arg, label) => h('button', { class: 'switch' + (on ? ' on' : ''), role: 'switch', 'aria-checked': String(!!on), 'aria-label': label || '', onclick: () => act(name, arg) });
  const title = (t, line, tone) => line ? h('span', { class: 'two' }, h('span', {}, t), h('span', { class: 'line ' + (tone || '') }, line)) : h('span', {}, t);
  const row = (t, line, ...end) => h('div', { class: 'set' }, title(t, line), h('span', { class: 'end' }, end));
  // a whole row toggles its switch, like a Mac settings row
  const toggle = (t, line, on, name, arg) => h('button', { class: 'set', role: 'switch', 'aria-checked': String(!!on), onclick: () => act(name, arg) },
    title(t, line), h('span', { class: 'switch' + (on ? ' on' : '') }));
  const seg = (cur, name, key, opts, disabled) => h('span', { class: 'seg' }, opts.map(([l, v]) =>
    h('button', { class: String(cur) === String(v) ? 'on' : '', disabled: !!disabled, onclick: () => act(name, key + '=' + v) }, l)));
  const pxb = (label, onclick, cls) => h('button', { class: 'pxb' + (cls ? ' ' + cls : ''), onclick }, label);
  const group = (...rows) => h('div', { class: 'group' }, rows);

  // built once, so it keeps animating instead of restarting on every redraw
  let aboutStage = null;

  // ---------- panes ----------
  const PANE = {
    general() {
      const notchOff = !S.hasNotch;
      const tile = (mode, t, d, drawing, disabled) => h('button', { class: S.displayMode === mode ? 'on' : '', disabled: !!disabled, onclick: () => act('displayMode', mode) },
        h('div', { class: 'screen' }, drawing), h('div', { class: 't' }, t), h('div', { class: 'd' }, d));
      const login = S.pet ? S.pet.login : S.launchAtLogin;
      return [
        h('h2', {}, 'show usage in'),
        h('div', { class: 'where' },
          tile('tray', 'menu bar', 'your mochi and its % up top. click it for the details.', h('i', { class: 'badge' })),
          tile('notch', 'notch', notchOff ? 'this display has no notch.' : 'a pill under the notch that fans out.', h('i', { class: 'pill' }), notchOff)),
        h('h2', {}, 'startup'),
        group(
          toggle('open at login', 'mochi starts with your mac.', login, 'login', !login),
          row('setup', 'walk through finding and signing in again.', pxb('run setup', () => act('wizard')))),
      ];
    },

    mochi() {
      const p = S.pet;
      if (!p) return [h('h2', {}, 'your mochi'), h('div', { class: 'cap' }, "mochi's own settings show up here while it's running.")];
      const t = (key, label, line) => toggle(label, line, p[key] !== false, 'pet', key + '=' + (p[key] === false));
      return [
        h('h2', {}, 'your mochi'),
        h('div', { class: 'cap' }, "it acts out the sessions of the tool you pick, and shows that tool's plan."),
        group(row('follows', '', seg(p.provider, 'pet', 'provider', IDS.map((id) => [MINI_LOOKS[id].name.toLowerCase(), id])))),
        h('h2', {}, 'on your screen'),
        group(
          toggle('show mochi', 'hidden, it comes back when you open the app.', p.visible !== false, 'pet', 'visible=' + (p.visible === false)),
          row('size', '', seg(p.scale, 'pet', 'scale', [['s', 2], ['m', 3], ['l', 4], ['xl', 6]])),
          t('roam', 'wander around', 'strolls, hops onto windows, follows you between screens.'),
          t('appAware', 'react to apps & calls', 'quiet on calls, popcorn for videos, headphones for music.'),
          t('emoji', 'use emoji', 'in its speech bubble, instead of pixel icons.'),
          toggle('quiet for an hour', 'no reminders or chatter until it\'s up.', !!p.quiet, 'pet', 'quiet=' + !p.quiet),
          row('lost it?', 'bring it back to the bottom corner.', pxb('move to corner', () => act('pet', 'corner=1')))),
        h('h2', {}, 'reminders'),
        group(
          t('waterReminders', 'drink water'),
          t('walkReminders', 'get up and walk'),
          t('stretchReminders', 'stretches & eye breaks'),
          t('lunchReminders', 'lunch'),
          t('coffeeReminders', 'coffee'),
          t('bedtimeReminders', 'bedtime'),
          t('cheers', 'cheer me on')),
      ];
    },

    usage() {
      return [
        h('h2', {}, 'providers'),
        h('div', { class: 'cap' }, 'mochi reads your plan from each one. switching one off stops it checking that tool at all.'),
        group(S.providers.map((p) => h('div', { class: 'set' + (p.enabled ? '' : ' off') },
          h('span', { class: 'who' }, title(p.name, p.status, p.tone)),
          h('span', { class: 'end' }, p.action && pxb(p.action, () => act('providerAction', p.id), 'primary'),
            sw(p.enabled, 'enable', p.id + '=' + !p.enabled, p.name))))),
      ];
    },

    agents() {
      const a = S.agents, p = S.pet || {};
      const hookLine = (k) => k.installed ? (k.live ? `connected. ${k.live} session${k.live === 1 ? '' : 's'} open.` : 'connected.')
        : k.canInstall ? 'not connected.' : "hasn't been run on this mac yet.";
      const t = (key, label, line) => S.pet ? toggle(label, line, p[key] !== false, 'pet', key + '=' + (p[key] === false)) : null;
      return [
        h('h2', {}, 'connected tools', h('span', { class: 'end' }, 'alerts')),
        h('div', { class: 'cap' }, 'a hook in each tool tells mochi what its sessions are doing. nothing leaves your mac.'),
        group(a.hooks.map((k) => h('div', { class: 'set' },
          h('span', { class: 'who' }, title(k.name, hookLine(k), k.installed ? 'ok' : '')),
          h('span', { class: 'end' },
            k.installed && pxb('test', () => act('test', k.id)),
            (k.installed || k.canInstall) && pxb(k.installed ? 'disconnect' : 'connect', () => act('hook', k.id + '=' + !k.installed), k.installed ? '' : 'primary'),
            sw(k.alertsOn, 'set', 'alerts.' + k.id + '=' + !k.alertsOn, k.name + ' alerts'))))),
        !a.listening && h('div', { class: 'note error' }, `can't listen on port ${a.port}. is another copy of mochi running?`),
        a.note && h('div', { class: 'note' }, a.note),
        a.error && h('div', { class: 'note error' }, a.error),
        S.pet && h('h2', {}, 'mochi and your sessions'),
        S.pet && group(
          t('follow', 'act out what they\'re doing', 'typing for edits, a magnifier for searches...'),
          t('narrate', 'say what they\'re doing', 'a word in its speech bubble.'),
          t('claudeDone', 'tell me when one finishes'),
          t('claudeFetch', 'come find me when one needs me', 'walks over to your pointer.'),
          t('showSessions', 'list sessions in its panel')),
        h('h2', {}, 'sessions'),
        group(row('forget idle sessions after', 'sessions waiting on you always stay.',
          seg(a.idleMinutes, 'set', 'idleMinutes', [['5m', 5], ['10m', 10], ['20m', 20], ['1h', 60], ['4h', 240]]))),
      ];
    },

    alerts() {
      const a = S.agents;
      return [
        h('h2', {}, 'sounds', h('span', { class: 'end' }, 'they wait until you answer')),
        group([['done', 'when one finishes'], ['needsInput', 'when one needs input'], ['failed', 'when one fails']].map(([kind, label]) => {
          const al = a.alerts[kind] || {};
          const i = Math.max(0, a.sounds.indexOf(al.sound));
          const step = (d) => act('set', `sound.${kind}=` + a.sounds[(i + d + a.sounds.length) % a.sounds.length]);
          return h('div', { class: 'set' + (al.on === false ? ' off' : '') }, h('span', {}, label), h('span', { class: 'end' },
            h('span', { class: 'sound' }, pxb('‹', () => step(-1), 'tiny'), h('span', { class: 'name' }, (al.sound || '').toLowerCase()), pxb('›', () => step(1), 'tiny')),
            pxb('play', () => act('preview', kind), 'tiny'),
            sw(al.on !== false, 'set', `alert.${kind}=` + (al.on === false), label)));
        })),
        group(
          row('repeat', '', seg(a.repeatSeconds, 'set', 'repeatSeconds', [['once', 0], ['15s', 15], ['30s', 30], ['1m', 60], ['2m', 120], ['5m', 300]])),
          row('volume', '', seg(Math.round(a.volume * 4) / 4, 'set', 'volume', [['25%', 0.25], ['50%', 0.5], ['75%', 0.75], ['100%', 1]]))),
        h('h2', {}, 'notifications'),
        group(h('div', { class: 'set' }, title('notifications', 'set mochi to "alerts" to keep them on screen until you act.'),
          h('span', { class: 'end' }, pxb('open', () => act('openNotifications')), sw(a.notifications, 'set', 'notifications=' + !a.notifications, 'notifications')))),
      ];
    },

    about() {
      if (!aboutStage) {
        aboutStage = h('div', { class: 'stage' });
        new Critter(aboutStage, { pose: 'wave', scale: 3 });
      }
      return [h('div', { class: 'about' },
        aboutStage,
        h('div', { class: 'big' }, 'mochi'),
        h('div', { class: 'muted' }, S.version ? 'version ' + S.version : ''),
        h('div', { class: 'muted' }, 'a pixel critter for your desktop, your agents and your plans.'),
        h('div', { class: 'btns' }, pxb('show data folder', () => act('reveal')), pxb('quit mochi', () => act('quit'))))];
    },
  };

  // ---------- drawing ----------
  const pane = $('pane');
  const height = () => pane.offsetHeight;
  function render() {
    const key = JSON.stringify(S);
    if (key === drawn) return;
    const switched = !drawn || JSON.parse(drawn).pane !== S.pane;
    drawn = key;
    const top = document.scrollingElement.scrollTop;
    pane.replaceChildren(...[(PANE[S.pane] || PANE.general)()].flat(3).filter(Boolean));
    document.scrollingElement.scrollTop = switched ? 0 : top;   // a redraw every second mustn't jump you around
  }
  new ResizeObserver(() => post({ type: 'size', h: height() })).observe(pane);

  addEventListener('keydown', (e) => {
    if (e.key === 'Escape' || (e.metaKey && e.key.toLowerCase() === 'w')) { e.preventDefault(); post({ type: 'close' }); }
    // ⌘1…⌘6 pick a pane, like the toolbar
    const n = e.metaKey ? Number(e.key) : 0;
    if (n >= 1 && n <= PANES.length) { e.preventDefault(); act('pane', PANES[n - 1]); }
  });

  window.page = { update(state) { S = state; render(); return { h: height() }; } };
  if (native) post({ type: 'ready' });

  // opened in a browser: sample data
  if (!native) {
    const q = new URLSearchParams(location.search);
    page.update({
      pane: q.get('pane') || 'general', version: '1.4', displayMode: 'tray', hasNotch: true, launchAtLogin: true,
      providers: [
        { id: 'claude', name: 'claude', enabled: true, status: 'signed in. 16% used.', tone: 'ok' },
        { id: 'antigravity', name: 'antigravity', enabled: true, status: 'installed, not signed in.', tone: '', action: 'log in' },
        { id: 'codex', name: 'codex', enabled: true, status: 'signed in (showing last known usage)', tone: 'warn' },
        { id: 'cursor', name: 'cursor', enabled: false, status: 'turned off.', tone: '' },
      ],
      agents: {
        listening: !q.has('deaf'), port: 47833,
        hooks: [
          { id: 'claude', name: 'claude', installed: true, canInstall: true, alertsOn: true, live: 2 },
          { id: 'antigravity', name: 'antigravity', installed: false, canInstall: false, alertsOn: true, live: 0 },
          { id: 'codex', name: 'codex', installed: true, canInstall: true, alertsOn: true, live: 1 },
          { id: 'cursor', name: 'cursor', installed: false, canInstall: true, alertsOn: false, live: 0 },
        ],
        note: 'codex: codex runs new hooks only after you approve them: open codex and type /hooks.', error: '', idleMinutes: 20,
        alerts: { done: { on: true, sound: 'Glass' }, needsInput: { on: true, sound: 'Ping' }, failed: { on: false, sound: 'Basso' } },
        repeatSeconds: 30, volume: 0.5, notifications: true,
        sounds: ['None', 'Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse', 'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink'],
      },
      pet: q.has('nopet') ? undefined : {
        provider: 'codex', scale: 3, roam: true, appAware: true, emoji: false, quiet: false, login: true, visible: true,
        waterReminders: true, walkReminders: true, stretchReminders: false, lunchReminders: true, coffeeReminders: true,
        bedtimeReminders: true, cheers: true, claudeDone: true, claudeFetch: true, showSessions: true, follow: true, narrate: true,
      },
    });
  }
})();
