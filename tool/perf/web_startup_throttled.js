async () => {
  const browser = page.context().browser();
  const URL = 'http://127.0.0.1:8900/';
  const inject = () => {
    window.__ff = null;
    const obs = new MutationObserver(() => {
      const sk = document.getElementById('boot-skeleton');
      if (sk && sk.getAttribute('data-done') === '1' && !window.__ff) window.__ff = performance.now();
    });
    obs.observe(document, { subtree: true, attributes: true, attributeFilter: ['data-done'], childList: true });
  };

  const measure = async (ctx, throttle) => {
    const p = await ctx.newPage();
    const cdp = await ctx.newCDPSession(p);
    await cdp.send('Network.enable');
    if (throttle) {
      // "Fast 4G": 9 Mbps down, 1.6 Mbps up, 150ms RTT
      await cdp.send('Network.emulateNetworkConditions', {
        offline: false, latency: 150,
        downloadThroughput: 9 * 1024 * 1024 / 8,
        uploadThroughput: 1.6 * 1024 * 1024 / 8
      });
    }
    await p.goto(URL, { waitUntil: 'load' });
    await p.waitForFunction(() => window.__ff !== null, null, { timeout: 60000 });
    const r = await p.evaluate(() => {
      const res = performance.getEntriesByType('resource');
      const wasm = res.find(x => x.name.includes('canvaskit.wasm'));
      const js = res.find(x => x.name.includes('main.dart.js'));
      return {
        ff: Math.round(window.__ff),
        wasmEnd: wasm ? Math.round(wasm.responseEnd) : 0,
        jsEnd: js ? Math.round(js.responseEnd) : 0,
        xferKB: Math.round(res.reduce((s, r) => s + (r.transferSize || 0), 0) / 1024)
      };
    });
    await cdp.detach().catch(()=>{});
    await p.close();
    return r;
  };

  // Cold on Fast 4G (empty cache)
  const c1 = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await c1.addInitScript(inject);
  const cold4g = await measure(c1, true);
  await c1.close();

  // Warm on Fast 4G (disk cache hit, bytes=0)
  const c2 = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await c2.addInitScript(inject);
  await measure(c2, true);   // prime
  const warm4g = await measure(c2, true);  // cached
  await c2.close();

  return JSON.stringify({ cold4g, warm4g, improvement: +(cold4g.ff / warm4g.ff).toFixed(2) }, null, 2);
}
