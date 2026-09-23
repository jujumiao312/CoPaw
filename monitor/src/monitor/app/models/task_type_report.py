# -*- coding: utf-8 -*-
"""金葵花任务类型报表的独立请求与响应契约。"""

import re
from datetime import date
from typing import Annotated, Literal

from pydantic import (
    BaseModel,
    BeforeValidator,
    Field,
    StringConstraints,
    model_validator,
)

ReportGroupBy = Literal["overall", "branch", "org", "manager"]
ReportTaskType = Literal["push_plan", "ask_plan", "push_other"]
OrganizationId = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)
]
OrganizationName = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=256)
]
ReportSource = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)
]
Count = Annotated[int, Field(ge=0)]
Percentage = Annotated[float, Field(ge=0, allow_inf_nan=False)]
MAX_REPORT_DAYS = 93


COMMON_METRIC_PERIODS = ("t1", "t3", "t7", "t14")
# 落盘表通用转化指标：字段顺序与 swe_rm_claw_list_ind_stat 保持一致。
COMMON_METRIC_BASE_FIELDS = (
    ("wlth_prod_buy_cm_qty", "财富产品购买客户经理人数"),
    ("wlth_prod_buy_cust_qty", "财富产品购买客户数"),
    ("wlth_prod_buy_amt", "财富产品购买金额"),
    ("aum_asc_amt", "AUM提升金额"),
    ("sfl_cust_asc_qty", "金葵花客户提升数"),
    ("wlth_inc", "财富中收"),
    ("fnd_prod_buy_cm_qty", "基金购买客户经理人数"),
    ("fnd_prod_buy_cust_qty", "基金购买客户数"),
    ("fnd_prod_buy_amt", "基金购买金额"),
    ("fnd_aum_asc_amt", "基金AUM提升金额"),
    ("fnd_inc", "基金中收"),
)
COMMON_METRIC_FIELDS = (
    "vld_ctc_cust_qty",
    "vld_ctc_cust_rate",
    *(
        f"{name}_{period}"
        for period in COMMON_METRIC_PERIODS
        for name, _ in COMMON_METRIC_BASE_FIELDS
    ),
)
COMMON_METRIC_LABELS = {
    "vld_ctc_cust_qty": "强接触客户数",
    "vld_ctc_cust_rate": "强接触客户率",
    **{
        f"{name}_{period}": f"{label}(T+{period[1:]})"
        for period in COMMON_METRIC_PERIODS
        for name, label in COMMON_METRIC_BASE_FIELDS
    },
}
COMMON_METRIC_INT_FIELDS = frozenset(
    field
    for field in COMMON_METRIC_FIELDS
    if field == "vld_ctc_cust_qty" or "_qty_" in field
)


def _strict_date(value: object) -> date:
    if type(value) is date:
        return value
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value
    ):
        raise ValueError("日期须为有效的 YYYY-MM-DD")
    return date.fromisoformat(value)


ReportDate = Annotated[date, BeforeValidator(_strict_date)]


class TaskTypeReportParams(BaseModel):
    start_date: ReportDate
    end_date: ReportDate
    group_by: ReportGroupBy = "overall"
    skill_detail: bool = False
    first_bbk_id: OrganizationId | None = None
    first_bbk_name: OrganizationName | None = None
    org_id: OrganizationId | None = None
    org_name: OrganizationName | None = None
    task_type: ReportTaskType | None = None
    user_id: OrganizationId | None = None
    keyword: (
        Annotated[
            str, StringConstraints(strip_whitespace=True, max_length=100)
        ]
        | None
    ) = None
    page: Annotated[int, Field(ge=1)] | None = None
    page_size: Annotated[int, Field(ge=1, le=100)] | None = None

    @model_validator(mode="after")
    def validate_date_window(self):
        days = (self.end_date - self.start_date).days + 1
        if not 1 <= days <= MAX_REPORT_DAYS:
            raise ValueError("日期范围须为 1 至 93 个自然日")
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
        return self


class ResolvedReportFilters(BaseModel):
    first_bbk_id: str | None = None
    org_id: str | None = None


