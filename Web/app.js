const MAX_BYTES = 100000;
const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;

const textEl = document.getElementById("text");
const byteCountEl = document.getElementById("byte-count");
const warnEl = document.getElementById("warn");
const filesEl = document.getElementById("files");
const fileListEl = document.getElementById("file-list");
const sendBtn = document.getElementById("send");
const statusEl = document.getElementById("status");

function utf8Bytes(str) {
  return new TextEncoder().encode(str).length;
}

function chosenFiles() {
  return Array.from(filesEl.files || []);
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function setStatus(message) {
  statusEl.hidden = !message;
  statusEl.textContent = message || "";
}

function update() {
  const text = textEl.value;
  const bytes = utf8Bytes(text);
  const files = chosenFiles();
  const uploadBytes = files.reduce((total, file) => total + file.size, 0);

  byteCountEl.textContent = `${bytes} / ${MAX_BYTES}`;

  if (files.length === 1) {
    fileListEl.textContent = `${files[0].name} (${formatSize(uploadBytes)})`;
  } else if (files.length > 1) {
    fileListEl.textContent = `${files.length} files (${formatSize(uploadBytes)})`;
  }
  fileListEl.hidden = files.length === 0;

  const textOver = bytes > MAX_BYTES;
  const uploadOver = uploadBytes > MAX_UPLOAD_BYTES;
  warnEl.hidden = !textOver && !uploadOver;
  warnEl.textContent = uploadOver
    ? "Too large to send in one go."
    : textOver
      ? "Too long to send in one go."
      : "";

  sendBtn.disabled = files.length
    ? uploadOver
    : textOver || text.trim().length === 0;

  return { bytes, files, uploadBytes, textOver, uploadOver };
}

async function sendText() {
  const text = textEl.value;
  setStatus("Sending…");

  const res = await fetch("/send", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.ok) {
    throw new Error(data.error || `Send failed (${res.status})`);
  }
  setStatus("Copied on your Mac.");
}

function uploadFiles(files) {
  return new Promise((resolve, reject) => {
    const form = new FormData();
    files.forEach((file) => form.append("files", file, file.name));

    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/upload");

    xhr.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      const percent = Math.round((event.loaded / event.total) * 100);
      setStatus(`Sending ${percent}%`);
    };

    xhr.onload = () => {
      let data = {};
      try {
        data = JSON.parse(xhr.responseText);
      } catch (err) {
        data = {};
      }
      if (xhr.status !== 200 || !data.ok) {
        reject(new Error(errorMessage(data.error, xhr.status)));
        return;
      }
      const saved = data.saved || [];
      setStatus(
        saved.length === 1
          ? `Saved ${saved[0]} on your Mac.`
          : `Saved ${saved.length} files on your Mac.`,
      );
      resolve();
    };

    xhr.onerror = () => reject(new Error("Upload failed. Same Wi-Fi?"));
    xhr.send(form);
  });
}

function errorMessage(code, status) {
  if (code === "too_large") return "Too large to send in one go.";
  if (code === "write_failed") return "The Mac could not save it. Allow Downloads access.";
  if (code === "empty") return "Nothing to send.";
  return `Send failed (${status})`;
}

async function send() {
  const { files, textOver, uploadOver } = update();
  if (textOver || uploadOver) return;
  if (!files.length && textEl.value.trim().length === 0) return;

  sendBtn.disabled = true;
  try {
    if (files.length) {
      await uploadFiles(files);
      filesEl.value = "";
    } else {
      await sendText();
    }
  } catch (err) {
    setStatus(err.message || String(err));
  } finally {
    update();
  }
}

textEl.addEventListener("input", update);
textEl.addEventListener("change", update);
textEl.addEventListener("paste", () => setTimeout(update, 0));
filesEl.addEventListener("change", update);
sendBtn.addEventListener("click", send);

update();
