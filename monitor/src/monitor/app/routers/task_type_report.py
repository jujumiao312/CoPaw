# -*- coding: utf-8 -*-
"""独立的金葵花任务类型统计接口。"""

import asyncio
import logging
from contextlib import asynccontextmanager
from urllib.parse import quote
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool
from pydantic import ValidationError

from ..models.task_type_report import (
    ReportGroupBy,
    ReportTaskType,
    ReportOptionsParams,
    ReportOptionsResponse,
    ReportSource,
    TaskTypeReportParams,
    TaskTypeReportResponse,
)
from ..services.cron.task_type_report import (
    ReportError,
    TaskTypeReportService,
    get_task_type_report_service,
)

from ..services.cron.task_type_report_export import (
    XLSX_MEDIA_TYPE,
    export_task_type_report,
)

logger = logging.getLogger(__name__)


class ReportRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def validated(request):
            try:
                return await handler(request)
            except RequestValidationError as exc:
                raise HTTPException(
                    422,
                    detail={
                        "code": "report_validation_error",
                        "message": "参数校验失败，请检查必填请求头、日期、范围及分页参数。",
                    },
                ) from exc

        return validated


router = APIRouter(
    prefix="/monitor/cron", tags=["cron"], route_class=ReportRoute
)
REPORT_TIMEOUT_SECONDS = 30


def report_filters(
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


def report_dimensions(
    filters: dict = Depends(report_filters),
    group_by: ReportGroupBy = Query(default="overall"),
    skill_detail: bool = Query(
        default=False, description="按技能 ID 展开指标"
    ),
) -> dict:
    return {"group_by": group_by, "skill_detail": skill_detail, **filters}


def report_params(
    start_date: str = Query(description="开始日期 YYYY-MM-DD"),
    end_date: str = Query(description="结束日期 YYYY-MM-DD，包含当天"),
    dimensions: dict = Depends(report_dimensions),
    first_bbk_id: str | None = Query(default=None, max_length=64),
    first_bbk_name: str | None = Query(default=None, max_length=256),
    org_id: str | None = Query(default=None, max_length=64),
    org_name: str | None = Query(default=None, max_length=256),
) -> TaskTypeReportParams:
    """局部映射跨字段校验错误，保持旧路由的错误处理不变。"""
    try:
        return TaskTypeReportParams(
            start_date=start_date,
            end_date=end_date,
            **dimensions,
            first_bbk_id=first_bbk_id,
            first_bbk_name=first_bbk_name,
            org_id=org_id,
            org_name=org_name,
        )
    except ValidationError as exc:
        errors = [
            {**error, "loc": ("query", *error["loc"])}
            for error in exc.errors(include_context=False)
        ]
        raise RequestValidationError(errors) from exc


@asynccontextmanager
async def report_errors():
    try:
        yield
    except HTTPException:
        raise
    except ReportError as exc:
        raise HTTPException(
            exc.status_code, detail={"code": exc.code, "message": str(exc)}
        ) from exc
    except asyncio.TimeoutError as exc:
        raise HTTPException(
            504,
            detail={
                "code": "report_query_timeout",
                "message": "报表查询超时，请缩小时间或机构范围。",
            },
        ) from exc
    except Exception as exc:
        logger.exception("Task type report query failed")
        raise HTTPException(
            500,
            detail={
                "code": "report_query_failed",
                "message": "报表查询失败，请稍后重试。",
            },
        ) from exc


@router.get("/task-type-report", response_model=TaskTypeReportResponse)
async def task_type_report(
    params: Annotated[TaskTypeReportParams, Depends(report_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeReportService, Depends(get_task_type_report_service)
    ],
) -> TaskTypeReportResponse:
    async with report_errors():
        return await asyncio.wait_for(
            service.get_report(params, source_id, bbk_id),
            timeout=REPORT_TIMEOUT_SECONDS,
        )


def options_params(
    end_date: str = Query(),
    kind: str = Query(),
    first_bbk_id: str | None = Query(default=None),
) -> ReportOptionsParams:
    try:
        return ReportOptionsParams(
            end_date=end_date, kind=kind, first_bbk_id=first_bbk_id
        )
    except ValidationError as exc:
        raise RequestValidationError(
            exc.errors(include_context=False)
        ) from exc


@router.get("/task-type-report/options", response_model=ReportOptionsResponse)
async def task_type_report_options(
    params: Annotated[ReportOptionsParams, Depends(options_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeReportService, Depends(get_task_type_report_service)
    ],
) -> ReportOptionsResponse:
    async with report_errors():
        return await asyncio.wait_for(
            service.get_options(params, source_id, bbk_id),
            timeout=REPORT_TIMEOUT_SECONDS,
        )


@router.get("/task-type-report/export", response_class=Response)
async def task_type_report_export(
    params: Annotated[TaskTypeReportParams, Depends(report_params)],
    source_id: Annotated[ReportSource, Header(alias="X-Source-Id")],
    bbk_id: Annotated[ReportSource, Header(alias="X-Bbk-Id")],
    service: Annotated[
        TaskTypeReportService, Depends(get_task_type_report_service)
    ],
) -> Response:
    async with report_errors():
        if params.task_type is None or params.page is not None:
            raise ReportError(
                422,
                "report_export_parameters",
                "导出须指定 task_type，且不能传分页参数。",
            )
        report = await asyncio.wait_for(
            service.get_report(params, source_id, bbk_id),
            timeout=REPORT_TIMEOUT_SECONDS,
        )
        content = await run_in_threadpool(
            export_task_type_report, report, params.task_type
        )
        filename = quote(
            f"Claw报表_{params.start_date}_{params.end_date}.xlsx"
        )
        return Response(
            content,
            media_type=XLSX_MEDIA_TYPE,
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{filename}",
                "Access-Control-Expose-Headers": "Content-Disposition",
            },
        )
