/* A browser-shaped harness that runs ui/bridge.html's OWN script in Node.

   No server, no browser and no microphone: the page's script is loaded into a
   stubbed window and driven through its own event listeners, so nothing renders,
   nothing is served, and nothing can speak. That is not merely convenient here -
   it is what the captain's standing rule requires, and CONTRIBUTING.md's
   "Seeing the browser screen" states it in full.

   THE CLOCK IS VIRTUAL, which is what makes a thirty-second hold and ten
   consecutive presses cheap enough to run on every suite. Timers and animation
   frames are driven from Clock.advance rather than from wall time, and the page
   sees that clock through Date.now.

   THE SERVER MODEL MIRRORS bin/fm-bridge.ps1, and the two rules it exists to
   reproduce are the ones that broke: /api/listen is an edge the SERVER owns
   (Step-FmSpeechCaptureState), and a transcript produced by a page-driven
   capture never leaves by /api/fleet. A change to either belongs in both places.

   WHAT IS STUBBED IS NOT PROVEN. The analyser returns a constant level, so real
   amplitude is not tested here and cannot be; tests/FmBridgeScreen.Tests.ps1
   lists that gap and the others alongside it. */
'use strict';
const fs = require('fs');
const vm = require('vm');

// ---- virtual clock -------------------------------------------------------
class Clock {
  constructor(){ this.now = 1000; this.seq = 0; this.timers = new Map(); this.raf = new Map(); }
  setTimeout(fn, ms){ const id = ++this.seq; this.timers.set(id, {at:this.now+(ms||0), fn, every:0}); return id; }
  setInterval(fn, ms){ const id = ++this.seq; this.timers.set(id, {at:this.now+(ms||0), fn, every:Math.max(1,ms||1)}); return id; }
  clear(id){ this.timers.delete(id); }
  requestAnimationFrame(fn){ const id = ++this.seq; this.raf.set(id, fn); return id; }
  cancelAnimationFrame(id){ this.raf.delete(id); }
  async advance(ms){
    const end = this.now + ms;
    while (this.now < end){
      const step = Math.min(16, end - this.now);
      this.now += step;
      const due = [...this.timers.entries()].filter(function(e){ return e[1].at <= H.clock.now; })
                                            .sort(function(a,b){ return a[1].at - b[1].at; });
      for (const pair of due){
        const id = pair[0], t = pair[1];
        if (t.every){ t.at = this.now + t.every; } else { this.timers.delete(id); }
        try { t.fn(); } catch(e){ H.errors.push('timer: ' + e.message); }
      }
      const frames = [...this.raf.values()];
      this.raf.clear();
      for (const fn of frames){ try { fn(this.now); } catch(e){ H.errors.push('raf: ' + e.message); } }
      await new Promise(function(r){ setImmediate(r); });
    }
  }
}

// ---- DOM ------------------------------------------------------------------
class ClassList {
  constructor(){ this.s = new Set(); }
  add(c){ this.s.add(c); }
  remove(c){ this.s.delete(c); }
  toggle(c, on){ if (on === undefined) { this.s.has(c) ? this.s.delete(c) : this.s.add(c); } else if (on) this.s.add(c); else this.s.delete(c); }
  contains(c){ return this.s.has(c); }
}
class El {
  constructor(id, tag){
    this.id = id || '';
    this.tagName = (tag || 'DIV').toUpperCase();
    this.classList = new ClassList();
    this.dataset = {};
    this.style = {};
    this.attrs = {};
    this.children = [];
    this.listeners = {};
    this._text = '';
    this._html = '';
    this.value = '';
    this.hidden = true;
    this.disabled = false;
    this.scrollTop = 0; this.scrollHeight = 0; this.clientHeight = 400; this.clientWidth = 600;
    this.offsetHeight = 20;
    this.width = 0; this.height = 0;
    this.parentElement = null;
  }
  get textContent(){ return this._text; }
  set textContent(v){ this._text = String(v); }
  get innerHTML(){ return this._html; }
  set innerHTML(v){ this._html = String(v); }
  setAttribute(k, v){ this.attrs[k] = String(v); }
  getAttribute(k){ return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; }
  removeAttribute(k){ delete this.attrs[k]; }
  addEventListener(t, fn){ (this.listeners[t] = this.listeners[t] || []).push(fn); }
  removeEventListener(t, fn){ const a = this.listeners[t]; if (a) this.listeners[t] = a.filter(function(f){ return f !== fn; }); }
  dispatch(t, ev){
    const a = (this.listeners[t] || []).slice();
    const e = Object.assign({type:t, preventDefault(){}, stopPropagation(){}}, ev||{});
    const out = [];
    for (const fn of a){
      try { out.push(fn(e)); }
      catch(err){ H.errors.push('listener ' + t + ' on #' + this.id + ': ' + err.message); }
    }
    return out;
  }
  appendChild(c){ this.children.push(c); c.parentElement = this; return c; }
  insertBefore(c){ this.children.unshift(c); c.parentElement = this; return c; }
  querySelector(){ return null; }
  querySelectorAll(){ return []; }
  focus(){ H.doc.activeElement = this; }
  blur(){ H.doc.activeElement = H.doc.body; }
  select(){}
  getContext(){ return CANVAS_CTX; }
  getBoundingClientRect(){ return {top:0,left:0,right:this.clientWidth,bottom:this.clientHeight,width:this.clientWidth,height:this.clientHeight}; }
  scrollTo(){}
  remove(){}
  setPointerCapture(){ this.captured = true; }
  releasePointerCapture(){ this.captured = false; }
  hasPointerCapture(){ return !!this.captured; }
}
const CANVAS_CTX = new Proxy({}, {
  get: function(_t, k){
    if (k === 'canvas') return null;
    if (k === 'createLinearGradient' || k === 'createRadialGradient') return function(){ return {addColorStop(){}}; };
    if (k === 'measureText') return function(){ return {width:10}; };
    return function(){};
  },
  set: function(){ return true; }
});

