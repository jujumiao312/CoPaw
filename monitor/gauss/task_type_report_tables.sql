-- =============================================================================
-- 金葵花任务类型报表 —— 高斯（GaussDB）目标表结构（现场下发版本，首次部署执行一次）
--
-- 跑数脚本：gauss/task_type_report_daily.sql
-- TDSQL 出仓：gauss/task_type_report_tdsql.sql（接口 /api/monitor/cron/report/task-type* 读它）
-- 口径真源：docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md、DIMENSIONS.md
-- 移植说明：gauss/README.md（与 hive/task_type_report_tables.sql 的差异）
--
-- 说明：
--   1. 七种报表组合（overall / branch / org / manager × 是否技能明细）落同一张表，
--      用 RPT_COMBO 区分，消费方必须按 DW_DAT_DT + SOURCE_ID + RPT_COMBO 过滤后再取数；
--      不同组合的行不能混用、也不能相加（技能明细各列本身也不可相加）。
--   2. DW_DAT_DT 是数据日期：跑数脚本一次重写「跑数日期前 7 天 ~ 跑数日期」共 8 天
--      （推送当天为基线、统计推送后 7 天），每天整体覆盖（脚本里 delete + insert）。
--      每天的行用**当天**的名单快照（重跑日 D 用 D 当天的名单）：名单归属/成员判断、
--      机构名与经理名都按该日快照取值，所以同一客户经理在不同 DW_DAT_DT 的归属可能不同；
--      名单里没有 D 当天快照时该 DW_DAT_DT 不会落任何行（跑数前 8 天分区仍会被清空）。
--   3. 某个组合用不到的维度列写 'ALL'（不是 NULL），例如 overall 组合的
--      一级分行号/网点号/客户经理号/技能号都是 'ALL'；名单里机构号缺失才落空串 ''。
--      两种值含义不同：消费方不要把 'ALL' 当真实机构号，也不要吞掉空串分组。
--   4. 客户经理编号列是 CM_ID，一级分行号列是 FRS_BBK_ORG_ID，网点号列是 BRN_ORG_ID，
--      任务类型列是 JOB_TYPE（直接存中文：推送 / 主动 / 推送非，即显示名，不再单列
--      JOB_TYPE_NM）；名称列是 FRS_BBK_ORG_NM / BRN_ORG_NM / CM_NM / SKILL_NM。
--   5. 活跃客户经理数 ACTIVE_MANAGER_CNT 只在总体/分行/支行维度有值，客户经理维度为 NULL；
--      当前活跃/暂停任务数 ACTIVE_JOB_CNT / PAUSED_JOB_CNT 只在客户经理维度有值，其余为 NULL。
--   6. 接口侧的 permission_manager_count（有权限客户经理数）不在仓内计算，因此表中不设该字段。
--   7. 库名用 ${AALC_DATA} 占位（与调度变量一致）；表名如与分析层规范不同，要同时改
--      跑数脚本第 6 段的落数表名与 gauss/task_type_report_tdsql.sql 的数据源。
--   8. 统计区间不再单独落列：统计区间起点 = DW_DAT_DT 所在月 1 号，终点 = DW_DAT_DT，
--      需要时在查询里用 date_trunc('month', DW_DAT_DT) 现算。
--   9. 本表按现场规范建列存 + hash 分布、不建分区；列宽比 Hive 版宽（SOURCE_ID 100、
--      RPT_COMBO 100、JOB_TYPE 100、SKILL_ID 500、名称列 500/1000），TDSQL 侧落盘表的
--      列宽与之对齐，装载时不会再被截断（见 gauss/task_type_report_tdsql.sql 第 5 节）。
--  10. 仓库里的 task_type_report_gauss_optimized_v2*.sql、version2.sql 是历史草稿，
--      当前维护的是本文件与 task_type_report_daily.sql。
-- =============================================================================

