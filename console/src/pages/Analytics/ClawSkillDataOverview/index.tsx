import { useEffect, useRef, useState } from "react";
import {
  Alert,
  Button,
  DatePicker,
  Input,
  Segmented,
  Table,
  Tag,
  Tooltip,
} from "antd";
import {
  BarChartOutlined,
  ReloadOutlined,
  CloseOutlined,
  ExclamationCircleOutlined,
} from "@ant-design/icons";
import type { ColumnsType } from "antd/es/table";
import type { Dayjs } from "dayjs";
import {
  canSelectReportDate,
  defaultReportDate,
  EMPTY_DATE_WINDOW,
  getTaskReportBbk,
  getTaskReportDates,
  latestReportDate,
  reportDateWindow,
  type ReportGroup,
  type ReportRow,
  type ReportParams,
  type ReportDateWindow,
  type TaskType,
} from "../../../api/modules/taskTypeReport";
import { useIframeStore } from "../../../stores/iframeStore";
import { isTaskReportDemo } from "../../../api/modules/taskTypeReportDemo";
import { useReport } from "./useReport";
import { OrganizationFilters } from "./OrganizationFilters";
import { ReportExport } from "./ReportExport";
import styles from "./index.module.less";
const groups: { label: string; value: ReportGroup }[] = [
  { label: "分行维度", value: "branch" },
  { label: "支行维度", value: "org" },
  { label: "客户经理维度", value: "manager" },
];
const tasks: { label: string; value: TaskType }[] = [
  { label: "推送（名单+方案）", value: "push_plan" },
  { label: "主动提问（名单+方案）", value: "ask_plan" },
  { label: "推送（非名单方案）", value: "push_other" },
];
const leadingMetrics = [
  ["permission_manager_count", "有权限客户经理人数"],
  ["active_manager_count", "活跃客户经理人数"],
  ["suc_execute_job", "成功执行任务数"],
  ["read_tasks", "客户经理已查看任务数"],
  ["read_rate", "任务查看率"],
  ["recommended_customers", "客户级方案数"],
  ["read_customer_count", "已查看客户级方案数"],
  ["plan_read_rate", "客户级方案查看率"],
  ["insight_customer_count", "点击跳转客户洞察客户数"],
  ["click_to_insight_rate", "点击跳转客户洞察客户数覆盖率"],
  ["insight_count", "点击客户洞察总次数"],
  ["phone_customer_count", "点击跳转电访客户数"],
  ["click_to_phone_rate", "点击跳转电访客户数覆盖率"],
  ["phone_count", "点击去电访总次数"],
] as const;
const statMetricBases = [
  ["wlth_prod_buy_cm_qty", "财富产品购买客户经理人数"],
  ["wlth_prod_buy_cust_qty", "财富产品购买客户数"],
  ["wlth_prod_buy_amt", "财富产品购买金额"],
  ["aum_asc_amt", "AUM提升金额"],
  ["sfl_cust_asc_qty", "金葵花客户提升数"],
  ["wlth_inc", "财富中收"],
  ["fnd_prod_buy_cm_qty", "基金购买客户经理人数"],
  ["fnd_prod_buy_cust_qty", "基金购买客户数"],
  ["fnd_prod_buy_amt", "基金购买金额"],
  ["fnd_aum_asc_amt", "基金AUM提升金额"],
  ["fnd_inc", "基金中收"],
] as const;
const statPeriods = [
  ["_t1", "(T+1)"],
  ["_t3", "(T+3)"],
  ["_t7", "(T+7)"],
  ["_t14", "(T+14)"],
] as const;
const statMetrics = [
  ["vld_ctc_cust_qty", "强接触客户数"],
  ["vld_ctc_cust_rate", "强接触客户率"],
  ...statPeriods.flatMap(([suffix, title]) =>
    statMetricBases.map(
      ([key, label]) => [`${key}${suffix}`, `${label}${title}`] as const,
    ),
  ),
] as const;
const metrics = [...leadingMetrics, ...statMetrics];
const METRIC_COLUMN_MIN_WIDTH = 96;
const METRIC_COLUMN_MAX_WIDTH = 150;
/** 指标列按列名长度取宽，短列名不占位，长列名允许表头折行。 */
function metricColumnWidth(title: string) {
  return Math.min(
    METRIC_COLUMN_MAX_WIDTH,
    Math.max(METRIC_COLUMN_MIN_WIDTH, title.length * 12 + 20),
  );
}
function metricColumns(params: ReportParams): ColumnsType<ReportRow> {
  const leadingMetrics =
    params.group_by === "manager"
      ? ([
          ["active_task_count", "当前活跃任务数"],
          ["paused_task_count", "当前暂停任务数"],
        ] as const)
      : params.skill_detail
      ? metrics.slice(1, 2)
      : metrics.slice(0, 2);
  return [...leadingMetrics, ...metrics.slice(2)].map(([key, title]) => ({
    title,
    dataIndex: key,
    width: metricColumnWidth(title),
    align: "right",
    render: (value: number | null) =>
      value == null
        ? "—"
        : key.endsWith("rate")
        ? `${value.toFixed(2)}%`
        : value.toLocaleString(),
  }));
}

