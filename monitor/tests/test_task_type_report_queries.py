# -*- coding: utf-8 -*-
"""SQLite 验证真实聚合 SQL；不代表 TDSQL 方言与性能验证。"""

import sqlite3
import asyncio
import logging
import re
from dataclasses import replace
from datetime import date, datetime

import pytest

from monitor.app.services.cron.task_type_report_sql import (
    Scope,
    bind,
    build_queries,
)
from monitor.app.services.cron.task_type_report import (
    assemble,
    date_bounds,
    percentage,
)
from monitor.app.services.cron import task_type_report as report_service
from monitor.app.models.task_type_report import TaskTypeReportParams


@pytest.fixture
def db():
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.create_function(
        "FIND_IN_SET",
        2,
        lambda value, values: int(value in (values or "").split(",")),
    )
    connection.executescript("""
        CREATE TABLE jkh_user_inf(user_id TEXT, sync_date TEXT, first_bbk_id TEXT,
            org_id TEXT, first_bbk_nm TEXT, org_nm TEXT);
        CREATE TABLE swe_tenant_init_source(tenant_id TEXT, source_id TEXT);
        CREATE TABLE swe_cron_jobs(id TEXT, tenant_id TEXT, source_id TEXT,
            skill_ids TEXT, status TEXT, deleted_at TEXT);
        CREATE TABLE swe_cron_executions(id INTEGER, job_id TEXT, tenant_id TEXT,
            trace_id TEXT, actual_time TEXT, status TEXT, async_status TEXT, is_read INTEGER);
        CREATE TABLE swe_cron_subtasks(trace_id TEXT, custuid TEXT);
        CREATE TABLE swe_tracing_traces(trace_id TEXT, source_id TEXT, user_id TEXT,
            start_time TEXT, status TEXT);
        CREATE TABLE swe_tracing_spans(span_id TEXT, trace_id TEXT, source_id TEXT, skill_id TEXT,
            user_id TEXT DEFAULT 'alice', start_time TEXT DEFAULT '2026-09-13 10:00:00', has_error INTEGER DEFAULT 0);
        CREATE TABLE swe_marketplace_skills(source_id TEXT, skill_id TEXT, include_in_statistics INTEGER);
        CREATE TABLE swe_html_preview_click_events(source_id TEXT, user_id TEXT,
            cron_task_id TEXT, trace_id TEXT, customer_id TEXT, clicked_at TEXT,
            event_type TEXT, template_type TEXT, button_type TEXT);
        INSERT INTO jkh_user_inf VALUES
            ('alice','2026-09-13','001','01','甲分行','同名支行'),
            ('alice','2026-09-13','001','01','甲分行','同名支行'),
            ('bob','2026-09-13','002','01','乙分行','同名支行'),
            ('empty','2026-09-13','003','03','丙分行','空支行');
        INSERT INTO swe_tenant_init_source VALUES ('alice','S'),('alice','S'),('bob','OTHER');
        INSERT INTO swe_cron_jobs VALUES
            ('j1','alice','S','k1,k2','active',NULL),
            ('j2','alice','S','k1','active',NULL),
            ('j3','outsider','S','k1','active',NULL);
        INSERT INTO swe_cron_executions VALUES
            (1,'j1','alice','p1','2026-09-13 10:00:00','success','success',1),
            (2,'j1','alice','p2','2026-09-13 10:00:00','error','error',1),
            (3,'j2','alice','p3','2026-09-13 10:00:00','success','success',1),
            (4,'j2','alice','p4','2026-09-13 10:00:00','error','error',0),
            (5,'j3','outsider','p5','2026-09-13 10:00:00','success','success',1),
            (6,'j1','alice','stop','2026-09-14 00:00:00','success','success',1);
        INSERT INTO swe_cron_subtasks VALUES
            ('p1','C1'),('p1','C1'),('p2','C2'),('p5','C5'),('stop','STOP'),
            ('a1','A1'),('a1','A1'),('aerr','A2'),('old','OLD');
        INSERT INTO swe_tracing_traces VALUES
            ('a1','S','alice','2026-09-13 10:00:00','completed'),
            ('aerr','S','alice','2026-09-13 10:00:00','error'),
            ('old','S','alice','2026-09-12 10:00:00','completed'),
            ('p1','S','alice','2026-09-13 10:00:00','completed'),
            ('nost','S','alice','2026-09-13 10:00:00','completed');
        INSERT INTO swe_tracing_spans (span_id, trace_id, source_id, skill_id) VALUES
            ('s1','a1','S','k1'),('s2','a1','S','k2'),('s3','aerr','S','k1'),
            ('s4','old','S','k1'),('s5','p1','S','k1'),('s6','nost','S','k1');
        UPDATE swe_tracing_spans SET start_time = '2026-09-12 10:00:00' WHERE trace_id = 'old';
        UPDATE swe_tracing_spans SET has_error = 1 WHERE trace_id = 'aerr';
        INSERT INTO swe_marketplace_skills VALUES ('S','k1',1),('S','k1',1),('S','k2',1),('OTHER','k9',1);
        INSERT INTO swe_html_preview_click_events VALUES
            ('S','alice','j1','p1','C1','2026-09-13 11:00:00','preview_view','sub',NULL),
            ('S','alice','j1','p1','C1','2026-09-13 11:01:00','preview_view','sub',NULL),
            ('S','alice','j1','p1','C1','2026-09-13 11:00:00','button_click','sub','insight'),
            ('S','alice','j1','p1','C1','2026-09-13 11:00:01','button_click','sub','insight'),
            ('S','alice','j1','p1','C1','2026-09-13 11:00:00','button_click','sub','phone'),
            ('S','alice','j1','p1','C1','2026-09-13 11:00:01','button_click','sub','phone'),
            ('S','alice',NULL,'a1',NULL,'2026-09-13 11:00:00','preview_view','main',NULL),
            ('S','alice',NULL,'a1','A1','2026-09-13 11:01:00','preview_view','sub',NULL),
            ('S','alice',NULL,'a1','A1','2026-09-13 11:02:00','preview_view','sub',NULL),
            ('S','alice',NULL,'old','OLD','2026-09-13 11:00:00','preview_view','sub',NULL),
            ('S','outsider',NULL,'a1','LEAK','2026-09-13 11:00:00','preview_view','sub',NULL),
            ('OTHER','alice',NULL,'a1','LEAK','2026-09-13 11:00:00','preview_view','sub',NULL),
            ('S','alice',NULL,'a1','STOP','2026-09-14 00:00:00','preview_view','sub',NULL);
    """)
    yield connection
    connection.close()


