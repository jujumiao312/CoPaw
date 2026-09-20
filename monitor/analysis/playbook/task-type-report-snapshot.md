# 任务类型报表落盘接口

更新日期：2026-09-18。覆盖“Hive 预聚合 → 出仓 TDSQL → 落盘接口”这条链路的模块分工、
既定口径、修改指引与排查入口。指标口径真源仍是
[DESIGN.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)；
接口契约见
[API.md](../../docs/superpowers/specs/2026-09-18-task-type-report-snapshot/API.md)。

## 1. 阅读入口

| 场景 | 先读 |
| --- | --- |
| 改接口参数/响应、加错误码 | API.md 第 2~7 节 + 本文第 3、4 节 |
| 报表数字不对、口径与在线接口不一致 | 本文第 4 节，再比对 HIVE.md 的 `VT_METRIC_FACT` 分支 |
| 切换前端到底层落盘接口 | API.md 第 8 节 |
| 出仓/装载失败、接口报 404/409 | 本文第 5 节 + `hive/task_type_report_tdsql.sql` |
| 维护 Hive 跑数脚本 | [task-type-report-hive.md](task-type-report-hive.md) |

## 2. 模块分工

| 层 | 文件 | 职责 |
| --- | --- | --- |
| Hive 跑数 | `hive/task_type_report_daily.sql` | 每次重跑近 7 天 + 当天共 8 个分区，按月累计口径预聚合七个组合 |
| 出仓装载 | `hive/task_type_report_tdsql.sql` | TDSQL 建表 + loading/导入/ready 三段装载 |
| 表结构 | `src/monitor/app/database/schema.py` | `CREATE_TASK_TYPE_REPORT_SNAPSHOT_TABLE` / `_BATCH_TABLE`，服务启动自动建表 |
| 模型 | `src/monitor/app/models/task_type_snapshot.py` | 参数校验（区间只允许当月）、响应信封；行模型复用 `TaskTypeReportRow` |
| 服务 | `src/monitor/app/services/report/task_type_snapshot.py` | 批次校验、范围校验、过滤、排序、分页、装配、权限人数 |
| 路由 | `src/monitor/app/routers/task_type_snapshot.py` | 五个接口与错误码映射；复用在线模块的 `ReportRoute` / `report_errors` |
| 测试 | `tests/test_task_type_report_snapshot.py` | SQLite 验证 SQL 与装配，ASGI 验证契约与 XLSX |

## 3. 必须成立的不变量

1. **组合标签唯一真源**：`(group_by, skill_detail)` → `rpt_combo` 只在
   `services/report/task_type_snapshot.COMBO_MAP` 定义，表里的标签必须与
   `hive/task_type_report_daily.sql` 第 6 段的 `RPT_COMBO` 常量集合完全一致；
   新增组合要同时改 Hive 脚本、这里的两张表与前端。
2. **维度还原规则**：落盘表里“不适用维度”是空串，出参必须按
   `COMBO_DIM_COLUMNS` 把不适用维度还原成 `null`，否则前端会把空串当真实机构号。
   注意：上游 Hive 落数已改用 `'ALL'`（见 [task-type-report-hive.md](task-type-report-hive.md)
   第 3/4 节），出仓若不做转换，这里必须同时把 `'ALL'` 还原成 `null`。
3. **筛选必须落在组合维度上**：`FILTER_REQUIRED_GROUPS` 决定分行/网点/经理筛选的可用组合，
   不匹配直接 422 `report_filter_not_supported`，不能用其它组合的数字冒充。
4. **批次状态是唯一就绪信号**：接口只读 `status='ready'` 的批次；装载必须按
   「loading → 清分区 → 导入 → 核对七组合 → ready」顺序执行，避免查到半份数据。
5. **权限人数不入仓**：`permission_manager_count` 仍按批次 `sync_date` 的名单 +
   当前 source 的初始化来源实时统计，口径与在线接口一致；不要把该列塞进落盘表。
6. **区间只支持当月**：落盘表是月累计快照，`start_date` 只允许等于当月 1 号；
   任意区间继续走在线接口，不要在服务层做“减法”。
7. **分页与截断**：分页只在 `group_by=manager` 且指定 `task_type` 时可用；
   非分页查询最多返回 200000 行，截断要带 `report_rows_truncated`；导出沿用 50000 行上限。

## 4. 容易误读的既定口径

- `metric_version` 与在线接口不同（`..._snapshot`），`consistency` 为 `snapshot`，
  这不是新口径，而是提示调用方数据来自哪条链路；
- `warnings` 固定包含 `snapshot_month_to_date`，说明统计区间是“当月 1 号 ~ 跑数日期”；
- 机构名解析、跨分行 403、名称歧义 422 仍查名单表（批次记录的 `sync_date`），
  因此接口对名单有实时依赖，这不是漏改；
