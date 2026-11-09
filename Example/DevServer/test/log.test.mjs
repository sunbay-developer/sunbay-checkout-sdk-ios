import { test } from 'node:test';
import assert from 'node:assert/strict';
import { maskSecret, summarizeCreateSessionPayload, summarizeCreateSessionResponse } from '../log.mjs';

test('maskSecret keeps the prefix and the last 4 characters only', () => {
    assert.equal(maskSecret('ccs_0123456789abcdef'), 'ccs_…cdef');
    assert.equal(maskSecret('cas_0123456789abcdef'), 'cas_…cdef');
    assert.equal(maskSecret('short'), '…');
    assert.equal(maskSecret(null), null);
    assert.equal(maskSecret(undefined), null);
});

test('payload summary carries business fields and no credentials', () => {
    const summary = summarizeCreateSessionPayload({
        appId: 'app', merchantId: 'm', transactionRequestId: 'IOS1', referenceOrderId: 'IOS1',
        amount: { orderAmount: 105, taxAmount: 8, priceCurrency: 'USD' },
        sessionType: 'sdk', customerId: 'cust-1', supportStoreCard: true,
        collectBillingAddress: false, collectShippingAddress: false,
    });
    assert.deepEqual(summary, {
        transactionRequestId: 'IOS1', merchantId: 'm', sessionType: 'sdk', customerId: 'cust-1',
        supportStoreCard: true, amount: { orderAmount: 105, taxAmount: 8, priceCurrency: 'USD' },
        collectBillingAddress: false, collectShippingAddress: false,
    });
    assert.ok(!JSON.stringify(summary).includes('app"'), 'appId is not needed in logs');
});

test('response summary masks both secrets', () => {
    const summary = summarizeCreateSessionResponse(200, {
        code: '0', msg: 'Success', traceId: 't1',
        data: { sessionId: 'cs_1', expiresAt: '2026-11-09 09:09:32',
            checkoutClientSecret: 'ccs_0123456789abcdef', customerAccessSecret: 'cas_0123456789abcdef' },
    });
    assert.deepEqual(summary, {
        httpStatus: 200, code: '0', msg: 'Success', traceId: 't1', sessionId: 'cs_1',
        expiresAt: '2026-11-09 09:09:32', checkoutClientSecret: 'ccs_…cdef', customerAccessSecret: 'cas_…cdef',
    });
    const text = JSON.stringify(summary);
    assert.ok(!text.includes('0123456789'));
});