@pytest.fixture
def scope():
    start, stop = date_bounds(date(2026, 9, 13), date(2026, 9, 13))
    return Scope("S", "2026-09-13", start, stop)


def execute(db, scope):
    results = {}
    for name, (sql, params) in build_queries(scope).items():
        params = tuple(
            value.isoformat(" ") if isinstance(value, datetime) else value
            for value in params
        )
        results[name] = [
            dict(row) for row in db.execute(sql.replace("%s", "?"), params)
        ]
    return results


def test_all_metrics_and_deduplication(db, scope):
    results = execute(db, scope)
    assert results["roster_conflicts"] == []
    rows = {row["task_type"]: row for row in assemble(results, scope.group_by)}
    push, ask, other = (
        rows[name] for name in ("push_plan", "ask_plan", "push_other")
    )
    assert (
        push["skill_count"],
        push["permission_manager_count"],
        push["active_manager_count"],
    ) == (2, 1, 1)
    assert (
        push["suc_execute_job"],
        push["read_tasks"],
        push["read_rate"],
    ) == (1, 2, 200.0)
    assert (push["recommended_customers"], push["read_customer_count"]) == (
        2,
        1,
    )
    assert (
        push["insight_customer_count"],
        push["phone_customer_count"],
        push["plan_read_rate"],
    ) == (1, 1, 50.0)
    assert (push["insight_count"], push["phone_count"]) == (2, 2)
    assert (ask["suc_execute_job"], ask["read_tasks"], ask["read_rate"]) == (
        2,
        2,
        100.0,
    )
    assert ask["recommended_customers"] == 2
    assert ask["read_customer_count"] == 2  # 包含当期点击、前期生成的 OLD。
    assert (ask["insight_count"], ask["phone_count"]) == (0, 0)
    assert ask["active_manager_count"] is None
    assert (
        other["suc_execute_job"],
        other["skill_count"],
        other["read_tasks"],
    ) == (1, 1, 1)
    assert (
        other["recommended_customers"] is None
        and other["plan_read_rate"] is None
    )
    assert other["insight_count"] is None and other["phone_count"] is None


