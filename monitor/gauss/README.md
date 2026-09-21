# 金葵花任务类型报表 —— 高斯（GaussDB）跑数说明

本目录把 `hive/` 下的同一套口径移植到高斯：**逐段一一对应**，指标定义不变，只换方言与
落地方式。指标口径真源仍是
[DESIGN.md](../docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md) 与
[DIMENSIONS.md](../docs/superpowers/specs/2026-09-13-jkh-task-report/DIMENSIONS.md)，
Hive 版的说明见 [hive/README.md](../hive/README.md)。

## 1. 文件清单与运行方式

| 文件 | 用途 |
| --- | --- |
| `task_type_report_tables.sql` | 目标表 `${AALC_DATA}.AALC_P_RM_CLAW_LIST_USE_IND_STAT` 建表语句（30 列，列存 + 按五个维度列 hash 分布、不建分区），首次部署执行一次 |
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
| 1.1~1.4 名单与机构名 | `VT_JKH_SNAPSHOT`、`VT_JKH_ROSTER`、`VT_BBK_NAME`、`VT_ORG_NAME` | `TF_*` | `last_day()` 换成 `date_trunc('month', 日期 + 1 个月) - 1 天` |
| 1.5 技能目录 | `VT_SKILL_CATALOG` | `TF_SKILL_CATALOG` | 口径不变（`include_in_statistics = 1`、按 source+skill 去重、`min(nullif(cn_name,''))`） |
| 1.6 任务类型字典 | `VT_TASK_TYPE` | `TF_TASK_TYPE` | 三条 `select ... union all`（高斯支持无 `from` 的 select） |
| 1.7 序号辅助表 | 无（Hive 用 `explode` 拆列） | `TF_DIGIT`、`TF_SEQ` | 高斯侧新增：给技能 ID 按逗号拆分提供 1..400 的序号（详见 3.2） |
| 2.1~2.3 trace 痕迹 | `VT_TRACE_SUB`、`VT_TRACE_EXEC`、`VT_SUBTASK_CUST` | `TF_*` | 同样不限时间、不限来源 |
| 2.4~2.8 推送 | `VT_PUSH_JOB_SKILL`、`VT_PUSH_JOB`、`VT_PUSH_EXEC`、`VT_PUSH_EXEC_SKILL`、`VT_PUSH_CUST` | `TF_*` | 技能拆列改用 `TF_SEQ + split_part()`；执行时间用 `ACTUAL_TIME` 半开区间 join 日历 |
| 2.9~2.11 主动提问 | `VT_ASK_SPAN`、`VT_ASK_TRACE`、`VT_ASK_CUST` | `TF_*` | `START_TIME` 半开区间 join 日历 |
| 2.12~2.17 点击 | `VT_CLICK_EVENT`、`VT_CLICK_PUSH`、`VT_CLICK_PUSH_KEY`、`VT_CLICK_ASK`、`VT_CLICK_CLS`、`VT_CLICK_SKILL` | `TF_*` | 点击窗口下界取日历的当月 1 号、上界固定在跑数日期次日零点的半开区间 |
| 3 指标长表 | `VT_METRIC_FACT` | `TF_METRIC_FACT` | 同样是 18 条指标分支（含 4 条 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`） |
| 4 组合骨架 | `VT_SKEL_*`（7 张） | `TF_SKEL_*` | `overall` / `branch` / `org` 与两张技能骨架排除 `ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT`，客户经理维度保留 |
| 5 组合宽表 | `VT_RPT_*`（7 张） | `TF_RPT_*` | `ACTIVE_MANAGER_CNT` 只在总体/分行/支行维度出数，`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 只在客户经理维度出数 |
| 6 落数 | `insert overwrite` 动态分区 | `delete` + 7 条 `insert` | 高斯没有 `insert overwrite` 与动态分区插入；日期列 `PRT_DT` 改名 `DW_DAT_DT`，名称列改为 `FRS_BBK_ORG_NM` / `BRN_ORG_NM` / `CM_NM` / `SKILL_NM` / `JOB_TYPE_NM`，统计区间起止不再单独落列 |

