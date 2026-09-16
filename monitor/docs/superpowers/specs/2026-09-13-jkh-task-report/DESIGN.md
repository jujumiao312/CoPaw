# 统计口径与核心 SQL

本文为 `jkh_task_report_v1` 的口径真源。2026-09-14 按用户最新指令修正 ask：Span 主表、trace_id 去重计成功、已读等于成功数。接口开发遵循本文；原始 SQL 中的笔误和未定义部分按本页规则补齐。

当前已增加客户经理与技能明细维度。本文定义基础指标；新维度的分组键、字段映射、技能归属、补零和性能规则以 [DIMENSIONS.md](DIMENSIONS.md) 为准。技能明细不改变每项指标的时间、删除、状态与去重口径，但限定到关联统计技能。

2026-09-15 新增 `insight_count` 和 `phone_count`。二者与对应客户数使用同一点击基础集合和限制条件，区别是按事件行计数，不按 customer_id 去重。

## 1. 原需求到设计的明确决策

| 原需求问题 | 本版执行规则 | 性质 |
| --- | --- | --- |
| 路径写为 `prompt/claw/_kb` | 实际读取 `D:/cmbwork/claw/prompt/claw_kb` | 文件定位修正 |
| `async_status='sucess'` | `async_status='success'` | 与已核实代码统一 |
| 多处缺 FROM / ON、错误 s 别名 | 修复语法，显式使用 e/j/sp/c/r 别名 | 语法修正 |
| `_name` 机构字段 | SQL 使用 `first_bbk_nm / org_nm`，响应使用 `_name` | 代码文档映射，生产 DDL 待核实 |
| 字段 14 复制了洞察字段名 | `click_to_phone_rate`，电访客户覆盖率 | 修正重复命名 |
| 主动提问成功数 | 基于合格 Span 的 COUNT(DISTINCT sp.trace_id) | 用户最新明确口径 |
| 主动成功状态筛选 | 不按 has_error 或 Trace 状态过滤 | 用户最新指令直接按 trace_id 去重计数 |
| 主动提问时间字段 | 使用 swe_tracing_spans.start_time | 主表改为 Span |
| 主动提问查看数 | read_tasks = suc_execute_job | 无任务级埋点，按用户要求赋值 |
| 主动点击 JOIN cron_jobs 可能无任务 ID | 根据点击 source+trace 关联 Trace/Span，统计技能来自 Span | 修复主动提问无 Cron 任务的问题 |
| 活跃人数缺少三类任务的分类规则 | 当前 active 且未删除任务，在窗口内有相应类型执行；按任务 owner 去重 | 以实际执行结果判类型，避免推测未来任务类型 |
| 非名单任务未定义字段 6 | 沿用执行表 is_read=1 | 对齐另一推送类型 |
| 字段 6 中文写“客户数”，SQL 实际数执行 | 显示“已查看任务数”，字段保留 read_tasks | 保留实际 SQL 单位 |
| 字段 8 写“方案数”，SQL 实际按客户去重 | 显示“客户级方案客户数（去重）” | 保留 COUNT DISTINCT custuid 的口径 |
| 日期、来源、零分母未定义完整 | 自然日半开区间；单一来源必填；零分母 null | 新接口契约，不改变旧报表 |

上述建议已经形成可执行 SQL，无需接手模型重新设计。若业务以后改为技能调用次数、方案份数或同批次转化率，应作为新口径修改指标和测试，不能悄悄替换。

## 2. 基础统计集合

### 2.1 人员与机构

所有指标都必须匹配同一 `jkh_user_inf.sync_date`，以该快照的机构归属分组，业务记录自身 bbk_id 不参与新报表分组。