@pytest.mark.parametrize("group_by", ["overall", "branch", "org"])
def test_grouping_and_empty_dimensions(db, scope, group_by):
    scoped = replace(scope, group_by=group_by)
    rows = assemble(execute(db, scoped), group_by)
    assert len(rows) == 3
    if group_by == "org":
        assert {(row["first_bbk_id"], row["org_id"]) for row in rows} == {
            ("001", "01"),
        }


def test_filter_values_bound_and_empty_filter_result(db, scope):
    scoped = replace(scope, first_bbk_id="001' OR 1=1 --")
    assert all(
        "001' OR 1=1 --" not in sql
        for sql, _ in build_queries(scoped).values()
    )
    assert assemble(execute(db, scoped), "overall") == []
    filtered = replace(scope, group_by="org", first_bbk_id="001", org_id="01")
    assert len(assemble(execute(db, filtered), "org")) == 3


def test_conflicting_roster_detected_before_filter(db, scope):
    db.execute(
        "INSERT INTO jkh_user_inf VALUES ('alice','2026-09-13','002','02','乙','乙支行')"
    )
    assert execute(db, replace(scope, first_bbk_id="001"))[
        "roster_conflicts"
    ] == [{"user_id": "alice"}]


def test_click_actor_and_active_owner_use_independent_rosters(db, scope):
    db.execute("UPDATE swe_cron_jobs SET tenant_id = 'bob' WHERE id = 'j1'")
    db.execute(
        "UPDATE swe_html_preview_click_events SET user_id = 'bob' WHERE cron_task_id = 'j1'"
    )
    rows = assemble(execute(db, replace(scope, group_by="branch")), "branch")
    push = {
        row["first_bbk_id"]: row
        for row in rows
        if row["task_type"] == "push_plan"
    }
    assert (
        push["001"]["suc_execute_job"] == 1
        and push["001"]["active_manager_count"] == 0
    )
    assert (
        push["002"]["active_manager_count"] == 1
        and push["002"]["read_customer_count"] == 1
    )
    assert push["002"]["plan_read_rate"] is None


def test_ask_not_read_by_other_user_or_exposure(db, scope):
    db.execute(
        "UPDATE swe_html_preview_click_events SET user_id = 'bob' WHERE trace_id = 'a1'"
    )
    assert execute(db, scope)["ask_tasks"][0]["read_tasks"] == 2
    db.execute(
        "UPDATE swe_html_preview_click_events SET user_id = 'alice', event_type = 'module_exposure' WHERE trace_id = 'a1'"
    )
    assert execute(db, scope)["ask_tasks"][0]["read_tasks"] == 2


def test_deleted_job_is_excluded_from_push_metrics(db, scope):
    """删除 job 后，它的执行、方案、技能与活跃都不再进入推送口径。"""
    db.execute(
        "UPDATE swe_cron_jobs SET deleted_at = '2026-09-14', status = 'deleted' WHERE id = 'j1'"
    )
    rows = {
        row["task_type"]: row
        for row in assemble(execute(db, scope), "overall")
    }
    plan, other = rows["push_plan"], rows["push_other"]
    assert plan["suc_execute_job"] == 0 and plan["read_tasks"] == 0
    assert plan["recommended_customers"] == 0
    assert plan["skill_count"] == 0 and plan["active_manager_count"] == 0
    assert plan["read_customer_count"] == 0
    # 剩下的未删除 job(j2) 只有一次成功执行，且没有子任务。
    assert other["suc_execute_job"] == other["read_tasks"] == 1
    assert other["skill_count"] == other["active_manager_count"] == 1


