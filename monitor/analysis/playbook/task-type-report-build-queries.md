# 金葵花任务类型报表 build_queries 梳理

## 2026-09-16 结构与排查入口

| 文件 | 职责 |
| --- | --- |
| `task_type_report.py` | 服务与编排：名单快照、范围校验、名称解析、查询执行（`query_core` / `query_page`）、阶段计时与 `TaskTypeReportService` |
| `task_type_report_rows.py` | 纯行组装：三类任务补齐、空值语义、派生比例（`assemble`、`percentage`），不访问数据库、不打日志 |
| `task_type_report_sql.py` | 参数化聚合 SQL 构造（`Scope`、`build_queries`、`META_QUERY_NAMES`） |
| `task_type_report_export.py`、`routers/task_type_report.py` | XLSX 导出与 HTTP 契约，本次未改动 |

`get_report` 现在是线性流程：`enforce_branch` → `report_db` → `_resolve_snapshot` → `_resolve_scope` → `_build_scope` → `_collect`（分页或全量）→ `_build_response`，每一步的耗时都对应一个 `stage`。排查慢查询或超时先看日志，不要先读 SQL。

## 期间事实与慢查询排查（2026-09-16）

权限查询优化后的复测：对比同样请求的 `stage=permissions elapsed_ms` 和 `rows`，同时查看 `get_report` 总耗时。分支行权限结果现在只包含事实机构，但每个机构人数仍按完整名单计算。无事实时不会出现 permissions 阶段日志。执行顺序改为事实在前、权限在后，不能拿日志行顺序当作查询丢失。

本地 3,000 名额外无活动经理的 SQLite 无显式索引样本中，旧权限查询约 337ms / 1,832 万 VM 指令，新查询约 5ms / 5.4 万 VM 指令；仅用于验证减少无关工作，不是 TDSQL 性能承诺。线上仍需比较相同请求的日志及执行计划。

当前口径：名单限定事实范围并提供元数据、权限人数；结果维度来自各指标的期间事实并集。普通经理分页与技能分页都使用推送执行、owner 活跃、Span、点击四条事实路径的 UNION。每个有效维度仍补三类任务，不能用全零指标判断是否有事实。

服务以 INFO 级别记录 `task_type_report_timing`，保持 `MONITOR_LOG_LEVEL=info` 即可。日志不含 SQL、绑定参数或人员信息。筛选同一个 `report_id` 后比较 `elapsed_ms`：

- `get_report`：方法总耗时，包含响应模型构造，不含路由 JSON 序列化、XLSX 文件生成和网络传输；它包含其他阶段，不能与子阶段相加。该行额外带 `stages`、`slowest`、`slowest_ms`，即本次请求记录了多少阶段、除总耗时外最慢的子阶段是谁；`rows` 为最终返回行数。先看这一行，再决定是否展开逐阶段日志。
- `resolve_snapshot` / `validate_scope` / `resolve_filters` / `validate_resolved_scope`：快照选择、范围校验和名称解析。
- `roster_conflicts` / `permissions` / `push_tasks` / `ask_tasks` / `active` / `push_skills` / `ask_skills` / `push_customers` / `ask_customers` / `clicks`：对应同名 SQL，`rows` 为返回聚合行数。
- `page_roster_conflicts` / `page_count` / `page_keys`：分页前校验、事实键计数与取页。
- `assemble`：Python 合并、补齐与排序，`rows` 为输出行数。

`status=ok` 表示正常结束；异常记录异常类型并原样抛出；路由超时取消会记录 `CancelledError`。并发请求用独立 `report_id`，多实例部署同时保留容器/实例日志标签。

正常的非分页请求固定是 11 条查询、15 个阶段（含 `get_report` 自身）；命中名称解析会多一个 `validate_resolved_scope`（16 个阶段）；经理分页请求另有 `page_roster_conflicts` / `page_count` / `page_keys` 三个阶段。阶段数与预期不符时先确认命中的是哪条分支，再查改动。

数据库调用的计时包含连接池等待、SQL 执行、传输和结果转换，不能直接等同于数据库执行时间。事实查询自 2026-09-16 起按 `REPORT_QUERY_CONCURRENCY`（默认 4）受限并发，可用 `TaskTypeReportService(concurrency=...)` 覆盖，设为 1 即退回全部串行；`roster_conflicts`、`permissions` 和三个分页阶段仍串行。并发只压缩总耗时（从"各查询相加"变成"约等于最慢一批"），不改变查询条数和指标口径。多条查询同时取连接时，阶段耗时会把连接池排队时间算进去，判断数据库侧耗时要结合 EXPLAIN 与连接池指标；需要区分时把并发调回 1 复测即可。

