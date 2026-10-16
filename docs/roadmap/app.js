/* Engineering roadmap + simulated request flow. Classic script (works from file://), no dependencies.
 * Reads window.RM_DATA (generated into data.js). Nothing here contacts a network or AWS. */
(function () {
  'use strict';

  document.documentElement.classList.add('js');
  var D = window.RM_DATA;
  var doc = document;
  var $ = function (sel, root) { return (root || doc).querySelector(sel); };
  var mqReduce = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  var reduce = !!(mqReduce && mqReduce.matches);
  if (mqReduce && mqReduce.addEventListener) {
    mqReduce.addEventListener('change', function (e) { reduce = e.matches; });
  }

  function el(tag, attrs, kids) {
    var n = doc.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === 'text') n.textContent = attrs[k];
      else if (k === 'class') n.className = attrs[k];
      else n.setAttribute(k, attrs[k]);
    });
    (kids || []).forEach(function (c) { if (c) n.appendChild(c); });
    return n;
  }
  function repoHref(p) { return '../../' + p; }

  if (!D) {
    var tl = $('#timeline');
    if (tl) tl.innerHTML = '<li class="note">The data file (data.js) did not load, so the interactive parts are unavailable. See ../ROADMAP.md.</li>';
    return;
  }

  /* ------------------------------------------------------------------ status helpers */
  var LOCAL_LABEL = { verified: 'Verified locally', documented: 'Documented', planned: 'Planned' };
  var AWS_LABEL = { pending: 'AWS: pending', na: 'AWS: n/a', verified: 'AWS: verified' };
  function chip(text, cls) { return el('span', { 'class': 'chip ' + cls, text: text }); }

  /* ------------------------------------------------------------------ summary counts */
  (function renderCounts() {
    var c = D.counts, box = $('#counts');
    if (!box) return;
    [['k-verified', 'Verified locally', c.verified + ' of ' + c.total],
     ['k-documented', 'Documented', String(c.documented)],
     ['k-planned', 'Planned', String(c.planned)],
     ['k-aws', 'Verified on AWS', c.aws_verified + ' of ' + c.total]].forEach(function (r) {
      box.appendChild(el('div', { 'class': r[0] }, [el('dt', { text: r[1] }), el('dd', { text: r[2] })]));
    });
  })();

  /* ------------------------------------------------------------------ roadmap */
  var timeline = $('#timeline');
  var toggles = [];
  function listBlock(title, items, cls) {
    if (!items || !items.length) return null;
    var ul = el('ul');
    items.forEach(function (t) { ul.appendChild(el('li', { text: t })); });
    return el('div', { 'class': cls || '' }, [el('h4', { text: title }), ul]);
  }
  function filesBlock(files) {
    if (!files || !files.length) return null;
    var ul = el('ul');
    files.forEach(function (f) {
      ul.appendChild(el('li', {}, [el('a', { href: repoHref(f.path), text: f.path }), el('span', { text: ' — ' + f.label })]));
    });
    return el('div', { 'class': 'files' }, [el('h4', { text: 'Files' }), ul]);
  }
  function setOpen(btn, open) {
    var panel = doc.getElementById(btn.getAttribute('aria-controls'));
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (open) {
      panel.hidden = false;
      if (!reduce) { panel.classList.remove('opening'); void panel.offsetWidth; panel.classList.add('opening'); }
    } else {
      panel.hidden = true;
    }
  }
  function renderStages() {
    timeline.innerHTML = '';
    D.stages.forEach(function (s) {
      var pid = 'panel-' + s.id;
      var chips = el('span', { 'class': 'chips' }, [
        chip(LOCAL_LABEL[s.local], 'c-' + s.local),
        chip(AWS_LABEL[s.aws], s.aws === 'pending' ? 'c-aws' : (s.aws === 'na' ? 'c-na' : 'c-verified'))
      ]);
      var btn = el('button', { type: 'button', 'class': 'stage-toggle', 'aria-expanded': 'false', 'aria-controls': pid, id: 'toggle-' + s.id }, [
        el('span', { 'class': 'title', text: s.n + '. ' + s.title }), el('span', { 'class': 'chev', 'aria-hidden': 'true' }), chips
      ]);
      var body = el('div', { 'class': 'panel-grid' }, [
        listBlock('Evidence', s.evidence), listBlock('Checks that ran', s.checks), filesBlock(s.files),
        listBlock('Decisions and trade-offs', s.decisions), listBlock('Limits and caveats', s.limits, 'limits'), listBlock('Next', s.next)
      ]);
      var panel = el('div', { 'class': 'panel', id: pid, role: 'region', 'aria-labelledby': 'toggle-' + s.id, hidden: '' }, [body]);
      if (s.ci) panel.appendChild(el('p', { 'class': 'ci-note' }, [el('strong', { text: 'Observed on GitHub: ' }), doc.createTextNode(s.ci)]));
      var card = el('article', { 'class': 'stage-card' }, [el('h3', {}, [btn]), el('p', { 'class': 'summary', text: s.summary }), panel]);
      var li = el('li', { 'class': 'stage reveal', id: 'stage-' + s.id, 'data-local': s.local, 'data-aws': s.aws }, [
        el('div', { 'class': 'dot', 'aria-hidden': 'true' }, [el('span', { text: String(s.n) })]), card
      ]);
      timeline.appendChild(li);
      toggles.push(btn);
      btn.addEventListener('click', function () { setOpen(btn, btn.getAttribute('aria-expanded') !== 'true'); });
      btn.addEventListener('keydown', function (e) {
        var vis = toggles.filter(function (b) { return !b.closest('.stage').hidden; });
        var i = vis.indexOf(btn), t = null;
        if (e.key === 'ArrowDown') t = vis[Math.min(i + 1, vis.length - 1)];
        else if (e.key === 'ArrowUp') t = vis[Math.max(i - 1, 0)];
        else if (e.key === 'Home') t = vis[0];
        else if (e.key === 'End') t = vis[vis.length - 1];
        if (t) { e.preventDefault(); t.focus(); }
      });
    });
  }
  renderStages();

  var filterBtns = Array.prototype.slice.call(doc.querySelectorAll('.filters button'));
  filterBtns.forEach(function (b) {
    b.addEventListener('click', function () {
      var f = b.getAttribute('data-filter');
      filterBtns.forEach(function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
      Array.prototype.forEach.call(timeline.children, function (li) {
        var show = f === 'all' || li.getAttribute('data-local') === f || (f === 'aws-pending' && li.getAttribute('data-aws') === 'pending');
        li.hidden = !show;
      });
      updateRail();
    });
  });
  var expandAll = $('#expand-all');
  if (expandAll) {
    expandAll.addEventListener('click', function () {
      var open = expandAll.getAttribute('data-open') !== 'true';
      toggles.forEach(function (b) { setOpen(b, open); });
      expandAll.setAttribute('data-open', open ? 'true' : 'false');
      expandAll.textContent = open ? 'Collapse all' : 'Expand all';
    });
  }
  if (location.hash.indexOf('#stage-') === 0) {
    var target = $('#toggle-' + location.hash.slice(7));
    if (target) setOpen(target, true);
  }

  /* reveal on scroll (everything is visible immediately when motion is reduced or IO is missing) */
  if ('IntersectionObserver' in window && !reduce) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { if (en.isIntersecting) { en.target.classList.add('is-visible'); io.unobserve(en.target); } });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
    Array.prototype.forEach.call(timeline.children, function (li) { io.observe(li); });
  } else {
    Array.prototype.forEach.call(timeline.children, function (li) { li.classList.add('is-visible'); });
  }

  /* rail: marks the reading position (a "you are here" indicator, not a completion percentage) */
  var railQueued = false;
  function updateRail() {
    railQueued = false;
    var r = timeline.getBoundingClientRect();
    var f = (window.innerHeight * 0.45 - r.top) / Math.max(1, r.height);
    timeline.style.setProperty('--read', String(Math.max(0, Math.min(1, f))));
  }
  function queueRail() { if (!railQueued) { railQueued = true; window.requestAnimationFrame(updateRail); } }
  window.addEventListener('scroll', queueRail, { passive: true });
  window.addEventListener('resize', queueRail);
  updateRail();

  /* ------------------------------------------------------------------ facts */
  (function renderFacts() {
    var grid = $('#facts-grid');
    if (!grid) return;
    D.facts.forEach(function (f) {
      var file = f.source.split(' ')[0];
      grid.appendChild(el('div', { 'class': 'fact' }, [
        el('div', { 'class': 'k', text: f.label }), el('div', { 'class': 'v', text: f.value }), el('div', { 'class': 'n', text: f.note }),
        el('div', { 'class': 's' }, [el('a', { href: repoHref(file), text: f.source })])
      ]));
    });
  })();

  /* ------------------------------------------------------------------ simulator */
  var svg = $('#diagram svg.arch');
  var steps = D.flow.steps;
  if (!svg) return;
  var NS = 'http://www.w3.org/2000/svg';
  var packetLayer = svg.querySelector('#packet-layer');
  var N = steps.length;

  function nodeEl(id) { return svg.querySelector('#n-' + id); }
  function edgeEl(id) { return svg.querySelector('#' + id); }

  /* Edge geometry: every path uses only M, L, H, V, so a tiny polyline model is enough and behaves
   * identically in every browser (no getTotalLength). */
  function parsePoints(d) {
    var pts = [], x = 0, y = 0, re = /([MLHV])\s*(-?[\d.]+)(?:[,\s]+(-?[\d.]+))?/g, m;
    while ((m = re.exec(d))) {
      if (m[1] === 'M' || m[1] === 'L') { x = +m[2]; y = +m[3]; }
      else if (m[1] === 'H') x = +m[2];
      else y = +m[2];
      pts.push([x, y]);
    }
    return pts;
  }
  function polyLength(p) { var t = 0; for (var i = 1; i < p.length; i++) t += Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]); return t; }
  function pointAt(p, dist) {
    for (var i = 1; i < p.length; i++) {
      var seg = Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]);
      if (dist <= seg || i === p.length - 1) {
        var t = seg === 0 ? 0 : Math.min(1, dist / seg);
        return [p[i - 1][0] + (p[i][0] - p[i - 1][0]) * t, p[i - 1][1] + (p[i][1] - p[i - 1][1]) * t];
      }
      dist -= seg;
    }
    return p[p.length - 1];
  }

  var S = { idx: -1, phase: 'idle', playing: false, oneShot: false, speed: 1, seg: null, dwell: 0, last: 0, raf: 0 };
  var PX_PER_MS = 0.36, MIN_SEG = 650, PULSE_MS = 1400, DWELL_MS = 900, DWELL_REDUCED_MS = 1600;

  var $play = $('#btn-play'), $step = $('#btn-step'), $restart = $('#btn-restart'), $reset = $('#btn-reset'), $speed = $('#speed');
  var $count = $('#step-count'), $title = $('#step-title'), $kicker = $('#step-kicker'), $text = $('#step-text'), $refs = $('#step-refs');
  var $fill = $('#bar-fill'), $list = $('#steps-list'), $done = $('#sim-complete');
  var stepBtns = [];

  steps.forEach(function (st, i) {
    var b = el('button', { type: 'button', 'aria-label': 'Go to step ' + (i + 1) + ': ' + st.title, text: String(i + 1) });
    b.addEventListener('click', function () { jump(i); });
    $list.appendChild(el('li', {}, [b]));
    stepBtns.push(b);
  });

  /* layer toggles and side-flow text */
  D.flow.layers.forEach(function (l) {
    var cb = el('input', { type: 'checkbox', id: 'layer-' + l.id });
    cb.checked = !!l.default;
    svg.classList.toggle('hide-' + l.id, !cb.checked);
    cb.addEventListener('change', function () { svg.classList.toggle('hide-' + l.id, !cb.checked); });
    $('#layer-toggles').appendChild(el('label', { 'for': 'layer-' + l.id }, [cb, doc.createTextNode(l.label)]));
  });
  D.flow.sideFlows.forEach(function (sf) {
    $('#side-flows').appendChild(el('dt', { text: sf.title }));
    $('#side-flows').appendChild(el('dd', { text: sf.text }));
  });

  function layerVisible(id) { return !svg.classList.contains('hide-' + id); }

  function clearVisuals() {
    Array.prototype.forEach.call(svg.querySelectorAll('.is-active,.is-done,.is-live'), function (n) { n.classList.remove('is-active', 'is-done', 'is-live'); });
    while (packetLayer.firstChild) packetLayer.removeChild(packetLayer.firstChild);
    svg.classList.remove('is-running');
    S.seg = null;
  }
  function setNodes(ids, cls, on) { ids.forEach(function (id) { var n = nodeEl(id); if (n) n.classList[on ? 'add' : 'remove'](cls); }); }
  function markStepDone(st) {
    setNodes(st.nodes, 'is-active', false);
    setNodes(st.nodes, 'is-done', true);
    st.path.concat(st.side || []).forEach(function (p) { var e = edgeEl(p.edge); if (e) { e.classList.remove('is-live'); e.classList.add('is-done'); } });
  }

  function renderPanel(i) {
    var st = steps[i];
    $count.textContent = 'Step ' + (i + 1) + ' of ' + N;
    $title.textContent = st.title;
    $kicker.textContent = st.kicker;
    $text.textContent = st.text;
    $refs.innerHTML = '';
    st.refs.forEach(function (r) { $refs.appendChild(el('li', {}, [el('a', { href: repoHref(r.path), text: r.path }), el('br'), el('span', { text: r.label })])); });
    stepBtns.forEach(function (b, k) {
      b.classList.toggle('done', k < i || (k === i && S.phase === 'dwell'));
      if (k === i) b.setAttribute('aria-current', 'step'); else b.removeAttribute('aria-current');
    });
  }
  function renderIdle() {
    $count.textContent = 'Ready';
    $title.textContent = 'Press Play to follow a request';
    $kicker.textContent = 'Nine steps from the browser to the database and back';
    $text.textContent = 'The animation walks through DNS resolution, CloudFront, the external load balancer, the frontend, the internal load balancer, the backend and the database, in the order the configuration defines.';
    $refs.innerHTML = '';
    stepBtns.forEach(function (b) { b.classList.remove('done'); b.removeAttribute('aria-current'); });
    $fill.style.width = '0%';
    $done.hidden = true;
  }
  function renderButtons() {
    var label = S.phase === 'complete' ? 'Replay' : (S.playing ? 'Pause' : 'Play');
    $play.querySelector('.lbl').textContent = label;
    $play.querySelector('.ico').textContent = S.playing ? '⏸' : '▶';
    $play.setAttribute('aria-label', label + ' the request simulation');
    $step.disabled = S.phase === 'complete';
  }
  function setProgress(fraction) { $fill.style.width = Math.max(0, Math.min(100, fraction * 100)).toFixed(1) + '%'; }

  function advancing() { return S.playing || S.oneShot; }

  function buildSegments(st) {
    return st.path.map(function (p) {
      var e = edgeEl(p.edge), pts = parsePoints(e.getAttribute('d'));
      if (p.dir === 'rev') pts = pts.slice().reverse();
      var len = polyLength(pts);
      return { edge: p.edge, dir: p.dir, pts: pts, len: len, dur: Math.max(MIN_SEG, len / PX_PER_MS), t: 0 };
    });
  }
  function makePacket(rev) {
    var g = doc.createElementNS(NS, 'g');
    g.setAttribute('class', 'packet' + (rev ? ' rev' : ''));
    var h = doc.createElementNS(NS, 'circle'); h.setAttribute('class', 'halo'); h.setAttribute('r', '15');
    var c = doc.createElementNS(NS, 'circle'); c.setAttribute('class', 'core'); c.setAttribute('r', '6');
    g.appendChild(h); g.appendChild(c);
    return g;
  }
  function placePacket(g, xy) { g.setAttribute('transform', 'translate(' + xy[0].toFixed(1) + ' ' + xy[1].toFixed(1) + ')'); }

  function startStep(i) {
    S.idx = i;
    var st = steps[i];
    svg.classList.add('is-running');
    setNodes(st.nodes, 'is-active', true);
    (st.side || []).forEach(function (s) { if (layerVisible(s.layer)) { var e = edgeEl(s.edge); if (e) e.classList.add('is-live'); } });
    renderPanel(i);
    $done.hidden = true;
    if (reduce) { finishStep(); return; }
    S.phase = 'moving';
    S.seg = { list: buildSegments(st), i: 0, packet: null, pulse: null, pulseT: 0, timerOnly: false };
    if (!S.seg.list.length) {
      S.seg.timerOnly = true;                       // nothing to travel along: highlight the node for a moment
      var n = nodeEl(st.nodes[0]), r = n && n.querySelector('rect');
      if (r) {
        var ring = doc.createElementNS(NS, 'ellipse');
        ring.setAttribute('class', 'pulse');
        ring.setAttribute('cx', String(+r.getAttribute('x') + r.getAttribute('width') / 2));
        ring.setAttribute('cy', String(+r.getAttribute('y') + r.getAttribute('height') / 2));
        ring.setAttribute('rx', String(r.getAttribute('width') / 2 + 6)); ring.setAttribute('ry', String(r.getAttribute('height') / 2 + 6));
        packetLayer.appendChild(ring); S.seg.pulse = ring;
      }
    } else {
      enterSegment();
    }
    renderButtons();
    loop();
  }
  function enterSegment() {
    var sg = S.seg, cur = sg.list[sg.i];
    if (sg.packet) packetLayer.removeChild(sg.packet);
    sg.packet = makePacket(cur.dir === 'rev');
    packetLayer.appendChild(sg.packet);
    placePacket(sg.packet, cur.pts[0]);
    var e = edgeEl(cur.edge); if (e) e.classList.add('is-live');
  }
  function finishStep() {
    var st = steps[S.idx];
    if (S.seg && S.seg.packet && S.seg.packet.parentNode) S.seg.packet.parentNode.removeChild(S.seg.packet);
    if (S.seg && S.seg.pulse && S.seg.pulse.parentNode) S.seg.pulse.parentNode.removeChild(S.seg.pulse);
    S.seg = null;
    markStepDone(st);
    setProgress((S.idx + 1) / N);
    if (S.idx === N - 1) { complete(); return; }
    stepBtns[S.idx].classList.add('done');
    S.oneShot = false;                              // a single manual step ends here
    if (S.playing) { S.phase = 'dwell'; S.dwell = reduce ? DWELL_REDUCED_MS : DWELL_MS; loop(); } else { S.phase = 'idle'; }
    renderButtons();
  }
  function complete() {
    S.phase = 'complete'; S.playing = false; S.oneShot = false;
    stepBtns[S.idx].classList.add('done');
    $kicker.textContent = 'Simulation complete';
    $done.hidden = false;
    renderButtons();
  }

  function frame(ts) {
    S.raf = 0;
    var dt = S.last ? Math.min(100, ts - S.last) : 16;
    S.last = ts;
    if (S.phase === 'moving' && advancing()) {
      var sg = S.seg, scaled = dt * S.speed;
      if (sg.timerOnly) {
        sg.pulseT += scaled;
        setProgress((S.idx + Math.min(1, sg.pulseT / PULSE_MS)) / N);
        if (sg.pulseT >= PULSE_MS) finishStep();
      } else {
        var cur = sg.list[sg.i];
        cur.t += scaled;
        var f = Math.min(1, cur.t / cur.dur);
        placePacket(sg.packet, pointAt(cur.pts, cur.len * f));
        setProgress((S.idx + (sg.i + f) / sg.list.length) / N);
        if (f >= 1) {
          var e = edgeEl(cur.edge); if (e) { e.classList.remove('is-live'); e.classList.add('is-done'); }
          sg.i += 1;
          if (sg.i >= sg.list.length) finishStep(); else enterSegment();
        }
      }
    } else if (S.phase === 'dwell' && advancing()) {
      S.dwell -= reduce ? dt : dt * S.speed;
      if (S.dwell <= 0) {
        if (S.playing && S.idx < N - 1) startStep(S.idx + 1);
        else S.phase = 'idle';
      }
    }
    if ((S.phase === 'moving' || S.phase === 'dwell') && advancing()) loop();   // paused: stop; play() restarts the loop
  }
  function loop() {
    if (!S.raf) { S.last = 0; S.raf = window.requestAnimationFrame(frame); }
  }

  /* controls */
  function resetAll(playing) {
    if (S.raf) { window.cancelAnimationFrame(S.raf); S.raf = 0; }
    clearVisuals();
    S.idx = -1; S.phase = 'idle'; S.playing = !!playing; S.oneShot = false;
    renderIdle();
  }
  function play() {
    if (S.phase === 'complete' || S.idx === -1) { resetAll(true); startStep(0); return; }
    S.playing = true;
    if (S.phase === 'idle' && S.idx < N - 1) startStep(S.idx + 1);
    else loop();
    renderButtons();
  }
  function pause() { S.playing = false; renderButtons(); }
  function stepForward() {
    if (S.phase === 'complete') return;
    if (S.phase === 'moving') { finishStep(); return; }   // finish the step in flight immediately
    if (S.idx >= N - 1) return;
    S.oneShot = !S.playing;
    startStep(S.idx + 1);
  }
  function jump(i) {
    resetAll(false);
    for (var k = 0; k < i; k++) markStepDone(steps[k]);
    S.oneShot = true;                               // play just this step, then wait
    startStep(i);
  }
  $play.addEventListener('click', function () { if (S.playing && S.phase !== 'complete') pause(); else play(); });
  $step.addEventListener('click', stepForward);
  $restart.addEventListener('click', function () { resetAll(true); startStep(0); });
  $reset.addEventListener('click', function () { resetAll(false); renderButtons(); });
  $speed.addEventListener('change', function () { S.speed = parseFloat($speed.value) || 1; });
  var archSection = $('#architecture');
  archSection.addEventListener('keydown', function (e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    var t = e.target && e.target.tagName;
    if (t === 'SELECT' || t === 'INPUT' || t === 'TEXTAREA') return;
    if (e.key === 'ArrowRight') { e.preventDefault(); stepForward(); }
    else if (e.key === 'p' || e.key === 'P') { e.preventDefault(); $play.click(); }
    else if (e.key === 'r' || e.key === 'R') { e.preventDefault(); $restart.click(); }
  });

  var $zoom = $('#btn-zoom'), $scroll = $('#diagram-scroll');
  if ($zoom && $scroll) {
    $zoom.addEventListener('click', function () {
      var on = $scroll.classList.toggle('zoomed');
      $zoom.setAttribute('aria-pressed', on ? 'true' : 'false');
      $zoom.textContent = on ? 'Fit diagram to width' : 'Enlarge diagram';
    });
  }

  resetAll(false);
  renderButtons();

  /* read-only state for tests and debugging */
  window.RM_SIM = {
    state: function () { return { idx: S.idx, phase: S.phase, playing: S.playing, speed: S.speed, steps: N }; },
    reducedMotion: function () { return reduce; }
  };
})();
