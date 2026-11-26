#!/usr/bin/env node
/**
 * A/B 冷启动综合基准 —— deepseek_monitor web
 *
 * 量化四件事，每侧 N 轮，取中位数：
 *   1) cold first frame   : 全新 incognito context（空 HTTP cache），
 *                           MutationObserver 捕获 #boot-skeleton 的 data-done="1"
 *                           → performance.now()。
 *   2) CPU TaskDuration   : CDP Performance.getMetrics，主线程累计忙时。
 *                           两个采样点：首帧瞬间 & 稳定窗口结束。
 *   3) longtask           : PerformanceObserver('longtask')，>50ms 主线程长任务。
 *   4) main.dart.js 体积  : resource timing 的 transfer/decoded + HTTP Content-Length。
 *
 * 公平性约束：
 *   - 每轮都是 browser.newContext()（隔离缓存/存储），跑完立即 close。
 *   - A/B 轮次交错（ABBA），抵消顺序漂移与热降频。
 *   - 两侧 serve 同源同策略（Cache-Control: no-store），首帧判定标记一致。
 *   - 首帧超时 25s < index.html 的 30s 兜底定时器，避免把兜底误判成首帧。
 *
 * 用法:
 *   node tool/perf/ab_baseline_bench.mjs
 *   node tool/perf/ab_baseline_bench.mjs --rounds 5 --after 8900 --before 8901
 *   node tool/perf/ab_baseline_bench.mjs --json out.json --md out.md
 */

import { createRequire } from 'node:module';
import { readdirSync, existsSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);

/* ------------------------------------------------------------------ args */
function parseArgs(argv) {
  const a = {
    after: 8900, before: 8901,
    rounds: 5, settle: 2500, frameTimeout: 25000,
    json: 'tool/perf/ab_baseline_result.json',
    md: 'tool/perf/ab_baseline_result.md',
    headed: false,
    isolate: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    switch (k) {
      case '--after': a.after = Number(v); i++; break;
      case '--before': a.before = Number(v); i++; break;
      case '--rounds': a.rounds = Math.max(1, Number(v)); i++; break;
      case '--settle': a.settle = Math.max(0, Number(v)); i++; break;
      case '--frame-timeout': a.frameTimeout = Number(v); i++; break;
      case '--json': a.json = v; i++; break;
      case '--md': a.md = v; i++; break;
      case '--headed': a.headed = true; break;
      case '--isolate-browser': a.isolate = true; break;
      case '--help': case '-h': printHelp(); process.exit(0);
      default: if (k.startsWith('--')) { console.error('unknown arg: ' + k); process.exit(2); }
    }
  }
  return a;
}
function printHelp() {
  console.log('ab_baseline_bench.mjs [--after PORT] [--before PORT] [--rounds N] [--settle MS] [--json PATH] [--md PATH] [--headed]');
  console.log('默认 AFTER=8900  BEFORE=8901  rounds=5  settle=2500ms');
  console.log('');
  console.log('注意: settle 必须 > 2000ms。实测 TaskDuration 在首帧后 ~1250ms 才进入平台期,');
  console.log('      在陡坡区间(250-1000ms)采样会产生 400ms 级抖动, 曾导致结论翻转。');
}

/* ------------------------------------------------------------- playwright */
function resolvePlaywright() {
  const tried = [];
  const tryReq = (spec) => {
    try { return require(spec); } catch (e) { tried.push(spec + ' -> ' + e.code); return null; }
  };
  let pw = tryReq('playwright');
  if (pw) return pw;

  const npxRoot = path.join(homedir(), '.npm', '_npx');
  if (existsSync(npxRoot)) {
    for (const d of readdirSync(npxRoot)) {
      const p = path.join(npxRoot, d, 'node_modules', 'playwright');
      if (existsSync(p)) {
        pw = tryReq(p);
        if (pw) { console.error('[bench] playwright <- ' + p); return pw; }
      }
    }
  }
  console.error('[bench] 找不到 playwright，尝试过的路径:\n  ' + tried.join('\n  '));
  console.error('[bench] 修复: npx --yes playwright@latest --version  （或 npm i -D playwright）');
  process.exit(3);
}

/* --------------------------------------------------------------- helpers */
const median = (xs) => {
  const v = xs.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
};
const round = (n, d = 1) => (n === null || n === undefined || !Number.isFinite(n)) ? null : Number(n.toFixed(d));
const pct = (after, before) => (before ? round(((after - before) / before) * 100, 2) : null);

