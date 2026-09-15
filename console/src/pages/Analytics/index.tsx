import { Routes, Route, Navigate } from "react-router-dom";
import UsersPage from "./Users";
import SessionsPage from "./Sessions";
import MessagesPage from "./Messages";
import TracesPage from "./Traces";
import BusinessOverviewPage from "./BusinessOverview";
import CronJobOverviewPage from "./CronJobOverview";
import ClawDataOverviewPage from "./ClawDataOverview";
import ClawSkillDataOverview from "./ClawSkillDataOverview";
import ContinuousGovernancePage from "./ContinuousGovernance";

export default function AnalyticsPage() {
  return (
    <Routes>
      <Route path="/" element={<Navigate to="business-overview" replace />} />
      <Route path="users" element={<UsersPage />} />
      <Route path="sessions" element={<SessionsPage />} />
      <Route path="messages" element={<MessagesPage />} />
      <Route path="traces" element={<TracesPage />} />
      <Route path="business-overview" element={<BusinessOverviewPage />} />
      <Route path="claw-data-overview" element={<ClawDataOverviewPage />} />
      <Route path="claw-skill-data-overview" element={<ClawSkillDataOverview />} />
      <Route path="cron-job-overview" element={<CronJobOverviewPage />} />
      <Route
        path="continuous-governance"
        element={<ContinuousGovernancePage />}
      />
    </Routes>
  );
}
