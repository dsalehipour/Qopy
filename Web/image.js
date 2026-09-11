const titleEl = document.getElementById("title");
const galleryEl = document.getElementById("gallery");
const downloadAllEl = document.getElementById("download-all");
const statusEl = document.getElementById("image-status");
const helpEl = document.getElementById("image-help");

// The transfer ID is already in the path, so every request stays scoped to it.
const base = location.pathname.replace(/\/$/, "");

const UNAVAILABLE =
  "Images unavailable. Reopen the send panel on your Mac and scan the new QR on the same Wi-Fi.";

function setStatus(message) {
  statusEl.textContent = message;
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function card(item) {
  const figure = document.createElement("figure");
  figure.className = "shot";

  const img = document.createElement("img");
  img.className = "received-image";
  img.src = item.url;
  img.alt = item.name;
  img.loading = "lazy";

  const meta = document.createElement("figcaption");
  meta.className = "shot-meta";
  const name = document.createElement("span");
  name.className = "shot-name";
  // Wraps rather than truncates: the filename is how you tell these apart now.
  name.textContent = item.name;
  const size = document.createElement("span");
  size.className = "shot-size";
  size.textContent = formatSize(item.size);
  meta.append(name, size);

  const save = document.createElement("a");
  save.className = "primary";
  save.href = item.url;
  save.download = item.name;
  save.textContent = "Save";

  img.addEventListener("error", () => {
    figure.replaceChildren(meta);
    setStatus(UNAVAILABLE);
  });

  figure.append(img, meta, save);
  return figure;
}

function triggerDownload(item) {
  const link = document.createElement("a");
  link.href = item.url;
  link.download = item.name;
  link.rel = "noopener";
  document.body.append(link);
  link.click();
  link.remove();
}

async function downloadAll(items) {
  downloadAllEl.disabled = true;
  for (const [index, item] of items.entries()) {
    setStatus(`Saving ${index + 1} of ${items.length}…`);
    triggerDownload(item);
    // Browsers drop downloads fired in one burst, and ask permission the first
    // time a page saves more than one file. Spacing them out keeps all of them.
    await delay(700);
  }
  setStatus(`Saved ${items.length} images. Check your downloads.`);
  downloadAllEl.disabled = false;
}

function render(items) {
  const one = items.length === 1;
  titleEl.textContent = one ? "Image from Mac" : `${items.length} images from Mac`;
  document.title = `${one ? "Image" : "Images"} from Mac · Qopy`;

  galleryEl.replaceChildren(...items.map(card));

  downloadAllEl.hidden = one;
  if (!one) {
    downloadAllEl.textContent = `Download all ${items.length}`;
    downloadAllEl.addEventListener("click", () => downloadAll(items));
    helpEl.textContent =
      "If your browser asks whether to allow multiple downloads, say yes. Keep Qopy’s send panel open on your Mac until you have saved them.";
  }

  setStatus(one ? "Ready to save on your phone." : "Save them one by one, or all at once.");
}

async function load() {
  try {
    const response = await fetch(`${base}/items.json`);
    if (!response.ok) throw new Error(`items ${response.status}`);
    const items = await response.json();
    if (!Array.isArray(items) || items.length === 0) {
      setStatus(UNAVAILABLE);
      return;
    }
    render(items);
  } catch (error) {
    setStatus(UNAVAILABLE);
  }
}

load();
