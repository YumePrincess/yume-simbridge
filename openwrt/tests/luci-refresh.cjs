// Run with Playwright available on NODE_PATH (no dependency in router packages).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const resources = path.resolve(__dirname, '../root/www/luci-static/resources');
  const source = fs.readFileSync(path.join(resources, 'view/yume-simbridge/overview.js'), 'utf8');
  const css = fs.readFileSync(path.join(resources, 'yume-simbridge/style.css'), 'utf8');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.setContent('<style>body{margin:0}#luci{height:650px;overflow:auto;margin:0 20px}.spacer{height:1000px}</style><div class="spacer"></div><div id="luci"></div><div class="spacer"></div>');
    await page.addStyleTag({ content: css });
    await page.evaluate(source => {
      const E = (tag, attrs = {}, children = []) => {
        const node = document.createElement(tag);
        for (const [key, value] of Object.entries(attrs)) {
          if (typeof value === 'function') node.addEventListener(key, value);
          else node.setAttribute(key, value);
        }
        for (const child of [children].flat(Infinity)) {
          if (child != null) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
        }
        return node;
      };
      window.localState = { running: true, preferences: {}, version: { version: '27.3.0', build: 27035 }, local: { modemConnected: true, sipRegistered: true, voiceReady: true } };
      window.cloudState = { settings: {}, jobs: Array.from({ length: 90 }, (_, i) => ({ id: String(i), kind: 'sms', status: 'sent', created: Date.now()-i*1000, payload: JSON.stringify({ to: '+15550000000', body: 'Activity entry '+i }) })) };
      const rpc = { setBaseURL() {}, declare({ method }) { return async () => structuredClone(method === 'settings' ? cloudState : method === 'action' ? { log: 'persistent runtime log\n'.repeat(100) } : localState); } };
      const view = new Function('view', 'rpc', 'poll', 'ui', 'qr', 'i18n', 'L', 'E', source)(
        { extend: v => v }, rpc, { add: fn => { window.pollHealth = fn; } }, {}, {},
        { translate: (_, key) => key }, { url: v => v, resource: () => 'data:text/css,' }, E);
      document.querySelector('#luci').append(view.render([structuredClone(localState), structuredClone(cloudState)]));
      const now = Date.now;
      window.offset = 0;
      Date.now = () => now()+window.offset;
      window.tick = async () => { window.offset += 6000; await pollHealth(); await new Promise(resolve => setTimeout(resolve, 0)); };
      document.querySelector('[data-page=activity]').click();
    }, source);
    const result = await page.evaluate(async () => {
      const panel = document.querySelector('#luci');
      panel.scrollTop = 1800;
      document.scrollingElement.scrollTop = 700;
      const first = document.querySelector('.yh-record');
      await tick();
      const stable = first === document.querySelector('.yh-record');
      cloudState.jobs[0].status = 'delivered';
      await tick();
      return { stable, panel: panel.scrollTop, document: document.scrollingElement.scrollTop, updated: document.querySelector('.yh-record').textContent.includes('delivered') };
    });
    assert.equal(result.stable, true, 'unchanged polling must retain DOM identity');
    assert.equal(result.panel, 1800, 'changed data must preserve LuCI container scroll');
    assert.equal(result.document, 700, 'changed data must preserve document scroll');
    assert.equal(result.updated, true, 'new activity must still appear');
    await page.evaluate(async () => {
      document.querySelector('[data-page=settings]').click();
      [...document.querySelectorAll('button')].find(node => node.textContent === 'Refresh log').click();
      await new Promise(resolve => setTimeout(resolve, 0));
    });
    const log = await page.evaluate(async () => {
      const node = document.querySelector('#yh-runtime-log');
      const panel = document.querySelector('#luci');
      panel.scrollTop = 1000;
      const position = panel.scrollTop;
      const before = node.textContent;
      cloudState.jobs[0].status = 'changed again';
      await tick();
      return { same: node === document.querySelector('#yh-runtime-log'), text: node.textContent === before, scroll: panel.scrollTop, position };
    });
    assert.equal(log.same, true, 'background polling must not rebuild log/settings');
    assert.equal(log.text, true, 'runtime log must survive polling');
    assert(log.position > 0, 'fixture must scroll through a long log');
    assert.equal(log.scroll, log.position, 'runtime log scroll must survive polling');
    console.log('LuCI browser regression passed: unchanged DOM, changed activity, nested/document scroll, runtime log.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
