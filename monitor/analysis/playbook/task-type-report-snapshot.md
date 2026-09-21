# 任务类型报表落盘接口

更新日期：2026-09-20。覆盖“高斯预聚合 → 装载 TDSQL → 落盘接口”这条链路的模块分工、
既定口径、修改指引与排查入口。指标口径真源仍是
[DESIGN.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)；
接口契约见
[API.md](../../docs/superpowers/specs/2026-09-18-task-type-report-snapshot/API.md)。

## 1. 阅读入口

| 场景 | 先读 |
| --- | --- |
| 改接口参数/响应、加错误码 | API.md 第 2~7 节 + 本文第 3、4 节 |
| 报表数字不对、口径与在线接口不一致 | 本文第 4 节，再比对高斯脚本第 3 段的 `TF_METRIC_FACT` 分支 |
| 切换前端到底层落盘接口 | API.md 第 8 节 |
| 装载失败、接口报 404/409/500 | 本文第 5 节 + `gauss/task_type_report_tdsql.sql` |
| 维护数仓跑数脚本 | [task-type-report-hive.md](task-type-report-hive.md)（Hive 版）与 `gauss/README.md`（高斯版） |

## 2. 模块分工

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 高斯跑数 | `gauss/task_type_report_daily.sql` | 每次重跑近 7 天 + 当天共 8 天，按月累计口径预聚合七个组合到 `${AALC_DATA}.AALC_P_RM_CLAW_LIST_USE_IND_STAT` |
| 建表 | `gauss/task_type_report_tdsql.sql` | TDSQL 两张表的建表语句、历史库升级与写入约定；**数据由现场作业写入，本仓库不含装载脚本**；`hive/task_type_report_tdsql.sql` 为历史参考 |
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
2. **维度还原规则**：落盘表里“本组合用不到的维度”是 `'ALL'`（高斯落数口径）、“名单里缺
   机构号”是空串，两者含义不同。出参必须按 `COMBO_DIM_COLUMNS` 把不适用维度置 `null`，
   并由 `_text` / `_dim` 把 `'ALL'` 一并还原成 `null`（只有名称列把空串也还原成 `null`，
   机构号维度的空串是真实分组，必须保留）。结构上不适用维度本就落在组合维度之外，但仍要
   保留这层兜底：上游一旦把 `'ALL'` 写进组合维度，前端就会把 `ALL` 当机构号显示。
3. **筛选必须落在组合维度上**：`FILTER_REQUIRED_GROUPS` 决定分行/网点/经理筛选的可用组合，
   不匹配直接 422 `report_filter_not_supported`，不能用其它组合的数字冒充。
4. **批次状态是唯一就绪信号**：接口只读 `status='ready'` 的批次（不存在 404、非 ready 409）。
   写入方要自己保证「先置 loading → 写数据 → 核对行数写进 `row_total` → 置 ready」，
   半份数据或 0 行时不要置 ready，否则接口会把不完整、或上一版留下的数据当成当天数据返回。
   批次还必须有 `sync_date`（见第 3 条与第 5 条），否则接口直接 409。
5. **权限人数不入仓**：`permission_manager_count` 仍按批次 `sync_date` 的名单 +
   当前 source 的初始化来源实时统计，口径与在线接口一致；不要把该列塞进落盘表。
6. **区间只支持当月**：落盘表是月累计快照，`start_date` 只允许等于当月 1 号；
   任意区间继续走在线接口，不要在服务层做“减法”。
7. **分页与截断**：分页只在 `group_by=manager` 且指定 `task_type` 时可用；
   非分页查询最多返回 200000 行，截断要带 `report_rows_truncated`；导出沿用 50000 行上限。
8. **表结构跟随高斯源**：列宽对齐高斯源表（`skill_id` 500、分行/经理号 200、名称列
   500/1000），否则装载会截断或报 1406；维度唯一性用 `dim_hash = MD5(组合 + 四个维度列)`，
   因为自然维度列拼出的唯一键超过 InnoDB 3072 字节上限（ERROR 1071）；
   `stat_start_dt` / `stat_end_dt` 高斯侧不落列，装载时由 `prt_dt` 推导；批次状态与
   `sync_date` 高斯侧也没有，仍由装载维护（`sync_date` 必须由调度传入）。
9. **列名一致性**：服务查询的列必须都建在表里。历史缺陷：表列是 `insight_customer_cnt`，
   服务曾按 `insight_customer_count` 查询，SQLite 夹具与真实 DDL 不一致所以测试没暴露，
   真实 TDSQL 上所有主查询都会 500（`Unknown column`）。夹具现在按真实列名维护，并由
   `tests/test_task_type_report_snapshot.py::test_selected_columns_exist_in_table_ddl` 兜底。
