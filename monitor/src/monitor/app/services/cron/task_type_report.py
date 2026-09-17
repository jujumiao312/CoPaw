# -*- coding: utf-8 -*-
"""金葵花任务类型报表服务。

- 入口：``TaskTypeReportService.get_report`` 完成一次统计查询，统计与导出共用；
  ``get_options`` 提供分行/支行下拉选项。
- 分工：SQL 构造在 ``task_type_report_sql``，行组装与派生比例在
  ``task_type_report_rows``；本模块只负责快照、范围、名称解析和查询编排。
- 排查：INFO 级别输出 ``task_type_report_timing`` 日志。同一个 ``report_id``
  下逐条比较 ``stage`` 的 ``elapsed_ms``，``stage=get_report`` 那行额外给出
  ``stages``、``slowest`` 和 ``slowest_ms``，可直接看到最慢阶段；该日志不含
  SQL、绑定参数和人员信息。
- SQL 排查：本模块执行（且仅限本模块执行）的每条查询另外输出一行
  ``task_type_report_sql``，带 ``query``、``sql`` 和 ``params``；``params``
  包含查询条件本身，只用于核对结果口径，不要对外转发。
- 单类型收窄：``params.task_type`` 会进入 ``Scope``，只执行该类型涉及的查询，
  维度骨架也只取该类型的事实路径；不传 ``task_type`` 时才回到全类型并集和三
  类任务。
"""

import asyncio
import logging
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import replace
from datetime import date, datetime, time, timedelta
from time import perf_counter
from uuid import uuid4

from ...database import get_db_connection
from ...models.task_type_report import (
    ReportOptionsParams,
    ReportOptionsResponse,
    TaskTypeReportParams,
    TaskTypeReportResponse,
)
from .query_service import QueryService

# assemble/percentage 继续从本模块导出，保持路由、导出和测试的导入路径不变。
from .task_type_report_rows import assemble, percentage  # noqa: F401
from .task_type_report_sql import META_QUERY_NAMES, Scope, build_queries

# 响应 warnings：顺序为期间口径、空名单或无匹配、技能明细不可相加。
PERIOD_RATIOS = "period_ratios_not_cohort_conversion"
EMPTY_ROSTER = "empty_roster"
NO_MATCHING_ORGANIZATION = "no_matching_organization"
NO_MATCHING_SKILLS = "no_matching_skills"
SKILL_ROWS_NOT_ADDITIVE = "skill_rows_not_additive"
# 错误码与稳定文案：路由按 code 映射 HTTP，不解析 message。
DATABASE_UNAVAILABLE_CODE = "report_database_unavailable"
DATABASE_UNAVAILABLE_MESSAGE = "报表数据库暂不可用。"
ROSTER_AMBIGUOUS_CODE = "jkh_roster_ambiguous"
ROSTER_AMBIGUOUS_MESSAGE = "名单快照中存在同一用户的多个机构归属。"
SCOPE_FORBIDDEN_CODE = "report_scope_forbidden"
# 互不依赖的事实查询并发上限；设为 1 即退回全部串行。
REPORT_QUERY_CONCURRENCY = 4
# 技能来源日志每条查询最多打印的技能 ID 数。
SKILL_LOG_LIMIT = 30
OPTION_COLUMNS = {
    "branches": ("first_bbk_id", "first_bbk_nm"),
    "orgs": ("org_id", "org_nm"),
}

logger = logging.getLogger(__name__)
_report_id = ContextVar("task_type_report_id", default=None)
_report_stages = ContextVar("task_type_report_stages", default=None)
SQL_LOG_TAG = "task_type_report_sql"


