-- =============================================================================
-- 金葵花任务类型报表 —— 高斯（GaussDB）跑数脚本（每天重跑近 7 天 + 当天）
--
-- 对应目标表：${AALC_DATA}.AALC_RM_TASK_TYPE_RPT（建表见 gauss/task_type_report_tables.sql）
-- 入参      ：${v_Trx_Dt}  跑数日期（yyyy-MM-dd，由调度传入，与高斯示例脚本变量名一致）
-- 来源库    ：${NDS_DATA} 原始层（NLQ13_SWE_*）、${AALC_DATA} 分析层（客户经理名单与目标表）
-- 血缘      ：本脚本由 hive/task_type_report_daily.sql 逐段移植，口径一致；
--             方言差异与逐段对照见 gauss/README.md
--
-- 统计区间（重跑日历见第 1.0 段）：
--   一次作业按日历写入 8 个日期分区，重跑日 D 依次取「跑数日期 R 前 7 天 ~ 跑数日期」：
--     * 推送任务、主动提问：当月 1 号 ~ D，按推送当天/提问当天落到该分区；
--     * 客户点击等行为：当月 1 号 ~ R，推送后 7 天内到达的点击都算回推送当天所在分区。
--   因此分区 D 会在 D ~ D+7 的每次运行里被重写，D+7 之后才定稿。
--
-- 写入方式：高斯没有 insert overwrite、也不支持动态分区插入，所以第 6 段先
--   delete 掉 8 天分区的数据，再按七种组合各 insert 一次；建议 8 条语句放在同一事务里执行
--   （barrier 后统一 commit），避免查数时读到半份数据。
--
-- 与 Hive 版的方言差异（逐条对照见 gauss/README.md）：
--   1. 临时表统一用 TF_ 前缀，create temporary table ... on commit preserve rows，
--      列存（orientation = column, colversion = 2.0, compression = middle）并指定 distribute by；
--   2. NDS 层时间列是 TIMESTAMP，直接用「>= 当月 1 号 00:00 且 < 次日 00:00」比较，
--      不再用 Hive 的 substr(时间列, 1, 10) 取字符串日期；
--   3. 日历表里直接给出 MTH_START_DT（当月 1 号）与 NEXT_DT（次日零点），事实表 join 日历取值，
--      不用在每处重算 concat(substr(...), '-01')；
--   4. explode(split(skill_ids, ',')) 用「序号辅助表 TF_SEQ + split_part()」替代（见第 1.7 段）：
--      高斯对 FROM 里的 set-returning 函数 / LATERAL 支持与 PostgreSQL 不一致，
--      cross join lateral regexp_split_to_table(...) 会报语法错误，所以不依赖 SRF 与 LATERAL；
--   5. 枚举值统一用 lower(列) = 'xxx' 比较：NDS 字段说明里枚举是大写（SUCCESS / ACTIVE /
--      PREVIEW_VIEW / BUTTON_CLICK …），在线实现与 Hive 版是小写，lower() 两种都能匹配；
--      确认库里只有一种写法后可以去掉 lower()，让过滤条件走原生比较；
--   6. 不使用 CTE 与派生表，分段与 Hive 版一一对应（1.0~1.6 / 2.1~2.17 / 3 / 4 / 5 / 6），
--      便于两个库对账。
-- =============================================================================


-- =============================================================================
-- 1. 基础维表与重跑日历
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.0 重跑日历（跑数日期前 7 天 ~ 跑数当天，共 8 行）
--     点击等行为数据以任务推送当天为基线、要统计推送后 7 天，所以同一个推送日期分区
--     在它之后 7 天的每次运行里都要重算。日历给出一轮要重跑的所有日期：
--       REPLAY_SEQ   = 重跑序号，1 = 跑数日期前 7 天，8 = 跑数当天；
--       REPLAY_DT    = 重跑日期 = 本次写入的分区 DW_DAT_DT = 该分区的统计截止日；
--       MTH_START_DT = REPLAY_DT 所在月 1 号（统计区间起点，跨月时各重跑日各算各的）；
--       NEXT_DT      = REPLAY_DT 次日（时间戳过滤用半开区间上界）。
--     改重跑天数只需改本段的行数与偏移天数（行数 = 天数 + 1）。
-- -----------------------------------------------------------------------------
drop table if exists TF_CALENDAR;
create temporary table TF_CALENDAR    /* 重跑日历 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号：1=跑数日期前 7 天 … 8=跑数当天 */
,REPLAY_DT             DATE           NOT NULL    /* 重跑日期（本次写入的分区值） */
,MTH_START_DT          DATE           NOT NULL    /* 重跑日期所在月 1 号：统计区间起点 */
,NEXT_DT               DATE           NOT NULL    /* 重跑日期次日：时间戳半开区间上界 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_CALENDAR
(
   REPLAY_SEQ            /* 重跑序号 */
  ,REPLAY_DT             /* 重跑日期 */
  ,MTH_START_DT          /* 统计区间起点 */
  ,NEXT_DT               /* 区间上界（次日） */
)
select
  1 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 7 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 7) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 6 as NEXT_DT                                            /* 区间上界（次日） */
union all
select
  2 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 6 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 6) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 5 as NEXT_DT                                            /* 区间上界（次日） */
union all
select
  3 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 5 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 5) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 4 as NEXT_DT                                            /* 区间上界（次日） */
union all
select
  4 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 4 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 4) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 3 as NEXT_DT                                            /* 区间上界（次日） */
union all
select
  5 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 3 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 3) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 2 as NEXT_DT                                            /* 区间上界（次日） */
union all
select
  6 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 2 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 2) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 1 as NEXT_DT                                            /* 区间上界（次日） */
union all
select
  7 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) - 1 as REPLAY_DT                                          /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) - 1) AS DATE) as MTH_START_DT    /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) as NEXT_DT                                                /* 区间上界（次日） */
union all
select
  8 as REPLAY_SEQ                                                                        /* 重跑序号 */
  ,CAST('${v_Trx_Dt}' AS DATE) as REPLAY_DT                                              /* 重跑日期 */
  ,CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE)) AS DATE) as MTH_START_DT        /* 统计区间起点 */
  ,CAST('${v_Trx_Dt}' AS DATE) + 1 as NEXT_DT                                            /* 区间上界（次日） */
;


-- -----------------------------------------------------------------------------
-- 1.1 名单快照日（对应接口 _resolve_jkh_sync_date）
--     优先级：跑数日期当天 -> 跑数日期当月月末 -> 全表最早日（全表最新日在跑数日期之后）
--             -> 全表最新日；只在 CLB_IND = '3' 口径内选择
--     月末用 date_trunc('month', 跑数日期 + 1 个月) - 1 天 替代 Hive 的 last_day()
-- -----------------------------------------------------------------------------
drop table if exists TF_JKH_SNAPSHOT;
create temporary table TF_JKH_SNAPSHOT    /* 客户经理名单快照日 */
(
 SNAPSHOT_DT           DATE           NOT NULL    /* 名单快照日 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_JKH_SNAPSHOT
(
   SNAPSHOT_DT           /* 名单快照日 */
)
select
  coalesce(
      max(case when S.DW_SNSH_DT = CAST('${v_Trx_Dt}' AS DATE) then S.DW_SNSH_DT end)
     ,max(case when S.DW_SNSH_DT = CAST(date_trunc('month', CAST('${v_Trx_Dt}' AS DATE) + interval '1 month') AS DATE) - 1
               then S.DW_SNSH_DT end)
     ,case when max(S.DW_SNSH_DT) > CAST('${v_Trx_Dt}' AS DATE) then min(S.DW_SNSH_DT) else max(S.DW_SNSH_DT) end
  ) as SNAPSHOT_DT          /* 名单快照日 */
from ${AALC_DATA}.AALC_R_RM_SFL_CM_BAS_INFO as S    /* 金葵花客户经理名单 */
where lower(S.CLB_IND) = '3'
;


-- -----------------------------------------------------------------------------
-- 1.2 客户经理名单快照（分行取 FRS_BBK_ORG_ID，支行取 BRN_ORG_ID）
--     一名客户经理一行，机构名称/岗位重复取值用 min 取稳定值
-- -----------------------------------------------------------------------------
drop table if exists TF_JKH_ROSTER;
create temporary table TF_JKH_ROSTER    /* 金葵花客户经理名单快照 */
(
 CM_ID                 VARCHAR(200)   NOT NULL    /* 客户经理编号（SAP号），对应 jkh_user_inf.user_id */
,CM_NM                 VARCHAR(500)               /* 客户经理姓名 */
,PST_LVL               VARCHAR(100)               /* 岗位定级 */
,BRN_ORG_ID            VARCHAR(100)               /* 网点号 */
,BRN_ORG_NM            VARCHAR(500)               /* 网点名称 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 一级分行号 */
,FRS_BBK_ORG_NM        VARCHAR(500)               /* 一级分行名称 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_JKH_ROSTER
(
   CM_ID                 /* 客户经理编号 */
  ,CM_NM                 /* 客户经理姓名 */
  ,PST_LVL               /* 岗位定级 */
  ,BRN_ORG_ID            /* 网点号 */
  ,BRN_ORG_NM            /* 网点名称 */
  ,FRS_BBK_ORG_ID        /* 一级分行号 */
  ,FRS_BBK_ORG_NM        /* 一级分行名称 */
)
select
  S.CM_ID as CM_ID                       /* 客户经理编号 */
  ,min(S.CM_NM) as CM_NM                 /* 客户经理姓名 */
  ,min(S.PST_LVL) as PST_LVL             /* 岗位定级 */
  ,min(S.BRN_ORG_ID) as BRN_ORG_ID       /* 网点号 */
  ,min(S.BRN_ORG_NM) as BRN_ORG_NM       /* 网点名称 */
  ,min(S.FRS_BBK_ORG_ID) as FRS_BBK_ORG_ID    /* 一级分行号 */
  ,min(S.FRS_BBK_ORG_NM) as FRS_BBK_ORG_NM    /* 一级分行名称 */
from ${AALC_DATA}.AALC_R_RM_SFL_CM_BAS_INFO as S    /* 金葵花客户经理名单 */
inner join TF_JKH_SNAPSHOT as P
        on S.DW_SNSH_DT = P.SNAPSHOT_DT
where lower(S.CLB_IND) = '3'
  and S.CM_ID is not null
  and trim(S.CM_ID) <> ''
group by S.CM_ID
;