| 指标来源 | 匹配名单的用户字段 |
| --- | --- |
| 有权限人数 | `swe_tenant_init_source.tenant_id` |
| 当前活跃人数 | `swe_cron_jobs.tenant_id` |
| 推送执行、推送技能、推送客户方案 | `swe_cron_executions.tenant_id` |
| 主动提问任务、技能、客户方案 | `swe_tracing_spans.user_id` |
| 客户预览、洞察、电访客户数 | `swe_html_preview_click_events.user_id` |
| 主动提问任务级“查看数” | 直接沿用成功任务数，不查询任务阅读埋点 |

任务所属人、执行人和点击人不能互换。点击人即使不是任务 owner，只要在名单内，其客户级行为仍归属点击人的机构。主动提问任务级查看按成功数赋值，点击人与事件不参与 read_tasks 的计算。

名单先按 `(user_id, first_bbk_id, org_id)` 去重，同机构名称用 MIN 取稳定显示值。一个快照中同一用户存在多套机构 ID 时，报 `jkh_roster_ambiguous`，避免人数重复归属。冲突检测在机构筛选之前执行；本版遇到任何这类快照冲突整份报表失败，不偷偷选 MIN(机构号)。

空机构 ID 作为缺失机构分组保留；NULL 与空字符串是两种数据值，不在代码中伪造真实机构号。显示名为空时 UI 显示“未知机构”。机构键始终使用 ID，禁止按名称 GROUP BY。支行使用 `(first_bbk_id, org_id)` 联合键，防止跨分行支行号重名。

源表均需按单一 source 限制。执行表没有 source_id 时通过 `e.job_id=j.id` 取 `j.source_id`。由于子任务表只有 trace_id，当前方案依赖 Trace ID 全局唯一（作为跨表关联键；本报表不查询 Trace 表）；部署前核实实际约束和数据。如果生产允许跨 source 相同 trace_id，必须先补充子任务来源键和关联规则，不能假定仅在上游过滤 source 就能消除混淆。

### 2.2 名单快照

调用现有 `_resolve_jkh_sync_date(db, end_time)` 一次。end_time 指用户选定截止日的结束时刻，**不是半开区间 stop 的次日零点**。

顺序：截止日当天 → 当月月末 → 若全表最新日在截止日之后，选全表最早日 → 否则全表最新日。这里不是“最近历史快照”，不要改成最近日期。

返回 None 时直接 `items=[]`，不继续查询。已有 `_build_jkh_filter(..., sync_date=None)` 会取消名单过滤，因此新报表不能将 None 传下去。

新查询使用去重名单派生表 JOIN，是因为必须取得机构字段；它实现与现有 helper 相同的成员资格约束。旧 helper 原样保留，新查询额外明确支行归属。

### 2.3 三种任务类型

| 代码 | 类型 | 基础集合 | 计数单位 |
| --- | --- | --- | --- |
| push_plan | 推送(名单+方案) | 窗口内 e.actual_time，至少一个同 trace 子任务 | 一条 e.id；不同执行 ID 的重试各算一次 |
| ask_plan | 主动提问(名单+方案) | 窗口内 sp.start_time，非空 skill_id、有子任务、所有执行历史不存在同 trace | COUNT(DISTINCT sp.trace_id) |
| push_other | 推送(非名单方案) | 窗口内 e.actual_time，无同 trace 子任务，且两个执行状态均 success | 一条 e.id |

有子任务仅使用 EXISTS，不要求 task_type='plan' 或 status='SUC'，这是原需求的分类条件。subtask.custuid 为空仍能将任务分类为 push_plan/ask_plan，但不贡献客户数。

排除 Cron 的 NOT EXISTS 不能限制到查询日期内，否则窗口前执行的任务可能被误算为当期主动提问。三种类型互斥；无子任务的主动聊天、未成功的无子任务推送不在任何类别。

空 trace_id 的推送无法关联子任务，若成功可进入 push_other；空 trace_id 的点击和主动提问不进入统计。执行多次复用 trace 时，执行次数按 e.id 保留，客户/点击按客户去重，不能强行把执行数也改为 DISTINCT trace。

