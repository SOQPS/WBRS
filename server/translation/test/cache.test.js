import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createTranslationCache, CACHE_COLLECTION } from '../src/cache.js';
import { readConfig } from '../src/config.js';

const config = readConfig({
  GCLOUD_PROJECT: 'demo-clrs-local', TRANSLATION_ENABLED: 'true',
  AWS_REGION: 'eu-central-1',
  TRANSLATION_CACHE_HMAC_KEY: Buffer.alloc(32, 9).toString('base64'),
});

class AtomicFirestore {
  constructor() { this.docs = new Map(); this.queue = Promise.resolve(); }
  collection(name) { return { doc: id => ({ path: `${name}/${id}` }) }; }
  async runTransaction(fn) {
    const prior = this.queue;
    let release;
    this.queue = new Promise(resolve => { release = resolve; });
    await prior;
    const writes = new Map();
    try {
      const result = await fn({
        get: async ref => ({ data: () => structuredClone(this.docs.get(ref.path)) }),
        set: (ref, data) => writes.set(ref.path, structuredClone(data)),
        delete: ref => writes.set(ref.path, undefined),
      });
      for (const [path, data] of writes) {
        if (data === undefined) this.docs.delete(path);
        else this.docs.set(path, data);
      }
      return result;
    } finally { release(); }
  }
}

function args(uid = 'u1', text = 'Привет', targetLanguage = 'en') {
  return { uid, text, targetLanguage, config, signal: new AbortController().signal };
}

test('repeat is served from account-separated cache keyed by detected source', async () => {
  const db = new AtomicFirestore();
  const cache = createTranslationCache({ db });
  let calls = 0;
  const translate = async () => { calls++; return { translatedText: 'Hello', detectedSourceLanguage: 'ru' }; };
  const first = await cache.getOrTranslate({ ...args(), translate });
  const second = await cache.getOrTranslate({ ...args(), translate });
  assert.deepEqual(first, second);
  assert.equal(calls, 1);
  assert.equal([...db.docs.keys()].filter(path => path.startsWith(CACHE_COLLECTION)).length, 2);
  assert.ok([...db.docs.keys()].every(path => !path.includes('Привет') && !path.includes('u1')));
  await cache.getOrTranslate({ ...args('u2'), translate });
  assert.equal(calls, 2);
  assert.equal(db.docs.size, 4);
});

test('parallel identical calls share one paid provider request across workers', async () => {
  const db = new AtomicFirestore();
  const left = createTranslationCache({ db, waitMs: 2 });
  const right = createTranslationCache({ db, waitMs: 2 });
  let calls = 0;
  let release;
  const translate = () => {
    calls++;
    return new Promise(resolve => { release = () => resolve({ translatedText: 'Hello', detectedSourceLanguage: 'ru' }); });
  };
  const pending = [left, right, left, right].map(cache => cache.getOrTranslate({ ...args(), translate }));
  for (let i = 0; i < 50 && !release; i++) await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal(calls, 1);
  release();
  const results = await Promise.all(pending);
  assert.ok(results.every(result => result.translatedText === 'Hello'));
  assert.equal(calls, 1);
});

test('provider failure removes claim; subsequent retry succeeds', async () => {
  const db = new AtomicFirestore();
  const cache = createTranslationCache({ db });
  await assert.rejects(cache.getOrTranslate({ ...args(), translate: async () => { throw new Error('private AWS detail'); } }), error => error.status === 503 && error.code === 'translation_unavailable');
  assert.equal(db.docs.size, 0);
  const result = await cache.getOrTranslate({ ...args(), translate: async () => ({ translatedText: 'Hello', detectedSourceLanguage: 'ru' }) });
  assert.equal(result.translatedText, 'Hello');
});

test('expired lease can be taken over, old worker cannot publish late result', async () => {
  const db = new AtomicFirestore();
  let clock = 1000000;
  const cache = createTranslationCache({ db, now: () => clock, waitMs: 2 });
  let releaseOld;
  const old = cache.getOrTranslate({ ...args(), translate: () => new Promise(resolve => { releaseOld = resolve; }) });
  for (let i = 0; i < 50 && !releaseOld; i++) await new Promise(resolve => setTimeout(resolve, 1));
  clock += 26000;
  const fresh = await cache.getOrTranslate({ ...args(), translate: async () => ({ translatedText: 'New', detectedSourceLanguage: 'ru' }) });
  releaseOld({ translatedText: 'Old', detectedSourceLanguage: 'ru' });
  await assert.rejects(old, error => error.status === 503);
  assert.equal(fresh.translatedText, 'New');
  assert.equal((await cache.getOrTranslate({ ...args(), translate: () => { throw Error('must not call'); } })).translatedText, 'New');
});

