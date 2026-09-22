# -*- coding: utf-8 -*-
"""金葵花任务类型报表（落盘快照）接口。

数据来自高斯预聚合（AALC_P_RM_CLAW_LIST_USE_IND_STAT）后装载到 TDSQL 的
swe_rm_claw_list_ind_stat，
覆盖在线 /task-type-report 与 /task-type-report/export 的全部查询、导出能力，
并补充可用跑数日期与批次状态两个运维接口。错误码、请求头与出参结构与在线接口
保持一致，前端切换时只需要换 URL 与日期参数。
"""

import asyncio
import re
from typing import Annotated
from urllib.parse import quote

from fastapi import APIRouter, Depends, Header, Query
from fastapi.exceptions import RequestValidationError
from fastapi.responses import Response
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from ..models.task_type_report import (
    ReportGroupBy,
    ReportOptionsParams,
    ReportOptionsResponse,
    ReportSource,
    ReportTaskType,
)
from ..models.task_type_snapshot import (
    SnapshotDatesResponse,
    SnapshotReportParams,
    SnapshotReportResponse,
    SnapshotStatusResponse,
)
from ..services.cron.task_type_report import ReportError
from ..services.cron.task_type_report_export import (
    MAX_EXPORT_ROWS,
    XLSX_MEDIA_TYPE,
    export_task_type_report,
)
from ..services.report.task_type_snapshot import (
    TaskTypeSnapshotService,
    get_task_type_snapshot_service,
)

from .task_type_report import ReportRoute, report_errors

# 挂回 /monitor/cron 前缀：网关只把 /api/monitor/cron/* 转发给本服务，
# 独立前缀 /monitor/report 会 404（旧在线接口同样在 cron 前缀下）。
router = APIRouter(
    prefix="/monitor/report", tags=["report"], route_class=ReportRoute
)
REPORT_TIMEOUT_SECONDS = 50
MONTH_PATTERN = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])$")


def _validation_error(errors: list[dict]) -> RequestValidationError:
    return RequestValidationError(
        [{**error, "loc": ("query", *error["loc"])} for error in errors]
    )


def snapshot_filters(
    task_type: ReportTaskType | None = Query(default=None),
    user_id: str | None = Query(default=None, min_length=1, max_length=64),
    keyword: str | None = Query(default=None, max_length=100),
    page: int | None = Query(default=None, ge=1),
    page_size: int | None = Query(default=None, ge=1, le=100),
) -> dict:
    return dict(
        task_type=task_type,
        user_id=user_id,
        keyword=keyword,
        page=page,
        page_size=page_size,
    )


def snapshot_dimensions(
    filters: dict = Depends(snapshot_filters),
    group_by: ReportGroupBy = Query(default="overall"),
    skill_detail: bool = Query(
        default=False, description="按技能 ID 展开指标"
    ),
) -> dict:
    return {"group_by": group_by, "skill_detail": skill_detail, **filters}


def snapshot_params(
    end_date: str = Query(description="跑数日期 YYYY-MM-DD，等于统计截止日"),
    start_date: str | None = Query(
        default=None,
        description="统计起始日，只支持当月 1 号；缺省取跑数日期当月 1 号",
    ),
    dimensions: dict = Depends(snapshot_dimensions),
    first_bbk_id: str | None = Query(default=None, max_length=64),
    first_bbk_name: str | None = Query(default=None, max_length=256),
    org_id: str | None = Query(default=None, max_length=64),
    org_name: str | None = Query(default=None, max_length=256),
) -> SnapshotReportParams:
    try:
        return SnapshotReportParams(
            end_date=end_date,
            start_date=start_date,
            **dimensions,
            first_bbk_id=first_bbk_id,
            first_bbk_name=first_bbk_name,
            org_id=org_id,
            org_name=org_name,
        )
    except ValidationError as exc:
        raise _validation_error(exc.errors(include_context=False)) from exc


