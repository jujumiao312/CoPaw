# Console 对接：分行范围、经理分页、名单选项与 XLSX

更新：2026-09-15。本文覆盖新增交互接口；指标保持 DESIGN.md，技能维度保持 DIMENSIONS.md。前后端共同契约位于 CoPaw 仓库 `docs/superpowers/specs/2026-09-14-claw-report-console/API.md`，本次仅修改 monitor。

响应与 XLSX 新增 `insight_count`（点击客户洞察总次数）和 `phone_count`（点击去电访总次数）。两列分别紧跟 `click_to_insight_rate`、`click_to_phone_rate`，条件与对应去重客户数完全一致，按点击事件行计数；push_other 为 null。

## 1. 三条接口共用请求头

路径前缀 `/api/monitor/cron`，下列三条接口都必须提供非空 `X-Source-Id` 与 `X-Bbk-Id`：

- `GET /task-type-report`
- `GET /task-type-report/options`
- `GET /task-type-report/export`

`X-Bbk-Id=100` 允许查询全部分行或传 first_bbk_id 收窄。其他值强制 first_bbk_id 等于该请求头：省略自动补齐，不一致返回 403。选项、查询与导出调用同一 enforce_branch。org_id/user_id/机构名称如果在名单中存在但属于有效分行/网点范围之外，返回 403；完全不存在的 ID 可返回空结果。

**身份边界未新增**：服务基于现有网关传入的可信来源/分行上下文限制数据。当前 monitor 没有发现独立身份与分行授权校验依赖，因此本实现不是新增身份认证系统。部署方必须保持现有认证并确保 X-Bbk-Id 由可信网关固定或验证，不能允许外部调用者通过伪造 100 绕过身份授权。没有修改全局认证或其他接口。

参数和缺失请求头统一返回 422 `detail.code=report_validation_error`，消息为中文。跨范围返回 403 `report_scope_forbidden`；数据库/超时/其他错误保持结构化 detail.code/message。仅本报表 router 使用 ReportRoute 校验包装，旧路由的错误格式不变。

## 2. 查询新增参数

| 参数 | 规则 |
| --- | --- |
| task_type | 可选 push_plan/ask_plan/push_other；省略保留三类型行为 |
| user_id | 可选精确经理 ID，先校验机构范围，再用于名单过滤 |
| keyword | 可选，最大100字符，仅 manager 模式；姓名、user_id（SAP号）、pst_lvl 模糊搜索；空白等同未传 |
| page | 可选整数≥1，与 page_size 成对；仅 manager 且必须 task_type |
| page_size | 可选整数1..100；前端通常20 |

关键词使用参数绑定，LIKE 中的 `%`、`_`、`!` 转义，采用 `ESCAPE '!'`，不会把用户的通配符当作额外搜索语法。ID和机构筛选同样绑定。

新增响应 `page/page_size/total/has_more`。未传分页时 page/page_size 为 null、total 等于最终 items 长度、has_more=false；只传 task_type 时只返回该类型。分行、支行仍全量，传分页参数会422。

## 3. 分页实现与性能边界

不在某条指标 SQL 上直接加 LIMIT。

1. 按名单快照、BBK范围、机构、经理ID和关键词筛选。
2. 普通和技能 manager 模式的维度键来自事实路径的 UNION；名单限制每条路径的范围。普通模式去重为机构+经理，技能模式去重为机构+经理+技能，无事实经理不占分页 total。2026-09-16 起分页必须带 `task_type`，键只取该类型的路径：`push_plan` 用推送执行/owner 活跃/推送点击，`ask_plan` 用 Span/主动点击，`push_other` 只用推送执行与 owner 活跃；只有其它类型事实的经理不再计入 total。
3. 对维度键 COUNT 得到 total，同时按稳定 ORDER BY 分行/支行/经理/技能并 LIMIT/OFFSET 取本页；两者互不依赖，2026-09-16 起并发取回。
4. 将页内经理键下推到全部指标的名单条件；技能明细还将每个经理+技能配对下推到技能 JOIN，避免一名经理的其他技能泄漏到本页。
5. 汇总完整指标后筛选 task_type，按原语义补零。技能组合原本就补三种类型；因此某一类型可有零指标行，分页与相同筛选的未分页结果完全一致。