## 3. 方言差异（改脚本前先读）

1. **时间列比较**：NDS 层 `ACTUAL_TIME` / `START_TIME` / `CLICKED_AT` 是 `TIMESTAMP`，
   脚本用 `>= 当月 1 号 00:00 且 < 次日 00:00` 的半开区间，等价 Hive 版的
   `substr(时间列, 1, 10) between 区间起点 and 区间终点`，但不会对列做函数变换（可走索引/分区）。
2. **技能拆列**：`explode(split(skill_ids, ','))` → **序号辅助表 + `split_part()`**：
   `inner join TF_SEQ as S on S.N <= length(skill_ids) - length(replace(skill_ids, ',', '')) + 1`，
   取第 N 个技能用 `trim(split_part(skill_ids, ',', S.N))`。
   原因：高斯（GaussDB(DWS)）对 FROM 里的 set-returning 函数 / LATERAL 支持与 PostgreSQL
   不一致，`cross join lateral regexp_split_to_table(...)` 在现场会报语法错误；这个写法不依赖
   SRF、不依赖 LATERAL、也不用递归 CTE。语义与 `explode` 完全一致（按逗号精确切分、不忽略
   空格，空元素由技能目录 join 过滤）。
   如果现场版本支持 SRF，可以少建两张表，把 2.4 的 join 改成下面任一种：
   - `inner join generate_series(1, 400) as S (N) on S.N <= length(J.SKILL_IDS) - length(replace(J.SKILL_IDS, ',', '')) + 1`
   - `from ... as J, regexp_split_to_table(J.SKILL_IDS, ',') as SK (SKILL_ID)`（不支持 LATERAL 关键字时可用）
   - `from ... as J, unnest(string_to_array(J.SKILL_IDS, ',')) as SK (SKILL_ID)`
3. **枚举大小写**：NDS 字段说明里枚举是大写（`SUCCESS` / `ACTIVE` / `PREVIEW_VIEW` /
   `BUTTON_CLICK` …），在线实现与 Hive 版是小写，脚本统一用 `lower(列) = 'xxx'` 兼容两种写法。
   确认库里只有一种写法后可以去掉 `lower()`（更利于走原生过滤）。
4. **零分母**：高斯除零会直接报错（Hive 返回 `NULL`），所以比例列写成
   `round(100.0 * 分子 / nullif(分母, 0), 2)`，零分母得到 `NULL`，与接口口径一致。
5. **写分区**：高斯没有 `insert overwrite`、也不支持动态分区插入，所以先
   `delete from 目标表 where DW_DAT_DT between 跑数日期-7 and 跑数日期`，再按组合 insert 七次。
   重跑幂等；建议放同一事务，必要时用 `start transaction` / `commit` 包裹。
6. **临时表与分布键**：临时表统一 `create temporary table ... on commit preserve rows`，
   列存（`orientation = column, colversion = 2.0, compression = middle`）；
   分布键是**首版经验值**——维表用 `distribute by replication`，事实表按其主键
   （`TRACE_ID` / `SOURCE_ID, JOB_ID` / 维度键）hash，上线前请按真实数据量和执行计划调优。
7. **日期函数**：`last_day()` 用 `date_trunc('month', 日期 + interval '1 month') - 1` 替代；
   日期减整数仍是日期，所以 `CAST('${v_Trx_Dt}' AS DATE) - 7` 就是 Hive 的 `date_sub(..., 7)`。
8. **其他**：`cast(null as bigint)` → `CAST(NULL AS BIGINT)`；`coalesce` / `nullif` / `min` /
   `count(distinct case when ... end)` 与 Hive 写法一致；`ifnull` 统一写 `coalesce`。

## 4. 目标表要点

