-- =============================================================================
-- 金葵花任务类型报表 —— TDSQL（MySQL 兼容）落盘表与装载脚本
--
-- 用途：承接 hive/task_type_report_daily.sql 的预聚合结果，供
--       /api/monitor/cron/report/task-type（查询）与 .../export（导出）读取。
-- 状态：生产链路已切到高斯（gauss/task_type_report_tdsql.sql + 高斯跑数脚本），本文件
--       保留作历史参考。注意：本节建表语句仍是 Hive 时代的结构（自增主键、窄列宽、
--       没有 dim_hash），与新表结构不一致；权威结构见 src/monitor/app/database/schema.py，
--       若要恢复 Hive 链路，请按 schema.py 重新生成建表语句，不要照抄本节。
-- 说明：同样两张表的建表语句已内置于服务端
--       src/monitor/app/database/schema.py，服务启动时会自动创建；
--       本文件用于 DBA 手工建表、权限审批与出仓装载，字段必须与 schema.py 一致。
-- 出仓粒度：Hive 侧一次跑数会重写「跑数日期前 7 天 ~ 跑数日期」共 8 个分区，
--       因此装载要按分区循环执行本文件的第 2 节，每个 ${PRT_DT} 各装一次。
-- 参数：${PRT_DT}     分区日期 yyyy-MM-dd（= 接口 end_date，同时是统计数据截止日）
--       ${SOURCE_ID}  来源标识（= 请求头 X-Source-Id）
--       ${STAT_START} / ${STAT_END} 统计区间（${PRT_DT} 当月 1 号 ~ ${PRT_DT}）
--       ${SYNC_DATE}  名单快照日（Hive 侧选择的 AALC_R_RM_SFL_CM_BAS_INFO 快照日）
--       ${DATA_FILE}  出仓文件（制表符分隔，列顺序见第 3 节）
-- =============================================================================