-- -----------------------------------------------------------------------------
-- 1.3 分行名称（对应接口 permissions 的 MIN(first_bbk_nm)）
-- -----------------------------------------------------------------------------
drop table if exists TF_BBK_NAME;
create temporary table TF_BBK_NAME    /* 分行名称 */
(
 FRS_BBK_ORG_ID        VARCHAR(200)   NOT NULL    /* 一级分行号 */
,FRS_BBK_ORG_NM        VARCHAR(500)               /* 一级分行名称 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_BBK_NAME
(
   FRS_BBK_ORG_ID        /* 一级分行号 */
  ,FRS_BBK_ORG_NM        /* 一级分行名称 */
)
select
  coalesce(S.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    /* 一级分行号 */
  ,min(S.FRS_BBK_ORG_NM) as FRS_BBK_ORG_NM          /* 一级分行名称 */
from TF_JKH_ROSTER as S    /* 金葵花客户经理名单快照 */
group by coalesce(S.FRS_BBK_ORG_ID, '')
;


-- -----------------------------------------------------------------------------
-- 1.4 网点名称（对应接口 permissions 的 MIN(org_nm)，按 分行+网点 联合键）
-- -----------------------------------------------------------------------------
drop table if exists TF_ORG_NAME;
create temporary table TF_ORG_NAME    /* 网点名称 */
(
 FRS_BBK_ORG_ID        VARCHAR(200)   NOT NULL    /* 一级分行号 */
,BRN_ORG_ID            VARCHAR(100)   NOT NULL    /* 网点号 */
,BRN_ORG_NM            VARCHAR(500)               /* 网点名称 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_ORG_NAME
(
   FRS_BBK_ORG_ID        /* 一级分行号 */
  ,BRN_ORG_ID            /* 网点号 */
  ,BRN_ORG_NM            /* 网点名称 */
)
select
  coalesce(S.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    /* 一级分行号 */
  ,coalesce(S.BRN_ORG_ID, '') as BRN_ORG_ID           /* 网点号 */
  ,min(S.BRN_ORG_NM) as BRN_ORG_NM                    /* 网点名称 */
from TF_JKH_ROSTER as S    /* 金葵花客户经理名单快照 */
group by coalesce(S.FRS_BBK_ORG_ID, ''), coalesce(S.BRN_ORG_ID, '')
;


-- -----------------------------------------------------------------------------
-- 1.5 技能目录（等价接口侧 swe_marketplace_skills 的去重目录）
--     来源 NLQ13_SWE_MARKETPLACE_SKILLS；只取 include_in_statistics = 1 且 skill_id 非空，
--     按 (source_id, skill_id) 去重，中文名取 min(nullif(cn_name, ''))
-- -----------------------------------------------------------------------------
drop table if exists TF_SKILL_CATALOG;
create temporary table TF_SKILL_CATALOG    /* 技能目录（纳入统计的市场技能） */
(
 SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* 技能ID */
,SKILL_NM              VARCHAR(1024)              /* 技能中文名，空值表示目录里没有中文名 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_SKILL_CATALOG
(
   SOURCE_ID             /* 来源标识 */
  ,SKILL_ID              /* 技能ID */
  ,SKILL_NM              /* 技能中文名 */
)
select
  K.SOURCE_ID as SOURCE_ID                            /* 来源标识 */
  ,trim(K.SKILL_ID) as SKILL_ID                       /* 技能ID */
  ,min(nullif(trim(K.CN_NAME), '')) as SKILL_NM       /* 技能中文名 */
from ${NDS_DATA}.NLQ13_SWE_MARKETPLACE_SKILLS as K    /* 市场技能目录 */
where coalesce(K.INCLUDE_IN_STATISTICS, 0) = 1
  and K.SKILL_ID is not null
  and trim(K.SKILL_ID) <> ''
group by K.SOURCE_ID, trim(K.SKILL_ID)
;


-- -----------------------------------------------------------------------------
-- 1.6 任务类型字典（三类任务，用于给每个维度对象补齐三行）
-- -----------------------------------------------------------------------------
drop table if exists TF_TASK_TYPE;
create temporary table TF_TASK_TYPE    /* 任务类型字典 */
(
 JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_TASK_TYPE
(
   JOB_TYPE              /* 任务类型 */
)
select 'push_plan' as JOB_TYPE          /* 推送(名单+方案) */
union all
select 'ask_plan' as JOB_TYPE           /* 主动提问(名单+方案) */
union all
select 'push_other' as JOB_TYPE         /* 推送(非名单方案) */
;


-- -----------------------------------------------------------------------------
-- 1.7 序号辅助表（技能ID按逗号拆分用，替代 Hive 的 explode + split）
--     高斯（GaussDB(DWS)）对 FROM 里的 set-returning 函数 / LATERAL 支持与 PostgreSQL
--     不一致，cross join lateral regexp_split_to_table(...) 会报语法错误，所以用
--     「数字表 + split_part(字符串, ',', N)」实现同一件事：不依赖 SRF、不依赖 LATERAL、
--     也不用递归 CTE（用 10 行数字表三次笛卡尔积造出 1..1000 再取前 400 行）。
--     为什么是 400：SKILL_IDS 是 VARCHAR(800)，按逗号拆分后 token 数远小于 400；
--     若现场可能出现更多技能，把下面的 400（两处）一起调大即可。
-- -----------------------------------------------------------------------------
drop table if exists TF_DIGIT;
create temporary table TF_DIGIT    /* 个位数字表 1..10 */
(
 N                     INTEGER        NOT NULL    /* 数字 1..10 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_DIGIT
(
   N                     /* 数字 1..10 */
)
select 1 as N    /* 1 */
union all select 2    /* 2 */
union all select 3    /* 3 */
union all select 4    /* 4 */
union all select 5    /* 5 */
union all select 6    /* 6 */
union all select 7    /* 7 */
union all select 8    /* 8 */
union all select 9    /* 9 */
union all select 10   /* 10 */
;


drop table if exists TF_SEQ;
create temporary table TF_SEQ    /* 序号辅助表 1..400 */
(
 N                     INTEGER        NOT NULL    /* 序号 1..400 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_SEQ
(
   N                     /* 序号 1..400 */
)
select A.N * 100 + B.N * 10 + C.N - 110 as N    /* 三位数字组合，取值 1..1000 */
from TF_DIGIT as A    /* 百位 */
cross join TF_DIGIT as B    /* 十位 */
cross join TF_DIGIT as C    /* 个位 */
where A.N * 100 + B.N * 10 + C.N - 110 <= 400
;


-- =============================================================================
-- 2. 事实集合
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 有子任务的 trace（接口 has_sub，用于推送类型分类与主动提问判定）
--     与 Hive 版一致：不限时间、不限来源
-- -----------------------------------------------------------------------------
drop table if exists TF_TRACE_SUB;
create temporary table TF_TRACE_SUB    /* 存在子任务的 trace */
(
 TRACE_ID              VARCHAR(256)   NOT NULL    /* trace_id */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (TRACE_ID)
;
insert into TF_TRACE_SUB
(
   TRACE_ID              /* trace_id */
)
select distinct
  S.TRACE_ID as TRACE_ID        /* trace_id */
from ${NDS_DATA}.NLQ13_SWE_CRON_SUBTASKS as S    /* 定时任务子任务 */
where S.TRACE_ID is not null
  and S.TRACE_ID <> ''
;


-- -----------------------------------------------------------------------------
-- 2.2 有执行记录的 trace（接口主动提问判定的“历史执行里不存在同 trace”）
--     不限时间、不限来源，与接口口径一致
-- -----------------------------------------------------------------------------
drop table if exists TF_TRACE_EXEC;
create temporary table TF_TRACE_EXEC    /* 存在执行记录的 trace */
(
 TRACE_ID              VARCHAR(256)   NOT NULL    /* trace_id */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (TRACE_ID)
;
insert into TF_TRACE_EXEC
(
   TRACE_ID              /* trace_id */
)
select distinct
  E.TRACE_ID as TRACE_ID        /* trace_id */
from ${NDS_DATA}.NLQ13_SWE_CRON_EXECUTIONS as E    /* 定时任务执行记录 */
where E.TRACE_ID is not null
  and E.TRACE_ID <> ''
;


-- -----------------------------------------------------------------------------
-- 2.3 子任务客户（方案客户来源），按 trace + 客户去重
-- -----------------------------------------------------------------------------
drop table if exists TF_SUBTASK_CUST;
create temporary table TF_SUBTASK_CUST    /* 子任务里的方案客户 */
(
 TRACE_ID              VARCHAR(256)   NOT NULL    /* trace_id */
,CUSTUID               VARCHAR(256)   NOT NULL    /* 任务中客户UID */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (TRACE_ID)
;
insert into TF_SUBTASK_CUST
(
   TRACE_ID              /* trace_id */
  ,CUSTUID               /* 任务中客户UID */
)
select distinct
  S.TRACE_ID as TRACE_ID        /* trace_id */
  ,S.CUSTUID as CUSTUID         /* 任务中客户UID */
from ${NDS_DATA}.NLQ13_SWE_CRON_SUBTASKS as S    /* 定时任务子任务 */
where S.TRACE_ID is not null
  and S.TRACE_ID <> ''
  and S.CUSTUID is not null
  and S.CUSTUID <> ''
;


-- -----------------------------------------------------------------------------
-- 2.4 合规推送任务 × 统计技能（接口 push_job_scope）
--     条件：job 未删除、未标记删除、skill_ids 非空，且命中的技能在统计目录内
--     技能拆列：Hive 用 lateral view explode(split(skill_ids, ','))；
--     高斯（GaussDB(DWS)）对 FROM 里的 set-returning 函数 / LATERAL 支持与 PostgreSQL 不一致，
--     直接写 cross join lateral regexp_split_to_table(...) 会报语法错误，因此改成
--     「序号辅助表 TF_SEQ + split_part(skill_ids, ',', N)」：
--       第 N 个技能 = trim(split_part(skill_ids, ',', N))，N 从 1 取到「逗号个数 + 1」。
--     语义与 explode 完全一致（按逗号精确切分、不忽略空格，空元素由技能目录 join 过滤）。
--     若现场版本支持 SRF，也可以少建一张表直接用 generate_series（见 gauss/README.md 第 3 节）。
-- -----------------------------------------------------------------------------
drop table if exists TF_PUSH_JOB_SKILL;
create temporary table TF_PUSH_JOB_SKILL    /* 推送任务×统计技能 */
(
 SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_ID                VARCHAR(256)   NOT NULL    /* 任务ID */
,OWNER_CM_ID           VARCHAR(256)               /* 任务归属人，取任务表 tenant_id */
,JOB_STATUS            VARCHAR(64)                /* 任务当前状态，取 job.status（ACTIVE/PAUSED…） */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* 任务绑定的统计技能ID */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, JOB_ID)
;
insert into TF_PUSH_JOB_SKILL
(
   SOURCE_ID             /* 来源标识 */
  ,JOB_ID                /* 任务ID */
  ,OWNER_CM_ID           /* 任务归属人 */
  ,JOB_STATUS            /* 任务当前状态 */
  ,SKILL_ID              /* 任务绑定的统计技能ID */
)
select distinct
  J.SOURCE_ID as SOURCE_ID          /* 来源标识 */
  ,J.ID as JOB_ID                   /* 任务ID */
  ,J.TENANT_ID as OWNER_CM_ID       /* 任务归属人 */
  ,J.STATUS as JOB_STATUS           /* 任务当前状态 */
  ,trim(split_part(J.SKILL_IDS, ',', S.N)) as SKILL_ID    /* 任务绑定的统计技能ID（第 N 个） */
from ${NDS_DATA}.NLQ13_SWE_CRON_JOBS as J    /* 定时任务定义 */
inner join TF_SEQ as S    /* 序号辅助表 1..400 */
        on S.N <= length(J.SKILL_IDS) - length(replace(J.SKILL_IDS, ',', '')) + 1    /* N 不超过技能个数 */
inner join TF_SKILL_CATALOG as K    /* 技能目录（纳入统计的市场技能） */
        on K.SOURCE_ID = J.SOURCE_ID
       and K.SKILL_ID = trim(split_part(J.SKILL_IDS, ',', S.N))
where J.DELETED_AT is null
  and lower(J.STATUS) <> 'deleted'
  and J.SKILL_IDS is not null
  and trim(J.SKILL_IDS) <> ''
;


-- -----------------------------------------------------------------------------
-- 2.5 合规推送任务（任务粒度，去掉技能列）
-- -----------------------------------------------------------------------------
drop table if exists TF_PUSH_JOB;
create temporary table TF_PUSH_JOB    /* 合规推送任务 */
(
 SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_ID                VARCHAR(256)   NOT NULL    /* 任务ID */
,OWNER_CM_ID           VARCHAR(256)               /* 任务归属人 */
,JOB_STATUS            VARCHAR(64)                /* 任务当前状态 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, JOB_ID)
;
insert into TF_PUSH_JOB
(
   SOURCE_ID             /* 来源标识 */
  ,JOB_ID                /* 任务ID */
  ,OWNER_CM_ID           /* 任务归属人 */
  ,JOB_STATUS            /* 任务当前状态 */
)
select distinct
  J.SOURCE_ID as SOURCE_ID          /* 来源标识 */
  ,J.JOB_ID as JOB_ID               /* 任务ID */
  ,J.OWNER_CM_ID as OWNER_CM_ID     /* 任务归属人 */
  ,J.JOB_STATUS as JOB_STATUS       /* 任务当前状态 */
from TF_PUSH_JOB_SKILL as J    /* 推送任务×统计技能 */
;


-- -----------------------------------------------------------------------------
-- 2.6 推送任务集合（执行粒度）：接口 push 子查询
--     过滤：任务合规、执行时间在「当月 1 号 ~ 重跑日」区间、
--           「有同 trace 子任务」或「执行与异步状态均成功」
--     分类：有子任务 -> push_plan，无子任务且成功 -> push_other
--     名单：执行人、任务归属人分别匹配名单（一个没在名单里不影响另一列，用标记区分）
--     重跑：关联第 1.0 段日历，每个重跑日各出一份执行集合（带 REPLAY_SEQ）
-- -----------------------------------------------------------------------------
drop table if exists TF_PUSH_EXEC;
create temporary table TF_PUSH_EXEC    /* 推送任务集合（执行粒度） */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,EXEC_ID               BIGINT         NOT NULL    /* 执行记录ID */
,JOB_ID                VARCHAR(256)   NOT NULL    /* 任务ID */
,TRACE_ID              VARCHAR(256)               /* trace_id */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：push_plan/push_other */
,SUC_FLAG              INTEGER                    /* 执行成功标记：status=success 且 async_status=success */
,READ_FLAG             INTEGER                    /* 已读标记：is_read=1 */
,JOB_STATUS            VARCHAR(64)                /* 任务当前状态 */
,EXEC_CM_ID            VARCHAR(256)               /* 执行人，取执行表 tenant_id */
,EXEC_IN_ROSTER        INTEGER                    /* 执行人是否在名单内 */
,EXEC_FRS_BBK_ORG_ID   VARCHAR(200)               /* 执行人一级分行号 */
,EXEC_BRN_ORG_ID       VARCHAR(100)               /* 执行人网点号 */
,OWNER_CM_ID           VARCHAR(256)               /* 任务归属人 */
,OWNER_IN_ROSTER       INTEGER                    /* 任务归属人是否在名单内 */
,OWNER_FRS_BBK_ORG_ID  VARCHAR(200)               /* 任务归属人一级分行号 */
,OWNER_BRN_ORG_ID      VARCHAR(100)               /* 任务归属人网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, JOB_ID)
;
insert into TF_PUSH_EXEC
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,EXEC_ID               /* 执行记录ID */
  ,JOB_ID                /* 任务ID */
  ,TRACE_ID              /* trace_id */
  ,JOB_TYPE              /* 任务类型 */
  ,SUC_FLAG              /* 执行成功标记 */
  ,READ_FLAG             /* 已读标记 */
  ,JOB_STATUS            /* 任务当前状态 */
  ,EXEC_CM_ID            /* 执行人 */
  ,EXEC_IN_ROSTER        /* 执行人是否在名单内 */
  ,EXEC_FRS_BBK_ORG_ID   /* 执行人一级分行号 */
  ,EXEC_BRN_ORG_ID       /* 执行人网点号 */
  ,OWNER_CM_ID           /* 任务归属人 */
  ,OWNER_IN_ROSTER       /* 任务归属人是否在名单内 */
  ,OWNER_FRS_BBK_ORG_ID  /* 任务归属人一级分行号 */
  ,OWNER_BRN_ORG_ID      /* 任务归属人网点号 */
)
select
  CAL.REPLAY_SEQ as REPLAY_SEQ                                        /* 重跑序号 */
  ,J.SOURCE_ID as SOURCE_ID                                           /* 来源标识 */
  ,E.ID as EXEC_ID                                                    /* 执行记录ID */
  ,J.JOB_ID as JOB_ID                                                 /* 任务ID */
  ,E.TRACE_ID as TRACE_ID                                             /* trace_id */
  ,case when TS.TRACE_ID is not null then 'push_plan' else 'push_other' end as JOB_TYPE    /* 任务类型 */
  ,case when lower(E.STATUS) = 'success' and lower(E.ASYNC_STATUS) = 'success' then 1 else 0 end as SUC_FLAG    /* 执行成功标记 */
  ,case when E.IS_READ = 1 then 1 else 0 end as READ_FLAG             /* 已读标记 */
  ,J.JOB_STATUS as JOB_STATUS                                        /* 任务当前状态 */
  ,E.TENANT_ID as EXEC_CM_ID                                         /* 执行人 */
  ,case when R.CM_ID is not null then 1 else 0 end as EXEC_IN_ROSTER  /* 执行人是否在名单内 */
  ,coalesce(R.FRS_BBK_ORG_ID, '') as EXEC_FRS_BBK_ORG_ID             /* 执行人一级分行号 */
  ,coalesce(R.BRN_ORG_ID, '') as EXEC_BRN_ORG_ID                     /* 执行人网点号 */
  ,J.OWNER_CM_ID as OWNER_CM_ID                                      /* 任务归属人 */
  ,case when R2.CM_ID is not null then 1 else 0 end as OWNER_IN_ROSTER    /* 任务归属人是否在名单内 */
  ,coalesce(R2.FRS_BBK_ORG_ID, '') as OWNER_FRS_BBK_ORG_ID          /* 任务归属人一级分行号 */
  ,coalesce(R2.BRN_ORG_ID, '') as OWNER_BRN_ORG_ID                  /* 任务归属人网点号 */
from ${NDS_DATA}.NLQ13_SWE_CRON_EXECUTIONS as E    /* 定时任务执行记录 */
inner join TF_PUSH_JOB as J    /* 合规推送任务 */
        on J.JOB_ID = E.JOB_ID
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on E.ACTUAL_TIME >= CAST(CAL.MTH_START_DT AS TIMESTAMP)
       and E.ACTUAL_TIME <  CAST(CAL.NEXT_DT AS TIMESTAMP)
left join TF_TRACE_SUB as TS    /* 存在子任务的 trace */
       on TS.TRACE_ID = E.TRACE_ID
left join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照（执行人） */
       on R.CM_ID = E.TENANT_ID
left join TF_JKH_ROSTER as R2   /* 金葵花客户经理名单快照（任务归属人） */
       on R2.CM_ID = J.OWNER_CM_ID
where (TS.TRACE_ID is not null
       or (lower(E.STATUS) = 'success' and lower(E.ASYNC_STATUS) = 'success'))
;


-- -----------------------------------------------------------------------------
-- 2.7 推送任务集合（执行 × 统计技能）：技能数、技能明细、点击技能归属共用
-- -----------------------------------------------------------------------------
drop table if exists TF_PUSH_EXEC_SKILL;
create temporary table TF_PUSH_EXEC_SKILL    /* 推送任务集合（执行×统计技能） */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,EXEC_ID               BIGINT         NOT NULL    /* 执行记录ID */
,JOB_ID                VARCHAR(256)   NOT NULL    /* 任务ID */
,TRACE_ID              VARCHAR(256)               /* trace_id */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* 任务绑定的统计技能ID */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：push_plan/push_other */
,SUC_FLAG              INTEGER                    /* 执行成功标记 */
,READ_FLAG             INTEGER                    /* 已读标记 */
,JOB_STATUS            VARCHAR(64)                /* 任务当前状态 */
,EXEC_CM_ID            VARCHAR(256)               /* 执行人 */
,EXEC_IN_ROSTER        INTEGER                    /* 执行人是否在名单内 */
,EXEC_FRS_BBK_ORG_ID   VARCHAR(200)               /* 执行人一级分行号 */
,EXEC_BRN_ORG_ID       VARCHAR(100)               /* 执行人网点号 */
,OWNER_CM_ID           VARCHAR(256)               /* 任务归属人 */
,OWNER_IN_ROSTER       INTEGER                    /* 任务归属人是否在名单内 */
,OWNER_FRS_BBK_ORG_ID  VARCHAR(200)               /* 任务归属人一级分行号 */
,OWNER_BRN_ORG_ID      VARCHAR(100)               /* 任务归属人网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, JOB_ID)
;
insert into TF_PUSH_EXEC_SKILL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,EXEC_ID               /* 执行记录ID */
  ,JOB_ID                /* 任务ID */
  ,TRACE_ID              /* trace_id */
  ,SKILL_ID              /* 任务绑定的统计技能ID */
  ,JOB_TYPE              /* 任务类型 */
  ,SUC_FLAG              /* 执行成功标记 */
  ,READ_FLAG             /* 已读标记 */
  ,JOB_STATUS            /* 任务当前状态 */
  ,EXEC_CM_ID            /* 执行人 */
  ,EXEC_IN_ROSTER        /* 执行人是否在名单内 */
  ,EXEC_FRS_BBK_ORG_ID   /* 执行人一级分行号 */
  ,EXEC_BRN_ORG_ID       /* 执行人网点号 */
  ,OWNER_CM_ID           /* 任务归属人 */
  ,OWNER_IN_ROSTER       /* 任务归属人是否在名单内 */
  ,OWNER_FRS_BBK_ORG_ID  /* 任务归属人一级分行号 */
  ,OWNER_BRN_ORG_ID      /* 任务归属人网点号 */
)
select
  E.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,E.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,E.EXEC_ID as EXEC_ID                             /* 执行记录ID */
  ,E.JOB_ID as JOB_ID                               /* 任务ID */
  ,E.TRACE_ID as TRACE_ID                           /* trace_id */
  ,JS.SKILL_ID as SKILL_ID                          /* 任务绑定的统计技能ID */
  ,E.JOB_TYPE as JOB_TYPE                           /* 任务类型 */
  ,E.SUC_FLAG as SUC_FLAG                           /* 执行成功标记 */
  ,E.READ_FLAG as READ_FLAG                         /* 已读标记 */
  ,E.JOB_STATUS as JOB_STATUS                       /* 任务当前状态 */
  ,E.EXEC_CM_ID as EXEC_CM_ID                       /* 执行人 */
  ,E.EXEC_IN_ROSTER as EXEC_IN_ROSTER               /* 执行人是否在名单内 */
  ,E.EXEC_FRS_BBK_ORG_ID as EXEC_FRS_BBK_ORG_ID     /* 执行人一级分行号 */
  ,E.EXEC_BRN_ORG_ID as EXEC_BRN_ORG_ID             /* 执行人网点号 */
  ,E.OWNER_CM_ID as OWNER_CM_ID                     /* 任务归属人 */
  ,E.OWNER_IN_ROSTER as OWNER_IN_ROSTER             /* 任务归属人是否在名单内 */
  ,E.OWNER_FRS_BBK_ORG_ID as OWNER_FRS_BBK_ORG_ID   /* 任务归属人一级分行号 */
  ,E.OWNER_BRN_ORG_ID as OWNER_BRN_ORG_ID           /* 任务归属人网点号 */
from TF_PUSH_EXEC as E    /* 推送任务集合（执行粒度） */
inner join TF_PUSH_JOB_SKILL as JS    /* 推送任务×统计技能 */
        on JS.JOB_ID = E.JOB_ID
       and JS.SOURCE_ID = E.SOURCE_ID
;


-- -----------------------------------------------------------------------------
-- 2.8 推送方案客户（执行 × 技能 × 客户）：接口 push_customers，只取 push_plan
-- -----------------------------------------------------------------------------
drop table if exists TF_PUSH_CUST;
create temporary table TF_PUSH_CUST    /* 推送方案客户（执行×技能×客户） */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：push_plan */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* 技能ID */
,CUSTUID               VARCHAR(256)   NOT NULL    /* 任务中客户UID */
,EXEC_CM_ID            VARCHAR(256)               /* 执行人 */
,EXEC_FRS_BBK_ORG_ID   VARCHAR(200)               /* 执行人一级分行号 */
,EXEC_BRN_ORG_ID       VARCHAR(100)               /* 执行人网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, EXEC_FRS_BBK_ORG_ID, EXEC_BRN_ORG_ID, EXEC_CM_ID)
;
insert into TF_PUSH_CUST
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_ID              /* 技能ID */
  ,CUSTUID               /* 任务中客户UID */
  ,EXEC_CM_ID            /* 执行人 */
  ,EXEC_FRS_BBK_ORG_ID   /* 执行人一级分行号 */
  ,EXEC_BRN_ORG_ID       /* 执行人网点号 */
)
select distinct
  E.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,E.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,E.JOB_TYPE as JOB_TYPE                           /* 任务类型 */
  ,E.SKILL_ID as SKILL_ID                           /* 技能ID */
  ,S.CUSTUID as CUSTUID                             /* 任务中客户UID */
  ,E.EXEC_CM_ID as EXEC_CM_ID                       /* 执行人 */
  ,E.EXEC_FRS_BBK_ORG_ID as EXEC_FRS_BBK_ORG_ID     /* 执行人一级分行号 */
  ,E.EXEC_BRN_ORG_ID as EXEC_BRN_ORG_ID             /* 执行人网点号 */
from TF_PUSH_EXEC_SKILL as E    /* 推送任务集合（执行×统计技能） */
inner join TF_SUBTASK_CUST as S    /* 子任务里的方案客户 */
        on S.TRACE_ID = E.TRACE_ID
where E.JOB_TYPE = 'push_plan'
;


-- -----------------------------------------------------------------------------
-- 2.9 合格主动提问 Span（接口 ask_qualifier，不限制时间）
--     条件：trace 非空、技能非空、有同 trace 子任务、历史执行里不存在同 trace 的执行；
--     同时带上提问人名单信息与“技能是否在统计目录内”标记。
--     不加时间窗是因为接口的主动点击关联也不限制 Span 生成时间，时间窗在 2.10 再收窄。
-- -----------------------------------------------------------------------------
drop table if exists TF_ASK_SPAN;
create temporary table TF_ASK_SPAN    /* 合格主动提问 Span（不含时间窗） */
(
 SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,TRACE_ID              VARCHAR(256)   NOT NULL    /* trace_id */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* Span技能ID */
,CM_ID                 VARCHAR(256)               /* 提问人 */
,START_TIME            TIMESTAMP                  /* Span开始时间 */
,IN_STAT_CATALOG       INTEGER                    /* 技能是否在统计目录内：1=在目录 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, TRACE_ID)
;
insert into TF_ASK_SPAN
(
   SOURCE_ID             /* 来源标识 */
  ,TRACE_ID              /* trace_id */
  ,SKILL_ID              /* Span技能ID */
  ,CM_ID                 /* 提问人 */
  ,START_TIME            /* Span开始时间 */
  ,IN_STAT_CATALOG       /* 技能是否在统计目录内 */
  ,FRS_BBK_ORG_ID        /* 一级分行号 */
  ,BRN_ORG_ID            /* 网点号 */
)
select distinct
  SP.SOURCE_ID as SOURCE_ID         /* 来源标识 */
  ,SP.TRACE_ID as TRACE_ID          /* trace_id */
  ,trim(SP.SKILL_ID) as SKILL_ID    /* Span技能ID */
  ,SP.USER_ID as CM_ID              /* 提问人 */
  ,SP.START_TIME as START_TIME      /* Span开始时间 */
  ,case when K.SKILL_ID is not null then 1 else 0 end as IN_STAT_CATALOG    /* 技能是否在统计目录内 */
  ,coalesce(R.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    /* 一级分行号 */
  ,coalesce(R.BRN_ORG_ID, '') as BRN_ORG_ID            /* 网点号 */
from ${NDS_DATA}.NLQ13_SWE_TRACING_SPANS as SP    /* 追踪 Span（主动提问） */
inner join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照 */
        on R.CM_ID = SP.USER_ID
inner join TF_TRACE_SUB as TS    /* 存在子任务的 trace */
        on TS.TRACE_ID = SP.TRACE_ID
left join TF_TRACE_EXEC as TE    /* 存在执行记录的 trace */
       on TE.TRACE_ID = SP.TRACE_ID
left join TF_SKILL_CATALOG as K    /* 技能目录（纳入统计的市场技能） */
       on K.SOURCE_ID = SP.SOURCE_ID
      and K.SKILL_ID = trim(SP.SKILL_ID)
where SP.TRACE_ID <> ''
  and SP.SKILL_ID is not null
  and trim(SP.SKILL_ID) <> ''
  and TE.TRACE_ID is null
;


-- -----------------------------------------------------------------------------
-- 2.10 统计区间内的主动提问（Span × 技能）：接口 ask 子查询
--      重跑：关联第 1.0 段日历，取「当月 1 号 ~ 重跑日」，每个重跑日各出一份
-- -----------------------------------------------------------------------------
drop table if exists TF_ASK_TRACE;
create temporary table TF_ASK_TRACE    /* 主动提问任务（Span×技能） */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：ask_plan */
,TRACE_ID              VARCHAR(256)   NOT NULL    /* trace_id */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* Span技能ID */
,CM_ID                 VARCHAR(256)               /* 提问人 */
,IN_STAT_CATALOG       INTEGER                    /* 技能是否在统计目录内 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, TRACE_ID)
;
insert into TF_ASK_TRACE
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,JOB_TYPE              /* 任务类型 */
  ,TRACE_ID              /* trace_id */
  ,SKILL_ID              /* Span技能ID */
  ,CM_ID                 /* 提问人 */
  ,IN_STAT_CATALOG       /* 技能是否在统计目录内 */
  ,FRS_BBK_ORG_ID        /* 一级分行号 */
  ,BRN_ORG_ID            /* 网点号 */
)
select distinct
  CAL.REPLAY_SEQ as REPLAY_SEQ      /* 重跑序号 */
  ,A.SOURCE_ID as SOURCE_ID         /* 来源标识 */
  ,'ask_plan' as JOB_TYPE           /* 任务类型 */
  ,A.TRACE_ID as TRACE_ID           /* trace_id */
  ,A.SKILL_ID as SKILL_ID           /* Span技能ID */
  ,A.CM_ID as CM_ID                 /* 提问人 */
  ,A.IN_STAT_CATALOG as IN_STAT_CATALOG    /* 技能是否在统计目录内 */
  ,A.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID      /* 一级分行号 */
  ,A.BRN_ORG_ID as BRN_ORG_ID              /* 网点号 */
from TF_ASK_SPAN as A    /* 合格主动提问 Span */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on A.START_TIME >= CAST(CAL.MTH_START_DT AS TIMESTAMP)
       and A.START_TIME <  CAST(CAL.NEXT_DT AS TIMESTAMP)
;


-- -----------------------------------------------------------------------------
-- 2.11 主动提问方案客户（Span × 技能 × 客户）：接口 ask_customers
-- -----------------------------------------------------------------------------
drop table if exists TF_ASK_CUST;
create temporary table TF_ASK_CUST    /* 主动提问方案客户（Span×技能×客户） */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：ask_plan */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* 技能ID */
,CUSTUID               VARCHAR(256)   NOT NULL    /* 任务中客户UID */
,CM_ID                 VARCHAR(256)               /* 提问人 */
,IN_STAT_CATALOG       INTEGER                    /* 技能是否在统计目录内 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, FRS_BBK_ORG_ID, BRN_ORG_ID, CM_ID)
;
insert into TF_ASK_CUST
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_ID              /* 技能ID */
  ,CUSTUID               /* 任务中客户UID */
  ,CM_ID                 /* 提问人 */
  ,IN_STAT_CATALOG       /* 技能是否在统计目录内 */
  ,FRS_BBK_ORG_ID        /* 一级分行号 */
  ,BRN_ORG_ID            /* 网点号 */
)
select distinct
  A.REPLAY_SEQ as REPLAY_SEQ        /* 重跑序号 */
  ,A.SOURCE_ID as SOURCE_ID         /* 来源标识 */
  ,A.JOB_TYPE as JOB_TYPE           /* 任务类型 */
  ,A.SKILL_ID as SKILL_ID           /* 技能ID */
  ,S.CUSTUID as CUSTUID             /* 任务中客户UID */
  ,A.CM_ID as CM_ID                 /* 提问人 */
  ,A.IN_STAT_CATALOG as IN_STAT_CATALOG    /* 技能是否在统计目录内 */
  ,A.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID      /* 一级分行号 */
  ,A.BRN_ORG_ID as BRN_ORG_ID              /* 网点号 */
from TF_ASK_TRACE as A    /* 主动提问任务（Span×技能） */
inner join TF_SUBTASK_CUST as S    /* 子任务里的方案客户 */
        on S.TRACE_ID = A.TRACE_ID
;


-- -----------------------------------------------------------------------------
-- 2.12 客户点击基础集合：接口 click_rows 的过滤部分
--     过滤：点击时间在「当月 1 号 ~ 跑数日期」、点击人在名单内、customer_id 与 trace_id 非空，
--           且属于「preview_view + sub」或「button_click + insight/phone」
--     重跑：关联第 1.0 段日历取当月 1 号，点击窗口统一截到跑数日期（推送后 7 天到达的点击
--           回算到推送当天所在分区），每个重跑日各带一份点击集合（带 REPLAY_SEQ）
-- -----------------------------------------------------------------------------
drop table if exists TF_CLICK_EVENT;
create temporary table TF_CLICK_EVENT    /* 客户点击基础集合 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,EVENT_ID              BIGINT         NOT NULL    /* 点击事件主键ID */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,CM_ID                 VARCHAR(256)               /* 点击人 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 点击人一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 点击人网点号 */
,TRACE_ID              VARCHAR(256)               /* trace_id */
,CRON_TASK_ID          VARCHAR(512)               /* 定时任务ID */
,CUSTOMER_ID           VARCHAR(512)               /* 客户唯一标识 */
,EVENT_TYPE            VARCHAR(128)               /* 事件类型：button_click/preview_view */
,TEMPLATE_TYPE         VARCHAR(64)                /* 模板类型：main/sub */
,BUTTON_TYPE           VARCHAR(128)               /* 按钮类型：insight/phone/other */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, TRACE_ID)
;
insert into TF_CLICK_EVENT
(
   REPLAY_SEQ            /* 重跑序号 */
  ,EVENT_ID              /* 点击事件主键ID */
  ,SOURCE_ID             /* 来源标识 */
  ,CM_ID                 /* 点击人 */
  ,FRS_BBK_ORG_ID        /* 点击人一级分行号 */
  ,BRN_ORG_ID            /* 点击人网点号 */
  ,TRACE_ID              /* trace_id */
  ,CRON_TASK_ID          /* 定时任务ID */
  ,CUSTOMER_ID           /* 客户唯一标识 */
  ,EVENT_TYPE            /* 事件类型 */
  ,TEMPLATE_TYPE         /* 模板类型 */
  ,BUTTON_TYPE           /* 按钮类型 */
)
select
  CAL.REPLAY_SEQ as REPLAY_SEQ                      /* 重跑序号 */
  ,C.ID as EVENT_ID                                 /* 点击事件主键ID */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,C.USER_ID as CM_ID                               /* 点击人 */
  ,coalesce(R.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    /* 点击人一级分行号 */
  ,coalesce(R.BRN_ORG_ID, '') as BRN_ORG_ID            /* 点击人网点号 */
  ,C.TRACE_ID as TRACE_ID                           /* trace_id */
  ,C.CRON_TASK_ID as CRON_TASK_ID                   /* 定时任务ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
from ${NDS_DATA}.NLQ13_SWE_HTML_PREVIEW_CLICK_EVENTS as C    /* 客户点击事件 */
inner join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照（点击人） */
        on R.CM_ID = C.USER_ID
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on C.CLICKED_AT >= CAST(CAL.MTH_START_DT AS TIMESTAMP)
       and C.CLICKED_AT <  CAST(CAST('${v_Trx_Dt}' AS DATE) + 1 AS TIMESTAMP)
where C.TRACE_ID is not null
  and C.TRACE_ID <> ''
  and C.CUSTOMER_ID is not null
  and C.CUSTOMER_ID <> ''
  and (
        (lower(C.EVENT_TYPE) = 'preview_view' and lower(C.TEMPLATE_TYPE) = 'sub')
        or (lower(C.EVENT_TYPE) = 'button_click' and lower(C.BUTTON_TYPE) in ('insight', 'phone'))
      )
;


-- -----------------------------------------------------------------------------
-- 2.13 推送类点击（接口 click_push）
--     条件：点击的 trace 有执行记录、执行所属任务就是点击带的任务ID、任务合规（未删除
--           且绑定统计技能）、且同 trace 有子任务
-- -----------------------------------------------------------------------------
drop table if exists TF_CLICK_PUSH;
create temporary table TF_CLICK_PUSH    /* 推送类点击 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,EVENT_ID              BIGINT         NOT NULL    /* 点击事件主键ID */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,CM_ID                 VARCHAR(256)               /* 点击人 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 点击人一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 点击人网点号 */
,TRACE_ID              VARCHAR(256)               /* trace_id */
,CRON_TASK_ID          VARCHAR(512)               /* 定时任务ID */
,CUSTOMER_ID           VARCHAR(512)               /* 客户唯一标识 */
,EVENT_TYPE            VARCHAR(128)               /* 事件类型 */
,TEMPLATE_TYPE         VARCHAR(64)                /* 模板类型 */
,BUTTON_TYPE           VARCHAR(128)               /* 按钮类型 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, TRACE_ID)
;
insert into TF_CLICK_PUSH
(
   REPLAY_SEQ            /* 重跑序号 */
  ,EVENT_ID              /* 点击事件主键ID */
  ,SOURCE_ID             /* 来源标识 */
  ,CM_ID                 /* 点击人 */
  ,FRS_BBK_ORG_ID        /* 点击人一级分行号 */
  ,BRN_ORG_ID            /* 点击人网点号 */
  ,TRACE_ID              /* trace_id */
  ,CRON_TASK_ID          /* 定时任务ID */
  ,CUSTOMER_ID           /* 客户唯一标识 */
  ,EVENT_TYPE            /* 事件类型 */
  ,TEMPLATE_TYPE         /* 模板类型 */
  ,BUTTON_TYPE           /* 按钮类型 */
)
select distinct
  C.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,C.EVENT_ID as EVENT_ID                           /* 点击事件主键ID */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,C.CM_ID as CM_ID                                 /* 点击人 */
  ,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID               /* 点击人一级分行号 */
  ,C.BRN_ORG_ID as BRN_ORG_ID                       /* 点击人网点号 */
  ,C.TRACE_ID as TRACE_ID                           /* trace_id */
  ,C.CRON_TASK_ID as CRON_TASK_ID                   /* 定时任务ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
from TF_CLICK_EVENT as C    /* 客户点击基础集合 */
inner join ${NDS_DATA}.NLQ13_SWE_CRON_EXECUTIONS as E    /* 定时任务执行记录 */
        on E.TRACE_ID = C.TRACE_ID
inner join TF_PUSH_JOB as J    /* 合规推送任务 */
        on J.JOB_ID = E.JOB_ID
       and J.JOB_ID = C.CRON_TASK_ID
       and J.SOURCE_ID = C.SOURCE_ID
inner join TF_TRACE_SUB as TS    /* 存在子任务的 trace */
        on TS.TRACE_ID = C.TRACE_ID
;


-- -----------------------------------------------------------------------------
-- 2.14 推送类点击的事件ID（用于把同一事件从主动类型里排除，两类互斥）
--      同一事件的任务类型归属与重跑日无关，因此只按 EVENT_ID 去重即可
-- -----------------------------------------------------------------------------
drop table if exists TF_CLICK_PUSH_KEY;
create temporary table TF_CLICK_PUSH_KEY    /* 推送类点击事件ID */
(
 EVENT_ID              BIGINT         NOT NULL    /* 点击事件主键ID */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_CLICK_PUSH_KEY
(
   EVENT_ID              /* 点击事件主键ID */
)
select distinct
  C.EVENT_ID as EVENT_ID        /* 点击事件主键ID */
from TF_CLICK_PUSH as C    /* 推送类点击 */
;


-- -----------------------------------------------------------------------------
-- 2.15 主动类点击（接口 click_ask）
--     条件：点击的 source + trace 命中合格主动提问 Span，且该 Span 技能在统计目录内
-- -----------------------------------------------------------------------------
drop table if exists TF_CLICK_ASK;
create temporary table TF_CLICK_ASK    /* 主动类点击 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,EVENT_ID              BIGINT         NOT NULL    /* 点击事件主键ID */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,CM_ID                 VARCHAR(256)               /* 点击人 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 点击人一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 点击人网点号 */
,TRACE_ID              VARCHAR(256)               /* trace_id */
,CRON_TASK_ID          VARCHAR(512)               /* 定时任务ID */
,CUSTOMER_ID           VARCHAR(512)               /* 客户唯一标识 */
,EVENT_TYPE            VARCHAR(128)               /* 事件类型 */
,TEMPLATE_TYPE         VARCHAR(64)                /* 模板类型 */
,BUTTON_TYPE           VARCHAR(128)               /* 按钮类型 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, TRACE_ID)
;
insert into TF_CLICK_ASK
(
   REPLAY_SEQ            /* 重跑序号 */
  ,EVENT_ID              /* 点击事件主键ID */
  ,SOURCE_ID             /* 来源标识 */
  ,CM_ID                 /* 点击人 */
  ,FRS_BBK_ORG_ID        /* 点击人一级分行号 */
  ,BRN_ORG_ID            /* 点击人网点号 */
  ,TRACE_ID              /* trace_id */
  ,CRON_TASK_ID          /* 定时任务ID */
  ,CUSTOMER_ID           /* 客户唯一标识 */
  ,EVENT_TYPE            /* 事件类型 */
  ,TEMPLATE_TYPE         /* 模板类型 */
  ,BUTTON_TYPE           /* 按钮类型 */
)
select distinct
  C.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,C.EVENT_ID as EVENT_ID                           /* 点击事件主键ID */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,C.CM_ID as CM_ID                                 /* 点击人 */
  ,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID               /* 点击人一级分行号 */
  ,C.BRN_ORG_ID as BRN_ORG_ID                       /* 点击人网点号 */
  ,C.TRACE_ID as TRACE_ID                           /* trace_id */
  ,C.CRON_TASK_ID as CRON_TASK_ID                   /* 定时任务ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
from TF_CLICK_EVENT as C    /* 客户点击基础集合 */
inner join TF_ASK_SPAN as A    /* 合格主动提问 Span */
        on A.SOURCE_ID = C.SOURCE_ID
       and A.TRACE_ID = C.TRACE_ID
       and A.IN_STAT_CATALOG = 1
;


-- -----------------------------------------------------------------------------
-- 2.16 点击事件的任务类型归属
--     能回溯到推送任务的是 push_plan；否则命中合格主动提问 Span 的是 ask_plan；
--     两类都不满足的点击不进统计（推送类优先，与接口 CASE WHEN click_push 一致）
-- -----------------------------------------------------------------------------
drop table if exists TF_CLICK_CLS;
create temporary table TF_CLICK_CLS    /* 点击事件（已判定任务类型） */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,EVENT_ID              BIGINT         NOT NULL    /* 点击事件主键ID */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：push_plan/ask_plan */
,CM_ID                 VARCHAR(256)               /* 点击人 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 点击人一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 点击人网点号 */
,TRACE_ID              VARCHAR(256)               /* trace_id */
,CRON_TASK_ID          VARCHAR(512)               /* 定时任务ID */
,CUSTOMER_ID           VARCHAR(512)               /* 客户唯一标识 */
,EVENT_TYPE            VARCHAR(128)               /* 事件类型 */
,TEMPLATE_TYPE         VARCHAR(64)                /* 模板类型 */
,BUTTON_TYPE           VARCHAR(128)               /* 按钮类型 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, TRACE_ID)
;
insert into TF_CLICK_CLS
(
   REPLAY_SEQ            /* 重跑序号 */
  ,EVENT_ID              /* 点击事件主键ID */
  ,SOURCE_ID             /* 来源标识 */
  ,JOB_TYPE              /* 任务类型 */
  ,CM_ID                 /* 点击人 */
  ,FRS_BBK_ORG_ID        /* 点击人一级分行号 */
  ,BRN_ORG_ID            /* 点击人网点号 */
  ,TRACE_ID              /* trace_id */
  ,CRON_TASK_ID          /* 定时任务ID */
  ,CUSTOMER_ID           /* 客户唯一标识 */
  ,EVENT_TYPE            /* 事件类型 */
  ,TEMPLATE_TYPE         /* 模板类型 */
  ,BUTTON_TYPE           /* 按钮类型 */
)
select
  C.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,C.EVENT_ID as EVENT_ID                           /* 点击事件主键ID */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,'push_plan' as JOB_TYPE                          /* 任务类型 */
  ,C.CM_ID as CM_ID                                 /* 点击人 */
  ,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID               /* 点击人一级分行号 */
  ,C.BRN_ORG_ID as BRN_ORG_ID                       /* 点击人网点号 */
  ,C.TRACE_ID as TRACE_ID                           /* trace_id */
  ,C.CRON_TASK_ID as CRON_TASK_ID                   /* 定时任务ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
from TF_CLICK_PUSH as C    /* 推送类点击 */
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,C.EVENT_ID as EVENT_ID                           /* 点击事件主键ID */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,'ask_plan' as JOB_TYPE                           /* 任务类型 */
  ,C.CM_ID as CM_ID                                 /* 点击人 */
  ,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID               /* 点击人一级分行号 */
  ,C.BRN_ORG_ID as BRN_ORG_ID                       /* 点击人网点号 */
  ,C.TRACE_ID as TRACE_ID                           /* trace_id */
  ,C.CRON_TASK_ID as CRON_TASK_ID                   /* 定时任务ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
from TF_CLICK_ASK as C    /* 主动类点击 */
left join TF_CLICK_PUSH_KEY as PK    /* 推送类点击事件ID */
       on PK.EVENT_ID = C.EVENT_ID
