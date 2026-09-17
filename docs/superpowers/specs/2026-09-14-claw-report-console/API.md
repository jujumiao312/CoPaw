# Claw 技能运行看板：前后端扩展契约

2026-09-14，Console 与 monitor 协作约定。保留 jkh_task_report_v1 指标、比例和名单快照口径，新增权限、筛选、分页与后端 XLSX 导出。前端负责人仅修改 console/ 及本文件；monitor 工作区负责后端代码、测试及其文档。

## 1. 所有接口的范围与错误

路径前缀 `/api/monitor/cron`。沿用认证、X-Source-Id；所有下述接口必须携带非空 `X-Bbk-Id`。
- 100：总行可查询全部分行，也可传 first_bbk_id 收窄。
- 非 100：后台强制限定 first_bbk_id 为头部 BBK；参数未传则自动补齐，参数冲突返回 403。下拉机构、经理查询、技能明细、导出均应用同一范围。
- 头缺失/空白：422，不能解释为总行。服务端应基于现有认证/网关可信上下文验证身份；浏览器头不应被当作绕过既有鉴权的授权凭证。
- org_id 必须属于有效分行；user_id 必须属于允许范围中的名单人员，不得通过这些参数扩大范围。跨范围直接 403；范围内无匹配数据可返回空。
- 错误沿用 `{"detail":{"code":"...","message":"中文说明"}}`，前端展示 message。

## 2. GET /task-type-report

原参数不变，增加：
| 参数 | 类型 | 规则 |
| --- | --- | --- |
| task_type | push_plan / ask_plan / push_other，可选 | 前端必传当前任务类型；无参数保留旧三类行为 |
| user_id | string，可选 | 精确查询经理；技能明细时传所点击行经理 ID |
| keyword | string，可选，最大 100 字符 | manager 维度按 jkh_user_inf 的 user_name/user_id（SAP号）/pst_lvl 模糊匹配；空白按未传。参数化 SQL，转义 LIKE 通配符 |
| page | integer >=1，可选 | manager 前端总是传，初始 1 |
| page_size | integer 1..100，可选 | manager 前端固定 20 |

- branch/org：不传分页，一次返回全部匹配行，前端初始挂载 20 行、滚到底部再增加 20 行。
- manager：传 page/page_size 时必须传 task_type，返回该类型 20 行。汇总按唯一经理分组键分页；skill_detail=true 时按唯一经理+技能键分页。在维度键上分页后计算完整指标，不能对某个指标子查询随意 LIMIT。未传分页时保留旧行为。
- 顺序稳定：first_bbk_id、org_id、user_id、skill_id（可空）顺序，不能出现相邻页重复/遗漏。
- 返回保留原字段，增加 `page: int|null, page_size: int|null, total: int, has_more: bool`。total 是当前筛选与 task_type 下总行数（不是人数之外另加三类行）。非分页 total=items.length、has_more=false。
- 指标新增 `insight_count`（点击客户洞察总次数）和 `phone_count`（点击去电访总次数）。它们与对应客户数共用范围、归属、分页和技能维度，但按事件行计数、不按 customer_id 去重；`push_other` 返回 null。表格和 XLSX 中分别放在对应覆盖率字段之后。
- 全月限制由前端执行；后端保留原日期校验以兼容旧调用。
- 分页使用同样 end_date 解析名单快照；实时数据变化仍遵循原 consistency=live，不能保证跨请求事务快照。

示例：`GET /task-type-report?start_date=2026-09-01&end_date=2026-09-14&group_by=manager&task_type=push_plan&first_bbk_id=110&org_id=11001&keyword=演示&page=1&page_size=20`

## 3. GET /task-type-report/options

从 `jkh_user_inf` 与报表相同的名单快照返回机构映射（去重、稳定按 ID 排序）。不从静态常量或报表活动行推导下拉项。

参数：`end_date` 必填 YYYY-MM-DD；`kind` 必填 branches 或 orgs；`first_bbk_id` 可选（orgs 时总行调用必须指定分行，非总行可由头补齐）。

