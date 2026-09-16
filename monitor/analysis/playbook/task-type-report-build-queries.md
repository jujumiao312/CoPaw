# 金葵花任务类型报表 build_queries 梳理

对象文件：`src/monitor/app/services/cron/task_type_report_sql.py`。

消费方：`src/monitor/app/services/cron/task_type_report.py` 的 `query_core` 与 `assemble`。

统计口径真源是 [DESIGN.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md)。本文只梳理 `build_queries` 的代码结构与契约，不重复口径定义；口径有疑问时以 DESIGN.md 为准。

2026-09-14 维度扩展：Scope 新增 skill_detail，group_by 支持 manager。以下为基础模式结构梳理；manager 使用 group_user，技能明细增加 skill_id 分组与去重目录关联，权限查询保持原粒度，核心 SQL 仍为 10 条。六种组合和经理元数据的完整规则见 [DIMENSIONS.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)，旧行号不作为定位依据。

## 1. 定位

`build_queries(scope)` 是纯函数 SQL 工厂：把已校验的 `Scope` 一次编译成**固定 10 条**参数化聚合 SQL，返回 `dict[str, tuple[str, tuple]]`，每个值可被 `db.fetch_all(*query)` 直接展开。

- 查询条数与机构数、用户数无关，不存在按机构循环的 N+1。DESIGN.md 第 7 节记录单次完整请求最多 13 次数据库查询：10 条报表查询 + 1 次快照选择 + 至多 2 次机构名称解析。
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
| `first_bbk_id` / `org_id` | 可选机构筛选，作用于名单骨架与指标侧名单 `EXISTS` 过滤 |

所以 `build_queries` 自身不做任何参数校验，它只接受已经合法的 `Scope`。

`bind(sql, values)`（第 35-40 行）是唯一的占位符编译器：

1. `re.findall(r":([a-z_]+)\b", sql)` 按**出现顺序**取名字，重复出现会重复计入；
2. 同顺序把 `:name` 替换为 `%s`；
3. `tuple(values[name] for name in names)` 生成 positional 参数。

因此同一个 `:source_id` 出现 N 次就会产生 N 个 `%s` 和 N 个重复值，数量与顺序天然对齐，兼容现有 `fetch_all(sql, params)` 接口。

已实测核对：10 条查询的 `len(params)` 与 `sql.count('%s')` 全部相等，且不存在残留的 `:name` 文本。

## 3. 内部结构：4 类原料 + 2 个基础集合

1. **名单派生表 `roster`（第 51-55 行）**
   `jkh_user_inf` 按 `sync_date` 取快照，`GROUP BY user_id, first_bbk_id, org_id`，机构名用 `MIN()` 取稳定显示值。`roster_filter` 按需追加 `first_bbk_id` / `org_id` 条件。
   `permissions` 和非技能明细分页键仍以它作为名单/维度骨架；指标查询不再 `JOIN ({roster}) r`，而是使用 `EXISTS (SELECT 1 FROM jkh_user_inf jkh ...)` 过滤非名单客户经理，并用同一快照查出聚合维度。

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

下表顺序即 `query` 字典的插入顺序，也是 `query_core` 的执行顺序。参数个数为 overall、无机构 ID 筛选、非技能明细时的基础值；分行/支行/经理分组会因快照维度查值增加 `sync_date` 绑定。2026-09-14：ask 已改为 Span 主表，以下旧行号仅供参考，定位以符号名为准。

| # | 名称 | 参数个数 | 输出字段 | 角色与要点 |
| --- | --- | --- | --- | --- |
| 1 | `roster_conflicts` | 1 | `user_id` | 名单机构唯一性校验，`HAVING COUNT(*) > 1 LIMIT 1`；命中即 503 `jkh_roster_ambiguous`。第 91 行注释说明必须在机构筛选之前执行，否则冲突会被筛选掩盖 |
| 2 | `permissions` | 2 | `group_bbk`、`group_org`、`first_bbk_name`、`org_name`、`permission_manager_count` | **唯一不带 `task_type` 的查询，是结果骨架**；`assemble` 用它补齐三类任务。空结果时 `query_core` 直接返回空列表 |
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

1. **键对齐**：除 `permissions` 外，每条查询都按 `(group_bbk, group_org, task_type)` 产出，且键必须是 `permissions` 骨架键的子集。否则 `assemble`（第 111-117 行）抛 `ValueError("roster changed during report query")`。这是名单并发变更的显式检测点，不是冗余判断。
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

`test_task_type_report_queries.py` 覆盖指标与去重、三种分组、筛选绑定与空结果、机构冲突先于筛选、点击人与任务 owner 使用独立名单、主动查看等于成功数且不依赖埋点、删除 job 的历史保留、反连接使用全部执行历史、overall 不等于分行相加，以及比例计算与参数绑定。
