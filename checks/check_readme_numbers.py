"""Числа README против выгрузок витрин.

Что проверяет:
1. Таблица по модулям между метками <!-- modules-table:start/end --> совпадает с таблицей, собранной
   из dashboard/data/presentation_outcome.json (--write перезаписывает её; руками таблицу не правят).
2. В блоках <!-- checked:start/end --> (русский текст) и <!-- checked-en:start/end --> (английский)
   нет чисел, которых нет среди подписей фактов (readme_facts.json, колонка display), счётчиков
   качества данных (data_quality.json) и нескольких параметров определений (номер недели, годы набора).
   Коды потоков вида «CCC 2014B» сверяются со списком потоков выгрузки, число из описания набора
   OULAD.names — с самим файлом.
3. В блоке <!-- checked-tooling:start/end --> числа о самих проверках (сколько проверок, сколько
   значений сверено, сколько порч поймано) совпадают с логами последнего прогона в .tmp/.

Чего не проверяет: числа вне этих блоков (версии PostgreSQL, порт, команды) и утверждения словами
(«во всех», «почти все») — их сверяют запросами отдельно.

Запуск: python3 -I checks/check_readme_numbers.py [--write] [--self-test]
"""
import argparse
import json
import re
import sys
from collections import OrderedDict
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NBSP = " "
# Параметры определений, а не результаты: номер недели в фактах week12_* и годы набора.
PARAMETERS = {"12": "неделя фактов week12_*", "2013": "год набора", "2014": "год набора"}

RU_NUMBER = re.compile(r"\d{1,3}(?:[  ]\d{3})+(?:,\d+)?|\d+(?:,\d+)?")
EN_NUMBER = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")
PRESENTATION = re.compile(r"\b[A-G]{3} 20\d{2}[BJ]\b")


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"), parse_float=Decimal)


def fmt_int(n):
    """Как mart.fmt_int: тысячи через неразрывный пробел начиная с 10 000."""
    n = int(n)
    if abs(n) < 10000:
        return str(n)
    return f"{n:,}".replace(",", NBSP)


def fmt_pct(x):
    """Как mart.fmt_pct: 100·x с одним знаком, округление половины от нуля, запятая."""
    v = (Decimal(x) * 100).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)
    return f"{v}".replace(".", ",") + "%"


def canon_ru(token):
    return token.replace(" ", "").replace(NBSP, "")


def canon_en(token):
    return token.replace(",", "").replace(".", ",")


