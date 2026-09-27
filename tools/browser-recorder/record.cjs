#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const puppeteer = require('puppeteer-core');

const recordingId = process.env.RECORDING_ID || new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
const fileName = `browser-recording-${recordingId}.jsonl`;
const outputDir = path.resolve(process.env.RECORDING_OUTPUT_DIR || process.cwd());
const outputPath = path.join(outputDir, fileName);
const captureRequestBodies = process.env.CAPTURE_REQUEST_BODIES !== 'false';
const captureResponseBodies = process.env.CAPTURE_RESPONSE_BODIES !== 'false';
const captureFormValues = process.env.CAPTURE_FORM_VALUES !== 'false';
const captureClipboard = process.env.CAPTURE_CLIPBOARD !== 'false';
const captureFileContents = process.env.CAPTURE_FILE_CONTENTS !== 'false';
const captureHighFrequencyEvents = process.env.CAPTURE_HIGH_FREQUENCY_EVENTS === 'true';
const domSnapshots = process.env.DOM_SNAPSHOTS || 'none';
if (!['none', 'actions', 'all'].includes(domSnapshots)) {
  throw new Error('DOM_SNAPSHOTS must be none, actions, or all');
}
const captureOptions = {domSnapshots, captureFormValues, captureClipboard, captureFileContents, captureHighFrequencyEvents};
fs.mkdirSync(outputDir, {recursive: true, mode: 0o700});
const output = fs.createWriteStream(outputPath, {flags: 'wx', mode: 0o600});
const activePages = new WeakSet();
let nextPageId = 1;
let stopping = false;

function record(event) {
  const line = `${JSON.stringify({at: new Date().toISOString(), ...event})}\n`;
  output.write(line);
}