where PK.EVENT_ID is null
;


-- -----------------------------------------------------------------------------
-- 2.17 点击事件 × 关联技能：接口 clicks 的技能关联
--     推送点击的技能取自关联任务的统计技能；主动点击的技能取自同 source + trace 的合格
--     Span 技能；同一事件关联多个技能时分别进入各技能行（明细不可相加）
-- -----------------------------------------------------------------------------
drop table if exists TF_CLICK_SKILL;
create temporary table TF_CLICK_SKILL    /* 点击事件×关联技能 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型：push_plan/ask_plan */
,SKILL_ID              VARCHAR(512)   NOT NULL    /* 技能ID */
,EVENT_ID              BIGINT         NOT NULL    /* 点击事件主键ID */
,CUSTOMER_ID           VARCHAR(512)               /* 客户唯一标识 */
,EVENT_TYPE            VARCHAR(128)               /* 事件类型 */
,TEMPLATE_TYPE         VARCHAR(64)                /* 模板类型 */
,BUTTON_TYPE           VARCHAR(128)               /* 按钮类型 */
,CM_ID                 VARCHAR(256)               /* 点击人 */
,FRS_BBK_ORG_ID        VARCHAR(200)               /* 点击人一级分行号 */
,BRN_ORG_ID            VARCHAR(100)               /* 点击人网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, SKILL_ID)
;
insert into TF_CLICK_SKILL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_ID              /* 技能ID */
  ,EVENT_ID              /* 点击事件主键ID */
  ,CUSTOMER_ID           /* 客户唯一标识 */
  ,EVENT_TYPE            /* 事件类型 */
  ,TEMPLATE_TYPE         /* 模板类型 */
  ,BUTTON_TYPE           /* 按钮类型 */
  ,CM_ID                 /* 点击人 */
  ,FRS_BBK_ORG_ID        /* 点击人一级分行号 */
  ,BRN_ORG_ID            /* 点击人网点号 */
)
select distinct
  C.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,C.JOB_TYPE as JOB_TYPE                           /* 任务类型 */
  ,J.SKILL_ID as SKILL_ID                           /* 技能ID */
  ,C.EVENT_ID as EVENT_ID                           /* 点击事件主键ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
  ,C.CM_ID as CM_ID                                 /* 点击人 */
  ,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID               /* 点击人一级分行号 */
  ,C.BRN_ORG_ID as BRN_ORG_ID                       /* 点击人网点号 */
