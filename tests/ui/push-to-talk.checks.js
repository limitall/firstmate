'use strict';
/* Push to talk, driven against ui/bridge.html's own script.

   WHY THIS IS NOT A PESTER FILE. The page is JavaScript, and the defect it is
   guarding against was a state machine defect: which edge of the engine's
   toggle a release is on, whose transcript a poll may take, and whether a hold
   survives the things that used to end it. None of that is reachable from
   PowerShell, and none of it needs a microphone, a browser or a served page to
   exercise - so it is executed here, in Node, against a stubbed browser.
   tests/FmBridgeScreen.Tests.ps1 runs this file and turns each line below into
   a Pester result, so `Invoke-Pester -Path ./tests` remains the one gate.

   WHAT IT CANNOT PROVE is stated in that file and in
   docs/windows-e2e-evidence.md section 32: real amplitude from real hardware,
   the browser's own permission prompt, and layout. Everything here is the
   logic around those.

   Emits one JSON object per line so the Pester wrapper can name each check. */
const {H, loadPage, el, act} = require('./bridge-page-harness.js');
const PAGE = process.argv[2];

const out = [];
function chk(name, got, want){
  out.push({name: name, ok: String(got) === String(want), got: String(got), want: String(want)});
}
function note(name, value){ out.push({name: name, ok: true, got: String(value), want: String(value), note: true}); }