function installInteractionCapture(reportName, options) {
  const installed = window.__codexFullCaptureBindings || (window.__codexFullCaptureBindings = new Set());
  if (installed.has(reportName)) return;
  installed.add(reportName);

  const elementSnapshot = (element, includeDom) => {
    if (!(element instanceof Element)) return element?.nodeName ? {nodeName: element.nodeName} : null;
    const attributes = {};
    for (const attribute of element.attributes) attributes[attribute.name] = attribute.value;
    const snapshot = {
      tag: element.tagName.toLowerCase(),
      attributes,
    };
    if (includeDom) {
      snapshot.outerHTML = element.outerHTML;
      snapshot.textContent = element.textContent;
      snapshot.innerText = element.innerText;
    }
    if (options.captureFormValues && 'value' in element) snapshot.value = element.value;
    if ('checked' in element) snapshot.checked = element.checked;
    if ('selectedIndex' in element) snapshot.selectedIndex = element.selectedIndex;
    if ('selectionStart' in element) {
      try { snapshot.selection = {start: element.selectionStart, end: element.selectionEnd, direction: element.selectionDirection}; } catch {}
    }
    if (options.captureFileContents && element instanceof HTMLInputElement && element.files) {
      snapshot.files = Array.from(element.files, (file) => ({name: file.name, size: file.size, type: file.type, lastModified: file.lastModified}));
    }
    return snapshot;
  };
  const encodeFile = async (file) => {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = '';
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    return {name: file.name, size: file.size, type: file.type, lastModified: file.lastModified, contentBase64: btoa(binary)};
  };
  const emit = (data) => {
    try { window[reportName]({...data, pageUrl: location.href, at: Date.now()}); } catch {}
  };
  const readTransfer = (transfer) => {
    if (!transfer) return undefined;
    const result = {types: Array.from(transfer.types || []), items: Array.from(transfer.items || [], (item) => ({kind: item.kind, type: item.type}))};
    try { result.text = transfer.getData('text/plain'); } catch {}
    try { result.html = transfer.getData('text/html'); } catch {}
    try { result.uriList = transfer.getData('text/uri-list'); } catch {}
    return result;
  };

  const listener = (event) => {
    const target = event.target;
    const interactiveTarget = target instanceof Element
      ? target.closest('a,button,input,textarea,select,[role="button"],[role="link"],[tabindex]')
      : null;
    const snapshotActions = ['click', 'dblclick', 'auxclick', 'contextmenu', 'input', 'beforeinput', 'change', 'submit', 'paste', 'copy', 'cut'];
    const includeTargetDom = options.domSnapshots === 'all'
      || (options.domSnapshots === 'actions' && snapshotActions.includes(event.type) && interactiveTarget);
    const entry = {
      kind: 'interaction',
      action: event.type,
      trusted: event.isTrusted,
      target: elementSnapshot(target, options.domSnapshots === 'all'),
      interactiveTarget: elementSnapshot(interactiveTarget, Boolean(includeTargetDom)),
      path: event.composedPath().map((element) => elementSnapshot(element, options.domSnapshots === 'all')),
      event: {
        bubbles: event.bubbles,
        cancelable: event.cancelable,
        defaultPrevented: event.defaultPrevented,
        timeStamp: event.timeStamp,
        detail: event.detail,
        key: event.key,
        code: event.code,
        location: event.location,
        repeat: event.repeat,
        isComposing: event.isComposing,
        inputType: event.inputType,
        data: event.data,
        inputData: event.data,
        button: event.button,
        buttons: event.buttons,
        clientX: event.clientX,
        clientY: event.clientY,
        screenX: event.screenX,
        screenY: event.screenY,
        pageX: event.pageX,
        pageY: event.pageY,
        movementX: event.movementX,
        movementY: event.movementY,
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        pressure: event.pressure,
        deltaX: event.deltaX,
        deltaY: event.deltaY,
        deltaZ: event.deltaZ,
        deltaMode: event.deltaMode,
        altKey: event.altKey,
        ctrlKey: event.ctrlKey,
        metaKey: event.metaKey,
        shiftKey: event.shiftKey,
        touches: event.touches ? Array.from(event.touches, (touch) => ({identifier: touch.identifier, clientX: touch.clientX, clientY: touch.clientY, pageX: touch.pageX, pageY: touch.pageY, force: touch.force})) : undefined,
      },
    };
    if (options.captureClipboard && event.clipboardData) entry.clipboard = readTransfer(event.clipboardData);
    if (event.dataTransfer) entry.dataTransfer = readTransfer(event.dataTransfer);
    const files = [];
    if (options.captureFileContents && target instanceof HTMLInputElement && target.type === 'file' && target.files) {
      files.push(...target.files);
    }
    if (options.captureFileContents && event.dataTransfer?.files?.length) {
      files.push(...event.dataTransfer.files);
    }
    if (files.length) {
      Promise.all(files.map(encodeFile)).then((fileContents) => {
        entry.fileContents = fileContents;
        emit(entry);
      }).catch((error) => {
        entry.fileReadError = String(error.message || error);
        emit(entry);
      });
    } else {
      emit(entry);
    }
  };
  const eventTypes = [
    'click', 'dblclick', 'auxclick', 'contextmenu',
    'pointerdown', 'pointerup', 'mousedown', 'mouseup',
    'wheel', 'keydown', 'keyup', 'keypress', 'focusin', 'focusout', 'input', 'beforeinput', 'change',
    'compositionstart', 'compositionupdate', 'compositionend', 'submit', 'reset', 'invalid',
    'copy', 'cut', 'paste', 'dragstart', 'drag', 'dragenter', 'dragleave', 'dragover', 'drop', 'dragend',
    'scroll', 'touchstart', 'touchmove', 'touchend', 'touchcancel', 'select', 'selectionchange',
  ];
  if (options.captureHighFrequencyEvents) {
    eventTypes.push('pointermove', 'pointerover', 'pointerout', 'pointerenter', 'pointerleave');
    eventTypes.push('mousemove', 'mouseover', 'mouseout', 'mouseenter', 'mouseleave');
  }
  for (const eventType of eventTypes) document.addEventListener(eventType, listener, true);
}

