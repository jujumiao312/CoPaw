# 金葵花任务类型报表 —— 高斯（GaussDB）跑数说明

本目录把 `hive/` 下的同一套口径移植到高斯：分段同序、指标定义不变，只换方言与落地方式；
另有少量现场简化（见第 2 节末尾），与 Hive 版不再逐字一致。指标口径真源仍是
[DESIGN.md](../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)，
Hive 版的说明见 [hive/README.md](../hive/README.md)。

## 1. 文件清单与运行方式

| 文件 | 用途 |
| --- | --- |
| `task_type_report_tables.sql` | 目标表 `${AALC_DATA}.AALC_P_RM_CLAW_LIST_USE_IND_STAT` 建表语句（29 列，列存 + 按五个维度列 hash 分布、不建分区），首次部署执行一次 |
| `task_type_report_daily.sql` | 每日跑数脚本：一次重写「跑数日期前 7 天 ~ 跑数日期」共 8 天数据，七种组合落同一张表 |
| `task_type_report_tdsql.sql` | TDSQL 落盘表（`swe_task_type_report_snapshot` / `_batch`）建表语句、历史库升级与写入约定，接口读它；数据由现场作业写入，见第 7 节 |

`task_type_report_gauss_optimized_v2.sql`、`task_type_report_gauss_optimized_v2_no_lower.sql`、
`version2.sql` 是调试期间的历史草稿（仍写旧表名 `AALC_RM_TASK_TYPE_RPT`），当前维护的是上表
前三个文件；继续用草稿要先把表名改成 `AALC_P_RM_CLAW_LIST_USE_IND_STAT`。

| 变量 | 说明 |
| --- | --- |
| `${v_Trx_Dt}` | 跑数日期，`yyyy-MM-dd`，与调度现有变量名一致 |
| `${NDS_DATA}` | 原始层库名（`NLQ13_SWE_*` 六张源表） |
| `${AALC_DATA}` | 分析层库名（客户经理名单 `AALC_R_RM_SFL_CM_BAS_INFO` 与目标表） |

```sql
-- 例：跑数日期 2026-09-17，脚本会重写 2026-09-10 ~ 2026-09-17 共 8 个分区
--     （执行前把 ${v_Trx_Dt} / ${NDS_DATA} / ${AALC_DATA} 替换成调度变量）
```

执行方式：跑数脚本的临时表是 `on commit preserve rows` 的会话级临时表，**必须在同一个会话里
整段执行**；第 6 段是「先 delete 近 8 天 + 再按组合 insert 7 次」，建议 6.0~6.7 放在同一个
事务里，避免下游在中间状态查到半份数据。

## 2. 与 Hive 版的逐段对照