from TF_CLICK_CLS as C    /* 点击事件（已判定任务类型） */
inner join TF_PUSH_JOB_SKILL as J    /* 推送任务×统计技能 */
        on J.JOB_ID = C.CRON_TASK_ID
       and J.SOURCE_ID = C.SOURCE_ID
where C.JOB_TYPE = 'push_plan'
union all
select distinct
  C.REPLAY_SEQ as REPLAY_SEQ                        /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                         /* 来源标识 */
  ,C.JOB_TYPE as JOB_TYPE                           /* 任务类型 */
  ,A.SKILL_ID as SKILL_ID                           /* 技能ID */
  ,C.EVENT_ID as EVENT_ID                           /* 点击事件主键ID */
  ,C.CUSTOMER_ID as CUSTOMER_ID                     /* 客户唯一标识 */
  ,C.EVENT_TYPE as EVENT_TYPE                       /* 事件类型 */
  ,C.TEMPLATE_TYPE as TEMPLATE_TYPE                 /* 模板类型 */
  ,C.BUTTON_TYPE as BUTTON_TYPE                     /* 按钮类型 */
  ,C.CM_ID as CM_ID                                 /* 点击人 */
  ,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID               /* 点击人一级分行号 */
  ,C.BRN_ORG_ID as BRN_ORG_ID                       /* 点击人网点号 */
