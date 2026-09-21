# 任务类型报表落盘接口（/api/monitor/report/task-type*）

更新：2026-09-20。本文是落盘接口的契约真源。指标口径仍以
[../2026-09-13-jkh-task-report/DESIGN.md](../2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../2026-09-13-jkh-task-report/DIMENSIONS.md) 为准；本文只说明数据来源替换成
数仓预聚合落盘表（高斯 → TDSQL）之后的参数、响应与差异。

## 1. 定位与数据来源

| 项 | 内容 |
| --- | --- |
| 目标 | 把 `/task-type-report`、`/task-type-report/export` 的全部能力改为读预聚合表，降低 TDSQL 明细扫描压力 |
| 数据表 | `swe_task_type_report_snapshot`（报表行）、`swe_task_type_report_batch`（批次状态与名单快照日） |
| 表结构 | `gauss/task_type_report_tdsql.sql`（建表语句 + 写入约定；权威结构是 `src/monitor/app/database/schema.py`） |
| 数据写入 | 由现场作业自行写入，本仓库不提供装载脚本；写入方须按该文件第 3 节遵守列语义（`'ALL'`、NULL 规则）、批次就绪信号与 `sync_date` 约定 |
| 行覆盖 | 主键 `(prt_dt, source_id, dim_hash)`，同键 upsert 即幂等重写；源侧已消失的维度行若没被清掉会继续出数，属已确认取舍 |
| 有权限客户经理数 | `permission_manager_count` **不在数据源里**（高斯表与落盘表都不存该列），由接口按批次 `sync_date` 的 `jkh_user_inf` + 当前 source 的 `swe_tenant_init_source` 实时计算；技能明细组合沿用它所在层级的维度统计；批次缺 `sync_date` 返回 409，不会返回全 0 |
| 在线接口 | `/api/monitor/cron/task-type-report`、`/export`、`/options` 保持不变，仍按明细实时统计 |
| 代码 | `routers/task_type_snapshot.py`、`services/report/task_type_snapshot.py`、`models/task_type_snapshot.py` |
| 历史链路 | Hive 版（`hive/task_type_report_tdsql.sql`）保留作参考，其建表语句已过时，以 `schema.py` 为准 |

接口前缀 `/api/monitor/report`，五个接口：

| 接口 | 作用 | 对应在线接口 |
| --- | --- | --- |
| `GET /task-type` | 主查询（七种组合、三类任务） | `GET /task-type-report` |
| `GET /task-type/export` | 全量 XLSX 导出 | `GET /task-type-report/export` |
| `GET /task-type/options` | 分行/支行下拉选项 | `GET /task-type-report/options` |
| `GET /task-type/dates` | 可用跑数日期与批次状态 | 新增 |
| `GET /task-type/status` | 批次就绪与七组合行数核对 | 新增 |

## 2. 通用约定

- 请求头：主查询、导出、选项、状态接口都必须带 `X-Source-Id`、`X-Bbk-Id`；
  `X-Bbk-Id` 不是 `100` 时强制把 `first_bbk_id` 固定为该值，与在线接口共用 `enforce_branch`。
- 错误结构：与在线接口一致；参数问题 422 `report_validation_error`，
  跨分行 403 `report_scope_forbidden`，机构名称歧义 422 `organization_name_ambiguous`。
- 新增错误码：

  | 状态 | code | 含义 |
  | --- | --- | --- |
  | 404 | `report_snapshot_not_found` | 该跑数日期 + 来源没有出仓批次 |
  | 409 | `report_snapshot_not_ready` | 批次状态不是 `ready`（装载中/失败）或缺少名单快照日 |
  | 422 | `report_filter_not_supported` | 机构/人员筛选与所选组合维度不匹配 |

- 比例仍为百分点数值，零分母返回 `null`；`read_evidence` 与在线接口一致。

## 3. 主查询 GET /task-type

### 3.1 请求参数

