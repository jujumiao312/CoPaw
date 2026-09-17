# -*- coding: utf-8 -*-
"""金葵花任务类型报表的行组装与派生比例。

SQL 只按维度聚合；补齐三类任务、空值语义和百分比都在这里计算，
不引入新的统计口径。本模块不访问数据库、不打日志，可单独对账。
"""

from decimal import Decimal, ROUND_HALF_UP

from .task_type_report_sql import META_QUERY_NAMES

TASK_TYPES = ("push_plan", "ask_plan", "push_other")
# 点击只提供查看/点击事实，不能单独定义一个技能明细行。
CLICK_QUERY = "clicks"
LABELS = dict(
    zip(
        TASK_TYPES,
        ("推送(名单+方案)", "主动提问(名单+方案)", "推送(非名单方案)"),
    )
)
COUNTS = (
    "skill_count",
    "permission_manager_count",
    "active_manager_count",
    "suc_execute_job",
    "read_tasks",
    "recommended_customers",
    "read_customer_count",
    "insight_customer_count",
    "insight_count",
    "phone_customer_count",
    "phone_count",
)
RATIOS = {
    "read_rate": ("read_tasks", "suc_execute_job"),
    "plan_read_rate": ("read_customer_count", "recommended_customers"),
    "click_to_insight_rate": (
        "insight_customer_count",
        "recommended_customers",
    ),
    "click_to_phone_rate": ("phone_customer_count", "recommended_customers"),
}
# 三类任务天然不产出的列：主动提问没有活跃客户经理，非名单推送没有客户方案。
NULL_FIELDS = {
    "ask_plan": ("active_manager_count",),
    "push_other": (
        "recommended_customers",
        "read_customer_count",
        "insight_customer_count",
        "insight_count",
        "phone_customer_count",
        "phone_count",
    ),
}


def percentage(numerator: int | None, denominator: int | None) -> float | None:
    """零分母或缺失分子返回 None，保留两位小数。"""
    if numerator is None or denominator in (None, 0):
        return None
    return float(
        (Decimal(numerator) * 100 / Decimal(denominator)).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )
    )


def assemble(
    results: dict[str, list[dict]],
    group_by: str,
    skill_detail: bool = False,
    task_type: str | None = None,
) -> list[dict]:
    """只合并数据库聚合结果；绝不累加分组后的 DISTINCT 计数生成总行。

    ``task_type`` 指定时只组装该类型，用于单类型请求按需生成行。
    """
    types = (task_type,) if task_type else TASK_TYPES
    base_rows = _base_rows(results, group_by, types)
    # 技能明细只展开事实里出现过的维度×技能，不做名单×技能笛卡尔积。
    rows = {} if skill_detail else base_rows
    skill_sources: dict[tuple, set[str]] = {}
    for name, records in results.items():
        if name in META_QUERY_NAMES:
            continue
        for record in records:
            key = (*_dimension_key(record), record["task_type"])
            if key not in base_rows:
                raise ValueError("roster changed during report query")
            if skill_detail:
                key = _expand_skill_rows(rows, base_rows, key, record, types)
                skill_key = (*key[:3], key[4])
                skill_sources.setdefault(skill_key, set()).add(name)
            _merge_counts(rows[key], record)
    if skill_detail:
        rows = _drop_click_only_skills(rows, skill_sources)
    return [
        _finish_row(rows[key])
        for key in sorted(rows, key=_sort_key(skill_detail))
    ]


def _drop_click_only_skills(
    rows: dict, skill_sources: dict[tuple, set[str]]
) -> dict:
    """剔除只有点击事实的“维度对象+技能”行。

    点击按点击时间取窗口、关联任务不限制生成时间，窗口外任务的技能会仅凭一次
    点击出现在明细里，使明细技能数多于统计表技能总数。这些技能不属于当前筛选
    的任务范围，装配阶段直接去掉，数据库侧不为此增加关联查询；同一技能只要在
    该维度有任何任务级事实，仍按原规则补齐三类任务行。
    """
    return {
        key: row
        for key, row in rows.items()
        if any(
            name != CLICK_QUERY
            for name in skill_sources.get((*key[:3], key[4]), ())
        )
    }


def _dimension_key(record: dict) -> tuple:
    """维度键；是否有事实由查询返回的分组决定，不能用指标是否为零判断。"""
    return (
        record["group_bbk"],
        record["group_org"],
        record.get("group_user", ""),
    )


def _base_rows(results: dict, group_by: str, task_types: tuple) -> dict:
    """只保留有事实的维度，并为每个维度补齐三类任务。"""
    facts = {
        _dimension_key(record)
        for name, records in results.items()
        if name not in META_QUERY_NAMES
        for record in records
    }
    dimensions = [
        record
        for record in results["permissions"]
        if _dimension_key(record) in facts
    ]
    return _empty_rows(dimensions, group_by, task_types)


def _empty_rows(
    dimensions: list[dict], group_by: str, task_types: tuple
) -> dict:
    """为传入的有效维度补齐三类任务，未参与分组的列留空。"""
    rows = {}
    for dimension in dimensions:
        user_id = dimension.get("group_user", "")
        for current_type in task_types:
            key = (
                dimension["group_bbk"],
                dimension["group_org"],
                user_id,
                current_type,
            )
            row = {field: 0 for field in COUNTS}
            row.update(
                first_bbk_id=key[0] if group_by != "overall" else None,
                org_id=key[1] if group_by in ("org", "manager") else None,
                first_bbk_name=(
                    dimension["first_bbk_name"]
                    if group_by != "overall"
                    else None
                ),
                org_name=(
                    dimension["org_name"]
                    if group_by in ("org", "manager")
                    else None
                ),
                user_id=key[2] if group_by == "manager" else None,
                user_name=dimension.get("user_name"),
                sapid=key[2] if group_by == "manager" else None,
                pst_lvl=dimension.get("pst_lvl"),
                skill_id=None,
                cn_name=None,
                task_type=current_type,
                task_type_name=LABELS[current_type],
                permission_manager_count=int(
                    dimension["permission_manager_count"]
                ),
            )
            rows[key] = row
    return rows


def _merge_counts(row: dict, record: dict):
    """只覆盖查询真正返回的指标，缺失指标保持补齐时的默认值。"""
    for field in COUNTS:
        if field in record:
            row[field] = int(record[field] or 0)


def _finish_row(row: dict) -> dict:
    """按任务类型清空天然缺失的列，再计算派生比例。"""
    for field in NULL_FIELDS.get(row["task_type"], ()):
        row[field] = None
    for field, (numerator, denominator) in RATIOS.items():
        row[field] = percentage(row[numerator], row[denominator])
    return row


def _expand_skill_rows(
    rows: dict, base_rows: dict, key: tuple, record: dict, task_types: tuple
) -> tuple:
    """只展开有事实关联的人员/机构与技能组合，不做名单×技能笛卡尔积。"""
    for current_type in task_types:
        base_key = (*key[:3], current_type)
        skill_key = (*base_key, record["skill_id"])
        if skill_key not in rows:
            rows[skill_key] = {
                **base_rows[base_key],
                "skill_id": record["skill_id"],
                "cn_name": record["cn_name"],
            }
    return (*key, record["skill_id"])


def _sort_key(skill_detail: bool):
    """维度升序；空机构号排在最后，三类任务按固定顺序。"""

    def key(row_key: tuple):
        return (
            row_key[0] is not None,
            row_key[0] or "",
            row_key[1] is not None,
            row_key[1] or "",
            row_key[2],
            row_key[4] if skill_detail else "",
            TASK_TYPES.index(row_key[3]),
        )

    return key