| 段 | Hive 临时表 | 高斯临时表 | 说明 |
| --- | --- | --- | --- |
| 1.0 重跑日历 | `VT_CALENDAR` | `TF_CALENDAR` | 高斯版多两列：`MTH_START_DT`（当月 1 号）、`NEXT_DT`（次日零点），供事实表做半开区间过滤 |
| 1.1 名单快照日 | `VT_JKH_SNAPSHOT` | `TF_JKH_SNAPSHOT` | 高斯的快照日**逐重跑日对齐**（`TF_JKH_SNSH_DAY` 列出名单里的可用快照日）：重跑日 D 用 D 当天的名单，行带 `REPLAY_SEQ`；**当天没有快照的日期不进表、整天不出数**。不再物化名单/机构名临时表，名单在用到的地方按 `REPLAY_SEQ` 直连（详见 3.9） |
| 1.2 技能目录 | `VT_SKILL_CATALOG` | `TF_SKILL_CATALOG` | 口径不变（`include_in_statistics = 1`、按 source+skill 去重、`min(nullif(cn_name,''))`） |
| 1.3 任务类型字典 | `VT_TASK_TYPE` | `TF_TASK_TYPE` | 三条 `select ... union all`（高斯支持无 `from` 的 select）；任务类型直接用中文取值（详见 3.3） |
| 2.1~2.3 trace 痕迹 | `VT_TRACE_SUB`、`VT_TRACE_EXEC`、`VT_SUBTASK_CUST` | `TF_*` | 同样不限时间、不限来源 |
| 2.4~2.8 推送 | `VT_PUSH_JOB_SKILL`、`VT_PUSH_JOB`、`VT_PUSH_EXEC`、`VT_PUSH_EXEC_SKILL`、`VT_PUSH_CUST` | `TF_*` | 技能拆列改用 `string_to_array + unnest`（详见 3.2）；执行时间用 `ACTUAL_TIME` 半开区间 join 日历；任务表不再带任务归属人，归属人由技能表在 2.7 带出 |
| 2.9~2.10 主动提问 | `VT_ASK_SPAN`、`VT_ASK_TRACE`、`VT_ASK_CUST` | `TF_ASK_SPAN`、`TF_ASK_CUST` | 高斯的 Span 与时间窗合并为一张 `TF_ASK_SPAN`（`START_TIME` 半开区间 join 日历），不再建 `TF_ASK_TRACE` |
| 2.11~2.16 点击 | `VT_CLICK_EVENT`、`VT_CLICK_PUSH`、`VT_CLICK_PUSH_KEY`、`VT_CLICK_ASK`、`VT_CLICK_CLS`、`VT_CLICK_SKILL` | `TF_*` | 点击窗口下界取日历的当月 1 号、上界固定在跑数日期次日零点的半开区间；主动点击按 `REPLAY_SEQ` 与 Span 对齐 |
| 3 指标长表 | `VT_METRIC_FACT` | `TF_METRIC_FACT` | 同样是 18 条指标分支（含 4 条 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`） |
| 4 组合骨架 | `VT_SKEL_*`（7 张） | `TF_SKEL_*` | `overall` / `branch` / `org` 与两张技能骨架排除 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`，客户经理维度保留 |
| 5 组合宽表 | `VT_RPT_*`（7 张） | `TF_RPT_*` | `ACTIVE_MANAGER_CNT` 只在总体/分行/支行维度出数，`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 只在客户经理维度出数 |
| 6 落数 | `insert overwrite` 动态分区 | `delete` + 7 条 `insert` | 高斯没有 `insert overwrite` 与动态分区插入；日期列 `PRT_DT` 改名 `DW_DAT_DT`，名称列改为 `FRS_BBK_ORG_NM` / `BRN_ORG_NM` / `CM_NM` / `SKILL_NM`；`JOB_TYPE` 直接落中文，不再单列 `JOB_TYPE_NM`；统计区间起止不再单独落列 |

现场简化（与 Hive 版不同，改动前先看第 3 节）：

- 名单不物化：不再建 `TF_JKH_ROSTER` / `TF_BBK_NAME` / `TF_ORG_NAME`，只留 1.1 的
  `TF_JKH_SNSH_DAY`（可用快照日）与 `TF_JKH_SNAPSHOT`（当天有快照的重跑日）；
  名单在 `TF_PUSH_EXEC`、`TF_PUSH_EXEC_SKILL`、`TF_ASK_SPAN`、`TF_CLICK_EVENT`、指标长表的
  活跃/暂停任务分支以及第 6 段名称列处直连，统一先
  `inner join TF_JKH_SNAPSHOT as P on P.REPLAY_SEQ = <事实>.REPLAY_SEQ`，再带
  `DW_SNSH_DT = P.SNAPSHOT_DT + CLB_IND = '3'`——**每个分区用当天的名单，当天没有快照就不出数**。
- `TF_PUSH_JOB` 只保留 `SOURCE_ID` / `JOB_ID` / `JOB_STATUS`，任务归属人改由
  `TF_PUSH_JOB_SKILL` 在 2.7 带出（活跃人数口径仍是 `cron_jobs.tenant_id`）。
- 任务类型中文取值：`推送` / `主动` / `推送非`，目标表只留 `JOB_TYPE` 一列。
- 主动提问：Span 与时间窗合并（2.9），技能目录在 join 时直接过滤（不再带
  `IN_STAT_CATALOG` 标记）。

## 3. 方言差异（改脚本前先读）

1. **时间列比较**：NDS 层 `ACTUAL_TIME` / `START_TIME` / `CLICKED_AT` 是 `TIMESTAMP`，
   脚本用 `>= 当月 1 号 00:00 且 < 次日 00:00` 的半开区间，等价 Hive 版的
   `substr(时间列, 1, 10) between 区间起点 and 区间终点`，但不会对列做函数变换（可走索引/分区）。
2. **技能拆列**：`explode(split(skill_ids, ','))` → **`string_to_array` + `unnest`**（2.4 段）：
   命中统计技能用 `K.SKILL_ID = ANY(string_to_array(J.SKILL_IDS, ','))`，
   展开技能列用 select 里的 `unnest(string_to_array(J.SKILL_IDS, ','))`。
   这是现场确认过的写法，不再建 `TF_DIGIT` / `TF_SEQ` 序号辅助表。
   注意：按现场口径**没有对拆出的技能做 `trim()`**，`skill_ids` 里若带空格会匹配不上技能目录；
   若现场数据可能出现空格，把 2.4 的三处 `string_to_array(J.SKILL_IDS, ',')` 外面套 `trim()`
   即可（此时不再与 Hive 版逐字一致）。
   如果现场版本对 select 里的集合返回函数支持有问题，退回上一种写法也行：
   - `inner join generate_series(1, 400) as S (N) on S.N <= length(J.SKILL_IDS) - length(replace(J.SKILL_IDS, ',', '')) + 1`
   - `from ... as J, regexp_split_to_table(J.SKILL_IDS, ',') as SK (SKILL_ID)`
3. **枚举大小写**：NDS 字段说明里枚举是大写（`SUCCESS` / `ACTIVE` / `PREVIEW_VIEW` /
   `BUTTON_CLICK` …），在线实现与 Hive 版是小写，脚本统一用 `lower(列) = 'xxx'` 兼容两种写法。
   确认库里只有一种写法后可以去掉 `lower()`（更利于走原生过滤）。例外：2.4 段按现场口径
   直接用 `J.STATUS <> 'deleted'`（job 状态已确认是小写），不再套 `lower()`。
4. **零分母**：高斯除零会直接报错（Hive 返回 `NULL`），所以比例列写成
   `round(100.0 * 分子 / nullif(分母, 0), 2)`，零分母得到 `NULL`，与接口口径一致。
5. **写分区**：高斯没有 `insert overwrite`、也不支持动态分区插入，所以先
   `delete from 目标表 where DW_DAT_DT between 跑数日期-7 and 跑数日期`，再按组合 insert 七次。
   重跑幂等；建议放同一事务，必要时用 `start transaction` / `commit` 包裹。
6. **临时表与分布键**：临时表统一 `create temporary table ... on commit preserve rows`，
   列存（`orientation = column, colversion = 2.0, compression = middle`）；
   分布键是**首版经验值**——维表用 `distribute by replication`，事实表按其主键
   （`TRACE_ID` / `SOURCE_ID, JOB_ID` / 维度键）hash，上线前请按真实数据量和执行计划调优。
7. **日期函数**：统计区间起点用 `date_trunc('month', 日期)` 现算（1.0 段日历的 `MTH_START_DT`）；
   名单快照日按日历逐日对齐、不再做月末退化，所以脚本里没有 `last_day()` 等价写法。
   日期减整数仍是日期，所以 `CAST('${v_Trx_Dt}' AS DATE) - 7` 就是 Hive 的 `date_sub(..., 7)`。
8. **其他**：`cast(null as bigint)` → `CAST(NULL AS BIGINT)`；`coalesce` / `nullif` / `min` /
   `count(distinct case when ... end)` 与 Hive 写法一致；`ifnull` 统一写 `coalesce`。
9. **名单直连**：不再物化 `TF_JKH_ROSTER` / `TF_BBK_NAME` / `TF_ORG_NAME`，需要名单的地方
   直连 `${AALC_DATA}.AALC_R_RM_SFL_CM_BAS_INFO`。快照日**逐重跑日对齐**：1.1 段用
   `TF_JKH_SNSH_DAY` 汇总名单里出现过的 `DW_SNSH_DT`，只把「重跑日 D 当天就有名单快照」的
   日期写进 `TF_JKH_SNAPSHOT`（`SNAPSHOT_DT = D`，行带 `REPLAY_SEQ`）；**当天没有快照的
   重跑日不进表**——不做当月月末/最早日/最新日的退化，那几天整体不出数。
   名单表是**按快照日**存放的（同一 `CM_ID` 每个快照日一行），所以 join 统一先
   `inner join TF_JKH_SNAPSHOT as P on P.REPLAY_SEQ = <事实>.REPLAY_SEQ`，再带
   `R.DW_SNSH_DT = P.SNAPSHOT_DT`、`lower(R.CLB_IND) = '3'`，并保留原来名单表构建时的
   `trim(CM_ID) <> ''` 守卫——漏掉快照日条件会跨快照日放大行数。**重跑日 D 用 D 当天的名单**，
   所以 `DW_DAT_DT = D` 的分区按 D 的名单归属/成员判断（在线聚合报表用的是 `end_date` 单一快照），
   D 当天没有名单快照时该分区不落任何行（6.0 段仍按 8 天 delete，旧行会被清掉）。
   机构名/经理名在第 6 段用 `min(...)` 标量子查询取稳定值（子查询里用同一个 `P.SNAPSHOT_DT`），
   与在线实现
   `_roster_value`（`SELECT MIN(jkh.列) ... WHERE jkh.sync_date = :sync_date`）同一写法；
   机构名按 `FRS_BBK_ORG_ID`（+ `BRN_ORG_ID`）先聚合，避免按机构 join 时一人一行放大指标。
   任务归属人（活跃人数）不在 `TF_PUSH_JOB` 上传递，改在 2.7 由 `TF_PUSH_JOB_SKILL` 带出。
10. **任务类型中文取值**：`TF_TASK_TYPE.JOB_TYPE` 直接是 `推送` / `主动` / `推送非`，
    目标表 `JOB_TYPE` 落中文、不再单列 `JOB_TYPE_NM`。装载作业写 TDSQL 时要按第 7 节
    把这三个中文值映射回 `push_plan` / `ask_plan` / `push_other`（接口侧 `task_type` 的
    排序、筛选与前端选项仍用英文码值）。
11. **主动提问**：Span 与统计时间窗合并为 2.9 一张 `TF_ASK_SPAN`（按 `REPLAY_SEQ` 展开），
    技能目录在 join 时直接过滤（不再用 `IN_STAT_CATALOG` 标记）；主动点击在 2.14 / 2.16 用
    `REPLAY_SEQ` 与 Span 对齐，等价于「Span 当天为任务日、之后 7 天内的点击回算到该分区」。

## 4. 目标表要点

- 29 列：`DW_DAT_DT`（数据日期 = 统计区间截止日）+ `SOURCE_ID` / `RPT_COMBO`
  + 9 个维度列（`FRS_BBK_ORG_ID` / `FRS_BBK_ORG_NM` / `BRN_ORG_ID` / `BRN_ORG_NM` /
  `CM_ID` / `CM_NM` / `PST_LVL` / `SKILL_ID` / `SKILL_NM`）+ `JOB_TYPE`（中文任务类型）
  + 14 个指标列；表结构见 `task_type_report_tables.sql`。
- 统计区间不再单独建列：起点 = `DW_DAT_DT` 所在月 1 号、终点 = `DW_DAT_DT`，需要时用
  `date_trunc('month', DW_DAT_DT)` 现算。
- 计量列类型是 `INTEGER`、比例列是 `DECIMAL(18,2)`（内部临时表仍用 `BIGINT` 累加，落数时
  隐式转换）。
- **临时表列名与目标表保持一致**：名单直连时按目标表列名取值（`CM_NM` / `FRS_BBK_ORG_NM` /
  `BRN_ORG_NM` / `PST_LVL`），技能目录用 `SKILL_NM`（`SOURCE_ID` / `SKILL_ID` /
  `BRN_ORG_ID` 等原本就同名）；名单来源表本身的列名保持原样（名单表列名与目标表一致，
  NDS 来源表如 `K.CN_NAME` 仍是原名）。
- 维度列取值：本组合用不到的维度写 `'ALL'`；名单里机构号缺失才落空串 `''`（两者含义不同）。
- 指标列的 NULL 规则与接口一致：`主动` 的活跃/任务状态列为 `NULL`、`推送非`
  的方案与点击类 9 列为 `NULL`、零分母为 `NULL`；`ACTIVE_MANAGER_CNT` 只在总体/分行/支行
  维度有值，`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 只在客户经理维度有值。
