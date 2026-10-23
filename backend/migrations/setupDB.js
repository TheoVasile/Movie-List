// Connect to PostgreSQL
const pool = require("../config/db");

// Define table creation queries
const createTables = async () => {
    //const client = await pool.connect( (err, connection) => {
    //    if (err) throw err;
    //    console.log('Database is connected successfully !');
    //    connection.release();
    //  }); 
    console.log("Connected to database");
    try {
        console.log("Creating database tables");
        await pool.query(`
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                firebase_uid VARCHAR(255) UNIQUE NOT NULL, 
                username VARCHAR(50) UNIQUE NOT NULL,
                email VARCHAR(255) UNIQUE NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            -- The @username people search for to follow each other. Picked by the user, always lowercase;
            -- null until they choose one. username stays the display name
            ALTER TABLE users ADD COLUMN IF NOT EXISTS handle VARCHAR(20) UNIQUE;

            -- Whether the user allows AI features. Kept on the server so a friend's Movie Night can check
            -- that both people agreed before either person's lists go to the AI
            ALTER TABLE users ADD COLUMN IF NOT EXISTS ai_allowed BOOLEAN NOT NULL DEFAULT false;

            -- Profile picture: a small JPEG (256x256) cropped and compressed by the app, and when it changed,
            -- which the app uses to know when to fetch it again
            ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar BYTEA;
            ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_updated_at TIMESTAMP;

            -- Replaced by phone below. Numbers saved this way were never verified, so they're cleared; the
            -- column stays only until no running server reads it
            ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_hash CHAR(64);
            UPDATE users SET phone_hash = NULL WHERE phone_hash IS NOT NULL;
            -- The user's phone number in international format (+14165550100), if they added one so friends can
            -- find them from their contacts. Only ever copied from their Firebase account once Firebase has
            -- verified it with a text message
            ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(20);
            CREATE UNIQUE INDEX IF NOT EXISTS users_phone ON users (phone) WHERE phone IS NOT NULL;

            -- Which push notifications the user wants. The phone also has to allow notifications
            ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_requests BOOLEAN NOT NULL DEFAULT true;
            ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_activity BOOLEAN NOT NULL DEFAULT true;
            -- When the user last got the daily friends digest, so they never get two in a day
            ALTER TABLE users ADD COLUMN IF NOT EXISTS last_digest_at TIMESTAMP;
            -- Streaming alerts: the user's country and services (TMDb provider ids), whether they want the alerts,
            -- and when they were last sent one
            ALTER TABLE users ADD COLUMN IF NOT EXISTS streaming_region VARCHAR(2);
            ALTER TABLE users ADD COLUMN IF NOT EXISTS streaming_services INT[] NOT NULL DEFAULT '{}';
            ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_streaming BOOLEAN NOT NULL DEFAULT true;
            ALTER TABLE users ADD COLUMN IF NOT EXISTS last_streaming_alert_at TIMESTAMP;
            -- Private profiles approve each follower; public ones (the default, and every account from before
            -- this existed) are followed straight away
            ALTER TABLE users ADD COLUMN IF NOT EXISTS is_private BOOLEAN NOT NULL DEFAULT false;

            -- Movie night groups, made by one user from people they follow
            CREATE TABLE IF NOT EXISTS watch_groups (
                id SERIAL PRIMARY KEY,
                owner_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                name VARCHAR(60) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS watch_group_members (
                group_id INT NOT NULL REFERENCES watch_groups(id) ON DELETE CASCADE,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                PRIMARY KEY (group_id, user_id)
            );

            -- Which services each film streams on in each country, as of the last daily check, so streaming alerts
            -- only go out for changes
            CREATE TABLE IF NOT EXISTS film_availability (
                tmdb_id INT NOT NULL,
                region VARCHAR(2) NOT NULL,
                providers INT[] NOT NULL DEFAULT '{}',
                checked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (tmdb_id, region)
            );
            -- Streaming alerts already sent, so a film that leaves a service and comes back isn't announced twice
            CREATE TABLE IF NOT EXISTS streaming_alerts_sent (
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                tmdb_id INT NOT NULL,
                provider_id INT NOT NULL,
                sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, tmdb_id, provider_id)
            );

            -- Movie night votes: films someone in a group sent for everyone to vote on, and the votes
            CREATE TABLE IF NOT EXISTS group_polls (
                id SERIAL PRIMARY KEY,
                group_id INT NOT NULL REFERENCES watch_groups(id) ON DELETE CASCADE,
                created_by VARCHAR(255) REFERENCES users(firebase_uid) ON DELETE SET NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                closes_at TIMESTAMP NOT NULL,
                closed_at TIMESTAMP,
                winner_tmdb_id INT
            );
            CREATE TABLE IF NOT EXISTS poll_options (
                poll_id INT NOT NULL REFERENCES group_polls(id) ON DELETE CASCADE,
                tmdb_id INT NOT NULL,
                title VARCHAR(255) NOT NULL,
                poster_path VARCHAR(255),
                release_date VARCHAR(20),
                reason TEXT,
                position INT NOT NULL,
                PRIMARY KEY (poll_id, tmdb_id)
            );
            CREATE TABLE IF NOT EXISTS poll_votes (
                poll_id INT NOT NULL REFERENCES group_polls(id) ON DELETE CASCADE,
                tmdb_id INT NOT NULL,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                vote SMALLINT NOT NULL CHECK (vote IN (-1, 1)),
                PRIMARY KEY (poll_id, tmdb_id, user_id)
            );

            -- A group's movie night shortlist: films recommended for it (suggested_by null) and films people in it
            -- suggested, with everyone's likes and dislikes. Films everyone disliked are kept in group_dismissed so
            -- they're never recommended to the group again
            CREATE TABLE IF NOT EXISTS group_picks (
                group_id INT NOT NULL REFERENCES watch_groups(id) ON DELETE CASCADE,
                tmdb_id INT NOT NULL,
                title VARCHAR(255) NOT NULL,
                poster_path VARCHAR(255),
                release_date VARCHAR(20),
                overview TEXT,
                original_language VARCHAR(10),
                popularity DOUBLE PRECISION,
                reason TEXT,
                suggested_by VARCHAR(255) REFERENCES users(firebase_uid) ON DELETE SET NULL,
                position INT NOT NULL DEFAULT 0,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (group_id, tmdb_id)
            );
            -- Whether the AI (Claude) picked it, as opposed to TMDb's recommendations, so only those get the AI mark
            ALTER TABLE group_picks ADD COLUMN IF NOT EXISTS by_ai BOOLEAN NOT NULL DEFAULT false;
            CREATE TABLE IF NOT EXISTS group_pick_reactions (
                group_id INT NOT NULL,
                tmdb_id INT NOT NULL,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                reaction SMALLINT NOT NULL CHECK (reaction IN (-1, 1)),
                reacted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (group_id, tmdb_id, user_id),
                FOREIGN KEY (group_id, tmdb_id) REFERENCES group_picks(group_id, tmdb_id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS group_dismissed (
                group_id INT NOT NULL REFERENCES watch_groups(id) ON DELETE CASCADE,
                tmdb_id INT NOT NULL,
                title VARCHAR(255),
                PRIMARY KEY (group_id, tmdb_id)
            );

            -- People the owner of a list has invited to edit it with them: they can add, rank and remove its films
            CREATE TABLE IF NOT EXISTS list_editors (
                list_id INT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (list_id, user_id)
            );

            -- Lists people follow to hear about updates in their daily digest
            CREATE TABLE IF NOT EXISTS list_follows (
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                list_id INT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, list_id)
            );

            -- Firebase Cloud Messaging tokens: one per device the user is signed in on
            CREATE TABLE IF NOT EXISTS device_tokens (
                token TEXT PRIMARY KEY,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS device_tokens_user ON device_tokens (user_id);

            -- One-way follows: once accepted, following someone lets you see their lists, rankings and
            -- watched films (never their notes)
            CREATE TABLE IF NOT EXISTS follows (
                follower_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                followee_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (follower_id, followee_id),
                CHECK (follower_id <> followee_id)
            );
            -- Follows are requests until the person being followed accepts. Follows from before requests
            -- existed were already approved in effect, so they start accepted; new ones start pending
            ALTER TABLE follows ADD COLUMN IF NOT EXISTS accepted BOOLEAN NOT NULL DEFAULT true;
            ALTER TABLE follows ALTER COLUMN accepted SET DEFAULT false;
            -- Public profiles don't approve followers, so requests to them (from before profiles could be public)
            -- are accepted
            UPDATE follows SET accepted = true
            WHERE NOT accepted AND followee_id IN (SELECT firebase_uid FROM users WHERE NOT is_private);

            CREATE TABLE IF NOT EXISTS movies (
                id SERIAL PRIMARY KEY,
                tmdb_id VARCHAR(20) UNIQUE,
                title VARCHAR(255) NOT NULL,
                release_date VARCHAR(20),
                overview TEXT,
                poster_path VARCHAR(255),
                original_language VARCHAR(10),
                popularity DOUBLE PRECISION,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS lists (
                id SERIAL PRIMARY KEY,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                name VARCHAR(100) NOT NULL,
                overview TEXT,
                is_ranked BOOLEAN DEFAULT FALSE,
                creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                date_modified TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS list_movies (
                id SERIAL PRIMARY KEY,
                list_id INT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                rank INT,
                UNIQUE (list_id, movie_id)
            );
            -- Who can see a list: everyone signed in (public), the owner's accepted followers (followers, how all
            -- lists worked before), or only the owner (private)
            ALTER TABLE lists ADD COLUMN IF NOT EXISTS visibility VARCHAR(10) NOT NULL DEFAULT 'followers';
            -- Unranked lists (is_ranked false) are collections in no particular order, like a watchlist: their order
            -- says nothing about how much the owner liked a film, so it's never used as a sign of taste
            ALTER TABLE lists ALTER COLUMN is_ranked SET DEFAULT true;
            -- New lists start public; lists made before keep the visibility they have
            ALTER TABLE lists ALTER COLUMN visibility SET DEFAULT 'public';

            -- When a film was added, for friends' activity. Films added before this was kept have none
            ALTER TABLE list_movies ADD COLUMN IF NOT EXISTS added_at TIMESTAMP;
            ALTER TABLE list_movies ALTER COLUMN added_at SET DEFAULT CURRENT_TIMESTAMP;
            -- Placed by Smart Placement (AI) rather than by the user. Cleared when the user approves the
            -- spot or moves the film themselves
            ALTER TABLE list_movies ADD COLUMN IF NOT EXISTS ai_placed BOOLEAN NOT NULL DEFAULT false;
            -- Who added a film, for shared lists. Null for films added before lists could be shared
            ALTER TABLE list_movies ADD COLUMN IF NOT EXISTS added_by VARCHAR(255) REFERENCES users(firebase_uid) ON DELETE SET NULL;

            -- Watched is per user, not per list: a film watched once shows as watched in every list
            CREATE TABLE IF NOT EXISTS watched_movies (
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                watched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, movie_id)
            );

            -- Watches after the first, for the diary. The first watch is the row in watched_movies
            CREATE TABLE IF NOT EXISTS watch_log (
                id SERIAL PRIMARY KEY,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                watched_on DATE NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS watch_log_user ON watch_log (user_id, watched_on);

            -- A user's note on a film, shared across their lists like watched and visible to their followers
            CREATE TABLE IF NOT EXISTS movie_notes (
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                note TEXT NOT NULL,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, movie_id)
            );
        `);

        console.log("Tables created successfully");
    } catch (error) {
        console.error("Error creating tables:", error);
    } finally {
        //await client.release();
    }
};

// Run the script
//createTables();

module.exports = createTables;