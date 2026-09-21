# 金葵花任务类型报表 —— Hive 跑数说明

本文说明 `task_type_report_daily.sql` 与 `task_type_report_tables.sql` 的用途、口径映射、
调度参数和与接口的差异。指标口径真源仍是
[DESIGN.md](../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)，
在线实现是 `src/monitor/app/services/cron/task_type_report_*.py`，落盘接口是
`src/monitor/app/services/report/task_type_snapshot.py`；本目录把同一口径搬到数仓侧预聚合，
除了下面第 4 节列出的差异外不改变指标定义。

## 1. 文件清单与运行方式

| 文件 | 用途 |
| --- | --- |
| `task_type_report_tables.sql` | 目标表 `P_AALC.AALC_RM_TASK_TYPE_RPT` 的建表语句，首次部署执行一次 |
| `task_type_report_daily.sql` | 每日跑数脚本，七种组合写入同一张表；一次重写近 7 天 + 当天共 8 个分区 |
| `task_type_report_tdsql.sql` | 出仓到 TDSQL 的建表与装载脚本，配套接口 `/api/monitor/report/task-type*` |

```bash
# 跑数日期=2026-09-17：写入 2026-09-10 ~ 2026-09-17 共 8 个分区
hive -hivevar INPUT_DATE=2026-09-17 -f task_type_report_daily.sql
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `INPUT_DATE` | 是 | 跑数日期，`yyyy-MM-dd`；决定重跑日历的终点、名单快照日与点击窗口的终点 |

脚本内所有临时表位于 `T_GPVT`，只在当前会话有效；脚本开头打开了动态分区
（`hive.exec.dynamic.partition`），落数一次写 8 个日期分区，重跑幂等。
建议在同一个 Hive 会话里执行，不要拆成多个 `-f`（临时表不跨会话）。

脚本按「重跑日历 → 维表 → 事实集合 → 指标长表 → 组合骨架 → 组合宽表 → 落数」执行，
**不使用任何子查询**（没有派生表、`EXISTS`、`IN` 子查询和 CTE），所有中间结果都落到临时表，
逐段可单独执行与抽查；需要半连接、反连接时用 `JOIN` + `IS NULL` 过滤。指标长表统一记录
“维度键 + 指标名 + 计数键”，下游任意维度组合用 `count(distinct 计数键)` 还原指标。

重跑日历（第 1.0 段 `VT_CALENDAR`）有 8 行：`REPLAY_SEQ` 1~8 依次对应跑数日期前 7 天到
跑数当天，`REPLAY_DT` 是要写入的分区值。事实表都带上 `REPLAY_SEQ`，宽表按它分组，
落数时再关联日历取出 `PRT_DT`。改写重跑天数只需改这一段（行数 = 天数 + 1）。

分区写入方式：第一条落数语句用 `insert overwrite ... partition (PRT_DT)` 重建这 8 个分区，
其余六条 `insert into ... partition (PRT_DT)` 追加，所以重跑不会重复。若某条语句失败导致分区
内容不完整，重跑整个脚本即可；也可以先逐日
`alter table P_AALC.AALC_RM_TASK_TYPE_RPT drop partition (PRT_DT='yyyy-MM-dd')`
清掉这 8 个分区，再把七条语句统一改成 `insert into` 执行。

注意：动态分区 `insert overwrite` 只重写结果里出现过的分区（这里就是日历的 8 天），
其余历史分区不受影响；这一点依赖 Hive 的 `insert overwrite` 语义，上线前先在测试环境确认。

## 1.1 出仓到 TDSQL

> 生产链路已切到高斯（`gauss/task_type_report_daily.sql` → `AALC_P_RM_CLAW_LIST_USE_IND_STAT`
> → `gauss/task_type_report_tdsql.sql`），本节与 `task_type_report_tdsql.sql` 保留作 Hive 版参考；
> 两条链路的落盘表结构由 `src/monitor/app/database/schema.py` 统一维护。

Hive 跑完后把这 8 个分区逐个导出到 TDSQL，供落盘接口读取；建表与装载步骤见
[task_type_report_tdsql.sql](task_type_report_tdsql.sql)，关键是四点：

1. 出仓的**不适用维度在 Hive 里是 `'ALL'`**（不再是 `NULL`），TDSQL 侧的维度列是
   `NOT NULL DEFAULT ''`，`'ALL'` 会按原值落库，唯一键仍然成立、重跑仍然能覆盖；
   **落盘接口侧必须把 `'ALL'` 还原成 `null`**（现在按空串判断，见第 4 节差异 5）；
2. 装载顺序是「批次置 `loading` → 清当天分区 → 导入 → 七组合齐全后置 `ready`」，
   接口只认 `status = 'ready'` 的批次；
3. 装载要按分区循环执行第 2 节，`${PRT_DT}` 依次取日历里的 8 天；
4. 每个分区都是「该分区日期所在月 1 号 ~ 该分区日期」的累计口径，跨月只建议保留每月最后
   一个跑数日的批次，否则同月数据会被重复放大（清理语句见该文件第 4 节）。

## 2. 目标表（七种组合落同一张表）

七种报表组合都写入 `P_AALC.AALC_RM_TASK_TYPE_RPT`，用 `RPT_COMBO` 区分的取数入口如下：

| `RPT_COMBO` | 接口组合 | 维度列 |
| --- | --- | --- |
| `overall` | `group_by=overall, skill_detail=false` | 无（维度列全为 `'ALL'`） |
| `branch` | `group_by=branch, skill_detail=false` | 分行 |
| `org` | `group_by=org, skill_detail=false` | 分行 + 网点 |
| `manager` | `group_by=manager, skill_detail=false` | 分行 + 网点 + 客户经理 |
| `branch_skill` | `group_by=branch, skill_detail=true` | 分行 + 技能 |
| `org_skill` | `group_by=org, skill_detail=true` | 分行 + 网点 + 技能 |
| `manager_skill` | `group_by=manager, skill_detail=true` | 分行 + 网点 + 客户经理 + 技能 |

消费方按 `PRT_DT + SOURCE_ID + RPT_COMBO` 过滤后再取数；七个组合的行不能混用、也不能相加
（技能明细各列本身也不可相加，汇总数字取不带 `_skill` 的组合）。某个组合用不到的维度列写
`'ALL'`（所有维度列一起看：`FRS_BBK_ORG_ID` / `BRN_ORG_ID` / `CM_ID` / `SKILL_ID` 及其名称
列都可能是 `'ALL'`），消费方不要把 `'ALL'` 当成真实的机构号或技能号。每行都有 `JOB_TYPE`，
覆盖三类任务（`push_plan` / `ask_plan` / `push_other`），因此“任务类型报表”不需要额外维度。

```sql
-- 客户经理汇总
select * from P_AALC.AALC_RM_TASK_TYPE_RPT
where PRT_DT = '2026-09-17' and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager';

