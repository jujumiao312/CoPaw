-- =============================================================================
-- 金葵花任务类型报表 —— TDSQL 落盘表结构（MySQL 兼容）
--
-- 本文件只描述表结构：数据由现场作业自行写入，仓库不提供装载脚本。
-- 消费方：/api/monitor/cron/report/task-type（查询）、/export、/options、/dates、/status
--         代码：routers/task_type_snapshot.py + services/report/task_type_snapshot.py
-- 权威结构：src/monitor/app/database/schema.py（服务启动会自动建表，两边必须逐字一致）
--
-- 两张表：
--   swe_task_type_report_snapshot  报表行：七种组合 × 三类任务，按 prt_dt 取数
--   swe_task_type_report_batch     批次：接口的就绪信号（status）+ 名单快照日（sync_date）
-- =============================================================================


-- =============================================================================
-- 1. 建表（首次部署执行一次；已有库走第 2 节的升级语句）
-- =============================================================================
    CREATE TABLE IF NOT EXISTS swe_task_type_report_snapshot (
        prt_dt            DATE NOT NULL COMMENT '数据日期(高斯 DW_DAT_DT)，等于接口 end_date 与统计截止日',
        source_id         VARCHAR(100) NOT NULL COMMENT '来源标识(高斯 SOURCE_ID)',
        rpt_combo         VARCHAR(32) NOT NULL COMMENT '报表组合: overall/branch/org/manager/branch_skill/org_skill/manager_skill',
        task_type         VARCHAR(16) NOT NULL COMMENT '任务类型码值: push_plan/ask_plan/push_other（高斯 JOB_TYPE 现在是中文，装载作业按 推送→push_plan、主动→ask_plan、推送非→push_other 映射后写入）',
        first_bbk_id      VARCHAR(200) NOT NULL DEFAULT '' COMMENT '一级分行号(FRS_BBK_ORG_ID)，不适用为 ALL、名单缺机构号为空串',
        org_id            VARCHAR(100) NOT NULL DEFAULT '' COMMENT '网点号(BRN_ORG_ID)，不适用为 ALL',
        user_id           VARCHAR(200) NOT NULL DEFAULT '' COMMENT '客户经理编号(CM_ID)，不适用为 ALL',
        skill_id          VARCHAR(500) NOT NULL DEFAULT '' COMMENT '技能ID(SKILL_ID)，非技能明细为 ALL',
        first_bbk_nm      VARCHAR(500) DEFAULT '' COMMENT '一级分行名称(FRS_BBK_ORG_NM)',
        org_nm            VARCHAR(500) DEFAULT '' COMMENT '网点名称(BRN_ORG_NM)',
        user_name         VARCHAR(500) DEFAULT '' COMMENT '客户经理姓名(CM_NM)',
        pst_lvl           VARCHAR(100) DEFAULT '' COMMENT '岗位定级(PST_LVL)',
        cn_name           VARCHAR(1000) DEFAULT '' COMMENT '技能中文名(SKILL_NM)',
        task_type_name    VARCHAR(100) DEFAULT '' COMMENT '任务类型名称（高斯 JOB_TYPE 原值，如 推送/主动/推送非）；为空时接口按 task_type 回退映射',
        skill_cnt         BIGINT NOT NULL DEFAULT 0 COMMENT '技能数(SKILL_CNT)',
        active_manager_cnt BIGINT DEFAULT NULL COMMENT '活跃客户经理数(ACTIVE_MANAGER_CNT)，仅总体/分行/支行维度有值',
        active_job_cnt    BIGINT DEFAULT NULL COMMENT '当前活跃任务数(ACTIVE_JOB_CNT)，仅客户经理维度有值',
        paused_job_cnt    BIGINT DEFAULT NULL COMMENT '当前暂停任务数(PAUSED_JOB_CNT)，仅客户经理维度有值',
        suc_execute_job   BIGINT NOT NULL DEFAULT 0 COMMENT '成功执行任务数(SUC_EXECUTE_JOB)',
        read_tasks        BIGINT NOT NULL DEFAULT 0 COMMENT '已查看任务数(READ_TASKS)',
        read_rate         DECIMAL(18,2) DEFAULT NULL COMMENT '任务查看率%(READ_RATE)，零分母为 NULL',
        recommended_customers BIGINT DEFAULT NULL COMMENT '方案客户数(RECOMMENDED_CUSTOMERS)',
        read_customer_cnt BIGINT DEFAULT NULL COMMENT '已查看方案客户数(READ_CUSTOMER_CNT)',
        plan_read_rate    DECIMAL(18,2) DEFAULT NULL COMMENT '方案查看率%(PLAN_READ_RATE)',
        insight_customer_cnt BIGINT DEFAULT NULL COMMENT '洞察客户数(INSIGHT_CUSTOMER_CNT)',
        click_to_insight_rate DECIMAL(18,2) DEFAULT NULL COMMENT '洞察覆盖率%(CLICK_TO_INSIGHT_RATE)',
        insight_cnt       BIGINT DEFAULT NULL COMMENT '点击客户洞察总次数(INSIGHT_CNT)',
        phone_customer_cnt BIGINT DEFAULT NULL COMMENT '电访客户数(PHONE_CUSTOMER_CNT)',
        click_to_phone_rate DECIMAL(18,2) DEFAULT NULL COMMENT '电访覆盖率%(CLICK_TO_PHONE_RATE)',
        phone_cnt         BIGINT DEFAULT NULL COMMENT '点击去电访总次数(PHONE_CNT)',
        stat_start_dt     DATE DEFAULT NULL COMMENT '统计区间起始日 = prt_dt 当月 1 号（写入时由 prt_dt 推导）',
        stat_end_dt       DATE DEFAULT NULL COMMENT '统计区间截止日 = prt_dt（写入时由 prt_dt 推导）',
        loaded_at         DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '本次写入时间',
        dim_hash          CHAR(32) CHARACTER SET ascii COLLATE ascii_bin
            GENERATED ALWAYS AS (MD5(CONCAT_WS(CHAR(1), rpt_combo, task_type,
                first_bbk_id, org_id, user_id, skill_id))) STORED
            COMMENT '组合+四维度键的 MD5，主键用它规避宽列索引长度上限',

        PRIMARY KEY (prt_dt, source_id, dim_hash),
        INDEX idx_swe_ttr_branch (prt_dt, source_id, rpt_combo, first_bbk_id, org_id),
        INDEX idx_swe_ttr_user (prt_dt, source_id, rpt_combo, user_id),
        INDEX idx_swe_ttr_skill (prt_dt, source_id, rpt_combo, skill_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='金葵花任务类型报表落盘快照(数据源:高斯)';


CREATE TABLE IF NOT EXISTS swe_task_type_report_batch (
    prt_dt            DATE NOT NULL COMMENT '数据日期(高斯 DW_DAT_DT)',
    source_id         VARCHAR(100) NOT NULL COMMENT '来源标识(高斯 SOURCE_ID)',
    stat_start_dt     DATE DEFAULT NULL COMMENT '统计区间起始日（当月1号）',
    stat_end_dt       DATE DEFAULT NULL COMMENT '统计区间截止日（= prt_dt）',
    sync_date         VARCHAR(32) DEFAULT '' COMMENT '名单快照日，用于机构/权限校验',
    status            VARCHAR(16) NOT NULL DEFAULT 'loading' COMMENT '批次状态: loading/ready/failed',
    row_total         BIGINT NOT NULL DEFAULT 0 COMMENT '本批次写入行数',
    message           VARCHAR(512) DEFAULT '' COMMENT '失败原因或备注',
    loaded_at         DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '写入时间',
    updated_at        DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',

    PRIMARY KEY (prt_dt, source_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='金葵花任务类型报表装载批次';


-- =============================================================================
-- 2. 历史库升级（只对已按旧结构建过表的库执行；新库跳过）
--    改动点：维度列加宽、主键从自增列改成 (prt_dt, source_id, dim_hash)。
--    加 STORED 生成列 / 换主键都会重建整表，数据量大时放到维护窗口执行。
-- =============================================================================
-- ALTER TABLE swe_task_type_report_snapshot
--     MODIFY source_id      VARCHAR(100) NOT NULL COMMENT '来源标识(高斯 SOURCE_ID)',
--     MODIFY first_bbk_id   VARCHAR(200) NOT NULL DEFAULT '' COMMENT '一级分行号，不适用为 ALL',
--     MODIFY org_id         VARCHAR(100) NOT NULL DEFAULT '' COMMENT '网点号，不适用为 ALL',
--     MODIFY user_id        VARCHAR(200) NOT NULL DEFAULT '' COMMENT '客户经理编号，不适用为 ALL',
--     MODIFY skill_id       VARCHAR(500) NOT NULL DEFAULT '' COMMENT '技能ID，非技能明细为 ALL',
--     MODIFY first_bbk_nm   VARCHAR(500) DEFAULT '' COMMENT '一级分行名称',
--     MODIFY org_nm         VARCHAR(500) DEFAULT '' COMMENT '网点名称',
--     MODIFY user_name      VARCHAR(500) DEFAULT '' COMMENT '客户经理姓名',
--     MODIFY pst_lvl        VARCHAR(100) DEFAULT '' COMMENT '岗位定级',
--     MODIFY cn_name        VARCHAR(1000) DEFAULT '' COMMENT '技能中文名',
--     MODIFY task_type_name VARCHAR(100) DEFAULT '' COMMENT '任务类型名称';
--
-- ALTER TABLE swe_task_type_report_snapshot
--     ADD COLUMN dim_hash CHAR(32) CHARACTER SET ascii COLLATE ascii_bin
--         GENERATED ALWAYS AS (MD5(CONCAT_WS(CHAR(1), rpt_combo, task_type,
--             first_bbk_id, org_id, user_id, skill_id))) STORED
--         COMMENT '组合+四维度键的 MD5，主键用它规避宽列索引长度上限'
--         AFTER loaded_at;
--
-- -- 去掉自增主键，改成自然主键（只在还带 id 列的老库上执行；已迁移过的库跳过）
-- ALTER TABLE swe_task_type_report_snapshot
--     DROP PRIMARY KEY,
--     DROP INDEX uk_swe_ttr_row,
--     DROP COLUMN id,
--     ADD PRIMARY KEY (prt_dt, source_id, dim_hash);
--
-- ALTER TABLE swe_task_type_report_batch
--     MODIFY source_id VARCHAR(100) NOT NULL COMMENT '来源标识(高斯 SOURCE_ID)';
--
-- ALTER TABLE swe_task_type_report_batch
--     DROP PRIMARY KEY,
--     DROP INDEX uk_swe_ttr_batch,
--     DROP COLUMN id,
--     ADD PRIMARY KEY (prt_dt, source_id);


-- =============================================================================
-- 3. 写入约定（接口按这些约定读取，写入方必须遵守）
-- =============================================================================
-- 3.1 主键与覆盖
--     * 报表行的业务键 = (prt_dt, source_id, dim_hash)，就是主键；同一业务键重复写入时
--       由写入方选择覆盖方式（INSERT ... ON DUPLICATE KEY UPDATE 即可原地更新、幂等重写）。
--     * 没有自增列：分布式 TDSQL 的分片键（prt_dt / source_id）已落在主键里；
--       代价是三个二级索引会带上整段主键（约 440 字节）。
--     * 组合与四个维度列决定 dim_hash，写同一条业务数据时这几列必须完全一致，
--       否则会被当成新行插进去（例如同一分行一会儿写 '001'、一会儿写 '1'）。
--
-- 3.2 维度列的两种特殊值（不能混用）
--     * 'ALL'：该组合用不到的维度（overall 的行四列全为 'ALL'，branch 的行网点/经理/技能为 'ALL'）。
--       接口会把它、以及“不在这层组合里”的维度一起还原成 null。
--     * 空串 ''：名单里机构号缺失，是真实分组，接口原样保留（排序排最后）。
--
-- 3.3 指标列的 NULL 规则（接口原样透出，写成 0 会失真）
--     * ask_plan：active_manager_cnt / active_job_cnt / paused_job_cnt 必须写 NULL；
--     * push_other：recommended_customers、read_customer_cnt、insight_customer_cnt、
--       insight_cnt、phone_customer_cnt、phone_cnt 必须写 NULL；
--     * 零分母的比例列（read_rate / plan_read_rate / click_to_insight_rate / click_to_phone_rate）
--       必须写 NULL，不能写 0；
--     * active_manager_cnt 只在总体/分行/支行维度有值，active_job_cnt / paused_job_cnt 只在
--       客户经理维度有值。
--
-- 3.4 派生列
--     * dim_hash 是 STORED 生成列，插入时不要给它赋值（显式赋值会报错）；
--     * stat_start_dt / stat_end_dt 由写入方按 prt_dt 推导（当月 1 号 / prt_dt），
--       /task-type 响应的 batch 与首屏区间提示用得上；
--     * loaded_at 默认取写入时间。
--
-- 3.5 批次表 = 接口的就绪开关
--     * 接口只读 status='ready' 的批次：批次不存在报 404，状态不是 ready 报 409。
--     * sync_date（名单快照日）必须有值：有权限客户经理数、机构范围校验（403）与机构名称解析
--       都按它查 jkh_user_inf；为空会直接 409（不会静默返回全 0）。
--     * 一次写多天（例如近 8 天）时，按 prt_dt 各写一行批次，各自置 ready。
--     * 建议顺序：批次置 loading → 写报表行 → 核对行数写进 row_total → 置 ready；半份数据或
--       0 行时不要置 ready（否则接口会把不完整、或上一版留下的数据当成当天数据返回）。
--
-- 3.6 表里没有、由接口实时算的列
--     * permission_manager_count（有权限客户经理数）：接口按批次的 sync_date 查
--       jkh_user_inf + swe_tenant_init_source 现算，不要往报表表里塞这一列。
--     * 统计区间固定「当月 1 号 ~ prt_dt」，表里不需要额外的区间列。


-- =============================================================================
-- 4. 保留策略
-- =============================================================================
-- 每个 prt_dt 的口径都是「该日期所在月 1 号 ~ 该日期」，同月不同日期之间是嵌套包含关系，
-- 全月保留等于把数据放大约 30 倍；一次重写近 8 天时，建议：
--   * 当月：保留每日批次，方便对比与回溯；
--   * 跨月：只保留每月最后一个数据日的批次：
--       DELETE FROM swe_task_type_report_snapshot
--       WHERE prt_dt < DATE_SUB(CURDATE(), INTERVAL 40 DAY)
--         AND prt_dt <> LAST_DAY(prt_dt);
--       DELETE FROM swe_task_type_report_batch
--       WHERE prt_dt < DATE_SUB(CURDATE(), INTERVAL 400 DAY);
--   * 若写入方式只能 UPDATE（不能 DELETE），源侧已消失的维度行会留在表里并继续出数；
--     需要清掉时先与业务确认，再按 prt_dt 对比源侧删除这些行，或给表按 prt_dt 建分区、
--     用 DROP PARTITION 做月度清理。