定位到慢查询名后，在相同 Scope 下取得实际参数化 SQL，通过现有连接执行普通 EXPLAIN：

```python
# db 为现有数据库连接，scope 为复现请求使用的 Scope。
sql, values = build_queries(scope)["clicks"]
plan = await db.fetch_all("EXPLAIN " + sql, values)
```

`page_count` / `page_keys` 使用 `build_queries(scope, keys_only=True)["keys"]`，并按 `query_page` 的实际 COUNT、ORDER BY、LIMIT/OFFSET 包装后查看执行计划。不要只解释内部键查询，也不要把参数展开到共享日志。

优先核查计划是否在时间和来源过滤后仍扫描大量行，以及 `EXISTS`、按用户查机构的相关子查询、`FIND_IN_SET`、UNION/DISTINCT 的成本。经理分页会分别执行事实键计数和取页，可能成为新的主要耗时点。若数据库侧执行快但上述调用计时慢，再检查连接池等待及网络；若 `assemble` 慢，查看返回行数及 Python CPU profile。

本地 SQLite 测试验证口径、分页、日志关联及取消路径，不代表真实 TDSQL 的执行计划或性能。生产瓶颈需要一次真实请求的分阶段日志和相应 EXPLAIN 才能确认。

对象文件：`src/monitor/app/services/cron/task_type_report_sql.py`。

消费方：`src/monitor/app/services/cron/task_type_report.py` 的 `query_core`（快照、范围、并发编排与阶段日志）与 `task_type_report_rows.py` 的 `assemble`（纯行组装）。

统计口径真源是 [DESIGN.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md)。本文只梳理 `build_queries` 的代码结构与契约，不重复口径定义；口径有疑问时以 DESIGN.md 为准。

2026-09-14 维度扩展：Scope 新增 skill_detail，group_by 支持 manager。以下为基础模式结构梳理；manager 使用 group_user，技能明细增加 skill_id 分组与去重目录关联，权限查询保持原粒度，核心 SQL 仍为 10 条。六种组合和经理元数据的完整规则见 [DIMENSIONS.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)，旧行号不作为定位依据。

## 1. 定位

`build_queries(scope, keys_only=False, permission_keys=None)` 是纯函数 SQL 工厂：把已校验的 `Scope` 一次编译成**固定 10 条**参数化聚合 SQL，返回 `dict[str, tuple[str, tuple]]`，每个值可被 `db.fetch_all(*query)` 直接展开。

- 查询条数与机构数、用户数无关，不存在按机构循环的 N+1。有事实时核心仍为 10 条查询，无事实时为 9 条；另外有快照、范围校验、名称解析以及分页键查询；总数随输入路径变化，不能统一宣称最多 13 条。
- 业务值全部通过内部 `:name` 占位符传递，不进入 SQL 文本，由 `bind` 编译为驱动可识别的 `%s`。
- 函数体为线性字符串拼接，无嵌套分支，圈复杂度低；无需为新增机构层级调整结构。

## 2. 入参与出口

`Scope`（第 9-32 行）是 frozen dataclass，`__post_init__` 已完成的校验：

| 字段 | 说明与校验 |
| --- | --- |
| `source_id` | 必填非空白；贯穿所有查询的来源约束 |
| `sync_date` | 必填；必须是 `date.fromisoformat` 可解析的名单快照日 |
| `start` / `stop` | 必填；**不允许携带 tzinfo**，要求调用方已换算到数据库存储时区；且 `0 < stop - start <= 93 天` |
| `group_by` | `overall` / `branch` / `org` / `manager` |
| `skill_detail` | 默认 false；true 要求非 overall，详情见 DIMENSIONS.md |
| `first_bbk_id` / `org_id` | 可选机构筛选，作用于元数据查询与指标侧名单 `EXISTS` 过滤 |

所以 `build_queries` 自身不做任何参数校验，它只接受已经合法的 `Scope`。

`bind(sql, values)`（第 35-40 行）是唯一的占位符编译器：

1. `re.findall(r":([a-z_]+)\b", sql)` 按**出现顺序**取名字，重复出现会重复计入；
2. 同顺序把 `:name` 替换为 `%s`；
3. `tuple(values[name] for name in names)` 生成 positional 参数。

因此同一个 `:source_id` 出现 N 次就会产生 N 个 `%s` 和 N 个重复值，数量与顺序天然对齐，兼容现有 `fetch_all(sql, params)` 接口。

已实测核对：10 条查询的 `len(params)` 与 `sql.count('%s')` 全部相等，且不存在残留的 `:name` 文本。

## 3. 内部结构：4 类原料 + 2 个基础集合

