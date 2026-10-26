const pool = require("../config/db");
const { FIELDS, check } = require("../services/moderation");
const { reportFlagged } = require("../models/reportsModel");

// Checks what people already wrote against the moderation rules (services/moderation.js), for after the term list
// changes or when moderation is first turned on. Run by hand from backend/:
//
//     node scripts/scanModeration.js               lists what would match: counts and ids, changes nothing
//     node scripts/scanModeration.js --flag-notes  also flags matching notes and recommendation messages that
//                                                  are still "ok", and reports each for review
//
// Names that would be blocked today are only listed: renaming someone is for a person to decide

const FLAG_NOTES = process.argv.includes("--flag-notes");

// What to scan: each query returns id, user_id and text; field is the moderation policy it's checked against
const SOURCES = [
    { label: "@usernames", field: "handle", sql: "SELECT firebase_uid AS id, firebase_uid AS user_id, handle AS text FROM users WHERE handle IS NOT NULL" },
    { label: "Display names", field: "display_name", sql: "SELECT firebase_uid AS id, firebase_uid AS user_id, username AS text FROM users" },
    { label: "List names", field: "list_name", sql: "SELECT id, user_id, name AS text FROM lists" },
    { label: "List descriptions", field: "list_description", sql: "SELECT id, user_id, overview AS text FROM lists WHERE overview <> ''" },
    { label: "Group names", field: "group_name", sql: "SELECT id, owner_id AS user_id, name AS text FROM watch_groups" },
    {
        label: "Film notes", field: "note", flaggable: "note",
        sql: `SELECT n.user_id || ':' || n.movie_id AS id, n.user_id, n.movie_id, m.tmdb_id, n.note AS text, n.moderation_status
              FROM movie_notes n JOIN movies m ON m.id = n.movie_id`,
    },
    {
        label: "Recommendation messages", field: "recommendation_note", flaggable: "recommendation",
        sql: "SELECT id, sender_id AS user_id, note AS text, moderation_status FROM film_recommendations WHERE note IS NOT NULL",
    },
];

// Marks one note or recommendation message as flagged and reports it, unless it's already been through review
async function flag(source, row, reason) {
    if (row.moderation_status !== "ok") return false;
    if (source.flaggable === "note") {
        await pool.query("UPDATE movie_notes SET moderation_status = 'flagged' WHERE user_id = $1 AND movie_id = $2", [row.user_id, row.movie_id]);
        await reportFlagged(row.user_id, { content_type: "note", content_id: row.tmdb_id, reason, details: row.text });
    } else {
        await pool.query("UPDATE film_recommendations SET moderation_status = 'flagged' WHERE id = $1", [row.id]);
        await reportFlagged(row.user_id, { content_type: "recommendation", content_id: String(row.id), reason, details: row.text });
    }
    return true;
}

async function scan() {
    let total = 0;
    for (const source of SOURCES) {
        const rows = (await pool.query(source.sql)).rows;
        const matches = [];
        for (const row of rows) {
            const result = check(source.field, row.text);
            if (result.action !== "ok") matches.push({ row, result });
        }
        total += matches.length;
        console.log(`\n${source.label}: ${matches.length} of ${rows.length} would be ${FIELDS[source.field].action === "flag" ? "flagged" : "blocked"}`);
        let flagged = 0;
        for (const { row, result } of matches) {
            // Ids and categories only, so the output can be shared without repeating what was written
            console.log(`  ${row.id}  ${result.category}${row.moderation_status && row.moderation_status !== "ok" ? `  (already ${row.moderation_status})` : ""}`);
            if (FLAG_NOTES && source.flaggable && (await flag(source, row, result.reason))) flagged++;
        }
        if (FLAG_NOTES && source.flaggable) console.log(`  Flagged ${flagged} for review`);
    }
    console.log(`\n${total} match${total === 1 ? "" : "es"} in total${FLAG_NOTES ? "" : ". Nothing was changed"}`);
}

scan()
    .then(() => pool.end())
    .catch((error) => {
        console.error("Scan failed:", error);
        pool.end(() => process.exit(1));
    });