from TF_CLICK_CLS as C    /* 点击事件（已判定任务类型） */
inner join TF_ASK_SPAN as A    /* 合格主动提问 Span */
        on A.SOURCE_ID = C.SOURCE_ID
       and A.TRACE_ID = C.TRACE_ID
       and A.IN_STAT_CATALOG = 1
where C.JOB_TYPE = 'ask_plan'
;


-- =============================================================================
-- 3. 指标长表（维度键 + 指标名 + 计数键）
--    每个指标一行压成“该指标被计数的集合”，下游按任意维度组合 count(distinct 计数键)
--    即可还原指标，因此同一份事实可以同时支撑分行、支行、客户经理与技能明细，
--    不会出现 DISTINCT 跨组相加。
--    REPLAY_SEQ：该行属于哪个重跑日（见第 1.0 段日历），宽表与落数都按它分组。
--    SKILL_IN_CATALOG：该行的技能是否在统计目录内，用于技能明细骨架收窄。
--    ACTIVE_MANAGER_CNT：活跃客户经理数，按推送执行集合中任务归属人去重（总体/分行/支行
--    维度使用，客户经理维度的宽表把它置 NULL）。
--    ACTIVE_JOB_CNT / PAUSED_JOB_CNT：当前活跃/暂停任务数，任务粒度，只按
--    NLQ13_SWE_CRON_JOBS.STATUS 的当前值（active / paused）取数，不设统计区间，
--    按任务归属人的机构/经理 + 技能展开；任务本身没有 push_plan/push_other 之分，
--    所以两类推送任务行都给同一个数，主动提问（没有 job）为 NULL。
--    这两条只给客户经理维度用，其它组合的宽表把它们置 NULL、骨架也把它们排除。
-- =============================================================================
drop table if exists TF_METRIC_FACT;
create temporary table TF_METRIC_FACT    /* 任务类型报表指标长表 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)               /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)               /* 网点号 */
,K_CM_ID               VARCHAR(256)               /* 客户经理编号 */
,K_SKILL               VARCHAR(512)               /* 技能ID */
,JOB_TYPE              VARCHAR(64)                /* 任务类型 */
,METRIC_NM             VARCHAR(64)    NOT NULL    /* 指标名 */
,METRIC_KEY            VARCHAR(512)   NOT NULL    /* 该指标的计数键 */
,SKILL_IN_CATALOG      INTEGER                    /* 技能是否在统计目录内：1=在目录 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_FRS_BBK_ORG_ID, K_BRN_ORG_ID, K_CM_ID)
;
insert into TF_METRIC_FACT
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_CM_ID               /* 客户经理编号 */
  ,K_SKILL               /* 技能ID */
  ,JOB_TYPE              /* 任务类型 */
  ,METRIC_NM             /* 指标名 */
  ,METRIC_KEY            /* 计数键 */
  ,SKILL_IN_CATALOG      /* 技能是否在统计目录内 */
)
select
  E.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,E.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,E.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID               /* 一级分行号 */
  ,E.EXEC_BRN_ORG_ID as K_BRN_ORG_ID                       /* 网点号 */
  ,E.EXEC_CM_ID as K_CM_ID                                 /* 客户经理编号 */
  ,E.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,E.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'SKILL_CNT' as METRIC_NM                                /* 技能数 */
  ,E.SKILL_ID as METRIC_KEY                                /* 计数键：技能ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_PUSH_EXEC_SKILL as E    /* 推送任务集合（执行×统计技能） */
where E.EXEC_IN_ROSTER = 1
union all
select
  E.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,E.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,E.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID               /* 一级分行号 */
  ,E.EXEC_BRN_ORG_ID as K_BRN_ORG_ID                       /* 网点号 */
  ,E.EXEC_CM_ID as K_CM_ID                                 /* 客户经理编号 */
  ,E.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,E.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'SUC_EXECUTE_JOB' as METRIC_NM                          /* 成功执行任务数 */
  ,E.EXEC_ID as METRIC_KEY                                 /* 计数键：执行记录ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_PUSH_EXEC_SKILL as E    /* 推送任务集合（执行×统计技能） */
where E.EXEC_IN_ROSTER = 1
  and E.SUC_FLAG = 1
union all
select
  E.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,E.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,E.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID               /* 一级分行号 */
  ,E.EXEC_BRN_ORG_ID as K_BRN_ORG_ID                       /* 网点号 */
  ,E.EXEC_CM_ID as K_CM_ID                                 /* 客户经理编号 */
  ,E.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,E.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'READ_TASKS' as METRIC_NM                               /* 已查看任务数 */
  ,E.EXEC_ID as METRIC_KEY                                 /* 计数键：执行记录ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_PUSH_EXEC_SKILL as E    /* 推送任务集合（执行×统计技能） */