def module_table(outcome):
    by_module = OrderedDict()
    for r in outcome:
        by_module.setdefault(r["code_module"], []).append(r)

    def row(name, rows):
        s = lambda k: sum(r[k] for r in rows)
        started = s("started")
        return (f"| {name} | {len(rows)} | {fmt_int(started)} | {fmt_pct(Decimal(s('started_distinction') + s('started_pass')) / started)} "
                f"| {fmt_pct(Decimal(s('started_withdrawn')) / started)} "
                f"| {fmt_pct(Decimal(s('submitted_assessments')) / s('expected_assessments'))} "
                f"| {fmt_pct(Decimal(s('tma_on_time')) / s('tma_submitted'))} |")

    lines = ["| Модуль | Потоков | Приступили | Сдали курс | Отписались | Сдача заданий | TMA в срок |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    lines += [row(m, rows) for m, rows in by_module.items()]
    lines.append(row("Все модули", outcome))
    return "\n".join(lines)


def blocks(text, tag):
    return re.findall(rf"<!-- {tag}:start -->(.*?)<!-- {tag}:end -->", text, flags=re.S)


def strip_noise(block):
    block = re.sub(r"(?m)^\s*\d+\.\s", " ", block)     # номера пунктов списка
    block = re.sub(r"`[^`]*`", " ", block)            # идентификаторы и код
    block = re.sub(r"\]\([^)]*\)", "]", block)         # адреса ссылок
    block = re.sub(r"<!--.*?-->", " ", block, flags=re.S)
    block = re.sub(r"CC BY \d\.\d", " ", block)        # название лицензии
    return block


def tooling_numbers():
    """Числа о проверках из логов последнего прогона."""
    found = {}
    sources = {
        ".tmp/25_raw_checks.log": [(r"Проверок сырья: (\d+), не прошло: 0", "raw_checks")],
        ".tmp/90_checks.log": [(r"Проверок витрин: (\d+), не прошло: 0", "mart_checks")],
        ".tmp/verify_independent.log": [(r"Всего сверено значений: (\d+); расхождений: 0", "values"),
                                        (r"порч поймано: (\d+) из \1", "self_test")],
        ".tmp/test_controls.out": [(r"Порч поймано: (\d+) из \1", "controls")],
    }
    for path, patterns in sources.items():
        p = ROOT / path
        text = p.read_text(encoding="utf-8") if p.exists() else ""
        for pattern, key in patterns:
            m = re.search(pattern, text)
            if m:
                found[key] = m.group(1).replace(" ", "")
    if "values" in found:
        found["mismatches"] = "0"                      # лог совпал только при «расхождений: 0»
    if "raw_checks" in found and "mart_checks" in found:
        found["all_checks"] = str(int(found["raw_checks"]) + int(found["mart_checks"]))
    return found


def check(text, facts, quality, outcome):
    problems = []
    expected_table = module_table(outcome)
    tables = re.findall(r"<!-- modules-table:start -->\n(.*?)<!-- modules-table:end -->", text, flags=re.S)
    if len(tables) != 1:
        problems.append(f"меток таблицы по модулям: {len(tables)}, ожидалась 1 пара")
    elif tables[0] != expected_table + "\n":
        problems.append("таблица по модулям не совпадает с выгрузкой: запустите с --write")

    allowed = {canon_ru(t) for f in facts if f["display"] for t in RU_NUMBER.findall(f["display"])}
    allowed |= {canon_ru(fmt_int(q["n"])) for q in quality}
    allowed |= set(PARAMETERS)
    # Число из описания набора OULAD.names (там опечатка, README её цитирует).
    names = ROOT / "data/raw/OULAD.names"
    if names.exists():
        allowed |= set(re.findall(r"students in courses: (\d+)", names.read_text(encoding="latin-1")))
    presentations = {f"{r['code_module']} {r['code_presentation']}" for r in outcome}

    checked = [(b, RU_NUMBER, canon_ru) for b in blocks(text, "checked")] + \
              [(b, EN_NUMBER, canon_en) for b in blocks(text, "checked-en")]
    if not blocks(text, "checked") or not blocks(text, "checked-en"):
        problems.append("нет проверяемых блоков checked или checked-en")
    numbers_seen = 0
    for block, pattern, canon in checked:
        block = strip_noise(block)
        for code in PRESENTATION.findall(block):
            if code not in presentations:
                problems.append(f"поток {code} не найден в выгрузке")
        block = PRESENTATION.sub(" ", block)
        for token in pattern.findall(block):
            numbers_seen += 1
            if canon(token) not in allowed:
                problems.append(f"число «{token}» не найдено среди фактов и счётчиков качества данных")

    tools = tooling_numbers()
    tool_values = set(tools.values())
    tool_blocks = blocks(text, "checked-tooling")
    if not tool_blocks:
        problems.append("нет блока checked-tooling")
    for block in tool_blocks:
        for token in RU_NUMBER.findall(strip_noise(block)):
            numbers_seen += 1
            if canon_ru(token) not in tool_values:
                problems.append(f"число о проверках «{token}» не совпадает с логами .tmp/ (найдено: {tools})")
    return problems, numbers_seen


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--readme", default=str(ROOT / "README.md"))
    ap.add_argument("--exports", default=str(ROOT / "dashboard/data"))
    ap.add_argument("--write", action="store_true", help="перерисовать таблицу по модулям")
    ap.add_argument("--self-test", action="store_true", help="убедиться, что порча README ловится")
    args = ap.parse_args()

    facts = load(Path(args.exports) / "readme_facts.json")
    quality = load(Path(args.exports) / "data_quality.json")
    outcome = load(Path(args.exports) / "presentation_outcome.json")
    readme = Path(args.readme)
    text = readme.read_text(encoding="utf-8")

    if args.write:
        new = re.sub(r"(<!-- modules-table:start -->\n).*?(<!-- modules-table:end -->)",
                     lambda m: m.group(1) + module_table(outcome) + "\n" + m.group(2), text, flags=re.S)
        readme.write_text(new, encoding="utf-8")
        text = new
        print("таблица по модулям перерисована из presentation_outcome.json")

    problems, seen = check(text, facts, quality, outcome)
    if args.self_test:
        if problems:
            print("самопроверка невозможна: исходный README не проходит:\n  " + "\n  ".join(problems))
            sys.exit(1)
        first_pct = next(f["display"] for f in facts if f["display"] and f["display"].endswith("%") and f["display"] in text)
        cases = {
            "изменён процент в выводах": text.replace(first_pct, first_pct.replace(",", ",9", 1), 1),
            "изменена ячейка таблицы по модулям": re.sub(r"(\| Все модули \| \d+ \| )", r"\g<1>1", text, count=1),
            "лишнее число в английском блоке": text.replace("<!-- checked-en:end -->", " 77.7% <!-- checked-en:end -->", 1),
            "несуществующий поток": text.replace("<!-- checked:end -->", " AAA 2015J <!-- checked:end -->", 1),
            "неверное число о проверках": re.sub(r"(<!-- checked-tooling:start -->.*?)(\d+)", lambda m: m.group(1) + "9999", text, count=1, flags=re.S),
        }
        missed = [name for name, bad in cases.items() if not check(bad, facts, quality, outcome)[0]]
        caught = len(cases) - len(missed)
        print(f"самопроверка README: поймано порч {caught} из {len(cases)}" + (f"; НЕ пойманы: {', '.join(missed)}" if missed else ""))
        sys.exit(1 if missed else 0)

    if problems:
        print("README расходится с выгрузками:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print(f"README: проверено чисел {seen}, все найдены в выгрузках и логах проверок; таблица по модулям совпадает")


if __name__ == "__main__":
    main()