-- 客户经理技能明细
select * from P_AALC.AALC_RM_TASK_TYPE_RPT
where PRT_DT = '2026-09-17' and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager_skill';
```

## 3. 字段与取数口径

维度列名：客户经理编号是 `CM_ID`（= 接口的 `USER_ID` / `sapid`），一级分行号是
`FRS_BBK_ORG_ID`（= 接口的 `FIRST_BBK_ID`），网点号是 `BRN_ORG_ID`（= 接口的 `ORG_ID`，
按 `(分行, 网点)` 联合键分组），任务类型是 `JOB_TYPE`（= 接口的 `TASK_TYPE`）；
`FIRST_BBK_NM` / `ORG_NM` / `USER_NAME` / `PST_LVL` / `TASK_TYPE_NAME` 取名单快照或字典。

两种“特殊值”要分清：

- 名单里机构号缺失（`NULL`）时，脚本统一落**空串**并按空串分组，保证与在线接口一样保留
  “缺失机构”分组，也不会因为等值 join 对 `NULL` 不成立而丢数；消费方不要把空串当真实机构号；
- 该组合用不到的维度写 `'ALL'`（第 6 段落数），表示“本维度不适用”，例如 `overall` 组合的
  分行/网点/经理/技能列全是 `'ALL'`。

| 接口字段 | 仓内取数逻辑 |
| --- | --- |
| `skill_count` | 推送：任务绑定的技能中纳入统计（`include_in_statistics=1`）的技能去重计数；主动提问：Span 技能中纳入统计的技能去重计数 |
| `permission_manager_count` | **仓内不计算**，见第 4 节 |
| `active_manager_count`（仓内 `ACTIVE_MANAGER_CNT`） | 活跃客户经理数：推送集合中 `job.status='active'` 的任务归属人（`cron_jobs.tenant_id`）去重；**只有总体/分行/支行维度（含技能明细）使用**，客户经理维度与主动提问为 `NULL` |
| `active_job_count`（仓内 `ACTIVE_JOB_CNT`） | 当前活跃任务数：任务归属人在名单内、`job.status='active'` 的任务（`NLQ13_SWE_CRON_JOBS.id`）去重；**只有客户经理维度（manager / manager_skill）使用**，推送(名单+方案)/推送(非名单方案)两行都取同一个数，其余维度与主动提问为 `NULL` |
| `paused_job_count`（仓内 `PAUSED_JOB_CNT`） | 当前暂停任务数：同上，状态取 `job.status='paused'`；同样只有客户经理维度使用 |
| `suc_execute_job` | `push_plan`：`status='success' AND async_status='success'` 的执行数；`push_other`：推送集合执行数；主动提问：Span `trace_id` 去重数 |
| `read_tasks` | 推送：`is_read=1` 的执行数；主动提问：等于 `suc_execute_job` |
| `read_rate` | `read_tasks / suc_execute_job × 100`，零分母 `NULL` |
| `recommended_customers` | `push_plan`：同 trace 子任务 `custuid` 去重；主动提问：Span trace 对应子任务 `custuid` 去重；`push_other` 为 `NULL` |
| `read_customer_count` | 点击 `preview_view + sub` 的客户去重 |
| `plan_read_rate` | `read_customer_count / recommended_customers × 100` |
| `insight_customer_count` / `insight_count` | 点击 `button_click + insight` 的客户去重数 / 事件行数 |
| `phone_customer_count` / `phone_count` | 点击 `button_click + phone` 的客户去重数 / 事件行数 |
| `click_to_insight_rate` / `click_to_phone_rate` | 洞察、电访客户数 / 方案客户数 × 100 |

三类任务的判定、名单匹配字段（执行人、任务归属人、点击人、提问人分别匹配）、删除任务
过滤、点击回溯规则都按 `task_type_report_sql.py` 的 `push` / `ask` / `click_rows`
逐条实现，临时表命名与脚本注释里标注了对应关系。

技能目录来自 `NLQ13_SWE_MARKETPLACE_SKILLS`（字段名同 `swe_marketplace_skills`），
只保留 `include_in_statistics = 1` 且 `skill_id` 非空的技能，按 `(source_id, skill_id)`
去重、`cn_name` 取 `MIN(NULLIF(cn_name,''))`；`cn_name` 为空时该列返回 `NULL`，消费方回退展示
`SKILL_ID`。开关的下沉位置与接口一致：推送集合要求任务至少绑定一个统计技能，推送技能行、
点击技能归属都只保留统计技能；主动提问的**任务数与方案客户数**不要求技能在目录内，只有
**技能数**要求，而技能明细模式下主动侧三条指标都要求。

两条容易误读的既有口径保持不变：

1. 结果只包含统计区间内出现过事实的维度对象（点击、任务归属人的活跃/暂停任务也算事实），
   每个对象补齐三类任务，指标全零也保留；没有任何事实的整体/机构/经理不出数。
2. 技能明细以“维度对象 + 技能”为骨架，只由任务级事实展开，不给纯目录技能、纯点击
   技能建行；同一任务绑定多个技能时分别进入各技能行，各列不能相加，汇总要看不带
   `_SKL` 的表。

## 4. 与接口的差异（部署前请确认）

| # | 差异 | 位置与处理 |
| --- | --- | --- |
| 1 | `permission_manager_count`（有权限客户经理数）不在仓内计算 | 目标表不含该字段；该指标依赖初始化来源表，仍由接口按名单快照计算 |
| 2 | 名单快照日只在 `CLB_IND='3'` 的口径内选择 | 脚本第 1 节；避免选到没有目标口径名单行的日期，其余优先级与 `_resolve_jkh_sync_date` 一致 |
| 3 | 结果不排序、不落 `warnings` | 表是预聚合结果，消费方按维度列自行排序；接口的 `warnings` 属于在线响应元数据 |
| 4 | 技能门槛用 `lateral view explode(split(skill_ids, ','))` + 技能目录 join 实现 | 脚本第 2.4 段；等价 MySQL 的 `FIND_IN_SET`（按逗号元素精确匹配、不忽略空格），与在线 `push_job_scope` 一致 |
| 5 | 不适用维度写 `'ALL'`（在线接口返回 `null`） | 第 6 段落数（`'ALL'` 是唯一取值，空串只表示“机构号缺失”）；落盘接口侧需把 `'ALL'` 还原成 `null`，否则前端会显示 `ALL` |
| 6 | 一次跑数重写 8 个分区，行为数据回溯到跑数日期 | 第 1.0 段日历；分区 `D` 的任务/提问口径是「当月 1 号 ~ D」，点击等行为口径是「当月 1 号 ~ 跑数日期 R」，所以 `D` 在 `D ~ D+7` 的运行里数值会变化，`D+7` 之后才定稿 |
| 7 | 只有客户经理维度的活跃客户经理数被换成当前活跃任务数 + 当前暂停任务数 | 总体/分行/支行维度仍保留 `ACTIVE_MANAGER_CNT`；客户经理维度（manager / manager_skill）该列为 `NULL`、改出 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`（第 3 段任务粒度分支、第 4 段骨架过滤、第 5/6 段列）；在线接口仍只有 `active_manager_count`，落盘接口的行模型与导出列需要同步 |