where E.EXEC_IN_ROSTER = 1
  and E.READ_FLAG = 1
union all
select
  E.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,E.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,E.OWNER_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID              /* 一级分行号（任务归属人） */
  ,E.OWNER_BRN_ORG_ID as K_BRN_ORG_ID                      /* 网点号（任务归属人） */
  ,E.OWNER_CM_ID as K_CM_ID                                /* 客户经理编号（任务归属人） */
  ,E.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,E.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'ACTIVE_MANAGER_CNT' as METRIC_NM                       /* 活跃客户经理数 */
  ,E.OWNER_CM_ID as METRIC_KEY                             /* 计数键：任务归属人 */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_PUSH_EXEC_SKILL as E    /* 推送任务集合（执行×统计技能） */
where E.OWNER_IN_ROSTER = 1
  and lower(E.JOB_STATUS) = 'active'
union all
select
  CAL.REPLAY_SEQ as REPLAY_SEQ                              /* 重跑序号 */
  ,J.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                     /* 一级分行号（任务归属人） */
  ,R.BRN_ORG_ID as K_BRN_ORG_ID                             /* 网点号（任务归属人） */
  ,J.OWNER_CM_ID as K_CM_ID                                 /* 客户经理编号（任务归属人） */
  ,J.SKILL_ID as K_SKILL                                    /* 技能ID */
  ,'push_plan' as JOB_TYPE                                  /* 任务类型 */
  ,'ACTIVE_JOB_CNT' as METRIC_NM                            /* 当前活跃任务数 */
  ,J.JOB_ID as METRIC_KEY                                   /* 计数键：任务ID */
  ,1 as SKILL_IN_CATALOG                                    /* 技能在统计目录内 */
from TF_PUSH_JOB_SKILL as J    /* 推送任务×统计技能 */
inner join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照 */
        on R.CM_ID = J.OWNER_CM_ID
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on 1 = 1
where lower(J.JOB_STATUS) = 'active'
union all
select
  CAL.REPLAY_SEQ as REPLAY_SEQ                              /* 重跑序号 */
  ,J.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                     /* 一级分行号（任务归属人） */
  ,R.BRN_ORG_ID as K_BRN_ORG_ID                             /* 网点号（任务归属人） */
  ,J.OWNER_CM_ID as K_CM_ID                                 /* 客户经理编号（任务归属人） */
  ,J.SKILL_ID as K_SKILL                                    /* 技能ID */
  ,'push_other' as JOB_TYPE                                 /* 任务类型 */
  ,'ACTIVE_JOB_CNT' as METRIC_NM                            /* 当前活跃任务数 */
  ,J.JOB_ID as METRIC_KEY                                   /* 计数键：任务ID */
  ,1 as SKILL_IN_CATALOG                                    /* 技能在统计目录内 */
from TF_PUSH_JOB_SKILL as J    /* 推送任务×统计技能 */
inner join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照 */
        on R.CM_ID = J.OWNER_CM_ID
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on 1 = 1
where lower(J.JOB_STATUS) = 'active'
union all
select
  CAL.REPLAY_SEQ as REPLAY_SEQ                              /* 重跑序号 */
  ,J.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                     /* 一级分行号（任务归属人） */
  ,R.BRN_ORG_ID as K_BRN_ORG_ID                             /* 网点号（任务归属人） */
  ,J.OWNER_CM_ID as K_CM_ID                                 /* 客户经理编号（任务归属人） */
  ,J.SKILL_ID as K_SKILL                                    /* 技能ID */
  ,'push_plan' as JOB_TYPE                                  /* 任务类型 */
  ,'PAUSED_JOB_CNT' as METRIC_NM                            /* 当前暂停任务数 */
  ,J.JOB_ID as METRIC_KEY                                   /* 计数键：任务ID */
  ,1 as SKILL_IN_CATALOG                                    /* 技能在统计目录内 */
from TF_PUSH_JOB_SKILL as J    /* 推送任务×统计技能 */
inner join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照 */
        on R.CM_ID = J.OWNER_CM_ID
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on 1 = 1
where lower(J.JOB_STATUS) = 'paused'
union all
select
  CAL.REPLAY_SEQ as REPLAY_SEQ                              /* 重跑序号 */
  ,J.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                     /* 一级分行号（任务归属人） */
  ,R.BRN_ORG_ID as K_BRN_ORG_ID                             /* 网点号（任务归属人） */
  ,J.OWNER_CM_ID as K_CM_ID                                 /* 客户经理编号（任务归属人） */
  ,J.SKILL_ID as K_SKILL                                    /* 技能ID */
  ,'push_other' as JOB_TYPE                                 /* 任务类型 */
  ,'PAUSED_JOB_CNT' as METRIC_NM                            /* 当前暂停任务数 */
  ,J.JOB_ID as METRIC_KEY                                   /* 计数键：任务ID */
  ,1 as SKILL_IN_CATALOG                                    /* 技能在统计目录内 */
from TF_PUSH_JOB_SKILL as J    /* 推送任务×统计技能 */
inner join TF_JKH_ROSTER as R    /* 金葵花客户经理名单快照 */
        on R.CM_ID = J.OWNER_CM_ID
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on 1 = 1
where lower(J.JOB_STATUS) = 'paused'
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,C.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID               /* 一级分行号 */
  ,C.EXEC_BRN_ORG_ID as K_BRN_ORG_ID                       /* 网点号 */
  ,C.EXEC_CM_ID as K_CM_ID                                 /* 客户经理编号 */
  ,C.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,C.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'RECOMMENDED_CUSTOMERS' as METRIC_NM                    /* 方案客户数 */
  ,C.CUSTUID as METRIC_KEY                                 /* 计数键：客户UID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_PUSH_CUST as C    /* 推送方案客户（执行×技能×客户） */
union all
select
  A.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,A.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,A.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,A.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,A.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,A.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'SKILL_CNT' as METRIC_NM                                /* 技能数 */
  ,A.SKILL_ID as METRIC_KEY                                /* 计数键：技能ID */
  ,A.IN_STAT_CATALOG as SKILL_IN_CATALOG                   /* 技能在统计目录内 */
from TF_ASK_TRACE as A    /* 主动提问任务（Span×技能） */
where A.IN_STAT_CATALOG = 1
union all
select
  A.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,A.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,A.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,A.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,A.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,A.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'SUC_EXECUTE_JOB' as METRIC_NM                          /* 成功执行任务数 */
  ,A.TRACE_ID as METRIC_KEY                                /* 计数键：trace_id */
  ,A.IN_STAT_CATALOG as SKILL_IN_CATALOG                   /* 技能在统计目录内 */
from TF_ASK_TRACE as A    /* 主动提问任务（Span×技能） */
union all
select
  A.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,A.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,A.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,A.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,A.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,A.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'READ_TASKS' as METRIC_NM                               /* 已查看任务数（等于成功数） */
  ,A.TRACE_ID as METRIC_KEY                                /* 计数键：trace_id */
  ,A.IN_STAT_CATALOG as SKILL_IN_CATALOG                   /* 技能在统计目录内 */
from TF_ASK_TRACE as A    /* 主动提问任务（Span×技能） */
union all
select
  A.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,A.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,A.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,A.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,A.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,A.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'RECOMMENDED_CUSTOMERS' as METRIC_NM                    /* 方案客户数 */
  ,A.CUSTUID as METRIC_KEY                                 /* 计数键：客户UID */
  ,A.IN_STAT_CATALOG as SKILL_IN_CATALOG                   /* 技能在统计目录内 */
from TF_ASK_CUST as A    /* 主动提问方案客户（Span×技能×客户） */
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,C.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,C.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,C.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,C.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'READ_CUSTOMER_CNT' as METRIC_NM                        /* 已查看方案客户数 */
  ,C.CUSTOMER_ID as METRIC_KEY                             /* 计数键：客户ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_CLICK_SKILL as C    /* 点击事件×关联技能 */
where lower(C.EVENT_TYPE) = 'preview_view'
  and lower(C.TEMPLATE_TYPE) = 'sub'
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,C.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,C.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,C.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,C.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'INSIGHT_CUSTOMER_CNT' as METRIC_NM                     /* 洞察客户数 */
  ,C.CUSTOMER_ID as METRIC_KEY                             /* 计数键：客户ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_CLICK_SKILL as C    /* 点击事件×关联技能 */
where lower(C.EVENT_TYPE) = 'button_click'
  and lower(C.BUTTON_TYPE) = 'insight'
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,C.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,C.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,C.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,C.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'INSIGHT_CNT' as METRIC_NM                              /* 点击客户洞察总次数 */
  ,CAST(C.EVENT_ID AS VARCHAR) as METRIC_KEY               /* 计数键：事件ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_CLICK_SKILL as C    /* 点击事件×关联技能 */
where lower(C.EVENT_TYPE) = 'button_click'
  and lower(C.BUTTON_TYPE) = 'insight'
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,C.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,C.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,C.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,C.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'PHONE_CUSTOMER_CNT' as METRIC_NM                       /* 电访客户数 */
  ,C.CUSTOMER_ID as METRIC_KEY                             /* 计数键：客户ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_CLICK_SKILL as C    /* 点击事件×关联技能 */
where lower(C.EVENT_TYPE) = 'button_click'
  and lower(C.BUTTON_TYPE) = 'phone'
union all
select
  C.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,C.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                    /* 一级分行号 */
  ,C.BRN_ORG_ID as K_BRN_ORG_ID                            /* 网点号 */
  ,C.CM_ID as K_CM_ID                                      /* 客户经理编号 */
  ,C.SKILL_ID as K_SKILL                                   /* 技能ID */
  ,C.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,'PHONE_CNT' as METRIC_NM                                /* 点击去电访总次数 */
  ,CAST(C.EVENT_ID AS VARCHAR) as METRIC_KEY               /* 计数键：事件ID */
  ,1 as SKILL_IN_CATALOG                                   /* 技能在统计目录内 */
from TF_CLICK_SKILL as C    /* 点击事件×关联技能 */
where lower(C.EVENT_TYPE) = 'button_click'
  and lower(C.BUTTON_TYPE) = 'phone'
;


