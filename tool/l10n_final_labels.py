def add_final_labels(batch, cat):
    batch('Документы приложения', {
        'en':'App documents','de':'App-Dokumente','es':'Documentos de la aplicación',
        'fr':'Documents de l’application','it':'Documenti dell’app','pt':'Documentos da aplicação',
        'el':'Έγγραφα εφαρμογής','sr':'Dokumenti aplikacije','pl':'Dokumenty aplikacji',
        'sl':'Dokumenti aplikacije','sk':'Dokumenty aplikácie','cs':'Dokumenty aplikace',
        'bg':'Документи на приложението','ro':'Documentele aplicației','mk':'Документи на апликацијата',
        'hu':'Az alkalmazás dokumentumai','sv':'Appdokument','nb':'Appdokumenter',
        'fi':'Sovelluksen asiakirjat','da':'Appdokumenter','nl':'Appdocumenten','is':'Skjöl forritsins',
    })
    # Standalone duration, not the grammatically different "days ago" label.
    days = {
        'ru':{'one':'день','few':'дня','many':'дней','other':'дня'},
        'en':{'one':'day','other':'days'}, 'de':{'one':'Tag','other':'Tage'},
        'es':{'one':'día','other':'días'}, 'fr':{'one':'jour','other':'jours'},
        'it':{'one':'giorno','other':'giorni'}, 'pt':{'one':'dia','other':'dias'},
        'el':{'one':'ημέρα','other':'ημέρες'},
        'sr':{'one':'dan','few':'dana','other':'dana'},
        'pl':{'one':'dzień','few':'dni','many':'dni','other':'dnia'},
        'sl':{'one':'dan','two':'dneva','few':'dni','other':'dni'},
        'sk':{'one':'deň','few':'dni','many':'dňa','other':'dní'},
        'cs':{'one':'den','few':'dny','many':'dne','other':'dní'},
        'bg':{'one':'ден','other':'дни'},
        'ro':{'one':'zi','few':'zile','other':'de zile'},
        'mk':{'one':'ден','other':'дена'}, 'hu':{'other':'nap'},
        'sv':{'one':'dag','other':'dagar'}, 'nb':{'one':'dag','other':'dager'},
        'fi':{'one':'päivä','other':'päivää'}, 'da':{'one':'dag','other':'dage'},
        'nl':{'one':'dag','other':'dagen'}, 'is':{'one':'dagur','other':'dagar'},
    }
    assert set(days) == set(cat)
    for code, forms in days.items():
        cat[code]['{count} дней'] = {form: '{count} ' + word for form, word in forms.items()}