// ---- the fake bridge server ----------------------------------------------
// Mirrors bin/fm-bridge.ps1: /api/listen is a TOGGLE whose edge the caller owns,
// and BOTH /api/fleet and /api/heard drain the one pending dictated line.
class Server {
  constructor(){
    this.pendingDictation = '';
    this.engineRecording = false;   // the dictation app's own microphone flag
    this.recording = false;         // a capture THE PAGE asked for
    this.awaitingPage = false;
    this.pendingForPage = false;
    this.toggles = [];
    this.warm = true;
    this.handsOver = true;
    this.calls = [];
    this.asked = [];
    this.listenBusy = false;
  }
  // A transcript arriving from the engine's hook (POST /api/dictate). It does
  // NOT mean the engine stopped: its capture is started and stopped by one
  // flag and by nothing else, which is why the page has to own a VAD for
  // continuous mode. So `engineRecording` is untouched here.
  engineHandsOver(text){
    this.pendingDictation = text;
    this.pendingForPage = (this.recording || this.awaitingPage);
  }
  async handle(url, opts){
    const p = String(url).split('#')[0].split('?')[0];
    this.calls.push(p);
    const body = opts && opts.body ? JSON.parse(opts.body) : null;
    if (p === '/api/health'){
      return {ok:true, configured:true, voice:false, listenMode:'push',
              speech:{installed:true, running:true, warm:this.warm, handsOver:this.handsOver, setup:''}};
    }
    if (p === '/api/listen'){
      // The same machine bin/fm-bridge.ps1 runs: the SERVER owns which edge of
      // the engine's toggle a request is on. Mirrors Step-FmSpeechCaptureState.
      let want = (body && body.action) || 'toggle';
      if (want === 'toggle') want = this.recording ? 'stop' : 'start';
      if (want === 'start'){
        if (!this.recording){ this.recording = true; this.engineRecording = !this.engineRecording; this.toggles.push('START'); }
        this.awaitingPage = false; this.pendingDictation = ''; this.pendingForPage = false;
      } else if (want === 'stop'){
        if (this.recording){ this.recording = false; this.engineRecording = !this.engineRecording; this.toggles.push('stop'); this.awaitingPage = true; }
        else { this.toggles.push('(none)'); }
      } else if (want === 'cancel'){
        if (this.recording){ this.recording = false; this.engineRecording = false; this.toggles.push('cancel'); }
        this.awaitingPage = false; this.pendingDictation = ''; this.pendingForPage = false;
      }
      return {ok:true, recording:this.recording, handsOver:this.handsOver, setup:''};
    }
    if (p === '/api/heard'){
      const t = this.pendingDictation;
      this.pendingDictation = ''; this.pendingForPage = false;
      // Only a line that actually arrived ends the wait - most polls here are
      // empty, because the engine takes about three seconds. Mirrors
      // Step-FmSpeechCaptureState's TakeForPage, and the reason is the same.
      if (t) this.awaitingPage = false;
      return {ok:true, text:t};
    }
    if (p === '/api/fleet'){
      let d = '';
      if (!(this.pendingForPage || this.awaitingPage)){ d = this.pendingDictation; this.pendingDictation = ''; }
      return {ok:true, engine:true, captain:'captain', voice:false, dictated:d,
              recording:this.recording,
              tasks:[], decisions:[], activity:[], house:[], capacity:null};
    }
    if (p === '/api/say'){ this.asked.push(body.text); return {ok:true, reply:'Acknowledged.', spoken:'Acknowledged.'}; }
    if (p === '/api/listen-mode') return {ok:true, mode:(body && body.mode) || 'push'};
    if (p === '/api/voice') return {ok:true, state:'off'};
    if (p === '/api/transcribe') return {ok:true, text:'a clip recorded here'};
    return {ok:true};
  }
}

