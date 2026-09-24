import { afterEach, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { createParser } from "@openuidev/react-lang";
import { library } from "../lib/library-info";
import { LibraryInfoPanel, libraryInfoProgram } from "./LibraryInfoPanel";

afterEach(cleanup);

it("renders escaped package metadata as text through the real OpenUI renderer", () => {
  const selected = { id: "odd", title: 'Quote ");\nroot = Evil("<script>&한글', path: '/library/"odd"', previewPath: null, packageType: "video", gravity: "cover" };
  const program = libraryInfoProgram([selected], selected);
  const parsed = createParser(library.toJSONSchema(), "LibraryInfo").parse(program);
  expect(parsed.meta.errors).toEqual([]);
  expect(parsed.meta.unresolved).toEqual([]);
  const { container } = render(<LibraryInfoPanel packages={[selected]} selected={selected} />);
  expect(screen.getByText(`마지막 선택: ${selected.title}`, { normalizer: text => text })).toBeInTheDocument();
  expect(screen.getByText(selected.path)).toBeInTheDocument();
  expect(container.querySelector("script")).toBeNull();
});

it("updates local counts on rescan without claiming model generation", () => {
  const { rerender } = render(<LibraryInfoPanel packages={[]} />);
  expect(screen.getByText(/사용 가능한 배경화면/)).toHaveTextContent("0개");
  rerender(<LibraryInfoPanel packages={[{ id: "one", title: "One", path: "/one", previewPath: "/preview.png", packageType: "video", gravity: "cover" }]} />);
  expect(screen.getByText(/사용 가능한 배경화면/)).toHaveTextContent("1개 · 미리보기 없는 항목: 0개");
  expect(screen.getByText(/AI 생성 아님/)).toBeInTheDocument();
});