def test_push_cohort_requires_live_job_with_statistical_skill(db, scope):
    """推送口径只包含未删除且至少绑定一个统计技能的任务。"""
    db.execute("UPDATE swe_marketplace_skills SET include_in_statistics = 0")
    db.execute("INSERT INTO swe_marketplace_skills VALUES ('S','k9',1)")
    rows = {
        row["task_type"]: row
        for row in assemble(execute(db, scope), "overall")
    }
    assert rows["push_plan"]["suc_execute_job"] == 0
    assert rows["push_other"]["suc_execute_job"] == 0

    db.execute(
        "UPDATE swe_marketplace_skills SET include_in_statistics = 1 "
        "WHERE skill_id = 'k1'"
    )
    rows = {
        row["task_type"]: row
        for row in assemble(execute(db, scope), "overall")
    }
    assert rows["push_plan"]["suc_execute_job"] == 1
    assert rows["push_other"]["suc_execute_job"] == 1

    # 只改状态、deleted_at 仍为空：同样按删除处理。
    db.execute("UPDATE swe_cron_jobs SET status = 'deleted' WHERE id = 'j2'")
    rows = {
        row["task_type"]: row
        for row in assemble(execute(db, scope), "overall")
    }
    assert rows["push_other"]["suc_execute_job"] == 0

    # 只改 deleted_at、状态仍为 active：同样按删除处理。
    db.execute(
        "UPDATE swe_cron_jobs SET status = 'active', "
        "deleted_at = '2026-09-13' WHERE id = 'j2'"
    )
    rows = {
        row["task_type"]: row
        for row in assemble(execute(db, scope), "overall")
    }
    assert rows["push_other"]["suc_execute_job"] == 0
    assert rows["push_plan"]["suc_execute_job"] == 1


def test_anti_join_uses_all_execution_history(db, scope):
    db.execute(
        "INSERT INTO swe_cron_executions VALUES (9,'j1','alice','a1','2026-09-12','success','success',1)"
    )
    ask = assemble(execute(db, scope), "overall")[1]
    assert ask["suc_execute_job"] == 1 and ask["recommended_customers"] == 1


def test_overall_distinct_not_sum_of_branches(db, scope):
    db.execute(
        "INSERT INTO swe_cron_executions VALUES (9,'j1','bob','p1','2026-09-13 12:00:00','success','success',1)"
    )
    overall = assemble(execute(db, scope), "overall")[0]
    branch = assemble(execute(db, replace(scope, group_by="branch")), "branch")
    assert overall["recommended_customers"] == 2
    assert (
        sum(
            row["recommended_customers"]
            for row in branch
            if row["task_type"] == "push_plan"
        )
        == 3
    )


@pytest.mark.parametrize(
    "numerator,denominator,expected",
    [(1, 3, 33.33), (0, 1, 0.0), (1, 0, None), (None, 3, None), (2, 1, 200.0)],
)
def test_percentages(numerator, denominator, expected):
    assert percentage(numerator, denominator) == expected


def test_validation_and_binding(scope):
    assert bind("x=:source_id OR y=:source_id", {"source_id": "S"}) == (
        "x=%s OR y=%s",
        ("S", "S"),
    )
    with pytest.raises(ValueError):
        replace(scope, group_by="org_id; DROP TABLE x")
    with pytest.raises(ValueError):
        replace(scope, stop=scope.start)
    with pytest.raises(ValueError):
        replace(scope, source_id="")


