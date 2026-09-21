# -*- coding: utf-8 -*-
"""Database schema initialization for Monitor cron tables.

This module provides SQL scripts to create the required tables for
cron job definitions and execution history.
"""

import logging

from .connection import get_db_connection

logger = logging.getLogger(__name__)


# SQL for creating cron_jobs table
CREATE_CRON_JOBS_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_jobs (
    id              VARCHAR(64) PRIMARY KEY COMMENT '任务ID (UUID)',
    name            VARCHAR(255) NOT NULL COMMENT '任务名称',
    tenant_id       VARCHAR(64) NOT NULL COMMENT '租户ID (分行号)',
    tenant_name     VARCHAR(255) DEFAULT '' COMMENT '租户姓名 (X-User-Name header)',
    bbk_id          VARCHAR(64) DEFAULT '' COMMENT '分行号 (X-Bbk-Id header)',
    source_id       VARCHAR(64) DEFAULT '' COMMENT '来源标识 (X-Source-Id header)',
    enabled         TINYINT(1) DEFAULT 1 COMMENT '是否启用',
    task_type       VARCHAR(16) NOT NULL COMMENT '任务类型: text/agent',

    -- 调度配置
    cron_expr       VARCHAR(64) NOT NULL COMMENT 'cron表达式 (5字段)',
    timezone        VARCHAR(32) DEFAULT 'UTC' COMMENT '时区',

    -- 执行目标
    channel         VARCHAR(32) NOT NULL COMMENT '分发渠道',
    target_user_id  VARCHAR(64) DEFAULT '' COMMENT '目标用户ID',
    target_session_id VARCHAR(64) DEFAULT '' COMMENT '目标会话ID',

    -- 执行配置
    timeout_seconds INT DEFAULT 7200 COMMENT '超时秒数',
    max_concurrency INT DEFAULT 1 COMMENT '最大并发数',
    misfire_grace_seconds INT DEFAULT 300 COMMENT 'misfire容错秒数',

    -- 任务内容
    text_content    VARCHAR(4096) DEFAULT '' COMMENT 'text类型任务内容',
    request_input   VARCHAR(4096) DEFAULT '' COMMENT 'agent类型请求输入',

    -- 任务元数据
    creator_user_id VARCHAR(64) DEFAULT '' COMMENT '创建者用户ID',
    task_chat_id    VARCHAR(64) DEFAULT '' COMMENT '关联聊天ID',
    task_session_id VARCHAR(64) DEFAULT '' COMMENT '关联会话ID',
    job_origin      VARCHAR(32) NOT NULL DEFAULT 'manual' COMMENT '任务来源: manual/subscription/system',
    subscription_key VARCHAR(255) DEFAULT '' COMMENT '订阅任务稳定分组ID',
    skill_ids       VARCHAR(200) DEFAULT '' COMMENT '绑定技能ID，逗号分隔',
    meta            VARCHAR(4096) DEFAULT '' COMMENT '扩展元数据',

    -- 状态追踪
    status          VARCHAR(16) DEFAULT 'active' COMMENT '状态: active/paused/deleted',
    pause_reason    VARCHAR(32) DEFAULT '' COMMENT '暂停原因',

    -- 时间戳
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    deleted_at      DATETIME DEFAULT NULL COMMENT '删除时间',

    INDEX idx_tenant_id (tenant_id),
    INDEX idx_bbk_id (bbk_id),
    INDEX idx_source_id (source_id),
    INDEX idx_creator_user_id (creator_user_id),
    INDEX idx_swe_cron_jobs_origin (job_origin),
    INDEX idx_swe_cron_jobs_subscription (job_origin, subscription_key),
    INDEX idx_swe_cron_jobs_subscription_user (job_origin, subscription_key, creator_user_id),
    INDEX idx_status (status),
    INDEX idx_enabled (enabled),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='定时任务定义表';
"""

# SQL for adding tenant_name column to existing table
ALTER_CRON_JOBS_ADD_TENANT_NAME = """
ALTER TABLE swe_cron_jobs
ADD COLUMN tenant_name VARCHAR(255) DEFAULT '' COMMENT '租户姓名 (X-User-Name header)'
AFTER tenant_id;
"""

CRON_JOBS_EXTRA_COLUMNS: dict[str, str] = {
    "job_origin": (
        "ALTER TABLE swe_cron_jobs "
        "ADD COLUMN job_origin VARCHAR(32) NOT NULL DEFAULT 'manual' "
        "COMMENT '任务来源: manual/subscription/system' "
        "AFTER task_session_id"
    ),
    "subscription_key": (
        "ALTER TABLE swe_cron_jobs "
        "ADD COLUMN subscription_key VARCHAR(255) DEFAULT '' "
        "COMMENT '订阅任务稳定分组ID' "
        "AFTER job_origin"
    ),
    "skill_ids": (
        "ALTER TABLE swe_cron_jobs "
        "ADD COLUMN skill_ids VARCHAR(200) DEFAULT '' "
        "COMMENT '绑定技能ID，逗号分隔' "
        "AFTER subscription_key"
    ),
    "broadcast_source_job_id": (
        "ALTER TABLE swe_cron_jobs "
        "ADD COLUMN broadcast_source_job_id VARCHAR(64) DEFAULT '' "
        "COMMENT '分发源定时任务ID' "
        "AFTER skill_ids"
    ),
}

CRON_JOBS_EXTRA_INDEXES: dict[str, str] = {
    "idx_swe_cron_jobs_origin": (
        "CREATE INDEX idx_swe_cron_jobs_origin "
        "ON swe_cron_jobs (job_origin)"
    ),
    "idx_swe_cron_jobs_subscription": (
        "CREATE INDEX idx_swe_cron_jobs_subscription "
        "ON swe_cron_jobs (job_origin, subscription_key)"
    ),
    "idx_swe_cron_jobs_subscription_user": (
        "CREATE INDEX idx_swe_cron_jobs_subscription_user "
        "ON swe_cron_jobs (job_origin, subscription_key, creator_user_id)"
    ),
}

# SQL for creating cron_executions table
CREATE_CRON_EXECUTIONS_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_executions (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '执行记录ID',
    job_id          VARCHAR(64) NOT NULL COMMENT '任务ID',
    job_name        VARCHAR(255) DEFAULT '' COMMENT '任务名称 (冗余存储便于查询)',
    tenant_id       VARCHAR(64) NOT NULL COMMENT '租户ID (分行号)',

    -- 执行时间
    scheduled_time  DATETIME DEFAULT NULL COMMENT '计划执行时间',
    actual_time     DATETIME NOT NULL COMMENT '实际开始时间',
    end_time        DATETIME DEFAULT NULL COMMENT '结束时间',
    duration_ms     INT DEFAULT 0 COMMENT '执行耗时 (毫秒)',

    -- 执行状态
    status          VARCHAR(16) NOT NULL COMMENT '状态: success/error/cancelled/timeout/skipped',
    async_status    VARCHAR(16) DEFAULT NULL COMMENT '异步任务执行状态: success/error',
    need_notification TINYINT(1) DEFAULT 0 COMMENT '是否需要通知: 0-否, 1-是',
    error_message   VARCHAR(2048) DEFAULT '' COMMENT '错误信息',

    -- 执行上下文
    instance_id     VARCHAR(64) DEFAULT '' COMMENT '执行实例标识',
    executor_leader VARCHAR(64) DEFAULT '' COMMENT '执行者 leader ID',
    is_manual       TINYINT(1) DEFAULT 0 COMMENT '是否手动触发',

    -- 可追溯链路
    trace_id        VARCHAR(64) DEFAULT '' COMMENT '关联的 trace ID',
    session_id      VARCHAR(64) DEFAULT '' COMMENT '关联的 session ID',

    -- 执行结果预览
    input_snapshot  VARCHAR(2048) DEFAULT '' COMMENT '执行时的输入快照',
    output_preview  VARCHAR(512) DEFAULT '' COMMENT '输出预览 (前100字符)',

    -- 执行元数据
    meta            VARCHAR(2048) DEFAULT '' COMMENT '执行元数据',
    dispatch_intent_id BIGINT DEFAULT NULL COMMENT '批调度派发意图ID',
    dispatch_batch_id VARCHAR(64) DEFAULT '' COMMENT '批调度批次ID',
    dispatch_attempt INT DEFAULT NULL COMMENT '批调度派发尝试次数',

    -- 通知状态
    notification_status VARCHAR(16) DEFAULT 'not_required' COMMENT '通知状态',
    notification_due_at DATETIME DEFAULT NULL COMMENT '计划通知时间',
    notification_timezone VARCHAR(64) DEFAULT '' COMMENT '通知计算时区',
    notification_sent_at DATETIME DEFAULT NULL COMMENT '通知发送时间',
    notification_attempts INT DEFAULT 0 COMMENT '通知尝试次数',
    notification_error VARCHAR(2048) DEFAULT '' COMMENT '通知错误',
    notification_lock_owner VARCHAR(128) DEFAULT '' COMMENT '通知锁持有者',
    notification_locked_at DATETIME DEFAULT NULL COMMENT '通知锁时间',

    -- 时间戳
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '记录创建时间',

    is_read        TINYINT(1) DEFAULT 0 COMMENT 'whether execution result was read',
    read_at        DATETIME DEFAULT NULL COMMENT 'read time',

    INDEX idx_job_id (job_id),
    INDEX idx_tenant_id (tenant_id),
    INDEX idx_status (status),
    INDEX idx_async_status (async_status),
    INDEX idx_scheduled_time (scheduled_time),
    INDEX idx_actual_time (actual_time),
    INDEX idx_trace_id (trace_id),
    INDEX idx_notification_scan (notification_status, notification_due_at),
    INDEX idx_notification_lock (notification_lock_owner, notification_locked_at),
    INDEX idx_execution_read (is_read, read_at),
    INDEX idx_cron_execution_dispatch (
        dispatch_intent_id, dispatch_batch_id, dispatch_attempt
    ),
    INDEX idx_tenant_actual (tenant_id, actual_time),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='定时任务执行历史表';
"""


ALTER_CRON_EXECUTIONS_NOTIFICATION_COLUMNS = [
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_status VARCHAR(16) DEFAULT 'not_required'
    COMMENT '通知状态'
    AFTER meta
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_due_at DATETIME DEFAULT NULL
    COMMENT '计划通知时间'
    AFTER notification_status
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_timezone VARCHAR(64) DEFAULT ''
    COMMENT '通知计算时区'
    AFTER notification_due_at
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_sent_at DATETIME DEFAULT NULL
    COMMENT '通知发送时间'
    AFTER notification_timezone
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_attempts INT DEFAULT 0
    COMMENT '通知尝试次数'
    AFTER notification_sent_at
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_error VARCHAR(2048) DEFAULT ''
    COMMENT '通知错误'
    AFTER notification_attempts
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_lock_owner VARCHAR(128) DEFAULT ''
    COMMENT '通知锁持有者'
    AFTER notification_error
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN notification_locked_at DATETIME DEFAULT NULL
    COMMENT '通知锁时间'
    AFTER notification_lock_owner
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD INDEX idx_notification_scan (notification_status, notification_due_at)
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD INDEX idx_notification_lock (
        notification_lock_owner,
        notification_locked_at
    )
    """,
]

ALTER_CRON_EXECUTIONS_READ_COLUMNS = [
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN is_read TINYINT(1) DEFAULT 0
    COMMENT 'whether execution result was read'
    AFTER notification_locked_at
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN read_at DATETIME DEFAULT NULL
    COMMENT 'read time'
    AFTER is_read
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD INDEX idx_execution_read (is_read, read_at)
    """,
]

ALTER_CRON_EXECUTIONS_DISPATCH_COLUMNS = [
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN dispatch_intent_id BIGINT DEFAULT NULL
    COMMENT '批调度派发意图ID'
    AFTER meta
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN dispatch_batch_id VARCHAR(64) DEFAULT ''
    COMMENT '批调度批次ID'
    AFTER dispatch_intent_id
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN dispatch_attempt INT DEFAULT NULL
    COMMENT '批调度派发尝试次数'
    AFTER dispatch_batch_id
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD INDEX idx_cron_execution_dispatch (
        dispatch_intent_id, dispatch_batch_id, dispatch_attempt
    )
    """,
]

# SQL for creating extracted customer names table
CREATE_EXTRACTED_CUSTOMER_NAMES_TABLE = """
CREATE TABLE IF NOT EXISTS swe_extracted_customer_names (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键ID',
    trace_id        VARCHAR(64) NOT NULL COMMENT '关联的 trace ID',
    skill_name      VARCHAR(255) NOT NULL COMMENT '技能名称',
    user_message_names JSON NOT NULL COMMENT '用户消息中提取的姓名列表',
    model_output_names JSON NOT NULL COMMENT '模型输出中提取的姓名列表',
    user_id         VARCHAR(64) DEFAULT '' COMMENT '用户 ID',
    bbk_id          VARCHAR(64) DEFAULT '' COMMENT '分行 ID',
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',

    UNIQUE INDEX uk_trace_skill (trace_id, skill_name),
    INDEX idx_skill_name (skill_name),
    INDEX idx_user_id (user_id),
    INDEX idx_bbk_id (bbk_id),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='提取客户姓名记录表';
"""

# SQL for creating cron subtasks table
CREATE_CRON_SUBTASKS_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_subtasks (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键ID',
    trace_id     VARCHAR(64) NOT NULL COMMENT '主任务trace_id',
    task_id      VARCHAR(128) NOT NULL COMMENT '子任务task_id',
    filename     VARCHAR(512) NOT NULL COMMENT '文件名',
    task_type    VARCHAR(16) DEFAULT NULL COMMENT '任务类型: list/plan',
    custuid      VARCHAR(64) DEFAULT NULL COMMENT '任务中客户ID',
    bbk_org_id   VARCHAR(64) DEFAULT NULL COMMENT '客户归属二级分行ID',
    cust_nm      VARCHAR(255) DEFAULT NULL COMMENT '任务中客户名称',
    template_id  BIGINT DEFAULT NULL COMMENT 'HTML模板ID',
    result_id    VARCHAR(100) DEFAULT NULL COMMENT '待填充数据ID',
    notification_content_wplus VARCHAR(5000) DEFAULT NULL COMMENT 'W+渠道通知消息内容',
    notification_content_zhaohu VARCHAR(5000) DEFAULT NULL COMMENT '招乎渠道通知消息内容',
    need_notification TINYINT(1) DEFAULT 1 COMMENT '是否需要通知: 0-否, 1-是',
    status       VARCHAR(16) DEFAULT NULL COMMENT '子任务状态: SUC/FAIL/PART_SUC/TIMEOUT',
    info         VARCHAR(2048) DEFAULT '' COMMENT '预留扩展信息',
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at   DATETIME DEFAULT NULL COMMENT '更新时间',

    UNIQUE INDEX uk_trace_task (trace_id, task_id),
    INDEX idx_trace_id (trace_id),
    INDEX idx_status (status),
    INDEX idx_task_type (task_type),
    INDEX idx_custuid (custuid),
    INDEX idx_bbk_org_id (bbk_org_id),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='定时任务子任务表';
"""

CREATE_CRON_RESULT_INDEX_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_result_index (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键ID',
    source_id VARCHAR(64) NOT NULL DEFAULT '' COMMENT '来源ID',
    tenant_id VARCHAR(64) NOT NULL COMMENT '客户经理/租户ID',
    first_bbk_id VARCHAR(64) NOT NULL COMMENT '一级分行号',
    bbk_org_id VARCHAR(64) NOT NULL COMMENT '二级分行号',
    custuid VARCHAR(64) NOT NULL DEFAULT '' COMMENT '客户ID',
    cust_nm VARCHAR(255) DEFAULT NULL COMMENT '客户名称',
    skill_id VARCHAR(64) NOT NULL COMMENT '技能ID',
    job_id VARCHAR(64) NOT NULL COMMENT '定时任务ID',
    execution_id BIGINT NOT NULL COMMENT '执行记录ID',
    trace_id VARCHAR(64) NOT NULL COMMENT '执行trace_id',
    subtask_id BIGINT NOT NULL COMMENT 'subtask主键',
    task_id VARCHAR(128) NOT NULL COMMENT '异步子任务ID',
    result_type VARCHAR(16) NOT NULL COMMENT 'list/plan',
    template_id BIGINT DEFAULT NULL COMMENT 'HTML模板ID',
    result_id VARCHAR(100) DEFAULT NULL COMMENT '待填充数据ID',
    filename VARCHAR(512) DEFAULT NULL COMMENT '文件名',
    status VARCHAR(16) DEFAULT NULL COMMENT '子任务状态',
    is_latest_success TINYINT(1) NOT NULL DEFAULT 1 COMMENT '是否为最新成功结果',
    execution_at DATETIME NOT NULL COMMENT '执行成功时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at DATETIME DEFAULT NULL COMMENT '更新时间',
    expire_at DATETIME NOT NULL COMMENT '过期时间',

    UNIQUE KEY uk_subtask_skill (subtask_id, skill_id),
    KEY idx_plan_query (
        source_id, tenant_id, first_bbk_id, bbk_org_id, custuid,
        result_type, is_latest_success, execution_at DESC, id DESC
    ),
    KEY idx_list_query (
        source_id, tenant_id, first_bbk_id, bbk_org_id,
        result_type, is_latest_success, execution_at DESC, id DESC
    ),
    KEY idx_skill_scope (
        source_id, tenant_id, first_bbk_id, skill_id,
        result_type, is_latest_success, execution_at DESC
    ),
    KEY idx_expire_at (expire_at),
    KEY idx_job_latest (job_id, is_latest_success, execution_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='定时任务结果查询索引表';
"""

CREATE_CRON_DISPATCH_BATCHES_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_batches (
    batch_id VARCHAR(64) PRIMARY KEY COMMENT 'dispatch batch id',
    parent_job_id VARCHAR(64) NOT NULL COMMENT 'batch parent cron job id',
    parent_external_job_id VARCHAR(64) DEFAULT '' COMMENT 'external scheduler job id',
    tenant_id VARCHAR(64) NOT NULL COMMENT 'parent tenant id',
    source_id VARCHAR(64) DEFAULT '' COMMENT 'source id',
    provider_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'provider id',
    model_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'model id',
    agent_id VARCHAR(64) NOT NULL DEFAULT 'default' COMMENT 'agent id',
    scheduled_fire_at DATETIME NOT NULL COMMENT 'parent scheduled fire time',
    callback_received_at DATETIME NOT NULL COMMENT 'scheduler callback receive time',
    status VARCHAR(16) NOT NULL DEFAULT 'received' COMMENT 'received/pending/running/completed/failed',
    lock_owner VARCHAR(128) DEFAULT '' COMMENT '批次派发锁持有者',
    locked_at DATETIME DEFAULT NULL COMMENT '批次派发锁时间',
    total_count INT NOT NULL DEFAULT 0 COMMENT 'total intents',
    completed_count INT NOT NULL DEFAULT 0 COMMENT 'completed intents',
    failed_count INT NOT NULL DEFAULT 0 COMMENT 'failed intents',
    callback_metadata JSON DEFAULT NULL COMMENT 'raw callback metadata',
    error_message VARCHAR(2048) DEFAULT '' COMMENT 'batch error summary',
    completed_at DATETIME DEFAULT NULL COMMENT 'batch completed time',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'updated time',
    UNIQUE INDEX uk_dispatch_batch_parent_fire (
        parent_job_id, scheduled_fire_at
    ),
    INDEX idx_dispatch_batch_parent (parent_job_id, created_at),
    INDEX idx_dispatch_batch_source (source_id, scheduled_fire_at),
    INDEX idx_dispatch_batch_status (status, updated_at),
    INDEX idx_dispatch_batch_lock (lock_owner, locked_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='SWE cron dispatch batch runs';
"""

CREATE_CRON_DISPATCH_INTENTS_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_intents (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT 'dispatch intent id',
    batch_id VARCHAR(64) NOT NULL COMMENT 'dispatch batch id',
    intent_role VARCHAR(16) NOT NULL COMMENT 'parent/child',
    status VARCHAR(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/claimed/dispatched/completed/failed/cancelled',
    source_id VARCHAR(64) DEFAULT '' COMMENT 'source id',
    provider_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'provider id',
    model_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'model id',
    tenant_id VARCHAR(64) NOT NULL COMMENT 'runtime tenant id',
    agent_id VARCHAR(64) NOT NULL DEFAULT 'default' COMMENT 'agent id',
    job_id VARCHAR(64) NOT NULL COMMENT 'cron job id',
    parent_job_id VARCHAR(64) DEFAULT '' COMMENT 'parent broadcast job id',
    scheduled_fire_at DATETIME DEFAULT NULL COMMENT 'parent scheduled fire time',
    due_at DATETIME NOT NULL COMMENT 'earliest claim time',
    dispatch_order INT NOT NULL DEFAULT 0 COMMENT 'stable order inside batch',
    viewer_heat_score DECIMAL(12,4) NOT NULL DEFAULT 0 COMMENT 'bounded read heat score',
    attempt_count INT NOT NULL DEFAULT 0 COMMENT 'attempt count',
    max_attempts INT NOT NULL DEFAULT 3 COMMENT 'max attempts',
    lock_owner VARCHAR(128) DEFAULT '' COMMENT 'worker lock owner',
    locked_at DATETIME DEFAULT NULL COMMENT 'lock time',
    acked_at DATETIME DEFAULT NULL COMMENT 'worker acknowledged time',
    completed_at DATETIME DEFAULT NULL COMMENT 'completion time',
    error_message VARCHAR(2048) DEFAULT '' COMMENT 'last error',
    payload JSON DEFAULT NULL COMMENT 'intent payload',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'updated time',
    UNIQUE INDEX uk_dispatch_batch_role_job (batch_id, intent_role, tenant_id, job_id),
    INDEX idx_dispatch_claim (status, due_at, dispatch_order, id),
    INDEX idx_dispatch_batch (batch_id, dispatch_order),
    INDEX idx_dispatch_lock (lock_owner, locked_at),
    INDEX idx_dispatch_job (job_id),
    INDEX idx_dispatch_source (source_id),
    INDEX idx_dispatch_scope_claim (
        source_id,
        provider_id,
        model_id,
        status,
        due_at,
        dispatch_order,
        id
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='SWE cron dispatch intent queue';
"""

CREATE_CRON_DISPATCH_EVENTS_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_events (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT 'dispatch event id',
    batch_id VARCHAR(64) NOT NULL COMMENT 'dispatch batch id',
    intent_id BIGINT DEFAULT NULL COMMENT 'dispatch intent id',
    event_type VARCHAR(64) NOT NULL COMMENT 'event type',
    worker_id VARCHAR(128) DEFAULT '' COMMENT 'worker id',
    job_id VARCHAR(64) DEFAULT '' COMMENT 'job id',
    tenant_id VARCHAR(64) DEFAULT '' COMMENT 'tenant id',
    source_id VARCHAR(64) DEFAULT '' COMMENT 'source id',
    details JSON DEFAULT NULL COMMENT 'event details',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    INDEX idx_dispatch_events_batch (batch_id, created_at),
    INDEX idx_dispatch_events_intent (intent_id),
    INDEX idx_dispatch_events_type (event_type, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='SWE cron dispatch telemetry events';
"""

CREATE_CRON_DISPATCH_WORKER_CAPACITY_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_worker_capacity (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT 'capacity snapshot id',
    worker_id VARCHAR(128) NOT NULL COMMENT 'worker id',
    source_id VARCHAR(64) DEFAULT '' COMMENT 'source id',
    provider_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'provider id',
    model_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'model id',
    strategy_id VARCHAR(64) DEFAULT '' COMMENT 'worker strategy id',
    previous_workers INT NOT NULL DEFAULT 0 COMMENT 'previous effective workers',
    baseline_workers INT NOT NULL DEFAULT 1 COMMENT 'baseline workers',
    min_workers INT NOT NULL DEFAULT 1 COMMENT 'minimum workers',
    max_workers INT NOT NULL DEFAULT 1 COMMENT 'max workers',
    effective_workers INT NOT NULL DEFAULT 1 COMMENT 'effective workers',
    pending_count INT NOT NULL DEFAULT 0 COMMENT 'pending intents',
    claimed_count INT NOT NULL DEFAULT 0 COMMENT 'claimed intents',
    running_count INT NOT NULL DEFAULT 0 COMMENT 'running intents',
    success_count INT NOT NULL DEFAULT 0 COMMENT 'recent success count',
    failure_count INT NOT NULL DEFAULT 0 COMMENT 'recent terminal failure count',
    error_rate DECIMAL(8,6) NOT NULL DEFAULT 0 COMMENT 'terminal failure rate',
    matched_rule JSON DEFAULT NULL COMMENT 'matched adjustment rule',
    avg_latency_ms INT NOT NULL DEFAULT 0 COMMENT 'recent average latency',
    decision_reason VARCHAR(255) DEFAULT '' COMMENT 'capacity decision reason',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    INDEX idx_dispatch_capacity_worker (worker_id, created_at),
    INDEX idx_dispatch_capacity_source (source_id, created_at),
    INDEX idx_dispatch_capacity_scope (
        source_id, provider_id, model_id, strategy_id, created_at
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='SWE cron dispatch worker capacity snapshots';
"""

CREATE_CRON_DISPATCH_SCOPE_LEASES_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_scope_leases (
    source_id VARCHAR(64) NOT NULL DEFAULT '' COMMENT 'source id',
    provider_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'provider id',
    model_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'model id',
    lock_owner VARCHAR(128) NOT NULL DEFAULT '' COMMENT 'scope lease owner',
    locked_at DATETIME DEFAULT NULL COMMENT 'scope lock time',
    lease_expires_at DATETIME DEFAULT NULL COMMENT 'scope lease expiry time',
    heartbeat_at DATETIME DEFAULT NULL COMMENT 'scope owner heartbeat time',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'updated time',
    PRIMARY KEY (source_id, provider_id, model_id),
    INDEX idx_scope_lease_owner (lock_owner, lease_expires_at),
    INDEX idx_scope_lease_expiry (lease_expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Cron dispatch model scope leases';
"""

CREATE_CRON_DISPATCH_MODEL_WORKER_POLICY_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_model_worker_policy (
    source_id VARCHAR(64) NOT NULL DEFAULT 'default' COMMENT 'source id',
    provider_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'provider id',
    model_id VARCHAR(128) NOT NULL DEFAULT 'default' COMMENT 'model id',
    default_strategy_id VARCHAR(64) NOT NULL COMMENT 'default strategy id',
    strategy_schedule JSON DEFAULT NULL COMMENT 'time-window strategy schedule',
    enabled TINYINT(1) NOT NULL DEFAULT 1 COMMENT 'enabled',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'updated time',
    PRIMARY KEY (source_id, provider_id, model_id),
    INDEX idx_dispatch_worker_policy_strategy (default_strategy_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Cron dispatch model worker policy';
"""

CREATE_CRON_DISPATCH_WORKER_STRATEGY_TABLE = """
CREATE TABLE IF NOT EXISTS swe_cron_dispatch_worker_strategy (
    strategy_id VARCHAR(64) PRIMARY KEY COMMENT 'strategy id',
    min_workers INT NOT NULL DEFAULT 1 COMMENT 'minimum workers',
    baseline_workers INT NOT NULL DEFAULT 1 COMMENT 'baseline workers',
    max_workers INT NOT NULL DEFAULT 1 COMMENT 'maximum workers',
    adjust_interval_seconds INT NOT NULL DEFAULT 300 COMMENT 'adjust interval',
    feedback_window_seconds INT NOT NULL DEFAULT 300 COMMENT 'feedback window',
    stale_execution_seconds INT NOT NULL DEFAULT 7800 COMMENT 'stale dispatch timeout',
    error_rate_rules JSON DEFAULT NULL COMMENT 'error-rate adjustment rules',
    enabled TINYINT(1) NOT NULL DEFAULT 1 COMMENT 'enabled',
    description VARCHAR(255) DEFAULT '' COMMENT 'strategy description',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP COMMENT 'created time',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'updated time'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Cron dispatch worker strategy';
"""

ALTER_CRON_DISPATCH_INTENTS_INDEXES = [
    """
    ALTER TABLE swe_cron_dispatch_intents
    ADD COLUMN provider_id VARCHAR(128) NOT NULL DEFAULT 'default'
    COMMENT 'provider id'
    AFTER source_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_intents
    ADD COLUMN model_id VARCHAR(128) NOT NULL DEFAULT 'default'
    COMMENT 'model id'
    AFTER provider_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_intents
    ADD COLUMN scheduled_fire_at DATETIME DEFAULT NULL
    COMMENT 'parent scheduled fire time'
    AFTER parent_job_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_intents
    ADD INDEX idx_dispatch_scope_claim (
        source_id,
        provider_id,
        model_id,
        status,
        due_at,
        dispatch_order,
        id
    )
    """,
]

ALTER_CRON_DISPATCH_BATCHES_MODEL_COLUMNS = [
    """
    ALTER TABLE swe_cron_dispatch_batches
    ADD COLUMN provider_id VARCHAR(128) NOT NULL DEFAULT 'default'
    COMMENT 'provider id'
    AFTER source_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_batches
    ADD COLUMN model_id VARCHAR(128) NOT NULL DEFAULT 'default'
    COMMENT 'model id'
    AFTER provider_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_batches
    ADD COLUMN lock_owner VARCHAR(128) DEFAULT ''
    COMMENT '批次派发锁持有者'
    AFTER status
    """,
    """
    ALTER TABLE swe_cron_dispatch_batches
    ADD COLUMN locked_at DATETIME DEFAULT NULL
    COMMENT '批次派发锁时间'
    AFTER lock_owner
    """,
    """
    ALTER TABLE swe_cron_dispatch_batches
    ADD INDEX idx_dispatch_batch_lock (lock_owner, locked_at)
    """,
]

ALTER_CRON_DISPATCH_WORKER_CAPACITY_COLUMNS = [
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN provider_id VARCHAR(128) NOT NULL DEFAULT 'default'
    COMMENT 'provider id'
    AFTER source_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN model_id VARCHAR(128) NOT NULL DEFAULT 'default'
    COMMENT 'model id'
    AFTER provider_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN strategy_id VARCHAR(64) DEFAULT ''
    COMMENT 'worker strategy id'
    AFTER model_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN previous_workers INT NOT NULL DEFAULT 0
    COMMENT 'previous effective workers'
    AFTER strategy_id
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN min_workers INT NOT NULL DEFAULT 1
    COMMENT 'minimum workers'
    AFTER baseline_workers
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN success_count INT NOT NULL DEFAULT 0
    COMMENT 'recent success count'
    AFTER running_count
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN failure_count INT NOT NULL DEFAULT 0
    COMMENT 'recent terminal failure count'
    AFTER success_count
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN error_rate DECIMAL(8,6) NOT NULL DEFAULT 0
    COMMENT 'terminal failure rate'
    AFTER failure_count
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD COLUMN matched_rule JSON DEFAULT NULL
    COMMENT 'matched adjustment rule'
    AFTER error_rate
    """,
    """
    ALTER TABLE swe_cron_dispatch_worker_capacity
    ADD INDEX idx_dispatch_capacity_scope (
        source_id, provider_id, model_id, strategy_id, created_at
    )
    """,
]

# SQL for adding async_status column to cron_executions table
ALTER_CRON_EXECUTIONS_ASYNC_STATUS = [
    """
    ALTER TABLE swe_cron_executions
    ADD COLUMN async_status VARCHAR(16) DEFAULT NULL
    COMMENT '异步任务执行状态: success/error'
    AFTER status
    """,
    """
    ALTER TABLE swe_cron_executions
    ADD INDEX idx_async_status (async_status)
    """,
]

# SQL for adding filename column to cron_subtasks table
ALTER_CRON_SUBTASKS_FILENAME = """
ALTER TABLE swe_cron_subtasks
ADD COLUMN filename VARCHAR(512) NOT NULL COMMENT '文件名'
AFTER task_id
"""

# SQL for adding new columns to cron_subtasks table
ALTER_CRON_SUBTASKS_NEW_COLUMNS = [
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN task_type VARCHAR(16) DEFAULT NULL
    COMMENT '任务类型: list/plan'
    AFTER filename
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN custuid VARCHAR(64) DEFAULT NULL
    COMMENT '任务中客户ID'
    AFTER task_type
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN cust_nm VARCHAR(255) DEFAULT NULL
    COMMENT '任务中客户名称'
    AFTER custuid
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN bbk_org_id VARCHAR(64) DEFAULT NULL
    COMMENT '客户归属二级分行ID'
    AFTER custuid
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN template_id BIGINT DEFAULT NULL
    COMMENT 'HTML模板ID'
    AFTER cust_nm
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN result_id VARCHAR(100) DEFAULT NULL
    COMMENT '待填充数据ID'
    AFTER template_id
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN notification_content_wplus VARCHAR(5000) DEFAULT NULL
    COMMENT 'W+渠道通知消息内容'
    AFTER cust_nm
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD COLUMN notification_content_zhaohu VARCHAR(5000) DEFAULT NULL
    COMMENT '招乎渠道通知消息内容'
    AFTER notification_content_wplus
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD INDEX idx_task_type (task_type)
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD INDEX idx_custuid (custuid)
    """,
    """
    ALTER TABLE swe_cron_subtasks
    ADD INDEX idx_bbk_org_id (bbk_org_id)
    """,
]

# SQL for adding need_notification column
ALTER_CRON_SUBTASKS_NEED_NOTIFICATION = """
ALTER TABLE swe_cron_subtasks
ADD COLUMN need_notification TINYINT(1) DEFAULT 1
COMMENT '是否需要通知: 0-否, 1-是'
AFTER notification_content_zhaohu
"""

ALTER_CRON_EXECUTIONS_NEED_NOTIFICATION = """
ALTER TABLE swe_cron_executions
ADD COLUMN need_notification TINYINT(1) DEFAULT 1
COMMENT '是否需要通知: 0-否, 1-是'
AFTER async_status
"""


# 任务类型报表落盘表（供 /api/monitor/cron/report/task-type* 读取；表结构同时写在
# gauss/task_type_report_tdsql.sql，数据写入由现场作业负责，本仓库不含装载脚本）。
#
# 维度列统一 NOT NULL DEFAULT ''，两种特殊值含义不同、不能混用：
#   - 'ALL' 表示“该组合用不到的维度”（源侧口径），接口出参必须还原成 null；
#   - 空串表示“名单里机构号缺失”，是真实分组，保留原值。
# 列宽按源表取宽，避免写入被截断；宽列拼不出主键（InnoDB 索引上限 3072 字节），
# 因此用 dim_hash（组合 + 四个维度列的 MD5）承担唯一性，重跑仍可按它覆盖。
#
# 主键不要自增列：报表行的业务唯一键是 (prt_dt, source_id, dim_hash)，直接用它做主键，
# 分布式 TDSQL 的分片键（prt_dt / source_id）也落在主键里；接口不引用自增列。
# 副作用是二级索引里会带整段主键（约 440 字节），换来的是没有无意义的自增消耗。
#
# 覆盖方式由写入方决定（同键 upsert 即可幂等重写）；接口按主键读取、不做版本过滤，
# 因此源侧已消失的维度行（客户经理离职、技能下线）若没被清掉，会继续带着旧数值出数。
CREATE_TASK_TYPE_REPORT_SNAPSHOT_TABLE = """
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
"""

# 批次表：记录每个 数据日期 + 来源 的就绪状态与名单快照日，由写入方维护；
# 接口只读 status='ready' 的批次，且必须有 sync_date（算有权限客户经理数）。
CREATE_TASK_TYPE_REPORT_BATCH_TABLE = """
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
"""


# pylint: disable=too-many-statements
async def init_database_tables() -> None:
    """Initialize database tables for cron monitoring.

    Creates the cron_jobs, cron_executions, extracted_customer_names,
    and cron_subtasks tables if they don't exist.
    """
    db = get_db_connection()

    try:
        await db.execute(CREATE_CRON_JOBS_TABLE)
        logger.info("Created cron_jobs table (or already exists)")

        await db.execute(CREATE_CRON_EXECUTIONS_TABLE)
        logger.info("Created cron_executions table (or already exists)")

        for statement in ALTER_CRON_EXECUTIONS_NOTIFICATION_COLUMNS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron execution notification columns")

        for statement in ALTER_CRON_EXECUTIONS_READ_COLUMNS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron execution read marker columns")

        for statement in ALTER_CRON_EXECUTIONS_DISPATCH_COLUMNS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron execution dispatch identity columns")

        await db.execute(CREATE_EXTRACTED_CUSTOMER_NAMES_TABLE)
        logger.info(
            "Created extracted_customer_names table (or already exists)",
        )

        await db.execute(CREATE_CRON_SUBTASKS_TABLE)
        logger.info("Created cron_subtasks table (or already exists)")

        await db.execute(CREATE_TASK_TYPE_REPORT_SNAPSHOT_TABLE)
        logger.info(
            "Created task_type_report_snapshot table (or already exists)",
        )

        await db.execute(CREATE_TASK_TYPE_REPORT_BATCH_TABLE)
        logger.info(
            "Created task_type_report_batch table (or already exists)",
        )

        await db.execute(CREATE_CRON_RESULT_INDEX_TABLE)
        logger.info("Created cron_result_index table (or already exists)")

        await db.execute(CREATE_CRON_DISPATCH_BATCHES_TABLE)
        logger.info("Created cron_dispatch_batches table (or already exists)")

        for statement in ALTER_CRON_DISPATCH_BATCHES_MODEL_COLUMNS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron dispatch batch model columns")

        await db.execute(CREATE_CRON_DISPATCH_INTENTS_TABLE)
        logger.info("Created cron_dispatch_intents table (or already exists)")

        for statement in ALTER_CRON_DISPATCH_INTENTS_INDEXES:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron dispatch intent indexes")

        await db.execute(CREATE_CRON_DISPATCH_EVENTS_TABLE)
        logger.info("Created cron_dispatch_events table (or already exists)")

        await db.execute(CREATE_CRON_DISPATCH_WORKER_CAPACITY_TABLE)
        logger.info(
            "Created cron_dispatch_worker_capacity table (or already exists)",
        )

        for statement in ALTER_CRON_DISPATCH_WORKER_CAPACITY_COLUMNS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron dispatch worker capacity columns")

        await db.execute(CREATE_CRON_DISPATCH_SCOPE_LEASES_TABLE)
        logger.info(
            "Created cron_dispatch_scope_leases table (or already exists)",
        )

        await db.execute(CREATE_CRON_DISPATCH_MODEL_WORKER_POLICY_TABLE)
        logger.info(
            "Created cron_dispatch_model_worker_policy table (or already exists)",
        )

        await db.execute(CREATE_CRON_DISPATCH_WORKER_STRATEGY_TABLE)
        logger.info(
            "Created cron_dispatch_worker_strategy table (or already exists)",
        )

        for statement in ALTER_CRON_EXECUTIONS_ASYNC_STATUS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron execution async_status column")

        try:
            await db.execute(ALTER_CRON_SUBTASKS_FILENAME)
        except Exception as exc:  # pylint: disable=broad-except
            message = str(exc).lower()
            if "duplicate" not in message and "exists" not in message:
                raise
        logger.info("Ensured cron subtasks filename column")

        for statement in ALTER_CRON_SUBTASKS_NEW_COLUMNS:
            try:
                await db.execute(statement)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured cron subtasks new columns")

        # 添加 need_notification 字段
        for alter_sql in [
            ALTER_CRON_SUBTASKS_NEED_NOTIFICATION,
            ALTER_CRON_EXECUTIONS_NEED_NOTIFICATION,
        ]:
            try:
                await db.execute(alter_sql)
            except Exception as exc:  # pylint: disable=broad-except
                message = str(exc).lower()
                if "duplicate" not in message and "exists" not in message:
                    raise
        logger.info("Ensured need_notification columns")

        await _ensure_cron_jobs_extra_schema()

    except Exception as e:
        logger.error("Failed to initialize database tables: %s", e)
        raise


async def _ensure_cron_jobs_extra_schema() -> None:
    """Ensure newly added cron job columns and indexes exist."""
    db = get_db_connection()
    database_row = await db.fetch_one("SELECT DATABASE() AS db_name")
    database_name = database_row.get("db_name") if database_row else None
    if not database_name:
        logger.warning("Skip cron job schema migration: database unknown")
        return

    for column_name, alter_sql in CRON_JOBS_EXTRA_COLUMNS.items():
        row = await db.fetch_one(
            """
            SELECT COUNT(*) AS count
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = %s
              AND TABLE_NAME = 'swe_cron_jobs'
              AND COLUMN_NAME = %s
            """,
            (database_name, column_name),
        )
        if not row or int(row.get("count", 0)) == 0:
            await db.execute(alter_sql)
            logger.info("Added swe_cron_jobs.%s", column_name)

    for index_name, create_sql in CRON_JOBS_EXTRA_INDEXES.items():
        row = await db.fetch_one(
            """
            SELECT COUNT(*) AS count
            FROM INFORMATION_SCHEMA.STATISTICS
            WHERE TABLE_SCHEMA = %s
              AND TABLE_NAME = 'swe_cron_jobs'
              AND INDEX_NAME = %s
            """,
            (database_name, index_name),
        )
        if not row or int(row.get("count", 0)) == 0:
            await db.execute(create_sql)
            logger.info("Added swe_cron_jobs index %s", index_name)