const quantile = (xs, q) => {
  const v = xs.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const pos = (v.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  return lo === hi ? v[lo] : v[lo] + (v[hi] - v[lo]) * (pos - lo);
};

/**
 * 配对差值的中位数检验（符号翻转 / 单样本置换）。
 * 每一轮 AFTER 与 BEFORE 相邻测量，相减可抵消机器负载的分钟级漂移
 * —— 这是跨运行复现性差的主因（实测平台值跨运行可差 377ms）。
 * H0: 配对差值的中位数为 0。
 */
function pairedTest(deltas, iterations = 5000) {
  const d = deltas.filter((x) => Number.isFinite(x));
  if (d.length < 3) return { observed: null, p: null, note: '样本不足' };
  const observed = median(d);
  // 单样本置换：随机翻转每个差值的符号
  let hits = 0;
  const absObs = Math.abs(observed);
  for (let i = 0; i < iterations; i++) {
    let sum = 0;
    const flipped = d.map((x) => (Math.random() < 0.5 ? -x : x)).sort((a, b) => a - b);
    const m = Math.floor(flipped.length / 2);
    const med = flipped.length % 2 ? flipped[m] : (flipped[m - 1] + flipped[m]) / 2;
    if (Math.abs(med) >= absObs - 1e-9) hits++;
  }
  const p = (hits + 1) / (iterations + 1);
  return {
    observed: round(observed, 1),
    mean: round(d.reduce((a, b) => a + b, 0) / d.length, 1),
    n: d.length,
    p: round(p, 3),
    note: p < 0.05 ? '显著' : '不显著',
  };
}

/**
 * 两独立样本置换检验（双侧），统计量为中位数差。
 * 样本小、分布未知时比 t 检验可靠；5000 次重排足够稳定。
 */
function permutationTest(a, b, iterations = 5000) {
  const A = a.filter((x) => Number.isFinite(x));
  const B = b.filter((x) => Number.isFinite(x));
  if (A.length < 2 || B.length < 2) return { observed: null, p: null, note: '样本不足' };
  const observed = Math.abs(median(A) - median(B));
  const pool = A.concat(B);
  const na = A.length;
  let hits = 0;
  for (let i = 0; i < iterations; i++) {
    const s = pool.slice();
    for (let j = s.length - 1; j > 0; j--) {
      const k = Math.floor(Math.random() * (j + 1));
      const t = s[j]; s[j] = s[k]; s[k] = t;
    }
    const d = Math.abs(median(s.slice(0, na)) - median(s.slice(na)));
    if (d >= observed - 1e-9) hits++;
  }
  const p = (hits + 1) / (iterations + 1);
  return { observed: round(observed, 1), p: round(p, 3), note: p < 0.05 ? '显著' : '不显著' };
}

async function httpProbe(port, file) {
  const url = 'http://127.0.0.1:' + port + '/' + file;
  const res = await fetch(url, { cache: 'no-store' });
  const buf = Buffer.from(await res.arrayBuffer());
  return {
    url, status: res.status,
    contentLengthHeader: Number(res.headers.get('content-length') || 0) || null,
    bytes: buf.length,
  };
}

async function assertReachable(port) {
  try {
    const r = await fetch('http://127.0.0.1:' + port + '/', { cache: 'no-store' });
    if (!r.ok) throw new Error('status ' + r.status);
    return true;
  } catch (e) {
    console.error('[bench] 端口 ' + port + ' 不可达: ' + e.message);
    return false;
  }
}

/* -------------------------------------------------- 页面内注入的采集探针 */
function injectedProbe() {
  window.__perf = { sdone: null, longtasks: [], sw: null };
  try {
    const sk0 = document.getElementById('boot-skeleton');
    if (sk0 && sk0.getAttribute('data-done') === '1') window.__perf.sdone = 0;
  } catch (e) {}

  const obs = new MutationObserver(() => {
    const sk = document.getElementById('boot-skeleton');
    if (!sk) return;
    if (sk.getAttribute('data-done') === '1' && window.__perf.sdone === null) {
      window.__perf.sdone = Math.round(performance.now() * 10) / 10;
    }
  });
  obs.observe(document, { subtree: true, attributes: true, attributeFilter: ['data-done'], childList: true });

  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        window.__perf.longtasks.push({ start: Math.round(e.startTime), dur: Math.round(e.duration) });
      }
    }).observe({ entryTypes: ['longtask'] });
  } catch (e) {}

  try {
    if ('serviceWorker' in navigator) {
      const c = navigator.serviceWorker.controller;
      window.__perf.sw = c ? 'controlled' : 'none';
    } else {
      window.__perf.sw = 'unsupported';
    }
  } catch (e) {}
}

