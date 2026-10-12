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
      } catch (e) {}
    };
    ws.on('message', handler);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function recordFrames() {
  const chromePath = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  const port = 9334;
  const targetUrl = 'file:///' + path.resolve('prototype/showcase.html').replace(/\\/g, '/');

  console.log('Launching headless Chrome on port', port);
  const chrome = spawn(chromePath, [
    '--headless=new',
    `--remote-debugging-port=${port}`,
    '--window-size=600,1000',
    '--hide-scrollbars',
    '--force-device-scale-factor=1',
    targetUrl
  ]);

  await sleep(2000);

  try {
    const targets = await new Promise((resolve, reject) => {
      http.get(`http://127.0.0.1:${port}/json`, res => {
        let body = '';
        res.on('data', d => body += d);
        res.on('end', () => resolve(JSON.parse(body)));
      }).on('error', reject);
    });

    const pageTarget = targets.find(t => t.type === 'page') || targets[0];
    const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
    await new Promise(res => ws.on('open', res));

    let cmdId = 1;
    async function evalCode(code) {
      return await sendCDP(ws, ++cmdId, 'Runtime.evaluate', {
        expression: code,
        returnByValue: true,
        awaitPromise: true
      });
    }

    let frameCount = 0;
    async function captureFrame() {
      const res = await sendCDP(ws, ++cmdId, 'Page.captureScreenshot', {
        format: 'png',
        clip: {
          x: 96,
          y: 30,
          width: 390,
          height: 844,
          scale: 1
        }
      });
      const num = String(frameCount++).padStart(4, '0');
      const filename = path.join('assets', 'frames', `frame_${num}.png`);
      fs.writeFileSync(filename, Buffer.from(res.data, 'base64'));
    }

    console.log('Starting demo storyboard recording...');

    // Helper to repeat current state for N frames (at 10 fps, 10 frames = 1s)
    async function hold(frames) {
      for (let i = 0; i < frames; i++) {
        await captureFrame();
      }
    }

    // SCENE 1: Pantalla Sesiones
    await evalCode('window.__layers.go("sessions")');
    await sleep(200);
    console.log('Scene: Sesiones');
    await hold(12); // 1.2s

    // Click into Chat
    await evalCode('window.__layers.go("chat")');
    await sleep(200);
    console.log('Scene: Chat');
    await hold(10); // 1.0s

    // Tool expand / toggle
    await evalCode('const box = document.querySelector(".actbox"); if (box) box.classList.toggle("collapsed");');
    await sleep(200);
    console.log('Scene: Chat - Tool activity toggle');
    await hold(8); // 0.8s

    // Open model selector sheet
    await evalCode('openLayer(document.getElementById("shModel"))');
    await sleep(250);
    console.log('Scene: Model selector sheet');
    await hold(12); // 1.2s

    // Close model sheet
    await evalCode('closeLayer(document.getElementById("shModel"))');
    await sleep(250);
    console.log('Scene: Chat resume');
    await hold(6);

    // SCENE 3: Archivos
    await evalCode('window.__layers.go("files")');
    await sleep(200);
    console.log('Scene: Archivos');
    await hold(12); // 1.2s

    // SCENE 4: Ajustes
    await evalCode('window.__layers.go("settings")');
    await sleep(200);
    console.log('Scene: Ajustes');
    await hold(12); // 1.2s

    // Toggle a setting switch for realism
    await evalCode('const sw = document.querySelector("[role=switch]"); if (sw) sw.click();');
    await sleep(200);
    console.log('Scene: Ajustes - Toggle');
    await hold(8);

    // Back to Sesiones
    await evalCode('window.__layers.go("sessions")');
    await sleep(200);
    console.log('Scene: Back to Sesiones');
    await hold(8);

    console.log(`Finished recording ${frameCount} frames!`);
    ws.close();
  } finally {
    chrome.kill();
  }
}

recordFrames().catch(err => {
  console.error(err);
  process.exit(1);
});