除上述七点外，指标、去重范围与在线接口一致。差异 5~7 是本次按需求调整的口径，需要同步
通知消费方：不适用维度从 `null`/空串变成 `'ALL'`、近 8 天分区会被反复刷新、
活跃客户经理数换成两个任务状态计数。

## 5. 时间口径

| 链路 | 时间列 | 区间（`D` = 重跑日，`R` = 跑数日期） |
| --- | --- | --- |
| 推送任务（任务数、技能、方案客户等） | `NLQ13_SWE_CRON_EXECUTIONS.ACTUAL_TIME` | `D` 所在月 1 号 ~ `D`（闭区间） |
| 主动提问 | `NLQ13_SWE_TRACING_SPANS.START_TIME` | `D` 所在月 1 号 ~ `D` |
| 客户点击 | `NLQ13_SWE_HTML_PREVIEW_CLICK_EVENTS.CLICKED_AT` | `D` 所在月 1 号 ~ `R`，把推送后 7 天到达的点击回算到推送当天所在分区 |
| 名单快照 | `AALC_R_RM_SFL_CM_BAS_INFO.DW_Snsh_Dt` | 单日快照，按第 1 节的优先级选取 |
| 当前活跃/暂停任务数 | `NLQ13_SWE_CRON_JOBS.STATUS` | 没有时间列：只按任务**当前**状态（`active` / `paused`）统计，不按统计区间过滤，因此 8 个重跑分区取到同一个值 |