class TaskTypeReportRow(BaseModel):
    first_bbk_id: str | None
    first_bbk_name: str | None
    org_id: str | None
    org_name: str | None
    user_id: str | None = None
    user_name: str | None = None
    sapid: str | None = None
    pst_lvl: str | None = None
    skill_id: str | None = None
    cn_name: str | None = None
    task_type: ReportTaskType
    task_type_name: str
    skill_count: Count | None
    permission_manager_count: Count | None
    active_manager_count: Count | None
    active_task_count: Count | None = None
    paused_task_count: Count | None = None
    suc_execute_job: Count
    read_tasks: Count
    read_rate: Percentage | None
    recommended_customers: Count | None
    read_customer_count: Count | None
    plan_read_rate: Percentage | None
    insight_customer_count: Count | None
    click_to_insight_rate: Percentage | None
    insight_count: Count | None
    phone_customer_count: Count | None
    click_to_phone_rate: Percentage | None
    phone_count: Count | None
    vld_ctc_cust_qty: Count | None = None
    vld_ctc_cust_rate: Percentage | None = None
    # T+1
    wlth_prod_buy_cm_qty_t1: Count | None = None
    wlth_prod_buy_cust_qty_t1: Count | None = None
    wlth_prod_buy_amt_t1: float | None = None
    aum_asc_amt_t1: float | None = None
    sfl_cust_asc_qty_t1: Count | None = None
    wlth_inc_t1: float | None = None
    fnd_prod_buy_cm_qty_t1: Count | None = None
    fnd_prod_buy_cust_qty_t1: Count | None = None
    fnd_prod_buy_amt_t1: float | None = None
    fnd_aum_asc_amt_t1: float | None = None
    fnd_inc_t1: float | None = None
    # T+3
    wlth_prod_buy_cm_qty_t3: Count | None = None
    wlth_prod_buy_cust_qty_t3: Count | None = None
    wlth_prod_buy_amt_t3: float | None = None
    aum_asc_amt_t3: float | None = None
    sfl_cust_asc_qty_t3: Count | None = None
    wlth_inc_t3: float | None = None
    fnd_prod_buy_cm_qty_t3: Count | None = None
    fnd_prod_buy_cust_qty_t3: Count | None = None
    fnd_prod_buy_amt_t3: float | None = None
    fnd_aum_asc_amt_t3: float | None = None
    fnd_inc_t3: float | None = None
    # T+7
    wlth_prod_buy_cm_qty_t7: Count | None = None
    wlth_prod_buy_cust_qty_t7: Count | None = None
    wlth_prod_buy_amt_t7: float | None = None
    aum_asc_amt_t7: float | None = None
    sfl_cust_asc_qty_t7: Count | None = None
    wlth_inc_t7: float | None = None
    fnd_prod_buy_cm_qty_t7: Count | None = None
    fnd_prod_buy_cust_qty_t7: Count | None = None
    fnd_prod_buy_amt_t7: float | None = None
    fnd_aum_asc_amt_t7: float | None = None
    fnd_inc_t7: float | None = None
    # T+14
    wlth_prod_buy_cm_qty_t14: Count | None = None
    wlth_prod_buy_cust_qty_t14: Count | None = None
    wlth_prod_buy_amt_t14: float | None = None
    aum_asc_amt_t14: float | None = None
    sfl_cust_asc_qty_t14: Count | None = None
    wlth_inc_t14: float | None = None
    fnd_prod_buy_cm_qty_t14: Count | None = None
    fnd_prod_buy_cust_qty_t14: Count | None = None
    fnd_prod_buy_amt_t14: float | None = None
    fnd_aum_asc_amt_t14: float | None = None
    fnd_inc_t14: float | None = None


class TaskTypeReportResponse(BaseModel):
    metric_version: Literal["jkh_task_report_v1"] = "jkh_task_report_v1"
    start_date: date
    end_date: date
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    source_id: str
    sync_date: str | None
    group_by: ReportGroupBy
    skill_detail: bool = False
    resolved_filters: ResolvedReportFilters
    ratio_unit: Literal["percent"] = "percent"
    read_evidence: dict[str, str] = Field(
        default_factory=lambda: {
            "push": "execution_is_read",
            "ask": "assumed_from_success",
        }
    )
    consistency: Literal["live"] = "live"
    warnings: list[str] = Field(default_factory=list)
    items: list[TaskTypeReportRow]
    page: int | None = None
    page_size: int | None = None
    total: int = 0
    has_more: bool = False


class ReportOptionsParams(BaseModel):
    end_date: ReportDate
    kind: Literal["branches", "orgs"]
    first_bbk_id: OrganizationId | None = None


class ReportOption(BaseModel):
    value: str
    label: str


class ReportOptionsResponse(BaseModel):
    sync_date: str | None
    items: list[ReportOption]