// ---- audio graph ----------------------------------------------------------
class Node2 {
  constructor(kind){ this.kind = kind; this.connected = []; this.disconnected = false; this.gain = {value:1}; H.nodes.push(this); }
  connect(dst){
    if (this.disconnected) H.errors.push('connect() called on an already-disconnected ' + this.kind);
    this.connected.push(dst);
    return dst;
  }
  disconnect(){ this.disconnected = true; this.connected = []; }
}
class Analyser extends Node2 {
  constructor(){ super('analyser'); this.fftSize = 256; this.smoothingTimeConstant = 0; this.frequencyBinCount = 128; }
  getByteFrequencyData(a){
    if (this.disconnected) H.errors.push('getByteFrequencyData on a disconnected analyser');
    a.fill(H.level);
  }
}
class ScriptProc extends Node2 {
  constructor(bufSize){ super('scriptprocessor'); this.bufferSize = bufSize; this.onaudioprocess = null; }
}
class Ctx {
  constructor(){ this.state = 'running'; this.sampleRate = 48000; this.destination = new Node2('destination'); this.procs = []; H.ctxCount++; }
  async resume(){ this.state = 'running'; H.resumes++; }
  createScriptProcessor(n){ const p = new ScriptProc(n); this.procs.push(p); return p; }
  createGain(){ return new Node2('gain'); }
  createAnalyser(){ return new Analyser(); }
  createMediaStreamSource(){ return new Node2('source'); }
  pump(frames){
    for (const p of this.procs){
      if (p.disconnected || !p.onaudioprocess) continue;
      for (let i = 0; i < frames; i++){
        const chan = new Float32Array(p.bufferSize).fill(0.3);
        p.onaudioprocess({inputBuffer:{getChannelData:function(){ return chan; }}});
      }
    }
  }
}
class Track {
  constructor(){ this.readyState = 'live'; this.kind = 'audio'; }
  stop(){ if (this.readyState === 'live'){ this.readyState = 'ended'; H.micStops++; } }
}
class Stream {
  constructor(){ this.tracks = [new Track()]; }
  getAudioTracks(){ return this.tracks; }
  getTracks(){ return this.tracks; }
}

// ---- harness state --------------------------------------------------------
const H = {
  clock: null,
  server: null,
  errors: [],
  els: null,
  doc: null,
  win: null,
  micOpens: 0,
  micStops: 0,
  micDenied: false,
  nodes: [],
  ctxCount: 0,
  resumes: 0,
  level: 90,
  spoke: 0,
};

function el(id, tag){
  if (!H.els.has(id)){
    const e = new El(id, tag);
    // Every element gets a synthetic parent so layout reads have something to
    // measure; nothing here asserts anything about layout.
    e.parentElement = new El('', 'div');
    H.els.set(id, e);
  }
  return H.els.get(id);
}