-- =============================================================================
-- 1. 建表（首次执行一次）
-- =============================================================================
CREATE TABLE IF NOT EXISTS swe_task_type_report_snapshot (
    id                BIGINT AUTO_INCREMENT PRIMARY KEY,
    prt_dt            DATE NOT NULL COMMENT '跑数日期，等于接口 end_date 与统计截止日',
    source_id         VARCHAR(64) NOT NULL COMMENT '来源标识 (X-Source-Id header)',
    rpt_combo         VARCHAR(32) NOT NULL COMMENT '报表组合: overall/branch/org/manager/branch_skill/org_skill/manager_skill',
    task_type         VARCHAR(16) NOT NULL COMMENT '任务类型: push_plan/ask_plan/push_other',
    first_bbk_id      VARCHAR(32) NOT NULL DEFAULT '' COMMENT '一级分行号，不适用为 ALL',
    org_id            VARCHAR(32) NOT NULL DEFAULT '' COMMENT '网点号，不适用为 ALL',
    user_id           VARCHAR(64) NOT NULL DEFAULT '' COMMENT '客户经理编号(SAP号)，不适用为 ALL',
    skill_id          VARCHAR(128) NOT NULL DEFAULT '' COMMENT '技能ID，非技能明细为 ALL',
    first_bbk_nm      VARCHAR(256) DEFAULT '' COMMENT '一级分行名称',
    org_nm            VARCHAR(256) DEFAULT '' COMMENT '网点名称',
    user_name         VARCHAR(256) DEFAULT '' COMMENT '客户经理姓名',
    pst_lvl           VARCHAR(64) DEFAULT '' COMMENT '岗位定级',
    cn_name           VARCHAR(256) DEFAULT '' COMMENT '技能中文名',
    task_type_name    VARCHAR(64) DEFAULT '' COMMENT '任务类型名称',
    skill_cnt         BIGINT NOT NULL DEFAULT 0 COMMENT '技能数 skill_count',
    active_manager_cnt BIGINT DEFAULT NULL COMMENT '活跃客户经理数（总体/分行/支行维度），客户经理维度与主动提问为 NULL',
    active_job_cnt    BIGINT DEFAULT NULL COMMENT '当前活跃任务数（job.status=active，仅客户经理维度），主动提问与其它维度为 NULL',
    paused_job_cnt    BIGINT DEFAULT NULL COMMENT '当前暂停任务数（job.status=paused，仅客户经理维度），主动提问与其它维度为 NULL',
    suc_execute_job   BIGINT NOT NULL DEFAULT 0 COMMENT '成功执行任务数',
    read_tasks        BIGINT NOT NULL DEFAULT 0 COMMENT '已查看任务数',
    read_rate         DECIMAL(18,2) DEFAULT NULL COMMENT '任务查看率(%)，零分母为 NULL',
    recommended_customers BIGINT DEFAULT NULL COMMENT '方案客户数，推送(非名单方案)为 NULL',
    read_customer_cnt BIGINT DEFAULT NULL COMMENT '已查看方案客户数',
    plan_read_rate    DECIMAL(18,2) DEFAULT NULL COMMENT '方案查看率(%)',
    insight_customer_cnt BIGINT DEFAULT NULL COMMENT '洞察客户数',
    click_to_insight_rate DECIMAL(18,2) DEFAULT NULL COMMENT '洞察覆盖率(%)',
    insight_cnt       BIGINT DEFAULT NULL COMMENT '点击客户洞察总次数',
    phone_customer_cnt BIGINT DEFAULT NULL COMMENT '电访客户数',
    click_to_phone_rate DECIMAL(18,2) DEFAULT NULL COMMENT '电访覆盖率(%)',
    phone_cnt         BIGINT DEFAULT NULL COMMENT '点击去电访总次数',
    stat_start_dt     DATE DEFAULT NULL COMMENT '统计区间起始日（当月1号）',
    stat_end_dt       DATE DEFAULT NULL COMMENT '统计区间截止日（= 分区日期 prt_dt）',
    loaded_at         DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '出仓写入时间',

    UNIQUE KEY uk_swe_ttr_row (prt_dt, source_id, rpt_combo, task_type,
        first_bbk_id, org_id, user_id, skill_id),
    INDEX idx_swe_ttr_branch (prt_dt, source_id, rpt_combo, first_bbk_id, org_id),
    INDEX idx_swe_ttr_user (prt_dt, source_id, rpt_combo, user_id),
    INDEX idx_swe_ttr_skill (prt_dt, source_id, rpt_combo, skill_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='金葵花任务类型报表落盘快照';


CREATE TABLE IF NOT EXISTS swe_task_type_report_batch (
    id                BIGINT AUTO_INCREMENT PRIMARY KEY,
    prt_dt            DATE NOT NULL COMMENT '跑数日期',
    source_id         VARCHAR(64) NOT NULL COMMENT '来源标识',
    stat_start_dt     DATE DEFAULT NULL COMMENT '统计区间起始日（当月1号）',
    stat_end_dt       DATE DEFAULT NULL COMMENT '统计区间截止日（跑数日期）',
    sync_date         VARCHAR(32) DEFAULT '' COMMENT '名单快照日，用于机构/权限校验',
    status            VARCHAR(16) NOT NULL DEFAULT 'loading' COMMENT '批次状态: loading/ready/failed',
    row_total         BIGINT NOT NULL DEFAULT 0 COMMENT '本批次写入行数',
    message           VARCHAR(512) DEFAULT '' COMMENT '失败原因或备注',
    loaded_at         DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '写入时间',
    updated_at        DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',

    UNIQUE KEY uk_swe_ttr_batch (prt_dt, source_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='金葵花任务类型报表出仓批次';


-- =============================================================================
-- 2. 装载流程（每天跑完 Hive 后按顺序执行；接口只认 status = 'ready'）
-- =============================================================================

-- 2.1 先把批次置为 loading，避免导入过程中被查询到半份数据
INSERT INTO swe_task_type_report_batch
    (prt_dt, source_id, stat_start_dt, stat_end_dt, sync_date, status, row_total, message)
VALUES
    ('${PRT_DT}', '${SOURCE_ID}', '${STAT_START}', '${STAT_END}', '${SYNC_DATE}', 'loading', 0, '')
ON DUPLICATE KEY UPDATE
    stat_start_dt = VALUES(stat_start_dt),
    stat_end_dt   = VALUES(stat_end_dt),
    sync_date     = VALUES(sync_date),
    status        = 'loading',
    message       = '';

-- 2.2 清掉当天分区（重跑幂等；也可跳过本步，靠唯一键 REPLACE 覆盖）
DELETE FROM swe_task_type_report_snapshot
WHERE prt_dt = '${PRT_DT}' AND source_id = '${SOURCE_ID}';

-- 2.3 导入出仓文件（列顺序见第 3 节；不适用维度在 Hive 里是 'ALL'，不是 \N）
LOAD DATA LOCAL INFILE '${DATA_FILE}'
INTO TABLE swe_task_type_report_snapshot
FIELDS TERMINATED BY '\t' LINES TERMINATED BY '\n'
(prt_dt, source_id, rpt_combo, task_type, first_bbk_id, org_id, user_id,
 skill_id, first_bbk_nm, org_nm, user_name, pst_lvl, cn_name,
 task_type_name, skill_cnt, active_manager_cnt, active_job_cnt,
 paused_job_cnt, suc_execute_job, read_tasks, read_rate,
 recommended_customers, read_customer_cnt, plan_read_rate,
 insight_customer_cnt, click_to_insight_rate, insight_cnt,
 phone_customer_cnt, click_to_phone_rate, phone_cnt, stat_start_dt,
 stat_end_dt)
SET loaded_at = NOW();

-- 2.4 核对七个组合都有数据后置为 ready（缺组合时不要置 ready）
SELECT rpt_combo, COUNT(*) AS row_cnt
FROM swe_task_type_report_snapshot
WHERE prt_dt = '${PRT_DT}' AND source_id = '${SOURCE_ID}'
GROUP BY rpt_combo;

UPDATE swe_task_type_report_batch
SET status = 'ready',
    row_total = (
        SELECT COUNT(*) FROM swe_task_type_report_snapshot
        WHERE prt_dt = '${PRT_DT}' AND source_id = '${SOURCE_ID}'
    ),
    loaded_at = NOW()
WHERE prt_dt = '${PRT_DT}' AND source_id = '${SOURCE_ID}';

-- 失败时置 failed 并写明原因，接口会返回 409 report_snapshot_not_ready
-- UPDATE swe_task_type_report_batch SET status = 'failed', message = ?
-- WHERE prt_dt = '${PRT_DT}' AND source_id = '${SOURCE_ID}';


-- =============================================================================
-- 3. 出仓文件列顺序（必须与本顺序一致，Hive 侧示例见下方注释）
-- =============================================================================
--  1 prt_dt              17 active_job_cnt
--  2 source_id           18 paused_job_cnt
--  3 rpt_combo           19 suc_execute_job
--  4 task_type           20 read_tasks
--  5 first_bbk_id        21 read_rate
--  6 org_id              22 recommended_customers
--  7 user_id             23 read_customer_cnt
--  8 skill_id            24 plan_read_rate
--  9 first_bbk_nm        25 insight_customer_cnt
-- 10 org_nm              26 click_to_insight_rate
-- 11 user_name           27 insight_cnt
-- 12 pst_lvl             28 phone_customer_cnt
-- 13 cn_name             29 click_to_phone_rate
-- 14 task_type_name      30 phone_cnt
-- 15 skill_cnt           31 stat_start_dt
-- 16 active_manager_cnt  32 stat_end_dt
--
-- Hive 侧导出示例（不适用维度在 Hive 里是 'ALL'，按原值导出即可；名称列可能为 NULL，
-- 用 ifnull 转空串避免文件里出现 \N）：
--   INSERT OVERWRITE DIRECTORY '/tmp/task_type_report/${PRT_DT}_${SOURCE_ID}'
--   ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
--   SELECT
--       prt_dt, source_id, rpt_combo, job_type,
--       frs_bbk_org_id, brn_org_id, cm_id,
--       ifnull(skill_id, ''), ifnull(first_bbk_nm, ''), ifnull(org_nm, ''),
--       ifnull(user_name, ''), ifnull(pst_lvl, ''), ifnull(cn_name, ''),
--       task_type_name, skill_cnt, active_manager_cnt, active_job_cnt, paused_job_cnt,
--       suc_execute_job,
--       read_tasks, read_rate, recommended_customers, read_customer_cnt,
--       plan_read_rate, insight_customer_cnt, click_to_insight_rate,
--       insight_cnt, phone_customer_cnt, click_to_phone_rate, phone_cnt,
--       stat_start_dt, stat_end_dt
--   FROM P_AALC.AALC_RM_TASK_TYPE_RPT
--   WHERE prt_dt = '${PRT_DT}' AND source_id = '${SOURCE_ID}';
--   注：Hive 目标表的列名是 frs_bbk_org_id / brn_org_id / cm_id / job_type（任务类型列），
--       出仓按位置装载，TDSQL 侧列名仍是 first_bbk_id / org_id / user_id / task_type；
--       不适用维度在 Hive 里已经是 'ALL'，不会再是 NULL。
--       如果落盘接口暂时不改（仍按空串判断“不适用”），把上面四个维度列的表达式改成
--       case when <列> = 'ALL' then '' else ifnull(<列>, '') end，出仓后语义与改动前一致。


-- =============================================================================
-- 4. 保留策略与运维
-- =============================================================================
-- 每个分区都是「该分区日期所在月 1 号 ~ 该分区日期」的累计口径，同月不同日期之间是嵌套
-- 包含关系，全月保留等于把数据放大约 30 倍（跑数脚本一次会重写近 8 个分区）。建议：
--   * 当月：保留每日批次，方便对比与回溯；
--   * 跨月：只保留每月最后一个跑数日的批次，其余按需清理：
--       DELETE FROM swe_task_type_report_snapshot
--       WHERE prt_dt < DATE_SUB(CURDATE(), INTERVAL 40 DAY)
--         AND prt_dt <> LAST_DAY(prt_dt);
--       DELETE FROM swe_task_type_report_batch
--       WHERE prt_dt < DATE_SUB(CURDATE(), INTERVAL 400 DAY);
--   * 单次导入后核对：swe_task_type_report_batch.row_total 应与
--     swe_task_type_report_snapshot 当日行数一致，七个组合齐全（见 2.4）。