- 30 列：`DW_DAT_DT`（数据日期 = 统计区间截止日）+ `SOURCE_ID` / `RPT_COMBO`
  + 9 个维度列（`FRS_BBK_ORG_ID` / `FRS_BBK_ORG_NM` / `BRN_ORG_ID` / `BRN_ORG_NM` /
  `CM_ID` / `CM_NM` / `PST_LVL` / `SKILL_ID` / `SKILL_NM`）+ `JOB_TYPE` / `JOB_TYPE_NM`
  + 14 个指标列；表结构见 `task_type_report_tables.sql`。
- 统计区间不再单独建列：起点 = `DW_DAT_DT` 所在月 1 号、终点 = `DW_DAT_DT`，需要时用
  `date_trunc('month', DW_DAT_DT)` 现算。
- 计量列类型是 `INTEGER`、比例列是 `DECIMAL(18,2)`（内部临时表仍用 `BIGINT` 累加，落数时
  隐式转换）。
- **临时表列名与目标表保持一致**：名单快照用 `CM_NM` / `FRS_BBK_ORG_NM`，分行名称表用
  `FRS_BBK_ORG_NM`，技能目录用 `SKILL_NM`（`SOURCE_ID` / `SKILL_ID` / `BRN_ORG_ID` /
  `BRN_ORG_NM` / `PST_LVL` 等原本就同名）；只有 NDS 来源表的列名保持原样
  （例如 `K.CN_NAME`、`S.CM_NM`）。
