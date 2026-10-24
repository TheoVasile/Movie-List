const pool = require("../config/db");

// Reports of objectionable users and content. Anyone can report another user, or something of theirs, for us to
// review; we aim to review every report within 24 hours

const REPORT_REASONS = ["spam", "harassment", "hate", "sexual", "violence", "impersonation", "other"];
const REPORT_CONTENT_TYPES = ["user", "list", "note", "recommendation", "activity", "group"];
const MAX_DETAILS = 500;

/// Saves a report against @handle. report is { content_type, content_id, reason, details }. Reporting the same
/// thing again within a day doesn't add another report. Returns { id, duplicate }, or null when there's no such
/// user (or it's the user themselves)
async function createReport(user_id, handle, report) {
    const target = await pool.query("SELECT firebase_uid FROM users WHERE handle = $1 AND firebase_uid <> $2", [handle, user_id]);
    const reported_id = target.rows[0]?.firebase_uid;
    if (!reported_id) return null;
    const recent = await pool.query(
        `SELECT id FROM reports
         WHERE reporter_id = $1 AND reported_user_id = $2 AND content_type = $3 AND content_id IS NOT DISTINCT FROM $4
           AND created_at > NOW() - INTERVAL '24 hours'
         LIMIT 1`,
        [user_id, reported_id, report.content_type, report.content_id]
    );
    if (recent.rows.length) return { id: recent.rows[0].id, duplicate: true };
    const result = await pool.query(
        `INSERT INTO reports (reporter_id, reported_user_id, content_type, content_id, reason, details)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
        [user_id, reported_id, report.content_type, report.content_id, report.reason, report.details]
    );
    return { id: result.rows[0].id, duplicate: false, reported_id };
}

/// Tells whoever runs Marquee about a new report: always in the server log, and also to REPORTS_WEBHOOK_URL
/// (e.g. a Slack or Discord webhook) when it's set. Never throws, so a failed alert doesn't fail the report
async function notifyOperator(report) {
    const summary = `New report #${report.id}: @${report.handle} (${report.content_type}${report.content_id ? ` ${report.content_id}` : ""}) for ${report.reason}${report.details ? ` - "${report.details}"` : ""}`;
    console.log(summary);
    const webhook = process.env.REPORTS_WEBHOOK_URL;
    if (!webhook) return;
    try {
        await fetch(webhook, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            // text for Slack, content for Discord
            body: JSON.stringify({ text: summary, content: summary }),
        });
    } catch (error) {
        console.error("Error sending report alert:", error);
    }
}

/// The open reports, oldest first, for whoever reviews them
async function fetchOpenReports() {
    const result = await pool.query(
        `SELECT r.id, r.content_type, r.content_id, r.reason, r.details, r.status,
                to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at,
                reporter.handle AS reporter_handle, reported.handle AS reported_handle
         FROM reports r
         JOIN users reporter ON reporter.firebase_uid = r.reporter_id
         JOIN users reported ON reported.firebase_uid = r.reported_user_id
         WHERE r.status = 'open'
         ORDER BY r.created_at`
    );
    return result.rows;
}

module.exports = { REPORT_REASONS, REPORT_CONTENT_TYPES, MAX_DETAILS, createReport, notifyOperator, fetchOpenReports };
