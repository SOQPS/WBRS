#!/usr/bin/env python3
"""Explicit display-only translation controls in all supported UI languages."""
import json
from pathlib import Path

KEYS = 'Перевести|Показать перевод|Показать оригинал|Перевод…|Не удалось перевести. Попробуйте ещё раз.|Переводчик ещё не подключён.|Слишком длинный текст для перевода.|Перевод временно недоступен. Попробуйте позже.|Текст уже на выбранном языке.|Сеанс изменился. Откройте текст заново.'.split('|')
ROWS = {
    'en': 'Translate|Show translation|Show original|Translating…|Could not translate. Please try again.|The translator is not connected yet.|This text is too long to translate.|Translation is temporarily unavailable. Please try again later.|The text is already in the selected language.|Your session has changed. Open the text again.',
    'de': 'Übersetzen|Übersetzung anzeigen|Original anzeigen|Wird übersetzt…|Übersetzung fehlgeschlagen. Bitte erneut versuchen.|Der Übersetzungsdienst ist noch nicht verbunden.|Dieser Text ist zu lang zum Übersetzen.|Übersetzung vorübergehend nicht verfügbar. Bitte später erneut versuchen.|Der Text ist bereits in der ausgewählten Sprache.|Ihre Sitzung hat sich geändert. Öffnen Sie den Text erneut.',
    'es': 'Traducir|Mostrar traducción|Mostrar original|Traduciendo…|No se pudo traducir. Inténtalo de nuevo.|El traductor aún no está conectado.|El texto es demasiado largo para traducirlo.|La traducción no está disponible temporalmente. Inténtalo más tarde.|El texto ya está en el idioma seleccionado.|Tu sesión ha cambiado. Abre el texto de nuevo.',
    'fr': 'Traduire|Afficher la traduction|Afficher l’original|Traduction en cours…|La traduction a échoué. Veuillez réessayer.|Le traducteur n’est pas encore connecté.|Ce texte est trop long pour être traduit.|La traduction est temporairement indisponible. Veuillez réessayer plus tard.|Le texte est déjà dans la langue sélectionnée.|Votre session a changé. Ouvrez à nouveau le texte.',
    'it': 'Traduci|Mostra traduzione|Mostra originale|Traduzione in corso…|Impossibile tradurre. Riprova.|Il traduttore non è ancora collegato.|Il testo è troppo lungo da tradurre.|La traduzione è temporaneamente non disponibile. Riprova più tardi.|Il testo è già nella lingua selezionata.|La sessione è cambiata. Apri di nuovo il testo.',
    'pt': 'Traduzir|Mostrar tradução|Mostrar original|A traduzir…|Não foi possível traduzir. Tente novamente.|O tradutor ainda não está ligado.|O texto é demasiado longo para traduzir.|A tradução está temporariamente indisponível. Tente mais tarde.|O texto já está no idioma selecionado.|A sua sessão mudou. Abra o texto novamente.',
    'el': 'Μετάφραση|Εμφάνιση μετάφρασης|Εμφάνιση πρωτοτύπου|Γίνεται μετάφραση…|Η μετάφραση απέτυχε. Δοκιμάστε ξανά.|Η υπηρεσία μετάφρασης δεν έχει συνδεθεί ακόμη.|Το κείμενο είναι πολύ μεγάλο για μετάφραση.|Η μετάφραση δεν είναι προσωρινά διαθέσιμη. Δοκιμάστε αργότερα.|Το κείμενο είναι ήδη στην επιλεγμένη γλώσσα.|Η συνεδρία σας άλλαξε. Ανοίξτε ξανά το κείμενο.',
    'sr': 'Prevedi|Prikaži prevod|Prikaži original|Prevođenje…|Prevod nije uspeo. Pokušajte ponovo.|Prevodilac još nije povezan.|Tekst je predugačak za prevođenje.|Prevod je privremeno nedostupan. Pokušajte kasnije.|Tekst je već na izabranom jeziku.|Vaša sesija se promenila. Ponovo otvorite tekst.',
    'pl': 'Przetłumacz|Pokaż tłumaczenie|Pokaż oryginał|Tłumaczenie…|Nie udało się przetłumaczyć. Spróbuj ponownie.|Tłumacz nie jest jeszcze podłączony.|Tekst jest za długi do przetłumaczenia.|Tłumaczenie jest chwilowo niedostępne. Spróbuj później.|Tekst jest już w wybranym języku.|Twoja sesja się zmieniła. Otwórz tekst ponownie.',
    'sl': 'Prevedi|Prikaži prevod|Prikaži izvirnik|Prevajanje…|Prevajanje ni uspelo. Poskusite znova.|Prevajalnik še ni povezan.|Besedilo je predolgo za prevajanje.|Prevajanje trenutno ni na voljo. Poskusite pozneje.|Besedilo je že v izbranem jeziku.|Vaša seja se je spremenila. Znova odprite besedilo.',
    'sk': 'Preložiť|Zobraziť preklad|Zobraziť originál|Prekladá sa…|Preklad sa nepodaril. Skúste to znova.|Prekladač ešte nie je pripojený.|Text je príliš dlhý na preklad.|Preklad je dočasne nedostupný. Skúste to neskôr.|Text je už vo vybranom jazyku.|Vaša relácia sa zmenila. Znova otvorte text.',
    'cs': 'Přeložit|Zobrazit překlad|Zobrazit originál|Překládá se…|Překlad se nezdařil. Zkuste to znovu.|Překladač ještě není připojen.|Text je příliš dlouhý na překlad.|Překlad je dočasně nedostupný. Zkuste to později.|Text je již ve vybraném jazyce.|Vaše relace se změnila. Otevřete text znovu.',
    'bg': 'Преведи|Покажи превода|Покажи оригинала|Превеждане…|Преводът не бе успешен. Опитайте отново.|Преводачът все още не е свързан.|Текстът е твърде дълъг за превод.|Преводът временно не е наличен. Опитайте по-късно.|Текстът вече е на избрания език.|Сесията ви се промени. Отворете текста отново.',
    'ro': 'Tradu|Afișează traducerea|Afișează originalul|Se traduce…|Traducerea a eșuat. Încercați din nou.|Traducătorul nu este încă conectat.|Textul este prea lung pentru a fi tradus.|Traducerea nu este disponibilă temporar. Încercați mai târziu.|Textul este deja în limba selectată.|Sesiunea s-a schimbat. Deschideți din nou textul.',
    'mk': 'Преведи|Прикажи го преводот|Прикажи го оригиналот|Се преведува…|Преводот не успеа. Обидете се повторно.|Преведувачот сè уште не е поврзан.|Текстот е премногу долг за преведување.|Преводот е привремено недостапен. Обидете се подоцна.|Текстот веќе е на избраниот јазик.|Вашата сесија се промени. Отворете го текстот повторно.',
    'hu': 'Fordítás|Fordítás megjelenítése|Eredeti megjelenítése|Fordítás folyamatban…|A fordítás nem sikerült. Próbálja újra.|A fordító még nincs csatlakoztatva.|A szöveg túl hosszú a fordításhoz.|A fordítás átmenetileg nem érhető el. Próbálja később.|A szöveg már a kiválasztott nyelven van.|A munkamenet megváltozott. Nyissa meg újra a szöveget.',
    'sv': 'Översätt|Visa översättning|Visa original|Översätter…|Det gick inte att översätta. Försök igen.|Översättaren är inte ansluten ännu.|Texten är för lång för att översättas.|Översättning är tillfälligt otillgänglig. Försök senare.|Texten är redan på det valda språket.|Din session har ändrats. Öppna texten igen.',
    'nb': 'Oversett|Vis oversettelse|Vis original|Oversetter…|Kunne ikke oversette. Prøv igjen.|Oversetteren er ikke tilkoblet ennå.|Teksten er for lang til å oversettes.|Oversettelse er midlertidig utilgjengelig. Prøv igjen senere.|Teksten er allerede på det valgte språket.|Økten din er endret. Åpne teksten på nytt.',
    'fi': 'Käännä|Näytä käännös|Näytä alkuperäinen|Käännetään…|Kääntäminen epäonnistui. Yritä uudelleen.|Kääntäjää ei ole vielä yhdistetty.|Teksti on liian pitkä käännettäväksi.|Käännös ei ole tilapäisesti saatavilla. Yritä myöhemmin uudelleen.|Teksti on jo valitulla kielellä.|Istuntosi on muuttunut. Avaa teksti uudelleen.',
    'da': 'Oversæt|Vis oversættelse|Vis original|Oversætter…|Kunne ikke oversætte. Prøv igen.|Oversætteren er ikke tilsluttet endnu.|Teksten er for lang til at blive oversat.|Oversættelse er midlertidigt utilgængelig. Prøv igen senere.|Teksten er allerede på det valgte sprog.|Din session er ændret. Åbn teksten igen.',
    'nl': 'Vertalen|Vertaling tonen|Origineel tonen|Bezig met vertalen…|Vertalen mislukt. Probeer het opnieuw.|De vertaler is nog niet verbonden.|De tekst is te lang om te vertalen.|Vertalen is tijdelijk niet beschikbaar. Probeer het later opnieuw.|De tekst is al in de geselecteerde taal.|Je sessie is gewijzigd. Open de tekst opnieuw.',
    'is': 'Þýða|Sýna þýðingu|Sýna frumtexta|Þýði…|Ekki tókst að þýða. Reyndu aftur.|Þýðingarþjónustan er ekki tengd enn.|Textinn er of langur til að þýða.|Þýðingar eru tímabundið ekki tiltækar. Reyndu aftur síðar.|Textinn er þegar á völdu tungumáli.|Setan þín hefur breyst. Opnaðu textann aftur.',
}

def write():
    codes = 'en de es fr it pt el ru sr pl sl sk cs bg ro mk hu sv nb fi da nl is'.split()
    assert set(ROWS) == set(codes) - {'ru'}
    catalogs = {'ru': dict(zip(KEYS, KEYS))}
    for code, row in ROWS.items():
        cells = row.split('|')
        assert len(cells) == len(KEYS), (code, len(cells))
        assert all(cell.strip() for cell in cells)
        catalogs[code] = dict(zip(KEYS, cells))
    destination = Path(__file__).resolve().parent / 'l10n_segments/dynamic_translation.json'
    destination.write_text(json.dumps(catalogs, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(catalogs)} languages × {len(KEYS)} translation controls')

if __name__ == '__main__':
    write()