| 参数 | 规则 |
| --- | --- |
| `end_date` | 必填，`YYYY-MM-DD`，= 跑数日期（落盘分区），同时是统计截止日 |
| `start_date` | 可选，只允许等于 `end_date` 当月 1 号；缺省取当月 1 号。其它区间返回 422 |
| `group_by` | `overall` / `branch` / `org` / `manager`，默认 `overall` |
| `skill_detail` | 默认 false；true 时 `group_by` 不能是 `overall` |
| `task_type` | 可选 `push_plan` / `ask_plan` / `push_other` |
| `first_bbk_id` / `first_bbk_name` | 分行筛选，需要组合含分行维度（见 3.4） |
| `org_id` / `org_name` | 网点筛选，需要组合含网点维度 |
| `user_id` | 客户经理筛选，只支持 `group_by=manager` |
| `keyword` | 最大 100 字符，仅 `group_by=manager`；匹配 `user_name` / `user_id` / `pst_lvl` |
| `page` / `page_size` | 成对出现，仅 `group_by=manager` 且指定 `task_type` 时可用；`page_size` 1..100 |

组合映射：`(group_by, skill_detail)` → `rpt_combo`，取值 `overall`、`branch`、`org`、
`manager`、`branch_skill`、`org_skill`、`manager_skill`，与落盘表标签一一对应。

### 3.2 响应

```json
{
  "metric_version": "jkh_task_report_v1_snapshot",
  "consistency": "snapshot",
  "timezone": "Asia/Shanghai",
  "source_id": "RMASSIST",
  "prt_dt": "2026-09-17",
  "start_date": "2026-09-01",
  "end_date": "2026-09-17",
  "group_by": "branch",
  "skill_detail": false,
  "rpt_combo": "branch",
  "sync_date": "2026-09-17",
  "resolved_filters": {"first_bbk_id": null, "org_id": null},
  "ratio_unit": "percent",
  "read_evidence": {"push": "execution_is_read", "ask": "assumed_from_success"},
  "warnings": ["period_ratios_not_cohort_conversion", "snapshot_month_to_date"],
  "batch": {
    "prt_dt": "2026-09-17", "source_id": "RMASSIST", "status": "ready",
    "stat_start_dt": "2026-09-01", "stat_end_dt": "2026-09-17",
    "sync_date": "2026-09-17", "row_total": 576123,
    "loaded_at": "2026-09-18T02:10:33"
  },
  "items": [
    {
      "first_bbk_id": "001", "first_bbk_name": "甲分行",
      "org_id": null, "org_name": null,
      "user_id": null, "user_name": null, "sapid": null, "pst_lvl": null,
      "skill_id": null, "cn_name": null,
      "task_type": "push_plan", "task_type_name": "推送(名单+方案)",
      "skill_count": 36, "permission_manager_count": 1280,
      "active_manager_count": 212, "suc_execute_job": 3021,
      "read_tasks": 2870, "read_rate": 95.0,
      "recommended_customers": 15320, "read_customer_count": 4210,
      "plan_read_rate": 27.48, "insight_customer_count": 1330,
      "click_to_insight_rate": 8.68, "insight_count": 1520,
      "phone_customer_count": 640, "click_to_phone_rate": 4.18,
      "phone_count": 700
    }
  ],
  "page": null, "page_size": null, "total": 150, "has_more": false
}
```

`items` 行结构与在线接口完全相同（含 `permission_manager_count`），前端无需改字段；
不同点：

1. `metric_version` 为 `jkh_task_report_v1_snapshot`，`consistency` 为 `snapshot`；
2. 新增 `prt_dt` / `rpt_combo` / `batch` 三个字段，说明数据来自哪个批次；
3. `start_date` 固定为当月 1 号，`warnings` 固定包含 `snapshot_month_to_date`；
4. 不适用维度返回 `null`：上游对“本组合用不到的维度”落的是 `'ALL'`（含名称列，
   见 [gauss/README.md](../../../gauss/README.md) 第 4 节），接口按组合维度与 `'ALL'`
   两种判据还原成 `null`；机构维度存在但名单里缺机构号时返回空串（与在线接口一致）。

`warnings` 顺序：`period_ratios_not_cohort_conversion` → `snapshot_month_to_date` →
（技能明细）`skill_rows_not_additive` → （无匹配）`no_matching_organization` /
`no_matching_skills` → （截断）`report_rows_truncated`。

### 3.3 分页与截断

