# 金葵花任务类型报表 Hive 跑数脚本

更新日期：2026-09-18。覆盖“把任务类型报表的七种组合预聚合落到数仓”的实现方式、
口径映射和修改入口。指标口径真源仍是
[DESIGN.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)，
在线实现是 `src/monitor/app/services/cron/task_type_report_*.py`，落盘接口是
`src/monitor/app/services/report/task_type_snapshot.py`（契约见
[API.md](../../docs/superpowers/specs/2026-09-18-task-type-report-snapshot/API.md)）。

## 1. 阅读入口与适用范围

涉及下列任一事项时先读本文：

- 修改 [hive/task_type_report_daily.sql](../../hive/task_type_report_daily.sql) 或
  [hive/task_type_report_tables.sql](../../hive/task_type_report_tables.sql)；
- 核对仓内报表与在线接口的口径差异、对账不一致；
- 新增维度、指标或改变统计区间；
- 排查仓内报表缺数、错数、重跑问题。

使用方式、参数与字段映射见 [hive/README.md](../../hive/README.md)，本文只记录脚本结构、
既定口径和修改指引，不重复字段清单。

## 2. 脚本结构

**写法约束：脚本不含任何子查询**（没有派生表、没有 `EXISTS` / `IN` 子查询、没有 CTE），
所有中间结果都落到 `T_GPVT` 临时表，逐段可单独执行与抽查。需要半连接/反连接时用
`JOIN` + `IS NULL` 过滤（例如 2.9 的主动提问、2.16 的点击类型互斥），不要改回 `EXISTS`。

单个脚本按“重跑日历 → 维表 → 事实 → 指标长表 → 组合骨架 → 组合宽表 → 落数”顺序执行；
事实表与下游临时表都带 `REPLAY_SEQ`（第 1.0 段 `VT_CALENDAR`，8 行 = 跑数日期前 7 天 ~
跑数当天），落数用动态分区 `insert overwrite/into ... partition (PRT_DT)` 一次写 8 个日期，
重跑幂等。

| 段 | 临时表 | 对应在线实现 |
| --- | --- | --- |
| 1.0 重跑日历 | `VT_CALENDAR` | 无对应（仓内新增：推送后 7 天的行为回算） |
| 1.1 名单快照日 | `VT_JKH_SNAPSHOT` | `_resolve_jkh_sync_date` 的四级优先级 |
| 1.2 名单 | `VT_JKH_ROSTER` | `jkh_user_inf`（`AALC_R_RM_SFL_CM_BAS_INFO`，`CLB_IND='3'`） |
| 1.3 / 1.4 机构名称 | `VT_BBK_NAME`、`VT_ORG_NAME` | `permissions` 的 `MIN(first_bbk_nm)` / `MIN(org_nm)` |
| 1.5 技能目录 | `VT_SKILL_CATALOG` | `swe_marketplace_skills` 去重目录（`NLQ13_SWE_MARKETPLACE_SKILLS`，`include_in_statistics=1`） |
| 1.6 任务类型字典 | `VT_TASK_TYPE` | 三类任务补齐 |
| 2.1~2.3 trace 痕迹 | `VT_TRACE_SUB`、`VT_TRACE_EXEC`、`VT_SUBTASK_CUST` | `has_sub`、反连接、子任务方案客户 |
| 2.4~2.8 推送 | `VT_PUSH_JOB_SKILL`、`VT_PUSH_JOB`、`VT_PUSH_EXEC`、`VT_PUSH_EXEC_SKILL`、`VT_PUSH_CUST` | `push_job_scope`、`push` 子查询、`push_customers` |
| 2.9~2.11 主动提问 | `VT_ASK_SPAN`、`VT_ASK_TRACE`、`VT_ASK_CUST` | `ask` 子查询、`ask_tasks` / `ask_skills` / `ask_customers` |
| 2.12~2.17 点击 | `VT_CLICK_EVENT`、`VT_CLICK_PUSH`、`VT_CLICK_PUSH_KEY`、`VT_CLICK_ASK`、`VT_CLICK_CLS`、`VT_CLICK_SKILL` | `click_rows`、`click_push` / `click_ask`、`clicks` 技能关联 |
| 3 指标长表 | `VT_METRIC_FACT` | 各指标按“指标名 + 计数键”压平 |
| 4 组合骨架 | `VT_SKEL_*`（7 张） | `assemble` 的维度并集与 `_drop_click_only_skills` |
| 5 组合宽表 | `VT_RPT_*`（7 张） | `assemble` 的补零、`NULL_FIELDS` 与派生比例的分母 |
| 6 落数 | `P_AALC.AALC_RM_TASK_TYPE_RPT` | 七种 `group_by` × `skill_detail` 组合，用 `RPT_COMBO` 区分 |

