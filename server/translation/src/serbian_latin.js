// Serbian Cyrillic alphabet -> the app's Serbian Latin presentation.
// Only the response is transformed. Existing Latin text and punctuation are preserved.
const CYRILLIC = [...'абвгдђежзијклљмнњопрстћуфхцчџш'];
const LATIN = ['a', 'b', 'v', 'g', 'd', 'đ', 'e', 'ž', 'z', 'i', 'j', 'k', 'l', 'lj', 'm', 'n', 'nj', 'o', 'p', 'r', 's', 't', 'ć', 'u', 'f', 'h', 'c', 'č', 'dž', 'š'];
const LETTERS = new Map(CYRILLIC.map((letter, index) => [letter, LATIN[index]]));

export function toSerbianLatin(text) {
  // Treat a run of letters/combining marks as a word. Uppercase digraphs are LJ/NJ/DŽ
  // in an all-uppercase word, otherwise Lj/Nj/Dž. Latin letters also supply case
  // context, so mixed-script ЉUBAV and Љubav keep their intended capitalization.
  return text.replace(/[\p{L}\p{M}]+/gu, word => {
    const allUppercase = word === word.toUpperCase();
    return [...word].map(letter => {
      const lower = letter.toLowerCase();
      const latin = LETTERS.get(lower);
      if (latin === undefined) return letter;
      if (letter === lower) return latin;
      if (allUppercase) return latin.toUpperCase();
      return latin[0].toUpperCase() + latin.slice(1);
    }).join('');
  });
}
