import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import dayjs from "dayjs";
import { request } from "../../../api/request";
import ClawSkillDataOverview from "./index";

vi.mock("../../../api/request", () => ({ request: vi.fn() }));
vi.mock("../../../api/authHeaders", () => ({
  buildAuthHeaders: () => ({ "X-Bbk-Id": "100", "X-Source-Id": "RMASSIST" }),
}));

const emptyReport = {
  sync_date: "2026-09-19",
  warnings: [],
  items: [],
  page: null,
  page_size: null,
  total: 0,
  has_more: false,
};

type DatesPayload = {
  latest_ready_prt_dt: string | null;
  items: { prt_dt: string; status: string }[];
};

const emptyDates: DatesPayload = { latest_ready_prt_dt: null, items: [] };

function mockRequests(dates: Partial<DatesPayload> = {}) {
  const payload = { ...emptyDates, ...dates };
  vi.mocked(request).mockImplementation(async (url) =>
    String(url).includes("/task-type/dates") ? payload : emptyReport,
  );
}

function mockMissingBatch(code: string) {
  vi.mocked(request).mockImplementation(async (url) => {
    if (String(url).includes("/task-type/dates")) return emptyDates;
    throw Object.assign(new Error("batch unavailable"), {
      status: code === "report_snapshot_not_found" ? 404 : 409,
      data: { detail: { code, message: "backend message" } },
    });
  });
}

function reportQueries() {
  return vi
    .mocked(request)
    .mock.calls.map(([url]) => new URL(String(url), "http://localhost"))
    .filter((url) => url.pathname === "/monitor/report/task-type");
}

function cellFor(value: string) {
  return Array.from(
    document.querySelectorAll<HTMLElement>(".ant-picker-cell"),
  ).find((cell) => cell.title === value);
}

async function openDatePanel(input: HTMLElement) {
  fireEvent.focus(input);
  fireEvent.mouseDown(input);
  fireEvent.click(input);
  await waitFor(() =>
    expect(document.querySelector(".ant-picker-dropdown")).not.toBeNull(),
  );
}

async function renderPage() {
  const view = render(<ClawSkillDataOverview />);
  await waitFor(() => expect(reportQueries().length).toBeGreaterThan(0));
  return view;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockRequests();
});

afterEach(cleanup);

