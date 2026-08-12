const MAX_BYTES = 100000;

const textEl = document.getElementById("text");
const byteCountEl = document.getElementById("byte-count");
const warnEl = document.getElementById("warn");
const sendBtn = document.getElementById("send");
const statusEl = document.getElementById("status");

function utf8Bytes(str) {
  return new TextEncoder().encode(str).length;
}

function updateMeter() {
  const text = textEl.value;
  const bytes = utf8Bytes(text);
  byteCountEl.textContent = `${bytes} / ${MAX_BYTES}`;
  const over = bytes > MAX_BYTES;
  const empty = text.trim().length === 0;
  warnEl.hidden = !over;
  warnEl.textContent = over ? "Too long to send in one go." : "";
  sendBtn.disabled = over || empty;
  return { bytes, over, empty };
}

async function sendToMac() {
  const text = textEl.value;
  const { over, empty } = updateMeter();
  if (over || empty) return;

  sendBtn.disabled = true;
  statusEl.hidden = false;
  statusEl.textContent = "Sending…";

  try {
    const res = await fetch("/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) {
      throw new Error(data.error || `Send failed (${res.status})`);
    }
    statusEl.textContent = "Copied on your Mac.";
  } catch (err) {
    statusEl.textContent = err.message || String(err);
    sendBtn.disabled = false;
  }
}

textEl.addEventListener("input", updateMeter);
textEl.addEventListener("change", updateMeter);
textEl.addEventListener("paste", () => setTimeout(updateMeter, 0));
sendBtn.addEventListener("click", sendToMac);

updateMeter();
