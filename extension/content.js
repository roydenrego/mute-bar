(() => {
  'use strict';

  // Meet's bottom toolbar auto-hides when idle and its buttons are REMOVED
  // from the DOM. So: in-meeting state comes from the URL (stable), the muted
  // flag is sticky (last observed from the mic button), and toggle() wakes the
  // toolbar with a synthetic mousemove before clicking.

  const MIC_LABEL_RE = /micro(phone|fono|fófono|fône)|mikrofon/i;
  const MEETING_URL_RE = /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}/;

  let stickyMuted = null;
  let lastPath = location.pathname;

  function findMicButton() {
    // In-call toggle is <button role="button">, prejoin uses div[role=button].
    // Prefer the toolbar toggle ("Turn on/off microphone"); Meet's audio
    // settings rows also mention the microphone.
    const btns = [...document.querySelectorAll('[role="button"][aria-label], button[aria-label]')];
    const toggle = btns.find((b) => /\bturn (on|off) (the )?mic/i.test(b.getAttribute('aria-label') || ''));
    if (toggle) return toggle;
    return btns.find((b) => MIC_LABEL_RE.test(b.getAttribute('aria-label') || '')) || null;
  }

  function inMeetingURL() {
    if (!MEETING_URL_RE.test(location.pathname)) return false;
    // "You left the meeting" screen keeps the meeting URL; detect it by its
    // Rejoin / Return-to-home buttons.
    return ![...document.querySelectorAll('[role="button"], button')]
      .some((b) => /return to home screen|rejoin/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.textContent || '')));
  }

  function readState() {
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      stickyMuted = null; // new page, unknown mute state
    }
    const btn = findMicButton();
    if (btn) {
      const label = (btn.getAttribute('aria-label') || '').toLowerCase();
      // "turn on microphone" (i.e. action = un-mute) means we are currently muted
      stickyMuted = /\bturn on\b|attiva|aktivieren|activar/.test(label);
    }
    if (!inMeetingURL()) return { inMeeting: false, muted: null };
    return { inMeeting: true, muted: stickyMuted };
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  function wakeToolbar() {
    document.dispatchEvent(new MouseEvent('mousemove', {
      bubbles: true, cancelable: true, clientX: 200, clientY: 200,
    }));
  }

  async function toggle() {
    let btn = findMicButton();
    if (!btn) {
      wakeToolbar();
      const deadline = Date.now() + 800;
      while (!btn && Date.now() < deadline) {
        await sleep(50);
        btn = findMicButton();
      }
    }
    if (btn) {
      btn.click();
    } else {
      // Fallback: Meet's own keyboard shortcut (macOS)
      document.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'd', code: 'KeyD', keyCode: 68, which: 68,
        metaKey: true, bubbles: true, cancelable: true,
      }));
    }
    schedulePush(300);
  }

  let last = null;
  const same = (a, b) => a && b && a.inMeeting === b.inMeeting && a.muted === b.muted;

  function push(force) {
    const s = readState();
    if (!force && same(s, last)) return;
    last = s;
    // Promise rejection (SW asleep) must be caught explicitly — a try/catch
    // around sendMessage does not cover it.
    chrome.runtime.sendMessage({ type: 'state', ...s }).catch(() => {});
  }

  let pushTimer = null;
  function schedulePush(delay) {
    clearTimeout(pushTimer);
    pushTimer = setTimeout(() => push(false), delay);
  }

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg) return;
    if (msg.type === 'ping') {
      // Only a script whose extension context is still valid can answer. An
      // orphaned copy left behind by an extension reload cannot, which is how
      // the worker tells "already injected" from "needs re-injecting".
      sendResponse({ ok: true });
      return false;
    }
    if (msg.type === 'toggle') {
      toggle().then(() => sendResponse(readState()));
      return true; // async response
    }
    if (msg.type === 'getState') {
      push(true); // fresh state back to the app
      sendResponse(readState());
      return true;
    }
  });

  const observer = new MutationObserver(() => schedulePush(150));
  observer.observe(document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['aria-label'],
  });

  // Re-check periodically: toolbar hide/show and SPA navigations are covered
  // by the observer, but this catches anything missed while idle.
  setInterval(() => push(false), 5000);

  push(true);
})();