## 3. 十四字段矩阵

以下所有“去重”均为当前查询范围 + 当前机构分组 + 当前任务类型内的去重。

| 序号/字段 | push_plan | ask_plan | push_other |
| --- | --- | --- | --- |
| 1 task_type | push_plan | ask_plan | push_other |
| 2 skill_count | 基础执行关联未删除 job，统计开关=1的绑定技能，DISTINCT skill_id | 窗口内合格 Span 技能匹配相同 source 的统计技能，DISTINCT skill_id | 同左推送规则 |
| 3 permission_manager_count | 名单内在当前 source 有 tenant_init_source 记录的 DISTINCT user_id；同机构三行相同 | 同左 | 同左 |
| 4 active_manager_count | 当前未删除 active job，在窗口内有本类型执行，按 job owner 去重 | null，不计算 | 同左推送规则 |
| 5 suc_execute_job | 基础执行中 status=success AND async_status=success 的条数 | 合格 Span 的 COUNT(DISTINCT sp.trace_id)，不筛选状态 | 基础集合条数 |
| 6 read_tasks | 基础执行中 is_read=1 条数，保留原 SQL，不另外要求成功 | 直接等于该类型 suc_execute_job | 基础执行中 is_read=1 条数 |
| 7 read_rate | 6/5×100 | 6/5×100 | 6/5×100 |
| 8 recommended_customers | 基础执行关联子任务 DISTINCT 非空 custuid，job 至少绑定一个统计技能 | 合格 Span 关联的子任务 DISTINCT 非空 custuid，不额外加统计开关 | null |
| 9 read_customer_count | 当期点击人属于名单，preview_view + sub，DISTINCT customer_id；见点击规则 | 同左事件规则，通过 Span 关联统计技能 | null |
| 10 plan_read_rate | 9/8×100 | 9/8×100 | null |
| 11 insight_customer_count | 当期名单人员 button_click + insight，DISTINCT customer_id | 同左，主动关联规则 | null |
| 12 click_to_insight_rate | 11/8×100 | 11/8×100 | null |
| 13 phone_customer_count | 当期名单人员 button_click + phone，DISTINCT customer_id | 同左，主动关联规则 | null |
| 14 click_to_phone_rate | 13/8×100 | 13/8×100 | null |
| 15 insight_count | 满足洞察条件的点击事件总行数 | 同左，主动关联规则 | null |
| 16 phone_count | 满足电访条件的点击事件总行数 | 同左，主动关联规则 | null |

同一个客户在多个任务、多个经理、多个日期出现，在 overall 的同类型内只算一次；在不同机构内可以分别算一次。总计必须直接按 overall 查询，不能把支行数相加。单一 source 必填，所以 skill_id 的去重不会混合不同来源的同名 ID。

### 3.1 历史状态与删除过滤

本版保留原需求的指标级差异：

| 查询 | job 删除过滤 | success 过滤 | 统计技能开关 |
| --- | --- | --- | --- |
| 推送任务计数/已读 | 不加；仍需 job 行以识别 source | 成功数加；已读不加 | 不加 |
| 推送技能数 | 加 | 基础分类之外不加 | 加 |
| 活跃人数 | 未删除且当前 active | 基础分类之外不加 | 不加 |
| 推送客户方案客户数 | 不加 | 基础分类之外不加 | 加 |
| 推送客户级点击 | 加 | 不加 | 加 |
| 主动任务计数/已读 | 无 job | 不加状态过滤，已读等于成功数 | 分类仅非空 skill_id |
| 主动技能数 | 无 job | 不加 | 加 |
| 主动客户方案客户数 | 无 job | 不加 | 不加 |
| 主动客户级点击 | 无 job | 不加 | 加 |

