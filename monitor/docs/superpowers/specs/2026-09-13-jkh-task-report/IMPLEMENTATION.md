# 接口接入、TDSQL 落地与验收

2026-09-14 实现状态：接口已按本文接入，完整服务、SQL、模型和路由位于 README.md 第 4 节列出的正式模块。本文片段用于说明流程，维护时以正式代码和测试为准。真实 TDSQL 验证仍未执行。

后续维度扩展已经实现：新增 group_by=manager 与 skill_detail 开关；六种组合、经理属性和技能明细补零规则见 [DIMENSIONS.md](DIMENSIONS.md)。默认汇总行为保持兼容。

2026-09-15 的范围、分页、options/export 和统一错误结构按 [CONSOLE_API.md](CONSOLE_API.md) 执行，优先于本文保留的基础流程片段。所有报表接口现要求 X-Bbk-Id；省略分页仍全量。

## 1. HTTP 契约

新增 `GET /api/monitor/cron/task-type-report`。路由 prefix 用 `/monitor/cron`，子路径 `/task-type-report`，`/api` 由应用挂载。

| 参数 | 位置/类型 | 规则 |
| --- | --- | --- |
| X-Source-Id | Header/string | 本新接口必填，trim 后非空，最大 64 字符；同一次查询只统计一个来源 |
| X-Bbk-Id | Header/string | 必填；100 为总行范围，其他值强制本分行，冲突403 |
| start_date | Query/date | 必填，严格 YYYY-MM-DD |
| end_date | Query/date | 必填，严格 YYYY-MM-DD，包含当天；不得早于 start_date |
| group_by | Query/enum | overall（默认）、branch、org、manager |
| skill_detail | Query/bool | 默认 false；为 true 时要求 branch/org/manager |
| first_bbk_id | Query/string | 可选，trim 后非空，最大 64 字符，保留前导零 |
| first_bbk_name | Query/string | 可选，trim 后非空，最大 256 字符，精确匹配名单名称 |
| org_id | Query/string | 可选，trim 后非空，最大 64 字符 |
| org_name | Query/string | 可选，trim 后非空，最大 256 字符，精确匹配名单名称 |
| task_type / user_id / keyword | Query | 类型/经理精确筛选与经理关键字，见 CONSOLE_API.md |
| page / page_size | Query | 可选且成对，仅 manager 并要求 task_type |

一次筛选一个分行/支行，支持条件交集。未指定 task_type 时保留三类；经理分页与全量 XLSX、关键字搜索已按 CONSOLE_API.md 扩展。日期最多93个自然日，旧统计方法不变。

请求示例：

```http
GET /api/monitor/cron/task-type-report?start_date=2026-09-01&end_date=2026-09-13&group_by=org&first_bbk_name=甲分行
X-Source-Id: RMASSIST
```

来源与机构参数只是数据过滤，不代表鉴权。沿用项目当前受控网关/运维访问边界；已有工程未证实存在通用分行授权依赖，不编造 `require_admin` 或信任客户端角色。若发布环境要求细粒度授权，应使用该环境已有可信身份范围，在查询前交集约束来源和机构。本需求不扩建身份系统。

### 1.1 响应

```json
{
  "metric_version": "jkh_task_report_v1",
  "start_date": "2026-09-13",
  "end_date": "2026-09-13",
  "timezone": "Asia/Shanghai",
  "source_id": "RMASSIST",
  "sync_date": "2026-09-13",
  "group_by": "branch",
  "resolved_filters": {"first_bbk_id": "001", "org_id": null},
  "ratio_unit": "percent",
  "read_evidence": {"push": "execution_is_read", "ask": "assumed_from_success"},
  "consistency": "live",
  "warnings": ["period_ratios_not_cohort_conversion"],
  "items": [
    {
      "first_bbk_id": "001",
      "first_bbk_name": "甲分行",
      "org_id": null,
      "org_name": null,
      "task_type": "push_plan",
      "task_type_name": "推送(名单+方案)",
      "skill_count": 2,
      "permission_manager_count": 1,
      "active_manager_count": 1,
      "suc_execute_job": 1,
      "read_tasks": 2,
      "read_rate": 200.0,
      "recommended_customers": 2,
      "read_customer_count": 1,
      "plan_read_rate": 50.0,
      "insight_customer_count": 1,
      "click_to_insight_rate": 50.0,
      "insight_count": 2,
      "phone_customer_count": 1,
      "click_to_phone_rate": 50.0,
      "phone_count": 2
    }
  ]
}
```

