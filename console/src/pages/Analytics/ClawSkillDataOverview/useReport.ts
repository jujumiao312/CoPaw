import { useEffect, useRef, useState } from "react";
import {
  getTaskTypeReport,
  REPORT_PAGE_SIZE,
  snapshotUnavailable,
  taskReportError,
  type ReportParams,
  type ReportResponse,
  type SnapshotUnavailable,
} from "../../../api/modules/taskTypeReport";

interface ReportState {
  data?: ReportResponse;
  loading: boolean;
  error?: string;
  unavailable?: SnapshotUnavailable;
}

/** 快照不存在按空数据渲染，其余错误照旧走错误态。 */
function failure(error: unknown): ReportState {
  const unavailable = snapshotUnavailable(error);
  return {
    loading: false,
    unavailable: unavailable ?? undefined,
    error: unavailable ? undefined : taskReportError(error),
  };
}

export function useReport(params: ReportParams, revision: number) {
  const query = JSON.stringify(params);
  const controller = useRef<AbortController>();
  const pending = useRef(false);
  const [state, setState] = useState<ReportState>({ loading: true });
  const [visible, setVisible] = useState(REPORT_PAGE_SIZE);
  useEffect(() => {
    const abort = new AbortController();
    controller.current = abort;
    pending.current = true;
    setVisible(REPORT_PAGE_SIZE);
    setState({ loading: true });
    const filters: ReportParams = JSON.parse(query);
    getTaskTypeReport(
      {
        ...filters,
        ...(filters.group_by === "manager"
          ? { page: 1, page_size: REPORT_PAGE_SIZE }
          : {}),
      },
      abort.signal,
    )
      .then(
        (data) => {
          if (!abort.signal.aborted) setState({ data, loading: false });
        },
        (error: unknown) => {
          if (!abort.signal.aborted) setState(failure(error));
        },
      )
      .finally(() => {
        if (!abort.signal.aborted) pending.current = false;
      });
    return () => abort.abort();
  }, [query, revision]);

  const data = state.data;
  const serverPaged = params.group_by === "manager";
  const hasMore =
    !!data && (serverPaged ? data.has_more : visible < data.items.length);
  const loadMore = async () => {
    if (!data || !hasMore || pending.current) return;
    if (!serverPaged) {
      setVisible((count) =>
        Math.min(count + REPORT_PAGE_SIZE, data.items.length),
      );
      return;
    }
    const abort = controller.current;
    if (!abort || abort.signal.aborted) return;
    pending.current = true;
    setState((current) => ({ ...current, loading: true, error: undefined }));
    try {
      const next = await getTaskTypeReport(
        { ...params, page: (data.page || 1) + 1, page_size: REPORT_PAGE_SIZE },
        abort.signal,
      );
      if (!abort.signal.aborted)
        setState({
          data: { ...next, items: [...data.items, ...next.items] },
          loading: false,
        });
    } catch (error) {
      if (!abort.signal.aborted)
        setState((current) => ({ ...current, ...failure(error) }));
    } finally {
      if (!abort.signal.aborted) pending.current = false;
    }
  };
  return {
    ...state,
    rows: data ? (serverPaged ? data.items : data.items.slice(0, visible)) : [],
    hasMore,
    loadMore,
  };
}