async function collectPageData(page) {
  return page.evaluate(() => {
    const abs = (n) => Math.round(n * 10) / 10;
    const nav = performance.getEntriesByType('navigation')[0] || {};
    const res = performance.getEntriesByType('resource').map((r) => {
      let p = r.name;
      try { p = new URL(r.name).pathname; } catch (e) {}
      return {
        path: p,
        start: abs(r.startTime), end: abs(r.responseEnd), dur: abs(r.duration),
        transfer: r.transferSize || 0,
        encoded: r.encodedBodySize || 0,
        decoded: r.decodedBodySize || 0,
      };
    });
    const exact = (want) => res.find((r) => r.path === want || r.path.endsWith('/' + want)) || null;
    const mainJs = exact('main.dart.js');
    const wasm = res.find((r) => r.path.endsWith('/canvaskit.wasm'));
    const paint = performance.getEntriesByType('paint') || [];
    const fcp = paint.find((p) => p.name === 'first-contentful-paint');

    const lt = (window.__perf && window.__perf.longtasks) || [];
    return {
      firstFrameMs: window.__perf && window.__perf.sdone !== null ? abs(window.__perf.sdone) : null,
      sw: (window.__perf && window.__perf.sw) || null,
      nav: {
        responseEnd: abs(nav.responseEnd || 0),
        domContentLoaded: abs(nav.domContentLoadedEventEnd || 0),
        load: abs(nav.loadEventEnd || 0),
        transferSize: nav.transferSize || 0,
      },
      fcpMs: fcp ? abs(fcp.startTime) : null,
      resources: res.length,
      totalTransferKB: Math.round(res.reduce((s, r) => s + r.transfer, 0) / 1024),
      mainJs: mainJs ? {
        startMs: mainJs.start, endMs: mainJs.end, resourceMs: mainJs.dur,
        transferBytes: mainJs.transfer, encodedBytes: mainJs.encoded, decodedBytes: mainJs.decoded,
      } : null,
      canvaskitWasm: wasm ? { endMs: wasm.end, transferBytes: wasm.transfer } : null,
      longtask: {
        count: lt.length,
        totalMs: Math.round(lt.reduce((s, t) => s + t.dur, 0)),
        maxMs: lt.length ? Math.max(...lt.map((t) => t.dur)) : 0,
        tasks: lt.slice(0, 20),
        beforeFrameMs: (() => {
          const ff = window.__perf && window.__perf.sdone;
          if (ff === null || ff === undefined) return null;
          const pre = lt.filter((t) => t.start <= ff);
          return Math.round(pre.reduce((s, t) => s + t.dur, 0));
        })(),
      },
    };
  });
}

const CPU_KEYS = ['TaskDuration', 'ScriptDuration', 'LayoutDuration', 'RecalcStyleDuration', 'JSHeapUsedSize', 'Nodes'];
const pickCpu = (m) => {
  const o = {};
  for (const k of CPU_KEYS) {
    const hit = m.metrics.find((x) => x.name === k);
    const v = hit ? hit.value : 0;
    o[k] = (k === 'JSHeapUsedSize') ? Math.round(v / 1048576 * 10) / 10 : Math.round(v * 1000 * 10) / 10;
  }
  return o;
};

/* ------------------------------------------------ 单轮冷启动（一个全新 ctx） */
async function runRound(browser, port, opts, pairIndex) {
  const url = 'http://127.0.0.1:' + port + '/';
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 1,
    ignoreHTTPSErrors: true,
  });
  const out = { port, ok: false, error: null, pairIndex };
  try {
    await ctx.addInitScript(injectedProbe);
    const page = await ctx.newPage();
    const cdp = await ctx.newCDPSession(page);
    await cdp.send('Performance.enable');

    const t0 = Date.now();
    await page.goto(url, { waitUntil: 'load', timeout: 60000 });

    let frameOk = true;
    try {
      await page.waitForFunction(
        () => window.__perf && window.__perf.sdone !== null,
        null,
        { timeout: opts.frameTimeout, polling: 16 }
      );
    } catch (e) {
      frameOk = false;
    }
    const wallToFrame = Date.now() - t0;

    const mFrame = pickCpu(await cdp.send('Performance.getMetrics'));
    const atFrame = await collectPageData(page);

    await page.waitForTimeout(opts.settle);

    // 平台期自检：再等 300ms 采第二次，两次 TaskDuration 差值就是漂移量。
    // 漂移 > 50ms 说明还没进平台期，该轮 CPU 数值不可信，必须标记出来。
    const mSettle = pickCpu(await cdp.send('Performance.getMetrics'));
    await page.waitForTimeout(300);
    const mVerify = pickCpu(await cdp.send('Performance.getMetrics'));
    const taskDrift = Math.round((mVerify.TaskDuration - mSettle.TaskDuration) * 10) / 10;

    const atSettle = await collectPageData(page);
    const wallSettle = Date.now() - t0;

    out.ok = frameOk;
    out.error = frameOk ? null : 'first-frame timeout (' + opts.frameTimeout + 'ms)';
    out.wallToFrameMs = wallToFrame;
    out.wallToSettleMs = wallSettle;
    out.frame = atFrame;
    out.settle = atSettle;
    out.cpuAtFrame = mFrame;
    out.cpuAtSettle = mSettle;
    out.cpuVerify = mVerify;
    out.taskDrift = taskDrift;
    out.plateauReached = taskDrift <= 50;
  } catch (e) {
    out.error = String((e && e.message) || e);
  } finally {
    await ctx.close().catch(() => {});
  }
  return out;
}

