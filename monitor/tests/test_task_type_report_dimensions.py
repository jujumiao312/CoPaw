# -*- coding: utf-8 -*-
"""六种报表维度的真实 SQL 对账及经理元数据、技能展开边界。"""

from dataclasses import replace

import httpx
import pytest

from .test_task_type_report_queries import (
    db,
    scope,
    service_db,
    execute,
    request_params,
)
from monitor.app.services.cron.task_type_report import (
    TaskTypeReportService,
    assemble,
)
from monitor.app.services.cron.task_type_report_sql import build_queries


@pytest.fixture
def dimension_db(db):
    db.execute("ALTER TABLE jkh_user_inf ADD COLUMN user_name TEXT")
    db.execute("ALTER TABLE jkh_user_inf ADD COLUMN pst_lvl TEXT")
    db.execute(
        "UPDATE jkh_user_inf SET user_name = '张经理', pst_lvl = 'L1' WHERE user_id = 'alice'"
    )
    db.execute(
        "UPDATE jkh_user_inf SET user_name = '李经理', pst_lvl = 'L2' WHERE user_id = 'bob'"
    )
    db.execute("ALTER TABLE swe_marketplace_skills ADD COLUMN cn_name TEXT")
    db.execute(
        "UPDATE swe_marketplace_skills SET cn_name = '技能甲' WHERE skill_id = 'k1'"
    )
    db.execute(
        "UPDATE swe_marketplace_skills SET cn_name = '技能乙' WHERE skill_id = 'k2'"
    )
    return db


def find_row(rows, task="push_plan", user=None, skill=None, branch="001"):
    return next(
        row
        for row in rows
        if row["task_type"] == task
        and row["user_id"] == user
        and row["skill_id"] == skill
        and row["first_bbk_id"] == branch
    )


@pytest.mark.parametrize("group_by", ["branch", "org", "manager"])
@pytest.mark.parametrize("skill_detail", [False, True])
def test_six_combinations_execute_all_queries(
    dimension_db, scope, group_by, skill_detail
):
    scoped = replace(scope, group_by=group_by, skill_detail=skill_detail)
    results = execute(dimension_db, scoped)
    assert len(build_queries(scoped)) == 10
    rows = assemble(results, group_by, skill_detail)
    assert len(rows) == (6 if skill_detail else 3)
    user = "alice" if group_by == "manager" else None
    row = find_row(rows, user=user, skill="k1" if skill_detail else None)
    assert row["suc_execute_job"] == 1
    assert row["read_tasks"] == 2
    assert row["read_rate"] == 200
    assert row["permission_manager_count"] == 1
    assert row["active_manager_count"] == 1
    assert row["skill_count"] == (1 if skill_detail else 2)
    assert row["recommended_customers"] == 2
    assert row["read_customer_count"] == 1
    assert row["insight_customer_count"] == row["phone_customer_count"] == 1
    assert row["insight_count"] == row["phone_count"] == 2
    assert row["plan_read_rate"] == 50
    if group_by == "manager":
        assert (row["user_name"], row["sapid"], row["pst_lvl"]) == (
            "张经理",
            "alice",
            "L1",
        )
        assert (row["first_bbk_name"], row["org_name"]) == (
            "甲分行",
            "同名支行",
        )
    else:
        assert row["user_name"] is None and row["sapid"] is None
    if skill_detail:
        assert row["cn_name"] == "技能甲"
        assert all(r["skill_count"] in (0, 1) for r in rows)
        # k2 did not occur on aerr. Trace-wide self-join would overcount it.
        ask_k2 = find_row(rows, task="ask_plan", user=user, skill="k2")
        assert ask_k2["suc_execute_job"] == ask_k2["read_tasks"] == 1
        assert ask_k2["recommended_customers"] == 1
        assert ask_k2["read_customer_count"] == 1
    other = find_row(
        rows,
        task="push_other",
        user=user,
        skill="k1" if skill_detail else None,
    )
    assert other["suc_execute_job"] == 1
    assert other["read_customer_count"] is None
    assert other["insight_count"] is None and other["phone_count"] is None


def test_manager_counts_use_each_fact_actor(dimension_db, scope):
    dimension_db.execute(
        "UPDATE swe_cron_jobs SET tenant_id = 'bob' WHERE id = 'j1'"
    )
    dimension_db.execute(
        "UPDATE swe_html_preview_click_events SET user_id = 'bob' WHERE cron_task_id = 'j1'"
    )
    dimension_db.execute(
        "UPDATE swe_tracing_spans SET user_id = 'bob' WHERE trace_id = 'aerr'"
    )
    for detail in (False, True):
        scoped = replace(scope, group_by="manager", skill_detail=detail)
        rows = assemble(execute(dimension_db, scoped), "manager", detail)
        skill = "k1" if detail else None
        alice = find_row(rows, user="alice", skill=skill)
        bob = find_row(rows, user="bob", skill=skill, branch="002")
        assert alice["suc_execute_job"] == 1 and bob["suc_execute_job"] == 0
        assert (
            alice["active_manager_count"] == 0
            and bob["active_manager_count"] == 1
        )
        assert (
            alice["read_customer_count"] == 0
            and bob["read_customer_count"] == 1
        )
        assert bob["user_name"] == "李经理" and bob["pst_lvl"] == "L2"
        bob_ask = find_row(rows, "ask_plan", "bob", skill, "002")
        assert bob_ask["suc_execute_job"] == bob_ask["read_tasks"] == 1