describe("ClawSkillDataOverview report date filter", () => {
  it("queries the snapshot endpoint with the report date and its month start", async () => {
    await renderPage();

    const latest = dayjs().subtract(1, "day");
    const [query] = reportQueries();
    expect(query.searchParams.get("end_date")).toBe(
      latest.format("YYYY-MM-DD"),
    );
    expect(query.searchParams.get("start_date")).toBe(
      latest.startOf("month").format("YYYY-MM-DD"),
    );
    expect(query.searchParams.get("group_by")).toBe("branch");
    expect(query.searchParams.get("task_type")).toBe("push_plan");
    expect(query.searchParams.has("page")).toBe(false);
  });

  it("uses a single date control and offers no date after T-1", async () => {
    const { container } = await renderPage();
    const latest = dayjs().subtract(1, "day");

    expect(container.querySelector(".ant-picker-range")).toBeNull();
    const input = container.querySelector<HTMLInputElement>(
      ".ant-picker-input input",
    );
    expect(input?.value).toBe(latest.format("YYYY-MM-DD"));

    await openDatePanel(input!);
    const disabled = (value: dayjs.Dayjs) =>
      cellFor(value.format("YYYY-MM-DD"))?.className.includes(
        "ant-picker-cell-disabled",
      );
    expect(disabled(latest)).toBe(false);
    expect(disabled(dayjs())).toBe(true);
    expect(disabled(dayjs().add(1, "day"))).toBe(true);
  });

  it("re-queries with the picked date as the month-to-date end", async () => {
    const { container } = await renderPage();
    const input = container.querySelector<HTMLInputElement>(
      ".ant-picker-input input",
    );

    await openDatePanel(input!);
    fireEvent.click(document.querySelector(".ant-picker-header-prev-btn")!);
    const target = dayjs().subtract(1, "day").subtract(1, "month");
    const targetValue = target.startOf("month").format("YYYY-MM-DD");
    fireEvent.click(
      cellFor(targetValue)!.querySelector(".ant-picker-cell-inner")!,
    );

    await waitFor(() => expect(reportQueries().length).toBeGreaterThan(1));
    const queries = reportQueries();
    const query = queries[queries.length - 1];
    expect(query.searchParams.get("end_date")).toBe(targetValue);
    expect(query.searchParams.get("start_date")).toBe(targetValue);
  });

  it("surfaces the snapshot truncation warning instead of claiming full results", async () => {
    vi.mocked(request).mockImplementation(async (url) =>
      String(url).includes("/task-type/dates")
        ? emptyDates
        : {
            ...emptyReport,
            warnings: ["snapshot_month_to_date", "report_rows_truncated"],
          },
    );

    await renderPage();

    expect(
      await screen.findByText("结果超过上限已截断，请缩小筛选范围或导出全量"),
    ).toBeInTheDocument();
  });

  it("defaults to the latest ready batch when it is older than T-1", async () => {
    const ready = dayjs().subtract(2, "day");
    mockRequests({ latest_ready_prt_dt: ready.format("YYYY-MM-DD") });

    await renderPage();

    await waitFor(() => {
      const queries = reportQueries();
      expect(queries[queries.length - 1].searchParams.get("end_date")).toBe(
        ready.format("YYYY-MM-DD"),
      );
    });
    const queries = reportQueries();
    const query = queries[queries.length - 1];
    expect(query.searchParams.get("start_date")).toBe(
      ready.startOf("month").format("YYYY-MM-DD"),
    );
  });

  it("keeps T-1 as the ceiling when the ready batch is newer", async () => {
    mockRequests({ latest_ready_prt_dt: dayjs().format("YYYY-MM-DD") });

    await renderPage();
    await waitFor(() =>
      expect(
        vi
          .mocked(request)
          .mock.calls.some(([url]) => String(url).includes("/task-type/dates")),
      ).toBe(true),
    );

    const latest = dayjs().subtract(1, "day").format("YYYY-MM-DD");
    expect(reportQueries().length).toBeGreaterThan(0);
    expect(
      reportQueries().every(
        (query) => query.searchParams.get("end_date") === latest,
      ),
    ).toBe(true);
  });

  it("greys out dates in the covered window without a ready batch", async () => {
    const at = (offset: number) =>
      dayjs().subtract(offset, "day").format("YYYY-MM-DD");
    mockRequests({
      latest_ready_prt_dt: at(3),
      items: [
        { prt_dt: at(3), status: "ready" },
        { prt_dt: at(2), status: "loading" },
        { prt_dt: at(4), status: "failed" },
      ],
    });

    const { container } = await renderPage();
    const input = container.querySelector<HTMLInputElement>(
      ".ant-picker-input input",
    );
    await openDatePanel(input!);
    const disabled = (value: string) =>
      cellFor(value)?.className.includes("ant-picker-cell-disabled");

    expect(disabled(at(3))).toBe(false);
    expect(disabled(at(2))).toBe(true);
    expect(disabled(at(4))).toBe(true);
    expect(disabled(at(5))).toBe(false);
  });

  it.each([
    ["report_snapshot_not_found", "没有出仓数据，请更换统计日期。"],
    [
      "report_snapshot_not_ready",
      "的数据仍在装载中，请稍后重试或更换统计日期。",
    ],
  ])("renders %s as an empty state", async (code, notice) => {
    mockMissingBatch(code);
    const date = dayjs().subtract(1, "day").format("YYYY-MM-DD");

    await renderPage();

    expect(await screen.findByText(`${date} ${notice}`)).toBeInTheDocument();
    expect(screen.queryByText(/加载失败/)).not.toBeInTheDocument();
    expect(screen.getByText("该统计日期暂无出仓数据")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /导出统计报表/ })).toBeDisabled();
  });
});
