# 分行、支行、客户经理与技能明细

2026-09-14 扩展。本文描述新维度，基础指标口径继续以 DESIGN.md 为准。正式代码和正式测试是当前可执行实现；core_reference.py / test_core_reference.py 保留为原基础模式样本，不应用它们覆盖正式实现。

2026-09-15 已增加访问范围、经理关键字/分页、机构选项与后端导出。当前交互契约见 [CONSOLE_API.md](CONSOLE_API.md)；本文的技能归属和指标规则不变。

同日新增洞察、电访点击总次数：技能明细内按当前维度对象+技能+任务类型关联的点击事件行计数；多技能事件会分别进入关联技能行，仍遵循“技能明细不可加总”。

## 1. 一个接口，六种组合

接口仍为 `GET /api/monitor/cron/task-type-report`，日期、来源头和机构筛选保持原契约。

| 展示组合 | group_by | skill_detail |
| --- | --- | --- |
| 分行 + 技能明细 | branch | true |
| 支行 + 技能明细 | org | true |
| 客户经理 + 技能明细 | manager | true |
| 分行汇总 | branch | false |
| 支行汇总 | org | false |
| 客户经理汇总 | manager | false |

`skill_detail` 默认 false；旧 `overall` 汇总继续支持。`overall + skill_detail=true` 返回 422，六种新增组合之外不增加整体技能明细。每种组合仍有三类 task_type。

请求例子：

```http
GET /api/monitor/cron/task-type-report?start_date=2026-09-01&end_date=2026-09-13&group_by=manager&skill_detail=true&first_bbk_id=001
X-Source-Id: RMASSIST
```

响应顶层新增 `skill_detail`。行新增下列字段；旧汇总中这些字段保持 null。

| 字段 | 来源/含义 |
| --- | --- |
| user_id | 当前客户经理 ID，分组键 |
| user_name | 同一名单快照 `jkh_user_inf.user_name` |
| sapid | 同一名单快照 `jkh_user_inf.user_id`，与 user_id 相同 |
| pst_lvl | 同一名单快照 `jkh_user_inf.pst_lvl`，SAP 岗位 |
| skill_id | 技能明细行的技能 ID；汇总为 null |
| cn_name | 相同 source+skill_id 的市场技能中文名；汇总为 null |

客户经理归属分行、网点使用已经存在的 `first_bbk_id / first_bbk_name / org_id / org_name` 字段，名称分别取 `first_bbk_nm / org_nm`。无需增加同义的 branch_name/network_name 字段。manager 模式必须同时返回分行与网点，不再像 branch 模式那样把 org 字段置空。

技能中文名为空时返回 null，消费方可显示 skill_id。同名不同 ID 是不同技能行，不按中文名合并。

## 2. 客户经理归属规则

客户经理从所选快照取得唯一机构归属；重复相同归属行仍去重，冲突归属继续报错。姓名、岗位的重复值用 MIN 取稳定显示结果，正常一对一数据不受影响。

| 指标类别 | 匹配 jkh.user_id 的字段 |
| --- | --- |
| 权限人数 | 初始化来源表 tenant_id，限制当前 source |
| 推送任务、推送技能、推送客户方案 | 执行表 `tenant_id`（实际列名，不是 tanent_id） |
| 主动任务、主动技能、主动客户方案 | Span 表 user_id |
| 客户查看、洞察、电访 | 点击事件 user_id |
| 活跃人数 | 继续沿用任务 owner：cron_jobs.tenant_id |

同一任务的 owner、执行人和点击人可能不同；进入不同客户经理行属于原指标归属规则，不用 owner 覆盖全部行为字段。

manager 模式 SQL 按 `(first_bbk_id, org_id, user_id, task_type)` 分组。由于名单规定一名经理只有一个机构归属，这等价于按经理分组，并同时提供其机构信息。有权限人数在经理行是 0 或 1；活跃人数在推送经理行是 0 或 1，主动仍为 null。

## 3. 技能明细如何计算

技能维度在数据库聚合阶段加入，不是把一行汇总指标复制到所有技能后返回。

技能目录限定当前 source、`include_in_statistics=1` 和非空 skill_id。先按 `(source_id, skill_id)` 去重，中文名使用 `MIN(NULLIF(cn_name,''))`。这样相同技能在市场表出现多个版本，也不会放大 COUNT/SUM。

| 数据来源 | 明细技能关联 |
| --- | --- |
| 推送执行、活跃、客户方案 | 当前 job.skill_ids 中绑定的每个统计技能（FIND_IN_SET） |
| 主动任务、客户方案 | 满足原主动条件且时间窗口内 Span 的 skill_id，直接关联市场目录 |
| 推送客户点击 | 点击关联 job 的绑定技能，继续验证原推送点击条件 |
| 主动客户点击 | 点击 source+trace 对应 Span 的 skill_id；继续采用 clicked_at 时间窗，Span 不追加生成时间限制 |

关键粒度：

