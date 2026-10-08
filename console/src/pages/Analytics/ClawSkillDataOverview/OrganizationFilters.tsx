import { useEffect, useState } from "react";
import { Alert, Button, Select } from "antd";
import {
  getTaskReportOptions,
  snapshotUnavailable,
  taskReportError,
  type ReportOptionParams,
  type ReportOptions,
  type SnapshotUnavailable,
} from "../../../api/modules/taskTypeReport";
import styles from "./index.module.less";

function useOptions(params: ReportOptionParams | null) {
  const query = JSON.stringify(params);
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<{
    query: string;
    items: ReportOptions["items"];
    loading: boolean;
    error?: string;
    unavailable?: SnapshotUnavailable;
  }>({ query, items: [], loading: !!params });
  useEffect(() => {
    const abort = new AbortController();
    const filters: ReportOptionParams | null = JSON.parse(query);
    setState({ query, items: [], loading: !!filters });
    if (filters)
      getTaskReportOptions(filters, abort.signal).then(
        (data) => {
          if (!abort.signal.aborted)
            setState({ query, items: data.items, loading: false });
        },
        (error: unknown) => {
          if (abort.signal.aborted) return;
          const unavailable = snapshotUnavailable(error);
          setState({
            query,
            items: [],
            loading: false,
            unavailable: unavailable ?? undefined,
            error: unavailable ? undefined : taskReportError(error),
          });
        },
      );
    return () => abort.abort();
  }, [query, revision]);
  return {
    ...(state.query === query
      ? state
      : {
          items: [],
          loading: !!params,
          error: undefined,
          unavailable: undefined,
        }),
    retry: () => setRevision(revision + 1),
  };
}

/** 技能下拉：选项取统计日期当天 manager_skill 组合里去重后的技能名称。 */
export function SkillFilter({
  endDate,
  branch,
  value,
  onChange,
}: {
  endDate: string;
  branch?: string;
  value?: string;
  onChange: (value?: string) => void;
}) {
  const skills = useOptions({
    end_date: endDate,
    kind: "skills",
    first_bbk_id: branch,
  });
  return (
    <>
      <div className={styles.field}>
        <label htmlFor="report-skill">技能</label>
        <Select
          key={`${endDate}-${branch}`}
          id="report-skill"
          aria-label="技能"
          showSearch
          optionFilterProp="label"
          value={value}
          onChange={onChange}
          options={skills.items}
          disabled={skills.loading || !!skills.error || !!skills.unavailable}
          allowClear
          loading={skills.loading}
          placeholder="全部技能"
        />
      </div>
      {skills.error && (
        <Alert
          className={styles.filterError}
          type="error"
          showIcon
          message={`技能列表加载失败：${skills.error}`}
          action={<Button onClick={skills.retry}>重试技能列表</Button>}
        />
      )}
    </>
  );
}

export function OrganizationFilters({
  endDate,
  bbk,
  branch,
  org,
  showOrg,
  onBranchChange,
  onOrgChange,
}: {
  endDate: string;
  bbk: string;
  branch?: string;
  org?: string;
  showOrg: boolean;
  onBranchChange: (value?: string) => void;
  onOrgChange: (value?: string) => void;
}) {
  const locked = bbk !== "100";
  const branches = useOptions({
    end_date: endDate,
    kind: "branches",
    first_bbk_id: locked ? bbk : undefined,
  });
  const orgs = useOptions(
    showOrg && branch
      ? { end_date: endDate, kind: "orgs", first_bbk_id: branch }
      : null,
  );
  const branchOptions = locked
    ? branches.items.filter((item) => item.value === bbk)
    : branches.items;
  return (
    <>
      <div className={styles.field}>
        <label htmlFor="report-branch">
          分行{locked ? "（当前权限）" : ""}
        </label>
        <Select
          id="report-branch"
          aria-label="分行"
          showSearch
          optionFilterProp="label"
          value={branch}
          onChange={onBranchChange}
          options={branchOptions}
          disabled={locked || !!branches.unavailable}
          allowClear={!locked}
          loading={branches.loading}
          placeholder="全部分行"
        />
      </div>
      {showOrg && (
        <div className={styles.field}>
          <label htmlFor="report-org">支行</label>
          <Select
            key={`${endDate}-${branch}`}
            id="report-org"
            aria-label="支行"
            showSearch
            optionFilterProp="label"
            value={org}
            onChange={onOrgChange}
            options={orgs.items}
            disabled={
              !branch || orgs.loading || !!orgs.error || !!orgs.unavailable
            }
            allowClear
            loading={orgs.loading}
            placeholder={branch ? "全部支行" : "请先选择分行"}
          />
        </div>
      )}
      {branches.error && (
        <Alert
          className={styles.filterError}
          type="error"
          showIcon
          message={`分行列表加载失败：${branches.error}`}
          action={<Button onClick={branches.retry}>重试分行列表</Button>}
        />
      )}
      {orgs.error && (
        <Alert
          className={styles.filterError}
          type="error"
          showIcon
          message={`支行列表加载失败：${orgs.error}`}
          action={<Button onClick={orgs.retry}>重试支行列表</Button>}
        />
      )}
    </>
  );
}
