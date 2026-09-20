# -*- coding: utf-8 -*-
"""金葵花任务类型报表落盘快照查询服务。

数据来源：``swe_task_type_report_snapshot`` / ``swe_task_type_report_batch``，
由 Hive 侧 ``hive/task_type_report_daily.sql`` 预聚合后出仓到 TDSQL。

与在线服务的分工：

- 指标口径、去重范围、NULL 规则由出仓脚本保证，本模块只做筛选、排序、分页、装配；
- 机构范围校验与机构名称解析复用在线服务的 ``validate_roster_scope`` /
  ``resolve_organization_filters``，校验对象是批次记录的名单快照日（sync_date），
  保持 403 / 422 语义与在线接口一致；
- 有权限客户经理数不在仓内计算，仍按同一名单快照实时统计。

区间口径：落盘表是「当月 1 号 ~ 跑数日期」的累计快照，因此只支持该区间；
其它区间请调用在线接口。
"""

import logging
from datetime import date

from ...models.task_type_report import (
    ReportOption,
    ReportOptionsParams,
    ReportOptionsResponse,
    ResolvedReportFilters,
    TaskTypeReportParams,
    TaskTypeReportRow,
)
from ...models.task_type_snapshot import (
    SnapshotBatchInfo,
    SnapshotComboCount,
    SnapshotDateItem,
    SnapshotDatesResponse,
    SnapshotReportParams,
    SnapshotReportResponse,
    SnapshotStatusResponse,
)
from ..cron.task_type_report import (
    ReportError,
    enforce_branch,
    report_db,
    resolve_organization_filters,
    validate_roster_scope,
)

logger = logging.getLogger(__name__)

# 接口组合 -> 落盘表组合标签
COMBO_MAP = {
    ("overall", False): "overall",
    ("branch", False): "branch",
    ("org", False): "org",
    ("manager", False): "manager",
    ("branch", True): "branch_skill",
    ("org", True): "org_skill",
    ("manager", True): "manager_skill",
}
EXPECTED_COMBOS = (
    "overall",
    "branch",
    "org",
    "manager",
    "branch_skill",
    "org_skill",
    "manager_skill",
)
# 每个组合真正有值的维度列；其余维度列在落盘表里是空串，出参要还原成 null。
COMBO_DIM_COLUMNS = {
    "overall": (),
    "branch": ("first_bbk_id",),
    "org": ("first_bbk_id", "org_id"),
    "manager": ("first_bbk_id", "org_id", "user_id"),
    "branch_skill": ("first_bbk_id", "skill_id"),
    "org_skill": ("first_bbk_id", "org_id", "skill_id"),
    "manager_skill": (
        "first_bbk_id",
        "org_id",
        "user_id",
        "skill_id",
    ),
}
# 机构/人员筛选必须落在包含该维度的组合上，否则落盘表无法还原该口径。
FILTER_REQUIRED_GROUPS = {
    "first_bbk_id": ("branch", "org", "manager"),
    "org_id": ("org", "manager"),
    "user_id": ("manager",),
}
FILTER_LABELS = {
    "first_bbk_id": "分行",
    "org_id": "网点",
    "user_id": "客户经理",
}
TASK_TYPE_LABELS = {
    "push_plan": "推送(名单+方案)",
    "ask_plan": "主动提问(名单+方案)",
    "push_other": "推送(非名单方案)",
}
OPTION_COLUMNS = {
    "branches": ("first_bbk_id", "first_bbk_nm"),
    "orgs": ("org_id", "org_nm"),
}
TASK_TYPE_ORDER = (
    "CASE task_type WHEN 'push_plan' THEN 1 "
    "WHEN 'ask_plan' THEN 2 ELSE 3 END"
)
SNAPSHOT_COLUMNS = (
    "prt_dt, source_id, rpt_combo, task_type, first_bbk_id, org_id, "
    "user_id, skill_id, first_bbk_nm, org_nm, user_name, pst_lvl, "
    "cn_name, task_type_name, skill_cnt, active_manager_cnt, "
    "suc_execute_job, read_tasks, read_rate, recommended_customers, "
    "read_customer_cnt, plan_read_rate, insight_customer_count, "
    "click_to_insight_rate, insight_cnt, phone_customer_cnt, "
    "click_to_phone_rate, phone_cnt, stat_start_dt, stat_end_dt"
)
BATCH_COLUMNS = (
    "prt_dt, source_id, stat_start_dt, stat_end_dt, sync_date, "
    "status, row_total, loaded_at"
)
# 非分页查询一次最多返回的行数；导出走 MAX_EXPORT_ROWS 上限。
MAX_REPORT_ROWS = 200000

