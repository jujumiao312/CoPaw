# -*- coding: utf-8 -*-
"""金葵花任务类型报表的参数化聚合 SQL。"""

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta


@dataclass(frozen=True)
class Scope:
    source_id: str
    sync_date: str
    start: datetime
    stop: datetime
    group_by: str = "overall"
    first_bbk_id: str | None = None
    org_id: str | None = None
    skill_detail: bool = False
    user_id: str | None = None
    keyword: str | None = None
    manager_keys: tuple[tuple[str, str | None], ...] | None = None

    def __post_init__(self):
        if not self.source_id.strip() or not self.sync_date:
            raise ValueError("source_id and sync_date are required")
        date.fromisoformat(self.sync_date)
        if self.group_by not in ("overall", "branch", "org", "manager"):
            raise ValueError("invalid group_by")
        if self.skill_detail and self.group_by == "overall":
            raise ValueError("skill detail requires branch, org or manager")
        if self.start.tzinfo is not None or self.stop.tzinfo is not None:
            raise ValueError(
                "pass timestamps converted to the verified DB timezone"
            )
        if not timedelta(0) < self.stop - self.start <= timedelta(days=93):
            raise ValueError(
                "date window must be positive and at most 93 days"
            )


def bind(sql: str, values: dict) -> tuple[str, tuple]:
    """编译内部命名占位符；值不进入 SQL 文本，兼容现有 fetch_all。"""
    names = re.findall(r":([a-z_][a-z_0-9]*)\b", sql)
    return re.sub(r":([a-z_][a-z_0-9]*)\b", "%s", sql), tuple(
        values[name] for name in names
    )


def _roster_scope_sql(scope: Scope) -> tuple[str, str, str, dict]:
    """绑定人员、关键词与本页维度键，所有指标共用同一人员集合。"""
    values = dict(vars(scope))
    roster_filter = ""
    jkh_filter = ""
    if scope.first_bbk_id is not None:
        roster_filter += " AND first_bbk_id = :first_bbk_id"
        jkh_filter += " AND jkh.first_bbk_id = :first_bbk_id"
    if scope.org_id is not None:
        roster_filter += " AND org_id = :org_id"
        jkh_filter += " AND jkh.org_id = :org_id"
    if scope.user_id is not None:
        roster_filter += " AND user_id = :user_id"
        jkh_filter += " AND jkh.user_id = :user_id"
    if scope.keyword:
        values["keyword"] = (
            "%"
            + scope.keyword.replace("!", "!!")
            .replace("%", "!%")
            .replace("_", "!_")
            + "%"
        )
        roster_filter += " AND (user_name LIKE :keyword ESCAPE '!' OR user_id LIKE :keyword ESCAPE '!' OR pst_lvl LIKE :keyword ESCAPE '!')"
        jkh_filter += " AND (jkh.user_name LIKE :keyword ESCAPE '!' OR jkh.user_id LIKE :keyword ESCAPE '!' OR jkh.pst_lvl LIKE :keyword ESCAPE '!')"
    page_skill_filter = ""
    if scope.manager_keys is not None:
        page_filters = []
        users = []
        for index, (user_id, skill_id) in enumerate(scope.manager_keys):
            values[f"page_user_{index}"] = user_id
            users.append(f":page_user_{index}")
            values[f"page_skill_{index}"] = skill_id
            page_filters.append(
                f"({{user_column}} = :page_user_{index} AND kd.skill_id = :page_skill_{index})"
            )
        user_filter = " AND user_id IN (" + ",".join(users or ["NULL"]) + ")"
        roster_filter += user_filter
        jkh_filter += (
            " AND jkh.user_id IN (" + ",".join(users or ["NULL"]) + ")"
        )
        page_skill_filter = (
            " AND (" + " OR ".join(page_filters or ["1=0"]) + ")"
        )
    return roster_filter, jkh_filter, page_skill_filter, values


