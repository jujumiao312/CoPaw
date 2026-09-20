-- =============================================================================
-- 金葵花任务类型报表 —— Hive 跑数脚本（每天重跑近 7 天 + 当天）
--
-- 对应接口：GET /api/monitor/report/task-type（metric_version = jkh_task_report_v1_snapshot）
-- 入参    ：${hivevar:INPUT_DATE} 跑数日期，格式 yyyy-MM-dd，由调度传入
-- 出参    ：P_AALC.AALC_RM_TASK_TYPE_RPT（七种组合同一张表，用 RPT_COMBO 区分，
--           建表与取值见 task_type_report_tables.sql）
-- 口径真源：docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md、DIMENSIONS.md
-- 差异说明：hive/README.md（有权客户经理数不在仓内计算等）
-- 执行示例：hive -hivevar INPUT_DATE=2026-09-17 -f task_type_report_daily.sql
--
-- 统计区间（重跑日历见第 1.0 段）：
--   一次作业按日历写入 8 个分区，重跑日 D 依次取「跑数日期 R 前 7 天 ~ 跑数日期」：
--     * 推送任务、主动提问：当月 1 号 ~ D，按推送当天/提问当天落到该分区；
--     * 客户点击等行为：当月 1 号 ~ R，推送后 7 天内到达的点击都算回推送当天所在分区。
--   因此分区 D 会在 D ~ D+7 的每次运行里被重写，D+7 之后才定稿；这正是「以任务推送当天
--   为基线、统计推送后 7 天」的口径，也是每次都必须连跑近 7 天分区的原因。
--
-- 写法约束：本脚本不使用任何子查询（没有派生表、没有 EXISTS/IN 子查询、没有 CTE），
--   所有中间结果都落到 T_GPVT 临时表，逐段可单独 run 和抽查，便于在受限环境执行与排错。
--
-- 执行顺序（每段只依赖前面已建好的临时表）：
--   1. 基础维表   重跑日历、名单快照、名单、机构名称、技能目录、任务类型字典
--   2. 事实集合   推送任务、推送方案客户、主动提问、点击事件、点击技能（都带 REPLAY_SEQ）
--   3. 指标长表   把各指标压成“维度键 + 指标名 + 计数键”的长表，一次生成
--   4. 组合骨架   七种报表组合各自的维度对象
--   5. 组合宽表   七种组合各自的指标宽表（含类型不适用的 ALL 规则）
--   6. 报表落数   宽表按 REPLAY_SEQ 分组，关联日历与名称后写入各自日期的动态分区
--
-- 基础数据与字段对应（仓内表名 -> 服务库表名）：
--   R_RAW_VC.NLQ13_SWE_TRACING_SPANS                  -> swe_tracing_spans
--   R_RAW_VC.NLQ13_SWE_HTML_PREVIEW_CLICK_EVENTS      -> swe_html_preview_click_events
--   R_RAW_VC.NLQ13_SWE_CRON_JOBS                      -> swe_cron_jobs
--   R_RAW_VC.NLQ13_SWE_CRON_EXECUTIONS                -> swe_cron_executions
--   R_RAW_VC.NLQ13_SWE_CRON_SUBTASKS                  -> swe_cron_subtasks
--   R_RAW_VC.NLQ13_SWE_MARKETPLACE_SKILLS             -> swe_marketplace_skills（技能目录）
--   P_AALC_VC.AALC_R_RM_SFL_CM_BAS_INFO               -> jkh_user_inf（客户经理名单）
-- 若上述表所在库不是 R_RAW_VC / P_AALC_VC，替换库名即可。
--
-- 时间口径：三条链路各用自己的时间列。底表时间列是 STRING（yyyy-MM-dd HH:mm:ss），
--   这里统一用 substr(时间列, 1, 10) 取日期比较；若目标表按日分区（PRT_DT 等），
--   请把本条件换成对应的分区条件以减少扫描量。
--   推送执行 E.ACTUAL_TIME、主动提问 SP.START_TIME 取「当月 1 号 ~ 重跑日 D」；
--   客户点击 C.CLICKED_AT 取「当月 1 号 ~ 跑数日期 R」，把推送后 7 天的点击回算到分区。
-- =============================================================================


-- =============================================================================
-- 0. 运行参数（动态分区：一次作业写 8 个日期分区）
-- =============================================================================
set hive.exec.dynamic.partition = true;
set hive.exec.dynamic.partition.mode = nonstrict;


-- =============================================================================
-- 1. 基础维表与重跑日历
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.0 重跑日历（跑数日期前 7 天 ~ 跑数当天，共 8 行）
--     点击等行为数据以任务推送当天为基线、要统计推送后 7 天，所以同一个推送日期分区
--     在它之后 7 天的每次运行里都会被重算。日历给出一轮要重跑的所有日期：
--       REPLAY_SEQ = 重跑序号，1 = 跑数日期前 7 天，8 = 跑数当天；
--       REPLAY_DT  = 重跑日期 = 本次写入的分区 PRT_DT = 该分区的统计截止日。
--     事实表带上 REPLAY_SEQ，落数时按 REPLAY_SEQ 分组写回各自日期的分区。
--     若要改重跑天数，只改本段的行数与 date_sub 的天数即可（行数 = 天数 + 1）。
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CALENDAR;
create temporary table T_GPVT.VT_CALENDAR
(
    `REPLAY_SEQ` INT COMMENT '重跑序号：1=跑数日期前 7 天 ... 8=跑数当天' -- --
    ,`REPLAY_DT` STRING COMMENT '重跑日期 yyyy-MM-dd，本次写入的分区值' -- --
)
COMMENT '重跑日历（跑数日期前 7 天 ~ 跑数当天）'

;
insert overwrite table T_GPVT.VT_CALENDAR
    select
1 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 7) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
2 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 6) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
3 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 5) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
4 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 4) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
5 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 3) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
6 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 2) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
7 as REPLAY_SEQ    ---- 重跑序号 ----
,cast(date_sub(cast('${hivevar:INPUT_DATE}' as date), 1) as string) as REPLAY_DT    ---- 重跑日期 ----
union all
    select
8 as REPLAY_SEQ    ---- 重跑序号 ----
,'${hivevar:INPUT_DATE}' as REPLAY_DT    ---- 重跑日期 ----
;


-- -----------------------------------------------------------------------------
-- 1.1 名单快照日（对应接口 _resolve_jkh_sync_date）
--     优先级：跑数日期当天 -> 跑数日期当月月末 -> 全表最早日（全表最新日在跑数日期之后）
--             -> 全表最新日；只在 CLB_IND = '3' 口径内选择
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_JKH_SNAPSHOT;
create temporary table T_GPVT.VT_JKH_SNAPSHOT
(
    `SNAPSHOT_DT` STRING COMMENT '名单快照日，yyyy-MM-dd' -- --
)
COMMENT '客户经理名单快照日'

;
insert overwrite table T_GPVT.VT_JKH_SNAPSHOT
    select
cast(coalesce(
    max(case when S.DW_Snsh_Dt = cast('${hivevar:INPUT_DATE}' as date) then S.DW_Snsh_Dt end)
    ,max(case when S.DW_Snsh_Dt = last_day(cast('${hivevar:INPUT_DATE}' as date)) then S.DW_Snsh_Dt end)
    ,case when max(S.DW_Snsh_Dt) > cast('${hivevar:INPUT_DATE}' as date)
        then min(S.DW_Snsh_Dt) else max(S.DW_Snsh_Dt) end
    ) as string) as SNAPSHOT_DT    ---- 名单快照日 ----
FROM P_AALC_VC.AALC_R_RM_SFL_CM_BAS_INFO as S
WHERE  S.CLB_IND = '3'
;


-- -----------------------------------------------------------------------------
-- 1.2 客户经理名单快照（分行取 FRS_BBK_ORG_ID，支行取 BRN_ORG_ID）
--     一名客户经理一行，机构名称/岗位重复取值用 MIN 取稳定值
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_JKH_ROSTER;
create temporary table T_GPVT.VT_JKH_ROSTER
(
    `CM_ID` STRING COMMENT '客户经理编号（SAP号），对应 jkh_user_inf.user_id' -- --
    ,`USER_NAME` STRING COMMENT '客户经理姓名' -- --
    ,`PST_LVL` STRING COMMENT '岗位定级' -- --
    ,`BRN_ORG_ID` STRING COMMENT '网点号，对应 jkh_user_inf.org_id' -- --
    ,`BRN_ORG_NM` STRING COMMENT '网点名称' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '一级分行号，对应 jkh_user_inf.first_bbk_id' -- --
    ,`BBK_ORG_NM` STRING COMMENT '一级分行名称' -- --
)
COMMENT '金葵花客户经理名单快照'

;
insert overwrite table T_GPVT.VT_JKH_ROSTER
    select
S.CM_ID as CM_ID    ---- 客户经理编号 ----
,min(S.CM_NM) as USER_NAME    ---- 客户经理姓名 ----
,min(S.PST_LVL) as PST_LVL    ---- 岗位定级 ----
,min(S.BRN_ORG_ID) as BRN_ORG_ID    ---- 网点号 ----
,min(S.BRN_ORG_NM) as BRN_ORG_NM    ---- 网点名称 ----
,min(S.FRS_BBK_ORG_ID) as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,min(S.FRS_BBK_ORG_NM) as BBK_ORG_NM    ---- 一级分行名称 ----
FROM P_AALC_VC.AALC_R_RM_SFL_CM_BAS_INFO as S
JOIN T_GPVT.VT_JKH_SNAPSHOT as P
ON  S.DW_Snsh_Dt = cast(P.SNAPSHOT_DT as date)
WHERE  S.CLB_IND = '3'
AND S.CM_ID is not null
AND trim(S.CM_ID) <> ''
GROUP BY S.CM_ID
;