def test_metric_queries_filter_roster_with_exists_instead_of_join(scope):
    scoped = replace(scope, group_by="manager", skill_detail=True)
    queries = build_queries(scoped)
    metric_names = set(queries) - {"roster_conflicts", "permissions"}
    metric_sql = [queries[name][0] for name in metric_names]

    assert all(
        "JOIN (SELECT user_id, first_bbk_id, org_id" not in sql
        for sql in metric_sql
    )
    assert all("FROM jkh_user_inf jkh" in sql for sql in metric_sql)

    keys_sql = build_queries(scoped, keys_only=True)["keys"][0]
    assert "JOIN (SELECT user_id, first_bbk_id, org_id" not in keys_sql
    assert "FROM jkh_user_inf jkh" in keys_sql


def test_page_keys_dedupe_facts_before_roster_mapping(scope):
    """分页键先在事实里对（人员，技能）去重，再做名单过滤与机构映射。"""
    scoped = replace(scope, group_by="manager", skill_detail=True)
    keys_sql = build_queries(scoped, keys_only=True)["keys"][0]

    assert "SELECT DISTINCT p.user_id AS group_user" in keys_sql
    # 事实分支不再逐行做名单校验，机构映射只跑在去重后的人员上。
    assert "jkh_user_inf jkh WHERE jkh.user_id = p.user_id" not in keys_sql
    assert "jkh_user_inf jkh WHERE jkh.user_id = sp.user_id" not in keys_sql
    assert "jkh.user_id = pairs.group_user" in keys_sql


PUSH_TABLE = "FROM (SELECT e.id, e.trace_id"
ASK_TABLE = "FROM (SELECT sp.trace_id, sp.source_id"
CLICK_TABLE = "FROM (SELECT c.user_id, c.customer_id"


@pytest.mark.parametrize(
    "task_type,expected",
    [
        (
            "push_plan",
            {
                "push_tasks",
                "active",
                "push_skills",
                "push_customers",
                "clicks",
            },
        ),
        ("ask_plan", {"ask_tasks", "ask_skills", "ask_customers", "clicks"}),
        ("push_other", {"push_tasks", "active", "push_skills"}),
    ],
)
def test_single_task_type_builds_only_related_queries(
    scope, task_type, expected
):
    """方案 B：单类型只构造该类型涉及的查询，并在 SQL 内按类型收窄。"""
    scoped = replace(scope, group_by="manager", task_type=task_type)
    queries = build_queries(scoped)
    assert set(queries) == {"roster_conflicts", "permissions"} | expected
    for name in ("push_tasks", "active", "push_skills"):
        if name in queries:
            sql, values = queries[name]
            assert "p.task_type = %s" in sql
            assert task_type in values
    if "clicks" in queries:
        assert "c.task_type = %s" in queries["clicks"][0]
    # 未指定类型时行为不变：8 条事实查询全在。
    assert len(build_queries(replace(scope, group_by="manager"))) == 10


@pytest.mark.parametrize(
    "task_type,expected,unexpected",
    [
        ("push_plan", (PUSH_TABLE, CLICK_TABLE), (ASK_TABLE,)),
        ("ask_plan", (ASK_TABLE, CLICK_TABLE), (PUSH_TABLE,)),
        ("push_other", (PUSH_TABLE,), (ASK_TABLE, CLICK_TABLE)),
    ],
)
def test_page_keys_follow_requested_task_type(
    scope, task_type, expected, unexpected
):
    """分页键只取该类型的事实路径，不再用全类型并集占页。"""
    scoped = replace(scope, group_by="manager", task_type=task_type)
    keys_sql = build_queries(scoped, keys_only=True)["keys"][0]
    for marker in expected:
        assert marker in keys_sql
    for marker in unexpected:
        assert marker not in keys_sql
    if task_type == "push_other":
        assert "p.task_type = %s" in keys_sql


class AsyncQueryDb:
    """执行真实查询，保留调用记录以验证固定查询数和早退。"""

    is_connected = True

    def __init__(self, connection):
        self.connection = connection
        self.calls = []

    async def fetch_all(self, sql, params=()):
        self.calls.append((sql, params))
        await asyncio.sleep(0)
        values = tuple(
            value.isoformat(" ") if isinstance(value, datetime) else value
            for value in params
        )
        return [
            dict(row)
            for row in self.connection.execute(sql.replace("%s", "?"), values)
        ]

    async def fetch_one(self, sql, params=()):
        rows = await self.fetch_all(sql, params)
        return rows[0] if rows else None


