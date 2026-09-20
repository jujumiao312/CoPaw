-- =============================================================================
-- 金葵花任务类型报表 —— 目标表结构（首次部署执行一次，以后不必重复执行）
--
-- 对应接口：GET /api/monitor/cron/task-type-report
-- 指标口径：docs/superpowers/specs/2026-09-13-jkh-task-report/DESIGN.md、DIMENSIONS.md
-- 跑数脚本：hive/task_type_report_daily.sql
--
-- 说明：
--   1. 七种报表组合（overall / branch / org / manager × 是否技能明细）落同一张表，
--      用 RPT_COMBO 区分，见下方取值表；消费方必须按 RPT_COMBO（并按 SOURCE_ID）
--      过滤后再取数，不同组合的行不能混用、也不能相加。
--   2. 只有一个分区列 PRT_DT（yyyy-MM-dd）。跑数脚本一次重跑「跑数日期前 7 天 ~
--      跑数日期」共 8 个分区（推送当天为基线、统计推送后 7 天），每个分区重跑时整体覆盖；
--      某个组合用不到的维度列写 'ALL'，例如总体汇总的分行/网点/经理/技能列都是 'ALL'。
--      消费方按 'ALL' 判断“该维度不适用”，不要当成真实的机构号或技能号。
--   3. 表名、库名、存储格式与压缩请按数仓规范调整；调整后同步修改每天跑数脚本的
--      落数语句表名。仓库侧确认表名后，建议把本文件放到数仓的建表目录，不要放进
--      monitor 服务的发布包。
--   4. 接口的 permission_manager_count（有权限客户经理数）不在仓内计算，因此表中
--      不设该字段，见 hive/README.md 第 4 节。
--   5. 字段命名：客户经理编号列是 CM_ID，一级分行号列是 FRS_BBK_ORG_ID，网点号列是
--      BRN_ORG_ID，任务类型列是 JOB_TYPE；名称列（FIRST_BBK_NM / ORG_NM / USER_NAME /
--      TASK_TYPE_NAME）沿用原名。
--
--   RPT_COMBO 取值（与接口参数一一对应）：
--     overall         group_by=overall, skill_detail=false  总体汇总
--     branch          group_by=branch,  skill_detail=false  分行汇总
--     org             group_by=org,     skill_detail=false  支行汇总
--     manager         group_by=manager, skill_detail=false  客户经理汇总
--     branch_skill    group_by=branch,  skill_detail=true   分行 + 技能明细
--     org_skill       group_by=org,     skill_detail=true   支行 + 技能明细
--     manager_skill   group_by=manager, skill_detail=true   客户经理 + 技能明细
-- =============================================================================