-- -----------------------------------------------------------------------------
-- 1.3 分行名称（对应接口 permissions 的 MIN(first_bbk_nm)）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_BBK_NAME;
create temporary table T_GPVT.VT_BBK_NAME
(
    `FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`BBK_ORG_NM` STRING COMMENT '一级分行名称' -- --
)
COMMENT '分行名称'

;
insert overwrite table T_GPVT.VT_BBK_NAME
    select
coalesce(S.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,min(S.BBK_ORG_NM) as BBK_ORG_NM    ---- 一级分行名称 ----
FROM T_GPVT.VT_JKH_ROSTER as S
GROUP BY coalesce(S.FRS_BBK_ORG_ID, '')
;


-- -----------------------------------------------------------------------------
-- 1.4 网点名称（对应接口 permissions 的 MIN(org_nm)，按 分行+网点 联合键）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_ORG_NAME;
create temporary table T_GPVT.VT_ORG_NAME
(
    `FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`BRN_ORG_NM` STRING COMMENT '网点名称' -- --
)
COMMENT '网点名称'

;
insert overwrite table T_GPVT.VT_ORG_NAME
    select
coalesce(S.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,coalesce(S.BRN_ORG_ID, '') as BRN_ORG_ID    ---- 网点号 ----
,min(S.BRN_ORG_NM) as BRN_ORG_NM    ---- 网点名称 ----
FROM T_GPVT.VT_JKH_ROSTER as S
GROUP BY coalesce(S.FRS_BBK_ORG_ID, '')
, coalesce(S.BRN_ORG_ID, '')
;


-- -----------------------------------------------------------------------------
-- 1.5 技能目录（等价接口侧 swe_marketplace_skills 的去重目录）
--     来源 NLQ13_SWE_MARKETPLACE_SKILLS；只取 include_in_statistics = 1 且 skill_id 非空，
--     按 (source_id, skill_id) 去重，中文名取 MIN(NULLIF(cn_name, ''))
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKILL_CATALOG;
create temporary table T_GPVT.VT_SKILL_CATALOG
(
    `SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`SKILL_ID` STRING COMMENT '技能ID' -- --
    ,`CN_NAME` STRING COMMENT '技能中文名，空值表示目录里没有中文名' -- --
)
COMMENT '技能目录（纳入统计的市场技能）'

;
insert overwrite table T_GPVT.VT_SKILL_CATALOG
    select
K.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,trim(K.SKILL_ID) as SKILL_ID    ---- 技能ID ----
,min(nullif(trim(K.CN_NAME), '')) as CN_NAME    ---- 技能中文名 ----
FROM R_RAW_VC.NLQ13_SWE_MARKETPLACE_SKILLS as K
WHERE  coalesce(cast(K.INCLUDE_IN_STATISTICS as int), 0) = 1
AND K.SKILL_ID is not null
AND trim(K.SKILL_ID) <> ''
GROUP BY K.SOURCE_ID
, trim(K.SKILL_ID)
;


-- -----------------------------------------------------------------------------
-- 1.6 任务类型字典（三类任务，用于给每个维度对象补齐三行）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_TASK_TYPE;
create temporary table T_GPVT.VT_TASK_TYPE
(
    `JOB_TYPE` STRING COMMENT '任务类型' -- --
)
COMMENT '任务类型字典'

;
insert overwrite table T_GPVT.VT_TASK_TYPE
    select
'push_plan' as JOB_TYPE    ---- 推送(名单+方案) ----
union all
    select
'ask_plan' as JOB_TYPE    ---- 主动提问(名单+方案) ----
union all
    select
'push_other' as JOB_TYPE    ---- 推送(非名单方案) ----
;


-- =============================================================================
-- 2. 事实集合
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 有子任务的 trace（接口 has_sub，用于推送类型分类与主动提问判定）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_TRACE_SUB;
create temporary table T_GPVT.VT_TRACE_SUB
(
    `TRACE_ID` STRING COMMENT 'trace_id' -- --
)
COMMENT '存在子任务的 trace'

;
insert overwrite table T_GPVT.VT_TRACE_SUB
    select distinct
S.TRACE_ID as TRACE_ID    ---- trace_id ----
FROM R_RAW_VC.NLQ13_SWE_CRON_SUBTASKS as S
WHERE  S.TRACE_ID is not null
AND S.TRACE_ID <> ''
;


-- -----------------------------------------------------------------------------
-- 2.2 有执行记录的 trace（接口主动提问判定的“历史执行里不存在同 trace”）
--     不限时间、不限来源，与接口口径一致
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_TRACE_EXEC;
create temporary table T_GPVT.VT_TRACE_EXEC
(
    `TRACE_ID` STRING COMMENT 'trace_id' -- --
)
COMMENT '存在执行记录的 trace'

;
insert overwrite table T_GPVT.VT_TRACE_EXEC
    select distinct
E.TRACE_ID as TRACE_ID    ---- trace_id ----
FROM R_RAW_VC.NLQ13_SWE_CRON_EXECUTIONS as E
WHERE  E.TRACE_ID is not null
AND E.TRACE_ID <> ''
;


-- -----------------------------------------------------------------------------
-- 2.3 子任务客户（方案客户来源），按 trace + 客户去重
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SUBTASK_CUST;
create temporary table T_GPVT.VT_SUBTASK_CUST
(
    `TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`CUSTUID` STRING COMMENT '任务中客户UID' -- --
)
COMMENT '子任务里的方案客户'

;
insert overwrite table T_GPVT.VT_SUBTASK_CUST
    select distinct
S.TRACE_ID as TRACE_ID    ---- trace_id ----
,S.CUSTUID as CUSTUID    ---- 任务中客户UID ----
FROM R_RAW_VC.NLQ13_SWE_CRON_SUBTASKS as S
WHERE  S.TRACE_ID is not null
AND S.TRACE_ID <> ''
AND S.CUSTUID is not null
AND S.CUSTUID <> ''
;


-- -----------------------------------------------------------------------------
-- 2.4 合规推送任务 × 统计技能（接口 push_job_scope）
--     条件：job 未删除、未标记删除、skill_ids 非空，且命中的技能在统计目录内
--     array_contains(split(skill_ids, ','), skill_id) 等价 MySQL 的 FIND_IN_SET，
--     同样是按逗号元素精确匹配、不忽略空格
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_PUSH_JOB_SKILL;
create temporary table T_GPVT.VT_PUSH_JOB_SKILL
(
    `SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_ID` STRING COMMENT '任务ID' -- --
    ,`OWNER_CM_ID` STRING COMMENT '任务归属人，取任务表 tenant_id' -- --
    ,`JOB_STATUS` STRING COMMENT '任务当前状态，取 job.status（active/paused 等）' -- --
    ,`SKILL_ID` STRING COMMENT '任务绑定的统计技能ID' -- --
)
COMMENT '推送任务×统计技能'

;
insert overwrite table T_GPVT.VT_PUSH_JOB_SKILL
    select distinct
J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,J.ID as JOB_ID    ---- 任务ID ----
,J.TENANT_ID as OWNER_CM_ID    ---- 任务归属人 ----
,J.STATUS as JOB_STATUS    ---- 任务当前状态 ----
,trim(SK.SKILL_ID) as SKILL_ID    ---- 任务绑定的统计技能ID ----
FROM R_RAW_VC.NLQ13_SWE_CRON_JOBS as J
lateral view explode(split(J.SKILL_IDS, ',')) SK as SKILL_ID
JOIN T_GPVT.VT_SKILL_CATALOG as K
ON  K.SOURCE_ID = J.SOURCE_ID
AND K.SKILL_ID = trim(SK.SKILL_ID)
WHERE  J.DELETED_AT is null
AND J.STATUS <> 'deleted'
AND J.SKILL_IDS is not null
AND trim(J.SKILL_IDS) <> ''
;


-- -----------------------------------------------------------------------------
-- 2.5 合规推送任务（任务粒度，去掉技能列）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_PUSH_JOB;
create temporary table T_GPVT.VT_PUSH_JOB
(
    `SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_ID` STRING COMMENT '任务ID' -- --
    ,`OWNER_CM_ID` STRING COMMENT '任务归属人' -- --
    ,`JOB_STATUS` STRING COMMENT '任务当前状态，取 job.status' -- --
)
COMMENT '合规推送任务'

;
insert overwrite table T_GPVT.VT_PUSH_JOB
    select distinct
J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,J.JOB_ID as JOB_ID    ---- 任务ID ----
,J.OWNER_CM_ID as OWNER_CM_ID    ---- 任务归属人 ----
,J.JOB_STATUS as JOB_STATUS    ---- 任务当前状态 ----
FROM T_GPVT.VT_PUSH_JOB_SKILL as J
;


-- -----------------------------------------------------------------------------
-- 2.6 推送任务集合（执行粒度）：接口 push 子查询
--     过滤：任务合规、执行时间在「当月 1 号 ~ 重跑日」区间、
--           「有同 trace 子任务」或「执行与异步状态均成功」
--     分类：有子任务 -> push_plan，无子任务且成功 -> push_other
--     名单：执行人、任务归属人分别匹配名单（一个没在名单里不影响另一列，用标记区分）
--     重跑：关联第 1.0 段日历，每个重跑日各出一份执行集合（带 REPLAY_SEQ）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_PUSH_EXEC;
create temporary table T_GPVT.VT_PUSH_EXEC
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`EXEC_ID` STRING COMMENT '执行记录ID' -- --
    ,`JOB_ID` STRING COMMENT '任务ID' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：push_plan/push_other' -- --
    ,`SUC_FLAG` INT COMMENT '执行成功标记：status=success 且 async_status=success' -- --
    ,`READ_FLAG` INT COMMENT '已读标记：is_read=1' -- --
    ,`JOB_STATUS` STRING COMMENT '任务当前状态，取 job.status' -- --
    ,`EXEC_CM_ID` STRING COMMENT '执行人，取执行表 tenant_id' -- --
    ,`EXEC_IN_ROSTER` INT COMMENT '执行人是否在名单内' -- --
    ,`EXEC_FRS_BBK_ORG_ID` STRING COMMENT '执行人一级分行号' -- --
    ,`EXEC_BRN_ORG_ID` STRING COMMENT '执行人网点号' -- --
    ,`OWNER_CM_ID` STRING COMMENT '任务归属人' -- --
    ,`OWNER_IN_ROSTER` INT COMMENT '任务归属人是否在名单内' -- --
    ,`OWNER_FRS_BBK_ORG_ID` STRING COMMENT '任务归属人一级分行号' -- --
    ,`OWNER_BRN_ORG_ID` STRING COMMENT '任务归属人网点号' -- --
)
COMMENT '推送任务集合（执行粒度）'