@contextmanager
def _report_stage(stage: str):
    """记录请求关联耗时；不记录 SQL 参数、人员信息和异常正文。"""
    first = _report_id.get() is None
    token = _report_id.set(uuid4().hex) if first else None
    stages_token = _report_stages.set({}) if first else None
    started = perf_counter()
    status = "ok"
    details = {"rows": None}
    try:
        yield details
    except BaseException as exc:
        status = type(exc).__name__
        raise
    finally:
        elapsed_ms = (perf_counter() - started) * 1000
        summary = _record_stage(stage, elapsed_ms, outermost=first)
        logger.info(
            "task_type_report_timing report_id=%s stage=%s elapsed_ms=%.2f status=%s rows=%s%s",
            _report_id.get(),
            stage,
            elapsed_ms,
            status,
            details["rows"],
            summary,
        )
        if stages_token is not None:
            _report_stages.reset(stages_token)
        if token is not None:
            _report_id.reset(token)


def _record_stage(stage: str, elapsed_ms: float, *, outermost: bool) -> str:
    """累计本次请求各阶段耗时；最外层阶段额外返回最慢子阶段的汇总字段。"""
    stages = _report_stages.get()
    if stages is None:
        return ""
    stages[stage] = stages.get(stage, 0.0) + elapsed_ms
    if not outermost:
        return ""
    # 最外层阶段本身就是总耗时，只有它内部的阶段才对定位慢查询有意义。
    inner = {name: ms for name, ms in stages.items() if name != stage}
    if not inner:
        return ""
    slowest = max(inner, key=inner.get)
    slowest_ms = inner[slowest]
    return (
        f" stages={len(stages)} slowest={slowest}"
        f" slowest_ms={slowest_ms:.2f}"
    )


async def _fetch_report_query(db, name: str, query: tuple, *, one=False):
    """执行一条报表查询，记录阶段耗时、返回行数，并打印 SQL 与绑定参数。"""
    sql, values = query
    with _report_stage(name) as details:
        started = perf_counter()
        status, rows = "ok", None
        try:
            result = await (
                db.fetch_one(sql, values) if one else db.fetch_all(sql, values)
            )
        except BaseException as exc:
            status = type(exc).__name__
            raise
        else:
            rows = int(result is not None) if one else len(result)
            details["rows"] = rows
            return result
        finally:
            _log_report_sql(
                name,
                sql,
                values,
                status=status,
                rows=rows,
                elapsed_ms=(perf_counter() - started) * 1000,
            )


def _log_report_sql(
    name: str, sql: str, values, *, status: str, rows, elapsed_ms: float
) -> None:
    """按查询打印 SQL 与绑定参数；只覆盖本模块编排的查询。"""
    if not logger.isEnabledFor(logging.INFO):
        return
    logger.info(
        "%s report_id=%s query=%s elapsed_ms=%.2f status=%s rows=%s sql=%s params=%s",
        SQL_LOG_TAG,
        _report_id.get(),
        name,
        elapsed_ms,
        status,
        rows,
        sql,
        tuple(values or ()),
    )


def _log_skill_sources(results: dict) -> None:
    """按查询打印技能明细来源，用于定位多出来的技能由哪条查询带进来。"""
    if not logger.isEnabledFor(logging.INFO):
        return
    sources = []
    for name, records in results.items():
        if name in META_QUERY_NAMES:
            continue
        skills = sorted(
            {row["skill_id"] for row in records if row.get("skill_id")}
        )
        if not skills:
            continue
        shown = ",".join(skills[:SKILL_LOG_LIMIT])
        more = (
            f"(+{len(skills) - SKILL_LOG_LIMIT})"
            if len(skills) > SKILL_LOG_LIMIT
            else ""
        )
        sources.append(f"{name}={shown}{more}")
    if sources:
        logger.info(
            "%s_sources report_id=%s by_query=%s",
            SQL_LOG_TAG,
            _report_id.get(),
            " ".join(sources),
        )


class ReportError(Exception):
    """只由新报表路由消费的稳定业务错误。"""

    def __init__(self, status_code: int, code: str, message: str):
        super().__init__(message)
        self.status_code = status_code
        self.code = code


