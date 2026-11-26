async () => {
  const R = (n) => Math.round(n || 0);
  const mp = (m, ks) => Object.fromEntries(ks.map(k => [k, R((m.metrics.find(x => x.name === k) || {}).value)]));
  const browser = page.context().browser();
  const URL = 'http://127.0.0.1:8899/';
  const out = {};

  const injectObserver = () => {
    window.__perf = { sdone: null };
    const obs = new MutationObserver(() => {
      const sk = document.getElementById('boot-skeleton');
      if (sk && sk.getAttribute('data-done') === '1' && !window.__perf.sdone) {
        window.__perf.sdone = performance.now();
      }
    });
    obs.observe(document, { subtree: true, attributes: true, attributeFilter: ['data-done'], childList: true });
  };

  // ==================== COLD: fresh context, empty cache ====================
  const cold = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await cold.addInitScript(injectObserver);
  const cp = await cold.newPage();
  const cdp = await cold.newCDPSession(cp);
  await cdp.send('Performance.enable');
  const t0 = Date.now();
  await cp.goto(URL, { waitUntil: 'load' });
  let coldFrame = null;
  try {
    await cp.waitForFunction(() => window.__perf && window.__perf.sdone !== null, null, { timeout: 30000 });
    coldFrame = await cp.evaluate(() => window.__perf.sdone);
  } catch (e) { coldFrame = -1; }
  const wallCold = Date.now() - t0;
  await cp.waitForTimeout(400);
  const cm = await cdp.send('Performance.getMetrics');
  const cnav = await cp.evaluate(() => {
    const n = performance.getEntriesByType('navigation')[0] || {};
    const res = performance.getEntriesByType('resource').map(r => ({
      name: r.name.split('/').pop(), dur: Math.round(r.duration),
      size: r.transferSize || 0, start: Math.round(r.startTime)
    }));
    return {
      firstFrame: Math.round(window.__perf && window.__perf.sdone || 0),
      domContentLoaded: Math.round(n.domContentLoadedEventEnd || 0),
      load: Math.round(n.loadEventEnd || 0),
      responseEnd: Math.round(n.responseEnd || 0),
      resourceCount: res.length,
      totalTransferKB: Math.round(res.reduce((s, r) => s + r.size, 0) / 1024),
      topResources: res.slice().sort((a, b) => b.size - a.size).slice(0, 10)
    };
  });
  out.cold = {
    wallMs: wallCold,
    timing: cnav,
    cpu: mp(cm, ['ScriptDuration', 'LayoutDuration', 'RecalcStyleDuration', 'TaskDuration', 'JSHeapUsedSize', 'Nodes'])
  };
  await cold.close();

  // ==================== WARM: default context, cached reload ====================
  const dctx = page.context();
  await dctx.addInitScript(injectObserver);
  const dp = dctx.pages()[0] || await dctx.newPage();
  await dp.goto(URL, { waitUntil: 'load' }); // prime cache
  await dp.waitForTimeout(400);
  const wcdp = await dctx.newCDPSession(dp);
  await wcdp.send('Performance.enable');
  const tw = Date.now();
  await dp.reload({ waitUntil: 'load' });
  let warmFrame = null;
  try {
    await dp.waitForFunction(() => window.__perf && window.__perf.sdone !== null, null, { timeout: 15000 });
    warmFrame = await dp.evaluate(() => window.__perf.sdone);
  } catch (e) { warmFrame = -1; }
  const wallWarm = Date.now() - tw;
  await dp.waitForTimeout(300);
  const wm = await wcdp.send('Performance.getMetrics');
  const wnav = await dp.evaluate(() => {
    const n = performance.getEntriesByType('navigation')[0] || {};
    const res = performance.getEntriesByType('resource').map(r => ({
      name: r.name.split('/').pop(), dur: Math.round(r.duration), size: r.transferSize || 0
    }));
    return {
      firstFrame: Math.round(window.__perf && window.__perf.sdone || 0),
      domContentLoaded: Math.round(n.domContentLoadedEventEnd || 0),
      load: Math.round(n.loadEventEnd || 0),
      responseEnd: Math.round(n.responseEnd || 0),
      resourceCount: res.length,
      totalTransferKB: Math.round(res.reduce((s, r) => s + r.size, 0) / 1024),
      topResources: res.slice().sort((a, b) => b.size - a.size).slice(0, 10)
    };
  });
  out.warm = {
    wallMs: wallWarm,
    timing: wnav,
    cpu: mp(wm, ['ScriptDuration', 'LayoutDuration', 'RecalcStyleDuration', 'TaskDuration', 'JSHeapUsedSize', 'Nodes'])
  };

  return JSON.stringify(out, null, 2);
}