;
insert overwrite table T_GPVT.VT_PUSH_EXEC
    select
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.ID as EXEC_ID    ---- 执行记录ID ----
,J.JOB_ID as JOB_ID    ---- 任务ID ----
,E.TRACE_ID as TRACE_ID    ---- trace_id ----
,case when TS.TRACE_ID is not null then 'push_plan' else 'push_other' end as JOB_TYPE    ---- 任务类型 ----
,case when E.STATUS = 'success' and E.ASYNC_STATUS = 'success' then 1 else 0 end as SUC_FLAG    ---- 执行成功标记 ----
,case when E.IS_READ = 1 then 1 else 0 end as READ_FLAG    ---- 已读标记 ----
,J.JOB_STATUS as JOB_STATUS    ---- 任务当前状态 ----
,E.TENANT_ID as EXEC_CM_ID    ---- 执行人 ----
,case when R.CM_ID is not null then 1 else 0 end as EXEC_IN_ROSTER    ---- 执行人是否在名单内 ----
,coalesce(R.FRS_BBK_ORG_ID, '') as EXEC_FRS_BBK_ORG_ID    ---- 执行人一级分行号 ----
,coalesce(R.BRN_ORG_ID, '') as EXEC_BRN_ORG_ID    ---- 执行人网点号 ----
,J.OWNER_CM_ID as OWNER_CM_ID    ---- 任务归属人 ----
,case when R2.CM_ID is not null then 1 else 0 end as OWNER_IN_ROSTER    ---- 任务归属人是否在名单内 ----
,coalesce(R2.FRS_BBK_ORG_ID, '') as OWNER_FRS_BBK_ORG_ID    ---- 任务归属人一级分行号 ----
,coalesce(R2.BRN_ORG_ID, '') as OWNER_BRN_ORG_ID    ---- 任务归属人网点号 ----
FROM R_RAW_VC.NLQ13_SWE_CRON_EXECUTIONS as E
JOIN T_GPVT.VT_PUSH_JOB as J
ON  J.JOB_ID = E.JOB_ID
JOIN T_GPVT.VT_CALENDAR as CAL
ON  substr(E.ACTUAL_TIME, 1, 10) >= concat(substr(CAL.REPLAY_DT, 1, 7), '-01')
AND substr(E.ACTUAL_TIME, 1, 10) <= CAL.REPLAY_DT
LEFT OUTER JOIN T_GPVT.VT_TRACE_SUB as TS
ON  TS.TRACE_ID = E.TRACE_ID
LEFT OUTER JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = E.TENANT_ID
LEFT OUTER JOIN T_GPVT.VT_JKH_ROSTER as R2
ON  R2.CM_ID = J.OWNER_CM_ID
WHERE  (
        TS.TRACE_ID is not null
        or (E.STATUS = 'success' and E.ASYNC_STATUS = 'success')
    )
;


-- -----------------------------------------------------------------------------
-- 2.7 推送任务集合（执行 × 统计技能）：技能数、技能明细、点击技能归属共用
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_PUSH_EXEC_SKILL;
create temporary table T_GPVT.VT_PUSH_EXEC_SKILL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`EXEC_ID` STRING COMMENT '执行记录ID' -- --
    ,`JOB_ID` STRING COMMENT '任务ID' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`SKILL_ID` STRING COMMENT '任务绑定的统计技能ID' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：push_plan/push_other' -- --
    ,`SUC_FLAG` INT COMMENT '执行成功标记' -- --
    ,`READ_FLAG` INT COMMENT '已读标记' -- --
    ,`JOB_STATUS` STRING COMMENT '任务当前状态，取 job.status' -- --
    ,`EXEC_CM_ID` STRING COMMENT '执行人' -- --
    ,`EXEC_IN_ROSTER` INT COMMENT '执行人是否在名单内' -- --
    ,`EXEC_FRS_BBK_ORG_ID` STRING COMMENT '执行人一级分行号' -- --
    ,`EXEC_BRN_ORG_ID` STRING COMMENT '执行人网点号' -- --
    ,`OWNER_CM_ID` STRING COMMENT '任务归属人' -- --
    ,`OWNER_IN_ROSTER` INT COMMENT '任务归属人是否在名单内' -- --
    ,`OWNER_FRS_BBK_ORG_ID` STRING COMMENT '任务归属人一级分行号' -- --
    ,`OWNER_BRN_ORG_ID` STRING COMMENT '任务归属人网点号' -- --
)
COMMENT '推送任务集合（执行×统计技能）'

;
insert overwrite table T_GPVT.VT_PUSH_EXEC_SKILL
    select
E.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,E.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.EXEC_ID as EXEC_ID    ---- 执行记录ID ----
,E.JOB_ID as JOB_ID    ---- 任务ID ----
,E.TRACE_ID as TRACE_ID    ---- trace_id ----
,JS.SKILL_ID as SKILL_ID    ---- 任务绑定的统计技能ID ----
,E.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,E.SUC_FLAG as SUC_FLAG    ---- 执行成功标记 ----
,E.READ_FLAG as READ_FLAG    ---- 已读标记 ----
,E.JOB_STATUS as JOB_STATUS    ---- 任务当前状态 ----
,E.EXEC_CM_ID as EXEC_CM_ID    ---- 执行人 ----
,E.EXEC_IN_ROSTER as EXEC_IN_ROSTER    ---- 执行人是否在名单内 ----
,E.EXEC_FRS_BBK_ORG_ID as EXEC_FRS_BBK_ORG_ID    ---- 执行人一级分行号 ----
,E.EXEC_BRN_ORG_ID as EXEC_BRN_ORG_ID    ---- 执行人网点号 ----
,E.OWNER_CM_ID as OWNER_CM_ID    ---- 任务归属人 ----
,E.OWNER_IN_ROSTER as OWNER_IN_ROSTER    ---- 任务归属人是否在名单内 ----
,E.OWNER_FRS_BBK_ORG_ID as OWNER_FRS_BBK_ORG_ID    ---- 任务归属人一级分行号 ----
,E.OWNER_BRN_ORG_ID as OWNER_BRN_ORG_ID    ---- 任务归属人网点号 ----
FROM T_GPVT.VT_PUSH_EXEC as E
JOIN T_GPVT.VT_PUSH_JOB_SKILL as JS
ON  JS.JOB_ID = E.JOB_ID
AND JS.SOURCE_ID = E.SOURCE_ID
;


-- -----------------------------------------------------------------------------
-- 2.8 推送方案客户（执行 × 技能 × 客户）：接口 push_customers，只取 push_plan
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_PUSH_CUST;
create temporary table T_GPVT.VT_PUSH_CUST
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：push_plan' -- --
    ,`SKILL_ID` STRING COMMENT '技能ID' -- --
    ,`CUSTUID` STRING COMMENT '任务中客户UID' -- --
    ,`EXEC_CM_ID` STRING COMMENT '执行人' -- --
    ,`EXEC_FRS_BBK_ORG_ID` STRING COMMENT '执行人一级分行号' -- --
    ,`EXEC_BRN_ORG_ID` STRING COMMENT '执行人网点号' -- --
)
COMMENT '推送方案客户（执行×技能×客户）'

;
insert overwrite table T_GPVT.VT_PUSH_CUST
    select distinct
E.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,E.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,E.SKILL_ID as SKILL_ID    ---- 技能ID ----
,S.CUSTUID as CUSTUID    ---- 任务中客户UID ----
,E.EXEC_CM_ID as EXEC_CM_ID    ---- 执行人 ----
,E.EXEC_FRS_BBK_ORG_ID as EXEC_FRS_BBK_ORG_ID    ---- 执行人一级分行号 ----
,E.EXEC_BRN_ORG_ID as EXEC_BRN_ORG_ID    ---- 执行人网点号 ----
FROM T_GPVT.VT_PUSH_EXEC_SKILL as E
JOIN T_GPVT.VT_SUBTASK_CUST as S
ON  S.TRACE_ID = E.TRACE_ID
WHERE  E.JOB_TYPE = 'push_plan'
;