@pytest.fixture
def service_db(db, monkeypatch):
    database = AsyncQueryDb(db)
    monkeypatch.setattr(report_service, "get_db_connection", lambda: database)
    return database


def request_params(**kwargs):
    return TaskTypeReportParams(
        **{"start_date": "2026-09-13", "end_date": "2026-09-13", **kwargs}
    )


@pytest.mark.asyncio
async def test_service_full_pipeline_and_fixed_query_count(service_db):
    service = report_service.TaskTypeReportService()
    result = await service.get_report(
        request_params(group_by="org"), "S", "100"
    )
    assert result.sync_date == "2026-09-13"
    assert len(result.items) == 3
    assert len(service_db.calls) == 11
    assert result.items[0].read_rate == 200.0
    assert result.items[1].active_manager_count is None
    assert result.items[2].recommended_customers is None
    assert service_db.calls[0][1] == ("2026-09-13", "2026-09-30")
    service_db.connection.executemany(
        "INSERT INTO jkh_user_inf VALUES (?,'2026-09-13',?,?,'新增分行','新增支行')",
        [(f"user-{i}", str(i), str(i)) for i in range(100, 200)],
    )
    service_db.calls.clear()
    result = await service.get_report(
        request_params(group_by="org"), "S", "100"
    )
    assert len(result.items) == 3 and len(service_db.calls) == 11


class ConcurrentQueryDb(AsyncQueryDb):
    """记录同时在飞的查询数，用于验证事实查询的受限并发。"""

    def __init__(self, connection):
        super().__init__(connection)
        self.in_flight = 0
        self.peak = 0

    async def fetch_all(self, sql, params=()):
        self.in_flight += 1
        self.peak = max(self.peak, self.in_flight)
        try:
            await asyncio.sleep(0.01)
            return await super().fetch_all(sql, params)
        finally:
            self.in_flight -= 1


async def report_with(monkeypatch, db, *, concurrency):
    monkeypatch.setattr(report_service, "get_db_connection", lambda: db)
    return await report_service.TaskTypeReportService(
        concurrency=concurrency
    ).get_report(request_params(group_by="org"), "S", "100")


@pytest.mark.asyncio
async def test_fact_queries_run_concurrently_with_stable_results(
    db, monkeypatch
):
    """并发只压缩总耗时；查询条数、结果与串行一致，且在飞查询数受限。"""
    serial_db = ConcurrentQueryDb(db)
    serial = await report_with(monkeypatch, serial_db, concurrency=1)
    parallel_db = ConcurrentQueryDb(db)
    parallel = await report_with(
        monkeypatch,
        parallel_db,
        concurrency=report_service.REPORT_QUERY_CONCURRENCY,
    )
    assert serial.items == parallel.items
    assert len(serial_db.calls) == len(parallel_db.calls) == 11
    assert serial_db.peak == 1
    assert 1 < parallel_db.peak <= report_service.REPORT_QUERY_CONCURRENCY


def timing_lines(caplog):
    return [
        record.getMessage()
        for record in caplog.records
        if "task_type_report_timing" in record.getMessage()
    ]


def sql_lines(caplog):
    return [
        record.getMessage()
        for record in caplog.records
        if report_service.SQL_LOG_TAG in record.getMessage()
    ]