create table ${AALC_DATA}.AALC_P_RM_CLAW_LIST_USE_IND_STAT    /* 金葵花任务类型报表：CLAW 名单使用指标 */
(
 DW_DAT_DT             DATE            NOT NULL    /* 数据日期（= 统计区间截止日，yyyy-MM-dd） */
,SOURCE_ID             VARCHAR(100)    NOT NULL    /* 来源标识（X-Source-Id） */
,RPT_COMBO             VARCHAR(100)    NOT NULL    /* 报表组合：overall/branch/org/manager/branch_skill/org_skill/manager_skill */
,FRS_BBK_ORG_ID        VARCHAR(200)    NOT NULL    /* 一级分行号，不适用为 ALL */
,FRS_BBK_ORG_NM        VARCHAR(500)                /* 一级分行名称 */
,BRN_ORG_ID            VARCHAR(100)    NOT NULL    /* 网点号，不适用为 ALL、名单缺机构号为空串 */
,BRN_ORG_NM            VARCHAR(500)                /* 网点名称 */
,CM_ID                 VARCHAR(200)    NOT NULL    /* 客户经理编号（SAP号），不适用为 ALL */
,CM_NM                 VARCHAR(500)                /* 客户经理姓名 */
,PST_LVL               VARCHAR(100)                /* 岗位定级 */
,SKILL_ID              VARCHAR(500)    NOT NULL    /* 技能ID，非技能明细为 ALL */
,SKILL_NM              VARCHAR(1000)               /* 技能中文名，取不到为 NULL，消费方回退展示 SKILL_ID */
,JOB_TYPE              VARCHAR(100)    NOT NULL    /* 任务类型（中文）：推送/主动/推送非，即显示名 */
,SKILL_CNT             INTEGER                     /* 技能数 skill_count */
,ACTIVE_MANAGER_CNT    INTEGER                     /* 活跃客户经理数（总体/分行/支行维度） */
,ACTIVE_JOB_CNT        INTEGER                     /* 当前活跃任务数（job.status=active，仅客户经理维度） */
,PAUSED_JOB_CNT        INTEGER                     /* 当前暂停任务数（job.status=paused，仅客户经理维度） */
,SUC_EXECUTE_JOB       INTEGER                     /* 成功执行任务数 suc_execute_job */
,READ_TASKS            INTEGER                     /* 已查看任务数 read_tasks */
,READ_RATE             DECIMAL(18,2)               /* 任务查看率（%），零分母为 NULL */
,RECOMMENDED_CUSTOMERS INTEGER                     /* 方案客户数，推送(非名单方案)为 NULL */
,READ_CUSTOMER_CNT     INTEGER                     /* 已查看方案客户数 */
,PLAN_READ_RATE        DECIMAL(18,2)               /* 方案查看率（%） */
,INSIGHT_CUSTOMER_CNT  INTEGER                     /* 洞察客户数 */
,CLICK_TO_INSIGHT_RATE DECIMAL(18,2)               /* 洞察覆盖率（%） */
,INSIGHT_CNT           INTEGER                     /* 点击客户洞察总次数 */
,PHONE_CUSTOMER_CNT    INTEGER                     /* 电访客户数 */
,CLICK_TO_PHONE_RATE   DECIMAL(18,2)               /* 电访覆盖率（%） */
,PHONE_CNT             INTEGER                     /* 点击去电访总次数 */
)
WITH (ORIENTATION = COLUMN, COLVERSION = 2.0, COMPRESSION = middle, enable_disaster_cstore = 'on')
DISTRIBUTE BY HASH (FRS_BBK_ORG_ID, BRN_ORG_ID, CM_ID, SKILL_ID, JOB_TYPE)
;

-- 分布键取五个维度列：同一组合下这五列就是行的业务主键，按它分布能让「同维度取数 +
-- 按组合过滤」落在少量 DN 上；上线前按真实数据量核对数据倾斜。
-- 本表不建分区：跑数脚本按 DW_DAT_DT 做 delete + insert，扫描靠列存 + DW_DAT_DT 过滤。

-- 消费示例（下游取数 / 出仓作业）：
--   -- 客户经理汇总：接口 group_by=manager, skill_detail=false
--   select * from ${AALC_DATA}.AALC_P_RM_CLAW_LIST_USE_IND_STAT
--    where DW_DAT_DT = CAST('2026-09-17' AS DATE) and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager';
--
--   -- 客户经理技能明细：接口 group_by=manager, skill_detail=true（各列不可相加）
--   select * from ${AALC_DATA}.AALC_P_RM_CLAW_LIST_USE_IND_STAT
--    where DW_DAT_DT = CAST('2026-09-17' AS DATE) and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager_skill';