const FIELD_DEFINITION_URL = "https://doc.cmbchina.com/f/v?id=_4boSo1";
const fieldDefinitionTip = (
  <>
    该看板数据按机构、客户经理与任务类型查看技能运行表现，字段口径详情请参考
    <a
      href={FIELD_DEFINITION_URL}
      target="_blank"
      rel="noopener noreferrer"
      className={styles.tipLink}
    >
      {FIELD_DEFINITION_URL}
    </a>{" "}
    [Claw数据字段口径说明.pdf]。
  </>
);

function entityKey(row: ReportRow, group: ReportGroup) {
  return JSON.stringify([
    row.first_bbk_id,
    group === "branch" ? null : row.org_id,
    group === "manager" ? row.user_id : null,
  ]);
}
function entityName(row: ReportRow, group: ReportGroup) {
  if (group === "manager") return `${row.user_name || "未知客户经理"}`;
  if (group === "org") return row.org_name || row.org_id || "未知支行";
  return row.first_bbk_name || row.first_bbk_id || "未知分行";
}
function ReportTable({
  params,
  columns,
  revision,
  selectedKey,
  onReload,
}: {
  params: ReportParams;
  columns: ColumnsType<ReportRow>;
  revision: number;
  selectedKey?: string;
  onReload?: () => void;
}) {
  const report = useReport(params, revision);
  const rowKey = (row: ReportRow) =>
    JSON.stringify([
      entityKey(row, params.group_by),
      row.skill_id,
      row.task_type,
    ]);
  const tableWidth = columns.reduce(
    (total, column) =>
      total + (typeof column.width === "number" ? column.width : 0),
    0,
  );
  return (
    <>
      <div className={styles.reportMeta}>
        <span>名单快照：{report.data?.sync_date || "—"}</span>
        <span aria-live="polite">
          已加载 {report.rows.length} / {report.data?.total ?? 0} 条
        </span>
        {report.data?.warnings.includes("report_rows_truncated") && (
          <Tag color="warning">
            结果超过上限已截断，请缩小筛选范围或导出全量
          </Tag>
        )}
        <ReportExport
          params={params}
          disabled={!report.data?.total || report.loading}
        />
      </div>
      {report.error && (
        <Alert
          className={styles.notice}
          type="error"
          showIcon
          message={report.error}
          action={
            report.data ? (
              <Button onClick={() => void report.loadMore()}>重试加载</Button>
            ) : undefined
          }
        />
      )}
      {report.unavailable && (
        <Alert
          className={styles.notice}
          type="info"
          showIcon
          message={`${params.end_date} 没有出仓数据，请更换统计日期。`}
          action={
            onReload ? <Button onClick={onReload}>重试</Button> : undefined
          }
        />
      )}
      <Table<ReportRow>
        className={styles.reportTable}
        size="small"
        columns={columns}
        dataSource={report.rows}
        loading={!report.data && report.loading}
        rowKey={rowKey}
        pagination={false}
        rowClassName={(row) =>
          entityKey(row, params.group_by) === selectedKey
            ? styles.selectedRow
            : ""
        }
        scroll={{
          x: tableWidth,
          y: "min(720px, max(320px, calc(100vh - 440px)))",
        }}
        onScroll={(event) => {
          const node = event.currentTarget;
          if (
            node.scrollHeight - node.scrollTop - node.clientHeight < 48 &&
            !report.error
          )
            void report.loadMore();
        }}
        locale={{
          emptyText: report.error
            ? "加载失败，请刷新报表重试"
            : report.unavailable
            ? "该统计日期暂无出仓数据"
            : "当前条件下暂无数据，请调整筛选条件",
        }}
      />
      <div className={styles.tableFooter} aria-live="polite">
        {report.loading
          ? "正在加载报表…"
          : report.hasMore
          ? null
          : "已显示全部结果"}
      </div>
    </>
  );
}

