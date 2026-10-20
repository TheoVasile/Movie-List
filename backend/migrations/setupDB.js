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

            -- A SHA-256 hash of the user's phone number (its last 10 digits), if they chose to add one so friends
            -- can find them from their contacts. The number itself is never stored
            ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_hash CHAR(64);
            CREATE INDEX IF NOT EXISTS users_phone_hash ON users (phone_hash);

            -- Which push notifications the user wants. The phone also has to allow notifications
            ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_requests BOOLEAN NOT NULL DEFAULT true;
            ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_activity BOOLEAN NOT NULL DEFAULT true;
            -- When the user last got the daily friends digest, so they never get two in a day
            ALTER TABLE users ADD COLUMN IF NOT EXISTS last_digest_at TIMESTAMP;

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

            -- When a film was added, for friends' activity. Films added before this was kept have none
            ALTER TABLE list_movies ADD COLUMN IF NOT EXISTS added_at TIMESTAMP;
            ALTER TABLE list_movies ALTER COLUMN added_at SET DEFAULT CURRENT_TIMESTAMP;
            -- Placed by Smart Placement (Claude) rather than by the user. Cleared when the user approves the
            -- spot or moves the film themselves
            ALTER TABLE list_movies ADD COLUMN IF NOT EXISTS ai_placed BOOLEAN NOT NULL DEFAULT false;

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