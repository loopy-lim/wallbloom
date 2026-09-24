import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import "./styles.css";

type WallPackage = { id: string; title: string; path: string; previewPath: string | null };
const grid = document.querySelector<HTMLElement>("#grid")!;
const status = document.querySelector<HTMLElement>("#status")!;
const count = document.querySelector<HTMLElement>("#count")!;

async function scan() {
  status.textContent = "라이브러리를 스캔하는 중…";
  try {
    const packages = await invoke<WallPackage[]>("scan_library");
    grid.replaceChildren(...packages.map(renderPackage));
    count.textContent = `${packages.length}개`;
    status.textContent = packages.length ? "라이브러리를 불러왔습니다." : "라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.";
  } catch (error) {
    count.textContent = "";
    grid.replaceChildren();
    status.textContent = `라이브러리 스캔 실패: ${String(error)}`;
  }
}

function renderPackage(item: WallPackage): HTMLElement {
  const card = document.createElement("button");
  card.className = "card";
  card.type = "button";
  card.setAttribute("aria-label", `${item.title} 배경화면 선택`);
  if (item.previewPath) {
    const image = document.createElement("img");
    image.alt = "";
    image.src = convertFileSrc(item.previewPath);
    image.addEventListener("error", () => {
      const placeholder = document.createElement("div");
      placeholder.className = "card-placeholder";
      placeholder.setAttribute("aria-hidden", "true");
      image.replaceWith(placeholder);
    }, { once: true });
    card.append(image);
  } else {
    const placeholder = document.createElement("div");
    placeholder.className = "card-placeholder";
    placeholder.setAttribute("aria-hidden", "true");
    card.append(placeholder);
  }
  const title = document.createElement("span");
  title.className = "card-title";
  title.textContent = item.title;
  card.append(title);
  card.addEventListener("click", async () => {
    status.textContent = `${item.title} 선택 중…`;
    try {
      await invoke("select_wallpaper", { id: item.id });
      status.textContent = `${item.title}을(를) 선택했습니다.`;
    } catch (error) {
      status.textContent = `선택 실패: ${String(error)}`;
    }
  });
  return card;
}

document.querySelector("#refresh")?.addEventListener("click", () => void scan());
const downloadButton = document.querySelector<HTMLButtonElement>("#download-button")!;
downloadButton.addEventListener("click", async () => {
  const input = document.querySelector<HTMLInputElement>("#download-url")!;
  if (!input.value) return;
  downloadButton.disabled = true;
  let unlisten: (() => void) | undefined;
  try {
    unlisten = await listen<{ receivedBytes: number; totalBytes: number | null }>("download-progress", ({ payload }) => {
      const received = (payload.receivedBytes / 1024 / 1024).toFixed(1);
      const total = payload.totalBytes ? ` / ${(payload.totalBytes / 1024 / 1024).toFixed(1)} MB` : "";
      status.textContent = `다운로드 중: ${received} MB${total}`;
    });
    const id = await invoke<string>("download_wallpaper", { url: input.value });
    status.textContent = "다운로드 완료";
    input.value = "";
    await scan();
    status.textContent = `${id} 다운로드 완료`;
  } catch (error) {
    status.textContent = `다운로드 실패: ${String(error)}`;
  } finally {
    unlisten?.();
    downloadButton.disabled = false;
  }
});
void scan();
