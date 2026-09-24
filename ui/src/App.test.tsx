import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import App from "./App";

const { invokeMock, listenMock, unlistenMock } = vi.hoisted(() => ({
  invokeMock: vi.fn(), listenMock: vi.fn(), unlistenMock: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock, convertFileSrc: (path: string) => path }));
vi.mock("@tauri-apps/api/event", () => ({ listen: listenMock }));

beforeEach(() => { invokeMock.mockResolvedValue([]); });
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
    invokeMock.mockResolvedValueOnce([]).mockResolvedValueOnce([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null }]);
    render(<App />);
    await screen.findByText("라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.");
    await userEvent.tab();
    expect(screen.getByRole("button", { name: "Web 데모 설치" })).toHaveFocus();
    await userEvent.tab();
    expect(screen.getByRole("button", { name: "wallpkg 가져오기" })).toHaveFocus();
    await userEvent.tab();
    expect(screen.getByRole("button", { name: "라이브러리 새로고침" })).toHaveFocus();
    await userEvent.keyboard("{Enter}");
    expect(await screen.findByRole("button", { name: "Ocean Waves 배경화면 선택" })).toBeInTheDocument();
    const card = screen.getByRole("button", { name: "Ocean Waves 배경화면 선택" });
    for (let i = 0; i < 10 && document.activeElement !== card; i++) await userEvent.tab();
    expect(card).toHaveFocus();
    await userEvent.keyboard("{Enter}");
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("select_wallpaper", { id: "waves" }));
  });

  it("reports selection failures without losing the library", async () => {
    invokeMock.mockResolvedValueOnce([{ id: "waves", title: "Ocean Waves", path: "/waves", previewPath: null }]).mockRejectedValueOnce("package disappeared");
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
    invokeMock.mockResolvedValueOnce([]).mockRejectedValueOnce("network unavailable");
    listenMock.mockResolvedValue(unlistenMock);
    render(<App />);
    await screen.findByText("라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.");
    await userEvent.type(screen.getByLabelText("동영상 URL"), "https://example.com/fail.mp4");
    await userEvent.click(screen.getByRole("button", { name: "다운로드" }));
    expect(await screen.findByRole("status")).toHaveTextContent("다운로드 실패: network unavailable");
    expect(unlistenMock).toHaveBeenCalledOnce();
    expect(screen.getByRole("button", { name: "다운로드" })).toBeEnabled();
  });
});