因此不同列不一定对应同一批成功任务。删除 job、修改统计技能开关、后补子任务、后续已读都会影响历史报表；本接口不是不可变的历史快照。job 被物理删除且执行表无 source 时，当前实现无法归属该执行，应作为数据质量检查记录，而非用请求 source 强行补填。

## 4. 时间与比例

输入自然日按 Asia/Shanghai 解释：`start_date=2026-09-01,end_date=2026-09-13` 对应 `[09-01 00:00:00,09-14 00:00:00)`。

执行列、Span 列、点击列分别在自身表上使用 `>= start AND < stop`。Core 接收已经转换为数据库存储时区的无时区 datetime；参考默认三种表均为北京时间。Cron 有明确北京时间注释，Span/点击依赖部署 TZ 或前端上传值，生产核实后必要时分别计算三套边界。不要给 WHERE 的时间列包 DATE/CONVERT_TZ 来做转换。

字段 9/11/13 按“当期发生点击”统计，可以指向当期之前生成的任务，不对关联执行的 actual_time 再加窗口；否则会改变原需求事件口径。点击来源和任务来源必须一致，点击人需独立匹配名单。

主动任务查看数直接等于成功任务数；成功数大于零时 read_rate 为 100%，零分母仍为 null；推送 is_read 采用读取时当前状态，不按 read_at 限制，保留原需求。

比例返回 **百分点数值**，33.33 表示 33.33%，0 表示有分母但零次行为，分母 0 返回 null。使用 Decimal 四舍五入两位；前端不再乘 100。

以下情况比率可超过 100%，不截断、不加 max=100 模型限制：

- 推送名单方案中失败任务也已读，read_tasks 可能大于成功执行数。
- 当期点击了以前生成的客户方案，点击客户数可能大于当期推荐客户数。
- 不同机构的任务执行人和点击人不同。

这些是原始查询组合产生的期间比值，不能宣称为严格同批次转化率。若今后需要漏斗转化率，必须改为同一任务/客户/人员集合、明确点击观察期限并另立口径版本。

## 5. 关键 SQL：主动任务与查看

以下是合格 Span 的基础集合。正式 SQL 还会 JOIN 去重名单，并按请求机构维度分组。整个 ask 链路不查询 swe_tracing_traces，也不筛选 has_error。

```sql
SELECT sp.trace_id, sp.source_id, sp.user_id, sp.skill_id
FROM swe_tracing_spans sp
WHERE sp.source_id = %s
  AND sp.start_time >= %s AND sp.start_time < %s
  AND sp.trace_id <> ''
  AND sp.skill_id IS NOT NULL AND sp.skill_id <> ''
  AND EXISTS (
    SELECT 1 FROM swe_cron_subtasks s WHERE s.trace_id = sp.trace_id
  )
  AND NOT EXISTS (
    SELECT 1 FROM swe_cron_executions e WHERE e.trace_id = sp.trace_id
  );
```

在此基础集合、名单过滤和机构 GROUP BY 后，使用：

```sql
COUNT(DISTINCT sp.trace_id) AS suc_execute_job,
COUNT(DISTINCT sp.trace_id) AS read_tasks
```

同 trace 多个 Span 只贡献一次任务数。按每个分组内的 trace_id 去重，overall 重新查询去重，不加总支行计数。窗口外或其他来源、名单外用户的 Span 不参与任务与技能统计。

主动场景没有任务级阅读埋点。read_tasks 是按业务要求赋值，不是观测值；元数据 `read_evidence.ask=assumed_from_success` 明确这一点。客户级 read_customer_count/洞察/电访仍按点击事件统计，其主动归属通过 Span 判定；这些点击不影响 read_tasks。

## 6. 关键 SQL：点击指标合并

先由点击时间 + source 限定 c，再分别用 EXISTS 判断 push_plan 或 ask_plan。两类关联互斥；一次扫描同时聚合客户去重数与点击总次数。