function SkillDetails({
  row,
  params,
  onClose,
}: {
  row: ReportRow;
  params: ReportParams;
  onClose: () => void;
}) {
  const [revision, setRevision] = useState(0);
  const detailParams: ReportParams = {
    ...params,
    skill_detail: true,
    first_bbk_id: row.first_bbk_id || params.first_bbk_id,
    org_id: row.org_id || undefined,
    user_id: row.user_id || undefined,
  };
  const columns: ColumnsType<ReportRow> = [
    {
      title: "技能名称",
      dataIndex: "cn_name",
      width: 200,
      fixed: "left",
      render: (_, item) => {
        const name = item.cn_name || item.skill_id || "未知技能";
        return (
          <Tooltip title={name}>
            <span className={styles.skillName}>{name}</span>
          </Tooltip>
        );
      },
    },
    ...metricColumns(detailParams),
  ];
  return (
    <section aria-label="技能明细" className={styles.detailSection}>
      <div className={styles.sectionHeader}>
        <div>
          <h2>
            技能明细{" "}
            <span className={styles.headingHint}>
              {entityName(row, params.group_by)}
            </span>
          </h2>
          <p>展示当前机构或客户经理关联的技能运行情况</p>
        </div>
        <div className={styles.actions}>
          <Button
            icon={<ReloadOutlined />}
            onClick={() => setRevision(revision + 1)}
          >
            刷新明细
          </Button>
          <Button icon={<CloseOutlined />} onClick={onClose}>
            收起明细
          </Button>
        </div>
      </div>
      <Alert
        className={styles.notice}
        type="info"
        showIcon
        message="同一任务或客户可能关联多个技能，技能明细各行不可直接相加作为汇总。"
      />
      <ReportTable
        params={detailParams}
        columns={columns}
        revision={revision}
        onReload={() => setRevision(revision + 1)}
      />
    </section>
  );
}

function ReportResults({ params }: { params: ReportParams }) {
  const [revision, setRevision] = useState(0);
  const [selected, setSelected] = useState<ReportRow>();
  const dimensionLabel = groups
    .find((item) => item.value === params.group_by)
    ?.label.replace("维度", "");
  const columns: ColumnsType<ReportRow> = [
    {
      title: dimensionLabel,
      width: 160,
      fixed: "left",
      ellipsis: true,
      render: (_, row) => entityName(row, params.group_by),
    },
    ...(params.group_by === "manager"
      ? [
          {
            title: "所属分行",
            width: 100,
            ellipsis: true,
            render: (_: unknown, row: ReportRow) =>
              `${row.first_bbk_name || row.first_bbk_id || "未知分行"}`,
          },
          {
            title: "所属网点",
            width: 140,
            ellipsis: true,
            render: (_: unknown, row: ReportRow) =>
              `${row.org_name || row.org_id || "未知支行"}`,
          },
          {
            title: "SAPID",
            dataIndex: "user_id",
            width: 96,
            ellipsis: true,
            render: (value: string | null) => value || "—",
          },
          {
            title: "SAP岗位",
            dataIndex: "pst_lvl",
            width: 96,
            ellipsis: true,
            render: (value: string | null) => value || "—",
          },
        ]
      : []),
    {
      title: "技能总数",
      dataIndex: "skill_count",
      width: 88,
      align: "right",
      render: (value: number, row) => {
        const unavailable =
          !row.first_bbk_id ||
          (params.group_by === "org" && !row.org_id) ||
          (params.group_by === "manager" && !row.user_id);
        return (
          <Button
            className={styles.countLink}
            type="link"
            disabled={unavailable}
            title={
              unavailable
                ? "缺少机构或客户经理标识，无法查询对应明细"
                : undefined
            }
            aria-label={`查看${entityName(row, params.group_by)}的技能明细`}
            onClick={() => setSelected(row)}
          >
            {value.toLocaleString()}
          </Button>
        );
      },
    },
    ...metricColumns(params),
  ];
  return (
    <>
      <section aria-label="统计报表" className={styles.reportSection}>
        <div className={styles.sectionHeader}>
          <div>
            <h2>
              技能运行 · {dimensionLabel}统计{" "}
              <span className={styles.headingHint}>点击技能总数查看明细</span>
            </h2>
            <p>
              {tasks.find((item) => item.value === params.task_type)?.label} ·{" "}
              {params.start_date} 至 {params.end_date}
            </p>
          </div>
          <Button
            icon={<ReloadOutlined />}
            onClick={() => {
              setSelected(undefined);
              setRevision(revision + 1);
            }}
          >
            刷新报表
          </Button>
        </div>
        <ReportTable
          params={params}
          columns={columns}
          revision={revision}
          onReload={() => setRevision(revision + 1)}
          selectedKey={
            selected ? entityKey(selected, params.group_by) : undefined
          }
        />
        <p className={styles.metricNote}>
          统计口径：“—”表示不适用或分母为零；期间比率可能超过
          100%。主动提问的已查看任务数按成功任务数计。
        </p>
      </section>
      {selected && (
        <SkillDetails
          key={entityKey(selected, params.group_by)}
          row={selected}
          params={params}
          onClose={() => setSelected(undefined)}
        />
      )}
    </>
  );
}