响应：
```json
{"sync_date":"2026-09-14","items":[{"value":"11001","label":"营业部"}]}
```
branches 的 value=first_bbk_id，label=first_bbk_nm（为空时显示 ID）；orgs 的 value=org_id，label=org_nm（为空时显示 ID）。缺失/空白 ID 不作为可选项。非总行 branches 最多返回自身一项。

UI：分行 Select + 支行 Select 联动构成级联筛选；切换分行清空支行。未选分行时支行禁用。非总行分行 Select 只有本分行，固定禁用。manager 也可使用该级联筛选，并有“姓名 / SAP号 / 岗位”关键字搜索（由本节名单与第2节 manager 查询实现，无需额外经理候选接口）。

## 4. GET /task-type-report/export

请求参数与第2节一致但不传 page/page_size，导出当前筛选条件的全量数据，不只已滚动加载部分。必须传 task_type。skill_detail=false 为统计报表；true 为技能明细，包含当前行 first_bbk_id/org_id/user_id 范围。keyword 同样应用。

响应：200，Content-Type=`application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`，Content-Disposition 附件文件名 UTF-8。跨域部署暴露 Content-Disposition 头。

表格列与当前导出的报表一致：维度列按 group_by（分行/支行/客户经理）选取，技能明细才带技能名称，任务类型天然不产出的指标不导出；2026-09-17 起不再生成“筛选与口径”工作表。null 留空、0 保留、比例明确单位。字符串按 Excel 文本写入，不能解释为公式。复用现有后端 XLSX 工具，不接受前端生成 CSV 冒充 Excel。

导出复用报表的统计和权限代码；不要把 manager 默认20行分页用于导出。若需要全量规模上限，返回明确 422/413 错误，禁止静默截断。成功文件使用现有流式/字节响应模式。业务报错保持 JSON 错误结构。

## 5. 验收

- 100/non-100/缺失头，参数冲突，非法跨分行 org/user，以及 options/export 同样权限约束。
- 三个维度；单类型筛选；经理姓名、SAP号、岗位搜索；第一页20行/下一页/尾页/空页，总量与不分页对账。
- 技能分页不重复、不漏指标；相同名字不同ID不合并。
- options 与报表一致快照；分行到支行映射，零活动人员/机构仍可查询。
- 两种 XLSX 导出内容与筛选全量查询一致，校验 MIME、文件可读取、文本防公式注入和空值。
- 前端模拟模式仍可预览滚动及筛选，但模拟导出按钮禁用并说明需要后端，不写入真实数据库。

## 6. 实现确认

- 后端已实现三条接口；manager分页须page/page_size成对、task_type必填；Excel上限50000行，超过返回413 report_export_too_large。
- 前端分行/支行本地20行递增、经理远程20行分页，列表使用随窗口变化的独立滚动区域；保留键盘可触发的加载入口。
- 页面样式参考 cron-job-overview 的筛选区、统计表头、刷新/导出及下方明细，沿用 Console 白色管理界面规范。
- 当前环境未提供 Lovable 调用或安装入口，布局直接在现有 React/Ant Design 工程内完成。
## 7. 交付校验（2026-09-15）

- 前端：13项相关Vitest测试通过，覆盖身份范围、分页与重试、过期请求取消、级联筛选、经理搜索、明细范围与导出参数。生产构建、变更文件ESLint/Prettier、git diff --check通过。
- 后端：增加两项点击次数指标后的完整回归为198项通过；后端完整契约及限制见 monitor/docs/superpowers/specs/2026-09-13-jkh-task-report/CONSOLE_API.md。
- 浏览器模拟验证：分行20→24行、经理20→40行、SAP号搜索1行及对应4个技能明细；导出按钮在模拟模式中禁用并说明原因。
- 未完成环境验证：未启动连接真实TDSQL的常驻monitor服务，未执行生产查询计划或压测；真实Excel下载需该服务可用。没有修改数据库或提交Git。