def build_queries(
    scope: Scope, keys_only: bool = False
) -> dict[str, tuple[str, tuple]]:
    """一次构造所有分组查询；查询数与机构数无关。"""
    roster_filter, jkh_filter, page_skill_filter, values = _roster_scope_sql(
        scope
    )
    roster_manager = ""
    manager_info = ""
    if scope.group_by == "manager":
        roster_manager = (
            ", MIN(user_name) AS user_name, MIN(pst_lvl) AS pst_lvl"
        )
        manager_info = (
            ", MIN(r.user_name) AS user_name, MIN(r.pst_lvl) AS pst_lvl"
        )
    roster = f"""SELECT user_id, first_bbk_id, org_id,
        MIN(first_bbk_nm) AS first_bbk_nm, MIN(org_nm) AS org_nm {roster_manager}
        FROM jkh_user_inf WHERE sync_date = :sync_date
        AND user_id IS NOT NULL AND user_id <> '' {roster_filter}
        GROUP BY user_id, first_bbk_id, org_id"""
    dimensions = {
        "overall": ("''", "''"),
        "branch": ("r.first_bbk_id", "''"),
        "org": ("r.first_bbk_id", "r.org_id"),
        "manager": ("r.first_bbk_id", "r.org_id"),
    }
    bbk, org = dimensions[scope.group_by]
    dims = f"{bbk} AS group_bbk, {org} AS group_org"
    groups = "group_bbk, group_org"
    if scope.group_by == "manager":
        dims += ", r.user_id AS group_user"
        groups += ", group_user"

    def jkh_exists(user_column: str) -> str:
        return f"""EXISTS (
            SELECT 1 FROM jkh_user_inf jkh
            WHERE jkh.user_id = {user_column} AND jkh.sync_date = :sync_date
            AND jkh.user_id IS NOT NULL AND jkh.user_id <> '' {jkh_filter}
        )"""

    def roster_value(user_column: str, column: str) -> str:
        return f"""(SELECT MIN(jkh.{column}) FROM jkh_user_inf jkh
            WHERE jkh.user_id = {user_column} AND jkh.sync_date = :sync_date
            AND jkh.user_id IS NOT NULL AND jkh.user_id <> '')"""

    def metric_dims(user_column: str) -> str:
        if scope.group_by == "overall":
            metric_bbk, metric_org = "''", "''"
        elif scope.group_by == "branch":
            metric_bbk, metric_org = roster_value(
                user_column, "first_bbk_id"
            ), "''"
        else:
            metric_bbk = roster_value(user_column, "first_bbk_id")
            metric_org = roster_value(user_column, "org_id")
        result = f"{metric_bbk} AS group_bbk, {metric_org} AS group_org"
        if scope.group_by == "manager":
            result += f", {user_column} AS group_user"
        return result

    def skill_page_filter(user_column: str) -> str:
        if not scope.skill_detail:
            return ""
        return page_skill_filter.format(user_column=user_column)

    skill_dims, skill_groups = "", ""
    push_skill_join, ask_skill_join, click_skill_join = "", "", ""
    skill_match = ""
    if scope.skill_detail:
        # One catalog row per source+skill, even when marketplace has revisions.
        catalog = """SELECT source_id, skill_id,
            MIN(NULLIF(cn_name, '')) AS cn_name FROM swe_marketplace_skills
            WHERE source_id = :source_id AND include_in_statistics = 1
            AND skill_id IS NOT NULL AND skill_id <> ''
            GROUP BY source_id, skill_id"""
        skill_dims = ", kd.skill_id AS skill_id, MIN(kd.cn_name) AS cn_name"
        skill_groups = ", kd.skill_id"
        skill_match = " AND k.skill_id = kd.skill_id"
        push_skill_join = f"""JOIN ({catalog}) kd ON kd.source_id = p.source_id
            AND FIND_IN_SET(kd.skill_id, p.skill_ids)"""
        ask_skill_join = f"""JOIN ({catalog}) kd ON kd.source_id = sp.source_id
            AND kd.skill_id = sp.skill_id"""
        click_skill_join = f"""JOIN ({catalog}) kd ON kd.source_id = c.source_id
            AND ((c.task_type = 'push_plan' AND EXISTS (
                SELECT 1 FROM swe_cron_jobs j WHERE j.id = c.cron_task_id
                AND j.source_id = c.source_id AND FIND_IN_SET(kd.skill_id, j.skill_ids)
            )) OR (c.task_type = 'ask_plan' AND EXISTS (
                SELECT 1 FROM swe_tracing_spans sp
                WHERE sp.source_id = c.source_id AND sp.trace_id = c.trace_id
                AND sp.skill_id = kd.skill_id
            )))"""
    has_sub = "EXISTS (SELECT 1 FROM swe_cron_subtasks s WHERE s.trace_id = e.trace_id AND e.trace_id <> '')"
    push = f"""SELECT e.id, e.trace_id, e.tenant_id AS user_id,
        e.status, e.async_status, e.is_read, j.id AS job_id,
        j.tenant_id AS job_user_id, j.source_id, j.skill_ids,
        j.status AS job_status, j.deleted_at,
        CASE WHEN {has_sub} THEN 'push_plan' ELSE 'push_other' END AS task_type
        FROM swe_cron_executions e JOIN swe_cron_jobs j ON j.id = e.job_id
        WHERE j.source_id = :source_id AND e.actual_time >= :start AND e.actual_time < :stop
        AND ({has_sub} OR (e.status = 'success' AND e.async_status = 'success'))"""
    ask_qualifier = """sp.trace_id <> ''
        AND sp.skill_id IS NOT NULL AND sp.skill_id <> ''
        AND EXISTS (SELECT 1 FROM swe_cron_subtasks s WHERE s.trace_id = sp.trace_id)
        AND NOT EXISTS (SELECT 1 FROM swe_cron_executions e WHERE e.trace_id = sp.trace_id)"""
    ask = f"""SELECT sp.trace_id, sp.source_id, sp.user_id, sp.skill_id
        FROM swe_tracing_spans sp WHERE sp.source_id = :source_id
        AND sp.start_time >= :start AND sp.start_time < :stop AND {ask_qualifier}"""
    stat_job = """EXISTS (SELECT 1 FROM swe_marketplace_skills k
        WHERE k.source_id = p.source_id AND k.include_in_statistics = 1
        AND k.skill_id IS NOT NULL AND k.skill_id <> ''
        AND FIND_IN_SET(k.skill_id, p.skill_ids))"""
    stat_ask = """EXISTS (SELECT 1 FROM swe_marketplace_skills k
        WHERE k.source_id = sp.source_id AND k.skill_id = sp.skill_id
        AND k.include_in_statistics = 1 AND k.skill_id <> '')"""
    query = {}
    # 在名称/机构筛选之前查冲突，防止用户所属机构不唯一被筛选掩盖。
    query["roster_conflicts"] = """SELECT user_id FROM (
        SELECT DISTINCT user_id, first_bbk_id, org_id FROM jkh_user_inf
        WHERE sync_date = :sync_date AND user_id IS NOT NULL AND user_id <> ''
        ) r GROUP BY user_id HAVING COUNT(*) > 1 LIMIT 1"""
    query[
        "permissions"
    ] = f"""SELECT {dims}, MIN(r.first_bbk_nm) AS first_bbk_name,
        MIN(r.org_nm) AS org_name {manager_info},
        COUNT(DISTINCT CASE WHEN EXISTS (SELECT 1 FROM swe_tenant_init_source i
            WHERE i.tenant_id = r.user_id AND i.source_id = :source_id)
            THEN r.user_id END) AS permission_manager_count
        FROM ({roster}) r GROUP BY {groups}"""
    query["push_tasks"] = f"""SELECT {metric_dims("p.user_id")}{skill_dims}, p.task_type,
        SUM(CASE WHEN p.status = 'success' AND p.async_status = 'success' THEN 1 ELSE 0 END) AS suc_execute_job,
        SUM(CASE WHEN p.is_read = 1 THEN 1 ELSE 0 END) AS read_tasks
        FROM ({push}) p
        {push_skill_join}{skill_page_filter("p.user_id")}
        WHERE {jkh_exists("p.user_id")}
        GROUP BY {groups}{skill_groups}, p.task_type"""
    query[
        "ask_tasks"
    ] = f"""SELECT {metric_dims("sp.user_id")}{skill_dims}, 'ask_plan' AS task_type,
        COUNT(DISTINCT sp.trace_id) AS suc_execute_job,
        COUNT(DISTINCT sp.trace_id) AS read_tasks
        FROM ({ask}) sp
        {ask_skill_join}{skill_page_filter("sp.user_id")}
        WHERE {jkh_exists("sp.user_id")}
        GROUP BY {groups}{skill_groups}"""
    query["active"] = f"""SELECT {metric_dims("p.job_user_id")}{skill_dims}, p.task_type,
        COUNT(DISTINCT p.job_user_id) AS active_manager_count
        FROM ({push}) p
        {push_skill_join}{skill_page_filter("p.job_user_id")}
        WHERE p.job_status = 'active' AND p.deleted_at IS NULL
        AND {jkh_exists("p.job_user_id")}
        GROUP BY {groups}{skill_groups}, p.task_type"""
    query[
        "push_skills"
    ] = f"""SELECT {metric_dims("p.user_id")}{skill_dims}, p.task_type, COUNT(DISTINCT k.skill_id) AS skill_count
        FROM ({push}) p
        {push_skill_join}{skill_page_filter("p.user_id")}
        JOIN swe_marketplace_skills k ON k.source_id = p.source_id
            AND FIND_IN_SET(k.skill_id, p.skill_ids)
        WHERE k.include_in_statistics = 1 AND k.skill_id <> '' {skill_match}
            AND p.deleted_at IS NULL AND p.job_status <> 'deleted'
            AND {jkh_exists("p.user_id")}
        GROUP BY {groups}{skill_groups}, p.task_type"""
    query[
        "ask_skills"
    ] = f"""SELECT {metric_dims("sp.user_id")}{skill_dims}, 'ask_plan' AS task_type, COUNT(DISTINCT k.skill_id) AS skill_count
        FROM ({ask}) sp
        {ask_skill_join}{skill_page_filter("sp.user_id")}
        JOIN swe_marketplace_skills k ON k.source_id = sp.source_id AND k.skill_id = sp.skill_id
        WHERE k.include_in_statistics = 1 AND k.skill_id <> '' {skill_match}
        AND {jkh_exists("sp.user_id")} GROUP BY {groups}{skill_groups}"""
    query[
        "push_customers"
    ] = f"""SELECT {metric_dims("p.user_id")}{skill_dims}, 'push_plan' AS task_type,
        COUNT(DISTINCT s.custuid) AS recommended_customers
        FROM ({push}) p
        {push_skill_join}{skill_page_filter("p.user_id")}
        JOIN swe_cron_subtasks s ON s.trace_id = p.trace_id
        WHERE p.task_type = 'push_plan' AND s.custuid IS NOT NULL AND s.custuid <> ''
        AND {stat_job} AND {jkh_exists("p.user_id")}
        GROUP BY {groups}{skill_groups}"""
    query[
        "ask_customers"
    ] = f"""SELECT {metric_dims("sp.user_id")}{skill_dims}, 'ask_plan' AS task_type,
        COUNT(DISTINCT s.custuid) AS recommended_customers
        FROM ({ask}) sp
        {ask_skill_join}{skill_page_filter("sp.user_id")}
        JOIN swe_cron_subtasks s ON s.trace_id = sp.trace_id
        WHERE s.custuid IS NOT NULL AND s.custuid <> ''
        AND {jkh_exists("sp.user_id")} GROUP BY {groups}{skill_groups}"""
    # 点击必须从 clicked_at 缩小范围；关联任务不附加任务生成时间限制。
    click_push = """EXISTS (SELECT 1 FROM swe_cron_executions e
        JOIN swe_cron_jobs j ON j.id = e.job_id
        WHERE e.trace_id = c.trace_id AND j.id = c.cron_task_id
        AND j.source_id = c.source_id AND j.deleted_at IS NULL AND j.status <> 'deleted'
        AND EXISTS (SELECT 1 FROM swe_cron_subtasks s WHERE s.trace_id = e.trace_id)
        AND EXISTS (SELECT 1 FROM swe_marketplace_skills k
            WHERE k.source_id = j.source_id AND k.include_in_statistics = 1
            AND k.skill_id <> '' AND FIND_IN_SET(k.skill_id, j.skill_ids)))"""
    click_ask = f"""EXISTS (SELECT 1 FROM swe_tracing_spans sp
        WHERE sp.trace_id = c.trace_id AND sp.source_id = c.source_id
        AND {ask_qualifier} AND {stat_ask})"""
    click_rows = f"""SELECT c.user_id, c.customer_id, c.event_type,
        c.source_id, c.trace_id, c.cron_task_id,
        c.template_type, c.button_type,
        CASE WHEN {click_push} THEN 'push_plan' ELSE 'ask_plan' END AS task_type
        FROM swe_html_preview_click_events c WHERE c.source_id = :source_id
        AND c.clicked_at >= :start AND c.clicked_at < :stop
        AND c.trace_id IS NOT NULL AND c.trace_id <> ''
        AND c.customer_id IS NOT NULL AND c.customer_id <> ''
        AND ((c.event_type = 'preview_view' AND c.template_type = 'sub')
            OR (c.event_type = 'button_click' AND c.button_type IN ('insight', 'phone')))
        AND ({click_push} OR {click_ask})
        AND {jkh_exists("c.user_id")}"""
    if keys_only:
        if not scope.skill_detail:
            keys_sql = f"SELECT {dims}, NULL AS skill_id FROM ({roster}) r GROUP BY {groups}"
        else:
            push_key_dims = (
                metric_dims("p.user_id") + ", kd.skill_id AS skill_id"
            )
            active_key_dims = (
                metric_dims("p.job_user_id") + ", kd.skill_id AS skill_id"
            )
            ask_key_dims = (
                metric_dims("sp.user_id") + ", kd.skill_id AS skill_id"
            )
            click_key_dims = (
                metric_dims("c.user_id") + ", kd.skill_id AS skill_id"
            )
            keys_sql = f"""SELECT DISTINCT {push_key_dims}
                FROM ({push}) p {push_skill_join}
                WHERE {jkh_exists("p.user_id")}
                UNION SELECT DISTINCT {active_key_dims}
                FROM ({push}) p {push_skill_join}
                WHERE p.job_status = 'active' AND p.deleted_at IS NULL
                AND {jkh_exists("p.job_user_id")}
                UNION SELECT DISTINCT {ask_key_dims}
                FROM ({ask}) sp {ask_skill_join}
                WHERE {jkh_exists("sp.user_id")}
                UNION SELECT DISTINCT {click_key_dims}
                FROM ({click_rows}) c {click_skill_join}"""
        return {"keys": bind(keys_sql, values)}
    query["clicks"] = f"""SELECT {metric_dims("c.user_id")}{skill_dims}, c.task_type,
        COUNT(DISTINCT CASE WHEN c.event_type = 'preview_view' AND c.template_type = 'sub'
            THEN c.customer_id END) AS read_customer_count,
        COUNT(DISTINCT CASE WHEN c.event_type = 'button_click' AND c.button_type = 'insight'
            THEN c.customer_id END) AS insight_customer_count,
        COUNT(CASE WHEN c.event_type = 'button_click' AND c.button_type = 'insight'
            THEN 1 END) AS insight_count,
        COUNT(DISTINCT CASE WHEN c.event_type = 'button_click' AND c.button_type = 'phone'
            THEN c.customer_id END) AS phone_customer_count,
        COUNT(CASE WHEN c.event_type = 'button_click' AND c.button_type = 'phone'
            THEN 1 END) AS phone_count
        FROM ({click_rows}) c
        {click_skill_join}{skill_page_filter("c.user_id")}
        GROUP BY {groups}{skill_groups}, c.task_type"""
    return {name: bind(sql, values) for name, sql in query.items()}