def report_db():
    """取现有连接池；不可用时映射为稳定的 503。"""
    try:
        db = get_db_connection()
    except RuntimeError as exc:
        raise ReportError(
            503, DATABASE_UNAVAILABLE_CODE, DATABASE_UNAVAILABLE_MESSAGE
        ) from exc
    if not db.is_connected:
        raise ReportError(
            503, DATABASE_UNAVAILABLE_CODE, DATABASE_UNAVAILABLE_MESSAGE
        )
    return db


def enforce_branch(params, bbk_id: str):
    """使用现有可信网关传入的分行范围；客户端筛选只能收窄。"""
    if (
        not isinstance(bbk_id, str)
        or not bbk_id.strip()
        or len(bbk_id.strip()) > 64
    ):
        raise ReportError(
            422, "report_scope_required", "必须提供有效的 X-Bbk-Id。"
        )
    bbk_id = bbk_id.strip()
    if bbk_id != "100":
        if params.first_bbk_id is not None and params.first_bbk_id != bbk_id:
            raise ReportError(
                403, SCOPE_FORBIDDEN_CODE, "不能查询其他分行的数据。"
            )
        return params.model_copy(update={"first_bbk_id": bbk_id})
    return params


async def validate_roster_scope(
    db, sync_date: str, params: TaskTypeReportParams
):
    """存在但不属于有效分行/网点的 ID 报 403；不存在的 ID 保留空结果。"""
    selectors = (
        ("org_id", params.org_id),
        ("user_id", params.user_id),
        ("first_bbk_nm", params.first_bbk_name),
        ("org_nm", params.org_name),
    )
    for column, value in selectors:
        if value is None:
            continue
        conditions, allowed_params = [], []
        if params.first_bbk_id is not None:
            conditions.append("first_bbk_id = %s")
            allowed_params.append(params.first_bbk_id)
        if column == "user_id" and params.org_id is not None:
            conditions.append("org_id = %s")
            allowed_params.append(params.org_id)
        if not conditions:
            continue
        allowed = " AND ".join(conditions)
        row = await _fetch_report_query(
            db,
            "scope_check",
            (
                f"SELECT COUNT(*) AS total, SUM(CASE WHEN {allowed} THEN 1 ELSE 0 END) AS allowed "
                f"FROM jkh_user_inf WHERE sync_date = %s AND {column} = %s",
                tuple(allowed_params + [sync_date, value]),
            ),
            one=True,
        )
        if row and row["total"] and not row["allowed"]:
            raise ReportError(
                403,
                SCOPE_FORBIDDEN_CODE,
                "所选机构或客户经理不属于允许的查询范围。",
            )


async def resolve_organization_filters(
    db, sync_date: str, params: TaskTypeReportParams
) -> tuple[bool, dict[str, str | None]]:
    """同一快照内精确解析名称，显式区分无匹配和未筛选。"""
    resolved = {"first_bbk_id": params.first_bbk_id, "org_id": params.org_id}
    # 只遍历两个固定层级，机构数量不会扩大查询次数。
    for name, name_column, id_columns in (
        (params.first_bbk_name, "first_bbk_nm", ("first_bbk_id",)),
        (params.org_name, "org_nm", ("first_bbk_id", "org_id")),
    ):
        if name is None:
            continue
        conditions = ["sync_date = %s", f"{name_column} = %s"]
        values = [sync_date, name]
        for column in id_columns:
            conditions.extend([f"{column} IS NOT NULL", f"{column} <> ''"])
            if resolved[column] is not None:
                conditions.append(f"{column} = %s")
                values.append(resolved[column])
        sql = (
            f"SELECT DISTINCT {', '.join(id_columns)} FROM jkh_user_inf "
            f"WHERE {' AND '.join(conditions)} LIMIT 2"
        )
        rows = await _fetch_report_query(
            db, "resolve_filter", (sql, tuple(values))
        )
        if not rows:
            return False, resolved
        if len(rows) > 1:
            raise ReportError(
                422,
                "organization_name_ambiguous",
                "机构名称对应多个机构，请同时提供父分行或机构 ID。",
            )
        resolved.update(rows[0])
    return True, resolved


