import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import App from "./App";

const { invokeMock, listenMock, unlistenMock } = vi.hoisted(() => ({
  invokeMock: vi.fn(), listenMock: vi.fn(), unlistenMock: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock, convertFileSrc: (path: string) => path }));
vi.mock("@tauri-apps/api/event", () => ({ listen: listenMock }));

beforeEach(() => {
  invokeMock.mockImplementation((command: string) => {
    if (command === "read_active") return Promise.resolve({ active: null, paused: false, gravity: null });
    return Promise.resolve([]);
  });
});
afterEach(() => { cleanup(); vi.clearAllMocks(); });

describe("Wallbloom library", () => {
  it("scans through the generated rustra transport and shows local library information", async () => {
    invokeMock.mockResolvedValueOnce([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null }]);
    render(<App />);
    expect(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" })).toBeInTheDocument();
    expect(invokeMock).toHaveBeenCalledWith("rustra_dispatch", { command: "scanLibrary", args: {} });
    expect(screen.getByRole("region", { name: "로컬 라이브러리 정보" })).toHaveTextContent("미리보기 없는 항목: 1개");
  });

  it("labels web packages and offers archive import plus interaction guidance", async () => {
    invokeMock.mockResolvedValueOnce([{ id: "web-demo", title: "Web Demo", path: "/web-demo", previewPath: null, packageType: "web" }]);
    render(<App />);
    expect(await screen.findByText("WEB · 마우스 반응형")).toBeInTheDocument();
    expect(screen.getByText(/Web 배경화면 상호작용/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "wallpkg 가져오기" })).toBeInTheDocument();
  });

  it("renders packages and selects a chosen wallpaper", async () => {
    invokeMock.mockResolvedValueOnce([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null }]);
    render(<App />);
    expect(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Ocean Waves 배경화면 선택" }));
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("select_wallpaper", { id: "waves" }));
    expect(await screen.findByRole("status")).toHaveTextContent("선택했습니다");
  });

  it("supports keyboard selection and refresh", async () => {
    let scanResult: Array<Record<string, unknown>> = [];
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve(scanResult);
      if (command === "read_active") return Promise.resolve({ active: null, paused: false, gravity: null });
      return Promise.resolve();
    });
    render(<App />);
    await screen.findByText("라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.");
    await userEvent.tab();
    expect(screen.getByRole("button", { name: "Web 데모 설치" })).toHaveFocus();
    await userEvent.tab();
    expect(screen.getByRole("button", { name: "wallpkg 가져오기" })).toHaveFocus();
    await userEvent.tab();
    expect(screen.getByRole("button", { name: "라이브러리 새로고침" })).toHaveFocus();
    expect(screen.getByRole("button", { name: "라이브러리 새로고침" })).toHaveFocus();
    scanResult = [{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null, packageType: "video", gravity: "cover" }];
    await userEvent.keyboard("{Enter}");
    expect(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" })).toBeInTheDocument();
    const card = screen.getByRole("button", { name: "Ocean Waves 배경화면 선택" });
    for (let i = 0; i < 10 && document.activeElement !== card; i++) await userEvent.tab();
    expect(card).toHaveFocus();
    await userEvent.keyboard("{Enter}");
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("select_wallpaper", { id: "waves" }));
  });

  it("reports selection failures without losing the library", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null, packageType: "video", gravity: "cover" }]);
      if (command === "read_active") return Promise.resolve({ active: null, paused: false, gravity: null });
      if (command === "select_wallpaper") return Promise.reject("package disappeared");
      return Promise.resolve();
    });
    render(<App />);
    await userEvent.click(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" }));
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("선택 실패: package disappeared"));
    expect(screen.getByRole("button", { name: "Ocean Waves 배경화면 선택" })).toBeInTheDocument();
  });

  it("downloads, rescans, and removes the progress listener", async () => {
    let finishDownload!: (id: string) => void;
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve([]);
      if (command === "download_wallpaper") return new Promise<string>(resolve => { finishDownload = resolve; });
      if (command === "select_wallpaper") return Promise.resolve();
      return Promise.resolve();
    });
    let onProgress: ((event: { payload: { receivedBytes: number; totalBytes: number } }) => void) | undefined;
    listenMock.mockImplementation(async (_name, listener) => { onProgress = listener; return unlistenMock; });
    render(<App />);
    await screen.findByText("라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.");
    await userEvent.type(screen.getByLabelText("동영상 URL"), "https://example.com/wall.mp4");
    await userEvent.click(screen.getByRole("button", { name: "다운로드" }));
    await waitFor(() => expect(finishDownload).toBeTypeOf("function"));
    onProgress?.({ payload: { receivedBytes: 1048576, totalBytes: 2097152 } });
    expect(await screen.findByRole("status")).toHaveTextContent("다운로드 중: 1.0 MB / 2.0 MB");
    finishDownload("new-wall");
    expect(await screen.findByRole("status")).toHaveTextContent("new-wall 다운로드 완료");
    expect(listenMock).toHaveBeenCalledWith("rustra://download-progress", expect.any(Function));
    expect(unlistenMock).toHaveBeenCalledOnce();
  });

  it("reports download failures and still removes the listener", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve([]);
      if (command === "read_active") return Promise.resolve({ active: null, paused: false, gravity: null });
      if (command === "download_wallpaper") return Promise.reject("network unavailable");
      return Promise.resolve();
    });
    listenMock.mockResolvedValue(unlistenMock);
    render(<App />);
    await screen.findByText("라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.");
    await userEvent.type(screen.getByLabelText("동영상 URL"), "https://example.com/fail.mp4");
    await userEvent.click(screen.getByRole("button", { name: "다운로드" }));
    expect(await screen.findByRole("status")).toHaveTextContent("다운로드 실패: network unavailable");
    expect(unlistenMock).toHaveBeenCalledOnce();
    expect(screen.getByRole("button", { name: "다운로드" })).toBeEnabled();
  });

  it("shows the selected package gravity mode and switches it through set_wallpaper_gravity", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null, packageType: "video", gravity: "contain" }]);
      if (command === "read_active") return Promise.resolve({ active: null, paused: false, gravity: null });
      if (command === "set_wallpaper_gravity") return Promise.resolve(null);
      return Promise.resolve();
    });
    render(<App />);
    await userEvent.click(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" }));
    const group = await screen.findByRole("group", { name: "화면 맞춤 모드" });
    expect(group).toBeInTheDocument();
    expect(within(group).getByRole("button", { name: "전체 보기 (contain)" })).toHaveAttribute("aria-pressed", "true");
    expect(within(group).getByRole("button", { name: "화면 채움 (cover)" })).toHaveAttribute("aria-pressed", "false");
    await userEvent.click(within(group).getByRole("button", { name: "늘리기 (stretch)" }));
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("set_wallpaper_gravity", { id: "waves", gravity: "stretch" }));
    expect(await screen.findByRole("status")).toHaveTextContent("화면 맞춤을 늘리기 (stretch)(으)로 바꿨습니다.");
    expect(within(group).getByRole("button", { name: "늘리기 (stretch)" })).toHaveAttribute("aria-pressed", "true");
    expect(within(group).getByRole("button", { name: "전체 보기 (contain)" })).toHaveAttribute("aria-pressed", "false");
  });

  it("prefers the persisted active.json gravity override over the package default", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null, packageType: "video", gravity: "contain" }]);
      if (command === "read_active") return Promise.resolve({ active: "/waves", paused: false, gravity: "stretch" });
      return Promise.resolve();
    });
    render(<App />);
    await userEvent.click(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" }));
    const group = await screen.findByRole("group", { name: "화면 맞춤 모드" });
    expect(within(group).getByRole("button", { name: "늘리기 (stretch)" })).toHaveAttribute("aria-pressed", "true");
  });

  it("falls back to cover for unknown gravity values and resets the override on reselection", async () => {
    let persisted: { active: string | null; paused: boolean; gravity: string | null } = { active: "/waves", paused: false, gravity: "diagonal" };
    invokeMock.mockImplementation((command: string) => {
      if (command === "rustra_dispatch") return Promise.resolve([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null, packageType: "video", gravity: "diagonal" }]);
      if (command === "read_active") return Promise.resolve(persisted);
      if (command === "select_wallpaper") return Promise.resolve();
      return Promise.resolve();
    });
    render(<App />);
    await userEvent.click(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" }));
    const group = await screen.findByRole("group", { name: "화면 맞춤 모드" });
    expect(within(group).getByRole("button", { name: "화면 채움 (cover)" })).toHaveAttribute("aria-pressed", "true");
    persisted = { active: null, paused: false, gravity: null };
    await userEvent.click(screen.getByRole("button", { name: "Ocean Waves 배경화면 선택" }));
    expect(await screen.findByRole("status")).toHaveTextContent("선택했습니다");
    expect(within(group).getByRole("button", { name: "화면 채움 (cover)" })).toHaveAttribute("aria-pressed", "true");
  });
});
