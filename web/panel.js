/* Mochi's panel (panel.html), opened by right-clicking Mochi. The app hands it everything to show as one state
   object and gets back what you click: panel.show(state, below) when it opens, panel.update(state) every second while
   open, panel.place(tailX, below) to point the tail at Mochi. It posts {type: 'act' | 'tab' | 'size' | 'close'} to the
   app. Also opens in a browser with sample data, for working on the look (?tab=, ?provider=). */
(() => {
  'use strict';
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.panel;
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
    for (const k of kids.flat()) if (k != null && k !== false) el.append(k.nodeType ? k : document.createTextNode(k));
    return el;
  }
  // text with pixel icons (":drop: water"), or emoji when those are on
  const say = (tag, attrs, text) => { const el = h(tag, attrs); MochiIcons.render(el, text, !!S.emoji); return el; };

  const TABS = [['usage', 'usage'], ['today', 'today'], ['play', 'play'], ['closet', 'dress up'], ['settings', ':gear:']];
  const COSTUMES = [['idle', 'plain'], ['wizard', 'wizard'], ['detective', 'sleuth'], ['chef', 'chef'],
    ['focus', 'dj'], ['shades', 'shades'], ['tv', 'tv'], ['party', 'party']];
  const PROVIDERS = Object.keys(MINI_LOOKS);

  let S = {}, tab = 'usage', drawn = '';
  const look = (id) => MINI_LOOKS[id || S.provider] || MINI_LOOKS.claude;
  const name = () => (look().name || 'your agent').toLowerCase();

  // ---------- tabs ----------
  const VIEWS = {
    usage() {
      const out = [h('h2', {}, `your ${name()} ${S.plan ? S.plan + ' ' : ''}plan`, h('span', { class: 'end' }, S.updated || '',
        say('button', { class: 'ghost small-ghost', title: 'check now', onclick: () => act('refreshUsage') }, ':refresh:')))];
      if ((S.usage || []).length) {
        for (const w of S.usage) {
          const fill = w.pct >= 90 ? 'var(--red)' : w.pct >= 70 ? '#e0a43b' : 'var(--orange)';
          const lit = Math.round(Math.min(100, Math.max(0, w.pct)) / 5);   // 20 blocks, 5% each
          out.push(h('div', { class: 'meter' },
            h('div', { class: 'top' }, h('span', {}, w.label), h('span', {}, Math.round(w.pct) + '%')),
            h('div', { class: 'bar', style: `--fill:${fill}` }, Array.from({ length: 20 }, (_, k) => h('i', { class: k < Math.max(w.pct > 0 ? 1 : 0, lit) ? 'lit' : '' }))),
            w.resets && h('div', { class: 'small muted' }, 'resets ' + w.resets)));
        }
      } else {
        out.push(h('div', { class: 'muted small' }, S.usageStatus || 'no numbers yet.'));
      }
      if (!S.connected) {
        out.push(h('div', { class: 'empty' }, h('p', {}, S.canConnect
          ? `connect ${name()} and i'll act out what it's doing.`
          : `run ${name()} once on this mac, then connect it here.`),
          S.canConnect && h('button', { class: 'pxb primary', onclick: () => act('connect') }, 'connect')));
        return out;
      }
      // each session, most recent first: red needs you, green finished, coloured is working; click one to jump to it
      if ((S.toggles || {}).showSessions !== false) {
        out.push(h('h2', {}, 'sessions'));
        if (!(S.sessions || []).length) out.push(h('div', { class: 'muted small' }, `no ${name()} sessions right now.`));
        for (const s of S.sessions || []) {
          const need = s.needsYou || s.failed;
          out.push(h('button', { class: 'set sess', title: 'switch to it', onclick: () => act('focus', s.id) },
            h('span', {}, h('span', { class: 'dot' + (need ? ' need' : s.done ? ' done' : s.busy ? ' busy' : '') }), s.project),
            h('span', { class: 'line' + (need ? ' need' : s.done ? ' done' : '') }, s.line)));
        }
      }
      return out;
    },

    today() {
      const st = S.stats || {};
      const stat = (v, label) => h('div', {}, h('b', {}, String(v ?? '–')), h('span', {}, label));
      return [
        h('h2', {}, 'today'),
        h('div', { class: 'stats' }, stat(st.active, 'at the computer'), stat(st.sitting, 'sitting for'), stat(st.breaks ?? 0, 'breaks'),
          stat(st.water ?? 0, 'water'), stat(st.coffee ?? 0, 'coffee'), stat(st.energy ?? 0, 'energy drinks')),
        h('h2', {}, 'i just had...'),
        h('div', { class: 'btns two' },
          say('button', { class: 'pxb', onclick: () => act('pet', 'water') }, ':drop: some water'),
          say('button', { class: 'pxb', onclick: () => act('pet', 'coffee') }, ':mug: a coffee'),
          say('button', { class: 'pxb', onclick: () => act('pet', 'energy') }, ':bolt: an energy drink'),
          say('button', { class: 'pxb', onclick: () => act('pet', 'walk') }, ':shoe: going for a walk')),
      ];
    },

    play() {
      const b = (icon, label, id) => say('button', { class: 'pxb left', onclick: () => act('pet', id) }, `:${icon}: ${label}`);
      return [
        h('h2', {}, 'mochi, please...'),
        h('div', { class: 'btns two' }, b('sparkle', 'cheer me on', 'cheer'), b('star', 'how am i doing?', 'stats'), b('ball', 'play ball', 'ball'),
          b('plant', 'water the plant', 'plant'), b('window', 'sit on my window', 'perch'), b('magnifier', 'go explore', 'explore')),
      ];
    },

    closet() {
      const wearing = S.wearing || 'idle';
      dressUp().querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.id === wearing));
      return [h('h2', {}, 'dress up', h('span', { class: 'end small' }, 'worn for a little while')), dressUp()];
    },

    settings() {
      const sw = (label, on, name, arg) => h('button', { class: 'set', onclick: () => act(name, arg) }, label, h('span', { class: 'switch' + (on ? ' on' : '') }));
      const tg = (label, key) => sw(label, (S.toggles || {})[key] !== false, 'toggle', key);
      const sizes = [['s', 2], ['m', 3], ['l', 4], ['xl', 6]];
      pickers().querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.id === S.provider));
      return [
        h('h2', {}, 'who am i', h('span', { class: 'end small' }, 'i follow that agent')),
        pickers(),
        h('h2', {}, 'mochi'),
        h('div', { class: 'set' }, 'size', h('span', { class: 'seg' }, sizes.map(([l, v]) =>
          h('button', { class: S.scale === v ? 'on' : '', onclick: () => act('size', v) }, l)))),
        sw('roam around', S.roam, 'roam'),
        sw('react to apps & calls', S.appAware, 'appAware'),
        sw('use emoji', S.emoji, 'emoji'),
        sw('open at login', S.login, 'login'),
        h('h2', {}, 'reminders'),
        tg('drink water', 'waterReminders'),
        tg('get up and walk', 'walkReminders'),
        tg('stretches & eye breaks', 'stretchReminders'),
        tg('lunch', 'lunchReminders'),
        tg('coffee', 'coffeeReminders'),
        tg('bedtime', 'bedtimeReminders'),
        tg('cheer me on', 'cheers'),
        sw('quiet for an hour', S.quiet, 'quiet'),
        h('h2', {}, name()),
        h('div', { class: 'set' }, h('span', {}, h('span', { class: 'dot' + (S.connected ? ' on' : '') }),
          S.connected ? 'connected' : S.listening ? 'not connected' : `can't listen on port ${S.port}`),
          (S.connected || S.canConnect) && h('button', { class: 'pxb' + (S.connected ? '' : ' primary'), onclick: () => act('connect') }, S.connected ? 'disconnect' : 'connect')),
        sw(`act out what ${name()} is doing`, S.follow, 'follow'),
        sw(`say what ${name()} is doing`, S.narrate, 'narrate'),
        tg("tell me when it's done", 'claudeDone'),
        tg('come find me when it needs me', 'claudeFetch'),
        tg('show sessions', 'showSessions'),
        h('div', { class: 'foot' }, h('span', { class: 'muted' }, S.version ? 'mochi ' + S.version : ''),
          h('button', { class: 'pxb', onclick: () => act('settings') }, 'all settings'),
          h('button', { class: 'pxb', title: "bring mochi back if it's lost", onclick: () => act('corner') }, 'corner'),
          h('button', { class: 'pxb', onclick: () => act('quit') }, 'quit')),
      ];
    },
  };

  // Built once (and again when Mochi changes critter), so each little critter keeps animating instead of restarting
  // every second.
  let closetFor = '', closetEl = null, pickerEl = null;
  function dressUp() {
    if (closetEl && closetFor === S.provider) return closetEl;
    closetFor = S.provider;
    const L = look();
    closetEl = h('div', { class: 'closet' }, COSTUMES.map(([id, label]) => {
      const stage = h('div', { class: 'stage' });
      new Critter(stage, { pose: id, scale: 1.5, species: L.species, palette: L.palette, particles: false });
      return h('button', { 'data-id': id, title: label, onclick: () => act('pet', id === 'idle' || id === S.wearing ? 'wear:none' : 'wear:' + id) }, stage, h('span', {}, label));
    }));
    return closetEl;
  }
  function pickers() {
    if (pickerEl) return pickerEl;
    pickerEl = h('div', { class: 'closet' }, PROVIDERS.map((id) => {
      const stage = h('div', { class: 'stage' });
      const L = look(id);
      new Critter(stage, { pose: 'idle', scale: 1.5, species: L.species, palette: L.palette, particles: false });
      return h('button', { 'data-id': id, title: L.name, onclick: () => act('provider', id) }, stage, h('span', {}, L.name.toLowerCase()));
    }));
    return pickerEl;
  }

  // ---------- drawing ----------
  function render(force) {
    const key = JSON.stringify([tab, S]);
    if (key === drawn && !force) return;
    drawn = key;
    $('card').style.setProperty('--accent', look().accent || '#e5714b');
    $('mood').textContent = S.mood || '';
    const eye = $('eye');
    eye.title = S.visible === false ? 'show mochi' : 'hide mochi';
    MochiIcons.render(eye, ':eye:', false);
    eye.style.opacity = S.visible === false ? 0.4 : 1;
    const nav = $('tabs');
    nav.replaceChildren(...TABS.map(([id, label]) => {
      const b = say('button', { class: id === tab ? 'on' : '', title: id, onclick: () => { tab = id; post({ type: 'tab', tab }); render(true); } }, label);
      if (id === 'settings') b.classList.add('gear');
      return b;
    }));
    $('body').replaceChildren(...[(VIEWS[tab] || VIEWS.usage)()].flat().filter(Boolean));
    $('body').classList.toggle('scroll', tab === 'settings');
  }

  $('eye').addEventListener('click', () => act('visible'));
  addEventListener('keydown', (e) => { if (e.key === 'Escape') post({ type: 'close' }); });
  const wrap = $('wrap');
  new ResizeObserver(() => post({ type: 'size', w: wrap.offsetWidth, h: wrap.offsetHeight })).observe(wrap);

  window.panel = {
    show(state, below) {
      S = state;
      tab = VIEWS[state.tab] ? state.tab : 'usage';
      $('wrap').classList.toggle('below', !!below);
      render(true);
      const card = $('card');
      card.focus({ preventScroll: true });   // Escape works, and no button shows a focus ring until you press Tab
      card.classList.remove('pop');
      void card.offsetWidth;
      card.classList.add('pop');
      return { w: wrap.offsetWidth, h: wrap.offsetHeight };   // BubblePanel sizes its window before showing it
    },
    update(state) { S = state; render(); },
    place(tail, below) {
      $('wrap').classList.toggle('below', !!below);
      $('card').style.setProperty('--tail-left', tail - 9 + 'px');   // less #wrap's padding and the card's margin
    },
  };

  // opened in a browser: sample data
  if (!native) {
    const params = new URLSearchParams(location.search);
    panel.show({
      tab: params.get('tab') || 'usage', provider: params.get('provider') || 'claude', mood: 'at your service', visible: true,
      wearing: 'wizard', emoji: false, connected: true, canConnect: true, listening: true, port: 47833,
      usage: [{ label: '5-hour limit', pct: 16, resets: '11:10 pm' }, { label: 'weekly limit', pct: 48, resets: 'sun 12:00 pm' }],
      updated: 'updated 2 min ago',
      stats: { active: '3h 12m', sitting: '41m', water: 3, coffee: 1, energy: 0, breaks: 2 }, roam: true, appAware: true, quiet: false, login: true,
      toggles: { lunchReminders: false }, sessions: [{ id: 'a', project: 'mochi', line: 'editing panel.js', busy: true },
        { id: 'b', project: 'parallax', line: 'needs your ok to use Bash', needsYou: true }, { id: 'c', project: 'dotfiles', line: 'done, your turn', done: true }],
      scale: 3, follow: true, narrate: true, version: '2.0',
    }, params.has('below'));
    panel.place(170, params.has('below'));
  }
})();