PERIOD_RATIOS = "period_ratios_not_cohort_conversion"
SNAPSHOT_WINDOW = "snapshot_month_to_date"
SKILL_ROWS_NOT_ADDITIVE = "skill_rows_not_additive"
NO_MATCHING_ORGANIZATION = "no_matching_organization"
NO_MATCHING_SKILLS = "no_matching_skills"
ROWS_TRUNCATED = "report_rows_truncated"
SNAPSHOT_NOT_FOUND_CODE = "report_snapshot_not_found"
SNAPSHOT_NOT_READY_CODE = "report_snapshot_not_ready"
FILTER_NOT_SUPPORTED_CODE = "report_filter_not_supported"


def combo_of(params: SnapshotReportParams) -> str:
    """把接口参数映射成落盘表的组合标签。"""
    return COMBO_MAP[(params.group_by, params.skill_detail)]


def _text(value) -> str | None:
    """空串与 None 统一还原为 None，避免前端显示空字符串。"""
    if value is None:
        return None
    text = str(value)
    return text or None


def _int(value) -> int:
    return int(value or 0)


def _optional_int(value) -> int | None:
    return None if value is None else int(value)


def _optional_float(value) -> float | None:
    return None if value is None else float(value)


def _as_date(value) -> date | None:
    if value is None:
        return None
    if isinstance(value, date):
        return value
    return date.fromisoformat(str(value)[:10])


def _month_bounds(month: str) -> tuple[str, str]:
    """返回 month（yyyy-MM）对应的半开区间 [当月1号, 次月1号)。"""
    first = date.fromisoformat(f"{month}-01")
    if first.month == 12:
        following = date(first.year + 1, 1, 1)
    else:
        following = date(first.year, first.month + 1, 1)
    return first.isoformat(), following.isoformat()


def _permission_dim_columns(combo: str) -> list[str]:
    """权限人数按名单维度统计，技能明细沿用其汇总维度。"""
    dims = COMBO_DIM_COLUMNS[combo]
    return [
        column
        for column in ("first_bbk_id", "org_id", "user_id")
        if column in dims
    ]


def _permission_key(record, combo: str) -> tuple:
    return tuple(
        str(record.get(column) or "")
        for column in _permission_dim_columns(combo)
    )


async def _load_batch(db, prt_dt: date, source_id: str) -> dict | None:
    return await db.fetch_one(
        f"SELECT {BATCH_COLUMNS} FROM swe_task_type_report_batch "
        "WHERE prt_dt = %s AND source_id = %s",
        (prt_dt.isoformat(), source_id),
    )


def _require_ready(batch, prt_dt: date, source_id: str) -> dict:
    """批次不存在报 404，状态不是 ready 报 409，避免把未就绪当成没有数据。"""
    if not batch:
        raise ReportError(
            404,
            SNAPSHOT_NOT_FOUND_CODE,
            f"{prt_dt.isoformat()} 没有来源 {source_id} 的报表批次。",
        )
    status = str(batch.get("status") or "").lower()
    if status != "ready":
        raise ReportError(
            409,
            SNAPSHOT_NOT_READY_CODE,
            f"{prt_dt.isoformat()} 来源 {source_id} 的报表批次状态为 "
            f"{status or 'unknown'}，请等待出仓完成或重跑。",
        )
    return batch


def _batch_info(batch: dict) -> SnapshotBatchInfo:
    return SnapshotBatchInfo(
        prt_dt=_as_date(batch.get("prt_dt")),
        source_id=str(batch.get("source_id") or ""),
        status=str(batch.get("status") or ""),
        stat_start_dt=_as_date(batch.get("stat_start_dt")),
        stat_end_dt=_as_date(batch.get("stat_end_dt")),
        sync_date=_text(batch.get("sync_date")),
        row_total=_int(batch.get("row_total")),
        loaded_at=batch.get("loaded_at"),
    )