/* -------------------------------------------------------------- 汇总侧别 */
function aggregate(rounds) {
  const ok = rounds.filter((r) => r.ok);
  const col = (fn) => ok.map(fn).filter((x) => x !== null && x !== undefined && Number.isFinite(x));
  const med = (fn) => median(col(fn));
  const spread = (fn) => {
    const v = col(fn);
    if (v.length < 2) return null;
    return { min: round(Math.min(...v)), max: round(Math.max(...v)), iqr: round(quantile(v, 0.75) - quantile(v, 0.25)) };
  };

  // 原始样本留给置换检验（供 buildMarkdown 之外的调用方使用）
  const samples = {
    coldFirstFrameMs: col((r) => r.frame.firstFrameMs),
    taskDurationMs: col((r) => r.cpuAtSettle.TaskDuration),
    stableScriptMs: col((r) => r.cpuAtSettle.ScriptDuration),
    longtaskTotalMs: col((r) => r.frame.longtask.totalMs),
    longtaskMaxMs: col((r) => r.frame.longtask.maxMs),
    beforeFrameLongtaskMs: col((r) => r.frame.longtask.beforeFrameMs),
    fcpMs: col((r) => r.frame.fcpMs),
  };

  return {
    spread: {
      coldFirstFrameMs: spread((r) => r.frame.firstFrameMs),
      taskDurationMs: spread((r) => r.cpuAtSettle.TaskDuration),
      longtaskTotalMs: spread((r) => r.frame.longtask.totalMs),
    },
    samples,
    rounds: rounds.length,
    okRounds: ok.length,
    failedRounds: rounds.length - ok.length,
    coldFirstFrameMs: round(med((r) => r.frame.firstFrameMs)),
    wallToFrameMs: round(med((r) => r.wallToFrameMs)),
    fcpMs: round(med((r) => r.frame.fcpMs)),
    dclMs: round(med((r) => r.frame.nav.domContentLoaded)),
    loadMs: round(med((r) => r.frame.nav.load)),
    cpu: {
      taskDurationAtFrameMs: round(med((r) => r.cpuAtFrame.TaskDuration)),
      taskDurationMs: round(med((r) => r.cpuAtSettle.TaskDuration)),
      scriptMs: round(med((r) => r.cpuAtSettle.ScriptDuration)),
      layoutMs: round(med((r) => r.cpuAtSettle.LayoutDuration)),
      recalcStyleMs: round(med((r) => r.cpuAtSettle.RecalcStyleDuration)),
      jsHeapMB: round(med((r) => r.cpuAtSettle.JSHeapUsedSize)),
      nodes: round(med((r) => r.cpuAtSettle.Nodes), 0),
    },
    longtask: {
      count: round(med((r) => r.frame.longtask.count), 0),
      totalMs: round(med((r) => r.frame.longtask.totalMs)),
      maxMs: round(med((r) => r.frame.longtask.maxMs)),
      beforeFrameMs: round(med((r) => r.frame.longtask.beforeFrameMs)),
    },
    mainJs: {
      decodedBytes: round(med((r) => r.frame.mainJs && r.frame.mainJs.decodedBytes), 0),
      transferBytes: round(med((r) => r.frame.mainJs && r.frame.mainJs.transferBytes), 0),
      resourceMs: round(med((r) => r.frame.mainJs && r.frame.mainJs.resourceMs)),
    },
    totalTransferKB: round(med((r) => r.frame.totalTransferKB), 0),
    resources: round(med((r) => r.frame.resources), 0),
    swMode: ok.length ? ok[0].frame.sw : null,
    plateau: {
      reached: ok.filter((r) => r.plateauReached).length,
      total: ok.length,
      maxDriftMs: ok.length ? round(Math.max(...ok.map((r) => Math.abs(r.taskDrift || 0)))) : null,
      medDriftMs: round(med((r) => Math.abs(r.taskDrift || 0))),
    },
    perRound: rounds.map((r, i) => ({
      round: i + 1, ok: r.ok, error: r.error,
      firstFrameMs: r.ok ? round(r.frame.firstFrameMs) : null,
      taskDurationMs: r.ok ? round(r.cpuAtSettle.TaskDuration) : null,
      taskDriftMs: r.ok ? r.taskDrift : null,
      plateau: r.ok ? r.plateauReached : null,
      longtaskTotalMs: r.ok ? round(r.frame.longtask.totalMs) : null,
      mainJsDecoded: r.ok && r.frame.mainJs ? r.frame.mainJs.decodedBytes : null,
    })),
  };
}