- 表按现场规范建**列存 + hash 分布（五个维度列）、不建分区**，重跑靠第 6 段的
  `delete + insert` 覆盖近 8 天；库名、存储参数、压缩级别按现场规范调整。
- 列宽比 Hive 版宽：`SOURCE_ID` 100、`RPT_COMBO` 100、`JOB_TYPE` 100、`FRS_BBK_ORG_ID` /
  `CM_ID` 200、`BRN_ORG_ID` 100、`SKILL_ID` 500、名称列 500/1000。**TDSQL 落盘表的列宽按
  这套宽度对齐**，否则超长值在装载时会被截断或报 1406（见第 7 节）。
- `permission_manager_count`（有权限客户经理数）仍在接口侧实时计算，不落这张表。

## 5. 上线前待确认

1. 枚举值大小写与 `lower()` 过滤对性能的影响（见 3.3）；2.4 段已按现场口径去掉 job 状态的
   `lower()`，名单快照条件仍是 `lower(CLB_IND) = '3'`。
2. 现场版本是否支持 `PARTITION BY RANGE ... DISTRIBUTE BY HASH ... WITH (orientation = column)`
   的写法；技能拆列见 3.2（现在用的是 `any(string_to_array(...))` + select 里的 `unnest(...)`），
   若现场对 select 里集合返回函数支持有问题，改回 `generate_series` / `regexp_split_to_table`
   前先试跑 `select S.N from generate_series(1,10) as S (N);` 确认语法可用。