def _legacy_params(
    params: SnapshotReportParams, sync_date: str
) -> TaskTypeReportParams:
    """构造在线参数模型，复用其范围校验与名称解析。"""
    return TaskTypeReportParams(
        start_date=params.stat_start_date,
        end_date=params.end_date,
        group_by=params.group_by,
        skill_detail=params.skill_detail,
        first_bbk_id=params.first_bbk_id,
        first_bbk_name=params.first_bbk_name,
        org_id=params.org_id,
        org_name=params.org_name,
        user_id=params.user_id,
        keyword=params.keyword,
    )


async def _resolve_scope(
    db, batch: dict, params: SnapshotReportParams
) -> tuple[bool, dict]:
    """机构范围校验 + 名称解析；批次没有名单快照日时只允许 ID 筛选。"""
    sync_date = str(batch.get("sync_date") or "").strip()
    if not sync_date:
        if params.first_bbk_name or params.org_name:
            raise ReportError(
                409,
                SNAPSHOT_NOT_READY_CODE,
                "批次缺少名单快照日，无法按机构名称筛选。",
            )
        return True, {
            "first_bbk_id": params.first_bbk_id,
            "org_id": params.org_id,
        }
    legacy = _legacy_params(params, sync_date)
    await validate_roster_scope(db, sync_date, legacy)
    return await resolve_organization_filters(db, sync_date, legacy)


def validate_filter_scope(group_by: str, filters: dict, user_id: str | None):
    """机构/人员筛选必须落在包含该维度的组合上。"""
    values = dict(filters)
    values["user_id"] = user_id
    for dimension, allowed in FILTER_REQUIRED_GROUPS.items():
        if not values.get(dimension):
            continue
        if group_by in allowed:
            continue
        raise ReportError(
            422,
            FILTER_NOT_SUPPORTED_CODE,
            f"落盘报表的 {group_by} 维度不支持"
            f"{FILTER_LABELS[dimension]}筛选，请改用 "
            f"{'/'.join(allowed)} 维度或在线接口。",
        )


def _keyword_pattern(keyword: str) -> str:
    """按在线接口的方式转义 LIKE 通配符，避免用户输入被当作搜索语法。"""
    escaped = keyword.replace("!", "!!").replace("%", "!%").replace("_", "!_")
    return f"%{escaped}%"


def build_filters(
    params: SnapshotReportParams,
    source_id: str,
    combo: str,
    filters: dict,
) -> tuple[str, list]:
    """按参数拼装过滤条件，全部走参数绑定。"""
    clauses = ["prt_dt = %s", "source_id = %s", "rpt_combo = %s"]
    values: list = [params.end_date.isoformat(), source_id, combo]
    if params.task_type:
        clauses.append("task_type = %s")
        values.append(params.task_type)
    if filters.get("first_bbk_id"):
        clauses.append("first_bbk_id = %s")
        values.append(filters["first_bbk_id"])
    if filters.get("org_id"):
        clauses.append("org_id = %s")
        values.append(filters["org_id"])
    if params.user_id:
        clauses.append("user_id = %s")
        values.append(params.user_id)
    if params.keyword:
        pattern = _keyword_pattern(params.keyword)
        clauses.append(
            "(user_name LIKE %s ESCAPE '!' OR user_id LIKE %s ESCAPE '!' "
            "OR pst_lvl LIKE %s ESCAPE '!')"
        )
        values.extend([pattern, pattern, pattern])
    return " AND ".join(clauses), values


def order_clause(combo: str) -> str:
    """与在线接口一致的排序：分行、网点、经理、技能，空机构排最后。"""
    dims = COMBO_DIM_COLUMNS[combo]
    parts: list[str] = []
    for column in ("first_bbk_id", "org_id"):
        if column in dims:
            parts.append(f"CASE WHEN {column} = '' THEN 1 ELSE 0 END")
            parts.append(column)
    for column in ("user_id", "skill_id"):
        if column in dims:
            parts.append(column)
    parts.append(TASK_TYPE_ORDER)
    return " ORDER BY " + ", ".join(parts)


async def _fetch_rows(
    db, where: str, values: list, combo: str, limit: int | None, offset: int
) -> list[dict]:
    sql = (
        f"SELECT {SNAPSHOT_COLUMNS} FROM swe_task_type_report_snapshot "
        f"WHERE {where}{order_clause(combo)}"
    )
    params = list(values)
    if limit is not None:
        sql += " LIMIT %s OFFSET %s"
        params.extend([limit, offset])
    return await db.fetch_all(sql, tuple(params))