/* ---------------------------------------------------------------- 报告 */
function buildMarkdown(after, before, httpAfter, httpBefore, opts, paired) {
  const L = [];
  const get = (o, pathStr) => pathStr.split('.').reduce((acc, k) => (acc == null ? null : acc[k]), o);
  const row = (label, pathStr) => {
    const a = get(after, pathStr), b = get(before, pathStr);
    return '| ' + label + ' | ' + (a ?? '—') + ' | ' + (b ?? '—') + ' | ' + (pct(a, b) ?? '—') + '% | — |';
  };
  const sigOf = (sampleKey) => {
    const s = after.samples && after.samples[sampleKey];
    const t = before.samples && before.samples[sampleKey];
    if (!s || !t) return null;
    return permutationTest(s, t);
  };
  const head = () => {
    L.push('| 指标 | AFTER (' + opts.after + ') | BEFORE (' + opts.before + ') | Δ | p (置换检验) |');
    L.push('| --- | ---: | ---: | ---: | ---: |');
  };
  const rowSig = (label, pathStr, sampleKey) => {
    const a = get(after, pathStr), b = get(before, pathStr);
    const sig = sigOf(sampleKey);
    const pv = sig && sig.p !== null ? sig.p + (sig.p < 0.05 ? ' 显著' : ' 不显著') : '—';
    return '| ' + label + ' | ' + (a ?? '—') + ' | ' + (b ?? '—') + ' | ' + (pct(a, b) ?? '—') + '% | ' + pv + ' |';
  };

  L.push('# deepseek_monitor web · A/B 冷启动综合基准');
  L.push('');
  L.push('- AFTER : 127.0.0.1:' + opts.after + '  (Lite sigma 2-5)');
  L.push('- BEFORE: 127.0.0.1:' + opts.before + '  (旧 sigma 18-26)');
  L.push('- 每侧 ' + opts.rounds + ' 轮全新 incognito context，ABBA 交错，取中位数');
  L.push('- 首帧口径: #boot-skeleton 的 data-done="1" 被设置时的 performance.now()');
  L.push('- CPU 口径: CDP Performance.getMetrics，首帧后稳定 ' + opts.settle + 'ms 的累计值');
  L.push('- Δ 为正 = AFTER 更大；耗时/长任务/体积越小越好');
  L.push('');
  L.push('## 首帧与加载');
  L.push('');
  head();
  L.push(rowSig('冷启动首帧 (ms)', 'coldFirstFrameMs', 'coldFirstFrameMs'));
  L.push(rowSig('FCP (ms)', 'fcpMs', 'fcpMs'));
  L.push(row('DOMContentLoaded (ms)', 'dclMs'));
  L.push(row('load (ms)', 'loadMs'));
  L.push(row('墙钟到首帧 (ms)', 'wallToFrameMs'));
  L.push('');
  L.push('## CPU TaskDuration (ms)');
  L.push('');
  head();
  L.push(row('TaskDuration @首帧', 'cpu.taskDurationAtFrameMs'));
  L.push(rowSig('TaskDuration @稳定', 'cpu.taskDurationMs', 'taskDurationMs'));
  L.push(rowSig('ScriptDuration', 'cpu.scriptMs', 'stableScriptMs'));
  L.push(row('LayoutDuration', 'cpu.layoutMs'));
  L.push(row('RecalcStyleDuration', 'cpu.recalcStyleMs'));
  L.push(row('JSHeapUsed (MB)', 'cpu.jsHeapMB'));
  L.push('');
  L.push('## Long Task (>50ms)');
  L.push('');
  head();
  L.push(row('longtask 次数', 'longtask.count'));
  L.push(rowSig('longtask 总时长 (ms)', 'longtask.totalMs', 'longtaskTotalMs'));
  L.push(rowSig('longtask 最长 (ms)', 'longtask.maxMs', 'longtaskMaxMs'));
  L.push(rowSig('首帧前 longtask (ms)', 'longtask.beforeFrameMs', 'beforeFrameLongtaskMs'));
  L.push('');
  L.push('## main.dart.js 与传输');
  L.push('');
  head();
  L.push(row('main.dart.js decoded (B)', 'mainJs.decodedBytes'));
  L.push(row('main.dart.js transfer (B)', 'mainJs.transferBytes'));
  L.push(row('main.dart.js 下载耗时 (ms)', 'mainJs.resourceMs'));
  L.push('| HTTP Content-Length (B) | ' + (httpAfter.contentLengthHeader ?? '—') + ' | ' + (httpBefore.contentLengthHeader ?? '—') + ' | ' + (pct(httpAfter.contentLengthHeader, httpBefore.contentLengthHeader) ?? '—') + '% | — |');
  L.push(row('全页 transfer (KB)', 'totalTransferKB'));
  L.push(row('请求数', 'resources'));
  L.push('| SW 状态 | ' + (after.swMode ?? '—') + ' | ' + (before.swMode ?? '—') + ' | — |');
  L.push('');
  L.push('## 逐轮原始值');
  L.push('');
  L.push('| 轮 | 侧 | 首帧 (ms) | TaskDuration (ms) | 漂移 (ms) | 平台期 | longtask 总 (ms) | main.dart.js (B) |');
  L.push('| ---: | --- | ---: | ---: | ---: | :---: | ---: | ---: |');
  const prow = (r, side) => '| ' + r.round + ' | ' + side + ' | ' + (r.firstFrameMs ?? 'FAIL') + ' | ' + (r.taskDurationMs ?? '—') + ' | ' + (r.taskDriftMs ?? '—') + ' | ' + (r.plateau === true ? 'OK' : r.plateau === false ? '未达标' : '—') + ' | ' + (r.longtaskTotalMs ?? '—') + ' | ' + (r.mainJsDecoded ?? '—') + ' |';
  for (const r of after.perRound) L.push(prow(r, 'AFTER'));
  for (const r of before.perRound) L.push(prow(r, 'BEFORE'));
  L.push('');
  if (after.failedRounds || before.failedRounds) {
    L.push('> 失败轮次: AFTER ' + after.failedRounds + ' / BEFORE ' + before.failedRounds + ' —— 已从统计中剔除。');
    L.push('');
  }
  // ---- 离散度与自动结论 ----
  const sp = (side, key) => {
    const s = side.spread && side.spread[key];
    if (!s) return '—';
    return s.min + '–' + s.max + ' (IQR ' + s.iqr + ')';
  };
  L.push('## 离散度（min–max, IQR）');
  L.push('');
  L.push('| 指标 | AFTER | BEFORE |');
  L.push('| --- | --- | --- |');
  L.push('| 冷启动首帧 (ms) | ' + sp(after, 'coldFirstFrameMs') + ' | ' + sp(before, 'coldFirstFrameMs') + ' |');
  L.push('| TaskDuration (ms) | ' + sp(after, 'taskDurationMs') + ' | ' + sp(before, 'taskDurationMs') + ' |');
  L.push('| longtask 总 (ms) | ' + sp(after, 'longtaskTotalMs') + ' | ' + sp(before, 'longtaskTotalMs') + ' |');
  L.push('');
  L.push('## 配对差值（同轮 AFTER − BEFORE，抵消环境漂移）');
  L.push('');
  L.push('> 跨运行平台值可差 377ms，远大于 A/B 差异本身；独立样本检验因此会翻转符号。');
  L.push('> 配对差值在同轮相邻测量内相减，共享的机器负载被抵消。负值 = AFTER 更省。');
  L.push('');
  L.push('| 指标 | 中位差值 | 均值差 | 样本 | p (符号翻转) | 判定 |');
  L.push('| --- | ---: | ---: | ---: | ---: | --- |');
  const prow2 = (label, t, unit) => {
    if (!t || t.p === null) return '| ' + label + ' | — | — | ' + (t ? t.n : 0) + ' | — | 样本不足 |';
    const better = t.observed < 0;
    return '| ' + label + ' | ' + t.observed + ' ' + unit + ' | ' + t.mean + ' | ' + t.n + ' | ' + t.p + ' | ' +
      (t.p < 0.05 ? ('显著，AFTER ' + (better ? '更省' : '更费')) : '不显著') + ' |';
  };
  L.push(prow2('TaskDuration', paired.taskDuration, 'ms'));
  L.push(prow2('ScriptDuration', paired.scriptDuration, 'ms'));
  L.push(prow2('冷启动首帧', paired.firstFrame, 'ms'));
  L.push(prow2('longtask 总时长', paired.longtaskTotal, 'ms'));
  L.push('');
  L.push('逐轮差值 (TaskDuration, ms): ' + (paired.raw.task.join(', ') || '—'));
  L.push('');
  L.push('## 自动判读');
  L.push('');
  const verdicts = [];
  // 配对检验为主判据（抵消漂移），独立样本检验仅作交叉参考
  const pT = paired.taskDuration;
  const pF = paired.firstFrame;
  const pL = paired.longtaskTotal;
  const pairedJudge = (name, t, unit) => {
    if (!t || t.p === null) return name + ': 配对样本不足（需 ≥3 对），不作结论。';
    if (t.p >= 0.05) return name + ': 配对差值不显著 (p=' + t.p + ', 中位差 ' + t.observed + ' ' + unit + ')，视为噪声。';
    return name + ': 配对显著 (p=' + t.p + ', 中位差 ' + t.observed + ' ' + unit + ')，AFTER ' +
      (t.observed < 0 ? '更省' : '更费') + '。';
  };
  const vt = sigOf('coldFirstFrameMs');
  const vc = sigOf('taskDurationMs');
  const vl = sigOf('longtaskTotalMs');
  const judge = (name, sig, deltaPct, goodDirection) => {
    if (!sig || sig.p === null) return name + ': 样本不足，不作结论。';
    if (sig.p >= 0.05) return name + ': 差异不显著 (p=' + sig.p + ')，视为噪声，不能作为改进或退化的证据。';
    const better = goodDirection === 'lower' ? deltaPct < 0 : deltaPct > 0;
    return name + ': 显著 (p=' + sig.p + ', Δ=' + deltaPct + '%)，AFTER ' + (better ? '更优' : '更差') + '。';
  };
  verdicts.push('[主判据] ' + pairedJudge('TaskDuration', pT, 'ms'));
  verdicts.push('[主判据] ' + pairedJudge('冷启动首帧', pF, 'ms'));
  verdicts.push('[主判据] ' + pairedJudge('longtask 总时长', pL, 'ms'));
  verdicts.push('[参考] ' + judge('TaskDuration(独立样本)', vc, pct(after.cpu.taskDurationMs, before.cpu.taskDurationMs), 'lower'));
  verdicts.push('[参考] ' + judge('冷启动首帧(独立样本)', vt, pct(after.coldFirstFrameMs, before.coldFirstFrameMs), 'lower'));
  const sizeDelta = pct(after.mainJs.decodedBytes, before.mainJs.decodedBytes);
  verdicts.push('main.dart.js 体积: Δ=' + sizeDelta + '% (' + after.mainJs.decodedBytes + ' vs ' + before.mainJs.decodedBytes + ' B)，确定性事实，非统计推断。');

  // 平台期是 CPU 数字可信的前提；不达标就直接判废，不给漂亮数字
  const pA = after.plateau, pB = before.plateau;
  const plateauOk = pA.reached === pA.total && pB.reached === pB.total;
  verdicts.push('平台期校验 (settle=' + opts.settle + 'ms): AFTER ' + pA.reached + '/' + pA.total +
    ' (最大漂移 ' + pA.maxDriftMs + 'ms), BEFORE ' + pB.reached + '/' + pB.total +
    ' (最大漂移 ' + pB.maxDriftMs + 'ms) → ' +
    (plateauOk ? '全部达标，CPU 数字可信。' : '存在未达标轮次，CPU 对比结论不可信，需加大 settle 重测。'));
  for (const v of verdicts) L.push('- ' + v);
  L.push('');
  L.push('> 判读纪律：p ≥ 0.05 的差异一律记为噪声。体积是确定性事实，不受样本量影响。');
  return L.join('\n');
}