指标长表把每个指标压成“该指标被计数的集合”：`METRIC_KEY` 就是该指标的计数键
（执行 ID / trace_id / 客户 UID / 客户 ID / 事件 ID / 技能 ID / 归属人），因此下游任意
维度组合只要 `count(distinct METRIC_KEY)` 就能还原指标；`METRIC_NM` 的取值与在线指标名
一一对应（`SKILL_CNT`、`ACTIVE_MANAGER_CNT`、`ACTIVE_JOB_CNT`、`PAUSED_JOB_CNT`、`SUC_EXECUTE_JOB`、`READ_TASKS`、
`RECOMMENDED_CUSTOMERS`、`READ_CUSTOMER_CNT`、`INSIGHT_CUSTOMER_CNT`、`INSIGHT_CNT`、
`PHONE_CUSTOMER_CNT`、`PHONE_CNT`）。

## 3. 必须成立的口径（改动前先读）

1. **所有指标可跨层聚合**：`VT_METRIC_FACT` 把事实统一压到“维度键 + 技能 + 任务类型 +
   指标名 + 计数键”的集合粒度，每个指标都用 `count(distinct METRIC_KEY)`，因此同一份事实
   能同时支撑分行、支行、客户经理三层，不需要为每层重写聚合，也不会出现 `DISTINCT`
   跨组相加。新增指标就在长表加一个分支，不要在宽表里做多表 JOIN 求和。
2. **骨架按报表粒度收敛**：每张报表的维度骨架先按该报表的键 `select distinct`（例如分行
   骨架只留 `REPLAY_SEQ, SOURCE_ID, K_FRS_BBK_ORG_ID`），否则同分行两名经理会把分行行
   复制成两行；技能明细骨架只取任务级事实且技能在统计目录内，键里必须带 `REPLAY_SEQ`。
3. **技能行只由任务级事实展开**：技能表骨架只取推送执行、任务归属人的活跃/暂停任务、主动提问三类
   事实，点击不单独建行，对应接口装配阶段的 `_drop_click_only_skills`；所有技能关联都先
   命中 `VT_SKILL_CATALOG`（`include_in_statistics = 1`），与接口的技能目录 join 对齐。
4. **不适用维度写 `'ALL'`，指标列仍按接口规则写 `NULL`**：指标侧 `ask_plan` 的当前活跃/
   暂停任务数为 `NULL`、`push_other` 的方案与点击类共 9 列为 `NULL`，比例用
   `round(100 * 分子 / 分母, 2)`、零分母自然为 `NULL`；另外 `ACTIVE_MANAGER_CNT` 只在
   总体/分行/支行维度有值（客户经理维度为 `NULL`），`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`
   只在客户经理维度有值（其它维度为 `NULL`），由第 5 段宽表按组合决定；维度侧第 6 段落数
   把本组合用不到的维度写成 `'ALL'`（原来是 `NULL`），消费方按 `'ALL'` 判断“不适用”。
