// DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.
/**
 * Console logging helpers for the dev server.
 *
 * Rules: the API key and the Authorization header are never logged; client secrets are masked to their
 * prefix plus the last 4 characters (enough to match a log line with what the app received).
 */

/**
 * Masks a secret such as `ccs_…` / `cas_…`.
 *
 * @param {string|null|undefined} value
 * @returns {string|null} `prefix_…last4`, `…` for values too short to mask safely, or null when absent.
 */
export function maskSecret(value) {
    if (value === null || value === undefined) return null;
    const text = String(value);
    if (text.length < 12) return '…';
    const underscore = text.indexOf('_');
    const prefix = underscore > 0 && underscore <= 4 ? text.slice(0, underscore + 1) : '';
    return `${prefix}…${text.slice(-4)}`;
}

/**
 * Business fields of the create-session request worth logging (no appId, no credentials).
 *
 * @param {object} payload the body sent to the open platform
 */
export function summarizeCreateSessionPayload(payload) {
    return {
        transactionRequestId: payload.transactionRequestId,
        merchantId: payload.merchantId,
        sessionType: payload.sessionType,
        customerId: payload.customerId,
        supportStoreCard: payload.supportStoreCard,
        amount: payload.amount,
        collectBillingAddress: payload.collectBillingAddress,
        collectShippingAddress: payload.collectShippingAddress,
    };
}

/**
 * Upstream create-session response worth logging, with both secrets masked.
 *
 * @param {number} httpStatus upstream HTTP status
 * @param {object|null} body parsed upstream body (null when it was not JSON)
 */
export function summarizeCreateSessionResponse(httpStatus, body) {
    const data = body?.data ?? {};
    return {
        httpStatus,
        code: body?.code ?? null,
        msg: body?.msg ?? null,
        traceId: body?.traceId ?? null,
        sessionId: data.sessionId ?? null,
        expiresAt: data.expiresAt ?? null,
        checkoutClientSecret: maskSecret(data.checkoutClientSecret),
        customerAccessSecret: maskSecret(data.customerAccessSecret),
    };
}

/**
 * Writes one timestamped log line: `[ISO time] tag {json}`.
 *
 * @param {string} tag short label, for example `create-session ->`
 * @param {object} [fields] values to print as JSON
 */
export function log(tag, fields) {
    const suffix = fields === undefined ? '' : ` ${JSON.stringify(fields)}`;
    console.log(`[${new Date().toISOString()}] ${tag}${suffix}`);
}
