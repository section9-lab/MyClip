#!/usr/bin/env python3
"""Keeps the two String Catalogs in sync with the source code.

Keys come from the compiler's `.stringsdata` files (app target under DerivedData, Core under the work dir). Existing
translations in the catalogs are preserved; new keys are added untranslated; keys that disappeared from the code are
removed. With `--translations DIR`, files named `<lang>.json` ({"<key>": "<translation>"}) are merged in first, after
checking that each translation keeps the same format placeholders as its key. Translation keys may use positional
placeholders (`%1$lld`) as XLIFF exports do; they are matched to the catalog's `%lld` keys. Ends with a report of keys
still missing a language.
"""
import argparse, glob, json, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[2]
LANGS = ['en', 'ja', 'ko', 'es', 'fr', 'de']
# One catalog for both the app target and MyClipCore: a SwiftPM resource bundle does not ship the compiled
# per-language files, so Core looks its strings up in the main bundle, which is the app's.
CATALOG = ROOT / 'MyClip/Supporting/Localizable.xcstrings'
CJK = re.compile(r'[一-鿿]')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:@|lld|lf|ld|d|%)')

def stringsdata_keys(pattern):
    keys = set()
    for path in glob.glob(pattern, recursive=True):
        for item in json.load(open(path)).get('tables', {}).get('Localizable', []):
            keys.add(item['key'])
    return keys

def unpositional(text):
    """`%1$lld` -> `%lld`: the form String(localized:) and LocalizedStringKey use for their keys."""
    return re.sub(r'%(\d+)\$', '%', text)

def load_translations(directory):
    result = {}
    for lang in LANGS:
        path = pathlib.Path(directory, f'{lang}.json')
        if path.exists(): result[lang] = {unpositional(k): v for k, v in json.load(open(path)).items()}
    return result

def sync(path, keys, translations):
    catalog = json.load(open(path)) if path.exists() else {'sourceLanguage': 'zh-Hans', 'version': '1.0', 'strings': {}}
    old = catalog.get('strings', {})
    strings, problems, missing = {}, [], {lang: 0 for lang in LANGS}
    for key in sorted(keys):
        entry = {k: v for k, v in old.get(key, {}).items() if k in ('localizations', 'comment', 'shouldTranslate')}
        if not CJK.search(key):
            entry = {'shouldTranslate': False}
        else:
            locs = entry.get('localizations', {})
            for lang, table in translations.items():
                value = table.get(key)
                if value is None or not value.strip(): continue
                if sorted(PLACEHOLDER.findall(unpositional(value))) != sorted(PLACEHOLDER.findall(key)):
                    problems.append((lang, key)); continue
                locs[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
            if locs: entry['localizations'] = locs
            for lang in LANGS:
                if lang not in locs: missing[lang] += 1
        strings[key] = entry
    catalog['strings'] = strings
    catalog.setdefault('sourceLanguage', 'zh-Hans'); catalog.setdefault('version', '1.0')
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    removed = sorted(set(old) - keys)
    return problems, missing, removed

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', required=True, help='directory written by update_keys.sh (Core .stringsdata)')
    parser.add_argument('--app-stringsdata', required=True, help='Objects-normal directory of the app target build')
    parser.add_argument('--translations', help='directory of <lang>.json files to merge')
    args = parser.parse_args()
    translations = load_translations(args.translations) if args.translations else {}
    keys = stringsdata_keys(str(pathlib.Path(args.app_stringsdata, '**', '*.stringsdata')))
    keys |= stringsdata_keys(str(pathlib.Path(args.work, 'core', '*.stringsdata')))
    problems, missing, removed = sync(CATALOG, keys, translations)
    print(f'{len(keys)} keys; missing translations: ' + ', '.join(f'{l} {n}' for l, n in missing.items()))
    for lang, key in problems: print(f'  placeholder mismatch [{lang}]: {key[:80]!r}')
    for key in removed: print(f'  removed stale key: {key[:80]!r}')

if __name__ == '__main__':
    main()