5. **删除过滤与状态过滤分链路**：推送侧统一 `job.deleted_at is null and job.status <> 'deleted'`；
   主动侧不查任务表，只要求 Span 技能非空、有子任务、历史执行无同 trace。
6. **机构维度键统一落空串**：名单机构号为空时不能保留 `NULL`，否则等值 join 会把该维度
   的指标整片丢掉；接口本身也保留“缺失机构”分组，不能把空机构改写成真实机构号。空串与
   第 4 点的 `'ALL'` 含义不同，不能混用。
7. **七种组合同表共存，靠 `RPT_COMBO` 隔离**：七个组合的聚合粒度与 DISTINCT 范围不同，
   必须各自独立聚合后打上组合标签，禁止把明细行相加或跨组合聚合；写分区时第一条
   `insert overwrite`、其余 `insert into`，并保证组合标签与语句一一对应。
8. **重跑维度贯穿全链路**：第 1.0 段 `VT_CALENDAR` 定义 8 个重跑日（跑数日期前 7 天 ~
   跑数当天），事实表（推送执行、主动提问、点击）都按日历出多份并带 `REPLAY_SEQ`，
   下游所有临时表、骨架、宽表都以它为一等键，落数再关联日历取 `PRT_DT`；漏带
   `REPLAY_SEQ` 会把不同重跑日的数据串在一起（`count(distinct)` 会跨日相加）。
9. **两侧时间窗不同**：任务/提问按「当月 1 号 ~ 重跑日」、点击等行为按「当月 1 号 ~
   跑数日期」，所以推送当天推送的任务会把推送后 7 天到达的点击算回自己所在分区，
   分区 `D` 在 `D ~ D+7` 的运行里会被反复刷新。
10. **当前活跃/暂停任务数只给客户经理维度，且是状态快照**：`ACTIVE_JOB_CNT` /
    `PAUSED_JOB_CNT` 只按 `NLQ13_SWE_CRON_JOBS.STATUS`（`active` / `paused`）取当前值，
    不设统计区间、也不看执行，口径是「任务归属人在名单内、任务未删除且至少绑定一个统计
    技能」的任务数；因此 8 个重跑分区取到同一个值，重复跑数结果也相同。任务本身没有
    push_plan / push_other 分类，两条推送任务行都显示该值，主动提问（无 job）为 `NULL`；
    分行/支行/总体维度的骨架会把这两条指标排除、宽表把它们置 `NULL`，这些维度继续用
    `ACTIVE_MANAGER_CNT`。

## 4. 与在线接口的既定差异

| # | 差异 | 原因 |
| --- | --- | --- |
| 1 | 不计算 `permission_manager_count` | 依赖初始化来源表，按需求在仓内不算 |
| 2 | 名单快照日在 `CLB_IND='3'` 范围内选择 | 避免选到没有目标口径名单行的日期 |
| 3 | 不排序、不输出 `warnings`、不区分分页 | 仓内是预聚合结果，分页与元数据属于在线响应 |
| 4 | `FIND_IN_SET` 用 `lateral view explode(split(skill_ids, ','))` + 技能目录 join 替代 | 与 MySQL 侧 `push_job_scope` 等价：按逗号元素精确匹配、不忽略空格 |
| 5 | 不适用维度写 `'ALL'`（接口返回 `null`） | 落数口径变更，便于下游区分“不适用”与“机构号缺失（空串）” |
| 6 | 一次跑数重写 8 个分区、行为数据回溯到跑数日期 | 推送后 7 天仍有点击到达，近 7 天分区必须重算才能定稿 |
| 7 | 只有客户经理维度的活跃客户经理数换成当前活跃任务数 + 当前暂停任务数 | 总体/分行/支行维度仍算 `ACTIVE_MANAGER_CNT`（在线接口也仍只算 `active_manager_count`）；落盘接口需同步新增的两列 |

