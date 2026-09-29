import { TranslateClient, TranslateTextCommand } from '@aws-sdk/client-translate';
import { PublicError, assertActive } from './config.js';
import { toSerbianLatin } from './serbian_latin.js';

const MAX_RESULT_BYTES = 256 * 1024;

// The AWS default credential provider chain runs only on the server. No AWS
// credential or caller-selectable endpoint is accepted in the HTTP request.
export function createAmazonTranslator({
  clientForRegion = region => new TranslateClient({ region, maxAttempts: 1 }),
  CommandType = TranslateTextCommand,
} = {}) {
  const clients = new Map();
  return async ({ text, targetLanguage, config, signal }) => {
    assertActive(signal);
    const target = targetLanguage === 'nb' ? 'no' : targetLanguage;
    try {
      let client = clients.get(config.awsRegion);
      if (!client) {
        client = clientForRegion(config.awsRegion);
        clients.set(config.awsRegion, client);
      }
      const result = await client.send(new CommandType({
        Text: text,
        SourceLanguageCode: 'auto',
        TargetLanguageCode: target,
      }), { abortSignal: signal });
      assertActive(signal);
      const source = result?.SourceLanguageCode;
      const translated = result?.TranslatedText;
      if (result?.TargetLanguageCode !== target ||
          typeof source !== 'string' || !/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(source) ||
          typeof translated !== 'string' || !translated.trim() ||
          !translated.isWellFormed() || Buffer.byteLength(translated, 'utf8') > MAX_RESULT_BYTES) {
        throw new PublicError(503, 'translation_unavailable');
      }
      return {
        translatedText: targetLanguage === 'sr' ? toSerbianLatin(translated) : translated,
        detectedSourceLanguage: source === 'no' ? 'nb' : source,
      };
    } catch {
      // SDK exceptions can include private text, request metadata or credentials.
      throw new PublicError(503, 'translation_unavailable');
    }
  };
}