function buildSandbox(){
  const doc = {
    activeElement: null,
    hidden: false,
    listeners: {},
    getElementById: function(id){ return el(id); },
    createElement: function(tag){ return new El('', tag); },
    addEventListener: function(t, fn){ (this.listeners[t] = this.listeners[t] || []).push(fn); },
    removeEventListener: function(t, fn){ const a = this.listeners[t]; if (a) this.listeners[t] = a.filter(function(f){ return f !== fn; }); },
    dispatch: function(t, ev){
      const e = Object.assign({type:t, preventDefault(){}}, ev||{});
      for (const fn of (this.listeners[t]||[]).slice()){
        try { fn(e); } catch(err){ H.errors.push('document ' + t + ': ' + err.message); }
      }
    },
    body: new El('body','body'),
    documentElement: new El('html','html'),
  };
  doc.activeElement = doc.body;
  H.doc = doc;

  const win = {
    listeners: {},
    devicePixelRatio: 1,
    innerWidth: 1366, innerHeight: 768,
    location: {hash:'#t=testtoken', href:'http://127.0.0.1:7777/#t=testtoken', reload: function(){ H.reloaded = true; }},
    document: doc,
    ResizeObserver: null,
    AudioContext: Ctx,
    webkitAudioContext: Ctx,
    speechSynthesis: {speaking:false, getVoices: function(){ return []; }, cancel: function(){}, speak: function(){ H.spoke++; }},
    SpeechSynthesisUtterance: function(t){ this.text = t; },
    navigator: {mediaDevices:{ getUserMedia: async function(){
      if (H.micDenied) throw new Error('NotAllowedError');
      H.micOpens++;
      return new Stream();
    } }},
    getComputedStyle: function(){ return {paddingLeft:'0px',paddingRight:'0px',paddingTop:'0px',paddingBottom:'0px',rowGap:'0px'}; },
    addEventListener: function(t, fn){ (this.listeners[t] = this.listeners[t] || []).push(fn); },
    removeEventListener: function(t, fn){ const a = this.listeners[t]; if (a) this.listeners[t] = a.filter(function(f){ return f !== fn; }); },
    dispatch: function(t, ev){
      const e = Object.assign({type:t, preventDefault(){}}, ev||{});
      for (const fn of (this.listeners[t]||[]).slice()){
        try { fn(e); } catch(err){ H.errors.push('window ' + t + ': ' + err.message); }
      }
    },
    setTimeout: function(fn, ms){ return H.clock.setTimeout(fn, ms); },
    clearTimeout: function(id){ H.clock.clear(id); },
    setInterval: function(fn, ms){ return H.clock.setInterval(fn, ms); },
    clearInterval: function(id){ H.clock.clear(id); },
    requestAnimationFrame: function(fn){ return H.clock.requestAnimationFrame(fn); },
    cancelAnimationFrame: function(id){ H.clock.cancelAnimationFrame(id); },
    fetch: async function(url, opts){
      const obj = await H.server.handle(url, opts);
      return {status:200, ok:true, json: async function(){ return obj; }};
    },
    URLSearchParams: URLSearchParams,
    Date: (function(){
      // A real Date whose `now` and no-arg construction come from the virtual clock.
      function FakeDate(){
        if (arguments.length === 0) return new Date(H.clock.now);
        return new (Function.prototype.bind.apply(Date, [null].concat([].slice.call(arguments))))();
      }
      FakeDate.now = function(){ return H.clock.now; };
      FakeDate.parse = Date.parse; FakeDate.UTC = Date.UTC;
      FakeDate.prototype = Date.prototype;
      return FakeDate;
    })(),
    Blob: class { constructor(parts){ this.size = (parts && parts[0] && parts[0].byteLength) || 0; this.type = 'audio/wav'; } },
    console: console,
  };
  win.window = win;
  win.self = win;
  // Bare `addEventListener(...)` in the page resolves to the global with no
  // receiver, so bind the window's own methods to the window.
  ['addEventListener','removeEventListener','dispatch'].forEach(function(k){ win[k] = win[k].bind(win); });
  ['addEventListener','removeEventListener','dispatch'].forEach(function(k){ doc[k] = doc[k].bind(doc); });
  return win;
}

async function loadPage(htmlPath, tune){
  H.clock = new Clock();
  H.server = new Server();
  H.els = new Map();
  H.errors = [];
  H.nodes = [];
  H.micOpens = 0; H.micStops = 0; H.ctxCount = 0; H.resumes = 0; H.spoke = 0;
  H.micDenied = false; H.level = 90;

  if (tune) tune(H.server);
  const html = fs.readFileSync(htmlPath, 'utf8');
  const m = html.match(/<script>([\s\S]*)<\/script>/);
  if (!m) throw new Error('no <script> block in ' + htmlPath);
  const sandbox = buildSandbox();
  vm.createContext(sandbox);
  vm.runInContext(m[1], sandbox, {filename:'bridge.html'});
  H.win = sandbox;
  await H.clock.advance(400);      // bootCheck + the 300ms focusMessage settle
  return sandbox;
}

// ---- what a test drives ---------------------------------------------------
const act = {
  mouseDown: function(){ el('talk').dispatch('pointerdown', {pointerId:1}); },
  mouseUp:   function(){ el('talk').dispatch('pointerup', {pointerId:1}); },
  mouseLeave:function(){ el('talk').dispatch('pointerleave', {pointerId:1}); },
  pointerOff:function(){ el('talk').dispatch('pointercancel', {pointerId:1}); },
  blur:      function(){ H.win.dispatch('blur', {}); },
  keyDown:   function(code){ H.win.dispatch('keydown', {code:code, key:code, repeat:false}); },
  keyUp:     function(code){ H.win.dispatch('keyup', {code:code, key:code}); },
  micIsOpen: function(){ return el('micState').dataset.open === 'true'; },
  micWord:   function(){ return el('micStateWord').textContent; },
  stage:     function(){ return el('stateStrip').dataset.state; },
  stageWord: function(){ return el('stateWord').textContent; },
  hint:      function(){ return el('dockHint').textContent; },
  heard:     function(){ return el('heard').textContent || el('heard').innerHTML; },
  focused:   function(){ return H.doc.activeElement ? H.doc.activeElement.id : '(none)'; },
  liveTracks:function(){ return H.nodes.length; },
};

module.exports = {H, loadPage, el, act};