示例为默认汇总，仅展开一行，实际每个机构/经理固定返回三行。overall 的四个机构显示字段均 null；branch 的两个 org 字段 null；org 同时返回父分行和支行；manager 同时返回分支行和经理信息。技能明细按实际关联的维度对象+技能补三行，详见 DIMENSIONS.md。

Pydantic 行模型的计数字段：普通指标 `int >= 0`，`active_manager_count` 以及字段 8/9/11/13 使用 `int | None`。比例用 `float | None`、下限 0、无 100 上限。响应始终保留字段和 null，不使用 `exclude_none=True`。

顶层 `sync_date: str | None`；空名单响应 items=[] 且 sync_date=null，warnings 增加 `empty_roster`。机构筛选无匹配返回 items=[]，warnings 增加 `no_matching_organization`。即使结果为空也返回有效日期、来源和 group_by。

正常响应固定 warnings 包含 `period_ratios_not_cohort_conversion`，让消费方明确期间比值。更多数据质量报警通过日志和验收报告记录，不在 v1 添加昂贵的每请求全库巡检。

### 1.2 错误契约

```json
{"detail": {"code": "organization_name_ambiguous", "message": "支行名称对应多个机构，请同时提供分行条件。"}}
```

| HTTP | code / 返回结构 | 场景 |
| --- | --- | --- |
| 422 | report_validation_error | 参数格式、缺必填、无效枚举、空白字符串、日期/分页非法，结构为 detail.code/message |
| 422 | organization_name_ambiguous | 精确名称匹配多个机构键，需增加父机构/ID 条件 |
| 503 | jkh_roster_ambiguous | 快照同用户属于多个不同机构 |
| 503 | report_database_unavailable | 数据库连接不可用 |
| 504 | report_query_timeout | 整个报表超过 30 秒 |
| 500 | report_query_failed | 其他数据库/查询异常，内部记录异常，不返回 SQL 或敏感参数 |

名称+ID 组合无结果统一按“无匹配机构”返回 200 空列表，不额外查库区分两者冲突与机构不存在。

## 2. 名称解析逻辑

快照选定后再解析名称；每次最多一个分行解析、一个支行解析。参数值全部绑定；可选条件通过固定分支追加。

### 分行名称

```sql
SELECT DISTINCT first_bbk_id
FROM jkh_user_inf
WHERE sync_date = %s AND first_bbk_nm = %s
  AND first_bbk_id IS NOT NULL AND first_bbk_id <> ''
-- 已传 first_bbk_id 时追加：AND first_bbk_id = %s
LIMIT 2;
```

0 行：返回无匹配；1 行：将 ID 写入 Scope；2 行：422 ambiguous，不把多个 ID 静默当成一个分行。

### 支行名称

```sql
SELECT DISTINCT first_bbk_id, org_id
FROM jkh_user_inf
WHERE sync_date = %s AND org_nm = %s
  AND first_bbk_id IS NOT NULL AND first_bbk_id <> ''
  AND org_id IS NOT NULL AND org_id <> ''
-- 已有分行 ID 时追加：AND first_bbk_id = %s
-- 已有支行 ID 时追加：AND org_id = %s
LIMIT 2;
```

0 行：返回无匹配；1 行：同时写入分行、支行 ID；2 行：422 ambiguous。先解析分行，再解析支行。

只传 org_id 而不传分行时，按原需求字段等值匹配所有该 org_id 的机构；group_by=org 仍以父分行+支行分组。若用户要求唯一支行，应同时传 first_bbk_id。名字是精确匹配，不做 LIKE、拼音或近似猜测；不同 collations 的大小写语义以数据库为准。

名称解析返回显式的 `matched: bool`。解析失败后绝不能把 ID 置 None 然后继续全范围查询。空白参数直接 422，不能解释为“省略”。

## 3. 服务核心接入逻辑

以下为服务流程说明。正式实现将简单响应构造放在 get_report 内，名称解析返回 `(matched, filters)`；SQL 与组装逻辑已经迁移到正式模块。

