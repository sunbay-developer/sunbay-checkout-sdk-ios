import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildCreateSessionPayload } from '../session.mjs';

const config = { appId: 'a', merchantId: 'm', currency: 'USD', customerId: 'cust-1' };
const NOW = 1700000000000;

test('builds an sdk session payload with COF enabled', () => {
    const p = buildCreateSessionPayload({ amount: 9.99 }, config, NOW);
    assert.equal(p.sessionType, 'sdk');
    assert.equal(p.customerId, 'cust-1');
    assert.equal(p.supportStoreCard, true);
    assert.equal(p.amount.orderAmount, 999);
    assert.equal(p.amount.taxAmount, Math.round(999 * 0.08));
    assert.equal(p.productList[0].amount, 999);
    assert.equal(p.productList[0].num, 1);
    assert.equal(p.collectBillingAddress, false);
    assert.ok(p.transactionRequestId.startsWith('IOS'));
    assert.ok(p.referenceOrderId.startsWith('IOS'));
});

test('explicit items win over amount', () => {
    const items = [{ name: 'X', amount: 500, num: 2 }];
    const p = buildCreateSessionPayload({ amount: 9.99, items }, config, NOW);
    assert.equal(p.amount.orderAmount, 1000);
    assert.deepEqual(p.productList, items);
});

test('supportStoreCard defaults to true and can be turned off per request', () => {
    const cfg = { appId: 'a', merchantId: 'm', currency: 'USD', customerId: 'c' };
    assert.equal(buildCreateSessionPayload({}, cfg, 1).supportStoreCard, true);
    assert.equal(buildCreateSessionPayload({ supportStoreCard: false }, cfg, 1).supportStoreCard, false);
});