- 技能明细各列仍不可相加，汇总取不带 `_skill` 的组合；
- `overall` 组合不支持任何机构筛选（落盘表没有“某分行的总体”这一行）。

## 5. 排查入口

| 现象 | 先查 |
| --- | --- |
| 404 `report_snapshot_not_found` | `swe_task_type_report_batch` 是否有该 `prt_dt + source_id`；出仓是否漏跑 |
| 409 `report_snapshot_not_ready` | 批次 `status` 是否 `ready`；`sync_date` 是否为空 |
| 422 `report_filter_not_supported` | 是否用 overall/branch 组合做了网点或经理筛选（见 API.md 3.4） |
| 行数比在线接口少 | 先 `GET /task-type/status` 看 `missing_combos`，再看 Hive 侧第 6 段是否漏写某个组合 |
| 数字与在线接口不一致 | 比对三处：Hive `VT_METRIC_FACT` 分支的过滤条件、落盘表 `prt_dt` 是否对应同一跑数日期、在线接口的 `sync_date` 是否同一名单快照日 |
| 导出 413 | 组合 + 日期粒度太大，缩小筛选或按 `task_type` 分别导出 |
| 耗时异常 | 检查是否命中 `idx_swe_ttr_*`；关键字筛选会走 `LIKE`，只能靠 `prt_dt + source_id + rpt_combo` 收窄 |

核对 SQL：

```sql
-- 批次是否完整（七个组合都应有行）
SELECT rpt_combo, COUNT(*) FROM swe_task_type_report_snapshot
WHERE prt_dt = '2026-09-17' AND source_id = 'RMASSIST' GROUP BY rpt_combo;

-- 与在线接口对账：同一跑数日期、同一组合、同一机构
SELECT * FROM swe_task_type_report_snapshot
WHERE prt_dt = '2026-09-17' AND source_id = 'RMASSIST'
  AND rpt_combo = 'branch' AND first_bbk_id = '001';
```

## 6. 修改指引

| 新需求 | 修改位置 | 完成判据 |
| --- | --- | --- |
| 新增报表组合 | Hive 脚本第 4~6 段、`COMBO_MAP` / `EXPECTED_COMBOS` / `COMBO_DIM_COLUMNS`、`FILTER_REQUIRED_GROUPS`（如含新维度）、API.md | 组合标签一致、/status 不再报缺失、SQLite 与 ASGI 测试通过 |
| 新增指标列 | Hive 目标表与跑数脚本、`schema.py` 与 `hive/task_type_report_tdsql.sql` 建表、`_to_row` 映射、`TaskTypeReportRow`、导出列 | 两处 DDL 一致，导出列同步，行模型校验通过 |
| 调整筛选规则 | `FILTER_REQUIRED_GROUPS`、`build_filters` | 筛选规则与组合维度一致，422 场景补测试 |
| 修改装载方式 | `hive/task_type_report_tdsql.sql` 第 2 节 | 仍是 loading → 导入 → ready，重跑幂等 |
| 上游不改值直接上 `'ALL'` | 服务 `COMBO_DIM_COLUMNS` 的还原逻辑、`schema.py` 注释、本文件与 API.md | `'ALL'` 与空串都要按“不适用”还原成 `null`（Hive 侧现在落 `'ALL'`，见 [task-type-report-hive.md](task-type-report-hive.md) 第 3/4 节） |
| 客户经理维度新增当前活跃/暂停任务数 | `schema.py` 的 `CREATE_TASK_TYPE_REPORT_SNAPSHOT_TABLE`、`hive/task_type_report_tdsql.sql` 第 1/2/3 节、服务行模型与导出列、API.md 响应字段 | 落盘表在 `active_manager_cnt` 后新增 `active_job_cnt` + `paused_job_cnt`（Hive 侧 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`，仅客户经理维度有值），出仓列顺序与第 3 节一致，行模型与导出列同步；`active_manager_cnt` 保留给总体/分行/支行维度 |
| 切换接口前缀或参数命名 | `routers/task_type_snapshot.py`、API.md、前端 | 前端同步，旧接口不动 |

## 7. 验证与限制

- 新增测试 `tests/test_task_type_report_snapshot.py` 16 项通过；既有报表相关回归 219 项通过。
- SQLite 只验证 SQL 形状与装配逻辑，不代表 TDSQL 方言、索引命中与真实耗时；
  上线前需在目标 TDSQL 执行 EXPLAIN 并核对接口耗时与导出体积。
- 出仓链路（Hive 跑数 → 文件 → TDSQL 装载）尚未在真实环境联调，需要出仓侧确认
  文件列顺序、字符编码与空串约定。