```sql
COUNT(DISTINCT CASE
  WHEN c.event_type='preview_view' AND c.template_type='sub'
  THEN c.customer_id END) AS read_customer_count,
COUNT(DISTINCT CASE
  WHEN c.event_type='button_click' AND c.button_type='insight'
  THEN c.customer_id END) AS insight_customer_count,
COUNT(DISTINCT CASE
  WHEN c.event_type='button_click' AND c.button_type='phone'
  THEN c.customer_id END) AS phone_customer_count,
COUNT(CASE
  WHEN c.event_type='button_click' AND c.button_type='insight'
  THEN 1 END) AS insight_count,
COUNT(CASE
  WHEN c.event_type='button_click' AND c.button_type='phone'
  THEN 1 END) AS phone_count
```

同一客户重复点击时，客户数仍为 1，总次数按实际事件行增加。两个次数不参与现有覆盖率计算。

推送点击：`c.trace_id=e.trace_id AND c.cron_task_id=j.id AND e.job_id=j.id AND c.source_id=j.source_id`，有子任务、job 未删除且有统计技能。主动点击：`c.source_id=sp.source_id AND c.trace_id=sp.trace_id`，满足主动分类并存在相同 source 下的统计 Span 技能，**不依赖 cron_task_id**。

所有客户级点击过滤空 customer_id、空 trace_id。保持原事件口径，不额外要求 customer_id 必须出现在同 trace 的 subtasks.custuid；这类不一致作为数据质量核查，不通过静默 JOIN 隐藏。

## 7. 合并 SQL 的边界

core_reference.py 共构造 **10 条 SQL**：

| 名称 | 聚合内容 |
| --- | --- |
| roster_conflicts | 名单机构唯一性校验，至多返回一条冲突 |
| permissions | 机构维度列表 + 权限人数 |
| push_tasks | 两类推送的成功数、已读数 |
| ask_tasks | 主动成功数、已读数 |
| active | 两类推送活跃人数 |
| push_skills | 两类推送技能数 |
| ask_skills | 主动技能数 |
| push_customers | 推送方案客户数 |
| ask_customers | 主动方案客户数 |
| clicks | 两类名单方案的查看、洞察、电访客户数 |

此外固定一次快照查询，名称解析至多两次，即完整请求最多 13 次数据库查询。已传 ID 时无需名称解析。查询数与机构数无关，参考版串行执行。

2026-09-16 更新：正式服务把互不依赖的事实查询改为受限并发（默认 4，`TaskTypeReportService(concurrency=...)` 可覆盖，设为 1 即串行），查询条数、指标口径与分页路径不变；快照、冲突校验、权限查询和分页阶段仍串行。

2026-09-16 修正：结果以期间事实出现的维度为骨架，每个有效维度仍输出三类任务；没有期间事实的分行、支行和经理不输出，整体无事实也返回空列表。permissions 仅提供机构/人员元数据及原口径权限人数，不单独生成结果行。事实维度取各指标查询的并集，不能按指标是否全零判断；只有点击或 owner 活跃事实也保留。初始每类计数 0，汇总后仅按不适用规则置 null。结果按分行 ID、支行 ID、固定类型顺序排序。

2026-09-16 同日修正（单类型请求）：显式指定 `task_type` 时，骨架只取该类型涉及的指标事实，只执行该类型的查询并只输出该类型行——`push_plan` 取推送执行、owner 活跃、推送技能、推送方案客户与推送点击，`ask_plan` 取主动提问的三条事实与主动点击，`push_other` 只取推送执行、owner 活跃与推送技能；只有其它类型事实的经理不再出现在该类型报表的分页 total 与结果行中。不传 `task_type` 时仍是全类型事实并集并补齐三类任务，行为不变。该收窄只影响单类型请求的维度骨架，各指标的取值口径不变。

不把 COUNT DISTINCT 结果跨机构相加。应用层只接收机构级聚合行，不拉取全量执行、Span、客户或点击明细。