3. `TF_TRACE_SUB` / `TF_TRACE_EXEC` / `TF_SUBTASK_CUST` 是**全表**扫描（与 Hive 版一致）；
   2.9 段的 Span 已按日历收窄（`START_TIME` 落在统计区间内），与在线实现
   `sp.start_time >= :start AND sp.start_time < :stop` 一致；注意在线实现的「主动点击」
   关联不限制 Span 生成时间，高斯侧改成按 `REPLAY_SEQ` 取当天窗口内的 Span（见 3.11）。
   数据量大时可用 `DW_DAT_DT` 收窄，但要注意漏掉迟到数据会让主动提问/方案客户数偏小，
   取舍需与业务确认。
4. 分布键、分区策略、列存参数与并发度按目标集群压测后调整。
5. TDSQL 落盘表结构已按本表写好（见 [task_type_report_tdsql.sql](task_type_report_tdsql.sql)
   与第 7 节），**数据写入由现场作业负责**：按第 6 段重写的日期逐日写入，并把名单快照日
   `sync_date` 写进批次表——高斯表里不存该列，接口的有权限客户经理数、机构范围校验、
   机构名称解析与 `/task-type/options` 都依赖它。**快照日逐日不同**：写入 `prt_dt = D` 的
   行时，`sync_date` 要写该重跑日的 `SNAPSHOT_DT`（即 D 本身，见 1.1 段），否则接口算出的
   权限人数/机构名会和仓内的名单口径不一致；D 当天没有名单快照时该 `prt_dt` 不落行，
   也不要把批次置成 ready。