1. **名单与权限元数据**
   `permissions` 直接从所选快照的 `jkh_user_inf r` 出发，`LEFT JOIN swe_tenant_init_source i`，在 JOIN 条件中限定 source，按目标机构/经理分组并 `COUNT(DISTINCT i.tenant_id)`。不再先按人员构造名单派生表，也不再逐人执行 `CASE WHEN EXISTS`。重复名单/初始化记录不会放大权限人数，零权限的事实维度仍保留元数据。
   服务先查询事实并收集维度键，再通过 `build_queries(scope, permission_keys=...)` 参数化限制权限查询的名单范围：分行按分行，支行按分行+支行，经理按机构+经理；overall 保持原全范围口径。权限人数包含目标机构中无活动的有权限经理，不能按事实用户集合裁剪机构人数。普通和技能分页键仍来自期间事实并集。

2. **分组维度（第 56-63 行）**

   | `group_by` | `group_bbk` | `group_org` |
   | --- | --- | --- |
   | `overall` | `''` | `''` |
   | `branch` | `r.first_bbk_id` | `''` |
   | `org` | `r.first_bbk_id` | `r.org_id` |

   统一产出 `dims = "{bbk} AS group_bbk, {org} AS group_org"` 与 `groups = "group_bbk, group_org"`。用空字符串常量而非 `NULL` 占位，使整体维度退化为单组，同时保持所有查询的列结构一致。

3. **两个基础集合 `push` / `ask`（第 64-81 行）**
   - `push`：`swe_cron_executions e JOIN swe_cron_jobs j`，时间窗用 `e.actual_time`，并在派生表内用 `CASE WHEN {has_sub}` 打好 `push_plan` / `push_other` 标签。
   - `ask`：`swe_tracing_spans sp`，时间窗用 `sp.start_time`。`ask_qualifier` 的四个条件是分类关键：有非空 skill span、有子任务、且**不存在同 trace 的 cron execution**，从而与 push 互斥。

4. **可复用的布尔谓词片段**

   | 片段 | 作用 |
   | --- | --- |
   | `has_sub` | trace 是否存在子任务，决定 push 类型 |
   | `stat_job` | job 的 `skill_ids` 是否含 `include_in_statistics=1` 的技能（`FIND_IN_SET`） |
   | `stat_ask` | trace 的 span 是否命中统计内技能 |
   | `click_push` / `click_ask` | 点击事件回溯归属为推送或主动提问的二次校验 |

   这些片段被内联到多条 f-string 中，属于复用性与可读性的取舍；修改时必须同时检查所有引用点。

## 4. 10 条查询

下表顺序为 `query` 字典的插入顺序。`query_core` 先校验冲突、再执行事实查询，最后按事实维度查询 `permissions`；无事实时跳过权限查询。参数个数为 overall、无机构 ID 筛选、非技能明细时的基础值；权限查询还会绑定实际维度键；分行/支行/经理分组会因快照维度查值增加 `sync_date` 绑定。2026-09-14：ask 已改为 Span 主表，以下旧行号仅供参考，定位以符号名为准。

| # | 名称 | 参数个数 | 输出字段 | 角色与要点 |
| --- | --- | --- | --- | --- |
| 1 | `roster_conflicts` | 1 | `user_id` | 名单机构唯一性校验，`HAVING COUNT(*) > 1 LIMIT 1`；命中即 503 `jkh_roster_ambiguous`。第 91 行注释说明必须在机构筛选之前执行，否则冲突会被筛选掩盖 |
| 2 | `permissions` | 2 | `group_bbk`、`group_org`、`first_bbk_name`、`org_name`、`permission_manager_count` | **唯一不带 `task_type` 的查询，提供元数据与权限人数**；`assemble` 只对事实中出现的维度补齐三类任务。无事实时 `query_core` 跳过此查询并返回空列表 |
| 3 | `push_tasks` | 4 | 维度 + `task_type`、`suc_execute_job`、`read_tasks` | 执行侧按 `p.user_id` 用名单 `EXISTS` 过滤 |
| 4 | `ask_tasks` | 4 | 维度 + `ask_plan`、`suc_execute_job`、`read_tasks` | 成功数和已读数均为 `COUNT(DISTINCT sp.trace_id)`，不依赖 Trace 表、has_error 或阅读埋点 |
| 5 | `active` | 4 | 维度 + `task_type`、`active_manager_count` | `COUNT(DISTINCT p.job_user_id)`，条件 `job_status='active' AND deleted_at IS NULL`；**按任务归属人而非执行人匹配名单** |
| 6 | `push_skills` | 4 | 维度 + `task_type`、`skill_count` | `DISTINCT k.skill_id`，要求 `include_in_statistics=1`，且排除已删除 job |
| 7 | `ask_skills` | 4 | 维度 + `ask_plan`、`skill_count` | 经 `swe_tracing_spans` 关联统计技能 |
| 8 | `push_customers` | 4 | 维度 + `push_plan`、`recommended_customers` | `DISTINCT s.custuid`，额外要求 `stat_job`；`WHERE p.task_type = 'push_plan'` 二次收口 |
| 9 | `ask_customers` | 4 | 维度 + `ask_plan`、`recommended_customers` | 仅要求 `custuid` 非空，**不加统计技能开关** |
| 10 | `clicks` | 4 | 维度 + `task_type`、`read_customer_count`、`insight_customer_count`、`insight_count`、`phone_customer_count`、`phone_count` | 由 `click_rows` 派生；客户数按 customer_id 去重，总次数按事件行计数；其余限制一致 |