async def _assert_unique_roster(db, query: tuple, *, stage: str):
    """同一用户多个机构归属时整份报表失败；空页也不能跳过该校验。"""
    conflicts = await _fetch_report_query(db, stage, query)
    if conflicts:
        raise ReportError(503, ROSTER_AMBIGUOUS_CODE, ROSTER_AMBIGUOUS_MESSAGE)


async def _run_queries(db, queries: dict, *, concurrency: int) -> dict:
    """受限并发执行互不依赖的聚合查询。

    任一查询失败都让整份报表失败；为了留下完整的分阶段诊断，这里会等
    所有查询结束后再抛出第一个异常，不返回部分指标。
    """
    semaphore = asyncio.Semaphore(max(1, concurrency))

    async def run(name: str, query: tuple):
        async with semaphore:
            return name, await _fetch_report_query(db, name, query)

    tasks = [
        asyncio.create_task(run(name, query))
        for name, query in queries.items()
    ]
    completed = await asyncio.gather(*tasks, return_exceptions=True)
    for item in completed:
        if isinstance(item, BaseException):
            raise item
    return dict(completed)


async def query_core(
    db,
    scope: Scope,
    *,
    concurrency: int = REPORT_QUERY_CONCURRENCY,
    assert_roster: bool = True,
) -> list[dict]:
    """db 使用现有 DatabaseConnection；空快照应在调用此函数之前处理。

    ``assert_roster`` 为假时跳过名单唯一性校验，供调用方（分页）在同样的
    全快照查询上先行校验过的情况使用。
    """
    queries = build_queries(scope)
    if assert_roster:
        await _assert_unique_roster(
            db, queries["roster_conflicts"], stage="roster_conflicts"
        )
    facts = {
        name: query
        for name, query in queries.items()
        if name not in META_QUERY_NAMES
    }
    results = await _run_queries(db, facts, concurrency=concurrency)
    dimension_keys = {
        (row["group_bbk"], row["group_org"], row.get("group_user", ""))
        for records in results.values()
        for row in records
    }
    if not dimension_keys:
        return []
    permission_query = build_queries(
        scope, permission_keys=tuple(dimension_keys)
    )["permissions"]
    results["permissions"] = await _fetch_report_query(
        db, "permissions", permission_query
    )
    if scope.skill_detail:
        _log_skill_sources(results)
    with _report_stage("assemble") as details:
        rows = assemble(
            results, scope.group_by, scope.skill_detail, scope.task_type
        )
        details["rows"] = len(rows)
        return rows


async def _fetch_page_total(db, key_sql: str, values: tuple) -> int:
    row = await _fetch_report_query(
        db,
        "page_count",
        (f"SELECT COUNT(*) AS total FROM ({key_sql}) dimension_keys", values),
        one=True,
    )
    return int(row["total"] or 0)


async def _fetch_page_keys(
    db, key_sql: str, values: tuple, params: TaskTypeReportParams, offset: int
) -> list[dict]:
    return await _fetch_report_query(
        db,
        "page_keys",
        (
            f"SELECT * FROM ({key_sql}) dimension_keys ORDER BY "
            "group_bbk IS NOT NULL, COALESCE(group_bbk, ''), "
            "group_org IS NOT NULL, COALESCE(group_org, ''), group_user, skill_id "
            "LIMIT %s OFFSET %s",
            values + (params.page_size, offset),
        ),
    )


