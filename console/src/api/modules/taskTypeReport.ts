import dayjs, { type Dayjs } from "dayjs";
import { buildAuthHeaders } from "../authHeaders";
import { getApiUrl } from "../config";
import { request } from "../request";
import {
  buildTaskReportDemo,
  buildTaskReportOptionsDemo,
  isTaskReportDemo,
} from "./taskTypeReportDemo";

export type ReportGroup = "branch" | "org" | "manager";
export type TaskType = "push_plan" | "ask_plan" | "push_other";
export interface ReportParams {
  start_date: string;
  end_date: string;
  group_by: ReportGroup;
  task_type?: TaskType;
  skill_detail?: boolean;
  first_bbk_id?: string;
  org_id?: string;
  user_id?: string;
  keyword?: string;
  page?: number;
  page_size?: number;
}
type ClawPeriodSuffix = "_t1" | "_t3" | "_t7" | "_t14";
type ClawPeriodMetric =
  | "wlth_prod_buy_cm_qty"
  | "wlth_prod_buy_cust_qty"
  | "wlth_prod_buy_amt"
  | "aum_asc_amt"
  | "sfl_cust_asc_qty"
  | "wlth_inc"
  | "fnd_prod_buy_cm_qty"
  | "dps_prod_buy_cm_qty"
  | "fp_prod_buy_cm_qty"
  | "insu_prod_buy_cm_qty"
  | "fnd_prod_buy_cust_qty"
  | "dps_prod_buy_cust_qty"
  | "fp_prod_buy_cust_qty"
  | "insu_prod_buy_cust_qty"
  | "fnd_prod_buy_amt"
  | "dps_prod_buy_amt"
  | "fp_prod_buy_amt"
  | "insu_prod_buy_amt"
  | "fnd_aum_asc_amt"
  | "dps_aum_asc_amt"
  | "fp_aum_asc_amt"
  | "insu_aum_asc_amt"
  | "fnd_inc"
  | "dps_inc"
  | "fp_inc"
  | "insu_inc";
type ClawStatMetric =
  | "vld_ctc_cust_qty"
  | "vld_ctc_cust_rate"
  | `${ClawPeriodMetric}${ClawPeriodSuffix}`;

export type ReportRow = {
  first_bbk_id: string | null;
  first_bbk_name: string | null;
  org_id: string | null;
  org_name: string | null;
  user_id: string | null;
  user_name: string | null;
  sapid: string | null;
  pst_lvl: string | null;
  skill_id: string | null;
  cn_name: string | null;
  task_type: TaskType;
  task_type_name: string;
  skill_count: number | null;
  permission_manager_count: number | null;
  active_manager_count: number | null;
  active_task_count?: number | null;
  paused_task_count?: number | null;
  suc_execute_job: number;
  read_tasks: number;
  read_rate: number | null;
  recommended_customers: number | null;
  read_customer_count: number | null;
  plan_read_rate: number | null;
  insight_customer_count: number | null;
  click_to_insight_rate: number | null;
  insight_count: number | null;
  phone_customer_count: number | null;
  click_to_phone_rate: number | null;
  phone_count: number | null;
} & Partial<Record<ClawStatMetric, number | null>>;
export interface ReportResponse {
  sync_date: string | null;
  warnings: string[];
  items: ReportRow[];
  page: number | null;
  page_size: number | null;
  total: number;
  has_more: boolean;
}
export interface ReportOptionParams {
  end_date: string;
  kind: "branches" | "orgs";
  first_bbk_id?: string;
}
export interface ReportOptions {
  sync_date: string | null;
  items: { value: string; label: string }[];
}
export interface ReportDateItem {
  prt_dt: string;
  status: string;
}
export interface ReportDates {
  latest_ready_prt_dt: string | null;
  items: ReportDateItem[];
}
/** 快照数据覆盖的日期窗口；窗口之外是否有数据未知，不做限制。 */
export interface ReportDateWindow {
  ready: Set<string>;
  start: string | null;
}
/** 快照不存在时按“暂无出仓数据”处理，其余错误保留错误态。 */
export type SnapshotUnavailable = "missing";
export const REPORT_PAGE_SIZE = 20;
/** 可用跑数日期取最近 90 个快照日期，覆盖日历上会翻到的范围。 */
const DATE_WINDOW_LIMIT = 90;
const REPORT_PATH = "/monitor/report/task-type";
const XLSX_TYPE =
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

export function getTaskReportBbk() {
  return (
    buildAuthHeaders()["X-Bbk-Id"]?.trim() || (isTaskReportDemo() ? "100" : "")
  );
}

/** 落盘快照按 T-1 出数，页面可选的最新统计日期。 */
export function latestReportDate(): Dayjs {
  return dayjs().subtract(1, "day");
}

