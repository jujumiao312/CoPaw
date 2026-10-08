import { describe, expect, it } from "vitest";
import { buildTaskReportDemo } from "./taskTypeReportDemo";
import type { ReportGroup } from "./taskTypeReport";

describe("模拟看板数据", () => {
  it("三种维度均可筛选并展开四个技能，经理 ID 保持一致", () => {
    for (const group_by of [
      "branch",
      "org",
      "manager",
      "skill",
    ] satisfies ReportGroup[]) {
      const params = {
        start_date: "2026-09-01",
        end_date: "2026-09-14",
        group_by,
        first_bbk_id: "110",
      };
      const report = buildTaskReportDemo(params);
      expect(report.items.length).toBeGreaterThan(0);
      expect(report.items.every((row) => row.first_bbk_id === "110")).toBe(
        true,
      );
      const first = report.items[0];
      const details = buildTaskReportDemo({
        ...params,
        org_id: first.org_id ?? undefined,
        skill_detail: true,
      });
      const selected = details.items.filter(
        (row) =>
          row.user_id === first.user_id && row.task_type === first.task_type,
      );
      expect(selected).toHaveLength(4);
      expect(new Set(selected.map((row) => row.skill_id)).size).toBe(4);
      expect(
        report.items.find((row) => row.task_type === "push_other")
          ?.recommended_customers,
      ).toBeNull();
      const plan = report.items.find((row) => row.task_type === "push_plan");
      expect(plan?.insight_count).toBeGreaterThan(
        plan?.insight_customer_count ?? 0,
      );
      expect(plan?.phone_count).toBeGreaterThan(
        plan?.phone_customer_count ?? 0,
      );
    }
  });
});
