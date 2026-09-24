// Native-acceptance only: observe trusted input, never invoke selection or click().
(async () => {
  const report = data => window.__TAURI_INTERNALS__.invoke('gui_acceptance_report', { data });
  const wait = async test => {
    const end = performance.now() + 60000;
    while (!test()) {
      if (performance.now() > end) throw Error('integrated UI timeout');
      await new Promise(resolve => setTimeout(resolve, 25));
    }
  };
  try {
    for (const [phase, id, kind] of [
      ['initial', 'fixture-a', 'keydown'], ['mouse', 'fixture-b', 'click'],
      ['keyboard', 'fixture-a', 'keydown'], ['performance', 'fixture-video', 'keydown'],
    ]) {
      const selector = `button[aria-label="${id} 배경화면 선택"]`;
      await wait(() => document.querySelector(selector));
      const card = document.querySelector(selector);
      card.scrollIntoView({ block: 'center' });
      card.focus();
      let trusted = false;
      card.addEventListener(kind, e => {
        if (e.isTrusted && (kind === 'click' || e.key === 'Enter')) {
          trusted = true;
          report({ phase: `integrated-${phase}-input`, trusted: true, kind });
        }
      }, { once: true });
      const rect = card.getBoundingClientRect();
      await report({ phase: `integrated-${phase}-ready`, x: rect.x + rect.width / 2,
        y: rect.y + rect.height / 2, innerHeight, id, kind });
      await wait(() => trusted);
      // The runner, not this ACK, decides when the visible-frame measurement ends.
      await new Promise(resolve => setTimeout(resolve, phase === 'performance' ? 1000 : 5000));
    }
  } catch (error) {
    await report({ phase: 'integrated-error', error: String(error) });
  }
})();
