/* Mochi's panel (panel.html). The app hands it everything to show as one state object and gets back what you click:
   panel.show(state, below) when it opens, panel.update(state) every second while open, panel.place(tailX, below)
   to point the tail at Mochi. It posts {type: 'act' | 'tab' | 'size' | 'close'} to the app. Also opens in a browser
   with sample data, for working on the look. */
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

  const CLAUDE_LOGO = '<svg width="13" height="13" viewBox="0 0 256 257" aria-hidden="true"><path fill="#D97757" d="m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z"/></svg>';
  const logo = () => { const s = h('span', { style: 'display:flex' }); s.innerHTML = CLAUDE_LOGO; return s; };

  const TABS = [['claude', 'claude'], ['today', 'today'], ['play', 'play'], ['closet', 'dress up'], ['settings', ':gear:']];
  const COSTUMES = [['idle', 'mochi'], ['wizard', 'wizard'], ['detective', 'sleuth'], ['chef', 'chef'],
    ['focus', 'dj'], ['shades', 'shades'], ['tv', 'tv'], ['party', 'party']];

  let S = {}, tab = 'claude', drawn = '';

  // ---------- tabs ----------
  const VIEWS = {
    claude() {
      if (!S.connected && !S.five && !S.canCheck) {
        return h('div', { class: 'empty' }, logo(), h('p', {}, "connect claude code and i'll act out what it's doing. your usage shows up here too."),
          h('button', { class: 'pxb primary', onclick: () => act('connect') }, 'connect'));
      }
      const out = [h('h2', {}, 'usage', h('span', { class: 'end small' }, S.updated || '',
        S.canCheck && say('button', { class: 'ghost', title: 'check now', onclick: () => act('refreshUsage') }, '↻')))];
      if (S.five || S.week) {
        for (const [label, w] of [['5-hour limit', S.five], ['weekly limit', S.week]]) {
          if (!w) continue;
          const fill = w.pct >= 90 ? 'var(--red)' : w.pct >= 70 ? '#e0a43b' : 'var(--claude)';
          out.push(h('div', { class: 'meter' },
            h('div', { class: 'top' }, h('span', {}, label), h('span', {}, Math.round(w.pct) + '%')),
            h('div', { class: 'bar' }, h('i', { style: `width:${Math.max(3, Math.min(100, w.pct))}%; --fill:${fill}` })),
            w.resets && h('div', { class: 'small muted' }, 'resets ' + w.resets)));
        }
      } else {
        out.push(h('div', { class: 'muted small' }, S.checkUsage && S.canCheck ? 'checking your usage...' : 'your usage shows up after your next claude code message.'));
      }
      const busy = (S.sessions || []).filter((s) => s.busy || s.need).length;
      out.push(h('h2', {}, 'sessions', busy ? h('span', { class: 'end small' }, busy + ' working') : null));
      if (!(S.sessions || []).length) {
        out.push(S.connected ? h('div', { class: 'muted small' }, 'no claude code sessions right now.')
          : h('div', { class: 'btns' }, h('button', { class: 'pxb primary', onclick: () => act('connect') }, 'connect claude code')));
      }
      for (const s of S.sessions || []) {
        out.push(h('button', { class: 'row' + (s.busy || s.need ? '' : ' idle'), title: 'switch to it', onclick: () => act('focus', s.id) },
          h('span', { class: 'sq' + (s.need ? ' need' : s.busy ? ' busy' : '') }),
          h('span', { class: 'txt' }, h('div', { class: 'proj' }, s.project), h('div', { class: 'line' + (s.need ? ' need' : '') }, s.line))));
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
      closet.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.id === wearing));
      return [h('h2', {}, 'dress up', h('span', { class: 'end small' }, 'worn for a little while')), closet];
    },

    settings() {
      const sw = (label, on, name) => h('button', { class: 'set', onclick: () => act(name) }, label, h('span', { class: 'switch' + (on ? ' on' : '') }));
      const sizes = [['s', 2], ['m', 3], ['l', 4], ['xl', 6]];
      return [
        h('h2', {}, 'mochi'),
        h('div', { class: 'set' }, 'size', h('span', { class: 'seg' }, sizes.map(([l, v]) =>
          h('button', { class: S.scale === v ? 'on' : '', onclick: () => act('size', v) }, l)))),
        sw('roam around', S.roam, 'roam'),
        sw('react to apps & calls', S.appAware, 'appAware'),
        sw('use emoji', S.emoji, 'emoji'),
        sw('open at login', S.login, 'login'),
        h('h2', {}, 'reminders'),
        sw('water reminders', S.water, 'water'),
        sw('quiet for an hour', S.quiet, 'quiet'),
        h('h2', {}, logo(), 'claude code'),
        h('div', { class: 'set' }, h('span', {}, h('span', { class: 'dot' + (S.connected ? ' on' : '') }),
          S.connected ? 'connected' : S.listening ? 'not connected' : `can't listen on port ${S.port}`),
          h('button', { class: 'pxb' + (S.connected ? '' : ' primary'), onclick: () => act('connect') }, S.connected ? 'disconnect' : 'connect')),
        sw('act out what claude is doing', S.follow, 'follow'),
        sw('say what claude is doing', S.narrate, 'narrate'),
        S.canCheck && sw('check usage every 5 minutes', S.checkUsage, 'checkUsage'),
        h('div', { class: 'foot' }, h('span', { class: 'muted' }, S.version ? 'mochi ' + S.version : ''),
          h('button', { class: 'pxb', title: "bring mochi back if it's lost", onclick: () => act('corner') }, 'move to corner'),
          h('button', { class: 'pxb', onclick: () => act('quit') }, 'quit')),
      ];
    },
  };

  // the closet is built once, so each little Mochi keeps animating instead of restarting every second
  const closet = h('div', { class: 'closet' }, COSTUMES.map(([id, label]) => {
    const stage = h('div', { class: 'stage' });
    new Critter(stage, { pose: id, scale: 1.5 });
    return h('button', { 'data-id': id, title: label, onclick: () => act('pet', id === 'idle' || id === S.wearing ? 'wear:none' : 'wear:' + id) }, stage, h('span', {}, label));
  }));

  // ---------- drawing ----------
  function render(force) {
    const key = JSON.stringify([tab, S]);
    if (key === drawn && !force) return;
    drawn = key;
    $('mood').textContent = S.mood || '';
    const eye = $('eye');
    eye.title = S.visible === false ? 'show mochi' : 'hide mochi';
    MochiIcons.render(eye, ':eye:', false);
    eye.style.opacity = S.visible === false ? 0.4 : 1;
    const nav = $('tabs');
    nav.replaceChildren(...TABS.map(([id, label], i) => {
      const b = say('button', { class: id === tab ? 'on' : '', title: id, onclick: () => { tab = id; post({ type: 'tab', tab }); render(true); } }, label);
      if (id === 'claude') b.prepend(logo());
      return i === TABS.length - 1 ? [h('span', { class: 'grow' }), b] : b;
    }).flat());
    $('body').replaceChildren(...[(VIEWS[tab] || VIEWS.claude)()].flat().filter(Boolean));
  }

  $('eye').addEventListener('click', () => act('visible'));
  addEventListener('keydown', (e) => { if (e.key === 'Escape') post({ type: 'close' }); });
  const wrap = $('wrap');
  new ResizeObserver(() => post({ type: 'size', w: wrap.offsetWidth, h: wrap.offsetHeight })).observe(wrap);

  window.panel = {
    show(state, below) {
      S = state;
      tab = VIEWS[state.tab] ? state.tab : 'claude';
      document.body.classList.toggle('below', !!below);
      render(true);
      if (document.activeElement) document.activeElement.blur();   // no focus ring until you press Tab
      const card = $('card');
      card.classList.remove('pop');
      void card.offsetWidth;
      card.classList.add('pop');
    },
    update(state) { S = state; render(); },
    place(tail, below) {
      document.body.classList.toggle('below', !!below);
      $('card').style.setProperty('--tail-left', tail - 9 + 'px');   // less #wrap's padding and the card's margin
    },
  };

  // opened in a browser: sample data
  if (!native) {
    const params = new URLSearchParams(location.search);
    panel.show({
      tab: params.get('tab') || 'claude', mood: 'at your service', visible: true, wearing: 'wizard', emoji: false, connected: true, listening: true, canCheck: true,
      checkUsage: true, five: { pct: 21, resets: '9:20 PM' }, week: { pct: 74, resets: 'Sun 12:00 PM' }, updated: 'updated 2 min ago',
      sessions: [{ id: 'a', project: 'web', line: 'needs your ok to use Bash', need: true, busy: true }, { id: 'b', project: 'mochi', line: 'editing Panel.swift', busy: true },
        { id: 'c', project: 'formula-fly', line: 'running tests', busy: true }, { id: 'd', project: 'notes', line: 'idle' }],
      stats: { active: '3h 12m', sitting: '41m', water: 3, coffee: 1, energy: 0, breaks: 2 }, roam: true, appAware: true, water: true, quiet: false, login: true,
      scale: 3, follow: true, narrate: true, version: '1.1', port: 47833,
    }, false);
    panel.place(170, false);
  }
})();
