# 金葵花分支行 × 任务类型报表：开发交接包

设计日期：2026-09-13；实现更新：2026-09-15。对象：维护本接口的模型和开发人员。

最新 Console 对接已增加强制 X-Bbk-Id、经理搜索/分页、机构选项与全量 XLSX；当前请求契约和限制先阅读 [CONSOLE_API.md](CONSOLE_API.md)。旧调用需要补齐分行范围头；未传分页仍保留全量行为。

新增洞察/电访点击总次数后的最终回归：**198 项通过**；真实 TDSQL 与常驻服务启动未执行，具体限制见 CONSOLE_API.md。

## 1. 交付目标与当前状态

在 **monitor 工程**提供查询接口，返回整体、分行、支行或客户经理维度下的三类任务统计，共 14 个指标；分行、支行、客户经理均支持技能明细展开。复用 FastAPI、aiomysql 和现有金葵花名单快照规则，采用固定数量的分组聚合 SQL。

本交付已完成：需求与真实代码对照、统计口径补齐、模块和接口设计、正式查询接口、参数化 SQL、名称解析、请求校验、超时/异常处理和对账测试。

正式路由已经注册到现有 app。生产代码位于第 4 节列出的模块，文档目录的参考代码保留作为最初设计样本，应用不会从文档目录导入代码。本次未执行数据库变更、真实 TDSQL 查询和压测。

实现采用独立模块，原工程生产代码仅在 `routers/__init__.py` 增加一条 import 和一条 include_router；原 QueryService、旧接口和数据库连接实现均未修改。最新六种维度组合扩展后，报表测试 85 项与既有回归 66 项组合运行，**151 项通过**。当前维度参数、经理字段和技能归属见 [DIMENSIONS.md](DIMENSIONS.md)。

用户授权根据现有代码自行补齐原需求中未写出的 SQL，并于 2026-09-14 授权按文档直接实现。当前接口使用 `jkh_task_report_v1`。数据库实际字段、分片与时间存储仍需在部署环境按实施步骤核实。

## 2. 按以下顺序阅读

1. 本文：了解目标、架构和执行顺序。
2. [DESIGN.md](DESIGN.md)：唯一的统计口径说明，包含 14 字段、数据关系和关键 SQL。
3. [IMPLEMENTATION.md](IMPLEMENTATION.md)：接口契约、名称解析、服务接入、TDSQL 校验和验收清单。
   涉及客户经理维度或技能明细时同时阅读 [DIMENSIONS.md](DIMENSIONS.md)，其中明确六种组合、关联技能计数、空行规则和性能边界。
4. [正式 SQL 模块](../../../../src/monitor/app/services/cron/task_type_report_sql.py)与[正式服务](../../../../src/monitor/app/services/cron/task_type_report.py)：当前实现；[core_reference.py](core_reference.py)为设计阶段参考。
5. [正式查询测试](../../../../tests/test_task_type_report_queries.py)与[正式接口测试](../../../../tests/test_task_type_report_api.py)：维护时执行；[test_core_reference.py](test_core_reference.py)为设计阶段对账样本。
6. [原始需求.txt](原始需求.txt)：原文存档，仅用于追溯；原文的缺漏、拼写与歧义按 DESIGN.md 的决策表处理。

## 3. 最终架构

```text
GET /api/monitor/cron/task-type-report
  → 新路由：参数校验、来源读取、错误映射
  → TaskTypeReportService.get_report
      → QueryService._resolve_jkh_sync_date：选择一次快照
      → 名称解析为名单中的机构 ID
      → 名单去重及机构冲突检查
      → 固定 SQL 查询各机构、各任务类型的聚合数据
      → assemble：补齐三种类型、处理 null、计算比例
  → TaskTypeReportResponse

数据：现有 monitor DatabaseConnection → 同一业务数据库中的现有表
```

服务向路由仅暴露一个报表入口。SQL 内部保留任务、技能、客户、点击四种粒度，隐藏在该入口后面。无需增加 ORM、通用报表引擎、Redis 缓存、后台定时汇总或新的微服务。

独立查询是为了保持去重粒度和可控执行计划。把所有明细表合成一个大 JOIN 会产生 `执行 × Span × 子任务 × 点击 × 技能` 的行数乘积。

## 4. 正式开发目录

以下路径相对于 `monitor/`。只有下表内容属于本需求的正式业务改动范围。

```text
src/monitor/app/
├── models/task_type_report.py           # 新增：请求、行与响应模型
├── routers/task_type_report.py          # 新增：一个 GET 接口
├── routers/__init__.py                  # 增加路由挂载
└── services/cron/
    ├── task_type_report.py              # 新增：服务、名称解析、查询编排与阶段日志
    ├── task_type_report_rows.py         # 后续拆分：纯行组装与派生比例
    ├── task_type_report_sql.py          # 新增：Scope、绑定及查询构造
    └── task_type_report_export.py       # 新增：全量 XLSX 生成
tests/
├── test_task_type_report_queries.py     # 核心 SQL 对账
├── test_task_type_report_api.py         # 请求/响应/快照/错误/路由集成
├── test_task_type_report_dimensions.py  # 六种维度组合与关联技能对账
└── test_task_type_report_console.py     # 范围、选项、分页、全量导出
```

参考文件到正式文件的映射：

