const pool = require("../config/db");
const { notifyUser } = require("../services/pushService");

// Movie night votes: someone in a group sends 2 to 5 films, everyone votes 👍 or 👎 on each, and the poll closes
// once everyone has voted on every film or its time runs out. The winner has the most 👍 minus 👎, then the most
// 👍, then whichever was sent first. A group has one open poll at a time: starting a new one closes the last

const MIN_FILMS = 2;
const MAX_FILMS = 5;
// A closed poll stays on the group's screen this long, so everyone sees the winner
const SHOW_RESULT_FOR_HOURS = 24;

// Polls waiting to close on time, so the same one isn't scheduled twice
const timers = new Map();

/// Everyone in the group, as account ids and names. Empty when the group doesn't exist
async function groupPeople(group_id) {
    const result = await pool.query(
        `SELECT u.firebase_uid, COALESCE(u.username, u.handle) AS name
         FROM watch_groups g
         JOIN users u ON u.firebase_uid = g.owner_id OR u.firebase_uid IN (SELECT user_id FROM watch_group_members WHERE group_id = g.id)
         WHERE g.id = $1`,
        [group_id]
    );
    return result.rows;
}

/// Starts a poll for a group the user is in. films are [{ tmdb_id, title, poster_path, release_date, reason }].
/// Returns the poll id, or null when the user isn't in the group
async function startPoll(user_id, group_id, films, hours) {
    const people = await groupPeople(group_id);
    const me = people.find((p) => p.firebase_uid === user_id);
    if (!me) return null;
    // Any poll still open is replaced
    await pool.query("UPDATE group_polls SET closed_at = CURRENT_TIMESTAMP WHERE group_id = $1 AND closed_at IS NULL", [group_id]);
    const poll = await pool.query(
        `INSERT INTO group_polls (group_id, created_by, closes_at)
         VALUES ($1, $2, CURRENT_TIMESTAMP + make_interval(hours => $3)) RETURNING id, closes_at`,
        [group_id, user_id, hours]
    );
    const { id, closes_at } = poll.rows[0];
    for (const [position, film] of films.entries()) {
        await pool.query(
            `INSERT INTO poll_options (poll_id, tmdb_id, title, poster_path, release_date, reason, position)
             VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT DO NOTHING`,
            [id, film.tmdb_id, film.title, film.poster_path, film.release_date, film.reason, position]
        );
    }
    scheduleClose(id, closes_at);
    const group = await pool.query("SELECT name FROM watch_groups WHERE id = $1", [group_id]);
    await Promise.all(people.filter((p) => p.firebase_uid !== user_id).map((p) => notifyUser(p.firebase_uid, "poll_started", {
        title: `Vote for ${group.rows[0].name}'s movie night`,
        body: `${me.name} picked ${films.length} films. Vote 👍 or 👎 on each before ${hours === 1 ? "the hour" : `${hours} hours`} are up.`,
        data: { group_id: String(group_id) },
    })));
    return id;
}

/// The group's open poll, or the last one if it closed recently, as everyone's tallies plus the user's own
/// votes. null when there's none or the user isn't in the group
async function currentPoll(user_id, group_id) {
    const people = await groupPeople(group_id);
    if (!people.some((p) => p.firebase_uid === user_id)) return null;
    const found = await pool.query(
        `SELECT p.id, p.created_by, COALESCE(u.username, u.handle) AS created_by_name, p.created_at, p.closes_at, p.closed_at, p.winner_tmdb_id
         FROM group_polls p LEFT JOIN users u ON u.firebase_uid = p.created_by
         WHERE p.group_id = $1 AND (p.closed_at IS NULL OR p.closed_at > CURRENT_TIMESTAMP - make_interval(hours => $2))
         ORDER BY p.created_at DESC LIMIT 1`,
        [group_id, SHOW_RESULT_FOR_HOURS]
    );
    let poll = found.rows[0];
    if (!poll) return null;
    // Closed late if the server was asleep when its time ran out
    if (!poll.closed_at && new Date(poll.closes_at) <= new Date()) {
        await closePoll(poll.id);
        return currentPoll(user_id, group_id);
    }
    const options = await pool.query(
        `SELECT o.tmdb_id, o.title, o.poster_path, o.release_date, o.reason,
                COUNT(v.*) FILTER (WHERE v.vote = 1)::int AS up, COUNT(v.*) FILTER (WHERE v.vote = -1)::int AS down,
                MAX(v.vote) FILTER (WHERE v.user_id = $2) AS my_vote
         FROM poll_options o LEFT JOIN poll_votes v ON v.poll_id = o.poll_id AND v.tmdb_id = o.tmdb_id
         WHERE o.poll_id = $1
         GROUP BY o.tmdb_id, o.title, o.poster_path, o.release_date, o.reason, o.position
         ORDER BY o.position`,
        [poll.id, user_id]
    );
    const voted = await pool.query("SELECT COUNT(DISTINCT user_id)::int AS n FROM poll_votes WHERE poll_id = $1", [poll.id]);
    return {
        id: poll.id,
        created_by_name: poll.created_by_name,
        started_by_me: poll.created_by === user_id,
        closes_at: poll.closes_at,
        closed: Boolean(poll.closed_at),
        winner_tmdb_id: poll.winner_tmdb_id,
        // How many people have voted on at least one film, out of everyone in the group
        voters: voted.rows[0].n,
        people: people.length,
        options: options.rows.map((o) => ({ ...o, my_vote: o.my_vote ?? 0 })),
    };
}