同一份事实会在多个重跑日各出现一次（`REPLAY_SEQ` 不同），因此事实临时表的行数约为原来的
几倍；`已查看任务数` 用的是执行行上的 `is_read` 当前值，也会随重跑刷新。因为点击侧区间到 `R`、
任务侧区间到 `D`，分区 `D` 的点击类客户数理论上可能大于同分区的方案客户数（点击发生在
`D` 之后、任务在 `D` 之后推送），对账时先看指标定义再看差异。

底表时间列是 `STRING`，脚本用 `substr(时间列, 1, 10)` 取日期比较，兼容
`yyyy-MM-dd HH:mm:ss` 与 `yyyy-MM-ddTHH:mm:ss`。如果目标表按日分区，请把该条件换成
分区过滤，减少扫描量；点击回溯主动提问的 Span 按接口口径**不限制** Span 生成时间。

## 6. 对账建议

1. 同一 `end_date`（= 分区日期）下，落盘接口 `group_by=branch` 的结果应与
   `AALC_RM_TASK_TYPE_RPT` 中 `PRT_DT = end_date and RPT_COMBO = 'branch'` 的行逐行一致，
   差异只应出现在第 4 节列出的项；其余六种组合同理（`RPT_COMBO` 取值见第 2 节）。
2. 逐项对账顺序：`SUC_EXECUTE_JOB` → `READ_TASKS` → `RECOMMENDED_CUSTOMERS` →
   三个点击客户数 → 三个比例。比例是派生值，先对计数再对比例。
