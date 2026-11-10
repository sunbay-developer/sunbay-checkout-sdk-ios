// DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.
/**
 * Dev-only checkout-session helper for the iOS SDK Example and real-API tests.
 *
 * Creates a checkout session via the open platform using the merchant key held
 * on this machine and returns { sessionId, checkoutClientSecret,
 * customerAccessSecret }. Dependency-free; Node 20.6+.
 *
 * Credentials are loaded from Example/DevServer/.env.local (git-ignored).
 */

import { log, summarizeCreateSessionPayload, summarizeCreateSessionResponse } from './log.mjs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

try {
    process.loadEnvFile(join(__dirname, '.env.local'));
} catch {
    // No .env.local: createSession() reports missing credentials.
}

export const DEV_WARNING =
    'DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.';

/** Default order amount in MAJOR units (e.g. dollars). */
export const DEFAULT_AMOUNT = 0.01;

/**
 * Per-environment settings. `dev` reads the unprefixed variables (API_KEY, APP_ID, MERCHANT_ID,
 * OPEN_API_URL); `test` reads TEST_*; `prod` reads PROD_*. The open-platform hosts below are defaults and
 * can be overridden with `<PREFIX>OPEN_API_URL`.
 */
const ENVIRONMENTS = {
    dev: { prefix: '', openApiUrl: 'https://open.sunbay-dev.com' },
    test: { prefix: 'TEST_', openApiUrl: 'https://open.sunbay-uat.us' },
    prod: { prefix: 'PROD_', openApiUrl: 'https://open.sunbay.us' },
};

export const ENVIRONMENT_NAMES = Object.keys(ENVIRONMENTS);

/** Resolve the upstream configuration of one environment (unknown names fall back to nothing). */
export function configFor(name = 'dev', env = process.env) {
    const spec = ENVIRONMENTS[name];
    if (!spec) return null;
    const get = (key) => env[`${spec.prefix}${key}`];
    return {
        environment: name,
        openApiUrl: get('OPEN_API_URL') ?? spec.openApiUrl,
        apiKey: get('API_KEY'),
        appId: get('APP_ID'),
        merchantId: get('MERCHANT_ID'),
        currency: env.CURRENCY ?? 'USD',
        customerId: env.CUSTOMER_ID ?? 'sunbay-ios-dev-customer',
    };
}

/** True when the environment has an API key, app id and merchant id. */
export function hasCredentialsFor(name, env = process.env) {
    const c = configFor(name, env);
    return Boolean(c && c.apiKey && c.appId && c.merchantId);
}

/** The dev environment (kept for the real-API tests and existing callers). */
export const CONFIG = configFor('dev');

export const HAS_CREDENTIALS = hasCredentialsFor('dev');

/** Convert a MAJOR-unit amount to minor units: 0.01 -> 1. */
function toMinorUnits(major) {
    return Math.round(Number(major) * 100);
}

/**
 * Pure payload builder.
 * @param {object} input  { amount?, items?, description?, returnUrl?, currency?, collectBillingAddress?, collectShippingAddress? }
 * @param {object} config { appId, merchantId, currency, customerId }
 * @param {number} now    epoch millis, used for request/order ids
 */
export function buildCreateSessionPayload(input, config, now) {
    const items =
        Array.isArray(input.items) && input.items.length > 0
            ? input.items
            : [
                  {
                      name: 'SDK iOS Item',
                      amount: toMinorUnits(input.amount ?? DEFAULT_AMOUNT),
                      num: 1,
                  },
              ];
    const orderAmount = items.reduce((sum, i) => sum + Number(i.amount) * Number(i.num), 0);
    const taxAmount = Math.round(orderAmount * 0.08);
    const id = `IOS${now}`;

    return {
        appId: config.appId,
        transactionRequestId: id,
        referenceOrderId: id,
        merchantId: config.merchantId,
        customerId: config.customerId,
        amount: {
            orderAmount,
            taxAmount,
            priceCurrency: input.currency ?? config.currency,
        },
        description: input.description ?? 'SDK iOS dev order',
        productList: items,
        collectBillingAddress: input.collectBillingAddress ?? false,
        collectShippingAddress: input.collectShippingAddress ?? false,
        merchantReturnUrl: input.returnUrl ?? '',
        notifyUrl: input.returnUrl ?? '',
        supportStoreCard: true,
        sessionType: 'sdk',
    };
}

/**
 * Create a checkout session upstream.
 * @returns {Promise<{sessionId:string, checkoutClientSecret:string|null, customerAccessSecret:string|null}>}
 */
export async function createSession(input = {}) {
    const environment = input.environment ?? 'dev';
    const config = configFor(environment);
    if (!config) {
        throw new Error(`Unknown environment "${environment}". Use one of: ${ENVIRONMENT_NAMES.join(', ')}.`);
    }
    if (!hasCredentialsFor(environment)) {
        const prefix = ENVIRONMENTS[environment].prefix;
        throw new Error(
            `Merchant credentials missing for "${environment}". Fill in ${prefix}API_KEY / ${prefix}APP_ID / ${prefix}MERCHANT_ID in .env.local.`
        );
    }
    const now = Date.now();
    const payload = buildCreateSessionPayload(input, config, now);
    const url = `${config.openApiUrl}/v1/checkout/create-session`;
    log('create-session -> upstream', { environment, url, ...summarizeCreateSessionPayload(payload) });
    const started = Date.now();

    const res = await fetch(url, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${config.apiKey}`,
            'X-Client-Request-Id': payload.transactionRequestId,
            'X-Timestamp': String(now),
        },
        body: JSON.stringify(payload),
    });

    let data = null;
    try {
        data = await res.json();
    } catch {
        // Non-JSON upstream body (for example a gateway HTML page); reported below.
    }
    log('create-session <- upstream', {
        ms: Date.now() - started,
        ...summarizeCreateSessionResponse(res.status, data),
    });
    if (!data) {
        const err = new Error(`upstream create-session returned a non-JSON body (HTTP ${res.status})`);
        err.code = `HTTP_${res.status}`;
        throw err;
    }
    if (data.code !== '0' || !data.data?.sessionId) {
        const err = new Error(data.msg || `upstream create-session failed (code=${data.code})`);
        err.code = data.code;
        throw err;
    }
    return {
        sessionId: data.data.sessionId,
        checkoutClientSecret: data.data.checkoutClientSecret ?? null,
        customerAccessSecret: data.data.customerAccessSecret ?? null,
    };
}