差异以 [hive/README.md](../../hive/README.md) 第 4 节为准；口径调整时先改在线实现与
DESIGN/DIMENSIONS，再同步脚本与落盘接口，不允许单方面改仓内口径。

## 5. 修改指引

| 新需求 | 修改位置 | 完成判据 |
| --- | --- | --- |
| 新增指标 | 第 3 段 `VT_METRIC_FACT` 加一个指标分支，第 5 段七张宽表与目标表补列 | 长表指标名与宽表列一一对应，比例列由计数派生 |
| 新增维度（如客群） | 名单快照取字段、第 2 段事实表补维度列、`VT_METRIC_FACT` 补 `K_` 列、第 4/5 段补键 | 骨架仍按本层粒度 `select distinct`，宽表 join 键与 group by 完全一致 |
| 新增一种报表组合 | 目标表 `RPT_COMBO` 取值、第 4 段加骨架、第 5 段加宽表、第 6 段加落数语句 | 组合标签与语句一一对应，写入仍保持一条 overwrite + 其余 insert into |
| 调整统计区间 | 脚本头部与第 2 段事实的时间条件 | 名义区间与 `STAT_START_DT/STAT_END_DT` 一致 |
| 调整重跑天数 | 第 1.0 段 `VT_CALENDAR` 的行数与 `date_sub` 天数 | 行数 = 天数 + 1，事实表/骨架/宽表都靠 `REPLAY_SEQ` 传递 |
| 调整当前活跃/暂停任务口径（改成统计区间内推送过、加别的任务状态、或改成所有维度都给值） | 第 2.4 段的 `JOB_STATUS`、第 3 段的四条 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 分支、第 4 段骨架过滤、第 5/6 段列 | 两条指标列的取值规则与 `job.status` 严格对应；放宽维度范围时要去掉第 4 段的排除并改第 5 段的 `NULL` 列；同步 hive/README.md 第 3、5 节 |
| 市场技能表改名或换库 | 第 1.5 段的 `NLQ13_SWE_MARKETPLACE_SKILLS` 及库名 | 技能目录仍按 `include_in_statistics=1` 过滤、按 source+skill 去重 |
| 技能统计开关口径变化 | 第 1.5 段开关过滤、第 2.4 段推送门槛、第 2.13 / 2.15 / 2.17 段技能关联 | 与在线 `push_job_scope` / `stat_ask` 保持同进同出 |
| 新增维度或改列名 | 目标表 DDL、第 2 段事实表、`VT_METRIC_FACT` 的 `K_` 列、第 4/5 段 | 列名在临时表与目标表保持一致（客户经理 `CM_ID`、分行 `FRS_BBK_ORG_ID`、网点 `BRN_ORG_ID`、任务类型 `JOB_TYPE`） |
| 只跑某个来源或分行 | 在事实表过滤条件上加 `SOURCE_ID` / 分行条件 | 不影响其他分区与指标口径 |

## 6. 验证与限制

- 脚本按底表清单编写，本地没有可执行的 Hive 环境，**尚未在真实 Hive 运行过**，也没有
  执行计划或耗时数据；上线前需要在目标环境试跑并与在线接口对账。
- 已做的静态校验：每张临时表的 `insert ... select` 列数与建表列数一一对应（脚本级自动核对），
  七条落数语句各 33 列 = 目标表 32 列 + 动态分区列 `PRT_DT`（必须在 SELECT 末尾）、
  括号配平、临时表引用列全部存在、脚本按“日历与事实在前、落数在后”的顺序排列。
- 动态分区写入依赖 `hive.exec.dynamic.partition`（脚本内已 `set`）与 Hive 的
  `insert overwrite` 只覆盖结果里出现过的分区这一语义；上线前必须在目标环境验证
  历史分区不会被清空。
- 对账方法见 [hive/README.md](../../hive/README.md) 第 6 节；在线侧排查入口见
  [task-type-report-build-queries.md](task-type-report-build-queries.md)。