## 5. 必须成立的不变量

改动任何一条查询时，以下契约不能破坏：

1. **键对齐**：除 `permissions` 外，每条查询都按 `(group_bbk, group_org, task_type)` 产出，且键必须是 `permissions` 元数据键的子集；最终结果只包含事实维度并集。否则 `assemble`（第 111-117 行）抛 `ValueError("roster changed during report query")`。这是名单并发变更的显式检测点，不是冗余判断。
2. **时间窗**：统一半开区间 `[start, stop)`（`date_bounds` 对 `end_date` 加一天），但三条链路各用自己的时间列——推送用 `actual_time`、主动提问用 `start_time`、点击用 `clicked_at`。第 152 行注释说明点击链路不对关联任务再附加生成时间限制。
3. **不跨组累加 DISTINCT**：SQL 只做机构级聚合，比例在 service 层用 `Decimal` 计算；`assemble` 不做分组行求和，所以 `overall` 行是独立重算而非 branch 行相加。
4. **空值语义两侧对齐**：`push_other` 天然没有客户数据（`push_customers` 限定 `push_plan`），`_finish_row` 也据此把 4 个客户字段置 `None`；`ask_plan` 无 `active_manager_count`。SQL 与组装逻辑必须同步修改。
5. **方言约束**：`FIND_IN_SET` 与在 `GROUP BY` 中引用别名都是 MySQL 行为，本模块不适用于其他方言。

## 6. 容易被误读为缺陷的既定口径

以下几点表面看像不一致，实际是 DESIGN.md 已明确的设计，改动前应先读口径而不是"顺手对齐"：

- **`push_customers` 有 `stat_job` 技能门槛，`ask_customers` 没有**：DESIGN.md 第 87 行字段 8 与第 3.1 节按原需求保留了推送加开关、主动不加的差异。
- **`active` 按 `job_user_id`（任务 owner）匹配名单，推送其余查询按执行人 `user_id`、主动按 Span 的 `user_id`、点击按事件 `user_id`**：DESIGN.md 第 19、36、83 行明确"按任务 owner 去重"，`tests/test_task_type_report_queries.py::test_click_actor_and_active_owner_use_independent_rosters` 专门锁定这一点。
- **`clicks` 用 `CASE WHEN {click_push} THEN 'push_plan' ELSE 'ask_plan'`**：DESIGN.md 第 178 行声明两类关联互斥；且 `click_rows` 的 `({click_push} OR {click_ask})` 已先行过滤，`ELSE` 实际只承接主动提问命中行。改动 `click_rows` 时需重新确认这个前提。
- **`roster_conflicts` 只返回一条冲突**：DESIGN.md 第 44 行说明遇到冲突整份报表失败，不返回全量明细，也不偷偷取 `MIN(机构号)`。

## 7. 验证入口

```powershell
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_queries.py tests/test_task_type_report_api.py -q
```

Linux 使用 `venv/bin/python -m pytest ...`。

`test_task_type_report_queries.py` 覆盖指标与去重、三种分组、筛选绑定与空结果、机构冲突先于筛选、点击人与任务 owner 使用独立名单、主动查看等于成功数且不依赖埋点、删除 job 的历史保留、反连接使用全部执行历史、overall 不等于分行相加，以及比例计算与参数绑定。并发与日志是两项独立契约测试：`test_fact_queries_run_concurrently_with_stable_results` 锁定"并发不改变查询条数与结果、在飞查询数受 `REPORT_QUERY_CONCURRENCY` 限制"，`test_timing_log_names_slowest_stage` 锁定"只有最外层阶段带 `stages` / `slowest` 汇总字段，且阶段数与该 `report_id` 的日志行数一致"。