3. 技能明细对账：汇总组合（如 `manager`）的 `SKILL_CNT` 应等于同维度该任务类型下
   `manager_skill` 组合的行数（技能明细行数为 0 或 1）；不相等时先看是否存在只有点击事实的技能。
4. 接口日志 `task_type_report_sql` 会打印每条查询的 SQL 与绑定参数，可直接与脚本里
   对应临时表的过滤条件比对；该日志含人员信息，只用于内部核对。
5. 重跑对账：同一天连跑两次，结果（含 8 个分区）应完全一致；跨天看 `PRT_DT = D` 的分区，
   `D+1 ~ D+7` 的每次运行都可能改变它，`D+8` 的运行不再触碰它。核对某天是否被漏重跑，
   直接看该分区最后一次写入时间（`insert overwrite` 会重写整份分区）。
6. 日历越界：`R` 前 7 天若跨月（例如 10 月 3 日跑数），日历里 9 月的重跑日取 9 月 1 号
   作为区间起点；对账时按分区日期自己的月份算，不要统一用跑数日期的月份。

## 7. 运维提示与未验证事项

- 重跑把事实集合放大了约 8 倍（每个重跑日一份），四个事实临时表又被多条落数语句重复
  读取；日数据量大时优先评估 `CACHE TABLE`，并确认日历天数与集群资源匹配。
- 点击侧窗口对所有重跑日都到跑数日期，同一批点击会按 `REPLAY_SEQ` 复制 8 份；如果确认
  业务上不需要“行为回溯到推送当天”，把点击窗口改成按 `CAL.REPLAY_DT` 收窄即可退回快照口径。
- 脚本未指定存储格式与压缩，建表时按数仓规范补充；分区 `PRT_DT` 建议保留日粒度，
  历史重跑只需重跑对应日期的分区（脚本会自动覆盖近 8 天）。
- 本文与脚本按 `AALC_R_RM_SFL_CM_BAS_INFO`（`CLB_IND='3'`）、`NLQ13_SWE_TRACING_SPANS`、
  `NLQ13_SWE_HTML_PREVIEW_CLICK_EVENTS`、`NLQ13_SWE_CRON_JOBS` / `_EXECUTIONS` / `_SUBTASKS`、
  `NLQ13_SWE_MARKETPLACE_SKILLS` 编写，库名默认 `P_AALC_VC` / `R_RAW_VC`。字段类型、分区方式、执行计划与真实数据
  耗时都需要在目标 Hive 环境实测确认；本地没有可执行的 Hive，脚本尚未在真实环境跑过。