/// Records the user's vote on one film (1, -1, or 0 to take it back). Returns false when the poll isn't open or
/// isn't one of their group's. Closes the poll once everyone has voted on every film
async function vote(user_id, group_id, poll_id, tmdb_id, value) {
    const poll = await pool.query(
        "SELECT 1 FROM group_polls WHERE id = $1 AND group_id = $2 AND closed_at IS NULL AND closes_at > CURRENT_TIMESTAMP",
        [poll_id, group_id]
    );
    if (!poll.rowCount || !(await groupPeople(group_id)).some((p) => p.firebase_uid === user_id)) return false;
    const option = await pool.query("SELECT 1 FROM poll_options WHERE poll_id = $1 AND tmdb_id = $2", [poll_id, tmdb_id]);
    if (!option.rowCount) return false;
    if (value === 0) {
        await pool.query("DELETE FROM poll_votes WHERE poll_id = $1 AND tmdb_id = $2 AND user_id = $3", [poll_id, tmdb_id, user_id]);
    } else {
        await pool.query(
            `INSERT INTO poll_votes (poll_id, tmdb_id, user_id, vote) VALUES ($1, $2, $3, $4)
             ON CONFLICT (poll_id, tmdb_id, user_id) DO UPDATE SET vote = $4`,
            [poll_id, tmdb_id, user_id, value]
        );
    }
    const counts = await pool.query(
        `SELECT (SELECT COUNT(*) FROM poll_options WHERE poll_id = $1)::int AS films,
                (SELECT COUNT(*) FROM poll_votes WHERE poll_id = $1)::int AS votes`,
        [poll_id]
    );
    const people = (await groupPeople(group_id)).length;
    if (counts.rows[0].votes >= counts.rows[0].films * people) await closePoll(poll_id);
    return true;
}

/// Closes a poll, picks its winner and tells everyone. Does nothing if it's already closed
async function closePoll(poll_id) {
    const closed = await pool.query(
        "UPDATE group_polls SET closed_at = CURRENT_TIMESTAMP WHERE id = $1 AND closed_at IS NULL RETURNING group_id",
        [poll_id]
    );
    clearTimeout(timers.get(poll_id));
    timers.delete(poll_id);
    if (!closed.rowCount) return;
    const group_id = closed.rows[0].group_id;
    const best = await pool.query(
        `SELECT o.tmdb_id, o.title,
                COALESCE(SUM(v.vote), 0)::int AS score, COUNT(v.*) FILTER (WHERE v.vote = 1)::int AS up
         FROM poll_options o LEFT JOIN poll_votes v ON v.poll_id = o.poll_id AND v.tmdb_id = o.tmdb_id
         WHERE o.poll_id = $1
         GROUP BY o.tmdb_id, o.title, o.position
         ORDER BY score DESC, up DESC, o.position
         LIMIT 1`,
        [poll_id]
    );
    const winner = best.rows[0];
    if (!winner) return;
    await pool.query("UPDATE group_polls SET winner_tmdb_id = $2 WHERE id = $1", [poll_id, winner.tmdb_id]);
    const group = await pool.query("SELECT name FROM watch_groups WHERE id = $1", [group_id]);
    const people = await groupPeople(group_id);
    await Promise.all(people.map((p) => notifyUser(p.firebase_uid, "poll_result", {
        title: `${group.rows[0]?.name ?? "Movie night"} picked ${winner.title} 🍿`,
        body: winner.up ? `It won the vote with ${winner.up} 👍.` : "Nobody voted, so it's the first pick.",
        data: { group_id: String(group_id) },
    })));
}

/// Closes the poll when its time runs out. Timers longer than a day aren't needed: polls last at most 24 hours
function scheduleClose(poll_id, closes_at) {
    if (timers.has(poll_id)) return;
    const delay = Math.max(0, new Date(closes_at) - Date.now());
    timers.set(poll_id, setTimeout(() => closePoll(poll_id).catch((error) => console.error("Couldn't close poll:", error.message)), delay));
}

/// On server start: schedules every open poll, closing any whose time ran out while the server was down
async function scheduleOpenPolls() {
    try {
        const open = await pool.query("SELECT id, closes_at FROM group_polls WHERE closed_at IS NULL");
        open.rows.forEach((poll) => scheduleClose(poll.id, poll.closes_at));
    } catch (error) {
        console.error("Couldn't schedule open polls:", error.message);
    }
}

/// Which of the user's groups have an open poll, and whether the user still has films to vote on there
async function openPollsFor(user_id, group_ids) {
    const result = await pool.query(
        `SELECT p.group_id,
                (SELECT COUNT(*) FROM poll_options o WHERE o.poll_id = p.id) >
                (SELECT COUNT(*) FROM poll_votes v WHERE v.poll_id = p.id AND v.user_id = $1) AS needs_my_vote
         FROM group_polls p
         WHERE p.group_id = ANY($2::int[]) AND p.closed_at IS NULL AND p.closes_at > CURRENT_TIMESTAMP`,
        [user_id, group_ids]
    );
    return new Map(result.rows.map((row) => [row.group_id, row.needs_my_vote]));
}

module.exports = { MIN_FILMS, MAX_FILMS, startPoll, currentPoll, vote, closePoll, scheduleOpenPolls, openPollsFor };
