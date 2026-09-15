import { useEffect, useRef, useState } from "react";
import { Alert, Button, Tooltip } from "antd";
import { DownloadOutlined } from "@ant-design/icons";
import {
  exportTaskReport,
  taskReportError,
  type ReportParams,
} from "../../../api/modules/taskTypeReport";
import { isTaskReportDemo } from "../../../api/modules/taskTypeReportDemo";
import styles from "./index.module.less";

export function ReportExport({
  params,
  disabled,
}: {
  params: ReportParams;
  disabled?: boolean;
}) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string>();
  const pending = useRef(false);
  const controller = useRef<AbortController>();
  useEffect(() => () => controller.current?.abort(), []);
  const label = params.skill_detail ? "导出技能明细" : "导出统计报表";
  const exportReport = async () => {
    if (pending.current) return;
    const abort = new AbortController();
    controller.current = abort;
    pending.current = true;
    setLoading(true);
    setError(undefined);
    try {
      const blob = await exportTaskReport(params, abort.signal);
      if (abort.signal.aborted) return;
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `Claw-${params.skill_detail ? "技能明细" : "统计报表"}-${
        params.group_by
      }-${params.start_date}-${params.end_date}.xlsx`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 0);
    } catch (reason) {
      if (!abort.signal.aborted) setError(taskReportError(reason));
    } finally {
      pending.current = false;
      if (!abort.signal.aborted) setLoading(false);
    }
  };
  return (
    <div className={styles.exportAction}>
      <Tooltip
        title={
          isTaskReportDemo()
            ? "模拟数据仅供预览，Excel 导出需连接真实后端"
            : "导出当前筛选下的全部数据，包含尚未滚动加载的记录"
        }
      >
        <Button
          icon={<DownloadOutlined />}
          loading={loading}
          disabled={disabled || isTaskReportDemo()}
          onClick={exportReport}
        >
          {label}
        </Button>
      </Tooltip>
      {error && <Alert type="error" showIcon message={error} />}
    </div>
  );
}