-- -----------------------------------------------------------------------------
-- 2.9 合格主动提问 Span（接口 ask_qualifier，不限制时间）
--     条件：trace 非空、技能非空、有同 trace 子任务、历史执行里不存在同 trace 的执行；
--     同时带上提问人名单信息与“技能是否在统计目录内”标记。
--     不加时间窗是因为接口的主动点击关联也不限制 Span 生成时间，时间窗在 2.10 再收窄。
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_ASK_SPAN;
create temporary table T_GPVT.VT_ASK_SPAN
(
    `SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`SKILL_ID` STRING COMMENT 'Span技能ID' -- --
    ,`CM_ID` STRING COMMENT '提问人' -- --
    ,`START_TIME` STRING COMMENT 'Span开始时间' -- --
    ,`IN_STAT_CATALOG` INT COMMENT '技能是否在统计目录内：1=在目录' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '网点号' -- --
)
COMMENT '合格主动提问 Span（不含时间窗）'

;
insert overwrite table T_GPVT.VT_ASK_SPAN
    select distinct
SP.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,SP.TRACE_ID as TRACE_ID    ---- trace_id ----
,trim(SP.SKILL_ID) as SKILL_ID    ---- Span技能ID ----
,SP.CM_ID as CM_ID    ---- 提问人 ----
,SP.START_TIME as START_TIME    ---- Span开始时间 ----
,case when K.SKILL_ID is not null then 1 else 0 end as IN_STAT_CATALOG    ---- 技能是否在统计目录内 ----
,coalesce(R.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,coalesce(R.BRN_ORG_ID, '') as BRN_ORG_ID    ---- 网点号 ----
FROM R_RAW_VC.NLQ13_SWE_TRACING_SPANS as SP
JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = SP.CM_ID
JOIN T_GPVT.VT_TRACE_SUB as TS
ON  TS.TRACE_ID = SP.TRACE_ID
LEFT OUTER JOIN T_GPVT.VT_TRACE_EXEC as TE
ON  TE.TRACE_ID = SP.TRACE_ID
LEFT OUTER JOIN T_GPVT.VT_SKILL_CATALOG as K
ON  K.SOURCE_ID = SP.SOURCE_ID
AND K.SKILL_ID = trim(SP.SKILL_ID)
WHERE  SP.TRACE_ID <> ''
AND SP.SKILL_ID is not null
AND trim(SP.SKILL_ID) <> ''
AND TE.TRACE_ID is null
;


-- -----------------------------------------------------------------------------
-- 2.10 统计区间内的主动提问（Span × 技能）：接口 ask 子查询
--      重跑：关联第 1.0 段日历，取「当月 1 号 ~ 重跑日」，每个重跑日各出一份
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_ASK_TRACE;
create temporary table T_GPVT.VT_ASK_TRACE
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：ask_plan' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`SKILL_ID` STRING COMMENT 'Span技能ID' -- --
    ,`CM_ID` STRING COMMENT '提问人' -- --
    ,`IN_STAT_CATALOG` INT COMMENT '技能是否在统计目录内' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '网点号' -- --
)
COMMENT '主动提问任务（Span×技能）'

;
insert overwrite table T_GPVT.VT_ASK_TRACE
    select distinct
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,A.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'ask_plan' as JOB_TYPE    ---- 任务类型 ----
,A.TRACE_ID as TRACE_ID    ---- trace_id ----
,A.SKILL_ID as SKILL_ID    ---- Span技能ID ----
,A.CM_ID as CM_ID    ---- 提问人 ----
,A.IN_STAT_CATALOG as IN_STAT_CATALOG    ---- 技能是否在统计目录内 ----
,A.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,A.BRN_ORG_ID as BRN_ORG_ID    ---- 网点号 ----
FROM T_GPVT.VT_ASK_SPAN as A
JOIN T_GPVT.VT_CALENDAR as CAL
ON  substr(A.START_TIME, 1, 10) >= concat(substr(CAL.REPLAY_DT, 1, 7), '-01')
AND substr(A.START_TIME, 1, 10) <= CAL.REPLAY_DT
;


-- -----------------------------------------------------------------------------
-- 2.11 主动提问方案客户（Span × 技能 × 客户）：接口 ask_customers
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_ASK_CUST;
create temporary table T_GPVT.VT_ASK_CUST
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：ask_plan' -- --
    ,`SKILL_ID` STRING COMMENT '技能ID' -- --
    ,`CUSTUID` STRING COMMENT '任务中客户UID' -- --
    ,`CM_ID` STRING COMMENT '提问人' -- --
    ,`IN_STAT_CATALOG` INT COMMENT '技能是否在统计目录内' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '网点号' -- --
)
COMMENT '主动提问方案客户（Span×技能×客户）'

;
insert overwrite table T_GPVT.VT_ASK_CUST
    select distinct
A.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,A.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,A.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,A.SKILL_ID as SKILL_ID    ---- 技能ID ----
,S.CUSTUID as CUSTUID    ---- 任务中客户UID ----
,A.CM_ID as CM_ID    ---- 提问人 ----
,A.IN_STAT_CATALOG as IN_STAT_CATALOG    ---- 技能是否在统计目录内 ----
,A.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,A.BRN_ORG_ID as BRN_ORG_ID    ---- 网点号 ----
FROM T_GPVT.VT_ASK_TRACE as A
JOIN T_GPVT.VT_SUBTASK_CUST as S
ON  S.TRACE_ID = A.TRACE_ID
;


-- -----------------------------------------------------------------------------
-- 2.12 客户点击基础集合：接口 click_rows 的过滤部分
--     过滤：点击时间在「当月 1 号 ~ 跑数日期」、点击人在名单内、customer_id 与 trace_id 非空，
--           且属于「preview_view + sub」或「button_click + insight/phone」
--     重跑：关联第 1.0 段日历，点击窗口统一截到跑数日期（推送后 7 天的点击回算到推送
--           当天所在分区），每个重跑日各带一份点击集合（带 REPLAY_SEQ）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CLICK_EVENT;
create temporary table T_GPVT.VT_CLICK_EVENT
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`EVENT_ID` BIGINT COMMENT '点击事件主键ID' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`CM_ID` STRING COMMENT '点击人' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '点击人一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '点击人网点号' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`CRON_TASK_ID` STRING COMMENT '定时任务ID' -- --
    ,`CUSTOMER_ID` STRING COMMENT '客户唯一标识' -- --
    ,`EVENT_TYPE` STRING COMMENT '事件类型：button_click/preview_view' -- --
    ,`TEMPLATE_TYPE` STRING COMMENT '模板类型：main/sub' -- --
    ,`BUTTON_TYPE` STRING COMMENT '按钮类型：insight/phone/other' -- --
)
COMMENT '客户点击基础集合'

;
insert overwrite table T_GPVT.VT_CLICK_EVENT
    select
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.ID as EVENT_ID    ---- 点击事件主键ID ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,coalesce(R.FRS_BBK_ORG_ID, '') as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,coalesce(R.BRN_ORG_ID, '') as BRN_ORG_ID    ---- 点击人网点号 ----
,C.TRACE_ID as TRACE_ID    ---- trace_id ----
,C.CRON_TASK_ID as CRON_TASK_ID    ---- 定时任务ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
FROM R_RAW_VC.NLQ13_SWE_HTML_PREVIEW_CLICK_EVENTS as C
JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = C.CM_ID
JOIN T_GPVT.VT_CALENDAR as CAL
ON  substr(C.CLICKED_AT, 1, 10) >= concat(substr(CAL.REPLAY_DT, 1, 7), '-01')
AND substr(C.CLICKED_AT, 1, 10) <= '${hivevar:INPUT_DATE}'
WHERE  C.TRACE_ID is not null
AND C.TRACE_ID <> ''
AND C.CUSTOMER_ID is not null
AND C.CUSTOMER_ID <> ''
AND (
        (C.EVENT_TYPE = 'preview_view' and C.TEMPLATE_TYPE = 'sub')
        or (C.EVENT_TYPE = 'button_click' and C.BUTTON_TYPE in ('insight', 'phone'))
    )
;


-- -----------------------------------------------------------------------------
-- 2.13 推送类点击（接口 click_push）
--     条件：点击的 trace 有执行记录、执行所属任务就是点击带的任务ID、任务合规（未删除
--           且绑定技能）、且同 trace 有子任务
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CLICK_PUSH;
create temporary table T_GPVT.VT_CLICK_PUSH
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`EVENT_ID` BIGINT COMMENT '点击事件主键ID' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`CM_ID` STRING COMMENT '点击人' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '点击人一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '点击人网点号' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`CRON_TASK_ID` STRING COMMENT '定时任务ID' -- --
    ,`CUSTOMER_ID` STRING COMMENT '客户唯一标识' -- --
    ,`EVENT_TYPE` STRING COMMENT '事件类型' -- --
    ,`TEMPLATE_TYPE` STRING COMMENT '模板类型' -- --
    ,`BUTTON_TYPE` STRING COMMENT '按钮类型' -- --
)
COMMENT '推送类点击'

;
insert overwrite table T_GPVT.VT_CLICK_PUSH
    select distinct
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,C.BRN_ORG_ID as BRN_ORG_ID    ---- 点击人网点号 ----
,C.TRACE_ID as TRACE_ID    ---- trace_id ----
,C.CRON_TASK_ID as CRON_TASK_ID    ---- 定时任务ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
FROM T_GPVT.VT_CLICK_EVENT as C
JOIN R_RAW_VC.NLQ13_SWE_CRON_EXECUTIONS as E
ON  E.TRACE_ID = C.TRACE_ID
JOIN T_GPVT.VT_PUSH_JOB as J
ON  J.JOB_ID = E.JOB_ID
AND J.JOB_ID = C.CRON_TASK_ID
AND J.SOURCE_ID = C.SOURCE_ID
JOIN T_GPVT.VT_TRACE_SUB as TS
ON  TS.TRACE_ID = C.TRACE_ID
;


-- -----------------------------------------------------------------------------
-- 2.14 推送类点击的事件ID（用于把同一事件从主动类型里排除，两类互斥）
--      同一事件的任务类型归属与重跑日无关，因此只按 EVENT_ID 去重即可
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CLICK_PUSH_KEY;
create temporary table T_GPVT.VT_CLICK_PUSH_KEY
(
    `EVENT_ID` BIGINT COMMENT '点击事件主键ID' -- --
)
COMMENT '推送类点击事件ID'

;
insert overwrite table T_GPVT.VT_CLICK_PUSH_KEY
    select distinct
C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
FROM T_GPVT.VT_CLICK_PUSH as C
;


-- -----------------------------------------------------------------------------
-- 2.15 主动类点击（接口 click_ask）
--     条件：点击的 source + trace 命中合格主动提问 Span，且该 Span 技能在统计目录内
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CLICK_ASK;
create temporary table T_GPVT.VT_CLICK_ASK
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`EVENT_ID` BIGINT COMMENT '点击事件主键ID' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`CM_ID` STRING COMMENT '点击人' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '点击人一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '点击人网点号' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`CRON_TASK_ID` STRING COMMENT '定时任务ID' -- --
    ,`CUSTOMER_ID` STRING COMMENT '客户唯一标识' -- --
    ,`EVENT_TYPE` STRING COMMENT '事件类型' -- --
    ,`TEMPLATE_TYPE` STRING COMMENT '模板类型' -- --
    ,`BUTTON_TYPE` STRING COMMENT '按钮类型' -- --
)
COMMENT '主动类点击'

;
insert overwrite table T_GPVT.VT_CLICK_ASK
    select distinct
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,C.BRN_ORG_ID as BRN_ORG_ID    ---- 点击人网点号 ----
,C.TRACE_ID as TRACE_ID    ---- trace_id ----
,C.CRON_TASK_ID as CRON_TASK_ID    ---- 定时任务ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
FROM T_GPVT.VT_CLICK_EVENT as C
JOIN T_GPVT.VT_ASK_SPAN as A
ON  A.SOURCE_ID = C.SOURCE_ID
AND A.TRACE_ID = C.TRACE_ID
AND A.IN_STAT_CATALOG = 1
;


-- -----------------------------------------------------------------------------
-- 2.16 点击事件的任务类型归属
--     能回溯到推送任务的是 push_plan；否则命中合格主动提问 Span 的是 ask_plan；
--     两类都不满足的点击不进统计（推送类优先，与接口 CASE WHEN click_push 一致）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CLICK_CLS;
create temporary table T_GPVT.VT_CLICK_CLS
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`EVENT_ID` BIGINT COMMENT '点击事件主键ID' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：push_plan/ask_plan' -- --
    ,`CM_ID` STRING COMMENT '点击人' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '点击人一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '点击人网点号' -- --
    ,`TRACE_ID` STRING COMMENT 'trace_id' -- --
    ,`CRON_TASK_ID` STRING COMMENT '定时任务ID' -- --
    ,`CUSTOMER_ID` STRING COMMENT '客户唯一标识' -- --
    ,`EVENT_TYPE` STRING COMMENT '事件类型' -- --
    ,`TEMPLATE_TYPE` STRING COMMENT '模板类型' -- --
    ,`BUTTON_TYPE` STRING COMMENT '按钮类型' -- --
)
COMMENT '点击事件（已判定任务类型）'

;
insert overwrite table T_GPVT.VT_CLICK_CLS
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'push_plan' as JOB_TYPE    ---- 任务类型 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,C.BRN_ORG_ID as BRN_ORG_ID    ---- 点击人网点号 ----
,C.TRACE_ID as TRACE_ID    ---- trace_id ----
,C.CRON_TASK_ID as CRON_TASK_ID    ---- 定时任务ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
FROM T_GPVT.VT_CLICK_PUSH as C
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'ask_plan' as JOB_TYPE    ---- 任务类型 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,C.BRN_ORG_ID as BRN_ORG_ID    ---- 点击人网点号 ----
,C.TRACE_ID as TRACE_ID    ---- trace_id ----
,C.CRON_TASK_ID as CRON_TASK_ID    ---- 定时任务ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
FROM T_GPVT.VT_CLICK_ASK as C
LEFT OUTER JOIN T_GPVT.VT_CLICK_PUSH_KEY as PK
ON  PK.EVENT_ID = C.EVENT_ID
WHERE  PK.EVENT_ID is null
;


-- -----------------------------------------------------------------------------
-- 2.17 点击事件 × 关联技能：接口 clicks 的技能关联
--     推送点击的技能取自关联任务的统计技能；主动点击的技能取自同 source + trace 的合格
--     Span 技能；同一事件关联多个技能时分别进入各技能行（明细不可相加）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_CLICK_SKILL;
create temporary table T_GPVT.VT_CLICK_SKILL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型：push_plan/ask_plan' -- --
    ,`SKILL_ID` STRING COMMENT '技能ID' -- --
    ,`EVENT_ID` BIGINT COMMENT '点击事件主键ID' -- --
    ,`CUSTOMER_ID` STRING COMMENT '客户唯一标识' -- --
    ,`EVENT_TYPE` STRING COMMENT '事件类型' -- --
    ,`TEMPLATE_TYPE` STRING COMMENT '模板类型' -- --
    ,`BUTTON_TYPE` STRING COMMENT '按钮类型' -- --
    ,`CM_ID` STRING COMMENT '点击人' -- --
    ,`FRS_BBK_ORG_ID` STRING COMMENT '点击人一级分行号' -- --
    ,`BRN_ORG_ID` STRING COMMENT '点击人网点号' -- --
)
COMMENT '点击事件×关联技能'

;
insert overwrite table T_GPVT.VT_CLICK_SKILL
    select distinct
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,J.SKILL_ID as SKILL_ID    ---- 技能ID ----
,C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,C.BRN_ORG_ID as BRN_ORG_ID    ---- 点击人网点号 ----
FROM T_GPVT.VT_CLICK_CLS as C
JOIN T_GPVT.VT_PUSH_JOB_SKILL as J
ON  J.JOB_ID = C.CRON_TASK_ID
AND J.SOURCE_ID = C.SOURCE_ID
WHERE  C.JOB_TYPE = 'push_plan'
union all
    select distinct
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,A.SKILL_ID as SKILL_ID    ---- 技能ID ----
,C.EVENT_ID as EVENT_ID    ---- 点击事件主键ID ----
,C.CUSTOMER_ID as CUSTOMER_ID    ---- 客户唯一标识 ----
,C.EVENT_TYPE as EVENT_TYPE    ---- 事件类型 ----
,C.TEMPLATE_TYPE as TEMPLATE_TYPE    ---- 模板类型 ----
,C.BUTTON_TYPE as BUTTON_TYPE    ---- 按钮类型 ----
,C.CM_ID as CM_ID    ---- 点击人 ----
,C.FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 点击人一级分行号 ----
,C.BRN_ORG_ID as BRN_ORG_ID    ---- 点击人网点号 ----
FROM T_GPVT.VT_CLICK_CLS as C
JOIN T_GPVT.VT_ASK_SPAN as A
ON  A.SOURCE_ID = C.SOURCE_ID
AND A.TRACE_ID = C.TRACE_ID
AND A.IN_STAT_CATALOG = 1
WHERE  C.JOB_TYPE = 'ask_plan'
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
drop table if exists T_GPVT.VT_METRIC_FACT;
create temporary table T_GPVT.VT_METRIC_FACT
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_CM_ID` STRING COMMENT '客户经理编号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`METRIC_NM` STRING COMMENT '指标名' -- --
    ,`METRIC_KEY` STRING COMMENT '该指标的计数键' -- --
    ,`SKILL_IN_CATALOG` INT COMMENT '技能是否在统计目录内：1=在目录' -- --
)
COMMENT '任务类型报表指标长表'

