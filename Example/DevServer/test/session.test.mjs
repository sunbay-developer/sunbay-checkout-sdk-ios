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

test('configFor reads unprefixed variables for dev and prefixed ones for test and prod', async () => {
    const { configFor, hasCredentialsFor } = await import('../session.mjs');
    const env = {
        API_KEY: 'k', APP_ID: 'a', MERCHANT_ID: 'm',
        TEST_API_KEY: 'tk', TEST_APP_ID: 'ta', TEST_MERCHANT_ID: 'tm', TEST_OPEN_API_URL: 'https://example.test',
    };
    assert.equal(configFor('dev', env).apiKey, 'k');
    assert.equal(configFor('test', env).apiKey, 'tk');
    assert.equal(configFor('test', env).openApiUrl, 'https://example.test');
    assert.equal(configFor('prod', env).openApiUrl, 'https://open.sunbay.us');
    assert.equal(hasCredentialsFor('prod', env), false);
    assert.equal(configFor('bogus', env), null);
});
