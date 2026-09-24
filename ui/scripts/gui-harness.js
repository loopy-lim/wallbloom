// Runs inside the actual Wry WebView; never substitutes invoke/listen or React.
(async () => {
  const log = [];
  const status = () => document.querySelector('[role="status"]')?.textContent || '';
  const report = (data) => window.__TAURI_INTERNALS__.invoke('gui_acceptance_report', { data });
  const wait = async (test, name) => {
    const start = performance.now();
    while (!test()) {
      if (performance.now() - start > 20000) throw Error(`timeout: ${name}; ${status()}`);
      await new Promise(r => setTimeout(r, 20));
    }
    log.push({ name, status: status(), ms: performance.now() - start });
  };
  const card = () => document.querySelector('button[aria-label="fixture 배경화면 선택"]');
  const input = () => document.querySelector('#download-url');
  const button = () => [...document.querySelectorAll('button')].find(b => b.textContent === '다운로드');
  const setUrl = value => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input(), value);
    input().dispatchEvent(new Event('input', { bubbles: true }));
  };
  try {
    await wait(card, 'real IPC scan rendered fixture');
    card().click();
    await wait(() => status().includes('선택했습니다'), 'DOM card click -> native select');
    await wait(() => document.querySelector('[aria-label="로컬 라이브러리 정보"]')?.textContent.includes('마지막 선택: fixture'), 'real OpenUI renderer shows selected local metadata');
    document.querySelector('header button').click();
    await wait(() => status().includes('불러왔습니다'), 'refresh via native scan');
    card().focus();
    let trustedKey = false;
    card().addEventListener('keydown', e => { if (e.isTrusted && e.key === 'Enter') trustedKey = true; });
    await report({ phase: 'keyboard-ready', log });
    await wait(() => trustedKey && status().includes('선택했습니다'), 'trusted OS Enter -> card selection');
    setUrl('__BASE__/download.mp4');
    await wait(() => button() && !button().disabled, 'download enabled');
    button().click();
    await wait(() => status().startsWith('다운로드 중:'), 'native progress rendered');
    await report({ phase: 'progress', log });
    await wait(() => status().includes('다운로드 완료'), 'download published and rescanned');
    await wait(() => document.querySelector('button[aria-label="download 배경화면 선택"]'), 'download card rendered');
    setUrl('__BASE__/failure.mp4');
    await wait(() => button() && !button().disabled, 'failure URL enabled');
    button().click();
    await wait(() => status().startsWith('다운로드 실패:'), 'HTTP failure rendered');
    await report({ phase: 'complete', status: 'PASS', javascript_ipc: true, real_tauri_webview: true, rustra_scan: true, openui_local_info: true, log });
  } catch (error) { await report({ phase: 'complete', status: 'FAIL', error: String(error), log }); }
})();