;
insert overwrite table T_GPVT.VT_METRIC_FACT
    select
E.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,E.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,E.EXEC_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,E.EXEC_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,E.SKILL_ID as K_SKILL    ---- 技能ID ----
,E.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'SKILL_CNT' as METRIC_NM    ---- 技能数 ----
,E.SKILL_ID as METRIC_KEY    ---- 计数键：技能ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_EXEC_SKILL as E
WHERE  E.EXEC_IN_ROSTER = 1
union all
    select
E.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,E.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,E.EXEC_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,E.EXEC_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,E.SKILL_ID as K_SKILL    ---- 技能ID ----
,E.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'SUC_EXECUTE_JOB' as METRIC_NM    ---- 成功执行任务数 ----
,E.EXEC_ID as METRIC_KEY    ---- 计数键：执行记录ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_EXEC_SKILL as E
WHERE  E.EXEC_IN_ROSTER = 1
AND E.SUC_FLAG = 1
union all
    select
E.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,E.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,E.EXEC_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,E.EXEC_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,E.SKILL_ID as K_SKILL    ---- 技能ID ----
,E.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'READ_TASKS' as METRIC_NM    ---- 已查看任务数 ----
,E.EXEC_ID as METRIC_KEY    ---- 计数键：执行记录ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_EXEC_SKILL as E
WHERE  E.EXEC_IN_ROSTER = 1
AND E.READ_FLAG = 1
union all
    select
E.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,E.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,E.OWNER_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号（任务归属人） ----
,E.OWNER_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号（任务归属人） ----
,E.OWNER_CM_ID as K_CM_ID    ---- 客户经理编号（任务归属人） ----
,E.SKILL_ID as K_SKILL    ---- 技能ID ----
,E.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'ACTIVE_MANAGER_CNT' as METRIC_NM    ---- 活跃客户经理数 ----
,E.OWNER_CM_ID as METRIC_KEY    ---- 计数键：任务归属人 ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_EXEC_SKILL as E
WHERE  E.OWNER_IN_ROSTER = 1
AND E.JOB_STATUS = 'active'
union all
    select
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号（任务归属人） ----
,R.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号（任务归属人） ----
,J.OWNER_CM_ID as K_CM_ID    ---- 客户经理编号（任务归属人） ----
,J.SKILL_ID as K_SKILL    ---- 技能ID ----
,'push_plan' as JOB_TYPE    ---- 任务类型 ----
,'ACTIVE_JOB_CNT' as METRIC_NM    ---- 当前活跃任务数 ----
,J.JOB_ID as METRIC_KEY    ---- 计数键：任务ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_JOB_SKILL as J
JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = J.OWNER_CM_ID
JOIN T_GPVT.VT_CALENDAR as CAL
ON  1 = 1
WHERE  J.JOB_STATUS = 'active'
union all
    select
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号（任务归属人） ----
,R.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号（任务归属人） ----
,J.OWNER_CM_ID as K_CM_ID    ---- 客户经理编号（任务归属人） ----
,J.SKILL_ID as K_SKILL    ---- 技能ID ----
,'push_other' as JOB_TYPE    ---- 任务类型 ----
,'ACTIVE_JOB_CNT' as METRIC_NM    ---- 当前活跃任务数 ----
,J.JOB_ID as METRIC_KEY    ---- 计数键：任务ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_JOB_SKILL as J
JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = J.OWNER_CM_ID
JOIN T_GPVT.VT_CALENDAR as CAL
ON  1 = 1
WHERE  J.JOB_STATUS = 'active'
union all
    select
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号（任务归属人） ----
,R.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号（任务归属人） ----
,J.OWNER_CM_ID as K_CM_ID    ---- 客户经理编号（任务归属人） ----
,J.SKILL_ID as K_SKILL    ---- 技能ID ----
,'push_plan' as JOB_TYPE    ---- 任务类型 ----
,'PAUSED_JOB_CNT' as METRIC_NM    ---- 当前暂停任务数 ----
,J.JOB_ID as METRIC_KEY    ---- 计数键：任务ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_JOB_SKILL as J
JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = J.OWNER_CM_ID
JOIN T_GPVT.VT_CALENDAR as CAL
ON  1 = 1
WHERE  J.JOB_STATUS = 'paused'
union all
    select