```python
# 位于新的 services/cron/task_type_report.py
# params 为已校验的 Pydantic 参数对象。
async def get_report(self, params, source_id):
    db = get_db_connection()
    start, stop = date_bounds(params.start_date, params.end_date)
    # resolver 要收到原来的截止日，而不是 stop 的次日。
    snapshot_end = datetime.combine(params.end_date, time.max)
    sync_date = await QueryService._resolve_jkh_sync_date(db, snapshot_end)
    if sync_date is None:
        return make_response(params, source_id, None, [], warning="empty_roster")

    resolved = await resolve_organization_filters(db, sync_date, params)
    if not resolved.matched:
        return make_response(params, source_id, sync_date, [],
                             warning="no_matching_organization")
    scope = Scope(
        source_id=source_id,
        sync_date=sync_date,
        start=start,
        stop=stop,
        group_by=params.group_by,
        first_bbk_id=resolved.first_bbk_id,
        org_id=resolved.org_id,
    )
    items = await query_core(db, scope)
    return make_response(params, source_id, sync_date, items, resolved=resolved)
```

`make_response` 是本服务的简单响应组装方法，不引入通用响应框架。空响应也应填充 section 1.1 中的元数据。生产核实时区不同后，只在创建 SQL 参数时转换，不改日期快照选择的业务日期。

路由保持薄层：

```python
router = APIRouter(prefix="/monitor/cron", tags=["cron"])

@router.get("/task-type-report", response_model=TaskTypeReportResponse)
async def task_type_report(
    params: TaskTypeReportParams = Depends(),
    source_id: str = Header(alias="X-Source-Id", min_length=1, max_length=64),
    service: TaskTypeReportService = Depends(get_task_type_report_service),
):
    # 在服务前 trim 并验证 source，按 section 1.2 映射具体异常。
    return await asyncio.wait_for(service.get_report(params, source_id), timeout=30)
```

上面是流程片段，完整错误映射、依赖工厂和模型已在正式模块实现。`query_core` 仅负责数据库聚合，HTTP、快照和名称解析分别由路由和服务处理。

请求模型对 start/end 做 model_validator：范围合法且自然日数 ≤93；日期字符串严格格式检查，避免自动接受时间戳或其他日期格式。nullable 字段与非空计数字段分别定义；type 枚举独立命名 `ReportTaskType`，避免与现有 Cron `TaskType` 冲突。

数据库错误必须整份失败，不返回缺某个指标的半成品，也不把查询异常转换成 0。`asyncio.wait_for` 只限制客户端等待，不保证数据库端 SQL 已取消；需按驱动/代理支持能力核实取消后连接可用性，并在服务端设置匹配的查询时间限制。不能直接搬用未验证的 MySQL hint。

## 4. 数据库核实清单

使用已有安全的数据库访问方式，只读检查。不要在文档、日志或回答中输出连接密码。

1. `SELECT VERSION()`，记录 TDSQL 产品/内核/代理版本；各表 SHOW CREATE TABLE、SHOW INDEX，记录 shardkey、是否广播表/单表、collation、主键/全局唯一约束。
2. 核实名单 `sync_date` 是统一 YYYY-MM-DD 字符串，以及 `first_bbk_nm/org_nm` 实际列名。检查选择快照是否存在同用户多机构、空 user_id、空机构号；不以生产 schema 未知为由创造新列。
3. 核实 `e.id` 主键、`j.id` 唯一性、Trace 全局唯一性、sp.skill_id/user_id/start_time、c.trace_id/user_id/source_id/template_type 等完整存在。早期 DDL 缺 sp.skill_id 时需核对技能字段初始化迁移，而不是退回 skill_name 猜测。
4. 推送仍核对两个 success 状态；ask 直接 COUNT(DISTINCT sp.trace_id)，不以 Trace 表或 has_error 作为筛选条件。
5. 同一条已知业务请求的实际发生时间，对照 e.actual_time、sp.start_time、c.clicked_at；核实容器 TZ、前端 ISO 时间解析与数据库 DATETIME 存储。三表存储不一致时给 SQL 构造分别传 exec_start/span_start/click_start 等边界，增加跨日测试。
6. 客户级点击按 source+trace 关联 Span；任务级 read_tasks 不读取埋点，直接等于成功任务数。
7. 检查 job 物理删除、孤立 Span/Trace、跨 source Trace ID 冲突、事件 customer_id 与子任务 custuid 不一致等样本，记录影响量。不能用 LIMIT 抽出的明细冒充全量准确统计。

