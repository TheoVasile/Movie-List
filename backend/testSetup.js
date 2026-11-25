// Loaded before every test file by `npm test`. backend/.env points at the real database, so tests must never see
// its values: dotenv doesn't overwrite variables that are already set
const net = require("node:net");

process.env.DATABASE_URL = "postgres://127.0.0.1:1/none";
process.env.API_KEY = "test";
process.env.ANTHROPIC_API_KEY = "test";

// Anything a test forgets to stand in for fails here instead of reaching a real service. Tests may still talk to
// the servers they start on this machine
const LOCAL = new Set(["localhost", "127.0.0.1", "::1"]);
const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
    const options = Array.isArray(args[0]) ? args[0][0] : args[0];
    const host = typeof options === "object" ? options.host : typeof args[1] === "string" ? args[1] : undefined;
    if (host && !LOCAL.has(host)) {
        throw new Error(`Tests can't connect to ${host}`);
    }
    return connect.apply(this, args);
};
