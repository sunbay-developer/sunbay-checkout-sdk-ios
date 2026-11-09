// DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.
/**
 * Dev-only session server for the iOS SDK Example app and real-API tests.
 *   POST /api/create-session  -> { sessionId, checkoutClientSecret, customerAccessSecret|null }
 *   GET  /healthz             -> { ok, hasCredentials, warning }
 * Dependency-free; Node 20.6+.  Run: node Example/DevServer/server.mjs
 */

import { createServer } from 'node:http';
import { createSession, HAS_CREDENTIALS, DEV_WARNING } from './session.mjs';

const HOST = process.env.HOST ?? '127.0.0.1';
const PORT = Number(process.env.PORT ?? 8095);

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

function sendJson(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
}

const server = createServer(async (req, res) => {
    try {
        const path = req.url?.split('?')[0];
        if (req.method === 'GET' && path === '/healthz') {
            sendJson(res, 200, { ok: true, hasCredentials: HAS_CREDENTIALS, warning: DEV_WARNING });
            return;
        }
        if (req.method === 'POST' && path === '/api/create-session') {
            if (!HAS_CREDENTIALS) {
                sendJson(res, 503, {
                    error: 'Merchant credentials missing. Copy .env.example to .env.local and fill in API_KEY / APP_ID / MERCHANT_ID.',
                });
                return;
            }
            let input;
            try {
                const raw = await readBody(req);
                input = raw ? JSON.parse(raw) : {};
            } catch {
                sendJson(res, 400, { error: 'request body is not valid JSON' });
                return;
            }
            try {
                sendJson(res, 200, await createSession(input));
            } catch (err) {
                sendJson(res, 502, { error: err.message, code: err.code });
            }
            return;
        }
        sendJson(res, 404, { error: 'not found' });
    } catch (err) {
        sendJson(res, 500, { error: err.message ?? 'internal error' });
    }
});

server.listen(PORT, HOST, () => {
    console.log(`\n\x1b[41m\x1b[97m ${DEV_WARNING} \x1b[0m\n`);
    console.log(`  session: POST http://${HOST}:${PORT}/api/create-session`);
    console.log(`  healthz: GET  http://${HOST}:${PORT}/healthz`);
    console.log(`  credentials: ${HAS_CREDENTIALS ? 'present' : 'MISSING'}\n`);
});
