"""Reviewed source-order translations of the 80 temperament statements.
Stored score/group identifiers stay Russian; only displayed statements change.
"""
import json
import re
from pathlib import Path

DATA = {}
DATA['en'] = '''
You are restless and fidgety
You are short-tempered and easily angered
You are impatient
You are abrupt and direct with people
You are decisive and take initiative
You are stubborn
You are quick-witted in an argument
You work in bursts
You tend to take risks
You hold grudges
You speak quickly and passionately, with uneven intonation
You are emotionally unsettled and easily heated
You are aggressive and quarrelsome
You are intolerant of shortcomings
You have expressive facial expressions
You can act and make decisions quickly
You constantly seek new experiences
Your movements are abrupt and impulsive
You persist in pursuing your goals
You tend to have sudden mood swings
You are cheerful and full of life
You are energetic and businesslike
You often leave things unfinished
You tend to overestimate yourself
You grasp new things quickly
Your interests and inclinations change often
You recover easily from setbacks and troubles
You adapt easily to different circumstances
You enthusiastically take on new tasks
You quickly lose enthusiasm when something no longer interests you
You get into new work quickly and switch easily between tasks
You find routine, painstaking work tedious
You are sociable and responsive, and feel at ease with new people
You have stamina and a strong capacity for work
You speak loudly, quickly and clearly, using gestures and expressive facial movements
You remain composed in unexpectedly difficult situations
You are consistently in good spirits
You fall asleep and wake up quickly
You are often disorganized and make hasty decisions
You sometimes deal with things superficially and become distracted
You are shy and bashful
You feel lost in unfamiliar surroundings
You find it difficult to connect with strangers
You lack confidence in your abilities
You cope well with being alone
Setbacks leave you feeling down and confused
You tend to withdraw into yourself
You tire quickly
You speak quietly
You unconsciously adapt to the personality of the person you are speaking with
You are easily moved to tears
You are extremely sensitive to praise and criticism
You set high standards for yourself and others
You tend to be suspicious and worry unnecessarily
You are painfully sensitive and easily hurt
You take offense too easily
You are reserved and unsociable, keeping your thoughts to yourself
You lack initiative and are timid
You are accommodating and submissive
You seek sympathy and help from others
You are calm and cool-headed
You are consistent and thorough in your work
You are cautious and sensible
You know how to wait
You are quiet and dislike idle chatter
You speak calmly and evenly, with pauses and little outward emotion, gesturing or facial expression
You are restrained and patient
You finish what you start
You do not waste your energy
You follow an established daily routine and a set approach to work
You easily control your impulses
You are relatively unaffected by praise or criticism
You are good-natured and tolerant of barbed remarks directed at you
You are steady in your relationships and interests
You take time to get into work and to switch between tasks
You treat everyone with the same even manner
You like neatness and order in everything
You find it difficult to adapt to unfamiliar surroundings
You have self-control
You are somewhat slow-paced
'''
DATA['de'] = '''
Sie sind unruhig und zappelig
Sie sind unbeherrscht und aufbrausend
Sie sind ungeduldig
Sie sind im Umgang mit anderen schroff und direkt
Sie sind entschlossen und ergreifen die Initiative
Sie sind stur
Sie sind in Auseinandersetzungen schlagfertig
Sie arbeiten in Schüben
Sie gehen gern Risiken ein
Sie sind nachtragend
Sie sprechen schnell und leidenschaftlich, mit wechselnder Betonung
Sie sind unausgeglichen und werden schnell hitzig
Sie sind aggressiv und streitsüchtig
Sie sind gegenüber Schwächen wenig tolerant
Sie haben eine ausdrucksstarke Mimik
Sie können schnell handeln und entscheiden
Sie streben unermüdlich nach Neuem
Ihre Bewegungen sind abrupt und impulsiv
Sie verfolgen Ihre Ziele beharrlich
Sie neigen zu plötzlichen Stimmungsschwankungen
Sie sind fröhlich und lebenslustig
Sie sind energiegeladen und tatkräftig
Sie bringen Angefangenes oft nicht zu Ende
Sie neigen dazu, sich zu überschätzen
Sie erfassen Neues schnell
Ihre Interessen und Neigungen wechseln häufig
Sie überwinden Misserfolge und Schwierigkeiten leicht
Sie passen sich unterschiedlichen Umständen leicht an
Sie gehen jede neue Aufgabe begeistert an
Sie verlieren schnell die Begeisterung, wenn Sie etwas nicht mehr interessiert
Sie finden sich schnell in neue Arbeit ein und wechseln rasch zwischen Aufgaben
Sie empfinden gleichförmige, sorgfältige Alltagsarbeit als mühsam
Sie sind gesellig und hilfsbereit und fühlen sich mit neuen Menschen ungezwungen
Sie sind ausdauernd und leistungsfähig
Sie sprechen laut, schnell und deutlich und begleiten Ihre Worte mit Gesten und lebhafter Mimik
Sie bewahren in unerwartet schwierigen Situationen die Fassung
Sie sind stets guter Dinge
Sie schlafen schnell ein und werden schnell wach
Sie sind oft unorganisiert und entscheiden überstürzt
Sie bleiben manchmal an der Oberfläche und lassen sich ablenken
Sie sind schüchtern und zurückhaltend
In ungewohnter Umgebung sind Sie orientierungslos
Es fällt Ihnen schwer, mit fremden Menschen Kontakt aufzunehmen
Sie vertrauen Ihren Fähigkeiten nicht
Sie kommen gut mit dem Alleinsein zurecht
Misserfolge machen Sie niedergeschlagen und ratlos
Sie ziehen sich häufig in sich selbst zurück
Sie ermüden schnell
Sie sprechen leise
Sie passen sich unwillkürlich dem Wesen Ihres Gegenübers an
Sie sind leicht zu Tränen gerührt
Sie reagieren äußerst empfindlich auf Lob und Kritik
Sie stellen hohe Ansprüche an sich und andere
Sie neigen zu Misstrauen und übermäßigen Befürchtungen
Sie sind äußerst empfindsam und leicht verletzbar
Sie fühlen sich übermäßig schnell gekränkt
Sie sind verschlossen und ungesellig und teilen Ihre Gedanken mit niemandem
Sie sind wenig aktiv und zaghaft
Sie sind nachgiebig und unterwürfig
Sie suchen Mitgefühl und Hilfe bei anderen
Sie sind ruhig und besonnen
Sie gehen konsequent und gründlich vor
Sie sind vorsichtig und vernünftig
Sie können warten
Sie sind schweigsam und mögen kein unnötiges Gerede
Sie sprechen ruhig und gleichmäßig, mit Pausen und wenig sichtbarer Emotion, Gestik oder Mimik
Sie sind beherrscht und geduldig
Sie bringen Angefangenes zu Ende
Sie verschwenden Ihre Kräfte nicht
Sie halten sich an einen festen Tagesablauf und eine geregelte Arbeitsweise
Sie können Ihre Impulse leicht kontrollieren
Lob und Kritik beeinflussen Sie wenig
Sie sind gutmütig und sehen über spitze Bemerkungen gegen Sie hinweg
Sie sind in Beziehungen und Interessen beständig
Sie brauchen Zeit, um mit einer Arbeit zu beginnen oder zwischen Aufgaben zu wechseln
Sie begegnen allen Menschen gleichmäßig und gelassen
Sie mögen Sauberkeit und Ordnung in allem
Es fällt Ihnen schwer, sich an eine neue Umgebung anzupassen
Sie verfügen über Selbstbeherrschung
Sie sind etwas langsam
'''
DATA['es'] = '''
Es inquieto y no para de moverse
Pierde el control y se enfada con facilidad
Es impaciente
Es brusco y directo en el trato con los demás
Es decidido y tiene iniciativa
Es terco
Tiene respuestas ingeniosas en las discusiones
Trabaja a rachas
Tiende a correr riesgos
Es rencoroso
Habla deprisa y con pasión, con una entonación irregular
Es inestable emocionalmente y se acalora con facilidad
Es agresivo y busca pelea
Es poco tolerante con los defectos
Tiene un rostro expresivo
Puede actuar y decidir rápidamente
Busca constantemente cosas nuevas
Sus movimientos son bruscos e impulsivos
Persevera hasta alcanzar sus objetivos
Tiende a sufrir cambios bruscos de humor
Es alegre y disfruta de la vida
Es enérgico y emprendedor
A menudo deja las cosas sin terminar
Tiende a sobrevalorarse
Capta las cosas nuevas con rapidez
Sus intereses e inclinaciones cambian con frecuencia
Supera fácilmente los fracasos y contratiempos
Se adapta fácilmente a distintas circunstancias
Emprende con entusiasmo cualquier actividad nueva
Pierde el entusiasmo rápidamente cuando algo deja de interesarle
Se incorpora rápidamente a una tarea nueva y cambia de una a otra con facilidad
Le pesa la monotonía del trabajo cotidiano minucioso
Es sociable y atento, y se siente cómodo con personas nuevas
Tiene resistencia y capacidad de trabajo
Habla alto, deprisa y con claridad, acompañándose de gestos y expresiones faciales
Mantiene la calma ante situaciones difíciles inesperadas
Siempre está de buen ánimo
Se duerme y se despierta rápidamente
A menudo es desorganizado y toma decisiones precipitadas
A veces trata las cosas superficialmente y se distrae
Es tímido y vergonzoso
Se siente perdido en un entorno desconocido
Le cuesta entablar contacto con desconocidos
No confía en sus capacidades
Lleva bien la soledad
Los fracasos le hacen sentirse abatido y desorientado
Tiende a encerrarse en sí mismo
Se cansa rápidamente
Habla en voz baja
Se adapta involuntariamente al carácter de su interlocutor
Se emociona hasta las lágrimas con facilidad
Es extremadamente sensible a los elogios y las críticas
Se exige mucho a sí mismo y a los demás
Tiende a desconfiar y a preocuparse en exceso
Es muy sensible y se siente herido con facilidad
Se ofende con demasiada facilidad
Es reservado y poco sociable, y no comparte sus pensamientos
Es poco activo y temeroso
Es complaciente y sumiso
Busca la compasión y la ayuda de los demás
Es tranquilo y mantiene la cabeza fría
Es constante y minucioso en lo que hace
Es prudente y sensato
Sabe esperar
Es callado y no le gusta hablar por hablar
Habla con calma y de manera uniforme, con pausas y pocas emociones, gestos o expresiones visibles
Es contenido y paciente
Termina lo que empieza
No malgasta sus energías
Sigue una rutina diaria y un método de trabajo establecidos
Controla sus impulsos con facilidad
Los elogios y las críticas le afectan poco
Es bondadoso y tolera las pullas dirigidas a usted
Es constante en sus relaciones e intereses
Tarda en ponerse a trabajar y en pasar de una tarea a otra
Trata a todo el mundo con la misma serenidad
Le gustan la pulcritud y el orden en todo
Le cuesta adaptarse a un entorno nuevo
Tiene dominio de sí mismo
Es algo lento
'''
DATA['fr'] = '''
Vous êtes agité et avez du mal à rester en place
Vous manquez de maîtrise de vous-même et vous emportez facilement
Vous êtes impatient
Vous êtes brusque et direct avec les autres
Vous êtes décidé et prenez des initiatives
Vous êtes obstiné
Vous avez de la répartie dans les discussions
Vous travaillez par à-coups
Vous avez tendance à prendre des risques
Vous êtes rancunier
Vous parlez vite et avec passion, avec une intonation irrégulière
Vous manquez de stabilité émotionnelle et vous échauffez facilement
Vous êtes agressif et querelleur
Vous tolérez mal les défauts
Votre visage est expressif
Vous savez agir et décider rapidement
Vous recherchez sans cesse la nouveauté
Vos mouvements sont brusques et impulsifs
Vous persévérez pour atteindre vos objectifs
Vous avez tendance à changer brusquement d'humeur
Vous êtes gai et plein de joie de vivre
Vous êtes énergique et entreprenant
Vous ne terminez souvent pas ce que vous commencez
Vous avez tendance à vous surestimer
Vous assimilez rapidement les choses nouvelles
Vos intérêts et vos penchants changent souvent
Vous surmontez facilement les échecs et les contrariétés
Vous vous adaptez facilement aux différentes circonstances
Vous abordez toute nouvelle activité avec enthousiasme
Votre enthousiasme retombe vite lorsque quelque chose ne vous intéresse plus
Vous vous mettez rapidement à une nouvelle tâche et passez vite de l'une à l'autre
La monotonie du travail quotidien minutieux vous pèse
Vous êtes sociable et attentionné, à l'aise avec les personnes que vous venez de rencontrer
Vous êtes endurant et avez une bonne capacité de travail
Vous parlez fort, vite et clairement, avec des gestes et des expressions du visage marquées
Vous gardez votre sang-froid dans les situations difficiles et imprévues
Vous êtes toujours de bonne humeur
Vous vous endormez et vous réveillez rapidement
Vous êtes souvent désorganisé et prenez des décisions hâtives
Vous restez parfois à la surface des choses et vous laissez distraire
Vous êtes timide et réservé
Vous perdez vos repères dans un nouvel environnement
Vous avez du mal à entrer en contact avec des inconnus
Vous ne croyez pas en vos capacités
Vous supportez bien la solitude
Les échecs vous abattent et vous désorientent
Vous avez tendance à vous replier sur vous-même
Vous vous fatiguez vite
Vous parlez doucement
Vous vous adaptez involontairement au caractère de votre interlocuteur
Vous êtes facilement ému aux larmes
Vous êtes extrêmement sensible aux compliments et aux critiques
Vous êtes très exigeant envers vous-même et les autres
Vous avez tendance à être méfiant et à vous inquiéter excessivement
Vous êtes très sensible et facilement blessé
Vous vous vexez trop facilement
Vous êtes secret et peu sociable, et ne partagez vos pensées avec personne
Vous êtes peu actif et craintif
Vous êtes conciliant et soumis
Vous cherchez à susciter la compassion et l'aide des autres
Vous êtes calme et gardez la tête froide
Vous êtes constant et méthodique dans vos activités
Vous êtes prudent et réfléchi
Vous savez attendre
Vous êtes taciturne et n'aimez pas les bavardages inutiles
Vous parlez calmement et régulièrement, avec des pauses et peu d'émotions, de gestes ou d'expressions visibles
Vous êtes retenu et patient
Vous terminez ce que vous commencez
Vous ne gaspillez pas votre énergie
Vous suivez une routine quotidienne et une méthode de travail établies
Vous maîtrisez facilement vos impulsions
Les compliments et les critiques vous affectent peu
Vous êtes bienveillant et indulgent face aux remarques piquantes à votre égard
Vous êtes constant dans vos relations et vos intérêts
Vous mettez du temps à vous mettre au travail et à passer d'une tâche à une autre
Vous êtes d'humeur égale avec tout le monde
Vous aimez la propreté et l'ordre en toute chose
Vous vous adaptez difficilement à un nouvel environnement
Vous avez de la maîtrise de vous-même
Vous êtes un peu lent
'''