10. **行的覆盖与残留由写入方负责（已确认的取舍）**：接口不做版本过滤、也不做软删除，
    只按主键 `(prt_dt, source_id, dim_hash)` 读当前表里的行。
    写入方若无法删除旧行（例如账号只有 SELECT/INSERT/UPDATE，`DELETE`、`REPLACE`、`TRUNCATE`
    都不可用），源侧这一版消失的维度行（人员离职、技能下线、名单机构号变化）会留在表里，
    并带着最后一次写入的数值继续出数——业务已确认接受。
    两点运维提醒：① 0 行时不要置 `ready`；② 残留行可用 `loaded_at` 识别，确需清理由有
    DELETE/DROP 权限的角色按建表文件第 4 节处理。同一个 `prt_dt + source_id` 建议串行写入。

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
| 整段接口 404 `Not Found`（响应体没有 `code`） | 路由没匹配上，不是业务 404：确认请求前缀是 `/api/monitor/cron/report/*`。网关只转发 `/api/monitor/cron/*`，历史上 `/api/monitor/report/*` 这个独立前缀会落到别的服务 |
| 404 `report_snapshot_not_found` | `swe_task_type_report_batch` 是否有该 `prt_dt + source_id`；写入方是否漏写批次 |
| 409 `report_snapshot_not_ready` | 批次 `status` 是否 `ready`；`sync_date` 是否为空 |
| 422 `report_filter_not_supported` | 是否用 overall/branch 组合做了网点或经理筛选（见 API.md 3.4） |
| 500 `Unknown column 'xxx' in 'field list'` | 服务查询列与表结构不一致：先跑 `test_selected_columns_exist_in_table_ddl` 定位，再对齐 `schema.py` 与 `gauss/task_type_report_tdsql.sql` |
| 写入报 1062 `Duplicate entry` | 同一 `prt_dt + source_id + 组合 + 维度` 重复写：改用 `INSERT ... ON DUPLICATE KEY UPDATE`（同键原地更新），或先删同分区再写 |
| 写入报 1142 `command denied` | 用了 `DELETE` / `REPLACE`（内部要求 DELETE 权限）/ `TRUNCATE`（要求 DROP 权限）：账号无这些权限，改用 upsert |
| 接口多出已经不存在的人员/技能 | 源侧已消失的维度行残留，属本文第 3 节第 10 条的既定取舍；确认要清理时按建表文件第 4 节（用 `loaded_at` 定位未刷新的行） |
| 有权限客户经理数全是 0 | 先看批次 `sync_date`（为空接口会 409）；再查 `jkh_user_inf` 是否有该快照日的名单、`swe_tenant_init_source` 是否有该 source 对应的 tenant 记录 |
| 写入报 1406 或 `Data truncated` | 值超出列宽，按建表文件第 2 节升级表结构（列宽已按源表取宽） |
| 建表报 1071 `Specified key was too long` | 主键用了自然维度列，改成 `dim_hash`（见建表文件第 1 节） |
| 前端显示 `ALL` | 落盘表把不适用维度写成了 `ALL` 而出参没还原，检查 `_text` / `_dim` 与 `COMBO_DIM_COLUMNS` |
| 比例列显示 0 而不是空 | 写入时把 NULL 写成了 0，按建表文件第 3.3 节的 NULL 规则检查（`ask_plan` 的任务状态列、`push_other` 的方案与点击列必须为 NULL） |
| `/task-type/dates` 只有部分日期 | 写入方漏写了某天的批次行或报表行；接口按批次的 `prt_dt` 列日期，没批次就没有那一天 |
| 行数比在线接口少 | 先 `GET /task-type/status` 看 `missing_combos`，再看 Hive 侧第 6 段是否漏写某个组合 |
| 数字与在线接口不一致 | 比对三处：高斯 `TF_METRIC_FACT` 分支的过滤条件、落盘表 `prt_dt` 是否对应同一跑数日期、在线接口的 `sync_date` 是否同一名单快照日 |
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
| 新增报表组合 | 数仓脚本第 4~6 段、`COMBO_MAP` / `EXPECTED_COMBOS` / `COMBO_DIM_COLUMNS`、`FILTER_REQUIRED_GROUPS`（如含新维度）、API.md | 组合标签一致、/status 不再报缺失、SQLite 与 ASGI 测试通过 |
| 新增指标列 | 数仓目标表与跑数脚本、`schema.py` 与 `gauss/task_type_report_tdsql.sql` 建表、`_to_row` 映射、`TaskTypeReportRow`、导出列 | 两处 DDL 一致（`test_selected_columns_exist_in_table_ddl` 兜底）、导出列同步、行模型校验通过 |
| 调整筛选规则 | `FILTER_REQUIRED_GROUPS`、`build_filters` | 筛选规则与组合维度一致，422 场景补测试 |
| 修改表结构（加列/改宽/换键） | `schema.py` 的 `CREATE_TASK_TYPE_REPORT_*_TABLE` + `gauss/task_type_report_tdsql.sql` 第 1/2 节；通知写入方 | 两处 DDL 逐字一致（`test_selected_columns_exist_in_table_ddl` 兜底）、升级语句可在真库执行、写入方同步 |
| 写入方权限变化（如拿到 DELETE） | `gauss/task_type_report_tdsql.sql` 第 3/4 节、本文第 3 节第 10 条 | 可以「删当天分区 + 重新写入」，残留行问题随之消失；接口不用动 |
| 调整写入天数 | 写入方的日期循环 + `gauss/task_type_report_daily.sql` 第 1.0 段日历 | 两边天数一致；接口按 `prt_dt` 单日取数，不受影响 |
| 上游维度标记变化（`'ALL'` / 空串） | 服务 `_text` / `_dim`、`COMBO_DIM_COLUMNS`、`schema.py` 注释、本文件与 API.md | `'ALL'`（不适用）还原成 `null`、空串（名单缺机构号）保留，见本文第 3 节第 2 条 |
| 客户经理维度新增当前活跃/暂停任务数 | `schema.py` 的 `CREATE_TASK_TYPE_REPORT_SNAPSHOT_TABLE`、`hive/task_type_report_tdsql.sql` 第 1/2/3 节、服务行模型与导出列、API.md 响应字段 | 落盘表在 `active_manager_cnt` 后新增 `active_job_cnt` + `paused_job_cnt`（Hive 侧 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`，仅客户经理维度有值），出仓列顺序与第 3 节一致，行模型与导出列同步；`active_manager_cnt` 保留给总体/分行/支行维度 |
| 切换接口前缀或参数命名 | `routers/task_type_snapshot.py`、API.md、前端 | 前端同步，旧接口不动 |

## 7. 验证与限制

- `tests/test_task_type_report_snapshot.py` 19 项通过（含「`'ALL'` 还原」「查询列必须建在
  表里」「缺 `sync_date` 报 409」）；报表相关回归 203 项通过（按文件逐个运行）。
- `pytest tests/` 整目录运行会被 `tests/test_async_tasks_query_api.py` 注入的 openpyxl 桩
  模块污染，导致后续模块收集失败（既有问题，与本链路无关）；排查时按文件运行，例如
  `venv/Scripts/python.exe -m pytest tests/test_task_type_report_snapshot.py -q`。
- 本次表结构已在本地真实 MySQL 5.7.33（TDSQL 5.7 兼容）上验证：建表（无自增主键、主键
  `(prt_dt, source_id, dim_hash)`）、历史库升级语句（加宽列 + 加 `dim_hash` + 换主键）、
  upsert 写入与重复覆盖、`'ALL'` / 空串 / NULL 语义、186 字符技能 ID、分页、关键字、
  五个接口、XLSX 导出，以及有权限客户经理数在七个组合下的取值。
- SQLite 只验证 SQL 形状与装配逻辑，不代表 TDSQL 方言、索引命中与真实耗时；
  上线前需在目标 TDSQL 执行 EXPLAIN 并核对接口耗时与导出体积。
- 数据写入由现场作业负责（本仓库不含装载脚本）：写入方需要按建表文件第 3 节遵守列语义、
  批次就绪信号与 `sync_date` 约定，否则接口会报 404/409 或给出错误数字。

## 8. Gauss V2 no_lower 专用口径

`gauss/task_type_report_gauss_optimized_v2_no_lower.sql` 按每个重跑日的
`DW_SNSH_DT = REPLAY_DT` 读取名单，同日客户经理唯一，名单不聚合、缺日不回退。
执行人、归属人、点击人及名称回填均匹配 `REPLAY_SEQ`，防止跨日机构串用。
分行、网点不再建立名称临时表；最终查询按日期与机构名称 DISTINCT，避免同机构多名经理放大行数。

推送技能按指定的 `ANY(string_to_array(...)) + unnest(...)` 实现：只要任务命中一个
统计技能，就展开任务的全部技能，不逐个过滤展开结果；未删除包含 NULL 和
`0001-01-01 00:00:00`。数字与序号辅助表已删除。

主动提问直接生成 `TF_ASK_TRACE`：START_TIME 在各重跑日的月初至次日零点半开区间内，
且技能在统计目录内。原先非统计技能参与的提问执行数、阅读数和方案客户数也随入口过滤排除。
主动点击与技能关联复用此表并匹配重跑序号，不再关联无时间限制的 Span。
这些是此脚本的专用调整，不能再假定与旧 Hive/在线接口完全一致。

本地检查：`venv/Scripts/python.exe scripts/check_gauss_v2_no_lower.py`。
该检查执行脚本中的名单、主动提问和主动点击 SQL，覆盖跨日换机构、缺日不回退、
跨月及截止日边界、非统计技能和定时 trace 排除、点击日期隔离；使用 SQLite，
不代替 Gauss 真库的数组函数、分布式执行计划和全量跑数验证。

名单过滤按指标归属人执行：执行类及推送方案客户指标检查 `EXEC_IN_ROSTER = 1`，
归属人指标检查 `OWNER_IN_ROSTER = 1`，主动提问、点击与任务状态通过名单内连接过滤。
尤其 `TF_PUSH_CUST` 不能只过滤 push_plan，否则未匹配名单的执行人会生成空机构维度。
本地检查包含执行人不存在及对应日期缺名单的回归场景。