CAL.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,J.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,R.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号（任务归属人） ----
,R.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号（任务归属人） ----
,J.OWNER_CM_ID as K_CM_ID    ---- 客户经理编号（任务归属人） ----
,J.SKILL_ID as K_SKILL    ---- 技能ID ----
,'push_other' as JOB_TYPE    ---- 任务类型 ----
,'PAUSED_JOB_CNT' as METRIC_NM    ---- 当前暂停任务数 ----
,J.JOB_ID as METRIC_KEY    ---- 计数键：任务ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_JOB_SKILL as J
JOIN T_GPVT.VT_JKH_ROSTER as R
ON  R.CM_ID = J.OWNER_CM_ID
JOIN T_GPVT.VT_CALENDAR as CAL
ON  1 = 1
WHERE  J.JOB_STATUS = 'paused'
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.EXEC_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,C.EXEC_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,C.EXEC_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,C.SKILL_ID as K_SKILL    ---- 技能ID ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'RECOMMENDED_CUSTOMERS' as METRIC_NM    ---- 方案客户数 ----
,C.CUSTUID as METRIC_KEY    ---- 计数键：客户UID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_PUSH_CUST as C
union all
    select
A.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,A.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,A.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,A.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,A.SKILL_ID as K_SKILL    ---- 技能ID ----
,A.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'SKILL_CNT' as METRIC_NM    ---- 技能数 ----
,A.SKILL_ID as METRIC_KEY    ---- 计数键：技能ID ----
,A.IN_STAT_CATALOG as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_ASK_TRACE as A
WHERE  A.IN_STAT_CATALOG = 1
union all
    select
A.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,A.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,A.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,A.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,A.SKILL_ID as K_SKILL    ---- 技能ID ----
,A.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'SUC_EXECUTE_JOB' as METRIC_NM    ---- 成功执行任务数 ----
,A.TRACE_ID as METRIC_KEY    ---- 计数键：trace_id ----
,A.IN_STAT_CATALOG as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_ASK_TRACE as A
union all
    select
A.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,A.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,A.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,A.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,A.SKILL_ID as K_SKILL    ---- 技能ID ----
,A.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'READ_TASKS' as METRIC_NM    ---- 已查看任务数（等于成功数） ----
,A.TRACE_ID as METRIC_KEY    ---- 计数键：trace_id ----
,A.IN_STAT_CATALOG as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_ASK_TRACE as A
union all
    select
A.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,A.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,A.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,A.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,A.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,A.SKILL_ID as K_SKILL    ---- 技能ID ----
,A.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'RECOMMENDED_CUSTOMERS' as METRIC_NM    ---- 方案客户数 ----
,A.CUSTUID as METRIC_KEY    ---- 计数键：客户UID ----
,A.IN_STAT_CATALOG as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_ASK_CUST as A
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,C.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,C.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,C.SKILL_ID as K_SKILL    ---- 技能ID ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'READ_CUSTOMER_CNT' as METRIC_NM    ---- 已查看方案客户数 ----
,C.CUSTOMER_ID as METRIC_KEY    ---- 计数键：客户ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_CLICK_SKILL as C
WHERE  C.EVENT_TYPE = 'preview_view'
AND C.TEMPLATE_TYPE = 'sub'
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,C.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,C.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,C.SKILL_ID as K_SKILL    ---- 技能ID ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'INSIGHT_CUSTOMER_CNT' as METRIC_NM    ---- 洞察客户数 ----
,C.CUSTOMER_ID as METRIC_KEY    ---- 计数键：客户ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_CLICK_SKILL as C
WHERE  C.EVENT_TYPE = 'button_click'
AND C.BUTTON_TYPE = 'insight'
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,C.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,C.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,C.SKILL_ID as K_SKILL    ---- 技能ID ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'INSIGHT_CNT' as METRIC_NM    ---- 点击客户洞察总次数 ----
,cast(C.EVENT_ID as string) as METRIC_KEY    ---- 计数键：事件ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_CLICK_SKILL as C
WHERE  C.EVENT_TYPE = 'button_click'
AND C.BUTTON_TYPE = 'insight'
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,C.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,C.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,C.SKILL_ID as K_SKILL    ---- 技能ID ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'PHONE_CUSTOMER_CNT' as METRIC_NM    ---- 电访客户数 ----
,C.CUSTOMER_ID as METRIC_KEY    ---- 计数键：客户ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_CLICK_SKILL as C
WHERE  C.EVENT_TYPE = 'button_click'
AND C.BUTTON_TYPE = 'phone'
union all
    select
C.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,C.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,C.FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,C.BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,C.CM_ID as K_CM_ID    ---- 客户经理编号 ----
,C.SKILL_ID as K_SKILL    ---- 技能ID ----
,C.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,'PHONE_CNT' as METRIC_NM    ---- 点击去电访总次数 ----
,cast(C.EVENT_ID as string) as METRIC_KEY    ---- 计数键：事件ID ----
,1 as SKILL_IN_CATALOG    ---- 技能在统计目录内 ----
FROM T_GPVT.VT_CLICK_SKILL as C
WHERE  C.EVENT_TYPE = 'button_click'
AND C.BUTTON_TYPE = 'phone'
;


-- =============================================================================
-- 4. 组合骨架（每种报表组合各自的维度对象）
--    汇总组合取所有事实的维度并集（点击、任务归属人的活跃/暂停任务也算事实）；
--    技能明细组合只取任务级事实且技能在统计目录内，(分行,网点,经理,技能) 只保留期间
--    真正有任务的组合，不给纯目录技能、纯点击技能建行。
--    所有骨架都带 REPLAY_SEQ，即每个重跑日各出一套维度对象。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 总体骨架（group_by=overall）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_OVERALL;
create temporary table T_GPVT.VT_SKEL_OVERALL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
)
COMMENT '总体维度骨架'

;
insert overwrite table T_GPVT.VT_SKEL_OVERALL
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
FROM T_GPVT.VT_METRIC_FACT as F
WHERE  F.METRIC_NM not in ('ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.2 分行骨架（group_by=branch）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_BRANCH;
create temporary table T_GPVT.VT_SKEL_BRANCH
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
)
COMMENT '分行维度骨架'

;
insert overwrite table T_GPVT.VT_SKEL_BRANCH
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
FROM T_GPVT.VT_METRIC_FACT as F
WHERE  F.METRIC_NM not in ('ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.3 支行骨架（group_by=org）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_ORG;
create temporary table T_GPVT.VT_SKEL_ORG
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
)
COMMENT '支行维度骨架'

;
insert overwrite table T_GPVT.VT_SKEL_ORG
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,F.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
FROM T_GPVT.VT_METRIC_FACT as F
WHERE  F.METRIC_NM not in ('ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.4 客户经理骨架（group_by=manager）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_MANAGER;
create temporary table T_GPVT.VT_SKEL_MANAGER
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_CM_ID` STRING COMMENT '客户经理编号' -- --
)
COMMENT '客户经理维度骨架'

;
insert overwrite table T_GPVT.VT_SKEL_MANAGER
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,F.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,F.K_CM_ID as K_CM_ID    ---- 客户经理编号 ----
FROM T_GPVT.VT_METRIC_FACT as F
;


-- -----------------------------------------------------------------------------
-- 4.5 分行 + 技能明细骨架（group_by=branch, skill_detail=true）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_BRANCH_SKL;
create temporary table T_GPVT.VT_SKEL_BRANCH_SKL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
)
COMMENT '分行技能明细骨架'

;
insert overwrite table T_GPVT.VT_SKEL_BRANCH_SKL
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,F.K_SKILL as K_SKILL    ---- 技能ID ----
FROM T_GPVT.VT_METRIC_FACT as F
WHERE  F.SKILL_IN_CATALOG = 1
AND F.METRIC_NM not in ('READ_CUSTOMER_CNT', 'INSIGHT_CUSTOMER_CNT', 'INSIGHT_CNT', 'PHONE_CUSTOMER_CNT', 'PHONE_CNT', 'ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.6 支行 + 技能明细骨架（group_by=org, skill_detail=true）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_ORG_SKL;
create temporary table T_GPVT.VT_SKEL_ORG_SKL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
)
COMMENT '支行技能明细骨架'

;
insert overwrite table T_GPVT.VT_SKEL_ORG_SKL
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,F.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,F.K_SKILL as K_SKILL    ---- 技能ID ----
FROM T_GPVT.VT_METRIC_FACT as F
WHERE  F.SKILL_IN_CATALOG = 1
AND F.METRIC_NM not in ('READ_CUSTOMER_CNT', 'INSIGHT_CUSTOMER_CNT', 'INSIGHT_CNT', 'PHONE_CUSTOMER_CNT', 'PHONE_CNT', 'ACTIVE_JOB_CNT', 'PAUSED_JOB_CNT')
;


-- -----------------------------------------------------------------------------
-- 4.7 客户经理 + 技能明细骨架（group_by=manager, skill_detail=true）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_SKEL_MANAGER_SKL;
create temporary table T_GPVT.VT_SKEL_MANAGER_SKL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_CM_ID` STRING COMMENT '客户经理编号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
)
COMMENT '客户经理技能明细骨架'

;
insert overwrite table T_GPVT.VT_SKEL_MANAGER_SKL
    select distinct
F.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,F.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,F.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,F.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,F.K_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,F.K_SKILL as K_SKILL    ---- 技能ID ----
FROM T_GPVT.VT_METRIC_FACT as F
WHERE  F.SKILL_IN_CATALOG = 1
AND F.METRIC_NM not in ('READ_CUSTOMER_CNT', 'INSIGHT_CUSTOMER_CNT', 'INSIGHT_CNT', 'PHONE_CUSTOMER_CNT', 'PHONE_CNT')
;


