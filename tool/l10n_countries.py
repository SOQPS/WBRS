"""Generate display-only country names from Babel 2.17 / Unicode CLDR 46.

Requires Babel==2.17.0 only when refreshing this checked-in source segment.
The app and build_l10n_catalogs.py do not require Python/Babel at runtime.
Stored geo_catalog names/codes and subdivision names are left unchanged.
"""
import json
from pathlib import Path
from babel import Locale
ROOT = Path(__file__).resolve().parents[1]
CODES = 'en de es fr it pt el ru sr pl sl sk cs bg ro mk hu sv nb fi da nl is'.split()
countries = json.loads((ROOT / 'assets/geo_catalog.json').read_text())['countries']
result = {}
for code in CODES:
    locale = Locale.parse('sr_Latn' if code == 'sr' else code)
    result[code] = {country['name']: country['name'] if code == 'ru' else locale.territories[country['code']]
                    for country in countries}
(ROOT / 'tool/l10n_segments/countries_cldr.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(f'{len(countries)} countries in {len(CODES)} languages')
