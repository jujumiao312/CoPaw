import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import dayjs from "dayjs";
import type { ReactNode } from "react";
import { request } from "../../../api/request";
import ClawSkillDataOverview from "./index";
import { reportExportFilename } from "./reportExportFilename";
import { buildTaskReportDemo } from "../../../api/modules/taskTypeReportDemo";
import type {
  ReportGroup,
  ReportRow,
} from "../../../api/modules/taskTypeReport";

vi.mock("../../../api/request", () => ({ request: vi.fn() }));
vi.mock("antd", async (importOriginal) => {
  const antd = await importOriginal<typeof import("antd")>();
  return {
    ...antd,
    Table: ({
      columns,
      dataSource,
      locale,
      rowKey,
    }: {
      columns: {
        title?: ReactNode;
        dataIndex?: string;
        render?: (value: unknown, row: ReportRow) => ReactNode;
      }[];
      dataSource: ReportRow[];
      locale?: { emptyText?: ReactNode };
      rowKey: (row: ReportRow) => string;
    }) => (
      <table>
        <thead>
          <tr>
            {columns.map((column, index) => (
              <th key={index}>{column.title}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {dataSource.length === 0 ? (
            <tr>
              <td colSpan={columns.length}>{locale?.emptyText}</td>
            </tr>
          ) : (
            dataSource.map((row) => (
              <tr key={rowKey(row)}>
                {columns.map((column, index) => (
                  <td key={index}>
                    {column.render
                      ? column.render(row[column.dataIndex ?? ""], row)
                      : String(row[column.dataIndex ?? ""] ?? "")}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    ),
  };
});
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

const statMetricTitles = (() => {
  const bases = [
    "财富产品购买客户经理人数",
    "财富产品购买客户数",
    "财富产品购买金额",
    "AUM提升金额",
    "金葵花客户提升数",
    "财富中收",
    "基金购买客户经理人数",
    "基金购买客户数",
    "基金购买金额",
    "基金AUM提升金额",
    "基金中收",
  ];
  return [
    "强接触客户数",
    "强接触客户率",
    ...["(T+1)", "(T+3)", "(T+7)", "(T+14)"].flatMap((period) =>
      bases.map((base) => `${base}${period}`),
    ),
  ];
})();

function tableRow(region: ReturnType<typeof within>, header: string) {
  const headers = region.getAllByRole("columnheader");
  const index = headers.findIndex((cell) => cell.textContent === header);
  const cells = region.getAllByRole("row")[1]?.querySelectorAll("td");
  return cells?.[index]?.textContent;
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

describe("ClawSkillDataOverview dimension columns", () => {
  it.each(["branch", "org", "manager"] as const)(
    "keeps %s summary and detail columns consistent with their scope",
    async (group) => {
      vi.mocked(request).mockImplementation(async (url) => {
        const query = new URL(String(url), "http://localhost");
        if (query.pathname.endsWith("/dates")) return emptyDates;
        if (query.pathname.endsWith("/options")) return { items: [] };
        const report = buildTaskReportDemo({
          start_date: "2026-09-01",
          end_date: "2026-09-14",
          first_bbk_id: "110",
          group_by: query.searchParams.get("group_by") as ReportGroup,
          task_type: "push_plan",
          skill_detail: query.searchParams.get("skill_detail") === "true",
          user_id: query.searchParams.get("user_id") || undefined,
          org_id: query.searchParams.get("org_id") || undefined,
        });
        return {
          ...report,
          items: report.items.slice(0, 1),
          total: 1,
          has_more: false,
        };
      });
      await renderPage();
      if (group !== "branch")
        fireEvent.click(
          screen.getByText(group === "org" ? "支行维度" : "客户经理维度"),
        );
      const summary = within(screen.getByRole("region", { name: "统计报表" }));
      const headers = () =>
        summary.getAllByRole("columnheader").map((cell) => cell.textContent);
      expect(headers()).toContain("技能总数");
      const phoneIndex = headers().indexOf("点击去电访总次数");
      expect(phoneIndex).toBeGreaterThan(-1);
      const appendedHeaders = headers().slice(phoneIndex + 1);
      expect(appendedHeaders).toHaveLength(46);
      expect(appendedHeaders).toEqual(statMetricTitles);
      expect(appendedHeaders[0]).toBe("强接触客户数");
      expect(appendedHeaders[45]).toBe("基金中收(T+14)");
      if (group === "manager") {
        expect(headers().slice(5, 8)).toEqual([
          "技能总数",
          "当前活跃任务数",
          "当前暂停任务数",
        ]);
        expect(headers()).not.toContain("有权限客户经理人数");
        expect(headers()).not.toContain("活跃客户经理人数");
        expect(await summary.findAllByText("演示经理1")).not.toHaveLength(0);
      } else {
        expect(headers()).toContain("有权限客户经理人数");
        expect(headers()).toContain("活跃客户经理人数");
      }
      if (group === "org") {
        expect(await summary.findByText("营业部")).toBeInTheDocument();
        expect(summary.queryByText(/营业部 ·/)).not.toBeInTheDocument();
      }
      const buttons = await summary.findAllByRole("button", {
        name: /查看.*的技能明细/,
      });
      fireEvent.click(buttons[0]);
      const detail = within(screen.getByRole("region", { name: "技能明细" }));
      const detailHeaders = detail
        .getAllByRole("columnheader")
        .map((cell) => cell.textContent);
      expect(detailHeaders).not.toContain("技能总数");
      const detailPhoneIndex = detailHeaders.indexOf("点击去电访总次数");
      expect(detailPhoneIndex).toBeGreaterThan(-1);
      const detailStatHeaders = detailHeaders.slice(detailPhoneIndex + 1);
      expect(detailStatHeaders).toHaveLength(46);
      expect(detailStatHeaders).toEqual(statMetricTitles);
      expect(detailHeaders).not.toContain("有权限客户经理人数");
      expect(detailHeaders).toContain(
        group === "manager" ? "当前活跃任务数" : "活跃客户经理人数",
      );
      if (group === "manager") {
        expect(detailHeaders).toContain("当前暂停任务数");
        expect(detailHeaders).not.toContain("活跃客户经理人数");
      }
      expect(await detail.findByText("客户经营方案生成")).toBeInTheDocument();
    },
    30000,
  );
});

describe("ClawSkillDataOverview new stat metrics", () => {
  it("renders integer, rate, null, and undefined stat values", async () => {
    vi.mocked(request).mockImplementation(async (url) => {
      const query = new URL(String(url), "http://localhost");
      if (query.pathname.endsWith("/dates")) return emptyDates;
      if (query.pathname.endsWith("/options")) return { items: [] };
      const report = buildTaskReportDemo({
        start_date: "2026-09-01",
        end_date: "2026-09-14",
        first_bbk_id: "110",
        group_by: "branch",
        task_type: "push_plan",
      });
      const row: ReportRow = {
        ...report.items[0],
        vld_ctc_cust_qty: 1234,
        vld_ctc_cust_rate: 12.34,
        wlth_prod_buy_cm_qty_t1: null,
        fnd_inc_t14: undefined,
      };
      return {
        ...report,
        items: [row],
        total: 1,
        has_more: false,
      };
    });

    await renderPage();

    const summary = within(screen.getByRole("region", { name: "统计报表" }));
    expect(tableRow(summary, "强接触客户数")).toBe("1,234");
    expect(tableRow(summary, "强接触客户率")).toBe("12.34%");
    expect(tableRow(summary, "财富产品购买客户经理人数(T+1)")).toBe("—");
    expect(tableRow(summary, "基金中收(T+14)")).toBe("—");
  }, 30000);
});

describe("ClawSkillDataOverview table chrome", () => {
  it("keeps the skill id, scroll hint, and date ceiling hint out of the page", async () => {
    vi.mocked(request).mockImplementation(async (url) => {
      const query = new URL(String(url), "http://localhost");
      if (query.pathname.endsWith("/dates")) return emptyDates;
      if (query.pathname.endsWith("/options")) return { items: [] };
      const report = buildTaskReportDemo({
        start_date: "2026-09-01",
        end_date: "2026-09-14",
        first_bbk_id: "110",
        group_by: "branch",
        task_type: "push_plan",
        skill_detail: query.searchParams.get("skill_detail") === "true",
      });
      return {
        ...report,
        items: report.items.slice(0, 1),
        total: 1,
        has_more: false,
      };
    });

    await renderPage();

    expect(screen.queryByText("向下滚动加载更多")).not.toBeInTheDocument();
    expect(screen.queryByText(/数据 T-1/)).not.toBeInTheDocument();
    expect(screen.queryByText(/最多可选/)).not.toBeInTheDocument();

    const summary = within(screen.getByRole("region", { name: "统计报表" }));
    fireEvent.click(
      (await summary.findAllByRole("button", { name: /查看.*的技能明细/ }))[0],
    );
    const detail = within(screen.getByRole("region", { name: "技能明细" }));
    expect(await detail.findByText("客户经营方案生成")).toBeInTheDocument();
    expect(detail.queryByText("demo-customer-plan")).not.toBeInTheDocument();
  });
});

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

  it("defaults to the latest snapshot date when it is older than T-1", async () => {
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

  it("keeps T-1 as the ceiling when the snapshot date is newer", async () => {
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

  it("greys out dates in the covered window without snapshot rows", async () => {
    const at = (offset: number) =>
      dayjs().subtract(offset, "day").format("YYYY-MM-DD");
    mockRequests({
      latest_ready_prt_dt: at(3),
      items: [
        { prt_dt: at(3), status: "ready" },
        { prt_dt: at(4), status: "ready" },
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
    expect(disabled(at(4))).toBe(false);
    expect(disabled(at(5))).toBe(false);
  });

  it.each([["report_snapshot_not_found", "没有出仓数据，请更换统计日期。"]])(
    "renders %s as an empty state",
    async (code, notice) => {
      mockMissingBatch(code);
      const date = dayjs().subtract(1, "day").format("YYYY-MM-DD");

      await renderPage();

      expect(await screen.findByText(`${date} ${notice}`)).toBeInTheDocument();
      expect(screen.queryByText(/加载失败/)).not.toBeInTheDocument();
      expect(screen.getByText("该统计日期暂无出仓数据")).toBeInTheDocument();
      expect(
        screen.getByRole("button", { name: /导出统计报表/ }),
      ).toBeDisabled();
    },
  );
  it("shows unexpected backend errors instead of an obsolete loading-batch state", async () => {
    mockMissingBatch("report_snapshot_not_ready");
    await renderPage();
    expect(
      (await screen.findAllByText(/backend message/)).length,
    ).toBeGreaterThan(0);
    expect(screen.queryByText(/仍在装载中/)).not.toBeInTheDocument();
    expect(
      screen.queryByText("该统计日期暂无出仓数据"),
    ).not.toBeInTheDocument();
  });
});

describe("ClawSkillDataOverview report export filename", () => {
  it.each([
    ["branch", "分行"],
    ["org", "支行"],
    ["manager", "客户经理"],
  ] as const)("uses the Chinese name for %s", (group_by, chineseName) => {
    expect(
      reportExportFilename({
        start_date: "2026-09-01",
        end_date: "2026-09-14",
        group_by,
        task_type: "push_plan",
      }),
    ).toBe(`Claw-统计报表-${chineseName}-2026-09-01-2026-09-14.xlsx`);
  });
});
