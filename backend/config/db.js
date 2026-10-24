const { Pool, types } = require("pg");
require("dotenv").config();

// TIMESTAMP columns have no timezone and the database runs in UTC, but pg would read them as this
// machine's local time, shifting every date by the local UTC offset. Read them as UTC instead
const TIMESTAMP_WITHOUT_TIME_ZONE = 1114;
types.setTypeParser(TIMESTAMP_WITHOUT_TIME_ZONE, (value) => new Date(value.replace(" ", "T") + "Z"));

// DATABASE_URL should be Supabase's pooled connection string in transaction mode (port 6543 on
// *.pooler.supabase.com), which shares a few real database connections between many clients, so more servers can
// run without hitting Postgres's connection limit. Transaction mode hands each transaction to whichever connection
// is free, so nothing here may rely on session state: no LISTEN/NOTIFY, session SET, advisory locks, temp tables
// or named prepared statements. pool.query and BEGIN...COMMIT on one pool.connect() client are fine.
// Port 5432 on the same host is session mode, which holds a real connection per client for as long as it's open
//
// Connections this server keeps open. Every instance gets this many, so instances x DB_POOL_MAX has to stay
// under the pooler's client limit
const POOL_MAX = Number(process.env.DB_POOL_MAX) || 10;

function getPool() {
    let pool;
    if (!pool) {
        pool = new Pool({
            connectionString: process.env.DATABASE_URL,
            ssl: {
                rejectUnauthorized: false // Enable if your RDS requires SSL
            },
            max: POOL_MAX, // Maximum number of clients in the pool
            idleTimeoutMillis: 30000, // How long a client is allowed to remain idle before being closed
            // Supabase can take a few seconds to open a new connection, especially from a host like Render
            connectionTimeoutMillis: 10000,
        });

        // Add error handling
        pool.on('error', (err, client) => {
            console.error('Unexpected error on idle client', err);
        });

        console.log("New database connection pool created");
    }
    return pool;
}

const pool = getPool();

module.exports = pool;