/* ------------------------------------------------------------------ main */
async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const pw = resolvePlaywright();

  const okA = await assertReachable(opts.after);
  const okB = await assertReachable(opts.before);
  if (!okA || !okB) process.exit(4);

  const httpAfter = await httpProbe(opts.after, 'main.dart.js');
  const httpBefore = await httpProbe(opts.before, 'main.dart.js');
  console.error('[bench] main.dart.js  AFTER: ' + httpAfter.bytes + ' B   BEFORE: ' + httpBefore.bytes + ' B');

  const launchArgs = [
    '--no-first-run', '--no-default-browser-check',
    '--disable-background-timer-throttling',
    '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows',
    '--force-device-scale-factor=1',
  ];
  const launch = () => pw.chromium.launch({ headless: !opts.headed, args: launchArgs });

  const roundsA = [];
  const roundsB = [];
  let sharedBrowser = opts.isolate ? null : await launch();
  if (opts.isolate) console.error('[bench] isolate-browser: 每轮独立浏览器进程');

  try {
    for (let i = 0; i < opts.rounds; i++) {
      const abFirst = i % 2 === 0;
      const order = abFirst
        ? [['AFTER', opts.after], ['BEFORE', opts.before]]
        : [['BEFORE', opts.before], ['AFTER', opts.after]];
      for (const pair of order) {
        const label = pair[0], port = pair[1];
        const t = Date.now();
        const b = opts.isolate ? await launch() : sharedBrowser;
        const r = await runRound(b, port, opts, i);
        if (opts.isolate) await b.close().catch(() => {});
        const ms = Date.now() - t;
        if (label === 'AFTER') roundsA.push(r); else roundsB.push(r);
        console.error('[bench] round ' + (i + 1) + '/' + opts.rounds + ' ' + label +
          ' (' + port + ') ' + (r.ok
            ? 'ff=' + r.frame.firstFrameMs + 'ms task=' + r.cpuAtSettle.TaskDuration + 'ms lt=' + r.frame.longtask.totalMs + 'ms'
            : 'FAIL: ' + r.error) + ' [' + ms + 'ms wall]');
      }
    }
  } finally {
    if (sharedBrowser) await sharedBrowser.close().catch(() => {});
  }

  const after = aggregate(roundsA);
  const before = aggregate(roundsB);

  // ---- 配对差值：同轮内 AFTER - BEFORE，抵消共享环境漂移 ----
  const paired = (() => {
    const byIdx = new Map();
    for (const r of roundsA) if (r.ok) byIdx.set(r.pairIndex, { a: r });
    for (const r of roundsB) if (r.ok) {
      const slot = byIdx.get(r.pairIndex);
      if (slot) slot.b = r;
    }
    const pairs = [...byIdx.values()].filter((s) => s.a && s.b);
    const dTask = pairs.map((s) => s.a.cpuAtSettle.TaskDuration - s.b.cpuAtSettle.TaskDuration);
    const dScript = pairs.map((s) => s.a.cpuAtSettle.ScriptDuration - s.b.cpuAtSettle.ScriptDuration);
    const dFrame = pairs.map((s) => s.a.frame.firstFrameMs - s.b.frame.firstFrameMs);
    const dLt = pairs.map((s) => s.a.frame.longtask.totalMs - s.b.frame.longtask.totalMs);
    return {
      pairCount: pairs.length,
      taskDuration: pairedTest(dTask),
      scriptDuration: pairedTest(dScript),
      firstFrame: pairedTest(dFrame),
      longtaskTotal: pairedTest(dLt),
      raw: {
        task: dTask.map((x) => round(x)),
        frame: dFrame.map((x) => round(x)),
      },
    };
  })();

  const result = {
    paired,
    generatedAt: new Date().toISOString(),
    options: opts,
    after: { label: 'AFTER', port: opts.after, http: httpAfter, metrics: after },
    before: { label: 'BEFORE', port: opts.before, http: httpBefore, metrics: before },
    significance: {
      coldFirstFrameMs: permutationTest(after.samples.coldFirstFrameMs, before.samples.coldFirstFrameMs),
      taskDurationMs: permutationTest(after.samples.taskDurationMs, before.samples.taskDurationMs),
      longtaskTotalMs: permutationTest(after.samples.longtaskTotalMs, before.samples.longtaskTotalMs),
    },
    delta: {
      coldFirstFrameMsPct: pct(after.coldFirstFrameMs, before.coldFirstFrameMs),
      taskDurationPct: pct(after.cpu.taskDurationMs, before.cpu.taskDurationMs),
      scriptPct: pct(after.cpu.scriptMs, before.cpu.scriptMs),
      longtaskTotalPct: pct(after.longtask.totalMs, before.longtask.totalMs),
      mainJsDecodedPct: pct(after.mainJs.decodedBytes, before.mainJs.decodedBytes),
      totalTransferPct: pct(after.totalTransferKB, before.totalTransferKB),
    },
  };

  const md = buildMarkdown(after, before, httpAfter, httpBefore, opts, paired);
  writeFileSync(opts.json, JSON.stringify(result, null, 2));
  writeFileSync(opts.md, md);

  console.log(md);
  console.error('\n[bench] wrote ' + opts.json + ' and ' + opts.md);
}

main().catch((e) => { console.error(e); process.exit(1); });
