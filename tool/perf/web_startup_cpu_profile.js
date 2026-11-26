async () => {
  const browser = page.context().browser();
  const URL = 'http://127.0.0.1:8899/';
  const out = {};

  const inject = () => {
    window.__perf = { sdone: null, longtasks: [] };
    const obs = new MutationObserver(() => {
      const sk = document.getElementById('boot-skeleton');
      if (sk && sk.getAttribute('data-done') === '1' && !window.__perf.sdone) {
        window.__perf.sdone = performance.now();
      }
    });
    obs.observe(document, { subtree: true, attributes: true, attributeFilter: ['data-done'], childList: true });
    try {
      new PerformanceObserver((l) => {
        l.getEntries().forEach(e => window.__perf.longtasks.push({ start: Math.round(e.startTime), dur: Math.round(e.duration) }));
      }).observe({ entryTypes: ['longtask'] });
    } catch (e) {}
  };

  // Cold: fresh context
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await ctx.addInitScript(inject);
  const p = await ctx.newPage();
  const cdp = await ctx.newCDPSession(p);
  await cdp.send('Performance.enable');
  await cdp.send('Profiler.enable');
  await cdp.send('Profiler.setSamplingInterval', { interval: 100 });
  await cdp.send('Profiler.start');
  await p.goto(URL, { waitUntil: 'load' });
  await p.waitForFunction(() => window.__perf && window.__perf.sdone !== null, null, { timeout: 30000 });
  const { profile } = await cdp.send('Profiler.stop');
  await p.waitForTimeout(200);
  const m = await cdp.send('Performance.getMetrics');
  const mv = (n) => (m.metrics.find(x => x.name === n) || {}).value || 0;

  const detail = await p.evaluate(() => {
    const res = performance.getEntriesByType('resource');
    const js = res.find(r => r.name.includes('main.dart.js'));
    const wasm = res.find(r => r.name.includes('canvaskit.wasm'));
    const cjs = res.find(r => r.name.includes('canvaskit.js'));
    const rinfo = (r) => r ? { start: Math.round(r.startTime), end: Math.round(r.responseEnd), dur: Math.round(r.duration) } : null;
    return {
      firstFrame: Math.round(window.__perf.sdone),
      js: rinfo(js), wasm: rinfo(wasm), canvaskitJs: rinfo(cjs),
      longtasks: window.__perf.longtasks.slice(0, 20),
      longtaskTotal: window.__perf.longtasks.reduce((s, t) => s + t.dur, 0)
    };
  });

  // Profile: aggregate self-time by function (top leaves)
  const nodes = profile.nodes;
  const idToNode = {};
  nodes.forEach(n => idToNode[n.id] = n);
  const selfSamples = {};
  (profile.samples || []).forEach(id => selfSamples[id] = (selfSamples[id] || 0) + 1);
  const intervalMs = (profile.endTime - profile.startTime) / 1000 / (profile.samples || []).length;
  const hot = Object.entries(selfSamples).map(([id, c]) => {
    const n = idToNode[id];
    const f = n && n.callFrame || {};
    return { fn: (f.functionName || '(anon)'), url: (f.url || '').split('/').pop(), ms: Math.round(c * (profile.timeDeltas ? 1 : 1)) };
  }).sort((a, b) => {
    const ca = selfSamples[Object.keys(idToNode).find(k => idToNode[k].callFrame && idToNode[k].callFrame.functionName === a.fn && idToNode[k].callFrame.url && idToNode[k].callFrame.url.endsWith(a.url))] || 0;
    return 0;
  });
  // simpler: top by sample count
  const top = Object.entries(selfSamples)
    .map(([id, c]) => {
      const f = (idToNode[id] && idToNode[id].callFrame) || {};
      return { fn: f.functionName || '(anonymous)', url: (f.url || '').split('/').pop() || '(native)', samples: c };
    })
    .sort((a, b) => b.samples - a.samples)
    .slice(0, 15);

  out.detail = detail;
  out.cpu = {
    scriptSec: +mv('ScriptDuration').toFixed(3),
    layoutSec: +mv('LayoutDuration').toFixed(3),
    recalcSec: +mv('RecalcStyleDuration').toFixed(3),
    taskSec: +mv('TaskDuration').toFixed(3),
    jsHeapMB: Math.round(mv('JSHeapUsedSize') / 1048576)
  };
  out.topCpu = top;
  await ctx.close();
  return JSON.stringify(out, null, 2);
}
