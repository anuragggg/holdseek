// Tracks which frames are playing media and relays seeks from the HoldSeek app.
// An open native port also keeps this service worker alive.
const playing = new Map(); // "tabId:frameId" -> { tabId, frameId }, most recently started last
let port = null;
let reported;

function connect() {
  if (port) return;
  port = chrome.runtime.connectNative('com.holdseek.bridge');
  port.onDisconnect.addListener(() => { void chrome.runtime.lastError; port = null; });
  port.onMessage.addListener(({ seek }) => {
    if (!seek) return report(true); // the app asked for the current state
    const target = [...playing.values()].pop();
    if (target) chrome.tabs.sendMessage(target.tabId, { seek }, { frameId: target.frameId }).catch(() => {});
  });
  report(true);
}

function report(force) {
  const now = playing.size > 0;
  if (port && (force || now !== reported)) port.postMessage({ playing: now });
  reported = now;
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  const key = `${sender.tab.id}:${sender.frameId}`;
  playing.delete(key);
  if (msg.playing) playing.set(key, { tabId: sender.tab.id, frameId: sender.frameId });
  connect(); // also retries if the app was installed after Chrome started
  report();
});

chrome.tabs.onRemoved.addListener(tabId => {
  for (const [key, t] of playing) if (t.tabId === tabId) playing.delete(key);
  report();
});

connect();