async def query_page(
    db,
    scope: Scope,
    params: TaskTypeReportParams,
    *,
    concurrency: int = REPORT_QUERY_CONCURRENCY,
):
    """经理/技能分页：并发取事实键总数与本页键，再按本页键执行聚合查询。"""
    queries = build_queries(scope)
    # 检查全快照冲突，空页也不能跳过该校验。
    await _assert_unique_roster(
        db, queries["roster_conflicts"], stage="page_roster_conflicts"
    )
    key_sql, values = build_queries(scope, keys_only=True)["keys"]
    offset = (params.page - 1) * params.page_size
    # 总数与本页键互不依赖，共用一个键子查询，并发取回可省掉一次完整等待。
    total, page_keys = await asyncio.gather(
        _fetch_page_total(db, key_sql, values),
        _fetch_page_keys(db, key_sql, values, params, offset),
    )
    if offset >= total or not page_keys:
        return [], total
    scoped_page = replace(
        scope,
        manager_keys=tuple(
            (row["group_user"], row["skill_id"]) for row in page_keys
        ),
    )
    # 名单唯一性校验与 page_roster_conflicts 是同一条全快照查询，不再重复执行。
    return (
        await query_core(
            db, scoped_page, concurrency=concurrency, assert_roster=False
        ),
        total,
    )


async def _resolve_snapshot(db, params: TaskTypeReportParams) -> str | None:
    """名单快照按截止日、月末、最早/最新回退；无快照时不再查事实。"""
    with _report_stage("resolve_snapshot"):
        return await QueryService._resolve_jkh_sync_date(
            db, datetime.combine(params.end_date, time.max)
        )


async def _resolve_scope(
    db, sync_date: str, params: TaskTypeReportParams
) -> tuple[bool, dict]:
    """校验可信范围并解析机构名称；解析出 ID 时再校验一次范围。"""
    with _report_stage("validate_scope"):
        await validate_roster_scope(db, sync_date, params)
    with _report_stage("resolve_filters"):
        matched, filters = await resolve_organization_filters(
            db, sync_date, params
        )
    if matched and (
        filters["first_bbk_id"] != params.first_bbk_id
        or filters["org_id"] != params.org_id
    ):
        with _report_stage("validate_resolved_scope"):
            await validate_roster_scope(
                db, sync_date, params.model_copy(update=filters)
            )
    return matched, filters


def date_bounds(start_date: date, end_date: date) -> tuple[datetime, datetime]:
    """日期首尾均包含；数据库查询统一使用半开区间。"""
    return datetime.combine(start_date, time.min), datetime.combine(
        end_date + timedelta(days=1), time.min
    )


def _build_scope(
    params: TaskTypeReportParams, source_id: str, sync_date: str, filters: dict
) -> Scope:
    start, stop = date_bounds(params.start_date, params.end_date)
    return Scope(
        source_id=source_id,
        sync_date=sync_date,
        start=start,
        stop=stop,
        group_by=params.group_by,
        task_type=params.task_type,
        skill_detail=params.skill_detail,
        user_id=params.user_id,
        keyword=params.keyword,
        **filters,
    )


def _unresolved_filters(params: TaskTypeReportParams) -> dict:
    """未经名称解析时的原始筛选范围。"""
    return {"first_bbk_id": params.first_bbk_id, "org_id": params.org_id}


def _warnings(
    params: TaskTypeReportParams,
    sync_date: str | None,
    matched: bool,
    items: list[dict],
    total: int | None,
) -> list[str]:
    """固定顺序：期间口径、空名单或无匹配、技能明细不可相加。"""
    warnings = [PERIOD_RATIOS]
    if sync_date is None:
        warnings.append(EMPTY_ROSTER)
    elif not items and not total:
        warnings.append(
            NO_MATCHING_SKILLS
            if matched and params.skill_detail
            else NO_MATCHING_ORGANIZATION
        )
    if params.skill_detail:
        warnings.append(SKILL_ROWS_NOT_ADDITIVE)
    return warnings


def _build_response(
    *,
    params: TaskTypeReportParams,
    source_id: str,
    sync_date: str | None,
    filters: dict,
    items: list[dict],
    total: int | None,
    warnings: list[str],
) -> TaskTypeReportResponse:
    """统一填充元数据、任务类型过滤和分页信息。"""
    if params.task_type is not None:
        items = [
            item for item in items if item["task_type"] == params.task_type
        ]
    if total is None:
        total = len(items)
    return TaskTypeReportResponse(
        start_date=params.start_date,
        end_date=params.end_date,
        source_id=source_id,
        sync_date=sync_date,
        group_by=params.group_by,
        skill_detail=params.skill_detail,
        resolved_filters=filters,
        warnings=warnings,
        items=items,
        page=params.page,
        page_size=params.page_size,
        total=total,
        has_more=(
            params.page is not None and params.page * params.page_size < total
        ),
    )


