// DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.
/**
 * Dev-only session server for the iOS SDK Example app and real-API tests.
 *   POST /api/create-session  -> { sessionId, checkoutClientSecret, customerAccessSecret|null }
 *   GET  /healthz             -> { ok, hasCredentials, warning }
 * Dependency-free; Node 20.6+.  Run: node Example/DevServer/server.mjs
 */

import { createServer } from 'node:http';
import { createSession, HAS_CREDENTIALS, DEV_WARNING } from './session.mjs';
import { log } from './log.mjs';

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

/** Business fields of an incoming create-session request worth logging. */
function summarizeInput(input) {
    return {
        amount: input.amount,
        currency: input.currency,
        items: Array.isArray(input.items) ? input.items.length : undefined,
        collectBillingAddress: input.collectBillingAddress,
        collectShippingAddress: input.collectShippingAddress,
        supportStoreCard: input.supportStoreCard,
    };
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
    const started = Date.now();
    res.on('finish', () => {
        log(`${req.method} ${req.url?.split('?')[0]} -> ${res.statusCode}`, {
            ms: Date.now() - started,
            from: req.socket.remoteAddress,
        });
    });
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
            log('create-session request', summarizeInput(input));
            try {
                sendJson(res, 200, await createSession(input));
            } catch (err) {
                log('create-session FAILED', { code: err.code ?? null, error: err.message });
                sendJson(res, 502, { error: err.message, code: err.code });
            }
            return;
        }
        sendJson(res, 404, { error: 'not found' });
    } catch (err) {
        log('internal error', { error: err.message ?? String(err) });
        sendJson(res, 500, { error: err.message ?? 'internal error' });
    }
});

server.listen(PORT, HOST, () => {
    console.log(`\n\x1b[41m\x1b[97m ${DEV_WARNING} \x1b[0m\n`);
    console.log(`  session: POST http://${HOST}:${PORT}/api/create-session`);
    console.log(`  healthz: GET  http://${HOST}:${PORT}/healthz`);
    console.log(`  credentials: ${HAS_CREDENTIALS ? 'present' : 'MISSING'}\n`);
});
