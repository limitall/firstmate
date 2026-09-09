'use strict';
/* The first-run panel's refusal, driven against ui/bridge.html's own script.

   WHY THIS FILE EXISTS. What the captain saw on a fresh VM was not a bug in
   what the panel DOES - it was what the panel was handed:

     Exception calling "WriteAllText" with "3" argument(s): "Access to the path
     'C:\Users\Adit\firstmate\.fm-home' is denied."

   in red, under "Where should firstmate keep its work?", naming a path they had
   never typed. `setupErr.textContent = r.error` renders whatever the server
   sends, verbatim, so the guarantee that a .NET exception never reaches that
   line is a property of the PAIR - the sentence the server writes, and this
   line painting it unchanged. tests/FmBridge.Tests.ps1 pins the first half.
   This pins the second, and that the panel does something sensible with it.

   NO BROWSER AND NO BRIDGE. The page's script runs under node:vm against a
   stubbed window with no speechSynthesis behind it, so this cannot make a
   sound - which is the whole reason the check is here rather than on a screen.
   tests/FmBridgeScreen.Tests.ps1 runs this file and turns each line into a
   Pester result, so `Invoke-Pester -Path ./tests` remains the one gate.

   Emits one JSON object per line so the Pester wrapper can name each check. */
const {H, loadPage, el} = require('./bridge-page-harness.js');
const PAGE = process.argv[2];

const out = [];
function chk(name, got, want){
  out.push({name: name, ok: String(got) === String(want), got: String(got), want: String(want)});
}
function note(name, value){ out.push({name: name, ok: true, got: String(value), want: String(value), note: true}); }

// The sentence Initialize-FmBridgeWorkspace answers with when the checkout
// cannot be written to. Copied as the server really sends it.
const PLAIN = 'Your workspace is ready, but firstmate cannot remember it: firstmate itself is installed in ' +
  'C:\Users\Adit\firstmate, and Windows does not let this account write there. Move that folder into ' +
  'your own user folder - C:\Users\higet\firstmate-win, say - and run install.ps1 from its new place.';
const RAW = 'Exception calling "WriteAllText" with "3" argument(s): "Access to the path ' +
  '\'C:\Users\Adit\firstmate\.fm-home\' is denied."';

// A machine that has not been set up yet, whose /api/setup refuses.
function unconfigured(answer){
  return function(server){
    const inner = server.handle.bind(server);
    server.handle = async function(url, opts){
      const p = String(url).split('#')[0].split('?')[0];
      if (p === '/api/health'){
        return {ok:true, configured:false, voice:false, listenMode:'push',
                suggested:'C:\Users\higet\firstmate',
                speech:{installed:false, running:false, warm:false, handsOver:false, setup:''}};
      }
      if (p === '/api/setup'){ server.setupBody = opts && opts.body ? JSON.parse(opts.body) : null; return answer; }
      return inner(url, opts);
    };
  };
}

async function pressSetUp(){
  el('setupPath').value = 'C:\Users\higet\firstmate';
  el('setupGo').dispatch('click', {});
  await H.clock.advance(50);
}

async function main(){
  // ---- the panel is up, and it is the first-run one ----------------------
  await loadPage(PAGE, unconfigured({ok:false, error:PLAIN}));
  chk('an unconfigured machine gets the first-run panel', el('firstRun').style.display, 'grid');
  note('the box is pre-filled with what the bridge suggested', el('setupPath').value);

  // ---- a refusal the captain can act on ----------------------------------
  await pressSetUp();
  chk('the refusal is shown', el('setupError').style.display, 'block');
  chk('the panel paints the sentence unchanged', el('setupError').textContent, PLAIN);
  chk('no .NET exception reaches the panel', /Exception calling|WriteAllText|argument\(s\)/.test(el('setupError').textContent), false);
  chk('it names the folder that actually refused', el('setupError').textContent.indexOf('C:\Users\Adit\firstmate') >= 0, true);
  chk('it names a next step', /install\.ps1/.test(el('setupError').textContent), true);
  chk('it does not answer with the workaround', /as administrator/i.test(el('setupError').textContent), false);
  chk('the panel stays up, so the captain can try again', el('firstRun').style.display, 'grid');
  chk('the button is usable again', el('setupGo').disabled, false);
  chk('nothing was spoken', H.spoke, 0);

  // ---- the raw text, if it ever came back, would still not be dressed up --
  // The page is not the owner of the sentence and must not become one: it
  // paints what it is handed. This records what the OLD server produced, so a
  // regression that puts the exception back is visible HERE too, as a failure
  // of the pair rather than of one side.
  await loadPage(PAGE, unconfigured({ok:false, error:RAW}));
  await pressSetUp();
  chk('the page paints what it is handed, so the sentence must be right at the server',
      /Exception calling/.test(el('setupError').textContent), true);

  // ---- and the way through, when it works --------------------------------
  await loadPage(PAGE, unconfigured({ok:true, home:'C:\Users\higet\firstmate', engine:false}));
  await pressSetUp();
  chk('a workspace that was made closes the panel', el('firstRun').style.display, 'none');

  process.stdout.write(out.map(o => JSON.stringify(o)).join('\n') + '\n');
}

main().catch(e => { process.stdout.write(JSON.stringify({name:'harness', ok:false, got:String(e && e.stack || e), want:'no error'}) + '\n'); });
