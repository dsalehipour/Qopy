const imageEl = document.getElementById("received-image");
const saveEl = document.getElementById("save-image");
const shareEl = document.getElementById("share-image");
const imageStatusEl = document.getElementById("image-status");
const imageURL = `${location.pathname.replace(/\/$/, "")}/image.png`;

imageEl.onload = () => {
  saveEl.hidden = false;
  imageStatusEl.textContent = "Ready to save on your phone.";
};
imageEl.onerror = () => {
  saveEl.hidden = true;
  shareEl.hidden = true;
  imageStatusEl.textContent = "Image unavailable. Reopen Send Clipboard to Phone on your Mac and scan the new QR on the same Wi-Fi.";
};
saveEl.href = imageURL;
imageEl.src = imageURL;

// Web Share is available only in supporting secure browser contexts. LAN HTTP
// always has a download link and the browser's touch-and-hold image menu.
if (window.isSecureContext && navigator.canShare) {
  fetch(imageURL).then(async response => {
    if (!response.ok) return;
    const file = new File([await response.blob()], "qopy-image.png", { type: "image/png" });
    if (!navigator.canShare({ files: [file] })) return;
    shareEl.hidden = false;
    shareEl.onclick = async () => {
      try { await navigator.share({ files: [file] }); }
      catch (error) {
        if (error.name !== "AbortError") imageStatusEl.textContent = "Sharing failed. Use Save image instead.";
      }
    };
  }).catch(() => {});
}