/** 默认统计日期：最近快照日期与 T-1 取较早的一个。 */
export function defaultReportDate(latestReady?: string | null): Dayjs {
  const latest = latestReportDate();
  if (!latestReady) return latest;
  const ready = dayjs(latestReady);
  return ready.isValid() && ready.isBefore(latest, "day") ? ready : latest;
}

export const EMPTY_DATE_WINDOW: ReportDateWindow = {
  ready: new Set(),
  start: null,
};

export function reportDateWindow(dates: ReportDates): ReportDateWindow {
  const items = dates.items ?? [];
  return {
    ready: new Set(items.map((item) => item.prt_dt)),
    start: items.reduce<string | null>(
      (earliest, item) =>
        !earliest || item.prt_dt < earliest ? item.prt_dt : earliest,
      null,
    ),
  };
}

/**
 * 可选统计日期：不超过 T-1；已覆盖的窗口内只放行有快照数据的日期。
 * 窗口之外的日期状态未知，保持可选，避免把窗口外的历史快照一并锁死。
 */
export function canSelectReportDate(
  value: Dayjs,
  window: ReportDateWindow,
): boolean {
  if (value.isAfter(latestReportDate(), "day")) return false;
  const day = value.format("YYYY-MM-DD");
  if (window.ready.has(day)) return true;
  return window.start === null || day < window.start;
}

export function snapshotUnavailable(
  error: unknown,
): SnapshotUnavailable | null {
  const code = (error as { data?: { detail?: { code?: string } } })?.data
    ?.detail?.code;
  return code === "report_snapshot_not_found" ? "missing" : null;
}

function scopedParams<T extends { first_bbk_id?: string }>(params: T): T {
  const bbk = getTaskReportBbk();
  if (!bbk) throw new Error("缺少分行身份，请从业务系统重新进入看板");
  if (bbk === "100") return params;
  if (params.first_bbk_id && params.first_bbk_id !== bbk)
    throw new Error("只能查询当前分行的数据");
  return { ...params, first_bbk_id: bbk };
}
function queryString(params: ReportParams | ReportOptionParams) {
  const query = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== "") query.set(key, String(value));
  });
  return query.toString();
}
function validateDates(params: ReportParams) {
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(params.start_date) ||
    !/^\d{4}-\d{2}-\d{2}$/.test(params.end_date) ||
    params.start_date !== `${params.end_date.slice(0, 7)}-01`
  ) {
    throw new Error("统计起始日期须为统计日期当月 1 号");
  }
}
export function taskReportError(error: unknown): string {
  const detail = (error as { data?: { detail?: { message?: string } } })?.data
    ?.detail;
  return (
    detail?.message ||
    (error instanceof Error ? error.message : "报表请求失败，请重试")
  );
}
export async function getTaskTypeReport(
  params: ReportParams,
  signal?: AbortSignal,
): Promise<ReportResponse> {
  validateDates(params);
  const filters = scopedParams(params);
  if (isTaskReportDemo()) return buildTaskReportDemo(filters);
  return request<ReportResponse>(`${REPORT_PATH}?${queryString(filters)}`, {
    signal,
    headers: { "X-Bbk-Id": getTaskReportBbk() },
  });
}
export async function getTaskReportOptions(
  params: ReportOptionParams,
  signal?: AbortSignal,
): Promise<ReportOptions> {
  const filters = scopedParams(params);
  if (isTaskReportDemo()) return buildTaskReportOptionsDemo(filters);
  return request<ReportOptions>(
    `${REPORT_PATH}/options?${queryString(filters)}`,
    { signal, headers: { "X-Bbk-Id": getTaskReportBbk() } },
  );
}
export async function getTaskReportDates(
  signal?: AbortSignal,
): Promise<ReportDates> {
  if (isTaskReportDemo()) return { latest_ready_prt_dt: null, items: [] };
  return request<ReportDates>(
    `${REPORT_PATH}/dates?limit=${DATE_WINDOW_LIMIT}`,
    { signal },
  );
}
export async function exportTaskReport(
  params: ReportParams,
  signal?: AbortSignal,
): Promise<Blob> {
  if (isTaskReportDemo())
    throw new Error("模拟数据仅供预览，Excel 导出需要连接真实后端");
  validateDates(params);
  const filters = {
    ...scopedParams(params),
    page: undefined,
    page_size: undefined,
  };
  const response = await fetch(
    getApiUrl(`${REPORT_PATH}/export?${queryString(filters)}`),
    { headers: buildAuthHeaders(), signal },
  );
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new Error(
      data?.detail?.message ||
        (typeof data?.detail === "string"
          ? data.detail
          : `导出失败（HTTP ${response.status}），请重试`),
    );
  }
  if (!response.headers.get("content-type")?.includes(XLSX_TYPE))
    throw new Error("导出接口未返回 Excel 文件，请重试");
  return response.blob();
}
