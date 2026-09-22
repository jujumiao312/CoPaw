# -*- coding: utf-8 -*-
"""金葵花任务类型报表（落盘快照）请求与响应契约。

数据来源是高斯预聚合（AALC_P_RM_CLAW_LIST_USE_IND_STAT）后装载到 TDSQL 的
swe_rm_claw_list_ind_stat，
口径定义仍在 DESIGN.md / DIMENSIONS.md；行结构复用在线接口的
``TaskTypeReportRow``，前端从在线接口切到落盘接口时字段不用改。

与在线接口的差别：只支持“当月 1 号 ~ 跑数日期”的区间（落盘表就是这个口径），
机构筛选必须与组合维度匹配，详见 docs/superpowers/specs/2026-09-18-task-type-report-snapshot/API.md。
"""

from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, model_validator

from .task_type_report import (
    OrganizationId,
    OrganizationName,
    ReportDate,
    ReportGroupBy,
    ReportTaskType,
    ResolvedReportFilters,
    TaskTypeReportRow,
)

SNAPSHOT_METRIC_VERSION = "jkh_task_report_v1_snapshot"
Keyword = Annotated[
    str, StringConstraints(strip_whitespace=True, max_length=100)
]


class SnapshotReportParams(BaseModel):
    """落盘快照报表查询参数；语义与在线接口一致，区间收窄到当月。"""

    end_date: ReportDate
    start_date: ReportDate | None = None
    group_by: ReportGroupBy = "overall"
    skill_detail: bool = False
    task_type: ReportTaskType | None = None
    first_bbk_id: OrganizationId | None = None
    first_bbk_name: OrganizationName | None = None
    org_id: OrganizationId | None = None
    org_name: OrganizationName | None = None
    user_id: OrganizationId | None = None
    keyword: Keyword | None = None
    page: Annotated[int, Field(ge=1)] | None = None
    page_size: Annotated[int, Field(ge=1, le=100)] | None = None

    @model_validator(mode="after")
    def validate_snapshot_scope(self):
        """校验区间与组合规则，错误在路由层映射为 422。"""
        if self.end_date == date.max:
            raise ValueError("结束日期须早于 9999-12-31")
        if self.skill_detail and self.group_by == "overall":
            raise ValueError("技能明细须选择分行、支行或客户经理维度")
        if self.keyword and self.group_by != "manager":
            raise ValueError("关键字仅用于客户经理维度")
        if (self.page is None) != (self.page_size is None):
            raise ValueError("page 与 page_size 必须同时提供")
        if self.page is not None and (
            self.group_by != "manager" or self.task_type is None
        ):
            raise ValueError("分页必须使用客户经理维度并指定 task_type")
        if self.start_date is not None and self.start_date != month_first_day(
            self.end_date
        ):
            raise ValueError(
                "落盘报表只支持当月 1 号 ~ 跑数日期，任意区间请用在线接口"
            )
        return self

    @property
    def stat_start_date(self) -> date:
        """统计区间起始日：显式传入时按传入值，否则取跑数日期当月 1 号。"""
        return self.start_date or month_first_day(self.end_date)


def month_first_day(value: date) -> date:
    return value.replace(day=1)


class SnapshotBatchInfo(BaseModel):
    """快照日期汇总；ready 表示已有数据，loaded_at 未提供时为 null。"""

    prt_dt: date
    source_id: str
    status: str
    stat_start_dt: date | None = None
    stat_end_dt: date | None = None
    sync_date: str | None = None
    row_total: int = 0
    loaded_at: datetime | None = None


class SnapshotReportResponse(BaseModel):
    metric_version: Literal["jkh_task_report_v1_snapshot"] = (
        SNAPSHOT_METRIC_VERSION
    )
    consistency: Literal["snapshot"] = "snapshot"
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    source_id: str
    prt_dt: date
    start_date: date
    end_date: date
    group_by: ReportGroupBy
    skill_detail: bool = False
    rpt_combo: str
    sync_date: str | None = None
    resolved_filters: ResolvedReportFilters
    ratio_unit: Literal["percent"] = "percent"
    read_evidence: dict[str, str] = Field(
        default_factory=lambda: {
            "push": "execution_is_read",
            "ask": "assumed_from_success",
        }
    )
    warnings: list[str] = Field(default_factory=list)
    batch: SnapshotBatchInfo
    items: list[TaskTypeReportRow]
    page: int | None = None
    page_size: int | None = None
    total: int = 0
    has_more: bool = False


class SnapshotDateItem(BaseModel):
    prt_dt: date
    status: str
    stat_start_dt: date | None = None
    stat_end_dt: date | None = None
    row_total: int = 0
    loaded_at: datetime | None = None


class SnapshotDatesResponse(BaseModel):
    source_id: str
    latest_ready_prt_dt: date | None = None
    items: list[SnapshotDateItem]


class SnapshotComboCount(BaseModel):
    rpt_combo: str
    row_cnt: int


class SnapshotStatusResponse(BaseModel):
    batch: SnapshotBatchInfo
    combo_counts: list[SnapshotComboCount]
    missing_combos: list[str]
