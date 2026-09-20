-- =============================================================================
-- 金葵花任务类型报表 —— 高斯（GaussDB）目标表结构（首次部署执行一次，以后不必重复执行）
--
-- 跑数脚本：gauss/task_type_report_daily.sql
-- 口径真源：docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md、DIMENSIONS.md
-- 移植说明：gauss/README.md（与 hive/task_type_report_tables.sql 的差异）
--
-- 说明：
--   1. 七种报表组合（overall / branch / org / manager × 是否技能明细）落同一张表，
--      用 RPT_COMBO 区分，消费方必须按 DW_DAT_DT + SOURCE_ID + RPT_COMBO 过滤后再取数；
--      不同组合的行不能混用、也不能相加（技能明细各列本身也不可相加）。
--   2. DW_DAT_DT 是数据日期（分区列）：跑数脚本一次重写「跑数日期前 7 天 ~ 跑数日期」共 8 天
--      （推送当天为基线、统计推送后 7 天），每个分区重跑时整体覆盖（脚本里 delete + insert）。
--   3. 某个组合用不到的维度列写 'ALL'（不是 NULL），例如 overall 组合的
--      一级分行号/网点号/客户经理号/技能号都是 'ALL'；名单里机构号缺失才落空串 ''。
--   4. 客户经理编号列是 CM_ID，一级分行号列是 FRS_BBK_ORG_ID，网点号列是 BRN_ORG_ID，
--      任务类型列是 JOB_TYPE；名称列是 FRS_BBK_ORG_NM / BRN_ORG_NM / CM_NM / SKILL_NM /
--      JOB_TYPE_NM（与名单表字段名保持一致）。
--   5. 活跃客户经理数 ACTIVE_MANAGER_CNT 只在总体/分行/支行维度有值，客户经理维度为 NULL；
--      当前活跃/暂停任务数 ACTIVE_JOB_CNT / PAUSED_JOB_CNT 只在客户经理维度有值，其余为 NULL。
--   6. 接口侧的 permission_manager_count（有权限客户经理数）不在仓内计算，因此表中不设该字段。
--   7. 库名用 ${AALC_DATA} 占位（与调度变量一致）；表名如与分析层规范不同，改这里即可，
--      同时要改跑数脚本第 6 段的落数表名。存储格式、压缩、分区与分布键按数仓规范调整。
--   8. 统计区间不再单独落列：统计区间起点 = DW_DAT_DT 所在月 1 号，终点 = DW_DAT_DT，
--      需要时在查询里用 date_trunc('month', DW_DAT_DT) 现算。
-- =============================================================================

create table if not exists ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT    /* 金葵花任务类型报表 */
(
 DW_DAT_DT             DATE            NOT NULL    /* 数据日期（= 分区日期、统计区间截止日，yyyy-MM-dd） */
,SOURCE_ID             VARCHAR(256)    NOT NULL    /* 来源标识（X-Source-Id） */
,RPT_COMBO             VARCHAR(32)     NOT NULL    /* 报表组合：overall/branch/org/manager/branch_skill/org_skill/manager_skill */
,FRS_BBK_ORG_ID        VARCHAR(200)    NOT NULL    /* 一级分行号，不适用为 ALL */
,FRS_BBK_ORG_NM        VARCHAR(500)                /* 一级分行名称 */
,BRN_ORG_ID            VARCHAR(100)    NOT NULL    /* 网点号，不适用为 ALL */
,BRN_ORG_NM            VARCHAR(500)                /* 网点名称 */
,CM_ID                 VARCHAR(200)    NOT NULL    /* 客户经理编号（SAP号），不适用为 ALL */
,CM_NM                 VARCHAR(500)                /* 客户经理姓名 */
,PST_LVL               VARCHAR(100)                /* 岗位定级 */
,SKILL_ID              VARCHAR(512)    NOT NULL    /* 技能ID，非技能明细为 ALL */
,SKILL_NM              VARCHAR(1024)               /* 技能中文名，取不到为 NULL，消费方回退展示 SKILL_ID */
,JOB_TYPE              VARCHAR(64)     NOT NULL    /* 任务类型：push_plan/ask_plan/push_other */
,JOB_TYPE_NM           VARCHAR(64)                 /* 任务类型名称 */
,SKILL_CNT             INTEGER                     /* 技能数 skill_count */
,ACTIVE_MANAGER_CNT    INTEGER                     /* 活跃客户经理数 active_manager_count（总体/分行/支行维度） */
,ACTIVE_JOB_CNT        INTEGER                     /* 当前活跃任务数（job.status=active，仅客户经理维度） */
,PAUSED_JOB_CNT        INTEGER                     /* 当前暂停任务数（job.status=paused，仅客户经理维度） */
,SUC_EXECUTE_JOB       INTEGER                     /* 成功执行任务数 suc_execute_job */
,READ_TASKS            INTEGER                     /* 已查看任务数 read_tasks，主动提问等于成功数 */
,READ_RATE             DECIMAL(18,2)               /* 任务查看率（%），零分母为 NULL */
,RECOMMENDED_CUSTOMERS INTEGER                     /* 方案客户数 recommended_customers，推送(非名单方案)为 NULL */
,READ_CUSTOMER_CNT     INTEGER                     /* 已查看方案客户数 read_customer_count */
,PLAN_READ_RATE        DECIMAL(18,2)               /* 方案查看率（%） */
,INSIGHT_CUSTOMER_CNT  INTEGER                     /* 洞察客户数 insight_customer_count */
,CLICK_TO_INSIGHT_RATE DECIMAL(18,2)               /* 洞察覆盖率（%） */
,INSIGHT_CNT           INTEGER                     /* 点击客户洞察总次数 insight_count */
,PHONE_CUSTOMER_CNT    INTEGER                     /* 电访客户数 phone_customer_count */
,CLICK_TO_PHONE_RATE   DECIMAL(18,2)               /* 电访覆盖率（%） */
,PHONE_CNT             INTEGER                     /* 点击去电访总次数 phone_count */
)
WITH (orientation = column, colversion = 2.0, compression = middle)
DISTRIBUTE BY HASH (DW_DAT_DT, SOURCE_ID, RPT_COMBO)
PARTITION BY RANGE (DW_DAT_DT)
(
    PARTITION P_MAX VALUES LESS THAN (MAXVALUE)
)
;

-- 分区维护：上面只建了一个兜底分区（P_MAX），数据会落进去。按数仓规范按日/按月建分区时，
-- 用下面语句拆分或新增（具体语法按现场版本核对），例如按月：
--   alter table ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT add partition P202609 values less than ('2026-10-01');
-- 建议保留：当月每天的批次 + 每月最后一个跑数日的批次，其余按月清理（口径是「当月 1 号 ~ 分区日期」
-- 的累计值，同月多份会放大数据量）。

-- 消费示例（Console / 下游取数）：
--   -- 客户经理汇总：接口 group_by=manager, skill_detail=false
--   select * from ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT
--    where DW_DAT_DT = CAST('2026-09-17' AS DATE) and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager';
--
--   -- 客户经理技能明细：接口 group_by=manager, skill_detail=true（各列不可相加）
--   select * from ${AALC_DATA}.AALC_RM_TASK_TYPE_RPT
--    where DW_DAT_DT = CAST('2026-09-17' AS DATE) and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager_skill';