function ScopedReportPage({ bbk }: { bbk: string }) {
  const [date, setDate] = useState<Dayjs>(() => latestReportDate());
  const [dateWindow, setDateWindow] =
    useState<ReportDateWindow>(EMPTY_DATE_WINDOW);
  const datePicked = useRef(false);
  const [group, setGroup] = useState<ReportGroup>("branch");
  const [task, setTask] = useState<TaskType>("push_plan");
  const [branch, setBranch] = useState<string>(bbk === "100" ? "" : bbk);
  const [org, setOrg] = useState<string>();
  const [search, setSearch] = useState("");
  const [keyword, setKeyword] = useState("");
  useEffect(() => {
    const abort = new AbortController();
    // 默认落在最近有快照数据的日期；取不到时保留 T-1，由报表请求给出空态。
    getTaskReportDates(abort.signal).then(
      (dates) => {
        if (abort.signal.aborted) return;
        setDateWindow(reportDateWindow(dates));
        if (datePicked.current) return;
        setDate(defaultReportDate(dates.latest_ready_prt_dt));
      },
      () => undefined,
    );
    return () => abort.abort();
  }, []);
  const params: ReportParams = {
    start_date: date.startOf("month").format("YYYY-MM-DD"),
    end_date: date.format("YYYY-MM-DD"),
    group_by: group,
    task_type: task,
    first_bbk_id: branch || undefined,
    org_id: group === "branch" ? undefined : org,
    keyword: group === "manager" ? keyword || undefined : undefined,
  };
  return (
    <main className={styles.page}>
      <header className={styles.pageHeader}>
        <div className={styles.titleRow}>
          <BarChartOutlined aria-hidden />
          <h1>Claw 技能运行看板</h1>
          <Tooltip
            title={fieldDefinitionTip}
            styles={{ root: { maxWidth: 360 } }}
          >
            <ExclamationCircleOutlined
              className={styles.titleTip}
              tabIndex={0}
              role="img"
              aria-label="字段口径说明"
            />
          </Tooltip>
          {isTaskReportDemo() && <Tag color="gold">模拟预览</Tag>}
        </div>
      </header>
      {isTaskReportDemo() && (
        <Alert
          className={styles.notice}
          type="warning"
          showIcon
          message="当前为虚构的模拟数据，仅用于预览布局与交互；Excel 导出需连接真实后端。"
        />
      )}
      <section aria-label="报表筛选" className={styles.filterPanel}>
        <div className={styles.dimensionRow}>
          <span className={styles.controlLabel}>统计维度</span>
          <Segmented
            aria-label="统计维度"
            options={groups}
            value={group}
            onChange={(value) => {
              setGroup(value);
              setOrg(undefined);
              setSearch("");
              setKeyword("");
            }}
          />
        </div>
        <div className={styles.toolbar}>
          <div className={styles.field}>
            <label htmlFor="report-date">统计日期</label>
            <DatePicker
              id="report-date"
              aria-label="统计日期"
              value={date}
              allowClear={false}
              disabledDate={(current) =>
                !canSelectReportDate(current, dateWindow)
              }
              onChange={(value) => {
                if (!value) return;
                datePicked.current = true;
                setDate(value);
                setOrg(undefined);
              }}
            />
          </div>
          <OrganizationFilters
            endDate={params.end_date}
            bbk={bbk}
            branch={branch || undefined}
            org={org}
            showOrg={group !== "branch"}
            onBranchChange={(value) => {
              setBranch(value || "");
              setOrg(undefined);
            }}
            onOrgChange={setOrg}
          />
          {group === "manager" && (
            <div className={`${styles.field} ${styles.managerSearch}`}>
              <label htmlFor="report-manager">客户经理</label>
              <Input.Search
                id="report-manager"
                aria-label="客户经理"
                placeholder="姓名 / SAP号"
                maxLength={100}
                allowClear
                value={search}
                onChange={(event) => {
                  setSearch(event.target.value);
                  if (!event.target.value) setKeyword("");
                }}
                onSearch={(value) => setKeyword(value.trim())}
                enterButton="查询"
              />
            </div>
          )}
        </div>
        <div className={styles.taskRow}>
          <span className={styles.controlLabel}>任务类型</span>
          <Segmented
            aria-label="任务类型"
            options={tasks}
            value={task}
            onChange={setTask}
          />
        </div>
      </section>
      <ReportResults key={JSON.stringify(params)} params={params} />
    </main>
  );
}
export default function ClawSkillDataOverview() {
  const identity = useIframeStore((state) => state);
  const bbk = getTaskReportBbk();
  if (!bbk)
    return (
      <main className={styles.page}>
        <h1>Claw 技能运行看板</h1>
        <Alert
          type="warning"
          showIcon
          message="缺少分行身份，请从业务系统重新进入看板"
        />
      </main>
    );
  return (
    <ScopedReportPage
      key={JSON.stringify([bbk, identity.source, identity.userId])}
      bbk={bbk}
    />
  );
}
