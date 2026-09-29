import test from 'node:test';
import assert from 'node:assert/strict';
import { toSerbianLatin } from '../src/serbian_latin.js';
import { createAmazonTranslator } from '../src/provider.js';
import { readConfig } from '../src/config.js';

const cyrillic = 'а б в г д ђ е ж з и ј к л љ м н њ о п р с т ћ у ф х ц ч џ ш';
const latin = 'a b v g d đ e ž z i j k l lj m n nj o p r s t ć u f h c č dž š';
test('all 30 Serbian letters, lowercase', () => assert.equal(toSerbianLatin(cyrillic), latin));
test('all 30 Serbian letters, uppercase including LJ NJ DŽ', () => assert.equal(toSerbianLatin(cyrillic.toUpperCase()), latin.toUpperCase()));
test('Lj/Nj/Dž title case and all-caps words differ correctly', () => {
  assert.equal(toSerbianLatin('Љубав Његош Џез / ЉУБАВ ЊЕГОШ ЏЕЗ / љубав његош џез'), 'Ljubav Njegoš Džez / LJUBAV NJEGOŠ DŽEZ / ljubav njegoš džez');
  assert.equal(toSerbianLatin('ПОЉЕ КОЊИ ОЏАЦИ / Поље Коњи Оџаци'), 'POLJE KONJI ODŽACI / Polje Konji Odžaci');
});
test('Latin context, punctuation, whitespace and emoji are preserved', () => {
  assert.equal(toSerbianLatin('„Љubav“, ЊEGOŠ — Džez/Lj/NJ!\nЧај & čaj: 25 € 😀'), '„Ljubav“, NJEGOŠ — Džez/Lj/NJ!\nČaj & čaj: 25 € 😀');
  const alreadyLatin = 'Ljiljana, NJEGOŠ, DŽEZ; ČĆĐŠŽ čćđšž. https://example.invalid/a?x=1 😀';
  assert.equal(toSerbianLatin(alreadyLatin), alreadyLatin);
});
test('combining marks stay intact and repeated presentation is idempotent', () => {
  const input = 'Љу\u0301бав — чај';
  const output = 'Lju\u0301bav — čaj';
  assert.equal(toSerbianLatin(input), output);
  assert.equal(toSerbianLatin(output), output);
  assert.equal(toSerbianLatin(''), '');
});

async function translateFixture({ input = 'original', target = 'sr', output = 'Љубав ЊЕГОШ Џез', detected = 'en' } = {}) {
  const calls = [];
  const translator = createAmazonTranslator({
    clientForRegion: region => ({ async send(command) {
      calls.push({ region, body: command.input });
      return { TranslatedText: output, SourceLanguageCode: detected, TargetLanguageCode: command.input.TargetLanguageCode };
    } }),
  });
  const result = await translator({ text: input, targetLanguage: target, config: readConfig({ GCLOUD_PROJECT: 'demo-clrs-local', TRANSLATION_ENABLED: 'true', AWS_REGION: 'eu-central-1' }), signal: new AbortController().signal });
  return { calls, result };
}

test('provider request remains sr and original input unchanged; result becomes Latin', async () => {
  const input = 'Private исходный текст';
  const { calls, result } = await translateFixture({ input });
  assert.deepEqual(calls[0].body, { Text: input, SourceLanguageCode: 'auto', TargetLanguageCode: 'sr' });
  assert.deepEqual(result, { translatedText: 'Ljubav NJEGOŠ Džez', detectedSourceLanguage: 'en' });
});
test('source==sr target==sr still transliterates Cyrillic returned unchanged by provider', async () => {
  const input = 'Љубав и пријатељство';
  const { calls, result } = await translateFixture({ input, output: input, detected: 'sr' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.Text, input);
  assert.deepEqual(result, { translatedText: 'Ljubav i prijateljstvo', detectedSourceLanguage: 'sr' });
});
test('source==sr target==sr with existing Latin text remains unchanged', async () => {
  const input = 'Ljubav i prijateljstvo';
  const { result } = await translateFixture({ input, output: input, detected: 'sr' });
  assert.deepEqual(result, { translatedText: input, detectedSourceLanguage: 'sr' });
});
test('a non-Serbian target never gets Serbian transliteration', async () => {
  const { result } = await translateFixture({ target: 'ru', output: 'Љ Њ Џ Привет', detected: 'sr' });
  assert.deepEqual(result, { translatedText: 'Љ Њ Џ Привет', detectedSourceLanguage: 'sr' });
});
