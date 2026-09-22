import dayjs from "dayjs";
import { BBK_ID_MAP } from "../../constants/bbk";
import type {
  ReportParams,
  ReportResponse,
  ReportRow,
  TaskType,
  ReportOptionParams,
  ReportOptions,
} from "./taskTypeReport";

export function isTaskReportDemo() {
  return (
    import.meta.env.DEV &&
    new URLSearchParams(window.location.search).get("demo") === "1"
  );
}

const skills = [
  ["demo-customer-plan", "客户经营方案生成"],
  ["demo-asset-insight", "客户资产配置洞察"],
  ["demo-phone-preparation", "客户电访准备"],
  ["demo-opportunity", "潜力客户机会识别"],
] as const;
const taskTypes: TaskType[] = ["push_plan", "ask_plan", "push_other"];
const taskNames = [
  "推送（名单+方案）",
  "主动提问（名单+方案）",
  "推送（非名单方案）",
];

/** Deterministic, synthetic presentation data; no backend or database writes. */
export function buildTaskReportDemo(params: ReportParams): ReportResponse {
  const items: ReportRow[] = [];
  const days = dayjs(params.end_date).diff(dayjs(params.start_date), "day") + 1;
  const branches = BBK_ID_MAP.filter((branch) =>
    params.first_bbk_id
      ? branch.value === params.first_bbk_id
      : branch.value !== "100",
  ).slice(0, 24);
  branches.forEach((branch) => {
    const branchIndex = BBK_ID_MAP.findIndex(
      (item) => item.value === branch.value,
    );
    const orgs =
      params.group_by === "branch"
        ? [null]
        : ["营业部", "科技园支行", "中心支行"];
    orgs.forEach((orgName, orgIndex) => {
      const orgId = orgName ? `${branch.value}0${orgIndex + 1}` : null;
      if (params.org_id && orgId !== params.org_id) return;
      const managers =
        params.group_by === "manager"
          ? Array.from({ length: 8 }, (_, index) => `演示经理${index + 1}`)
          : [null];
      managers.forEach((managerName, managerIndex) => {
        const userId = managerName ? `DEMO-${orgId}-${managerIndex + 1}` : null;
        if (params.user_id && userId !== params.user_id) return;
        if (
          params.keyword &&
          !`${managerName} ${userId} 客户经理（演示岗位）`
            .toLowerCase()
            .includes(params.keyword.toLowerCase())
        )
          return;
        const skillRows = params.skill_detail ? [...skills] : [null];
        skillRows.forEach((skill, skillIndex) => {
          taskTypes.forEach((task, taskIndex) => {
            if (params.task_type && task !== params.task_type) return;
            const scale =
              params.group_by === "branch"
                ? 18
                : params.group_by === "org"
                ? 6
                : 1;
            const count =
              days *
              scale *
              (branchIndex + orgIndex + managerIndex + taskIndex + 2);
            const successful = skill
              ? Math.ceil(count * (0.4 + skillIndex * 0.1))
              : count;
            const read =
              task === "ask_plan" ? successful : Math.floor(successful * 0.8);
            const customers = task === "push_other" ? null : successful * 3;
            items.push({
              first_bbk_id: branch.value,
              first_bbk_name: branch.label,
              org_id: orgId,
              org_name: orgName,
              user_id: userId,
              user_name: managerName,
              sapid: userId,
              pst_lvl: managerName ? "客户经理（演示岗位）" : null,
              skill_id: skill?.[0] ?? null,
              cn_name: skill?.[1] ?? null,
              task_type: task,
              task_type_name: taskNames[taskIndex],
              skill_count: skill ? null : skills.length,
              permission_manager_count: skill || managerName ? null : scale,
              active_manager_count:
                managerName || task === "ask_plan" ? null : scale,
              active_task_count:
                managerName && task !== "ask_plan" ? scale * 3 : null,
              paused_task_count:
                managerName && task !== "ask_plan" ? scale : null,
              suc_execute_job: successful,
              read_tasks: read,
              read_rate: Number(((read / successful) * 100).toFixed(2)),
              recommended_customers: customers,
              read_customer_count: customers === null ? null : successful * 2,
              plan_read_rate: customers === null ? null : 66.67,
              insight_customer_count: customers === null ? null : successful,
              click_to_insight_rate: customers === null ? null : 33.33,
              insight_count:
                customers === null ? null : Math.floor(successful * 1.35),
              phone_customer_count:
                customers === null ? null : Math.floor(successful / 2),
              click_to_phone_rate:
                customers === null
                  ? null
                  : Number(
                      ((Math.floor(successful / 2) / customers) * 100).toFixed(
                        2,
                      ),
                    ),
              phone_count:
                customers === null ? null : Math.floor(successful * 0.72),
            });
          });
        });
      });
    });
  });
  const page = params.group_by === "manager" ? params.page : undefined;
  const size = params.page_size || 20;
  return {
    sync_date: params.end_date,
    warnings: ["demo_data"],
    items: page ? items.slice((page - 1) * size, page * size) : items,
    total: items.length,
    page: page || null,
    page_size: page ? size : null,
    has_more: !!page && page * size < items.length,
  };
}

export function buildTaskReportOptionsDemo(
  params: ReportOptionParams,
): ReportOptions {
  const items =
    params.kind === "branches"
      ? BBK_ID_MAP.filter((item) =>
          params.first_bbk_id
            ? item.value === params.first_bbk_id
            : item.value !== "100",
        )
      : ["营业部", "科技园支行", "中心支行"].map((label, index) => ({
          value: `${params.first_bbk_id}0${index + 1}`,
          label,
        }));
  return { sync_date: params.end_date, items };
}