-- =============================================================================
-- 5. 组合宽表（每种组合的指标汇总，并把该任务类型天然不产出的列置 NULL）
--    骨架 × 任务类型字典 左连指标长表：每个维度对象都补齐三类任务，指标全零也保留；
--    维度对象只来自骨架，所以没有期间事实的机构/经理/技能不会出数。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 总体汇总（RPT_COMBO = 'overall'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_OVERALL;
create temporary table T_GPVT.VT_RPT_OVERALL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '总体汇总指标'

;
insert overwrite table T_GPVT.VT_RPT_OVERALL
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,cast(null as bigint) as ACTIVE_JOB_CNT    ---- 当前活跃任务数（仅客户经理维度使用） ----
,cast(null as bigint) as PAUSED_JOB_CNT    ---- 当前暂停任务数（仅客户经理维度使用） ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_OVERALL as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.2 分行汇总（RPT_COMBO = 'branch'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_BRANCH;
create temporary table T_GPVT.VT_RPT_BRANCH
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '分行汇总指标'

;
insert overwrite table T_GPVT.VT_RPT_BRANCH
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,cast(null as bigint) as ACTIVE_JOB_CNT    ---- 当前活跃任务数（仅客户经理维度使用） ----
,cast(null as bigint) as PAUSED_JOB_CNT    ---- 当前暂停任务数（仅客户经理维度使用） ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_BRANCH as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, D.K_FRS_BBK_ORG_ID
, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.3 支行汇总（RPT_COMBO = 'org'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_ORG;
create temporary table T_GPVT.VT_RPT_ORG
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '支行汇总指标'

