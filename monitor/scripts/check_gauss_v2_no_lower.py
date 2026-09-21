"""Run with venv/Scripts/python.exe scripts/check_gauss_v2_no_lower.py.

Execute the actual roster/ask SQL with SQLite fixtures; this is not Gauss dialect validation.
"""
from pathlib import Path
import re
import sqlite3

sql = (Path(__file__).resolve().parents[1] / 'gauss/task_type_report_gauss_optimized_v2_no_lower.sql').read_text(encoding='utf-8')
sql = re.sub(r'/\*.*?\*/|--[^\n]*', '', sql, flags=re.S)
sql = sql.replace('${AALC_DATA}.', '').replace('${NDS_DATA}.', '')
statements = sql.split(';')
db = sqlite3.connect(':memory:')
# Reuse every temporary table definition, stripping only Gauss storage options.
for statement in statements:
    if statement.strip().lower().startswith('create temporary table'):
        db.execute(re.split(r'\bWITH\s*\(', statement, flags=re.I)[0])
db.executescript("""
CREATE TABLE AALC_R_RM_SFL_CM_BAS_INFO
(DW_SNSH_DT, CLB_IND, CM_ID, CM_NM, PST_LVL, BRN_ORG_ID, BRN_ORG_NM, FRS_BBK_ORG_ID, FRS_BBK_ORG_NM);
INSERT INTO TF_CALENDAR VALUES
(1,'2026-08-31','2026-08-01','2026-09-01'),
(2,'2026-09-01','2026-09-01','2026-09-02'),
(3,'2026-09-02','2026-09-01','2026-09-03');
INSERT INTO AALC_R_RM_SFL_CM_BAS_INFO VALUES
('2026-08-31','3','m','old','p','o1','old org','b1','old branch'),
('2026-09-01','3','m','new','p','o2','new org','b2','new branch');
CREATE TABLE NLQ13_SWE_TRACING_SPANS (SOURCE_ID, TRACE_ID, SKILL_ID, USER_ID, START_TIME);
INSERT INTO TF_SKILL_CATALOG VALUES ('s','k','skill');
INSERT INTO TF_TRACE_SUB VALUES ('aug'),('sep'),('outside'),('excluded'),('cron');
INSERT INTO TF_TRACE_EXEC VALUES ('cron');
INSERT INTO NLQ13_SWE_TRACING_SPANS VALUES
('s','aug','k','m','2026-08-31 23:59:59'),
('s','sep','k','m','2026-09-01 00:00:00'),
('s','outside','k','m','2026-09-02 00:00:00'),
('s','excluded','other','m','2026-09-01 12:00:00'),
('s','cron','k','m','2026-09-01 12:00:00');
""")
for table in ('TF_JKH_ROSTER', 'TF_ASK_TRACE'):
    statement = next(s for s in statements if re.match(r'\s*insert into '+table+r'\b', s, re.I))
    # ISO timestamp text has the same ordering; SQLite's TIMESTAMP cast does not.
    statement = re.sub(r'CAST\((CAL\.\w+) AS TIMESTAMP\)', r"(\1 || ' 00:00:00')", statement)
    db.execute(statement)
assert db.execute('SELECT REPLAY_SEQ, CM_NM, FRS_BBK_ORG_ID FROM TF_JKH_ROSTER ORDER BY 1').fetchall() == [(1,'old','b1'),(2,'new','b2')]
assert db.execute('SELECT REPLAY_SEQ, TRACE_ID, FRS_BBK_ORG_ID FROM TF_ASK_TRACE ORDER BY 1').fetchall() == [(1,'aug','b1'),(2,'sep','b2')]
# A trace from September must not qualify a click in the August replay partition.
db.executescript("""
INSERT INTO TF_CLICK_EVENT (REPLAY_SEQ, EVENT_ID, SOURCE_ID, TRACE_ID) VALUES
(1,1,'s','sep'),(2,2,'s','sep');
""")
statement = next(s for s in statements if re.match(r'\s*insert into TF_CLICK_ASK\b', s, re.I))
db.execute(statement)
assert db.execute('SELECT REPLAY_SEQ, EVENT_ID FROM TF_CLICK_ASK').fetchall() == [(2,2)]
# Every referenced temporary table must still have a definition.
created = set(re.findall(r'create temporary table (TF_\w+)', sql, re.I))
referenced = set(re.findall(r'\bTF_\w+\b', sql))
assert referenced == created, referenced - created
print('PASS: daily roster, missing snapshot, month/cutoff boundaries, catalog/cron exclusion, click replay isolation, temporary table references')

# A matched owner must not let an unmatched executor create customer dimensions.
db.executescript("""
INSERT INTO TF_PUSH_EXEC_SKILL
(REPLAY_SEQ, SOURCE_ID, EXEC_ID, JOB_ID, TRACE_ID, SKILL_ID, JOB_TYPE,
 EXEC_CM_ID, EXEC_IN_ROSTER, EXEC_FRS_BBK_ORG_ID, EXEC_BRN_ORG_ID,
 OWNER_CM_ID, OWNER_IN_ROSTER)
VALUES
(2,'s',1,'j','matched','k','push_plan','m',1,'b2','o2','m',1),
(2,'s',2,'j','missing','k','push_plan','absent',0,'','','m',1),
(3,'s',3,'j','missing_day','k','push_plan','m',0,'','','m',0);
INSERT INTO TF_SUBTASK_CUST VALUES
('matched','c1'),('missing','c2'),('missing_day','c3');
""")
statement = next(s for s in statements if re.match(r'\s*insert into TF_PUSH_CUST\b', s, re.I))
db.execute(statement)
assert db.execute('SELECT REPLAY_SEQ, CUSTUID, EXEC_CM_ID, EXEC_FRS_BBK_ORG_ID FROM TF_PUSH_CUST').fetchall() == [(2,'c1','m','b2')]
print('PASS: unmatched executor and missing-day roster excluded from push customers')