| 参考内容 | 正式落点 |
| --- | --- |
| `Scope / bind / build_queries` | `task_type_report_sql.py` |
| `TASK_TYPES / LABELS / COUNTS / RATIOS` | `task_type_report_rows.py`，与行组装放在一起，避免循环导入 |
| `date_bounds / query_core` | `task_type_report.py`；query_core 自 2026-09-16 起按受限并发执行事实查询 |
| `percentage / assemble` | `task_type_report_rows.py`，并由服务模块再导出以兼容既有导入路径 |
| 本包测试夹具与断言 | `test_task_type_report_queries.py`，修改导入路径 |
| IMPLEMENTATION.md 的契约 | Pydantic 模型和新路由 |

不复制原有 6000 行 QueryService，不修改旧报表行为。新服务调用其现有快照方法即可；这一次不为两个静态 helper 做大规模抽取。

## 5. 开发及部署验证清单

接口代码与本地测试已完成；以下保留开发流程和完成标准，真实数据库核查与性能验证仍待部署环境执行。

### 第一步：核实数据库和接入边界

阅读下方定位表，按 IMPLEMENTATION.md 的数据库核查清单取得表结构、状态取值、时区和分片信息。确认 Span 的 source_id/user_id/start_time/skill_id/trace_id 字段存在；ask 不依赖 Trace 表或状态字段。

完成标准：为核查项记录实际结果；遇到与参考实现不一致的字段，修改映射及对应测试，不使用运行时“试列名”或自动降级为全表查询。

### 第二步：先运行参考对账

Windows，在 `monitor/` 中执行：

```powershell
.\venv\Scripts\python.exe -m pytest docs/superpowers/specs/2026-09-13-jkh-task-report/test_core_reference.py -q -p no:cacheprovider
```

Linux 使用 `venv/bin/python -m pytest ...`。

完成标准：参考对账全部通过，理解 DESIGN.md 中为什么存在 `read_rate=200.0` 的样本，不能为了让比率“好看”而改测试。

### 第三步：落地查询模块和服务

按第 4 节映射迁移代码；新增日期/名称解析、快照选择、空名单早退和稳定错误映射。名单快照只选择一次。机构数量增加时，SQL 数量保持常数。

完成标准：所有查询使用参数绑定；overall/branch/org 结果与参考样本一致；所有指标从各自正确的用户字段匹配同一快照。

### 第四步：接入接口

按 IMPLEMENTATION.md 定义模型、新路由和注册。新增接口返回三类任务行，空值保留为 JSON null。

完成标准：真实 FastAPI app 上的请求测试通过，验证 `/api` 前缀而不只单独测试路由函数。

### 第五步：TDSQL 校验与优化

先执行相同样本的数据对账，再逐条检查 EXPLAIN 和真实耗时。只对已证明慢的查询做优化。

完成标准：统计结果不变，留下内核/代理版本、分片规则、计划、数据量、扫描量、耗时与并发记录。通过 SQLite 不等于完成这一步。

### 第六步：回归和交付

执行新增测试，以及 `tests/test_jkh_branch_queries.py`、`tests/test_cron_skill_binding_queries.py`。更新本包及 Playbook 入口，说明哪些指标来自快照状态、哪些来自时间窗口。

完成标准：IMPLEMENTATION.md 的验收项逐项有证据；旧报表结果和接口不变；明确真实数据库验证的完成情况。

## 6. 已核实的代码定位

路径均相对于 CoPaw 仓库根目录；接手模型用方法名定位最新代码。

| 事实 | 代码证据 |
| --- | --- |
| 报表属于 monitor 而非 swe 主 HTTP 服务 | `monitor/src/monitor/app/routers/cron.py`：prefix `/monitor/cron` |
| `/api` 注册前缀 | `monitor/src/monitor/app/_app.py`：`app.include_router` |
| 名单日期与成员过滤 | `monitor/src/monitor/app/services/cron/query_service.py`：`_resolve_jkh_sync_date / _build_jkh_filter` |
| 技能统计开关按 source 匹配，技能列表为 CSV | 同文件：`_skill_binding_join / _statistics_skill_exists` |
| 执行成功是两个 success | 同文件执行统计；`monitor/src/monitor/app/database/schema.py` |
| ask 使用 Span 主表、trace_id 去重成功数，read_tasks 等于成功数 | 用户 2026-09-14 最新指令，正式 task_type_report_sql.py |
| Span 当前写入采用 datetime.now | `src/swe/tracing/manager.py`，部署 TZ 需要核实 |
| 点击有 source/user/trace/time/main/sub 字段 | `scripts/sql/html_preview_click_events.sql` |
| 点击由前端时间或服务当前时间产生 | `src/swe/app/html_preview_clicks/router.py` |
| 初始化人员支持同用户不同 source | `scripts/sql/tenant_init_source_table.sql` |
| 名单的机构名记录为 first_bbk_nm / org_nm | `monitor/analysis/playbook/jkh-branch-statistics.md`，还需核实生产 DDL |
| DatabaseConnection 每次 fetch 独立取池连接，autocommit=True | `monitor/src/monitor/app/database/connection.py` |

## 7. 修改边界与验证状态

当前已新增正式业务模块和测试，旧生产文件仅有两行路由注册改动。没有修改既有函数、表结构或数据，也没有提交 Git。

本环境未提供可调用的 GitNexus 工具，相关 skill 路径也不存在；本轮未声称完成调用图分析。后续正式开发若修改已有函数，按仓库 AGENTS.md 先做 upstream impact，报告直接调用方、受影响流程和风险；HIGH/CRITICAL 需先告知用户。提交前执行 detect_changes。纯新增路由的注册改动也要核对注册链路和重复路径。

本包 SQL 采用 MySQL 常见的派生表/EXISTS/条件聚合结构；实际 TDSQL 兼容性与性能尚未验证。验证命令和结果以 IMPLEMENTATION.md 末尾记录为准。
