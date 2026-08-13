const MAX_BYTES = 100000;
const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;

const textBlockEl = document.getElementById("text-block");
const textEl = document.getElementById("text");
const byteCountEl = document.getElementById("byte-count");
const warnEl = document.getElementById("warn");
const filesEl = document.getElementById("files");
const pickerEl = document.getElementById("picker");
const pickerLabelEl = document.getElementById("picker-label");
const selectionEl = document.getElementById("selection");
const thumbsEl = document.getElementById("thumbs");
const selectionTitleEl = document.getElementById("selection-title");
const selectionSubEl = document.getElementById("selection-sub");
const clearBtn = document.getElementById("clear");
const sendBtn = document.getElementById("send");
const statusEl = document.getElementById("status");

const DOC_GLYPH = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
  stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>`;

let thumbURLs = [];

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

function isImage(file) {
  return (file.type || "").startsWith("image/");
}

function noun(files) {
  const word = files.every(isImage) ? "photo" : "file";
  return files.length === 1 ? word : `${files.length} ${word}s`;
}

function renderSelection(files, uploadBytes, uploadOver) {
  thumbURLs.forEach(URL.revokeObjectURL);
  thumbURLs = [];
  thumbsEl.replaceChildren();

  selectionEl.hidden = files.length === 0;
  pickerEl.classList.toggle("compact", files.length > 0);
  pickerLabelEl.textContent = files.length ? "Choose different files" : "Choose photos or files";
  textBlockEl.classList.toggle("standby", files.length > 0 && textEl.value.trim().length > 0);
  if (!files.length) return;

  // At most two boxes wide: past two files it becomes one preview and a count,
  // otherwise the stack eats the width the filename and size need.
  const shown = files.length > 2 ? 1 : files.length;
  files.slice(0, shown).forEach((file) => {
    if (isImage(file)) {
      const url = URL.createObjectURL(file);
      thumbURLs.push(url);
      const img = document.createElement("img");
      img.className = "thumb";
      img.src = url;
      img.alt = "";
      // HEIC and friends may not decode in every browser; fall back to the glyph.
      img.addEventListener("error", () => img.replaceWith(glyphThumb()));
      thumbsEl.append(img);
    } else {
      thumbsEl.append(glyphThumb());
    }
  });

  if (files.length > shown) {
    const more = document.createElement("div");
    more.className = "thumb more";
    more.textContent = `+${files.length - shown}`;
    thumbsEl.append(more);
  }

  selectionTitleEl.textContent = files.length === 1 ? files[0].name : noun(files);
  // Readiness first: on a narrow phone the size is what gets ellipsized, not the verdict.
  selectionSubEl.textContent = uploadOver
    ? `Too large · ${formatSize(uploadBytes)}`
    : `Ready to send · ${formatSize(uploadBytes)}`;
}

function glyphThumb() {
  const box = document.createElement("div");
  box.className = "thumb glyph";
  box.innerHTML = DOC_GLYPH;
  return box;
}

function update() {
  const text = textEl.value;
  const bytes = utf8Bytes(text);
  const files = chosenFiles();
  const uploadBytes = files.reduce((total, file) => total + file.size, 0);

  byteCountEl.textContent = `${bytes} / ${MAX_BYTES}`;

  const textOver = bytes > MAX_BYTES;
  const uploadOver = uploadBytes > MAX_UPLOAD_BYTES;
  warnEl.hidden = !textOver;
  warnEl.textContent = textOver ? "Too long to send in one go." : "";

  renderSelection(files, uploadBytes, uploadOver);

  sendBtn.textContent = files.length ? `Send ${noun(files)} to Mac` : "Send to Mac";
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
filesEl.addEventListener("change", () => {
  setStatus("");
  update();
});
clearBtn.addEventListener("click", () => {
  filesEl.value = "";
  setStatus("");
  update();
});
sendBtn.addEventListener("click", send);

update();
