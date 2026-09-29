import assert from 'node:assert/strict';
import test from 'node:test';
import { LANGUAGES } from '../src/config.js';
import { createGoogleTranslator } from '../src/google_provider.js';

const config = { enabled: true, provider: 'google', projectId: 'demo-clrs-local' };
const active = () => new AbortController().signal;
const reply = (data, options = {}) => new Response(JSON.stringify(data), {
  headers: { 'content-type': 'application/json; charset=utf-8' }, ...options,
});
const translated = (text = 'Hello', source = 'ru') => ({
  translations: [{ translatedText: text, detectedLanguageCode: source }],
});
function harness(fetchImpl = async () => reply(translated())) {
  const requests = [];
  let tokenReads = 0;
  const translate = createGoogleTranslator({
    credential: { async getAccessToken() { tokenReads++; return { access_token: 'fixture-server-token' }; } },
    fetchImpl: async (url, options) => { requests.push({ url, options }); return fetchImpl(url, options); },
  });
  return { translate, requests, tokenReads: () => tokenReads };
}
const args = (targetLanguage = 'en', overrides = {}) => ({
  text: '<private text> & "quoted"', targetLanguage, config, signal: active(), ...overrides,
});
const unavailable = error => error.status === 503 && error.code === 'translation_unavailable';

for (const language of LANGUAGES) test(`Google NMT maps CLRS ${language} without changing source text`, async () => {
  const h = harness();
  const signal = active();
  const value = await h.translate(args(language, { signal }));
  assert.deepEqual(value, { translatedText: 'Hello', detectedSourceLanguage: 'ru', googlePowered: true });
  assert.equal(h.tokenReads(), 1);
  assert.equal(h.requests.length, 1);
  const { url, options } = h.requests[0];
  assert.equal(url, 'https://translate.googleapis.com/v3/projects/demo-clrs-local/locations/global:translateText');
  assert.equal(options.method, 'POST');
  assert.equal(options.redirect, 'error');
  assert.equal(options.signal, signal);
  assert.deepEqual(options.headers, {
    'Content-Type': 'application/json', Authorization: 'Bearer fixture-server-token',
    'x-goog-user-project': 'demo-clrs-local',
  });
  assert.deepEqual(JSON.parse(options.body), {
    contents: ['<private text> & "quoted"'], mimeType: 'text/plain',
    targetLanguageCode: language === 'nb' ? 'no' : language,
    model: 'projects/demo-clrs-local/locations/global/models/general/nmt',
  });
});

test('Serbian Cyrillic provider output is displayed in the accepted Latin script', async () => {
  const h = harness(async () => reply(translated('Љубав, породица и вера. ЉУБАВ!', 'ru')));
  assert.equal((await h.translate(args('sr'))).translatedText, 'Ljubav, porodica i vera. LJUBAV!');
});
test('Serbian source and Norwegian source codes are retained canonically', async () => {
  for (const [source, expected] of [['sr', 'sr'], ['sr-Latn', 'sr-Latn'], ['no', 'nb']]) {
    const h = harness(async () => reply(translated('Перевод', source)));
    assert.equal((await h.translate(args('ru'))).detectedSourceLanguage, expected);
  }
});
test('disabled, wrong provider, invalid project and unknown target never obtain a token', async () => {
  for (const overrides of [
    { config: { ...config, enabled: false } },
    { config: { ...config, provider: 'amazon' } },
    { config: { ...config, projectId: '../other' } },
    { targetLanguage: 'unknown' },
  ]) {
    const h = harness();
    await assert.rejects(h.translate(args('en', overrides)), unavailable);
    assert.equal(h.tokenReads(), 0);
    assert.equal(h.requests.length, 0);
  }
});
test('ADC failure and malformed credentials are sanitized before sending', async () => {
  for (const access of [{}, { access_token: 'private\r\ninvalid' }, { access_token: 'x'.repeat(8193) }, null]) {
    let requests = 0;
    const translate = createGoogleTranslator({
      credential: { async getAccessToken() { if (!access) throw Error('private token detail'); return access; } },
      fetchImpl: async () => { requests++; return reply(translated()); },
    });
    await assert.rejects(translate(args()), unavailable);
    assert.equal(requests, 0);
  }
});