async def _count_rows(db, where: str, values: list) -> int:
    row = await db.fetch_one(
        "SELECT COUNT(*) AS total FROM swe_task_type_report_snapshot "
        f"WHERE {where}",
        tuple(values),
    )
    return _int(row.get("total") if row else 0)


async def _collect_rows(
    db,
    params: SnapshotReportParams,
    where: str,
    values: list,
    combo: str,
    max_rows: int,
) -> tuple[list[dict], int, bool]:
    """分页时取当前页并返回总数；否则取全量并在超过上限时截断。"""
    if params.page is not None:
        offset = (params.page - 1) * params.page_size
        rows = await _fetch_rows(
            db, where, values, combo, params.page_size, offset
        )
        total = await _count_rows(db, where, values)
        return rows, total, False
    rows = await _fetch_rows(db, where, values, combo, max_rows + 1, 0)
    truncated = len(rows) > max_rows
    if truncated:
        rows = rows[:max_rows]
    return rows, len(rows), truncated


async def _fetch_permission_counts(
    db,
    batch: dict,
    source_id: str,
    combo: str,
    filters: dict,
) -> dict[tuple, int]:
    """有权限客户经理数：同一名单快照 + 当前 source 的初始化来源记录。"""
    sync_date = str(batch.get("sync_date") or "").strip()
    if not sync_date:
        return {}
    columns = _permission_dim_columns(combo)
    select_dims = ", ".join(f"r.{column}" for column in columns)
    clauses = ["r.sync_date = %s", "r.user_id IS NOT NULL", "r.user_id <> ''"]
    values: list = [source_id, sync_date]
    if filters.get("first_bbk_id"):
        clauses.append("r.first_bbk_id = %s")
        values.append(filters["first_bbk_id"])
    if filters.get("org_id"):
        clauses.append("r.org_id = %s")
        values.append(filters["org_id"])
    if filters.get("user_id"):
        clauses.append("r.user_id = %s")
        values.append(filters["user_id"])
    group_by = f" GROUP BY {', '.join(columns)}" if columns else ""
    dims_select = select_dims or "'' AS dummy"
    sql = (
        f"SELECT {dims_select}, "
        "COUNT(DISTINCT i.tenant_id) AS permission_manager_count "
        "FROM jkh_user_inf r "
        "LEFT JOIN swe_tenant_init_source i "
        "ON i.tenant_id = r.user_id AND i.source_id = %s "
        f"WHERE {' AND '.join(clauses)}{group_by}"
    )
    rows = await db.fetch_all(sql, tuple(values))
    counts: dict[tuple, int] = {}
    for row in rows:
        key = tuple(str(row.get(column) or "") for column in columns)
        counts[key] = _int(row.get("permission_manager_count"))
    return counts


def _to_row(
    record: dict, combo: str, permission_counts: dict
) -> TaskTypeReportRow:
    """落盘行还原成接口行：不适用维度置 null，空串名称还原成 null。"""
    dims = COMBO_DIM_COLUMNS[combo]
    has_bbk = "first_bbk_id" in dims
    has_org = "org_id" in dims
    has_user = "user_id" in dims
    has_skill = "skill_id" in dims
    task_type = str(record.get("task_type") or "")
    return TaskTypeReportRow(
        first_bbk_id=record.get("first_bbk_id") if has_bbk else None,
        first_bbk_name=_text(record.get("first_bbk_nm")) if has_bbk else None,
        org_id=record.get("org_id") if has_org else None,
        org_name=_text(record.get("org_nm")) if has_org else None,
        user_id=record.get("user_id") if has_user else None,
        user_name=_text(record.get("user_name")) if has_user else None,
        sapid=record.get("user_id") if has_user else None,
        pst_lvl=_text(record.get("pst_lvl")) if has_user else None,
        skill_id=record.get("skill_id") if has_skill else None,
        cn_name=_text(record.get("cn_name")) if has_skill else None,
        task_type=task_type,
        task_type_name=_text(record.get("task_type_name"))
        or TASK_TYPE_LABELS.get(task_type, task_type),
        skill_count=_int(record.get("skill_cnt")),
        permission_manager_count=permission_counts.get(
            _permission_key(record, combo), 0
        ),
        active_manager_count=_optional_int(record.get("active_manager_cnt")),
        suc_execute_job=_int(record.get("suc_execute_job")),
        read_tasks=_int(record.get("read_tasks")),
        read_rate=_optional_float(record.get("read_rate")),
        recommended_customers=_optional_int(
            record.get("recommended_customers")
        ),
        read_customer_count=_optional_int(record.get("read_customer_cnt")),
        plan_read_rate=_optional_float(record.get("plan_read_rate")),
        insight_customer_count=_optional_int(
            record.get("insight_customer_count")
        ),
        click_to_insight_rate=_optional_float(
            record.get("click_to_insight_rate")
        ),
        insight_count=_optional_int(record.get("insight_cnt")),
        phone_customer_count=_optional_int(record.get("phone_customer_cnt")),
        click_to_phone_rate=_optional_float(record.get("click_to_phone_rate")),
        phone_count=_optional_int(record.get("phone_cnt")),
    )