async def _fetch_options(
    db, params: ReportOptionsParams, sync_date: str
) -> list[dict]:
    """按 kind 选择 ID/名称列，只返回快照内非空的机构。"""
    id_column, name_column = OPTION_COLUMNS[params.kind]
    conditions, values = ["sync_date = %s"], [sync_date]
    if params.first_bbk_id is not None:
        conditions.append("first_bbk_id = %s")
        values.append(params.first_bbk_id)
    return await _fetch_report_query(
        db,
        "options",
        (
            f"SELECT {id_column} AS value, "
            f"COALESCE(MIN(NULLIF({name_column}, '')), {id_column}) AS label "
            f"FROM jkh_user_inf WHERE {' AND '.join(conditions)} "
            f"AND {id_column} IS NOT NULL AND TRIM({id_column}) <> '' "
            f"GROUP BY {id_column} ORDER BY {id_column}",
            tuple(values),
        ),
    )


class TaskTypeReportService:
    """请求状态均为局部变量；统计、选项、导出共用快照和范围规则。"""

    def __init__(self, concurrency: int = REPORT_QUERY_CONCURRENCY):
        # 事实查询并发上限；调小可降低数据库瞬时压力，设为 1 即串行。
        self._concurrency = max(1, concurrency)

    async def get_report(
        self, params: TaskTypeReportParams, source_id: str, bbk_id: str
    ) -> TaskTypeReportResponse:
        """统计主流程：可信范围 → 名单快照 → 名称解析 → 聚合 → 组装。"""
        with _report_stage("get_report") as details:
            params = enforce_branch(params, bbk_id)
            db = report_db()
            sync_date = await _resolve_snapshot(db, params)
            matched = False
            filters = _unresolved_filters(params)
            items, total = [], None
            if sync_date is not None:
                matched, filters = await _resolve_scope(db, sync_date, params)
                if matched:
                    scope = _build_scope(params, source_id, sync_date, filters)
                    items, total = await self._collect(db, scope, params)
            response = _build_response(
                params=params,
                source_id=source_id,
                sync_date=sync_date,
                filters=filters,
                items=items,
                total=total,
                warnings=_warnings(params, sync_date, matched, items, total),
            )
            details["rows"] = len(response.items)
            return response

    async def _collect(
        self, db, scope: Scope, params: TaskTypeReportParams
    ) -> tuple[list[dict], int | None]:
        """分页请求走 page 路径，其余请求一次性取全量分组。"""
        if params.page is not None:
            return await query_page(
                db, scope, params, concurrency=self._concurrency
            )
        rows = await query_core(db, scope, concurrency=self._concurrency)
        return rows, None

    async def get_options(
        self, params: ReportOptionsParams, source_id: str, bbk_id: str
    ) -> ReportOptionsResponse:
        """分行/支行下拉选项；与统计接口共用快照解析和分行范围规则。"""
        params = enforce_branch(params, bbk_id)
        if params.kind == "orgs" and params.first_bbk_id is None:
            raise ReportError(
                422, "report_branch_required", "查询支行选项必须指定分行。"
            )
        db = report_db()
        sync_date = await QueryService._resolve_jkh_sync_date(
            db, datetime.combine(params.end_date, time.max)
        )
        if sync_date is None:
            return ReportOptionsResponse(sync_date=None, items=[])
        items = await _fetch_options(db, params, sync_date)
        return ReportOptionsResponse(sync_date=sync_date, items=items)


def get_task_type_report_service() -> TaskTypeReportService:
    return TaskTypeReportService()