test('RFC6750 Bearer format allows tilde, plus, slash and trailing padding from ADC', async () => {
  for (const token of ['fixture-Az09._~+/token==', 'x'.repeat(8192)]) {
    let requests = 0;
    const translate = createGoogleTranslator({
      credential: { async getAccessToken() { return { access_token: token }; } },
      fetchImpl: async (_, options) => {
        requests++;
        assert.equal(options.headers.Authorization, `Bearer ${token}`);
        return reply(translated());
      },
    });
    assert.equal((await translate(args())).translatedText, 'Hello');
    assert.equal(requests, 1);
  }
});

test('ADC rejects whitespace, CRLF, excess length and invalid padding before HTTP', async () => {
  for (const token of ['fixture\r\n', 'fixture\n', 'fixture\r', 'fixture token',
    'fixture\ttoken', 'fixture=paddingAfter', '==', 'x'.repeat(8193)]) {
    let requests = 0;
    const translate = createGoogleTranslator({
      credential: { async getAccessToken() { return { access_token: token }; } },
      fetchImpl: async () => { requests++; return reply(translated()); },
    });
    await assert.rejects(translate(args()), unavailable);
    assert.equal(requests, 0);
  }
});
test('abort while ADC is pending prevents any later paid request', async () => {
  const controller = new AbortController();
  let release;
  let requests = 0;
  const translate = createGoogleTranslator({
    credential: { getAccessToken: () => new Promise(resolve => { release = resolve; }) },
    fetchImpl: async () => { requests++; return reply(translated()); },
  });
  const pending = translate(args('en', { signal: controller.signal }));
  controller.abort();
  release({ access_token: 'fixture-server-token' });
  await assert.rejects(pending, unavailable);
  assert.equal(requests, 0);
});
test('network failure and non-200 provider results produce one sanitized failure, no retry', async () => {
  for (const fetchImpl of [
    async () => { throw Error('private source, credential'); },
    ...[400, 401, 403, 429, 500].map(status => async () => reply({ error: 'private diagnostic' }, { status })),
  ]) {
    const h = harness(fetchImpl);
    await assert.rejects(h.translate(args()), unavailable);
    assert.equal(h.requests.length, 1);
  }
});
test('abort reaches fetch and no provider result is accepted after cancellation', async () => {
  const controller = new AbortController();
  const h = harness(async (_, options) => {
    assert.equal(options.signal, controller.signal);
    controller.abort();
    return reply(translated());
  });
  await assert.rejects(h.translate(args('en', { signal: controller.signal })), unavailable);
  assert.equal(h.requests.length, 1);
});
test('missing, extra, malformed, oversized or invalid UTF-8 results are rejected', async () => {
  const invalid = [
    reply({}), reply({ translations: [] }),
    reply({ translations: [...translated().translations, ...translated().translations] }),
    reply(translated('', 'ru')), reply(translated('text', '')), reply(translated('text', '../ru')),
    reply(translated('\ud800', 'ru')), reply(translated('x'.repeat(256 * 1024 + 1))),
    new Response('{invalid', { headers: { 'content-type': 'application/json' } }),
    new Response(Buffer.from([0xff]), { headers: { 'content-type': 'application/json' } }),
    new Response('private text', { headers: { 'content-type': 'text/plain' } }),
    new Response('{}', { headers: { 'content-type': 'application/json', 'content-length': '524289' } }),
    new Response('x'.repeat(512 * 1024 + 1), { headers: { 'content-type': 'application/json' } }),
  ];
  for (const response of invalid) {
    const h = harness(async () => response);
    await assert.rejects(h.translate(args()), unavailable);
    assert.equal(h.requests.length, 1);
  }
});