相比无分页，分页增加固定的维度键计数、取页及校验查询，不随经理人数循环查库。查询计划、UNION去重、分片路由和深OFFSET性能需在真实 TDSQL 上验证。2026-09-16 起分页键先在事实里对（人员，技能）去重、再做名单过滤与机构映射，逐行机构子查询只跑在去重后的人员上；技能键发现仍需扫描符合条件的事实范围，并不等于廉价的主键分页。普通指标聚合仅针对本页键，未引入缓存或新表。

查询次数不再统一宣称最多13次：原核心10条之外，按输入增加快照、机构名称解析与范围校验；分页再增加维度查询。数量仍不依赖经理数量。跨请求沿用 consistency=live，不承诺活动数据变化时跨页事务快照。

## 4. 名单选项

`/options` 参数为 end_date、kind=branches|orgs、可选 first_bbk_id。采用同一 `_resolve_jkh_sync_date`，从名单表去重取 ID/名称，未活动机构仍可出现在选项中。

- branches：value=first_bbk_id，label=first_bbk_nm；非总行最多自身一项。
- orgs：value=org_id，label=org_nm；必须确定分行，非总行可由头自动补齐，总行未指定则422。
- 空/空白 ID 排除，空名称回退 ID；按 ID 排序。
- 响应：`{"sync_date":"2026-09-13","items":[{"value":"001","label":"甲分行"}]}`。

## 5. 全量导出

`/export` 接收相同统计筛选，必须 task_type，禁止传 page/page_size。调用同一个报表服务 get_report 与范围校验后生成全量 XLSX。

新增 `task_type_report_export.py` 沿用项目已有 openpyxl，不改旧导出实现。使用 write-only 工作簿，包含“统计报表”或“技能明细”和“筛选与口径”两个工作表：

- 组织、经理、SAP信息、技能与全部指标；null为空，0为数值0。
- 百分点转成Excel百分比格式显示，保留超过100%的合法期间比值。
- 筛选、来源、实际范围、快照、行数、主动已读赋值与技能不可加总提示。
- 所有字符串显式写为文本，`=1+1` 等不会被当作公式。
- MIME 为真实 XLSX，附件 UTF-8 文件名，并在响应中暴露 Content-Disposition。

超过 **50000行** 返回 413 `report_export_too_large`，不静默截断。该限制在统计完成后、生成工作簿前检查；它限制文件生成规模，不是免除全量统计查询成本。导出使用工作线程，报表查询仍受30秒应用等待超时约束；数据库端查询取消能力需目标驱动/代理验证。

## 6. 验证与启动限制

新增点击总次数后的最终回归 **198 项通过**。既有 TestClient 两条依赖弃用警告未影响结果，没有为消除警告调整依赖。

测试覆盖 report/options/export 缺失头、范围冲突、跨分行 org/user/名称；姓名/SAP/岗位与字面通配符；经理和技能分页首/中/末/空页与全量逐行对账；一个经理多个技能跨页；真实XLSX完整行、百分比、空值、公式文本及导出上限。

```powershell
.\venv\Scripts\python.exe -m pytest tests/test_task_type_report_console.py tests/test_task_type_report_queries.py tests/test_task_type_report_api.py tests/test_task_type_report_dimensions.py tests/test_jkh_branch_queries.py tests/test_cron_skill_binding_queries.py tests/test_branch_export.py tests/test_branch_export_api.py -q -p no:cacheprovider
```

验证使用真实 FastAPI app 的 ASGI 路由和 SQLite 对 SQL 的占位符/FIND_IN_SET 适配。没有触发真实数据库启动生命周期，没有启动常驻服务、连接生产数据库或执行迁移。正式启动仍需现有 monitor 数据库配置、各底表字段及目标 TDSQL 兼容性；没有新增依赖或后台进程。

GitNexus upstream impact 已尝试，但现有索引存储版本不兼容，返回 UNKNOWN。实现和回归范围限于 monitor 的报表模块，未修改 console 或原 QueryService 的统计方法。
