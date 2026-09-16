# Monitor 排查与改造记录

- [技能运行看板 Console 接口](../../docs/superpowers/specs/2026-09-13-jkh-task-report/CONSOLE_API.md)：排查分行范围、经理筛选与分页、名单下拉和全量 XLSX 导出时阅读；三条接口均要求 X-Bbk-Id，同一身份网关边界与指标口径。

- [分行维度 Excel 导出](branch-dimension-export.md)：接口契约、展示与排序口径、权限接入状态及测试入口。
- [金葵花客户经理统计改造开发文档](jkh-branch-statistics.md)：开发分行排行、客户经理汇总、名单日期或分行过滤，处理汇总与下钻对账、查询性能问题时阅读；包含业务规则、方法清单、影响边界及测试入口。
- [build_queries 梳理](task-type-report-build-queries.md)：维护任务类型报表的固定 SQL 构造、排查慢查询或超时时阅读；含模块分工、Scope 校验、占位符绑定、10 条查询分工、事实查询并发开关、阶段耗时日志字段、五项不变量、易误读的既定口径与测试入口。
- [金葵花任务类型报表](../../docs/superpowers/specs/2026-09-13-jkh-task-report/README.md)：维护整体/分行/支行/客户经理 × 三类任务及技能明细时阅读；含 14 项指标、经理属性、技能归属规则、正式模块定位与对账测试。接口已独立接入，原工程旧方法未改；真实 TDSQL 计划与性能待部署环境核验。
