# 任务类型报表（task-type）2026-10-21 迭代总结

> 本文是 2026-10-21 两次迭代的交接与知识沉淀，供后续 AI Coding / 维护者快速定位。
> 接口契约真源：`docs/superpowers/specs/2026-09-18-task-type-report-snapshot/API.md`
> 指标口径：`docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md`、`DIMENSIONS.md`

## 1. 有效知识（接口是什么、代码在哪）

### 1.1 接口定位

「claw 技能运行看板」的 task-type 查询接口有两套，前端已切到快照接口：

| 类别 | 前缀 | 说明 |
| --- | --- | --- |
| 快照接口 | `/api/monitor/report/task-type*` | 读预聚合落盘表 `swe_rm_claw_list_ind_stat`（高斯 → TDSQL），本次两个迭代的主目标 |
| 在线接口 | `/api/monitor/cron/task-type-report*` | 按明细实时统计，本次只同步了「有权限客户经理数」口径 |

快照接口五个端点：

| 端点 | 作用 |
| --- | --- |
| `GET /task-type` | 主查询（七种组合、三类任务） |
| `GET /task-type/export` | 全量 XLSX 导出（必须指定 `task_type`，不能分页） |
| `GET /task-type/options` | 分行 / 支行 / 技能下拉选项 |
| `GET /task-type/dates` | 可用跑数日期（前端默认选 `latest_ready_prt_dt`） |
| `GET /task-type/status` | 批次信息 + 七组合行数核对 |

### 1.2 代码位置速查

路径相对 `monitor/`。

| 内容 | 路径 |
| --- | --- |
| 快照路由 | `src/monitor/app/routers/task_type_snapshot.py` |
| 快照服务（过滤/排序/分页/装配/权限人数） | `src/monitor/app/services/report/task_type_snapshot.py` |
| 快照模型 | `src/monitor/app/models/task_type_snapshot.py` |
| 在线 SQL（`permissions` 权限查询等） | `src/monitor/app/services/cron/task_type_report_sql.py` |
| 在线服务 / 名称解析 / 范围校验 | `src/monitor/app/services/cron/task_type_report.py` |
| 在线行组装与派生比例 | `src/monitor/app/services/cron/task_type_report_rows.py` |
| XLSX 导出 | `src/monitor/app/services/cron/task_type_report_export.py` |
| 快照表 DDL | `src/monitor/app/database/schema.py` |
| 路由挂载 | `src/monitor/app/routers/__init__.py` |
| 快照测试 | `tests/test_task_type_report_snapshot.py` |
| 在线 SQL 测试 | `tests/test_task_type_report_queries.py` |
| 在线维度测试 | `tests/test_task_type_report_dimensions.py` |
| 在线范围/选项/导出测试 | `tests/test_task_type_report_console.py` |

### 1.3 主查询数据流

`TaskTypeSnapshotService.get_report` 执行顺序：

1. `enforce_branch`：`X-Bbk-Id` 不是 `100` 时强制把 `first_bbk_id` 收窄到该分行。
2. `_load_batch` + `_require_ready`：按 `dw_dat_dt + source_id` 找快照批次，无行返回 404 `report_snapshot_not_found`。
3. `_resolve_scope`：复用在线 `resolve_organization_filters` 做机构名称解析；`validate_roster_scope` 已跳过（行内专属）。
4. `validate_filter_scope`：筛选维度必须落在所选组合维度上，否则 422 `report_filter_not_supported`。
5. `build_filters` → `_collect_rows`：拼 WHERE、排序、分页或全量截断（上限 200000）。
6. `_fetch_permission_counts`：仅 overall / branch / org 汇总实时统计权限人数。
7. `_to_row` 装配 → `build_response`（warnings / batch / resolved_filters）。

### 1.4 核心概念

- **`rpt_combo` 组合映射**：`(group_by, skill_detail)` → `overall / branch / org / manager / branch_skill / org_skill / manager_skill`；`group_by=skill` 复用 `manager_skill`（行仍按 客户经理 × 技能 展开）。
- **有权限客户经理数 `permission_manager_count`**：
  - 落盘表不存该列，接口实时计算；
  - 口径（2026-10-21 起）：左表为「当前 source 下未删除定时任务去重后的租户」
    `SELECT DISTINCT tenant_id FROM swe_cron_jobs WHERE status <> 'deleted' AND source_id = <当前 source>`，
    `LEFT JOIN jkh_user_inf`（`sync_date = end_date` 且 `user_id <> ''`）过滤有效金葵花，`COUNT(DISTINCT user_id)`；
  - 仅 overall / branch / org 汇总返回；manager / skill / 技能明细返回 `null`；
  - 支行按 `first_bbk_id + org_id` 统计该支行人数，而非整分行。