已核实的本地代码不足以证明生产数据库一致；核实结果应保存为同目录 `database-validation.md`，记录结构和汇总，不放个人/客户明细。

## 5. TDSQL 查询策略

### 5.1 先保留固定分组查询

参考版共 10 条查询，加快照和名称解析最多 13 条。顺序执行便于定位，不在首版并发十个跨分片查询。后续若证据证明网络往返是瓶颈，最多引入受限并发，重新核对连接池和多实例总压力。

2026-09-16 更新：线上反馈报表查询超时后，已按上一段预留的方式把 8 条事实查询改为受限并发（默认 4，`REPORT_QUERY_CONCURRENCY`，设为 1 即退回串行），`roster_conflicts`、`permissions` 与分页阶段仍串行；查询条数与口径不变。同批把纯行组装拆到 `task_type_report_rows.py`，并在 `stage=get_report` 日志上增加 `stages` / `slowest` / `slowest_ms` 汇总字段。EXPLAIN、索引与压测仍未在目标 TDSQL 完成，排查入口见 [analysis/playbook/task-type-report-build-queries.md](../../../../analysis/playbook/task-type-report-build-queries.md)。

同日补充：分页键查询改为先在事实里对 `(人员, 技能)` 去重、再做名单过滤与机构映射，`page_count` 与 `page_keys` 由 `asyncio.gather` 并发取回（分页阶段自此不再全部串行），指标 SQL 与统计口径不变；本模块执行的每条查询另输出一行 `task_type_report_sql`（含 `sql` 与 `params`）便于逐指标核对口径。分页的数据库侧收益仍以目标 TDSQL 的 EXPLAIN 与实测为准。

