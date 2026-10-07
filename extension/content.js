// Tells the extension whether this frame is playing media, and seeks it on request.
const playing = new Set(); // most recently started last

function send() {
  try { chrome.runtime.sendMessage({ playing: playing.size > 0 }).catch(() => {}); } catch {} // extension was reloaded
}

for (const type of ['play', 'pause', 'ended', 'emptied']) {
  document.addEventListener(type, ({ target: media }) => {
    if (!(media instanceof HTMLMediaElement)) return;
    playing.delete(media);
    if (!media.paused && !media.ended) playing.add(media);
    send();
  }, true); // media events don't bubble, so listen in the capture phase
}

addEventListener('pagehide', () => { playing.clear(); send(); });

chrome.runtime.onMessage.addListener(({ seek }) => {
  const media = [...playing].pop();
  if (media) media.currentTime = Math.max(0, media.currentTime + seek);
});
