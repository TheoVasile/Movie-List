const pool = require("../config/db");

// Celebrations for how many films the user has put in their lists. Each one plays once per user, ever, so the
// ones already reached are kept here rather than on the phone: a second device, a reinstall or removing films and
// adding them back doesn't play it again
const MILESTONES = { films_10: 10, films_50: 50, films_100: 100, films_1000: 1000, films_10000: 10000 };

// How many different films and shows are in the lists the user owns (a film in two lists counts once)
async function distinctFilmCount(user_id) {
    const result = await pool.query(
        `SELECT COUNT(DISTINCT lm.movie_id)::int AS count
         FROM lists l
         JOIN list_movies lm ON lm.list_id = l.id
         WHERE l.user_id = $1`,
        [user_id]
    );
    return result.rows[0]?.count ?? 0;
}

// The milestones the user has reached, oldest first
async function fetchMilestones(user_id) {
    const result = await pool.query(
        "SELECT milestone, achieved_at FROM user_milestones WHERE user_id = $1 ORDER BY achieved_at, milestone",
        [user_id]
    );
    return result.rows;
}

class UnknownMilestoneError extends Error {}
class MilestoneNotReachedError extends Error {}

// Records a milestone once the user really has that many films. created is false when it was already recorded,
// so only the first device to ask plays the celebration
async function recordMilestone(user_id, milestone) {
    if (!Object.prototype.hasOwnProperty.call(MILESTONES, milestone)) throw new UnknownMilestoneError();
    const count = await distinctFilmCount(user_id);
    if (count < MILESTONES[milestone]) throw new MilestoneNotReachedError();
    const result = await pool.query(
        `INSERT INTO user_milestones (user_id, milestone) VALUES ($1, $2)
         ON CONFLICT (user_id, milestone) DO NOTHING`,
        [user_id, milestone]
    );
    return { created: result.rowCount > 0, count };
}

module.exports = { MILESTONES, distinctFilmCount, fetchMilestones, recordMilestone, UnknownMilestoneError, MilestoneNotReachedError };