def write_draft():
    source = Path('lib/presentation/screens/test/red_group.dart').read_text()
    keys = [key for array in re.findall(r'final List<String> \w+\s*=\s*\[(.*?)\];', source, re.S)
            for key in re.findall(r"'([^']*)'", array)]
    assert len(keys) == len(set(keys)) == 80
    result = {'ru': {key: key for key in keys}}
    for code, raw in DATA.items():
        values = [line.strip() for line in raw.splitlines() if line.strip()]
        if len(values) != len(keys):
            raise ValueError(f'{code}: {len(values)} translations, expected {len(keys)}')
        result[code] = dict(zip(keys, values))
    Path('tool/l10n_segments/test_questions.draft.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print({code:len(values) for code,values in result.items()})

if __name__ == '__main__':
    for module in ['l10n_questions_west', 'l10n_questions_nordic',
                   'l10n_questions_central', 'l10n_questions_balkan',
                   'l10n_questions_remaining']:
        DATA.update(__import__(module).DATA)
    write_draft()
    draft = Path('tool/l10n_segments/test_questions.draft.json')
    codes = {'en','de','es','fr','it','pt','el','ru','sr','pl','sl','sk','cs','bg','ro','mk','hu','sv','nb','fi','da','nl','is'}
    assert set(json.loads(draft.read_text())) == codes
    draft.replace('tool/l10n_segments/test_questions.json')