test('aborted operation releases lease and malformed cache never returns translation', async () => {
  const db = new AtomicFirestore();
  const cache = createTranslationCache({ db });
  const controller = new AbortController();
  let started;
  const pending = cache.getOrTranslate({
    ...args(), signal: controller.signal,
    translate: ({ signal }) => new Promise((_, reject) => {
      started = true;
      signal.addEventListener('abort', () => reject(Error('aborted')), { once: true });
    }),
  });
  for (let i = 0; i < 50 && !started; i++) await new Promise(resolve => setTimeout(resolve, 1));
  controller.abort();
  await assert.rejects(pending, error => error.status === 503);
  assert.equal(db.docs.size, 0);
  await cache.getOrTranslate({ ...args(), translate: async () => ({ translatedText: 'Hello', detectedSourceLanguage: 'ru' }) });
  const canonical = [...db.docs.keys()].find(path => path.includes('/r_'));
  db.docs.get(canonical).expiresAt = undefined;
  await assert.rejects(cache.getOrTranslate({ ...args(), translate: () => { throw Error('must not call'); } }), error => error.status === 503);
});

test('Google and Amazon cache namespaces are isolated, attribution survives a Google hit', async () => {
  const db = new AtomicFirestore();
  const amazon = createTranslationCache({ db });
  const google = createTranslationCache({ db, namespace: 'google-cloud-nmt-v1' });
  let googleCalls = 0;
  const googleTranslate = async () => {
    googleCalls++;
    return { translatedText: 'Zdravo', detectedSourceLanguage: 'ru', googlePowered: true };
  };
  await amazon.getOrTranslate({ ...args('u1', 'Привет', 'sr'),
    translate: async () => ({ translatedText: 'Amazon answer', detectedSourceLanguage: 'ru' }) });
  const first = await google.getOrTranslate({ ...args('u1', 'Привет', 'sr'), translate: googleTranslate });
  const hit = await google.getOrTranslate({ ...args('u1', 'Привет', 'sr'), translate: googleTranslate });
  assert.deepEqual(first, hit);
  assert.deepEqual(hit, { translatedText: 'Zdravo', detectedSourceLanguage: 'ru', googlePowered: true });
  assert.equal(googleCalls, 1);
  assert.equal(db.docs.size, 4);
  const amazonHit = await amazon.getOrTranslate({ ...args('u1', 'Привет', 'sr'),
    translate: () => { throw Error('must not call'); } });
  assert.deepEqual(amazonHit, { translatedText: 'Amazon answer', detectedSourceLanguage: 'ru' });
});

test('parallel Google fallbacks across workers make one call and all retain attribution', async () => {
  const db = new AtomicFirestore();
  const caches = [createTranslationCache({ db, namespace: 'google-cloud-nmt-v1', waitMs: 2 }),
    createTranslationCache({ db, namespace: 'google-cloud-nmt-v1', waitMs: 2 })];
  let calls = 0;
  let release;
  const translate = () => {
    calls++;
    return new Promise(resolve => { release = () => resolve({
      translatedText: 'Zdravo', detectedSourceLanguage: 'ru', googlePowered: true,
    }); });
  };
  const pending = caches.map(cache => cache.getOrTranslate({ ...args('u1', 'Привет', 'sr'), translate }));
  for (let i = 0; i < 50 && !release; i++) await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal(calls, 1);
  release();
  assert.ok((await Promise.all(pending)).every(result => result.googlePowered && result.translatedText === 'Zdravo'));
  assert.equal(calls, 1);
});

test('missing or corrupt Google attribution never silently returns an unattributed result', async () => {
  const db = new AtomicFirestore();
  const cache = createTranslationCache({ db, namespace: 'google-cloud-nmt-v1' });
  await assert.rejects(cache.getOrTranslate({ ...args(),
    translate: async () => ({ translatedText: 'Hello', detectedSourceLanguage: 'ru' }) }), error => error.status === 503);
  assert.equal(db.docs.size, 0);
  await cache.getOrTranslate({ ...args(), translate: async () => ({
    translatedText: 'Hello', detectedSourceLanguage: 'ru', googlePowered: true,
  }) });
  const canonical = [...db.docs.values()].find(record => record.translatedText === 'Hello');
  canonical.googlePowered = false;
  await assert.rejects(cache.getOrTranslate({ ...args(), translate: () => { throw Error('must not call'); } }),
    error => error.status === 503);
});
