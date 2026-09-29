def add_groups(CAT):
    colors = {
      'ru':'красная|синяя|коричневая|белая',
      'en':'red|blue|brown|white', 'de':'rot|blau|braun|weiß',
      'es':'rojo|azul|marrón|blanco', 'fr':'rouge|bleu|marron|blanc',
      'it':'rosso|blu|marrone|bianco', 'pt':'vermelho|azul|castanho|branco',
      'el':'κόκκινη|μπλε|καφέ|λευκή', 'sr':'crvena|plava|braon|bela',
      'pl':'czerwona|niebieska|brązowa|biała', 'sl':'rdeča|modra|rjava|bela',
      'sk':'červená|modrá|hnedá|biela', 'cs':'červená|modrá|hnědá|bílá',
      'bg':'червена|синя|кафява|бяла', 'ro':'roșu|albastru|maro|alb',
      'mk':'црвена|сина|кафеава|бела', 'hu':'piros|kék|barna|fehér',
      'sv':'röd|blå|brun|vit', 'nb':'rød|blå|brun|hvit',
      'fi':'punainen|sininen|ruskea|valkoinen', 'da':'rød|blå|brun|hvid',
      'nl':'rood|blauw|bruin|wit', 'is':'rauður|blár|brúnn|hvítur',
    }
    source = colors['ru'].split('|')
    stems = ['красно','сине','коричнево','бело']
    for code, values in colors.items():
        names = values.split('|')
        for a in range(4):
            for b in range(4):
                key = source[a] if a == b else f'{stems[a]}-{source[b]}'
                value = names[a] if a == b else f'{names[a]}–{names[b]}'
                # Stored identifiers are unchanged: these are display strings only.
                CAT[code][key] = key if code == 'ru' else value
                CAT[code][key[0].upper()+key[1:]] = key[0].upper()+key[1:] if code == 'ru' else value[0].upper()+value[1:]