## 6. 对账建议

1. 同一 `${v_Trx_Dt}` 下，高斯与 Hive 的结果应按
   `DW_DAT_DT + SOURCE_ID + RPT_COMBO + JOB_TYPE + 维度列` 逐行一致——指标口径相同，差异是
   方言、列名（Hive 侧是 `PRT_DT` / `FIRST_BBK_NM` / `ORG_NM` / `USER_NAME` / `CN_NAME` /
   `TASK_TYPE_NAME`，高斯侧是 `DW_DAT_DT` / `FRS_BBK_ORG_NM` / `BRN_ORG_NM` / `CM_NM` /
   `SKILL_NM`）以及下面这些**有意保留的本地差异**，对账时先做值映射再比数：
   - `JOB_TYPE`：高斯是 `推送` / `主动` / `推送非`，Hive 是 `push_plan` / `ask_plan` / `push_other`，
     且高斯不再落 `JOB_TYPE_NM`（Hive 侧 `TASK_TYPE_NAME` 仍有值）；
   - 名单：高斯的名单/机构名直连名单快照并用 `min()` 取值，且**快照日逐重跑日对齐**
     （重跑日 D 用 D 当天的名单，当天没有快照则该天不出数），Hive 走 `VT_JKH_ROSTER` 等
     临时表、整段共用一个快照；
   - 主动提问：高斯的 Span 带统计时间窗、技能在 join 时过滤，主动点击按 `REPLAY_SEQ` 对齐，
     Hive 侧 `VT_ASK_SPAN` 不带时间窗、用 `in_stat_catalog` 标记；
   - Hive 侧多出的 `STAT_START_DT` / `STAT_END_DT` / `DW_STAT_DT` 在高斯侧由 `DW_DAT_DT` 现算。