- 传 `page`/`page_size` 时返回该页并给出 `total`、`has_more`，与在线接口分页语义一致；
- 不传分页时一次返回全量，但最多 `200000` 行；触及上限会截断并附
  `report_rows_truncated`，`total` 为返回行数。需要全量请用导出接口。

### 3.4 筛选与组合维度矩阵

落盘表把每个组合单独聚合，因此筛选必须落在该组合包含的维度上（否则返回 422
`report_filter_not_supported`）：

| 组合 | 支持的分行筛选 | 支持的网点筛选 | 支持的经理筛选 |
| --- | --- | --- | --- |
| `overall` | 否 | 否 | 否 |
| `branch` / `branch_skill` | 是 | 否 | 否 |
| `org` / `org_skill` | 是 | 是 | 否 |
| `manager` / `manager_skill` | 是 | 是 | 是 |

需要“总体只在某分行范围内”的口径时，请用 `branch` 组合按分行筛选，或调用在线接口。

## 4. 导出 GET /task-type/export

与在线导出相同：必须指定 `task_type`，不能传 `page`/`page_size`，其余筛选参数与主查询一致。
返回真实 XLSX（工作表名 `统计报表` 或 `技能明细`，列集合按组合与任务类型裁剪），
超过 `50000` 行返回 413 `report_export_too_large`，`Content-Disposition` 暴露给前端。

## 5. 选项 GET /task-type/options

参数 `end_date`、`kind=branches|orgs`、可选 `first_bbk_id`（查支行选项时必须指定分行）。
名单快照日取该批次记录的 `sync_date`，取值逻辑与在线接口一致；批次缺少 `sync_date` 返回 409。

## 6. 日期 GET /task-type/dates

参数：`month`（可选 `YYYY-MM`）、`limit`（1..90，默认 30）。返回按 `prt_dt` 倒序的批次列表：

```json
{
  "source_id": "RMASSIST",
  "latest_ready_prt_dt": "2026-09-17",
  "items": [
    {"prt_dt": "2026-09-18", "status": "loading", "row_total": 0,
     "stat_start_dt": "2026-09-01", "stat_end_dt": "2026-09-18",
     "loaded_at": "2026-09-19T02:10:33"},
    {"prt_dt": "2026-09-17", "status": "ready", "row_total": 576123,
     "stat_start_dt": "2026-09-01", "stat_end_dt": "2026-09-17",
     "loaded_at": "2026-09-18T02:10:33"}
  ]
}
```

## 7. 状态 GET /task-type/status

参数 `end_date`；返回批次信息、七个组合的行数与缺失组合（`missing_combos`），
用于出仓后核对完整性：

```json
{
  "batch": {"prt_dt": "2026-09-17", "source_id": "RMASSIST", "status": "ready",
            "row_total": 576123, "sync_date": "2026-09-17",
            "stat_start_dt": "2026-09-01", "stat_end_dt": "2026-09-17",
            "loaded_at": "2026-09-18T02:10:33"},
  "combo_counts": [{"rpt_combo": "manager_skill", "row_cnt": 421000}],
  "missing_combos": ["org_skill"]
}
```

批次不存在时返回 404，状态不是 ready 返回 409。

## 8. 前端切换指引

1. URL：`/api/monitor/cron/task-type-report` → `/api/monitor/report/task-type`，
   导出与选项同理；请求头不变。
2. 日期：把 `start_date`/`end_date` 改为只传 `end_date`（跑数日期），
   日期选择器数据源换成 `/task-type/dates`（默认选 `latest_ready_prt_dt`）。
3. 响应：行字段不变；如需提示“落盘口径”，读 `consistency` / `warnings` / `batch`。
4. 机构筛选：按 3.4 的矩阵限制可选范围（例如总体汇总不允许选分行）。

## 9. 测试与运行

```powershell
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_snapshot.py -q
```

测试覆盖组合映射、维度还原、NULL 语义、任务类型过滤与排序、分页与 `has_more`、
关键字转义、筛选维度限制、跨分行 403、名称歧义 422、批次 404/409、来源隔离、
日期/状态/选项接口、XLSX 导出列与参数校验。SQLite 只验证逻辑与 SQL 形状，
不代表 TDSQL 方言与性能；上线前需在目标环境核对执行计划与耗时。