-- =============================================================================
-- 4. 组合骨架（每种报表组合各自的维度对象）
--    汇总组合取所有事实的维度并集（点击、任务归属人的活跃/暂停任务也算事实）；
--    技能明细组合只取任务级事实且技能在统计目录内，(分行,网点,经理,技能) 只保留期间
--    真正有任务的组合，不给纯目录技能、纯点击技能建行。
--    所有骨架都带 REPLAY_SEQ，即每个重跑日各出一套维度对象。
--    客户经理维度才用的 ACTIVE_JOB_CNT / PAUSED_JOB_CNT 在其它组合里要被排除，
--    否则会出现只有任务状态、没有其它事实的全零行。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 总体骨架（group_by=overall）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_OVERALL;
create temporary table TF_SKEL_OVERALL    /* 总体维度骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_SKEL_OVERALL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ      /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID       /* 来源标识 */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
where F.METRIC_NM not in ('ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.2 分行骨架（group_by=branch）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_BRANCH;
create temporary table TF_SKEL_BRANCH    /* 分行维度骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_SKEL_BRANCH
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ                /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID                 /* 来源标识 */
  ,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID   /* 一级分行号 */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
where F.METRIC_NM not in ('ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.3 支行骨架（group_by=org）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_ORG;
create temporary table TF_SKEL_ORG    /* 支行维度骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_SKEL_ORG
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ                /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID                 /* 来源标识 */
  ,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID   /* 一级分行号 */
  ,F.K_BRN_ORG_ID as K_BRN_ORG_ID           /* 网点号 */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
where F.METRIC_NM not in ('ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.4 客户经理骨架（group_by=manager）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_MANAGER;
create temporary table TF_SKEL_MANAGER    /* 客户经理维度骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,K_CM_ID               VARCHAR(256)   NOT NULL    /* 客户经理编号 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_CM_ID)
;
insert into TF_SKEL_MANAGER
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_CM_ID               /* 客户经理编号 */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ                /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID                 /* 来源标识 */
  ,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID   /* 一级分行号 */
  ,F.K_BRN_ORG_ID as K_BRN_ORG_ID           /* 网点号 */
  ,F.K_CM_ID as K_CM_ID                     /* 客户经理编号 */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
;


-- -----------------------------------------------------------------------------
-- 4.5 分行 + 技能明细骨架（group_by=branch, skill_detail=true）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_BRANCH_SKL;
create temporary table TF_SKEL_BRANCH_SKL    /* 分行技能明细骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_SKILL               VARCHAR(512)   NOT NULL    /* 技能ID */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_SKILL)
;
insert into TF_SKEL_BRANCH_SKL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_SKILL               /* 技能ID */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ                /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID                 /* 来源标识 */
  ,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID   /* 一级分行号 */
  ,F.K_SKILL as K_SKILL                     /* 技能ID */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
where F.SKILL_IN_CATALOG = 1
  and F.METRIC_NM not in ('READ_CUSTOMER_CNT', 'INSIGHT_CUSTOMER_CNT', 'INSIGHT_CNT'
                         ,'PHONE_CUSTOMER_CNT', 'PHONE_CNT'
                         ,'ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.6 支行 + 技能明细骨架（group_by=org, skill_detail=true）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_ORG_SKL;
create temporary table TF_SKEL_ORG_SKL    /* 支行技能明细骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,K_SKILL               VARCHAR(512)   NOT NULL    /* 技能ID */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_SKILL)
;
insert into TF_SKEL_ORG_SKL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_SKILL               /* 技能ID */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ                /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID                 /* 来源标识 */
  ,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID   /* 一级分行号 */
  ,F.K_BRN_ORG_ID as K_BRN_ORG_ID           /* 网点号 */
  ,F.K_SKILL as K_SKILL                     /* 技能ID */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
where F.SKILL_IN_CATALOG = 1
  and F.METRIC_NM not in ('READ_CUSTOMER_CNT', 'INSIGHT_CUSTOMER_CNT', 'INSIGHT_CNT'
                         ,'PHONE_CUSTOMER_CNT', 'PHONE_CNT'
                         ,'ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.7 客户经理 + 技能明细骨架（group_by=manager, skill_detail=true）
-- -----------------------------------------------------------------------------
drop table if exists TF_SKEL_MANAGER_SKL;
create temporary table TF_SKEL_MANAGER_SKL    /* 客户经理技能明细骨架 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,K_CM_ID               VARCHAR(256)   NOT NULL    /* 客户经理编号 */
,K_SKILL               VARCHAR(512)   NOT NULL    /* 技能ID */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_CM_ID, K_SKILL)
;
insert into TF_SKEL_MANAGER_SKL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_CM_ID               /* 客户经理编号 */
  ,K_SKILL               /* 技能ID */
)
select distinct
  F.REPLAY_SEQ as REPLAY_SEQ                /* 重跑序号 */
  ,F.SOURCE_ID as SOURCE_ID                 /* 来源标识 */
  ,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID   /* 一级分行号 */
  ,F.K_BRN_ORG_ID as K_BRN_ORG_ID           /* 网点号 */
  ,F.K_CM_ID as K_CM_ID                     /* 客户经理编号 */
  ,F.K_SKILL as K_SKILL                     /* 技能ID */
from TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
where F.SKILL_IN_CATALOG = 1
  and F.METRIC_NM not in ('READ_CUSTOMER_CNT', 'INSIGHT_CUSTOMER_CNT', 'INSIGHT_CNT'
                         ,'PHONE_CUSTOMER_CNT', 'PHONE_CNT')
;


-- =============================================================================
-- 5. 组合宽表（每种组合的指标汇总，并把该任务类型/该维度天然不产出的列置 NULL）
--    骨架 × 任务类型字典 左连指标长表：每个维度对象都补齐三类任务，指标全零也保留；
--    维度对象只来自骨架，所以没有期间事实的机构/经理/技能不会出数。
--    ACTIVE_MANAGER_CNT 只有总体/分行/支行维度出数；ACTIVE_JOB_CNT / PAUSED_JOB_CNT
--    只有客户经理维度出数，其余组合直接写 NULL。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 总体汇总（RPT_COMBO = 'overall'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_OVERALL;
create temporary table TF_RPT_OVERALL    /* 总体汇总指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_RPT_OVERALL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_JOB_CNT                   /* 当前活跃任务数（仅客户经理维度） */
  ,CAST(NULL AS BIGINT) as PAUSED_JOB_CNT                   /* 当前暂停任务数（仅客户经理维度） */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_OVERALL as D    /* 总体维度骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.2 分行汇总（RPT_COMBO = 'branch'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_BRANCH;
create temporary table TF_RPT_BRANCH    /* 分行汇总指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by replication
;
insert into TF_RPT_BRANCH
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                   /* 一级分行号 */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_JOB_CNT                   /* 当前活跃任务数（仅客户经理维度） */
  ,CAST(NULL AS BIGINT) as PAUSED_JOB_CNT                   /* 当前暂停任务数（仅客户经理维度） */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_BRANCH as D    /* 分行维度骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, D.K_FRS_BBK_ORG_ID, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.3 支行汇总（RPT_COMBO = 'org'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_ORG;
create temporary table TF_RPT_ORG    /* 支行汇总指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_FRS_BBK_ORG_ID, K_BRN_ORG_ID)
;
insert into TF_RPT_ORG
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                   /* 一级分行号 */
  ,D.K_BRN_ORG_ID as K_BRN_ORG_ID                           /* 网点号 */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_JOB_CNT                   /* 当前活跃任务数（仅客户经理维度） */
  ,CAST(NULL AS BIGINT) as PAUSED_JOB_CNT                   /* 当前暂停任务数（仅客户经理维度） */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_ORG as D    /* 支行维度骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
      and F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, D.K_FRS_BBK_ORG_ID, D.K_BRN_ORG_ID, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.4 客户经理汇总（RPT_COMBO = 'manager'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_MANAGER;
create temporary table TF_RPT_MANAGER    /* 客户经理汇总指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,K_CM_ID               VARCHAR(256)   NOT NULL    /* 客户经理编号 */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_CM_ID)
;
insert into TF_RPT_MANAGER
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_CM_ID               /* 客户经理编号 */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                   /* 一级分行号 */
  ,D.K_BRN_ORG_ID as K_BRN_ORG_ID                           /* 网点号 */
  ,D.K_CM_ID as K_CM_ID                                     /* 客户经理编号 */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_MANAGER_CNT               /* 活跃客户经理数（仅总体/分行/支行维度） */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_JOB_CNT' then F.METRIC_KEY end) end as ACTIVE_JOB_CNT    /* 当前活跃任务数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PAUSED_JOB_CNT' then F.METRIC_KEY end) end as PAUSED_JOB_CNT    /* 当前暂停任务数 */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_MANAGER as D    /* 客户经理维度骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
      and F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
      and F.K_CM_ID = D.K_CM_ID
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, D.K_FRS_BBK_ORG_ID, D.K_BRN_ORG_ID, D.K_CM_ID, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.5 分行 + 技能明细（RPT_COMBO = 'branch_skill'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_BRANCH_SKL;
create temporary table TF_RPT_BRANCH_SKL    /* 分行技能明细指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_SKILL               VARCHAR(512)   NOT NULL    /* 技能ID */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_SKILL)
;
insert into TF_RPT_BRANCH_SKL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_SKILL               /* 技能ID */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                   /* 一级分行号 */
  ,D.K_SKILL as K_SKILL                                     /* 技能ID */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_JOB_CNT                   /* 当前活跃任务数（仅客户经理维度） */
  ,CAST(NULL AS BIGINT) as PAUSED_JOB_CNT                   /* 当前暂停任务数（仅客户经理维度） */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_BRANCH_SKL as D    /* 分行技能明细骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
      and F.K_SKILL = D.K_SKILL
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, D.K_FRS_BBK_ORG_ID, D.K_SKILL, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.6 支行 + 技能明细（RPT_COMBO = 'org_skill'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_ORG_SKL;
create temporary table TF_RPT_ORG_SKL    /* 支行技能明细指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,K_SKILL               VARCHAR(512)   NOT NULL    /* 技能ID */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_SKILL)
;
insert into TF_RPT_ORG_SKL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_SKILL               /* 技能ID */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                   /* 一级分行号 */
  ,D.K_BRN_ORG_ID as K_BRN_ORG_ID                           /* 网点号 */
  ,D.K_SKILL as K_SKILL                                     /* 技能ID */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_JOB_CNT                   /* 当前活跃任务数（仅客户经理维度） */
  ,CAST(NULL AS BIGINT) as PAUSED_JOB_CNT                   /* 当前暂停任务数（仅客户经理维度） */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_ORG_SKL as D    /* 支行技能明细骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
      and F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
      and F.K_SKILL = D.K_SKILL
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, D.K_FRS_BBK_ORG_ID, D.K_BRN_ORG_ID, D.K_SKILL, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.7 客户经理 + 技能明细（RPT_COMBO = 'manager_skill'）
-- -----------------------------------------------------------------------------
drop table if exists TF_RPT_MANAGER_SKL;
create temporary table TF_RPT_MANAGER_SKL    /* 客户经理技能明细指标 */
(
 REPLAY_SEQ            INTEGER        NOT NULL    /* 重跑序号 */
,SOURCE_ID             VARCHAR(256)   NOT NULL    /* 来源标识 */
,K_FRS_BBK_ORG_ID      VARCHAR(200)   NOT NULL    /* 一级分行号 */
,K_BRN_ORG_ID          VARCHAR(100)   NOT NULL    /* 网点号 */
,K_CM_ID               VARCHAR(256)   NOT NULL    /* 客户经理编号 */
,K_SKILL               VARCHAR(512)   NOT NULL    /* 技能ID */
,JOB_TYPE              VARCHAR(64)    NOT NULL    /* 任务类型 */
,SKILL_CNT             BIGINT                    /* 技能数 */
,ACTIVE_MANAGER_CNT    BIGINT                    /* 活跃客户经理数 */
,ACTIVE_JOB_CNT        BIGINT                    /* 当前活跃任务数 */
,PAUSED_JOB_CNT        BIGINT                    /* 当前暂停任务数 */
,SUC_EXECUTE_JOB       BIGINT                    /* 成功执行任务数 */
,READ_TASKS            BIGINT                    /* 已查看任务数 */
,RECOMMENDED_CUSTOMERS BIGINT                    /* 方案客户数 */
,READ_CUSTOMER_CNT     BIGINT                    /* 已查看方案客户数 */
,INSIGHT_CUSTOMER_CNT  BIGINT                    /* 洞察客户数 */
,INSIGHT_CNT           BIGINT                    /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    BIGINT                    /* 电访客户数 */
,PHONE_CNT             BIGINT                    /* 点击去电访总次数 */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
on commit preserve rows
distribute by hash (SOURCE_ID, K_CM_ID, K_SKILL)
;
insert into TF_RPT_MANAGER_SKL
(
   REPLAY_SEQ            /* 重跑序号 */
  ,SOURCE_ID             /* 来源标识 */
  ,K_FRS_BBK_ORG_ID      /* 一级分行号 */
  ,K_BRN_ORG_ID          /* 网点号 */
  ,K_CM_ID               /* 客户经理编号 */
  ,K_SKILL               /* 技能ID */
  ,JOB_TYPE              /* 任务类型 */
  ,SKILL_CNT             /* 技能数 */
  ,ACTIVE_MANAGER_CNT    /* 活跃客户经理数 */
  ,ACTIVE_JOB_CNT        /* 当前活跃任务数 */
  ,PAUSED_JOB_CNT        /* 当前暂停任务数 */
  ,SUC_EXECUTE_JOB       /* 成功执行任务数 */
  ,READ_TASKS            /* 已查看任务数 */
  ,RECOMMENDED_CUSTOMERS /* 方案客户数 */
  ,READ_CUSTOMER_CNT     /* 已查看方案客户数 */
  ,INSIGHT_CUSTOMER_CNT  /* 洞察客户数 */
  ,INSIGHT_CNT           /* 点击客户洞察总次数 */
  ,PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,PHONE_CNT             /* 点击去电访总次数 */
)
select
  D.REPLAY_SEQ as REPLAY_SEQ                                /* 重跑序号 */
  ,D.SOURCE_ID as SOURCE_ID                                 /* 来源标识 */
  ,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID                   /* 一级分行号 */
  ,D.K_BRN_ORG_ID as K_BRN_ORG_ID                           /* 网点号 */
  ,D.K_CM_ID as K_CM_ID                                     /* 客户经理编号 */
  ,D.K_SKILL as K_SKILL                                     /* 技能ID */
  ,TT.JOB_TYPE as JOB_TYPE                                  /* 任务类型 */
  ,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    /* 技能数 */
  ,CAST(NULL AS BIGINT) as ACTIVE_MANAGER_CNT               /* 活跃客户经理数（仅总体/分行/支行维度） */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'ACTIVE_JOB_CNT' then F.METRIC_KEY end) end as ACTIVE_JOB_CNT    /* 当前活跃任务数 */
  ,case when TT.JOB_TYPE = 'ask_plan' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PAUSED_JOB_CNT' then F.METRIC_KEY end) end as PAUSED_JOB_CNT    /* 当前暂停任务数 */
  ,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    /* 成功执行任务数 */
  ,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    /* 已查看任务数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    /* 方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    /* 已查看方案客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    /* 洞察客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    /* 点击客户洞察总次数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    /* 电访客户数 */
  ,case when TT.JOB_TYPE = 'push_other' then CAST(NULL AS BIGINT)
        else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    /* 点击去电访总次数 */
from TF_SKEL_MANAGER_SKL as D    /* 客户经理技能明细骨架 */
inner join TF_TASK_TYPE as TT    /* 任务类型字典 */
        on 1 = 1
left join TF_METRIC_FACT as F    /* 任务类型报表指标长表 */
       on F.SOURCE_ID = D.SOURCE_ID
      and F.REPLAY_SEQ = D.REPLAY_SEQ
      and F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
      and F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
      and F.K_CM_ID = D.K_CM_ID
      and F.K_SKILL = D.K_SKILL
      and F.JOB_TYPE = TT.JOB_TYPE