- **`skill_cnt`（技能总数）**：
  - 2026-10-21 起主查询不再过滤 `skill_cnt > 0`（之前仅 `overall` 不过滤，其余维度过滤），技能总数为 0 的行也返回；
  - 技能下拉 `options?kind=skills` 仍保留 `skill_cnt <> 0`，未改。
- **`'ALL'` 与空串**：落盘表对本组合用不到的维度写 `'ALL'`，接口还原为 `null`；空串表示「名单里缺机构号」的真实分组，保留不还原。

### 1.5 测试运行

```powershell
# Windows（当前仓库是 Windows venv）
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_snapshot.py -q
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_queries.py tests/test_task_type_report_dimensions.py tests/test_task_type_report_console.py -q
```

Linux 用 `venv/bin/python -m pytest ...`。SQLite 只验证逻辑与 SQL 形状，不代表 TDSQL 方言与性能。

### 1.6 已知坑（下次 AI Coding 注意）

- **GitNexus 索引损坏**：`impact` / `detect-changes` 均报 `LadybugDB` 版本不匹配（42 vs 41），返回 `risk: UNKNOWN`。需用文本 grep 兜底确认调用方。
- **全量 `pytest` 收集失败（历史问题，与本次无关）**：`tests/test_async_tasks_query_api.py` 在模块导入时
  `sys.modules.setdefault("openpyxl", stub)` 污染了 `openpyxl`，导致其后收集 `openpyxl` 的用例报
  `No module named 'openpyxl.cell'`。单文件 / 分组运行正常。
- **`swe_tenant_init_source` 无 monitor 侧 DDL**：该表由 CoPaw 后端维护，改动权限口径时需确认现场表存在；本次已改为读 `swe_cron_jobs`。
- 测试 fixture 中仍残留 `swe_tenant_init_source` 插数（`test_task_type_report_console.py`、`test_task_type_report_queries.py`），现已无人读取、无害。

## 2. 改动记录（2026-10-21）

### 2.1 迭代 1：主查询不再过滤技能总数为 0 的行

- **位置**：`src/monitor/app/services/report/task_type_snapshot.py` 的 `build_filters()`。
- **意图**：删除 `skill_cnt > 0` 过滤。此前该过滤对 `skill_detail=True` 或 `group_by ∈ (branch, org, manager, skill)` 生效，`overall` 本来不过滤；现在所有维度统一不过滤。
- **影响**：主查询 / 分页 `total` / 导出都会返回技能总数为 0 的行；技能下拉 options 仍过滤，不受影响。

### 2.2 迭代 2：有权限客户经理数取数口径

- **位置**：
  - 快照：`src/monitor/app/services/report/task_type_snapshot.py` 的 `_fetch_permission_counts()`；
  - 在线：`src/monitor/app/services/cron/task_type_report_sql.py` 的 `permissions` 查询。
- **意图**：左表由 `swe_tenant_init_source` 改为
  `(SELECT DISTINCT tenant_id FROM swe_cron_jobs WHERE status <> 'deleted' AND source_id = <source>)`，
  再 `LEFT JOIN jkh_user_inf` 过滤最终有效的金葵花客户经理。
- **决策确认**：
  - Q1 保留 `source_id` 过滤（方案 B）→ 子查询带 `AND source_id = %s`；
  - Q2 不叠加 `deleted_at IS NULL`，仅 `status <> 'deleted'`；
  - Q3 在线接口 `task_type_report_sql.py` 同步修改。
- **影响**：`permission_manager_count` 语义不变（仍按 source 隔离、只统计有效金葵花），来源表从「初始化来源」换成「未删除定时任务」。

### 2.3 测试改动

- `tests/test_task_type_report_snapshot.py`：`swe_tenant_init_source` → `swe_cron_jobs`（表结构 + seed + 3 处插数）；删除 `skill_cnt > 0` 的 SQL 断言；三个「零技能过滤」用例改写为「零技能保留」。
- `tests/test_task_type_report_dimensions.py`：`second` 经理改为插入 `swe_cron_jobs`。
- **验证**：snapshot 64 通过；task-type 相关 5 个测试文件共 218 通过。

### 2.4 文档同步

- 更新 `docs/superpowers/specs/2026-09-18-task-type-report-snapshot/API.md`：`swe_tenant_init_source` → `swe_cron_jobs`；移除 / 改写 `skill_cnt > 0` 相关表述。

## 3. 阅读顺序

1. 本文：了解定位、代码位置与本次改动。
2. `../2026-09-18-task-type-report-snapshot/API.md`：快照接口契约（已同步本次改动）。
3. `../2026-09-13-jkh-task-report/DESIGN.md`、`DIMENSIONS.md`：14 指标口径与六种维度组合。