async function attachPage(page) {
  if (activePages.has(page)) return;
  activePages.add(page);
  const pageId = nextPageId++;
  const reportName = '__codexRecordFullInteraction';
  try {
    await page.exposeFunction(reportName, (event) => {
      const {at, pageUrl, ...details} = event;
      record({kind: 'interaction', pageId, pageUrl, pageEventTime: at, ...details});
    });
    await page.evaluateOnNewDocument(installInteractionCapture, reportName, captureOptions);
    await page.evaluate(installInteractionCapture, reportName, captureOptions).catch(() => {});

    page.on('framenavigated', (frame) => record({kind: 'navigation', pageId, isMainFrame: frame === page.mainFrame(), url: frame.url()}));
    page.on('console', (message) => record({kind: 'console', pageId, type: message.type(), text: message.text(), location: message.location()}));
    page.on('pageerror', (error) => record({kind: 'page_error', pageId, message: String(error.stack || error)}));
    page.on('dialog', (dialog) => record({kind: 'dialog', pageId, type: dialog.type(), message: dialog.message(), defaultValue: dialog.defaultValue()}));

    const cdp = await page.createCDPSession();
    const networkEvents = [
      'requestWillBeSent', 'requestWillBeSentExtraInfo', 'responseReceived', 'responseReceivedExtraInfo',
      'dataReceived', 'loadingFinished', 'loadingFailed', 'webSocketCreated', 'webSocketWillSendHandshakeRequest',
      'webSocketHandshakeResponseReceived', 'webSocketFrameSent', 'webSocketFrameReceived', 'webSocketFrameError',
      'eventSourceMessageReceived', 'webTransportCreated', 'webTransportConnectionEstablished', 'webTransportClosed',
    ];
    for (const name of networkEvents) {
      cdp.on(`Network.${name}`, (event) => {
        const details = {...event};
        if (!captureRequestBodies && details.request) {
          details.request = {...details.request};
          delete details.request.postData;
        }
        record({kind: 'network', event: name, pageId, ...details});
        if (captureRequestBodies && name === 'requestWillBeSent' && event.request.hasPostData && !Object.hasOwn(event.request, 'postData')) {
          cdp.send('Network.getRequestPostData', {requestId: event.requestId})
            .then((data) => record({kind: 'request_body', pageId, requestId: event.requestId, postData: data.postData}))
            .catch((error) => record({kind: 'capture_error', capture: 'request_body', pageId, requestId: event.requestId, message: String(error.message || error)}));
        }
        if (captureResponseBodies && name === 'loadingFinished') {
          cdp.send('Network.getResponseBody', {requestId: event.requestId})
            .then((body) => record({kind: 'response_body', pageId, requestId: event.requestId, body: body.body, base64Encoded: body.base64Encoded}))
            .catch((error) => record({kind: 'capture_error', capture: 'response_body', pageId, requestId: event.requestId, message: String(error.message || error)}));
        }
      });
    }
    await cdp.send('Network.enable', {maxTotalBufferSize: 1000000000, maxResourceBufferSize: 100000000, maxPostDataSize: 100000000});
    await cdp.send('Page.enable');
    record({kind: 'page_attached', pageId, url: page.url()});
  } catch (error) {
    record({kind: 'recorder_error', pageId, message: String(error.stack || error)});
  }
}

(async () => {
  const browser = await puppeteer.connect({
    browserURL: process.env.HOST_BROWSER_URL,
    wsOptions: {headers: {Authorization: `Bearer ${process.env.HOST_BROWSER_TOKEN}`}},
  });
  record({kind: 'full_capture_started', outputPath, captureOptions: {...captureOptions, captureHighFrequencyEvents, captureRequestBodies, captureResponseBodies}, captures: ['network_events_and_headers', 'request_bodies', 'response_bodies', 'cookies', 'DOM_interactions', 'typed_text', 'clipboard_data', 'selected_file_contents', 'console', 'page_errors', 'dialogs']});
  for (const page of await browser.pages()) await attachPage(page);
  browser.on('targetcreated', async (target) => {
    if (target.type() === 'page') {
      const page = await target.page();
      if (page) await attachPage(page);
    }
  });
  console.log(`Full browser capture active: ${outputPath}`);
  console.log('Press Ctrl-C to stop recording.');
  const stop = (reason) => {
    if (stopping) return;
    stopping = true;
    record({kind: 'full_capture_stopped', reason});
    output.end();
    new Promise((resolve) => output.once('close', resolve)).then(() => {
      browser.disconnect();
      process.exit(0);
    });
  };
  process.once('SIGINT', () => stop('SIGINT'));
  process.once('SIGTERM', () => stop('SIGTERM'));
  browser.once('disconnected', () => stop('browser_disconnected'));
})().catch((error) => {
  console.error(`Recorder failed: ${error.message || error}`);
  process.exit(1);
});