- 每个技能行的推送成功数按该技能关联执行计数；一个执行不会因为市场目录重复行被重复计数。
- 每个技能行的主动成功数依然 `COUNT(DISTINCT sp.trace_id)`，`read_tasks` 等于成功数，不依赖 Trace 表/has_error/阅读埋点。
- 主动技能关联直接使用当前合格 Span，不再次按 trace 回连所有 Span，避免窗口外或其他经理的技能被误纳入。
- 客户数和点击客户数在“机构或经理 + 技能 + 类型”内部 DISTINCT 客户 ID。
- 权限人数没有技能权限映射来源，因此保持该机构或经理的原权限人数，重复展示于各技能行，不能相加。
- `skill_count` 沿用原统计过滤，在单技能类型行是 0 或 1。不能无条件写死 1：比如当前 job 已删除时，原规则仍保留执行/方案数，但技能数与活跃人数为 0。
- 其他列的删除状态、时间口径、统计开关差异、比例、null 规则保持 DESIGN.md 不变。

### 3.1 多技能归属不是分摊

一个任务绑定技能 A、B 时，任务次数和 trace 下客户方案会分别归入 A、B。现有执行/子任务/点击关系不能进一步确定每个客户方案由哪个技能独立生成，因此本版展示的是**关联技能视角**，不按技能数平均分摊。

两个技能的客户集合可以重叠，任务也可以重叠。技能明细的各列不能直接相加作为汇总；请通过 `skill_detail=false` 查询原汇总。明细响应会附加 `skill_rows_not_additive` 提示。

例如：一条成功执行绑定 A、B，产生客户 C1。分行汇总成功数=1、客户数=1；A 行成功数=1、客户数=1，B 行也是 1、1。两行相加=2 不是汇总。

### 3.2 有哪些行

2026-09-16 修正：汇总以期间事实实际出现的机构/经理为骨架，每个有效维度对象补齐三类任务。名单仅限定范围、提供归属/元数据及原口径权限人数，无事实的维度不输出；有事实但指标为零的维度仍保留。

技能明细以各指标实际出现的“维度对象 + 技能”组合为骨架，每个组合补齐三类任务。纯技能目录中未出现活动的技能、没有技能活动的经理不会展开成零矩阵。筛选结果没有关联统计技能时返回 items=[]，提示 `no_matching_skills`。

未绑定统计技能的任务仍按旧口径进入汇总任务计数，但无法归入统计技能明细；不生成虚构的“未知技能”行。因此除了重复归属之外，技能明细与汇总还可能有统计范围差异。

展示排序：分行 ID、支行 ID、客户经理 ID、技能 ID、固定任务类型顺序。非适用的维度字段为 null。

## 4. 架构与性能

本次复用原聚合链路，只在 task_type_report 独立模块内扩展：

1. 模型增加 manager、skill_detail 与行元数据。
2. 路由通过 report_dimensions 解析分组和技能开关，旧筛选参数不变。
3. SQL Scope 加 skill_detail；manager 时才从名单选择 user_name、pst_lvl，旧分支行查询不新增这两个列的依赖。
4. 技能明细时加入去重技能目录、技能分组和对应关联条件；不开启时保留原查询粒度，不查询 cn_name。
5. permissions 查询一次返回机构/经理信息与权限人数；其他 SQL 只返回聚合键和指标，不重复获取经理属性。
6. assemble 合并聚合行，在实际关联的维度对象+技能上补齐三类任务，不在 Python 逐人/逐技能查库。

仍是固定 10 条核心 SQL：加一次名单快照和至多两次名称解析，最多 13 次查询。机构、经理和技能数量增加不会带来 N+1 查询。技能目录先限定 source 并去重，点击通过 EXISTS 关联技能，避免直接 JOIN 多次执行或 Span 放大事件数据。

代价仍需关注：技能展开会增加数据库 GROUP BY 的行数，CSV 绑定的 FIND_IN_SET 不是普通索引查找；相同派生目录在多条 SQL 中出现不表示只扫描一次。真实 TDSQL 必须继续检查各 SQL 的 EXPLAIN、分片路由与耗时，不能仅从固定查询次数断言性能。

经理全量技能明细可能有很多返回行，现已支持可选的维度键分页，分行/支行及未传分页参数保持全量；实现细节见 CONSOLE_API.md。没有增加全量名单×全目录的笛卡尔积、进程缓存、日聚合或新表/索引；导出复用全量查询并明确限制最多50000行。

原候选索引继续适用。技能目录按 `(source_id, include_in_statistics, skill_id)`、Span 按 `(source_id,start_time)` 或 `(source_id,trace_id,skill_id)`、点击按 `(source_id,clicked_at)` 访问。经理信息从已筛选名单快照读取，不给每个姓名/岗位做单独查询。

## 5. 验收入口

新增 `tests/test_task_type_report_dimensions.py`，通过 SQLite 实际运行 SQL，同时在真实 app 的 ASGI 路由上覆盖六种组合。覆盖经理元数据和三种行为主体、同名不同 ID、重复目录、来源隔离、非统计技能、未使用技能、技能重叠不可加总、权限重复展示、删除规则及固定查询次数。

```powershell
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_dimensions.py tests/test_task_type_report_queries.py tests/test_task_type_report_api.py tests/test_jkh_branch_queries.py tests/test_cron_skill_binding_queries.py tests/test_branch_export.py tests/test_branch_export_api.py -q -p no:cacheprovider
```

未修改旧 QueryService、旧报表方法、连接实现或数据库结构。GitNexus 已尝试 upstream impact，但本地索引存储版本不兼容，风险返回 UNKNOWN；不能据此宣称调用图风险 LOW。真实 TDSQL 执行计划和压测仍需部署环境验证。