- 维度列取值：本组合用不到的维度写 `'ALL'`；名单里机构号缺失才落空串 `''`（两者含义不同）。
- 指标列的 NULL 规则与接口一致：`ask_plan` 的活跃/任务状态列为 `NULL`、`push_other`
  的方案与点击类 9 列为 `NULL`、零分母为 `NULL`；`ACTIVE_MANAGER_CNT` 只在总体/分行/支行
  维度有值，`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 只在客户经理维度有值。
- 表按现场规范建**列存 + hash 分布（五个维度列）、不建分区**，重跑靠第 6 段的
  `delete + insert` 覆盖近 8 天；库名、存储参数、压缩级别按现场规范调整。
- 列宽比 Hive 版宽：`SOURCE_ID` 100、`RPT_COMBO` 100、`JOB_TYPE` 100、`FRS_BBK_ORG_ID` /
  `CM_ID` 200、`BRN_ORG_ID` 100、`SKILL_ID` 500、名称列 500/1000。**TDSQL 落盘表的列宽按
  这套宽度对齐**，否则超长值在装载时会被截断或报 1406（见第 7 节）。
- `permission_manager_count`（有权限客户经理数）仍在接口侧实时计算，不落这张表。

## 5. 上线前待确认

1. 枚举值大小写与 `lower()` 过滤对性能的影响（见 3.3）。
2. 现场版本是否支持 `PARTITION BY RANGE ... DISTRIBUTE BY HASH ... WITH (orientation = column)`
   的写法；技能拆列已经不依赖 SRF / LATERAL（见 3.2），若想改回 `generate_series` 简写，
   先在现场试跑一条 `select S.N from generate_series(1,10) as S (N);` 确认语法可用。
3. `TF_TRACE_SUB` / `TF_TRACE_EXEC` / `TF_SUBTASK_CUST` 是**全表**扫描（与 Hive 版一致）。
   数据量大时可用 `DW_DAT_DT` 收窄，但要注意漏掉迟到数据会让主动提问/方案客户数偏小，
   取舍需与业务确认。
4. 分布键、分区策略、列存参数与并发度按目标集群压测后调整。
5. TDSQL 落盘表结构已按本表写好（见 [task_type_report_tdsql.sql](task_type_report_tdsql.sql)
   与第 7 节），**数据写入由现场作业负责**：按第 6 段重写的日期逐日写入，并把名单快照日
   `sync_date`（第 1.1 段选出的 `DW_Snsh_Dt`）写进批次表——高斯表里不存该列，接口的
   有权限客户经理数、机构名称解析与 `/task-type/options` 都依赖它。

## 6. 对账建议

1. 同一 `${v_Trx_Dt}` 下，高斯与 Hive 的结果应按
   `DW_DAT_DT + SOURCE_ID + RPT_COMBO + JOB_TYPE + 维度列` 逐行一致——口径相同，差异只有方言
   与列名（Hive 侧是 `PRT_DT` / `FIRST_BBK_NM` / `ORG_NM` / `USER_NAME` / `CN_NAME` /
   `TASK_TYPE_NAME`，高斯侧是 `DW_DAT_DT` / `FRS_BBK_ORG_NM` / `BRN_ORG_NM` / `CM_NM` /
   `SKILL_NM` / `JOB_TYPE_NM`），Hive 侧多出的 `STAT_START_DT` / `STAT_END_DT` / `DW_STAT_DT`
   在高斯侧由 `DW_DAT_DT` 现算。
2. 逐项对账顺序：`SUC_EXECUTE_JOB` → `READ_TASKS` → `RECOMMENDED_CUSTOMERS` → 三个点击客户数
   → 三个比例；比例是派生值，先对计数再对比例。
3. 重跑幂等：同一跑数日期连跑两次，8 个分区结果应完全一致。
4. 客户经理维度注意：`ACTIVE_JOB_CNT` / `PAUSED_JOB_CNT` 是**任务**个数（按 `job.status`
   当前值统计，不受统计区间限制，8 个分区数值相同），分行/支行维度看的是
   `ACTIVE_MANAGER_CNT`（活跃客户经理数），两者不能互相替代。

## 7. TDSQL 落盘表与落盘接口

接口 `/api/monitor/report/task-type*` 读的是 TDSQL 里的两张表，**表结构见
[task_type_report_tdsql.sql](task_type_report_tdsql.sql)（只含建表语句与写入约定，
数据由现场作业自行写入，本仓库不含装载脚本）**：

| 项 | 说明 |
| --- | --- |
| 目标表 | `swe_task_type_report_snapshot`（报表行）+ `swe_task_type_report_batch`（批次状态与名单快照日） |
| 列宽 | 按源表取宽（不会被截断）；宽列拼不出主键（InnoDB 索引上限 3072 字节），主键改用 `dim_hash`（组合 + 四个维度列的 MD5） |
| 主键 | `(prt_dt, source_id, dim_hash)`，没有自增列；同键 upsert 即幂等重写 |
| 区间列 | `stat_start_dt` / `stat_end_dt` 由写入方按 `prt_dt` 推导（当月 1 号 / `prt_dt`） |
| 就绪信号 | 接口只读 `status='ready'` 的批次；半份数据或 0 行时不要置 ready，否则接口会把不完整/上一版的数据当成当天数据返回 |
| 名单快照日 | `sync_date` 必须有值：有权限客户经理数、机构范围校验与机构名称解析都依赖它，为空直接 409 |
| 权限人数 | `permission_manager_count` 不在表里，由接口按 `jkh_user_inf` + `swe_tenant_init_source` 实时计算 |
| 空值 | 比例类与「本组合不适用」的指标必须写 `NULL`，写成 `0` 会让接口出参失真（ask_plan 的任务状态列、push_other 的方案/点击列、四个零分母比例列） |
| `'ALL'` | 落库保留原值（便于区分「不适用」与「机构号缺失空串」），接口侧统一还原成 `null`（`services/report/task_type_snapshot.py` 的 `_text` / `_dim`） |
| 历史库 | 曾按旧结构建过 TDSQL 表的库，执行该文件第 2 节的升级语句（加宽列 + 换主键），老数据不需要重刷 |
| 残留行 | 写入方式若删不掉旧行（只能 UPDATE），源侧已消失的维度行会继续出数——业务已确认接受；清理见该文件第 4 节 |
