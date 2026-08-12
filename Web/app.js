const MAX_BYTES = 1200;

const textEl = document.getElementById("text");
const byteCountEl = document.getElementById("byte-count");
const warnEl = document.getElementById("warn");
const qrWrap = document.getElementById("qr-wrap");
const emptyHint = document.getElementById("empty-hint");
const qrCanvas = document.getElementById("qr");

let renderTimer = null;

function utf8Bytes(str) {
  return new TextEncoder().encode(str).length;
}

function updateMeter() {
  const bytes = utf8Bytes(textEl.value);
  byteCountEl.textContent = `${bytes} / ${MAX_BYTES}`;
  const over = bytes > MAX_BYTES;
  warnEl.hidden = !over;
  warnEl.textContent = over
    ? "Too long for one QR — shorten it for now."
    : "";
  return { bytes, over };
}

async function renderQR() {
  const text = textEl.value;
  const { bytes, over } = updateMeter();

  if (!text || over) {
    qrWrap.hidden = true;
    emptyHint.hidden = !!text && over ? true : !text ? false : true;
    if (!text) emptyHint.hidden = false;
    if (over) emptyHint.hidden = true;
    return;
  }

  if (typeof QRCode === "undefined") {
    warnEl.hidden = false;
    warnEl.textContent = "QR library failed to load.";
    return;
  }

  // Raw text — Mac Vision / Android Camera both handle this cleanly.
  await QRCode.toCanvas(qrCanvas, text, {
    width: 280,
    margin: 1,
    errorCorrectionLevel: "M",
    color: { dark: "#111111", light: "#ffffff" },
  });

  qrWrap.hidden = false;
  emptyHint.hidden = true;
}

function scheduleRender() {
  updateMeter();
  clearTimeout(renderTimer);
  renderTimer = setTimeout(() => {
    renderQR().catch((err) => {
      warnEl.hidden = false;
      warnEl.textContent = err.message || String(err);
    });
  }, 120);
}

textEl.addEventListener("input", scheduleRender);
textEl.addEventListener("change", scheduleRender);
textEl.addEventListener("paste", () => setTimeout(scheduleRender, 0));
textEl.addEventListener("keyup", scheduleRender);

// If scripts load after autofill, render once ready.
window.addEventListener("load", scheduleRender);
if (document.readyState !== "loading") scheduleRender();

updateMeter();
