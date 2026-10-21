# Claw 技能运行看板（ClawSkillDataOverview）

> 看板按机构、客户经理与任务类型查看技能运行表现，支持点击「技能总数」下钻到技能明细，并导出 Excel。

## 一、页面职责与代码位置

| 内容 | 位置 |
| ---- | ---- |
| 路由挂载 | `src/pages/Analytics/index.tsx`，path `claw-skill-data-overview` → `ClawSkillDataOverview` |
| 侧边栏菜单 | `src/layouts/Sidebar.tsx`，key `analytics-claw-skill-data-overview`，label「Claw技能运行看板」 |
| 路由常量 | `src/layouts/constants.ts`，`analytics-claw-skill-data-overview` → `/analytics/claw-skill-data-overview` |
| 页面主体 | `src/pages/Analytics/ClawSkillDataOverview/index.tsx`（单文件承载，约 600 行） |
| 报表拉取 Hook | `src/pages/Analytics/ClawSkillDataOverview/useReport.ts` |
| 机构/技能筛选 | `src/pages/Analytics/ClawSkillDataOverview/OrganizationFilters.tsx` |
| Excel 导出 | `src/pages/Analytics/ClawSkillDataOverview/ReportExport.tsx` + `reportExportFilename.ts` |
| 样式 | `src/pages/Analytics/ClawSkillDataOverview/index.module.less` |
| 接口定义 | `src/api/modules/taskTypeReport.ts` |
| 模拟数据 | `src/api/modules/taskTypeReportDemo.ts` |
| 测试 | `src/pages/Analytics/ClawSkillDataOverview/index.test.tsx` |

### index.tsx 内部结构（自上而下）

- `ClawSkillDataOverview`（默认导出）：读取 `getTaskReportBbk()` 获取分行身份，无身份时渲染告警；否则渲染 `ScopedReportPage`。
- `ScopedReportPage`：筛选面板（统计维度、统计日期、机构/技能筛选、客户经理搜索、任务类型），拼装 `ReportParams`，渲染 `ReportResults`。
- `ReportResults`：汇总报表 + 技能明细。点击「技能总数」列 `setSelected(row)`，`selected` 存在时渲染 `<SkillDetails>`。
- `ReportTable`：通用报表表格，承载空态/错误态/「结果超上限截断」提示/滚动到底加载更多。
- `SkillDetails`：技能明细区，以 `skill_detail: true` 复用 `ReportTable`。
- 辅助函数：`metricColumns`（指标列生成）、`entityKey` / `entityName` / `skillName`（行主体键/名称/技能名称）、`metricColumnWidth`。

## 二、接口（`src/api/modules/taskTypeReport.ts`）

基础路径 `REPORT_PATH = "/monitor/report/task-type"`，请求统一走 `buildAuthHeaders()`，分行隔离由 `scopedParams()` 强制：非 100 分行只能查自身 `first_bbk_id`。

| 函数 | HTTP | 说明 |
| ---- | ---- | ---- |
| `getTaskTypeReport(params, signal)` | `GET /monitor/report/task-type` | 主报表数据，返回 `ReportResponse` |
| `getTaskReportOptions(params, signal)` | `GET /monitor/report/task-type/options` | 下拉选项，kind 为 `branches`/`orgs`/`skills` |
| `getTaskReportDates(signal)` | `GET /monitor/report/task-type/dates?limit=90` | 最近 90 个快照日期，用于日历可选范围 |
| `exportTaskReport(params, signal)` | `GET /monitor/report/task-type/export` | Excel 导出，用 `fetch` + `blob`，不走 `request` |

### `ReportParams` 关键字段

| 字段 | 含义 |
| ---- | ---- |
| `group_by` | 统计维度：`branch`(分行) / `org`(支行) / `manager`(客户经理) / `skill`(技能) |
| `task_type` | `push_plan`(推送名单+方案) / `ask_plan`(主动提问) / `push_other`(推送非名单方案) |
| `skill_detail` | `true` 表示下钻，返回某机构/客户经理关联的技能明细 |
| `skill_name` | 技能维度下的技能过滤 |
| `first_bbk_id` / `org_id` / `user_id` | 分行 / 支行 / 客户经理维度过滤 |
| `keyword` | 客户经理维度（manager/skill）姓名或 SAP 号搜索 |
| `page` / `page_size` | 服务端分页参数 |

### 分页与加载

- `branch` / `org` 维度：一次取全量，客户端 `slice` 分页（`REPORT_PAGE_SIZE = 20`）。
- `manager` / `skill` 维度：服务端分页，`useReport.loadMore` 追加下一页。
- 滚动到底触发 `loadMore` 的判断在 `ReportTable` 的 `onScroll`（距底部 < 48px 且无错误时）。

### 快照与空态

- 数据按 T-1 出数，最新可选统计日期 `latestReportDate()`。
- 后端错误码 `report_snapshot_not_found` → `snapshotUnavailable()` 返回 `"missing"`，页面显示「该统计日期暂无出仓数据」空态（`useReport.failure`）。
- 演示模式 `isTaskReportDemo()` 时，接口直接返回 `taskTypeReportDemo.ts` 的本地假数据，导出会抛错。

## 三、关键交互约定

- 「技能总数」列（`skill_count`）仅在非技能维度展示，点击 `setSelected(row)` 展开下方 `SkillDetails`；技能维度一行即一个技能，不下钻。
- 明细区标题显示 `entityName(row, params.group_by)`，即点击的是哪个机构/客户经理。
- 明细区提示「同一任务或客户可能关联多个技能，技能明细各行不可直接相加」。

## 四、改动记录

### 2026-10 点击「技能总数」自动滚动到技能明细

**意图**：点击「技能总数」展开技能明细后，页面滚动条停留在原处，用户不知道下方已展开明细。

**改动位置**：`src/pages/Analytics/ClawSkillDataOverview/index.tsx` 的 `ReportResults`。

**改动内容**：

1. 新增 `detailRef = useRef<HTMLDivElement>(null)`，用 `<div ref={detailRef}>` 包裹 `<SkillDetails>`。
2. 新增 `useEffect`，`selected` 有值时调用 `detailRef.current?.scrollIntoView?.({ behavior: "smooth", block: "start" })`，明细渲染后平滑滚动到其顶部。
3. 使用 `scrollIntoView?.()` 可选链：jsdom 未实现该方法，避免测试环境调用 `undefined` 抛错（与仓库内 `SkillMentions` 等处的写法一致）。

**测试**：`src/pages/Analytics/ClawSkillDataOverview/index.test.tsx` 新增 `scrolls the skill details into view when the count is clicked`，mock `HTMLElement.prototype.scrollIntoView`（try/finally 恢复原型），点击「技能总数」后断言明细出现且滚动参数为 `{ behavior: "smooth", block: "start" }`。

**验证**：`npx vitest run src/pages/Analytics/ClawSkillDataOverview/index.test.tsx` 23 用例通过；`npx eslint` 无报错。

**后续开发提示**：该页面的滚动交互统一在 `ReportTable` 的 `onScroll`（加载更多）与本例 `scrollIntoView`（定位明细）。若新增「定位到某行/某区」类需求，沿用 `scrollIntoView` + 可选链 `?.()` 的写法，并在测试中 mock 该方法。