@router.get("/task-type", response_model=SnapshotReportResponse)
async def task_type_snapshot_report(
    params: Annotated[SnapshotReportParams, Depends(snapshot_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeSnapshotService, Depends(get_task_type_snapshot_service)
    ],
) -> SnapshotReportResponse:
    """落盘快照主查询；参数语义与在线接口一致，区间收窄到当月。"""
    async with report_errors():
        return await asyncio.wait_for(
            service.get_report(params, source_id, bbk_id),
            timeout=REPORT_TIMEOUT_SECONDS,
        )


@router.get("/task-type/export", response_class=Response)
async def task_type_snapshot_export(
    params: Annotated[SnapshotReportParams, Depends(snapshot_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeSnapshotService, Depends(get_task_type_snapshot_service)
    ],
) -> Response:
    """全量 XLSX 导出；必须指定 task_type，不能传分页参数。"""
    async with report_errors():
        if params.task_type is None or params.page is not None:
            raise ReportError(
                422,
                "report_export_parameters",
                "导出须指定 task_type，且不能传分页参数。",
            )
        report = await asyncio.wait_for(
            service.get_report(
                params, source_id, bbk_id, max_rows=MAX_EXPORT_ROWS + 1
            ),
            timeout=REPORT_TIMEOUT_SECONDS,
        )
        content = await run_in_threadpool(
            export_task_type_report, report, params.task_type
        )
        filename = quote(
            f"Claw报表_{report.start_date}_{report.end_date}.xlsx"
        )
        return Response(
            content,
            media_type=XLSX_MEDIA_TYPE,
            headers={
                "Content-Disposition": (
                    f"attachment; filename*=UTF-8''{filename}"
                ),
                "Access-Control-Expose-Headers": "Content-Disposition",
            },
        )


def options_params(
    end_date: str = Query(description="跑数日期 YYYY-MM-DD"),
    kind: str = Query(description="branches 或 orgs"),
    first_bbk_id: str | None = Query(default=None, max_length=64),
) -> ReportOptionsParams:
    try:
        return ReportOptionsParams(
            end_date=end_date, kind=kind, first_bbk_id=first_bbk_id
        )
    except ValidationError as exc:
        raise _validation_error(exc.errors(include_context=False)) from exc


@router.get("/task-type/options", response_model=ReportOptionsResponse)
async def task_type_snapshot_options(
    params: Annotated[ReportOptionsParams, Depends(options_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeSnapshotService, Depends(get_task_type_snapshot_service)
    ],
) -> ReportOptionsResponse:
    """分行/支行下拉选项；当天无名单时使用最新一天名单。"""
    async with report_errors():
        return await asyncio.wait_for(
            service.get_options(params, source_id, bbk_id),
            timeout=REPORT_TIMEOUT_SECONDS,
        )


def dates_params(
    month: str | None = Query(
        default=None, description="月份 YYYY-MM，缺省返回最近批次"
    ),
    limit: int = Query(default=30, ge=1, le=90),
) -> tuple[str | None, int]:
    if month is not None and not MONTH_PATTERN.fullmatch(month):
        raise _validation_error(
            [
                {
                    "type": "value_error",
                    "loc": ("month",),
                    "msg": "月份须为 YYYY-MM",
                    "input": month,
                }
            ]
        )
    return month, limit


@router.get("/task-type/dates", response_model=SnapshotDatesResponse)
async def task_type_snapshot_dates(
    params: Annotated[tuple[str | None, int], Depends(dates_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    service: Annotated[
        TaskTypeSnapshotService, Depends(get_task_type_snapshot_service)
    ],
) -> SnapshotDatesResponse:
    """可用跑数日期，供前端默认选中最新就绪批次。"""
    month, limit = params
    async with report_errors():
        return await asyncio.wait_for(
            service.get_dates(source_id, month, limit),
            timeout=REPORT_TIMEOUT_SECONDS,
        )


def status_params(
    end_date: str = Query(description="跑数日期 YYYY-MM-DD"),
) -> SnapshotReportParams:
    try:
        return SnapshotReportParams(end_date=end_date)
    except ValidationError as exc:
        raise _validation_error(exc.errors(include_context=False)) from exc


@router.get("/task-type/status", response_model=SnapshotStatusResponse)
async def task_type_snapshot_status(
    params: Annotated[SnapshotReportParams, Depends(status_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeSnapshotService, Depends(get_task_type_snapshot_service)
    ],
) -> SnapshotStatusResponse:
    """批次就绪情况与七个组合的行数，用于核对出仓是否完整。"""
    async with report_errors():
        return await asyncio.wait_for(
            service.get_status(params, source_id, bbk_id),
            timeout=REPORT_TIMEOUT_SECONDS,
        )