create table if not exists P_AALC.AALC_RM_TASK_TYPE_RPT
(
    `SOURCE_ID` STRING COMMENT '来源标识，接口请求头 X-Source-Id'
    ,`RPT_COMBO` STRING COMMENT '报表组合：overall/branch/org/manager/branch_skill/org_skill/manager_skill'
    ,`FRS_BBK_ORG_ID` STRING COMMENT '一级分行号'
    ,`FIRST_BBK_NM` STRING COMMENT '一级分行名称'
    ,`BRN_ORG_ID` STRING COMMENT '网点号，支行维度使用'
    ,`ORG_NM` STRING COMMENT '网点名称，支行维度使用'
    ,`CM_ID` STRING COMMENT '客户经理编号（SAP号），客户经理维度使用'
    ,`USER_NAME` STRING COMMENT '客户经理姓名，客户经理维度使用'
    ,`PST_LVL` STRING COMMENT '岗位定级，客户经理维度使用'
    ,`SKILL_ID` STRING COMMENT '技能ID，技能明细使用'
    ,`CN_NAME` STRING COMMENT '技能名称，技能明细使用'
    ,`JOB_TYPE` STRING COMMENT '任务类型：push_plan/ask_plan/push_other'
    ,`TASK_TYPE_NAME` STRING COMMENT '任务类型名称：推送(名单+方案)/主动提问(名单+方案)/推送(非名单方案)'
    ,`SKILL_CNT` BIGINT COMMENT '技能数 skill_count'
    ,`ACTIVE_MANAGER_CNT` BIGINT COMMENT '活跃客户经理数 active_manager_count（总体/分行/支行维度），客户经理维度与主动提问为 NULL'
    ,`ACTIVE_JOB_CNT` BIGINT COMMENT '当前活跃任务数（job.status=active 的任务去重数，仅客户经理维度），主动提问与其它维度为 NULL'
    ,`PAUSED_JOB_CNT` BIGINT COMMENT '当前暂停任务数（job.status=paused 的任务去重数，仅客户经理维度），主动提问与其它维度为 NULL'
    ,`SUC_EXECUTE_JOB` BIGINT COMMENT '成功执行任务数 suc_execute_job'
    ,`READ_TASKS` BIGINT COMMENT '已查看任务数 read_tasks，主动提问等于成功数'
    ,`READ_RATE` DECIMAL(18,2) COMMENT '任务查看率（%），零分母为 NULL'
    ,`RECOMMENDED_CUSTOMERS` BIGINT COMMENT '方案客户数 recommended_customers，推送(非名单方案)为 NULL'
    ,`READ_CUSTOMER_CNT` BIGINT COMMENT '已查看方案客户数 read_customer_count，推送(非名单方案)为 NULL'
    ,`PLAN_READ_RATE` DECIMAL(18,2) COMMENT '方案查看率（%），零分母为 NULL'
    ,`INSIGHT_CUSTOMER_CNT` BIGINT COMMENT '洞察客户数 insight_customer_count，推送(非名单方案)为 NULL'
    ,`CLICK_TO_INSIGHT_RATE` DECIMAL(18,2) COMMENT '洞察覆盖率（%），零分母为 NULL'
    ,`INSIGHT_CNT` BIGINT COMMENT '点击客户洞察总次数 insight_count，推送(非名单方案)为 NULL'
    ,`PHONE_CUSTOMER_CNT` BIGINT COMMENT '电访客户数 phone_customer_count，推送(非名单方案)为 NULL'
    ,`CLICK_TO_PHONE_RATE` DECIMAL(18,2) COMMENT '电访覆盖率（%），零分母为 NULL'
    ,`PHONE_CNT` BIGINT COMMENT '点击去电访总次数 phone_count，推送(非名单方案)为 NULL'
    ,`STAT_START_DT` STRING COMMENT '统计区间起始日（当月1号）'
    ,`STAT_END_DT` STRING COMMENT '统计区间截止日（=本行分区日期）'
    ,`DW_STAT_DT` STRING COMMENT '统计日期（=本行分区日期）'
)
COMMENT '金葵花任务类型报表（总体/分行/支行/客户经理 × 是否技能明细，用 RPT_COMBO 区分）'
PARTITIONED BY (`PRT_DT` STRING COMMENT '跑数日期，yyyy-MM-dd')
;


-- 消费示例（Console / 下游取数）：
--   -- 跑数 2026-09-17 时，脚本会同时重写 2026-09-10 ~ 2026-09-17 共 8 个分区
--
--   -- 客户经理汇总：接口 group_by=manager, skill_detail=false
--   select * from P_AALC.AALC_RM_TASK_TYPE_RPT
--   where PRT_DT = '2026-09-17' and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager';
--
--   -- 客户经理技能明细：接口 group_by=manager, skill_detail=true
--   -- 明细各列不可相加，汇总数字请取 RPT_COMBO = 'manager' 的行
--   select * from P_AALC.AALC_RM_TASK_TYPE_RPT
--   where PRT_DT = '2026-09-17' and SOURCE_ID = 'RMASSIST' and RPT_COMBO = 'manager_skill';
