import type { ReportParams } from "../../../api/modules/taskTypeReport";

const groupNames: Record<ReportParams["group_by"], string> = {
  branch: "分行",
  org: "支行",
  manager: "客户经理",
};

export const reportExportFilename = (params: ReportParams) =>
  `Claw-${params.skill_detail ? "技能明细" : "统计报表"}-${
    groupNames[params.group_by]
  }-${params.start_date}-${params.end_date}.xlsx`;