def build_warnings(
    params: SnapshotReportParams,
    matched: bool,
    total: int,
    truncated: bool,
) -> list[str]:
    """固定顺序：期间口径、快照口径、技能明细、无匹配、截断。"""
    warnings = [PERIOD_RATIOS, SNAPSHOT_WINDOW]
    if params.skill_detail:
        warnings.append(SKILL_ROWS_NOT_ADDITIVE)
    if not matched:
        warnings.append(NO_MATCHING_ORGANIZATION)
    elif total == 0:
        warnings.append(
            NO_MATCHING_SKILLS
            if params.skill_detail
            else NO_MATCHING_ORGANIZATION
        )
    if truncated:
        warnings.append(ROWS_TRUNCATED)
    return warnings


def build_response(
    *,
    params: SnapshotReportParams,
    source_id: str,
    combo: str,
    batch: dict,
    filters: dict,
    matched: bool,
    items: list[TaskTypeReportRow],
    total: int,
    truncated: bool,
) -> SnapshotReportResponse:
    return SnapshotReportResponse(
        source_id=source_id,
        prt_dt=params.end_date,
        start_date=params.stat_start_date,
        end_date=params.end_date,
        group_by=params.group_by,
        skill_detail=params.skill_detail,
        rpt_combo=combo,
        sync_date=_text(batch.get("sync_date")),
        resolved_filters=ResolvedReportFilters(
            first_bbk_id=filters.get("first_bbk_id"),
            org_id=filters.get("org_id"),
        ),
        warnings=build_warnings(params, matched, total, truncated),
        batch=_batch_info(batch),
        items=items,
        page=params.page,
        page_size=params.page_size,
        total=total,
        has_more=bool(
            params.page is not None and params.page * params.page_size < total
        ),
    )