group by D.REPLAY_SEQ, D.SOURCE_ID, D.K_FRS_BBK_ORG_ID, D.K_BRN_ORG_ID, D.K_CM_ID, D.K_SKILL, TT.JOB_TYPE
;


-- =============================================================================
-- 6. 报表落数（七种组合落同一张表，用 RPT_COMBO 区分）
--    写入方式：6.0 先删掉「跑数日期前 7 天 ~ 跑数日期」这 8 天的数据，再按组合各 insert 一次，
--    因此重跑幂等；建议 6.0 ~ 6.7 放在同一事务里执行，避免查数时读到半份数据。
--    维度规则：本组合用不到的维度列写 'ALL'（不是 NULL），消费方按 'ALL' 判断“不适用”；
--    比例列的零分母用 nullif(分母, 0) 保护（高斯除零会直接报错，不会像 Hive 那样返回 NULL）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.0 清理近 8 天分区数据（重跑幂等，按 DW_DAT_DT）
-- -----------------------------------------------------------------------------
delete from ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
 where DW_DAT_DT >= CAST('${v_Trx_Dt}' AS DATE) - 7
   and DW_DAT_DT <= CAST('${v_Trx_Dt}' AS DATE)
;


-- -----------------------------------------------------------------------------
-- 6.1 总体汇总（RPT_COMBO = 'overall'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'overall' as RPT_COMBO                                       /* 报表组合 */
  ,'ALL' as FRS_BBK_ORG_ID                                      /* 一级分行号（不适用） */
  ,'ALL' as FRS_BBK_ORG_NM                                      /* 一级分行名称（不适用） */
  ,'ALL' as BRN_ORG_ID                                          /* 网点号（不适用） */
  ,'ALL' as BRN_ORG_NM                                          /* 网点名称（不适用） */
  ,'ALL' as CM_ID                                               /* 客户经理编号（不适用） */
  ,'ALL' as CM_NM                                               /* 客户经理姓名（不适用） */
  ,'ALL' as PST_LVL                                             /* 岗位定级（不适用） */
  ,'ALL' as SKILL_ID                                            /* 技能ID（不适用） */
  ,'ALL' as SKILL_NM                                            /* 技能名称（不适用） */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_OVERALL as R    /* 总体汇总指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
;


-- -----------------------------------------------------------------------------
-- 6.2 分行汇总（RPT_COMBO = 'branch'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'branch' as RPT_COMBO                                        /* 报表组合 */
  ,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID                         /* 一级分行号 */
  ,NB.FRS_BBK_ORG_NM as FRS_BBK_ORG_NM                          /* 一级分行名称 */
  ,'ALL' as BRN_ORG_ID                                          /* 网点号（不适用） */
  ,'ALL' as BRN_ORG_NM                                          /* 网点名称（不适用） */
  ,'ALL' as CM_ID                                               /* 客户经理编号（不适用） */
  ,'ALL' as CM_NM                                               /* 客户经理姓名（不适用） */
  ,'ALL' as PST_LVL                                             /* 岗位定级（不适用） */
  ,'ALL' as SKILL_ID                                            /* 技能ID（不适用） */
  ,'ALL' as SKILL_NM                                            /* 技能名称（不适用） */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_BRANCH as R    /* 分行汇总指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
left join TF_BBK_NAME as NB    /* 分行名称 */
       on NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
;


-- -----------------------------------------------------------------------------
-- 6.3 支行汇总（RPT_COMBO = 'org'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'org' as RPT_COMBO                                           /* 报表组合 */
  ,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID                         /* 一级分行号 */
  ,NB.FRS_BBK_ORG_NM as FRS_BBK_ORG_NM                          /* 一级分行名称 */
  ,R.K_BRN_ORG_ID as BRN_ORG_ID                                 /* 网点号 */
  ,NO.BRN_ORG_NM as BRN_ORG_NM                                  /* 网点名称 */
  ,'ALL' as CM_ID                                               /* 客户经理编号（不适用） */
  ,'ALL' as CM_NM                                               /* 客户经理姓名（不适用） */
  ,'ALL' as PST_LVL                                             /* 岗位定级（不适用） */
  ,'ALL' as SKILL_ID                                            /* 技能ID（不适用） */
  ,'ALL' as SKILL_NM                                            /* 技能名称（不适用） */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_ORG as R    /* 支行汇总指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
left join TF_BBK_NAME as NB    /* 分行名称 */
       on NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
left join TF_ORG_NAME as NO    /* 网点名称 */
       on NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
      and NO.BRN_ORG_ID = R.K_BRN_ORG_ID
;


-- -----------------------------------------------------------------------------
-- 6.4 客户经理汇总（RPT_COMBO = 'manager'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'manager' as RPT_COMBO                                       /* 报表组合 */
  ,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID                         /* 一级分行号 */
  ,NB.FRS_BBK_ORG_NM as FRS_BBK_ORG_NM                          /* 一级分行名称 */
  ,R.K_BRN_ORG_ID as BRN_ORG_ID                                 /* 网点号 */
  ,NO.BRN_ORG_NM as BRN_ORG_NM                                  /* 网点名称 */
  ,R.K_CM_ID as CM_ID                                           /* 客户经理编号 */
  ,RK.CM_NM as CM_NM                                            /* 客户经理姓名 */
  ,RK.PST_LVL as PST_LVL                                        /* 岗位定级 */
  ,'ALL' as SKILL_ID                                            /* 技能ID（不适用） */
  ,'ALL' as SKILL_NM                                            /* 技能名称（不适用） */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_MANAGER as R    /* 客户经理汇总指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
left join TF_BBK_NAME as NB    /* 分行名称 */
       on NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
left join TF_ORG_NAME as NO    /* 网点名称 */
       on NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
      and NO.BRN_ORG_ID = R.K_BRN_ORG_ID
left join TF_JKH_ROSTER as RK    /* 金葵花客户经理名单快照 */
       on RK.CM_ID = R.K_CM_ID
;


-- -----------------------------------------------------------------------------
-- 6.5 分行 + 技能明细（RPT_COMBO = 'branch_skill'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'branch_skill' as RPT_COMBO                                  /* 报表组合 */
  ,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID                         /* 一级分行号 */
  ,NB.FRS_BBK_ORG_NM as FRS_BBK_ORG_NM                          /* 一级分行名称 */
  ,'ALL' as BRN_ORG_ID                                          /* 网点号（不适用） */
  ,'ALL' as BRN_ORG_NM                                          /* 网点名称（不适用） */
  ,'ALL' as CM_ID                                               /* 客户经理编号（不适用） */
  ,'ALL' as CM_NM                                               /* 客户经理姓名（不适用） */
  ,'ALL' as PST_LVL                                             /* 岗位定级（不适用） */
  ,R.K_SKILL as SKILL_ID                                        /* 技能ID */
  ,NK.SKILL_NM as SKILL_NM                                      /* 技能名称 */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_BRANCH_SKL as R    /* 分行技能明细指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
left join TF_BBK_NAME as NB    /* 分行名称 */
       on NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
left join TF_SKILL_CATALOG as NK    /* 技能目录（纳入统计的市场技能） */
       on NK.SOURCE_ID = R.SOURCE_ID
      and NK.SKILL_ID = R.K_SKILL
;


-- -----------------------------------------------------------------------------
-- 6.6 支行 + 技能明细（RPT_COMBO = 'org_skill'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'org_skill' as RPT_COMBO                                     /* 报表组合 */
  ,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID                         /* 一级分行号 */
  ,NB.FRS_BBK_ORG_NM as FRS_BBK_ORG_NM                          /* 一级分行名称 */
  ,R.K_BRN_ORG_ID as BRN_ORG_ID                                 /* 网点号 */
  ,NO.BRN_ORG_NM as BRN_ORG_NM                                  /* 网点名称 */
  ,'ALL' as CM_ID                                               /* 客户经理编号（不适用） */
  ,'ALL' as CM_NM                                               /* 客户经理姓名（不适用） */
  ,'ALL' as PST_LVL                                             /* 岗位定级（不适用） */
  ,R.K_SKILL as SKILL_ID                                        /* 技能ID */
  ,NK.SKILL_NM as SKILL_NM                                      /* 技能名称 */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_ORG_SKL as R    /* 支行技能明细指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
left join TF_BBK_NAME as NB    /* 分行名称 */
       on NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
left join TF_ORG_NAME as NO    /* 网点名称 */
       on NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
      and NO.BRN_ORG_ID = R.K_BRN_ORG_ID
left join TF_SKILL_CATALOG as NK    /* 技能目录（纳入统计的市场技能） */
       on NK.SOURCE_ID = R.SOURCE_ID
      and NK.SKILL_ID = R.K_SKILL
;


-- -----------------------------------------------------------------------------
-- 6.7 客户经理 + 技能明细（RPT_COMBO = 'manager_skill'）
-- -----------------------------------------------------------------------------
insert into ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT, SOURCE_ID, RPT_COMBO, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM, BRN_ORG_ID
,BRN_ORG_NM, CM_ID, CM_NM, PST_LVL, SKILL_ID, SKILL_NM, JOB_TYPE, JOB_TYPE_NM
,SKILL_CNT, ACTIVE_MANAGER_CNT, ACTIVE_JOB_CNT, PAUSED_JOB_CNT, SUC_EXECUTE_JOB
,READ_TASKS, READ_RATE, RECOMMENDED_CUSTOMERS, READ_CUSTOMER_CNT, PLAN_READ_RATE
,INSIGHT_CUSTOMER_CNT, CLICK_TO_INSIGHT_RATE, INSIGHT_CNT, PHONE_CUSTOMER_CNT
,CLICK_TO_PHONE_RATE, PHONE_CNT
)
select
  CAL.REPLAY_DT as DW_DAT_DT                                   /* 数据日期（分区） */
  ,R.SOURCE_ID as SOURCE_ID                                     /* 来源标识 */
  ,'manager_skill' as RPT_COMBO                                 /* 报表组合 */
  ,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID                         /* 一级分行号 */
  ,NB.FRS_BBK_ORG_NM as FRS_BBK_ORG_NM                          /* 一级分行名称 */
  ,R.K_BRN_ORG_ID as BRN_ORG_ID                                 /* 网点号 */
  ,NO.BRN_ORG_NM as BRN_ORG_NM                                  /* 网点名称 */
  ,R.K_CM_ID as CM_ID                                           /* 客户经理编号 */
  ,RK.CM_NM as CM_NM                                            /* 客户经理姓名 */
  ,RK.PST_LVL as PST_LVL                                        /* 岗位定级 */
  ,R.K_SKILL as SKILL_ID                                        /* 技能ID */
  ,NK.SKILL_NM as SKILL_NM                                      /* 技能名称 */
  ,R.JOB_TYPE as JOB_TYPE                                       /* 任务类型 */
  ,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as JOB_TYPE_NM    /* 任务类型名称 */
  ,R.SKILL_CNT as SKILL_CNT                                     /* 技能数 */
  ,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT                   /* 活跃客户经理数 */
  ,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT                           /* 当前活跃任务数 */
  ,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT                           /* 当前暂停任务数 */
  ,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB                         /* 成功执行任务数 */
  ,R.READ_TASKS as READ_TASKS                                   /* 已查看任务数 */
  ,round(100.0 * R.READ_TASKS / nullif(R.SUC_EXECUTE_JOB, 0), 2) as READ_RATE    /* 任务查看率 */
  ,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS             /* 方案客户数 */
  ,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT                     /* 已查看方案客户数 */
  ,round(100.0 * R.READ_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as PLAN_READ_RATE    /* 方案查看率 */
  ,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT               /* 洞察客户数 */
  ,round(100.0 * R.INSIGHT_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_INSIGHT_RATE    /* 洞察覆盖率 */
  ,R.INSIGHT_CNT as INSIGHT_CNT                                 /* 点击客户洞察总次数 */
  ,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT                   /* 电访客户数 */
  ,round(100.0 * R.PHONE_CUSTOMER_CNT / nullif(R.RECOMMENDED_CUSTOMERS, 0), 2) as CLICK_TO_PHONE_RATE    /* 电访覆盖率 */
  ,R.PHONE_CNT as PHONE_CNT                                     /* 点击去电访总次数 */
from TF_RPT_MANAGER_SKL as R    /* 客户经理技能明细指标 */
inner join TF_CALENDAR as CAL    /* 重跑日历 */
        on CAL.REPLAY_SEQ = R.REPLAY_SEQ
left join TF_BBK_NAME as NB    /* 分行名称 */
       on NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
left join TF_ORG_NAME as NO    /* 网点名称 */
       on NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
      and NO.BRN_ORG_ID = R.K_BRN_ORG_ID
left join TF_JKH_ROSTER as RK    /* 金葵花客户经理名单快照 */
       on RK.CM_ID = R.K_CM_ID
left join TF_SKILL_CATALOG as NK    /* 技能目录（纳入统计的市场技能） */
       on NK.SOURCE_ID = R.SOURCE_ID
      and NK.SKILL_ID = R.K_SKILL
;