async function main(){
  // ---- the key the screen advertises -------------------------------------
  await loadPage(PAGE);
  note('the dock hint names a key', act.hint());
  note('focus 300ms after load is where focusMessage put it', act.focused());
  act.keyDown('AltRight');
  await H.clock.advance(300);
  chk('right Alt opens the microphone', act.stage(), 'listening');
  chk('right Alt: the badge says open', act.micWord(), 'Mic open');
  chk('right Alt: the engine is told exactly once', H.server.toggles.join(','), 'START');
  act.keyUp('AltRight');
  await H.clock.advance(300);
  chk('right Alt: release leaves nothing recording', H.server.recording, false);
  chk('right Alt: the engine is told exactly once more', H.server.toggles.join(','), 'START,stop');

  // ---- AltGr is a character, not a microphone ----------------------------
  await loadPage(PAGE);
  H.win.dispatch('keydown', {code:'AltRight', ctrlKey:true, repeat:false});
  await H.clock.advance(200);
  chk('Control and right Alt together is AltGr, not push to talk', act.stage(), 'undefined');
  H.win.dispatch('keyup', {code:'AltRight', ctrlKey:true});

  // ---- Space still types a space ----------------------------------------
  await loadPage(PAGE);
  chk('the caret starts in the message box', act.focused(), 'typed');
  act.keyDown('Space');
  await H.clock.advance(200);
  chk('Space while typing does not open the microphone', act.stage(), 'undefined');
  act.keyUp('Space');
  H.doc.activeElement = H.doc.body;
  act.keyDown('Space');
  await H.clock.advance(300);
  chk('Space with the caret elsewhere does open it', act.stage(), 'listening');
  act.keyUp('Space');
  await H.clock.advance(200);

  // ---- the 1-2 second cutoff --------------------------------------------
  // The previous capture's transcript arrives three seconds after ITS release,
  // which lands inside the next hold. The fleet poll used to answer it there.
  await loadPage(PAGE);
  act.mouseDown();
  await H.clock.advance(300);
  chk('the hold has opened the microphone', act.stage(), 'listening');
  H.server.engineHandsOver('a line still in flight from the last press');
  await H.clock.advance(2400);
  chk('a whole fleet poll later, still listening', act.stage(), 'listening');
  chk('a whole fleet poll later, nothing has been asked', H.server.asked.length, 0);
  await H.clock.advance(4000);
  chk('six seconds in, still listening', act.stage(), 'listening');
  chk('six seconds in, the badge is still open', act.micWord(), 'Mic open');
  act.mouseUp();
  await H.clock.advance(600);
  chk('the release told the engine once', H.server.toggles.join(','), 'START,stop');
  chk('the engine is not left recording', H.server.recording, false);
  chk('the badge closes with it', act.micWord(), 'Mic closed');
  const afterSteal = H.server.toggles.length;
  act.mouseDown();
  await H.clock.advance(400);
  chk('and the very next press opens the microphone', act.stage(), 'listening');
  chk('and the very next press reaches the engine', H.server.toggles.length - afterSteal, 1);
  act.mouseUp();
  await H.clock.advance(300);

  // ---- ten consecutive cycles -------------------------------------------
  await loadPage(PAGE);
  let opened = 0, answered = 0, closedAfter = 0;
  for (let i = 1; i <= 10; i++){
    act.mouseDown();
    await H.clock.advance(1500);
    if (act.stage() === 'listening' && act.micWord() === 'Mic open') opened++;
    act.mouseUp();
    await H.clock.advance(200);
    H.server.engineHandsOver('utterance ' + i);
    await H.clock.advance(1000);
    if (H.server.asked.length === i) answered++;
    if (act.micWord() === 'Mic closed' && !H.server.recording) closedAfter++;
  }
  chk('ten consecutive holds each opened the microphone', opened, 10);
  chk('ten consecutive releases each produced an answer', answered, 10);
  chk('ten consecutive releases each closed the microphone', closedAfter, 10);
  chk('twenty engine edges, strictly alternating', H.server.toggles.join(','),
      Array(10).fill('START,stop').join(','));
  chk('nothing is left recording after ten cycles', H.server.recording, false);

  // ---- a long hold -------------------------------------------------------
  await loadPage(PAGE);
  act.mouseDown();
  await H.clock.advance(200);
  let held = act.stage() === 'listening';
  for (let s = 0; s < 30; s++){
    await H.clock.advance(1000);
    if (act.stage() !== 'listening' || act.micWord() !== 'Mic open') held = false;
  }
  chk('a thirty second hold captures the whole thirty seconds', held, true);
  chk('a long hold tells the engine once, not repeatedly', H.server.toggles.join(','), 'START');
  note('the screen counts the hold out loud', el('stateSecs').textContent);
  act.mouseUp();
  await H.clock.advance(400);
  chk('a long hold releases cleanly', H.server.toggles.join(','), 'START,stop');
  chk('a long hold leaves the microphone closed', act.micWord(), 'Mic closed');

  // ---- the pointer drifting off the button -------------------------------
  await loadPage(PAGE);
  act.mouseDown();
  await H.clock.advance(300);
  act.mouseLeave();
  await H.clock.advance(500);
  chk('the pointer leaving the button does not end the hold', act.stage(), 'listening');
  chk('the button holds the pointer for the whole press', el('talk').hasPointerCapture(), true);
  act.mouseUp();
  await H.clock.advance(300);
  chk('and the release still lands after a drift', H.server.recording, false);

  // ---- a hold the window takes away --------------------------------------
  await loadPage(PAGE);
  act.keyDown('AltRight');
  await H.clock.advance(300);
  chk('holding the key before the window goes', act.stage(), 'listening');
  act.blur();                                   // the keyup will never arrive
  await H.clock.advance(500);
  chk('a window that loses focus closes the microphone', H.server.recording, false);
  chk('a window that loses focus says the microphone is closed', act.micWord(), 'Mic closed');
  chk('a window that loses focus says so on screen', /lost focus/.test(act.heard()), true);
  const afterBlur = H.server.toggles.length;
  act.keyDown('AltRight');
  await H.clock.advance(400);
  chk('the press after a lost hold still works', act.stage(), 'listening');
  chk('the press after a lost hold reaches the engine', H.server.toggles.length - afterBlur, 1);
  act.keyUp('AltRight');
  await H.clock.advance(300);

  // ---- a press while the last words are outstanding ----------------------
  await loadPage(PAGE);
  act.mouseDown(); await H.clock.advance(400); act.mouseUp();
  await H.clock.advance(300);
  const waiting = H.server.toggles.length;
  act.mouseDown();
  await H.clock.advance(400);
  chk('a press while waiting for the last words is not swallowed', act.stage(), 'listening');
  chk('a press while waiting for the last words reaches the engine',
      H.server.toggles.length - waiting, 1);
  act.mouseUp();
  await H.clock.advance(300);

  // ---- an answer must not relabel the hold that follows it ---------------
  // The settle back to "standing by" is scheduled a couple of seconds after an
  // answer. A press inside that window used to be relabelled while the
  // microphone was open, which on screen reads as the capture stopping itself.
  await loadPage(PAGE);
  act.mouseDown(); await H.clock.advance(400); act.mouseUp();
  await H.clock.advance(200);
  H.server.engineHandsOver('the first thing said');
  await H.clock.advance(900);
  chk('the answer landed', H.server.asked.length, 1);
  act.mouseDown();
  await H.clock.advance(2600);                 // straddles the 2.2s settle
  chk('the previous answer does not relabel the hold that follows it', act.stage(), 'listening');
  chk('and the microphone is still open through it', act.micWord(), 'Mic open');
  act.mouseUp();
  await H.clock.advance(300);

  // ---- refusals are visible ----------------------------------------------
  await loadPage(PAGE);
  H.win.showHeard('an answer long enough to be worth expanding');
  H.win.openSheet();
  await H.clock.advance(100);
  act.keyDown('AltRight');
  await H.clock.advance(300);
  chk('a press behind the reply overlay is refused', act.stage(), 'undefined');
  chk('and the refusal is said out loud', /Close the full reply/.test(act.heard()), true);
  act.keyUp('AltRight');

  // ---- the slow path, and what the audio graph looks like afterwards -----
  await loadPage(PAGE, function(sv){ sv.warm = false; });
  let slow = 0;
  for (let i = 1; i <= 10; i++){
    act.mouseDown();
    await H.clock.advance(600);
    if (act.stage() === 'listening' && act.micWord() === 'Mic open') slow++;
    for (const nd of H.nodes){
      if (nd.kind === 'scriptprocessor' && nd.onaudioprocess && !nd.disconnected){
        for (let k = 0; k < 40; k++){
          nd.onaudioprocess({inputBuffer:{getChannelData: function(){ return new Float32Array(4096).fill(0.3); }}});
        }
      }
    }
    act.mouseUp();
    await H.clock.advance(1200);
  }
  chk('ten holds on the slow path each opened the microphone', slow, 10);
  chk('every stream the slow path opened was stopped', H.micStops, H.micOpens);
  chk('the slow path leaves the page holding no stream', act.micWord(), 'Mic closed');
  const live = H.nodes.filter(function(nd){ return !nd.disconnected && nd.kind !== 'destination'; });
  note('audio nodes built over ten slow-path presses', H.nodes.length);
  chk('no audio node is left connected after ten presses', live.length, 0);
  chk('one AudioContext serves the whole page', H.ctxCount, 1);

  // ---- nothing threw where nothing could be seen to throw ----------------
  chk('no listener or timer raised', H.errors.join(' | '), '');

  out.forEach(function(r){ console.log(JSON.stringify(r)); });
  process.exit(out.some(function(r){ return !r.ok; }) ? 1 : 0);
}

main().catch(function(e){
  console.log(JSON.stringify({name:'the harness itself ran', ok:false, got:String(e && e.stack || e), want:'no error'}));
  process.exit(1);
});