;
insert overwrite table T_GPVT.VT_RPT_ORG
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,D.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,cast(null as bigint) as ACTIVE_JOB_CNT    ---- 当前活跃任务数（仅客户经理维度使用） ----
,cast(null as bigint) as PAUSED_JOB_CNT    ---- 当前暂停任务数（仅客户经理维度使用） ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_ORG as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
AND F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, D.K_FRS_BBK_ORG_ID
, D.K_BRN_ORG_ID
, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.4 客户经理汇总（RPT_COMBO = 'manager'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_MANAGER;
create temporary table T_GPVT.VT_RPT_MANAGER
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_CM_ID` STRING COMMENT '客户经理编号' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '客户经理汇总指标'

;
insert overwrite table T_GPVT.VT_RPT_MANAGER
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,D.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,D.K_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,cast(null as bigint) as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数（仅总体/分行/支行维度使用） ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_JOB_CNT' then F.METRIC_KEY end) end as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PAUSED_JOB_CNT' then F.METRIC_KEY end) end as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_MANAGER as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
AND F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
AND F.K_CM_ID = D.K_CM_ID
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, D.K_FRS_BBK_ORG_ID
, D.K_BRN_ORG_ID
, D.K_CM_ID
, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.5 分行 + 技能明细（RPT_COMBO = 'branch_skill'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_BRANCH_SKL;
create temporary table T_GPVT.VT_RPT_BRANCH_SKL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '分行技能明细指标'

;
insert overwrite table T_GPVT.VT_RPT_BRANCH_SKL
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,D.K_SKILL as K_SKILL    ---- 技能ID ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,cast(null as bigint) as ACTIVE_JOB_CNT    ---- 当前活跃任务数（仅客户经理维度使用） ----
,cast(null as bigint) as PAUSED_JOB_CNT    ---- 当前暂停任务数（仅客户经理维度使用） ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_BRANCH_SKL as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
AND F.K_SKILL = D.K_SKILL
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, D.K_FRS_BBK_ORG_ID
, D.K_SKILL
, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.6 支行 + 技能明细（RPT_COMBO = 'org_skill'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_ORG_SKL;
create temporary table T_GPVT.VT_RPT_ORG_SKL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '支行技能明细指标'

;
insert overwrite table T_GPVT.VT_RPT_ORG_SKL
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,D.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,D.K_SKILL as K_SKILL    ---- 技能ID ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_MANAGER_CNT' then F.METRIC_KEY end) end as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,cast(null as bigint) as ACTIVE_JOB_CNT    ---- 当前活跃任务数（仅客户经理维度使用） ----
,cast(null as bigint) as PAUSED_JOB_CNT    ---- 当前暂停任务数（仅客户经理维度使用） ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_ORG_SKL as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
AND F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
AND F.K_SKILL = D.K_SKILL
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, D.K_FRS_BBK_ORG_ID
, D.K_BRN_ORG_ID
, D.K_SKILL
, TT.JOB_TYPE
;


-- -----------------------------------------------------------------------------
-- 5.7 客户经理 + 技能明细（RPT_COMBO = 'manager_skill'）
-- -----------------------------------------------------------------------------
drop table if exists T_GPVT.VT_RPT_MANAGER_SKL;
create temporary table T_GPVT.VT_RPT_MANAGER_SKL
(
    `REPLAY_SEQ` INT COMMENT '重跑序号，见第 1.0 段日历' -- --
    ,`SOURCE_ID` STRING COMMENT '来源标识' -- --
    ,`K_FRS_BBK_ORG_ID` STRING COMMENT '一级分行号' -- --
    ,`K_BRN_ORG_ID` STRING COMMENT '网点号' -- --
    ,`K_CM_ID` STRING COMMENT '客户经理编号' -- --
    ,`K_SKILL` STRING COMMENT '技能ID' -- --
    ,`JOB_TYPE` STRING COMMENT '任务类型' -- --
    ,`SKILL_CNT` BIGINT COMMENT '技能数' -- --
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数（总体/分行/支行维度使用）' -- --
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active，仅客户经理维度使用）' -- --
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度使用）' -- --
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数' -- --
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数' -- --
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数' -- --
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数' -- --
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数' -- --
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数' -- --
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数' -- --
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数' -- --
)
COMMENT '客户经理技能明细指标'

;
insert overwrite table T_GPVT.VT_RPT_MANAGER_SKL
    select
D.REPLAY_SEQ as REPLAY_SEQ    ---- 重跑序号 ----
,D.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,D.K_FRS_BBK_ORG_ID as K_FRS_BBK_ORG_ID    ---- 一级分行号 ----
,D.K_BRN_ORG_ID as K_BRN_ORG_ID    ---- 网点号 ----
,D.K_CM_ID as K_CM_ID    ---- 客户经理编号 ----
,D.K_SKILL as K_SKILL    ---- 技能ID ----
,TT.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,count(distinct case when F.METRIC_NM = 'SKILL_CNT' then F.METRIC_KEY end) as SKILL_CNT    ---- 技能数 ----
,cast(null as bigint) as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数（仅总体/分行/支行维度使用） ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'ACTIVE_JOB_CNT' then F.METRIC_KEY end) end as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,case when TT.JOB_TYPE = 'ask_plan' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PAUSED_JOB_CNT' then F.METRIC_KEY end) end as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,count(distinct case when F.METRIC_NM = 'SUC_EXECUTE_JOB' then F.METRIC_KEY end) as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,count(distinct case when F.METRIC_NM = 'READ_TASKS' then F.METRIC_KEY end) as READ_TASKS    ---- 已查看任务数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'RECOMMENDED_CUSTOMERS' then F.METRIC_KEY end) end as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'READ_CUSTOMER_CNT' then F.METRIC_KEY end) end as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CUSTOMER_CNT' then F.METRIC_KEY end) end as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'INSIGHT_CNT' then F.METRIC_KEY end) end as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CUSTOMER_CNT' then F.METRIC_KEY end) end as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,case when TT.JOB_TYPE = 'push_other' then cast(null as bigint) else count(distinct case when F.METRIC_NM = 'PHONE_CNT' then F.METRIC_KEY end) end as PHONE_CNT    ---- 点击去电访总次数 ----
FROM T_GPVT.VT_SKEL_MANAGER_SKL as D
JOIN T_GPVT.VT_TASK_TYPE as TT
ON  1 = 1
LEFT OUTER JOIN T_GPVT.VT_METRIC_FACT as F
ON  F.SOURCE_ID = D.SOURCE_ID
AND F.REPLAY_SEQ = D.REPLAY_SEQ
AND F.K_FRS_BBK_ORG_ID = D.K_FRS_BBK_ORG_ID
AND F.K_BRN_ORG_ID = D.K_BRN_ORG_ID
AND F.K_CM_ID = D.K_CM_ID
AND F.K_SKILL = D.K_SKILL
AND F.JOB_TYPE = TT.JOB_TYPE
GROUP BY D.REPLAY_SEQ
, D.SOURCE_ID
, D.K_FRS_BBK_ORG_ID
, D.K_BRN_ORG_ID
, D.K_CM_ID
, D.K_SKILL
, TT.JOB_TYPE
;


-- =============================================================================
-- 6. 报表落数（七种组合落同一张表，用 RPT_COMBO 区分）
--    写入方式：每条语句按 REPLAY_SEQ 关联第 1.0 段日历，用动态分区一次写 8 个日期；
--    第一条 insert overwrite 重建这 8 个分区，其余六条 insert into 追加组合行，
--    因此重跑幂等；若某条失败导致分区不完整，重跑整个脚本即可。
--    维度规则：本组合用不到的维度列写 'ALL'（不再写 NULL），消费方按 'ALL' 判断“不适用”；
--    分区的 PRT_DT 取自日历，同一行数据的统计区间是「重跑日所在月 1 号 ~ 重跑日」。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 总体汇总（RPT_COMBO = 'overall'）
-- -----------------------------------------------------------------------------
insert overwrite table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'overall' as RPT_COMBO    ---- 报表组合 ----
,'ALL' as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,'ALL' as FIRST_BBK_NM    ---- 一级分行名称 ----
,'ALL' as BRN_ORG_ID    ---- 网点号 ----
,'ALL' as ORG_NM    ---- 网点名称 ----
,'ALL' as CM_ID    ---- 客户经理编号 ----
,'ALL' as USER_NAME    ---- 客户经理姓名 ----
,'ALL' as PST_LVL    ---- 岗位定级 ----
,'ALL' as SKILL_ID    ---- 技能ID ----
,'ALL' as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_OVERALL as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
;


-- -----------------------------------------------------------------------------
-- 6.2 分行汇总（RPT_COMBO = 'branch'）
-- -----------------------------------------------------------------------------
insert into table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'branch' as RPT_COMBO    ---- 报表组合 ----
,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,NB.BBK_ORG_NM as FIRST_BBK_NM    ---- 一级分行名称 ----
,'ALL' as BRN_ORG_ID    ---- 网点号 ----
,'ALL' as ORG_NM    ---- 网点名称 ----
,'ALL' as CM_ID    ---- 客户经理编号 ----
,'ALL' as USER_NAME    ---- 客户经理姓名 ----
,'ALL' as PST_LVL    ---- 岗位定级 ----
,'ALL' as SKILL_ID    ---- 技能ID ----
,'ALL' as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_BRANCH as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
LEFT OUTER JOIN T_GPVT.VT_BBK_NAME as NB
ON  NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
;


-- -----------------------------------------------------------------------------
-- 6.3 支行汇总（RPT_COMBO = 'org'）
-- -----------------------------------------------------------------------------
insert into table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'org' as RPT_COMBO    ---- 报表组合 ----
,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,NB.BBK_ORG_NM as FIRST_BBK_NM    ---- 一级分行名称 ----
,R.K_BRN_ORG_ID as BRN_ORG_ID    ---- 网点号 ----
,NO.BRN_ORG_NM as ORG_NM    ---- 网点名称 ----
,'ALL' as CM_ID    ---- 客户经理编号 ----
,'ALL' as USER_NAME    ---- 客户经理姓名 ----
,'ALL' as PST_LVL    ---- 岗位定级 ----
,'ALL' as SKILL_ID    ---- 技能ID ----
,'ALL' as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_ORG as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
LEFT OUTER JOIN T_GPVT.VT_BBK_NAME as NB
ON  NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_ORG_NAME as NO
ON  NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
AND NO.BRN_ORG_ID = R.K_BRN_ORG_ID
;


-- -----------------------------------------------------------------------------
-- 6.4 客户经理汇总（RPT_COMBO = 'manager'）
-- -----------------------------------------------------------------------------
insert into table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'manager' as RPT_COMBO    ---- 报表组合 ----
,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,NB.BBK_ORG_NM as FIRST_BBK_NM    ---- 一级分行名称 ----
,R.K_BRN_ORG_ID as BRN_ORG_ID    ---- 网点号 ----
,NO.BRN_ORG_NM as ORG_NM    ---- 网点名称 ----
,R.K_CM_ID as CM_ID    ---- 客户经理编号 ----
,RK.USER_NAME as USER_NAME    ---- 客户经理姓名 ----
,RK.PST_LVL as PST_LVL    ---- 岗位定级 ----
,'ALL' as SKILL_ID    ---- 技能ID ----
,'ALL' as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_MANAGER as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
LEFT OUTER JOIN T_GPVT.VT_BBK_NAME as NB
ON  NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_ORG_NAME as NO
ON  NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
AND NO.BRN_ORG_ID = R.K_BRN_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_JKH_ROSTER as RK
ON  RK.CM_ID = R.K_CM_ID
;


-- -----------------------------------------------------------------------------
-- 6.5 分行 + 技能明细（RPT_COMBO = 'branch_skill'）
-- -----------------------------------------------------------------------------
insert into table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'branch_skill' as RPT_COMBO    ---- 报表组合 ----
,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,NB.BBK_ORG_NM as FIRST_BBK_NM    ---- 一级分行名称 ----
,'ALL' as BRN_ORG_ID    ---- 网点号 ----
,'ALL' as ORG_NM    ---- 网点名称 ----
,'ALL' as CM_ID    ---- 客户经理编号 ----
,'ALL' as USER_NAME    ---- 客户经理姓名 ----
,'ALL' as PST_LVL    ---- 岗位定级 ----
,R.K_SKILL as SKILL_ID    ---- 技能ID ----
,NK.CN_NAME as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_BRANCH_SKL as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
LEFT OUTER JOIN T_GPVT.VT_BBK_NAME as NB
ON  NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_SKILL_CATALOG as NK
ON  NK.SOURCE_ID = R.SOURCE_ID
AND NK.SKILL_ID = R.K_SKILL
;


-- -----------------------------------------------------------------------------
-- 6.6 支行 + 技能明细（RPT_COMBO = 'org_skill'）
-- -----------------------------------------------------------------------------
insert into table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'org_skill' as RPT_COMBO    ---- 报表组合 ----
,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,NB.BBK_ORG_NM as FIRST_BBK_NM    ---- 一级分行名称 ----
,R.K_BRN_ORG_ID as BRN_ORG_ID    ---- 网点号 ----
,NO.BRN_ORG_NM as ORG_NM    ---- 网点名称 ----
,'ALL' as CM_ID    ---- 客户经理编号 ----
,'ALL' as USER_NAME    ---- 客户经理姓名 ----
,'ALL' as PST_LVL    ---- 岗位定级 ----
,R.K_SKILL as SKILL_ID    ---- 技能ID ----
,NK.CN_NAME as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_ORG_SKL as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
LEFT OUTER JOIN T_GPVT.VT_BBK_NAME as NB
ON  NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_ORG_NAME as NO
ON  NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
AND NO.BRN_ORG_ID = R.K_BRN_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_SKILL_CATALOG as NK
ON  NK.SOURCE_ID = R.SOURCE_ID
AND NK.SKILL_ID = R.K_SKILL
;


-- -----------------------------------------------------------------------------
-- 6.7 客户经理 + 技能明细（RPT_COMBO = 'manager_skill'）
-- -----------------------------------------------------------------------------
insert into table P_AALC.AALC_RM_TASK_TYPE_RPT partition (PRT_DT)
    select
R.SOURCE_ID as SOURCE_ID    ---- 来源标识 ----
,'manager_skill' as RPT_COMBO    ---- 报表组合 ----
,R.K_FRS_BBK_ORG_ID as FRS_BBK_ORG_ID    ---- 一级分行号 ----
,NB.BBK_ORG_NM as FIRST_BBK_NM    ---- 一级分行名称 ----
,R.K_BRN_ORG_ID as BRN_ORG_ID    ---- 网点号 ----
,NO.BRN_ORG_NM as ORG_NM    ---- 网点名称 ----
,R.K_CM_ID as CM_ID    ---- 客户经理编号 ----
,RK.USER_NAME as USER_NAME    ---- 客户经理姓名 ----
,RK.PST_LVL as PST_LVL    ---- 岗位定级 ----
,R.K_SKILL as SKILL_ID    ---- 技能ID ----
,NK.CN_NAME as CN_NAME    ---- 技能名称 ----
,R.JOB_TYPE as JOB_TYPE    ---- 任务类型 ----
,case R.JOB_TYPE when 'push_plan' then '推送(名单+方案)' when 'ask_plan' then '主动提问(名单+方案)' else '推送(非名单方案)' end as TASK_TYPE_NAME    ---- 任务类型名称 ----
,R.SKILL_CNT as SKILL_CNT    ---- 技能数 ----
,R.ACTIVE_MANAGER_CNT as ACTIVE_MANAGER_CNT    ---- 活跃客户经理数 ----
,R.ACTIVE_JOB_CNT as ACTIVE_JOB_CNT    ---- 当前活跃任务数 ----
,R.PAUSED_JOB_CNT as PAUSED_JOB_CNT    ---- 当前暂停任务数 ----
,R.SUC_EXECUTE_JOB as SUC_EXECUTE_JOB    ---- 成功执行任务数 ----
,R.READ_TASKS as READ_TASKS    ---- 已查看任务数 ----
,round(100.0 * R.READ_TASKS / R.SUC_EXECUTE_JOB, 2) as READ_RATE    ---- 任务查看率 ----
,R.RECOMMENDED_CUSTOMERS as RECOMMENDED_CUSTOMERS    ---- 方案客户数 ----
,R.READ_CUSTOMER_CNT as READ_CUSTOMER_CNT    ---- 已查看方案客户数 ----
,round(100.0 * R.READ_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as PLAN_READ_RATE    ---- 方案查看率 ----
,R.INSIGHT_CUSTOMER_CNT as INSIGHT_CUSTOMER_CNT    ---- 洞察客户数 ----
,round(100.0 * R.INSIGHT_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_INSIGHT_RATE    ---- 洞察覆盖率 ----
,R.INSIGHT_CNT as INSIGHT_CNT    ---- 点击客户洞察总次数 ----
,R.PHONE_CUSTOMER_CNT as PHONE_CUSTOMER_CNT    ---- 电访客户数 ----
,round(100.0 * R.PHONE_CUSTOMER_CNT / R.RECOMMENDED_CUSTOMERS, 2) as CLICK_TO_PHONE_RATE    ---- 电访覆盖率 ----
,R.PHONE_CNT as PHONE_CNT    ---- 点击去电访总次数 ----
,concat(substr(CAL.REPLAY_DT, 1, 7), '-01') as STAT_START_DT    ---- 统计区间起始日 ----
,CAL.REPLAY_DT as STAT_END_DT    ---- 统计区间截止日 ----
,CAL.REPLAY_DT as DW_STAT_DT    ---- 统计日期 ----
,CAL.REPLAY_DT as PRT_DT    ---- 分区（重跑日期） ----
FROM T_GPVT.VT_RPT_MANAGER_SKL as R
JOIN T_GPVT.VT_CALENDAR as CAL
ON  CAL.REPLAY_SEQ = R.REPLAY_SEQ
LEFT OUTER JOIN T_GPVT.VT_BBK_NAME as NB
ON  NB.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_ORG_NAME as NO
ON  NO.FRS_BBK_ORG_ID = R.K_FRS_BBK_ORG_ID
AND NO.BRN_ORG_ID = R.K_BRN_ORG_ID
LEFT OUTER JOIN T_GPVT.VT_JKH_ROSTER as RK
ON  RK.CM_ID = R.K_CM_ID
LEFT OUTER JOIN T_GPVT.VT_SKILL_CATALOG as NK
ON  NK.SOURCE_ID = R.SOURCE_ID
AND NK.SKILL_ID = R.K_SKILL
;