def test_skills_are_distinct_by_id_not_name_and_source(dimension_db, scope):
    dimension_db.execute(
        "UPDATE swe_marketplace_skills SET cn_name = '相同名' WHERE source_id = 'S'"
    )
    dimension_db.execute(
        "INSERT INTO swe_marketplace_skills VALUES ('OTHER','k1',1,'其他来源')"
    )
    dimension_db.execute(
        "INSERT INTO swe_marketplace_skills VALUES ('S','unused',1,'未使用')"
    )
    scoped = replace(scope, group_by="branch", skill_detail=True)
    rows = assemble(execute(dimension_db, scoped), "branch", True)
    assert {r["skill_id"] for r in rows} == {"k1", "k2"}
    assert {r["cn_name"] for r in rows} == {"相同名"}
    assert all(r["first_bbk_id"] == "001" for r in rows)
    assert (
        sum(
            r["suc_execute_job"] for r in rows if r["task_type"] == "push_plan"
        )
        == 2
    )
    assert (
        assemble(execute(dimension_db, scope), "overall")[0]["suc_execute_job"]
        == 1
    )


def test_skill_detail_filters_catalog_without_changing_summary(
    dimension_db, scope
):
    dimension_db.execute(
        "UPDATE swe_marketplace_skills SET include_in_statistics = 0 WHERE skill_id = 'k2'"
    )
    dimension_db.execute(
        "UPDATE swe_marketplace_skills SET cn_name = '' WHERE skill_id = 'k1'"
    )
    scoped = replace(scope, group_by="branch", skill_detail=True)
    rows = assemble(execute(dimension_db, scoped), "branch", True)
    assert {r["skill_id"] for r in rows} == {"k1"}
    assert all(r["cn_name"] is None for r in rows)
    dimension_db.execute(
        "UPDATE swe_marketplace_skills SET include_in_statistics = 0"
    )
    assert assemble(execute(dimension_db, scoped), "branch", True) == []
    assert (
        assemble(execute(dimension_db, scope), "overall")[0]["suc_execute_job"]
        == 1
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("group_by", ["branch", "org", "manager"])
@pytest.mark.parametrize("skill_detail", [False, True])
async def test_six_modes_through_real_app(
    dimension_db, service_db, group_by, skill_detail
):
    from monitor.app._app import app

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get(
            "/api/monitor/cron/task-type-report",
            params={
                "start_date": "2026-09-13",
                "end_date": "2026-09-13",
                "group_by": group_by,
                "skill_detail": str(skill_detail).lower(),
            },
            headers={"X-Source-Id": "S", "X-Bbk-Id": "100"},
        )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["skill_detail"] is skill_detail
    assert len(service_db.calls) == 11
    if skill_detail:
        assert "skill_rows_not_additive" in body["warnings"]
    if group_by == "manager":
        assert body["items"][0]["user_name"] == "张经理"


@pytest.mark.asyncio
async def test_sparse_dimensions_and_fixed_query_count(
    dimension_db, service_db
):
    # Many roster entries and catalog skills without activity must not cross join.
    dimension_db.executemany(
        "INSERT INTO jkh_user_inf (user_id,sync_date,first_bbk_id,org_id,user_name) VALUES (?,'2026-09-13','999','999',?)",
        [(str(i), str(i)) for i in range(100)],
    )
    dimension_db.executemany(
        "INSERT INTO swe_marketplace_skills VALUES ('S',?,1,?)",
        [(f"unused{i}", str(i)) for i in range(100)],
    )
    result = await TaskTypeReportService().get_report(
        request_params(group_by="manager", skill_detail=True), "S", "100"
    )
    assert len(result.items) == 6
    assert len(service_db.calls) == 11
    result = await TaskTypeReportService().get_report(
        request_params(
            group_by="manager", skill_detail=True, first_bbk_id="999"
        ),
        "S",
        "100",
    )
    assert result.items == []
    assert "no_matching_skills" in result.warnings


def test_permission_denominator_repeats_per_skill(dimension_db, scope):
    dimension_db.execute(
        "INSERT INTO jkh_user_inf VALUES ('second','2026-09-13','001','01','甲分行','同名支行','第二经理','L2')"
    )
    dimension_db.execute(
        "INSERT INTO swe_tenant_init_source VALUES ('second','S')"
    )
    scoped = replace(scope, group_by="branch", skill_detail=True)
    rows = assemble(execute(dimension_db, scoped), "branch", True)
    assert len(rows) == 6
    assert all(row["permission_manager_count"] == 2 for row in rows)
    assert find_row(rows, skill="k1")["suc_execute_job"] == 1


def test_skill_detail_keeps_deleted_job_and_click_time_rules(
    dimension_db, scope
):
    scoped = replace(scope, group_by="manager", skill_detail=True)
    dimension_db.execute(
        "UPDATE swe_cron_jobs SET status='deleted', deleted_at='2026-09-14' WHERE id='j1'"
    )
    rows = assemble(execute(dimension_db, scoped), "manager", True)
    push = find_row(rows, user="alice", skill="k1")
    assert push["suc_execute_job"] == 1
    assert push["recommended_customers"] == 2
    assert push["skill_count"] == push["active_manager_count"] == 0
    assert push["read_customer_count"] == 0
    ask = find_row(rows, task="ask_plan", user="alice", skill="k1")
    assert ask["suc_execute_job"] == 2
    assert (
        ask["read_customer_count"] == 2
    )  # includes old task viewed this period