class TaskTypeSnapshotService:
    """落盘快照报表服务；请求状态都是局部变量。"""

    async def get_report(
        self,
        params: SnapshotReportParams,
        source_id: str,
        bbk_id: str,
        *,
        max_rows: int = MAX_REPORT_ROWS,
    ) -> SnapshotReportResponse:
        """主查询：批次校验 → 范围校验 → 过滤分页 → 行装配。"""
        params = enforce_branch(params, bbk_id)
        db = report_db()
        combo = combo_of(params)
        batch = _require_ready(
            await _load_batch(db, params.end_date, source_id),
            params.end_date,
            source_id,
        )
        matched, filters = await _resolve_scope(db, batch, params)
        validate_filter_scope(params.group_by, filters, params.user_id)
        if not matched:
            return build_response(
                params=params,
                source_id=source_id,
                combo=combo,
                batch=batch,
                filters=filters,
                matched=False,
                items=[],
                total=0,
                truncated=False,
            )
        where, values = build_filters(params, source_id, combo, filters)
        rows, total, truncated = await _collect_rows(
            db, params, where, values, combo, max_rows
        )
        filters = dict(filters)
        filters["user_id"] = params.user_id
        permission_counts = await _fetch_permission_counts(
            db, batch, source_id, combo, filters
        )
        items = [_to_row(row, combo, permission_counts) for row in rows]
        return build_response(
            params=params,
            source_id=source_id,
            combo=combo,
            batch=batch,
            filters=filters,
            matched=True,
            items=items,
            total=total,
            truncated=truncated,
        )

    async def get_dates(
        self, source_id: str, month: str | None = None, limit: int = 30
    ) -> SnapshotDatesResponse:
        """可用跑数日期，按日期倒序，供前端默认选最新就绪批次。"""
        db = report_db()
        clauses = ["source_id = %s"]
        values: list = [source_id]
        if month:
            start, stop = _month_bounds(month)
            clauses.append("prt_dt >= %s")
            values.append(start)
            clauses.append("prt_dt < %s")
            values.append(stop)
        rows = await db.fetch_all(
            f"SELECT {BATCH_COLUMNS} FROM swe_task_type_report_batch "
            f"WHERE {' AND '.join(clauses)} "
            "ORDER BY prt_dt DESC LIMIT %s",
            tuple(values + [limit]),
        )
        items = [
            SnapshotDateItem(
                prt_dt=_as_date(row.get("prt_dt")),
                status=str(row.get("status") or ""),
                stat_start_dt=_as_date(row.get("stat_start_dt")),
                stat_end_dt=_as_date(row.get("stat_end_dt")),
                row_total=_int(row.get("row_total")),
                loaded_at=row.get("loaded_at"),
            )
            for row in rows
        ]
        latest = next(
            (item.prt_dt for item in items if item.status.lower() == "ready"),
            None,
        )
        return SnapshotDatesResponse(
            source_id=source_id, latest_ready_prt_dt=latest, items=items
        )

    async def get_status(
        self, params: SnapshotReportParams, source_id: str, bbk_id: str
    ) -> SnapshotStatusResponse:
        """批次就绪情况与七个组合的行数，供调度和运维核对出仓是否完整。"""
        enforce_branch(params, bbk_id)
        db = report_db()
        batch = _require_ready(
            await _load_batch(db, params.end_date, source_id),
            params.end_date,
            source_id,
        )
        rows = await db.fetch_all(
            "SELECT rpt_combo, COUNT(*) AS row_cnt "
            "FROM swe_task_type_report_snapshot "
            "WHERE prt_dt = %s AND source_id = %s GROUP BY rpt_combo",
            (params.end_date.isoformat(), source_id),
        )
        counts = [
            SnapshotComboCount(
                rpt_combo=str(row.get("rpt_combo") or ""),
                row_cnt=_int(row.get("row_cnt")),
            )
            for row in rows
        ]
        present = {item.rpt_combo for item in counts}
        return SnapshotStatusResponse(
            batch=_batch_info(batch),
            combo_counts=counts,
            missing_combos=[
                combo for combo in EXPECTED_COMBOS if combo not in present
            ],
        )

    async def get_options(
        self,
        params: ReportOptionsParams,
        source_id: str,
        bbk_id: str,
    ) -> ReportOptionsResponse:
        """分行/支行下拉选项，名单快照日取该批次出仓时使用的日期。"""
        params = enforce_branch(params, bbk_id)
        if params.kind == "orgs" and params.first_bbk_id is None:
            raise ReportError(
                422, "report_branch_required", "查询支行选项必须指定分行。"
            )
        db = report_db()
        batch = _require_ready(
            await _load_batch(db, params.end_date, source_id),
            params.end_date,
            source_id,
        )
        sync_date = str(batch.get("sync_date") or "").strip()
        if not sync_date:
            raise ReportError(
                409,
                SNAPSHOT_NOT_READY_CODE,
                "批次缺少名单快照日，无法提供机构选项。",
            )
        id_column, name_column = OPTION_COLUMNS[params.kind]
        clauses = ["sync_date = %s"]
        values: list = [sync_date]
        if params.first_bbk_id:
            clauses.append("first_bbk_id = %s")
            values.append(params.first_bbk_id)
        rows = await db.fetch_all(
            f"SELECT {id_column} AS value, "
            f"COALESCE(MIN(NULLIF({name_column}, '')), {id_column}) AS label "
            f"FROM jkh_user_inf WHERE {' AND '.join(clauses)} "
            f"AND {id_column} IS NOT NULL AND TRIM({id_column}) <> '' "
            f"GROUP BY {id_column} ORDER BY {id_column}",
            tuple(values),
        )
        return ReportOptionsResponse(
            sync_date=sync_date,
            items=[
                ReportOption(
                    value=str(row.get("value") or ""),
                    label=str(row.get("label") or row.get("value") or ""),
                )
                for row in rows
            ],
        )


def get_task_type_snapshot_service() -> TaskTypeSnapshotService:
    return TaskTypeSnapshotService()