2. 逐项对账顺序：`SUC_EXECUTE_JOB` → `READ_TASKS` → `RECOMMENDED_CUSTOMERS` → 三个点击客户数
   → 三个比例；比例是派生值，先对计数再对比例。
3. 重跑幂等：同一跑数日期连跑两次，8 个分区结果应完全一致。
4. 客户经理维度注意：`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 是**任务**个数（按 `job.status`
   当前值统计，不受统计区间限制，8 个分区数值相同），分行/支行维度看的是
   `ACTIVE_MANAGER_CNT`（活跃客户经理数），两者不能互相替代。

## 7. TDSQL 落盘表与落盘接口

接口 `/api/monitor/cron/report/task-type*` 读的是 TDSQL 里的两张表，**表结构见
[task_type_report_tdsql.sql](task_type_report_tdsql.sql)（只含建表语句与写入约定，
数据由现场作业自行写入，本仓库不含装载脚本）**：

| 项 | 说明 |
| --- | --- |
| 目标表 | `swe_task_type_report_snapshot`（报表行）+ `swe_task_type_report_batch`（批次状态与名单快照日） |
| 任务类型 | 高斯 `JOB_TYPE` 是中文（`推送` / `主动` / `推送非`），装载作业要映射回 `task_type` 的英文码值（`push_plan` / `ask_plan` / `push_other`），`task_type_name` 可直接用 `JOB_TYPE` 原值；接口的 `TASK_TYPE_ORDER`、`task_type` 筛选与前端选项都用英文码值 |
| 列宽 | 按源表取宽（不会被截断）；宽列拼不出主键（InnoDB 索引上限 3072 字节），主键改用 `dim_hash`（组合 + 四个维度列的 MD5） |
| 主键 | `(prt_dt, source_id, dim_hash)`，没有自增列；同键 upsert 即幂等重写 |
| 区间列 | `stat_start_dt` / `stat_end_dt` 由写入方按 `prt_dt` 推导（当月 1 号 / `prt_dt`） |
| 就绪信号 | 接口只读 `status='ready'` 的批次；半份数据或 0 行时不要置 ready，否则接口会把不完整/上一版的数据当成当天数据返回 |
| 名单快照日 | `sync_date` 必须有值（每个 `prt_dt` 用它自己那天的快照日）：有权限客户经理数、机构范围校验与机构名称解析都依赖它，为空直接 409；没有当天名单快照的 `prt_dt` 不要写入、也不要置 ready |
| 权限人数 | `permission_manager_count` 不在表里，由接口按 `jkh_user_inf` + `swe_tenant_init_source` 实时计算 |
| 空值 | 比例类与「本组合不适用」的指标必须写 `NULL`，写成 `0` 会让接口出参失真（ask_plan 的任务状态列、push_other 的方案/点击列、四个零分母比例列） |
| `'ALL'` | 落库保留原值（便于区分「不适用」与「机构号缺失空串」），接口侧统一还原成 `null`（`services/report/task_type_snapshot.py` 的 `_text` / `_dim`） |
| 历史库 | 曾按旧结构建过 TDSQL 表的库，执行该文件第 2 节的升级语句（加宽列 + 换主键），老数据不需要重刷 |
| 残留行 | 写入方式若删不掉旧行（只能 UPDATE），源侧已消失的维度行会继续出数——业务已确认接受；清理见该文件第 4 节 |