@pytest.mark.asyncio
async def test_sql_log_prints_every_metric_query(service_db, caplog):
    """排查入口：每条查询打印 SQL 与绑定参数，一眼看到指标口径。"""
    caplog.set_level(
        logging.INFO, logger="monitor.app.services.cron.task_type_report"
    )
    await report_service.TaskTypeReportService().get_report(
        request_params(group_by="org"), "S", "100"
    )
    lines = sql_lines(caplog)
    # 名单快照在 QueryService 里执行，不属于本模块的日志范围。
    own_calls = [
        call
        for call in service_db.calls
        if "MIN(sync_date) AS earliest_date" not in call[0]
    ]
    assert len(own_calls) == 10
    assert len(lines) == len(own_calls)
    joined = "\n".join(lines)
    for sql, _ in own_calls:
        assert f"sql={sql} params=" in joined
    for name in (
        "roster_conflicts",
        "push_tasks",
        "ask_tasks",
        "active",
        "push_skills",
        "ask_skills",
        "push_customers",
        "ask_customers",
        "clicks",
        "permissions",
    ):
        assert f"query={name} " in joined
    assert all("status=ok" in line and "rows=" in line for line in lines)


@pytest.mark.asyncio
async def test_timing_log_names_slowest_stage(service_db, caplog):
    """排查入口：最外层阶段额外给出阶段数和最慢子阶段。"""
    caplog.set_level(
        logging.INFO, logger="monitor.app.services.cron.task_type_report"
    )
    await report_service.TaskTypeReportService().get_report(
        request_params(), "S", "100"
    )
    lines = timing_lines(caplog)
    total = [line for line in lines if "stage=get_report " in line]
    assert len(total) == 1
    assert "status=ok" in total[0] and "rows=3" in total[0]
    # 汇总字段只挂在最外层阶段，避免每条日志重复拼接。
    assert [line for line in lines if " slowest=" in line] == total
    summary = re.search(r"stages=(\d+) slowest=(\S+)", total[0])
    assert summary
    assert int(summary.group(1)) == len(lines)
    assert f"stage={summary.group(2)} " in "\n".join(lines)


@pytest.mark.asyncio
async def test_resolve_names_and_ambiguity(service_db):
    service = report_service.TaskTypeReportService()
    result = await service.get_report(
        request_params(first_bbk_name="甲分行", org_name="同名支行"),
        "S",
        "100",
    )
    assert result.resolved_filters.first_bbk_id == "001"
    assert result.resolved_filters.org_id == "01"
    assert (
        len(service_db.calls) == 16
    )  # 名称解析后补查机构范围，避免通过名称绕过范围。
    assert all("甲分行" not in sql for sql, _ in service_db.calls)
    with pytest.raises(report_service.ReportError) as exc:
        await service.get_report(
            request_params(org_name="同名支行"), "S", "100"
        )
    assert exc.value.code == "organization_name_ambiguous"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "filters",
    [
        {"first_bbk_name": "无此分行"},
        {"first_bbk_name": "甲分行", "first_bbk_id": "002"},
    ],
)
async def test_unmatched_names_never_fall_back_to_all_rows(
    service_db, filters
):
    if "first_bbk_id" in filters:
        with pytest.raises(report_service.ReportError) as exc:
            await report_service.TaskTypeReportService().get_report(
                request_params(**filters), "S", "100"
            )
        assert exc.value.status_code == 403
        return
    result = await report_service.TaskTypeReportService().get_report(
        request_params(**filters), "S", "100"
    )
    assert result.items == []
    assert "no_matching_organization" in result.warnings
    assert len(service_db.calls) == 2


@pytest.mark.asyncio
async def test_empty_roster_short_circuit(service_db):
    service_db.connection.execute("DELETE FROM jkh_user_inf")
    result = await report_service.TaskTypeReportService().get_report(
        request_params(), "S", "100"
    )
    assert result.items == [] and result.sync_date is None
    assert "empty_roster" in result.warnings
    assert len(service_db.calls) == 1


@pytest.mark.asyncio
async def test_conflicting_roster_service_error(service_db):
    service_db.connection.execute(
        "INSERT INTO jkh_user_inf VALUES ('alice','2026-09-13','999','999','冲突','冲突')"
    )
    with pytest.raises(report_service.ReportError) as exc:
        await report_service.TaskTypeReportService().get_report(
            request_params(), "S", "100"
        )
    assert exc.value.code == "jkh_roster_ambiguous"
    assert len(service_db.calls) == 2