同一名单派生表在多条 SQL 中出现并不意味着被数据库缓存或只计算一次；优化器可能合并或物化派生表。腾讯文档说明 TDSQL 支持跨节点 JOIN/子查询，但相同 shardkey 的关联有更好的本地性。**因此，当前 SQL 是正确性基线，不能仅凭 MySQL 兼容就承诺 TDSQL 性能。** 依据：[TDSQL 开发概览](https://www.tencentcloud.com/document/product/1042/38142)、[MySQL 派生表优化](https://dev.mysql.com/doc/refman/8.0/en/derived-table-optimization.html)。

参考 SQL 不依赖 CTE、窗口函数或临时表，但相关 EXISTS、CASE 中的子查询和派生表仍需通过目标 TDSQL 代理验证。若计划显示 push 的分类 EXISTS 多次扫描、clicks 的 OR 导致劣化，可将点击查询拆成两条互斥类型聚合；指标口径和测试保持不变，不为少一条 SQL 承担无界扫描。

### 5.2 候选索引，按计划选择

下列是候选访问路径，不是要求全部执行的 DDL。先检查已有等效前缀索引、分片约束、选择性和写入成本。

| 表 | 候选列顺序/已有能力 | 对应访问 |
| --- | --- | --- |
| jkh_user_inf | `(sync_date, user_id, first_bbk_id, org_id)` | 快照去重与成员匹配 |
| jkh_user_inf | `(sync_date, first_bbk_id, org_id, user_id)` | 常见单分行/支行过滤 |
| jkh_user_inf | `(sync_date, first_bbk_nm)`、`(sync_date, first_bbk_id, org_nm)` | 名称解析确实慢时再评估 |
| swe_tenant_init_source | 既有 `(tenant_id, source_id)` | 权限 EXISTS |
| swe_cron_jobs | id 主键；`(source_id, id)` | 由来源筛选任务并关联执行 |
| swe_cron_executions | `(actual_time, job_id)` 或 `(job_id, actual_time)` | 日期驱动与来源任务驱动，二选一按选择性评估 |
| swe_cron_executions | 既有 trace_id 索引，必要时 `(trace_id, job_id)` | 全历史排除 Cron、点击关联 |
| swe_cron_subtasks | 既有 trace_id 索引，候选 `(trace_id, custuid)` | 子任务存在性、客户去重 |
| swe_tracing_spans | `(source_id, start_time)` | 主动任务窗口 |
| swe_tracing_spans | `(source_id, trace_id, skill_id)` | 资格/统计技能判断 |
| swe_marketplace_skills | `(source_id, include_in_statistics, skill_id)` | 统计技能筛选 |
| swe_html_preview_click_events | 既有 `(source_id, clicked_at)` | 当期事件扫描 |


FIND_IN_SET 与 CSV 技能绑定沿用项目，不能指望在 skill_ids 上建普通索引就解决成员查询。先用 source 和日期缩小任务，再进行技能判断。若该关联成为确定瓶颈，再单独设计 job-skill 关系表与回填；不在本次设计预建。

按 trace 查子任务/执行的全历史 EXISTS 逻辑不能随意加日期来“优化”，否则改变分类。如果它造成跨分片广播，优先检查 shardkey 共置、索引与代理路由；无可行在线计划时再评估独立事实层。

### 5.3 不默认引入临时表、缓存或日汇总

当前 DatabaseConnection 每次 fetch 可能使用不同池连接，普通 SESSION 临时表在后续查询未必可见；TDSQL 代理也可能有额外限制。若后续实测需要物化任务集合，必须显式单连接 acquire、限定生命周期并验证代理支持，不可直接在现有 fetch_all 链前加 CREATE TEMPORARY TABLE。

Distinct 客户/技能不能直接用每日计数求和得到跨日去重。若将来做离线加速，保存可跨日去重的业务键，并处理晚到子任务、点击和技能开关变化；本次不引入该复杂度。

### 5.4 一致性与多实例

Scope、sync_date、聚合结果只放请求局部变量，服务实例无可变请求状态。初版不依赖 Redis、不使用进程内锁控制数据归属。

每条查询独立读取，因此 response.consistency=`live`，同一次响应不保证数据库事务快照；晚到数据或执行状态变化可能造成列间短暂不一致。不要把同一 sync_date 描述成跨表一致事务快照。如果业务后续明确要求严格一致读取，再评估目标 TDSQL 的只读一致事务，并在同一 acquire 连接中运行全部查询；届时应调整元数据和集成测试。

机构快照应是完整批次；参考版检测到组装时机构键变化会抛错。相同机构下实时计数变化不会被该检测消除。

### 5.5 性能验收记录

使用有代表性的 1/7/31/93 日窗口，overall/单分行/全部支行，以及热、冷数据；并发至少覆盖 1 和 5 个报表请求。记录每条 SQL 的计划、实际耗时、扫描/返回行数、涉及分片数、连接等待和整体 P50/P95。

初始工程目标：31 日典型查询 P95≤5 秒、93 日≤15 秒、报表总超时30秒。这是建议验收目标，不是已测结果；应在部署硬件和样本规模明确后记录最终门槛。性能不过关时按慢 SQL 定位，不能删掉统计过滤或改成采样计数。

先在测试/只读环境 EXPLAIN；EXPLAIN ANALYZE 若目标版本支持会执行查询，应仅对有界样本使用。索引变更按项目正常迁移流程，不在服务启动时自动创建。

## 6. 必须完成的测试清单

### 已提供的 SQL 对账

core_reference.py 的所有 10 条 SQL 均在测试内实际执行，只有 `%s→?` 与 FIND_IN_SET 做 SQLite 适配，非 mock 返回固定数值。

覆盖：重复名单/技能/子任务/点击去重；同 Trace 多 Span 只算一次任务；三种分组；同 org_id 跨分行；0 任务机构补三行；异常机构冲突；source 过滤；非名单点击；点击人与 owner/执行人分离；主动阅读不依赖埋点、没有 Trace 表仍可查询；前期任务当期点击；全历史 Cron 排除；job 删除差异；overall DISTINCT 不可相加；窗口 stop 排除；比例与注入值绑定。

### 正式开发追加

| 验收项 | 明确预期 |
| --- | --- |
| 名单日期优先级 | 复用现有规则，月末/闰年/全表最早回退不变 |
| 空名单 | SQL 不继续执行，200 items=[]，sync_date=null |
| 日期边界 | 次日零点排除、末日微秒包含、start=end 允许、倒置/超过93日422 |
| 请求格式 | 非 YYYY-MM-DD、未知group_by、空白来源/名称/ID 422 |
| 名称解析 | 同名支行歧义422；加父分行后命中；无匹配200空列表，无全范围回退 |
| 三行结构 | 普通 count 为整数；ask active null；push_other 字段8起全部 null；零分母 null |
| 主动状态 | 不筛选 has_error 或 Trace 状态；多个 Span 按 trace_id 去重；read_tasks 等于成功数 |
| 类型排他 | 无子任务主动聊天排除；失败非名单推送排除；有 Cron 历史不进入主动 |
| 来源隔离 | 相同 skill_id 不同 source 不串；点击 source 与任务 source 必须一致 |
| 代理/数据库异常 | 任一 SQL 失败整份失败；不把缺失结果当零；超时按504 |
| 并发参数隔离 | 两个日期/分行/来源同时请求，SQL参数和响应不互相污染 |
| 路由注册 | 在真实 app 上测试 /api/monitor/cron/task-type-report；旧接口仍可访问 |
| 数据库方言 | TDSQL 上与同一数据夹具的期望逐列一致 |
| 查询数量 | 机构从1增至100，查询次数不随机构增长 |

## 7. 本次验证记录

- 2026-09-13 设计阶段参考对账：17 项通过。
- 2026-09-14 正式实现：ask 修正后的查询/服务/真实 app 接口测试共 59 项，与既有分行查询、技能绑定和导出 66 项回归组合运行，**125 项通过**；文档参考测试另有 17 项，总计 **142 项通过**。
- 随后新增六种维度组合：当前正式报表测试 85 项与既有回归 66 项，**151 项通过**，含经理信息、多技能重叠、目录去重、权限重复展示和固定查询次数验证。
- 真实 app 的 ASGI 请求已贯穿路由、请求模型、服务、现有快照方法、SQL、响应模型；数据库使用 SQLite 适配，未触发真实数据库连接或应用启动生命周期。
- Black 按 Python 3.10 语法目标和 79 列检查新增的 6 个 Python 文件；既有生产方法未改动。
- 未连接生产/测试 TDSQL，没有 EXPLAIN、索引变更或压测结果。
- 未执行全仓库 pre-commit 与全部 pytest。既有 TestClient 的两条依赖弃用警告不影响测试结果，未为消除警告修改依赖。

回归命令（monitor 目录）：

```powershell
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_queries.py tests/test_task_type_report_api.py tests/test_jkh_branch_queries.py tests/test_cron_skill_binding_queries.py tests/test_branch_export.py tests/test_branch_export_api.py -q -p no:cacheprovider
```

正式实现相对参考代码仅作以下等价或局部防护改进：点击派生表只投影需要的列；机构筛选后名单为空即早退；null/空机构 ID 使用稳定区分排序；补齐跨字段校验、最大日期溢出校验、名称解析、错误映射和响应元数据。所有指标计算口径保持 DESIGN.md 的 v1 定义。

## 8. 后续维护指令

> task-type-report 已在独立模块实现。维护时先读 DESIGN.md，保持 jkh_task_report_v1 的统计粒度、快照、时间、删除过滤和 null 规则。修改正式模块及正式测试，不将文档参考代码重新覆盖生产实现。不要把比例限制为100，不要累加分组后的客户去重数，不要改旧报表。接下来在目标 TDSQL 环境完成结构、时区、执行计划与压测核验；遇到差异记录并按真实代码/DDL修正映射和测试。最终报告测试结果，以及真实 TDSQL 验证完成或尚未完成的项目；不得把 SQLite 对账当作生产性能验证。修改现有符号和提交前遵守仓库 GitNexus 规则。

### ask 口径修正记录

2026-09-14 按用户最新指令：ask 的任务、技能、客户方案和点击归属均以 Span 为入口；成功数 COUNT(DISTINCT sp.trace_id)，无 has_error 或 Trace 状态条件；read_tasks 等于成功数，read_evidence.ask 为 assumed_from_success。任务级查看不查埋点，客户级点击仍维持事件统计。新增测试先验证旧实现缺少 Trace 表时失败，改造后同一测试及完整回归通过。未修改推送查询及旧报表方法；GitNexus impact 已尝试，但索引存储版本不兼容，返回 UNKNOWN，未将其表述为低风险分析结果。
