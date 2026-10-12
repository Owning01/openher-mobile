const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('G:/Proyectos/video-apuntes/node_modules/ws');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function sendCDP(ws, id, method, params = {}) {
  return new Promise((resolve, reject) => {
    const handler = (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.id === id) {
          ws.off('message', handler);
          if (msg.error) reject(new Error(JSON.stringify(msg.error)));
          else resolve(msg.result);
        }
      } catch (e) {
        // ignore other messages
      }
    };
    ws.on('message', handler);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function capture() {
  const chromePath = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  const port = 9333;
  const targetUrl = 'file:///' + path.resolve('prototype/showcase.html').replace(/\\/g, '/');

  console.log('Launching headless Chrome on port', port);
  const chrome = spawn(chromePath, [
    '--headless=new',
    `--remote-debugging-port=${port}`,
    '--window-size=480,960',
    '--hide-scrollbars',
    '--force-device-scale-factor=1',
    targetUrl
  ]);

  await sleep(2000);

  try {
    // Get list of targets
    const targets = await new Promise((resolve, reject) => {
      http.get(`http://127.0.0.1:${port}/json`, res => {
        let body = '';
        res.on('data', d => body += d);
        res.on('end', () => resolve(JSON.parse(body)));
      }).on('error', reject);
    });

    const pageTarget = targets.find(t => t.type === 'page') || targets[0];
    if (!pageTarget) throw new Error('No page target found');

    console.log('Connecting to page ws:', pageTarget.webSocketDebuggerUrl);
    const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
    await new Promise(res => ws.on('open', res));

    let cmdId = 1;
    async function evalCode(code) {
      const res = await sendCDP(ws, ++cmdId, 'Runtime.evaluate', {
        expression: code,
        returnByValue: true,
        awaitPromise: true
      });
      return res;
    }

    async function takeScreenshot(filename) {
      const res = await sendCDP(ws, ++cmdId, 'Page.captureScreenshot', {
        format: 'png',
        clip: {
          x: 45,
          y: 20,
          width: 390,
          height: 844,
          scale: 1
        }
      });
      const buf = Buffer.from(res.data, 'base64');
      fs.writeFileSync(filename, buf);
      console.log('Saved screenshot:', filename);
    }

    // Wait for load
    await sleep(1000);

    // Screen 1: Sesiones
    await evalCode('window.__layers.go("sessions")');
    await sleep(500);
    await takeScreenshot('assets/screenshots/01_sessions.png');

    // Screen 2: Chat
    await evalCode('window.__layers.go("chat")');
    await sleep(500);
    await takeScreenshot('assets/screenshots/02_chat.png');

    // Screen 3: Archivos
    await evalCode('window.__layers.go("files")');
    await sleep(500);
    await takeScreenshot('assets/screenshots/03_files.png');

    // Screen 4: Ajustes
    await evalCode('window.__layers.go("settings")');
    await sleep(500);
    await takeScreenshot('assets/screenshots/04_settings.png');

    // Screen 5: Model sheet open
    await evalCode('window.__layers.go("chat"); openLayer(document.getElementById("shModel"));');
    await sleep(500);
    await takeScreenshot('assets/screenshots/05_model_sheet.png');

    console.log('All screenshots captured successfully!');
    ws.close();
  } finally {
    chrome.kill();
  }
}

capture().catch(err => {
  console.error(err);
  process.exit(1);
});