@pytest.mark.asyncio
async def test_service_concurrent_scopes_are_isolated(service_db):
    service = report_service.TaskTypeReportService()
    first, second = await asyncio.gather(
        service.get_report(request_params(first_bbk_id="001"), "S", "100"),
        service.get_report(
            request_params(first_bbk_id="002", end_date="2026-09-14"),
            "OTHER",
            "100",
        ),
    )
    assert first.source_id == "S" and first.items[0].suc_execute_job == 1
    assert first.items[0].permission_manager_count == 1
    assert second.source_id == "OTHER" and second.items == []
    assert second.end_date == date(2026, 9, 14)


@pytest.mark.asyncio
async def test_database_unavailable(service_db, monkeypatch):
    service_db.is_connected = False
    with pytest.raises(report_service.ReportError) as exc:
        await report_service.TaskTypeReportService().get_report(
            request_params(), "S", "100"
        )
    assert exc.value.status_code == 503
    assert service_db.calls == []


@pytest.mark.asyncio
async def test_real_app_with_database_queries(service_db):
    import httpx
    from monitor.app._app import app

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get(
            "/api/monitor/cron/task-type-report",
            params={"start_date": "2026-09-13", "end_date": "2026-09-13"},
            headers={"X-Source-Id": "S", "X-Bbk-Id": "100"},
        )
    assert response.status_code == 200
    rows = response.json()["items"]
    assert len(rows) == 3
    assert rows[0]["read_rate"] == 200.0
    assert rows[1]["active_manager_count"] is None
    assert rows[2]["click_to_phone_rate"] is None
    assert len(service_db.calls) == 11


def test_ask_uses_spans_without_trace_table_or_read_events(db, scope):
    db.execute("DROP TABLE swe_tracing_traces")
    db.execute("DELETE FROM swe_html_preview_click_events")
    results = execute(db, scope)
    ask = assemble(results, "overall")[1]
    assert ask["suc_execute_job"] == 2
    assert ask["read_tasks"] == 2
    assert ask["read_rate"] == 100.0
    assert ask["skill_count"] == 2
    assert ask["recommended_customers"] == 2
    assert ask["read_customer_count"] == 0


def test_ask_clicks_do_not_require_trace_table(db, scope):
    db.execute("DROP TABLE swe_tracing_traces")
    ask = assemble(execute(db, scope), "overall")[1]
    assert ask["read_customer_count"] == 2
    assert ask["read_tasks"] == ask["suc_execute_job"] == 2


def test_ask_filters_span_time_user_source_and_skill(db, scope):
    db.execute("DROP TABLE swe_tracing_traces")
    db.execute("UPDATE swe_tracing_spans SET has_error = NULL")
    # Same trace with an out-of-window skill must not add that skill.
    db.execute("INSERT INTO swe_marketplace_skills VALUES ('S','outside',1)")
    db.execute(
        "INSERT INTO swe_tracing_spans VALUES ('extra','a1','S','outside','alice','2026-09-14 00:00:00',0)"
    )
    assert assemble(execute(db, scope), "overall")[1]["skill_count"] == 2
    # Keep only one in-window trace in the roster, regardless of error flags.
    db.execute(
        "UPDATE swe_tracing_spans SET start_time = '2026-09-14 00:00:00' WHERE trace_id = 'a1'"
    )
    ask = assemble(execute(db, scope), "overall")[1]
    assert ask["suc_execute_job"] == ask["read_tasks"] == 1
    for column, value in (
        ("source_id", "OTHER"),
        ("user_id", "outsider"),
        ("skill_id", ""),
    ):
        db.execute("SAVEPOINT filter_case")
        db.execute(
            f"UPDATE swe_tracing_spans SET {column} = ? WHERE trace_id = 'aerr'",
            (value,),
        )
        ask = assemble(execute(db, scope), "overall")[1]
        assert ask["suc_execute_job"] == ask["read_tasks"] == 0
        assert ask["read_rate"] is None
        db.execute("ROLLBACK TO filter_case")
        db.execute("RELEASE filter_case")
