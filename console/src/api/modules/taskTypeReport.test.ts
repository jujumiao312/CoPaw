import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import dayjs from "dayjs";
import { request } from "../request";
import {
  canSelectReportDate,
  defaultReportDate,
  EMPTY_DATE_WINDOW,
  exportTaskReport,
  getTaskReportDates,
  latestReportDate,
  getTaskReportOptions,
  getTaskTypeReport,
  reportDateWindow,
  snapshotUnavailable,
} from "./taskTypeReport";
const auth = vi.hoisted(() => ({ bbk: "100" }));
vi.mock("../authHeaders", () => ({
  buildAuthHeaders: () => ({ "X-Bbk-Id": auth.bbk, "X-Source-Id": "RMASSIST" }),
}));
vi.mock("../config", () => ({ getApiUrl: (path: string) => `/api${path}` }));
vi.mock("../request", () => ({ request: vi.fn() }));
const base = {
  start_date: "2026-09-01",
  end_date: "2026-09-14",
  group_by: "manager",
  task_type: "push_plan",
} as const;
beforeEach(() => {
  vi.clearAllMocks();
  auth.bbk = "100";
});
afterEach(() => vi.unstubAllGlobals());
describe("task type report adapter", () => {
  it("rejects a start date that is not the first day of the report month", async () => {
    for (const [start_date, end_date] of [
      ["2026-08-31", "2026-09-01"],
      ["2026-09-15", "2026-09-01"],
      ["2026-09-02", "2026-09-14"],
    ])
      await expect(
        getTaskTypeReport({ ...base, start_date, end_date }),
      ).rejects.toThrow("当月 1 号");
    expect(request).not.toHaveBeenCalled();
  });
  it("caps the selectable report date at T-1", () => {
    expect(latestReportDate().format("YYYY-MM-DD")).toBe(
      dayjs().subtract(1, "day").format("YYYY-MM-DD"),
    );
    expect(latestReportDate().isBefore(dayjs(), "day")).toBe(true);
  });
  it("defaults the report date to the earlier of the latest snapshot date and T-1", () => {
    const latest = dayjs().subtract(1, "day").format("YYYY-MM-DD");
    const ready = dayjs().subtract(3, "day").format("YYYY-MM-DD");
    expect(defaultReportDate(null).format("YYYY-MM-DD")).toBe(latest);
    expect(defaultReportDate(ready).format("YYYY-MM-DD")).toBe(ready);
    expect(
      defaultReportDate(dayjs().add(2, "day").format("YYYY-MM-DD")).format(
        "YYYY-MM-DD",
      ),
    ).toBe(latest);
    expect(defaultReportDate("not-a-date").format("YYYY-MM-DD")).toBe(latest);
  });
  it("reads available run dates from the snapshot endpoint", async () => {
    await getTaskReportDates();
    expect(request).toHaveBeenLastCalledWith(
      "/monitor/report/task-type/dates?limit=90",
      { signal: undefined },
    );
  });
  it("uses returned snapshot dates regardless of compatibility status", () => {
    const at = (offset: number) =>
      dayjs().subtract(offset, "day").format("YYYY-MM-DD");
    const ready = at(3);
    const loading = at(2);
    const failed = at(4);
    const window = reportDateWindow({
      latest_ready_prt_dt: ready,
      items: [
        { prt_dt: loading, status: "loading" },
        { prt_dt: ready, status: "ready" },
        { prt_dt: failed, status: "FAILED" },
      ],
    });

    expect([...window.ready]).toEqual([loading, ready, failed]);
    expect(window.start).toBe(failed);
    expect(canSelectReportDate(dayjs(ready), window)).toBe(true);
    expect(canSelectReportDate(dayjs(loading), window)).toBe(true);
    expect(canSelectReportDate(dayjs(failed), window)).toBe(true);
    expect(canSelectReportDate(dayjs(at(5)), window)).toBe(true);
    expect(canSelectReportDate(dayjs(), window)).toBe(false);
    expect(canSelectReportDate(dayjs(at(-1)), window)).toBe(false);
    expect(canSelectReportDate(dayjs(at(9)), EMPTY_DATE_WINDOW)).toBe(true);
  });
  it("only maps missing snapshots to an empty state", () => {
    const coded = (code: string) => ({ data: { detail: { code } } });
    expect(snapshotUnavailable(coded("report_snapshot_not_found"))).toBe(
      "missing",
    );
    expect(snapshotUnavailable(coded("report_snapshot_not_ready"))).toBeNull();
    expect(snapshotUnavailable(coded("report_scope_forbidden"))).toBeNull();
    expect(snapshotUnavailable(new Error("boom"))).toBeNull();
  });
  it("forwards the effective BBK header and forces local branch scope for report and options", async () => {
    auth.bbk = "110";
    const signal = new AbortController().signal;
    await getTaskTypeReport(
      { ...base, page: 2, page_size: 20, keyword: "张三" },
      signal,
    );
    const [url, options] = vi.mocked(request).mock.calls[0];
    expect(String(url).startsWith("/monitor/report/task-type?")).toBe(true);
    const params = new URL(String(url), "http://localhost").searchParams;
    expect(params.get("first_bbk_id")).toBe("110");
    expect(params.get("page")).toBe("2");
    expect(params.get("keyword")).toBe("张三");
    expect(options).toEqual({ signal, headers: { "X-Bbk-Id": "110" } });
    await getTaskReportOptions({ end_date: base.end_date, kind: "orgs" });
    expect(request).toHaveBeenLastCalledWith(
      expect.stringContaining("/monitor/report/task-type/options?"),
      expect.objectContaining({ headers: { "X-Bbk-Id": "110" } }),
    );
    expect(request).toHaveBeenLastCalledWith(
      expect.stringContaining("first_bbk_id=110"),
      expect.objectContaining({ headers: { "X-Bbk-Id": "110" } }),
    );
    await expect(
      getTaskTypeReport({ ...base, first_bbk_id: "120" }),
    ).rejects.toThrow("当前分行");
    auth.bbk = "";
    await expect(getTaskTypeReport(base)).rejects.toThrow("缺少分行身份");
  });
  it("exports full filters and headers, strips pagination, and rejects non-Excel replies", async () => {
    auth.bbk = "110";
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(new Blob(["xlsx"]), {
        headers: {
          "Content-Type":
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const file = await exportTaskReport({
      ...base,
      page: 3,
      page_size: 20,
      skill_detail: true,
      user_id: "u1",
      org_id: "11001",
    });
    expect(file.size).toBeGreaterThan(0);
    const [url, options] = fetchMock.mock.calls[0];
    const params = new URL(url, "http://localhost").searchParams;
    expect(new URL(url, "http://localhost").pathname).toBe(
      "/api/monitor/report/task-type/export",
    );
    expect(params.has("page")).toBe(false);
    expect(params.has("page_size")).toBe(false);
    expect(params.get("user_id")).toBe("u1");
    expect(params.get("skill_detail")).toBe("true");
    expect(options.headers["X-Bbk-Id"]).toBe("110");
    fetchMock.mockResolvedValue(
      new Response("bad", { headers: { "Content-Type": "text/plain" } }),
    );
    await expect(exportTaskReport(base)).rejects.toThrow("Excel");
  });
});
