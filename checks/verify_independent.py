#!/usr/bin/env python3
"""Независимый второй пересчёт всех выгрузок проекта по docs/spec.md.

Скрипт написан только по спецификации docs/spec.md, без доступа к SQL-коду сборки (sql/, scripts/):
так ошибка в SQL не может перетечь в проверку. Все выгрузки считаются заново прямо из CSV OULAD
(data/raw/*.csv) средствами pandas/numpy, без базы данных, и сверяются с файлами сборки:
число строк, ключи и их порядок, целые — точно (и тип «целое»), доли — с допуском 1e-12
(null только с null), текст и логические значения — точно.

Что сверяется:
  presentation_outcome.json, assessment_submission.json, cohort_week_activity.json — все колонки спеки;
  data_quality.json — n по каждому из 16 кодов и severity;
  readme_facts.json — value всех 39 фактов; display текстовых фактов; display числовых фактов
    против форматирования спеки от пересчитанного значения (проценты, п.п., целые);
  .tmp/export/student_presentation.csv — все 18 колонок как текст (t/f, пустая строка = пропуск);
  контрольные числа, которые спека называет в тексте (22 потока, 32 593 регистрации, 182 задания...).

Что не сверяется, потому что спека не определяет значения:
  data_quality — unit, description, handling; значения seq (проверяется только, что строки идут
  по возрастанию seq); readme_facts — значения ord (то же). Порядок кодов в этих двух выгрузках
  спека задаёт только через seq/ord, поэтому совпадение с порядком строк таблиц спеки выводится
  справкой, а не расхождением. Порядок колонок в JSON-объектах и в заголовке CSV — тоже справкой.

Режим --self-test: пересчёт выполняется один раз; затем выгрузки портятся в памяти разными способами,
и каждая порча обязана дать новое расхождение относительно базовой сверки. Плюс контроли самого
прибора: выгрузка против самой себя даёт 0 расхождений, сдвиг доли на 1e-13 не ловится (допуск),
форматирование подписей проверено на заведомо известных значениях.

Код возврата: 0 — расхождений нет; 1 — есть расхождение, лишняя или недостающая колонка или строка.
В режиме --self-test код возврата отражает только самопроверку: 1 — какая-то порча не поймана
или не прошёл контроль прибора.

Запуск из корня репозитория:
  python3 -I checks/verify_independent.py --data data/raw --exports dashboard/data \
      --students .tmp/export/student_presentation.csv [--self-test]
"""

import argparse
import copy
import json
import math
import sys
import time
from collections import Counter
from fractions import Fraction
from pathlib import Path

import numpy as np
import pandas as pd

TOL = 1e-12
NBSP = " "
# Разделитель перед «п.п.» — ровно как написан в спеке: « п.п.» (обычный пробел U+0020).
PP_SUFFIX = " п.п."

KEY = ["code_module", "code_presentation", "id_student"]
PKEY = ["code_module", "code_presentation"]

# R3. Группа итога по final_result
GROUP_OF = {"Distinction": "pass", "Pass": "pass", "Fail": "fail", "Withdrawn": "withdrawn"}
# Группы в порядке байтов (COLLATE "C")
GROUPS = tuple(sorted(set(GROUP_OF.values())))

# Колонки выгрузок и их тип сравнения: int — целое точно, share — доля с допуском (null = null),
# num — число точно, text — текст точно, bool — логическое точно.
PO_COLS = {
    "code_module": "text", "code_presentation": "text", "start_year": "int",
    "start_month_code": "text", "length_days": "int", "registered": "int",
    "withdrew_before_start": "int", "started": "int", "started_distinction": "int",
    "started_pass": "int", "started_fail": "int", "started_withdrawn": "int",
    "pass_rate": "share", "withdrawn_rate": "share", "pass_rate_registered": "share",
    "expected_assessments": "int", "submitted_assessments": "int", "tma_submitted": "int",
    "tma_on_time": "int", "submission_rate": "share", "tma_on_time_share": "share",
}
PO_KEYS = ["code_module", "code_presentation"]

AS_COLS = {
    "code_module": "text", "code_presentation": "text", "id_assessment": "int",
    "assessment_type": "text", "seq": "int", "deadline_day": "int", "weight": "num",
    "expected": "int", "submitted": "int", "on_time": "int", "banked": "int",
    "submitted_not_expected": "int", "on_time_measurable": "bool",
    "submission_rate": "share", "on_time_share": "share",
}
AS_KEYS = ["code_module", "code_presentation", "seq"]

CW_COLS = {
    "code_module": "text", "code_presentation": "text", "week": "int", "outcome_group": "text",
    "enrolled": "int", "active": "int", "clicks": "int",
}
CW_KEYS = ["code_module", "code_presentation", "week", "outcome_group"]

DQ_COLS = ["seq", "code", "severity", "n", "unit", "description", "handling"]
DQ_UNDEFINED = ["unit", "description", "handling"]
DQ_CODES = [
    "reg_day_missing", "late_registration", "withdrawn_no_unreg_day", "fail_withdrew_before_start",
    "unreg_day_not_withdrawn", "unreg_after_end", "banked", "submitted_not_expected",
    "score_missing", "exam_out_of_scope", "cma_deadline", "vle_repeated_key",
    "vle_exact_duplicate", "vle_before_start", "vle_after_unreg", "no_vle",
]

RF_COLS = ["ord", "code", "value", "display"]
# Факты README в порядке строк таблицы спеки и их тип: int — целое, pct — доля (подпись «%»),
# pp — разница долей (подпись «п.п.»), text — текстовый факт (value = null, сверяется display).
RF_KINDS = {
    "modules": "int", "presentations": "int", "registrations": "int",
    "withdrew_before_start": "int", "started": "int", "started_passed": "int",
    "pass_rate": "pct", "started_withdrawn": "int", "withdrawn_rate": "pct",
    "started_failed": "int", "pass_rate_min": "pct", "pass_rate_max": "pct",
    "pass_rate_min_presentation": "text", "pass_rate_max_presentation": "text",
    "pass_rate_feb": "pct", "pass_rate_oct": "pct", "feb_oct_pairs": "int",
    "feb_lower_pairs": "int", "feb_gap_min": "pp", "feb_gap_max": "pp",
    "feb_length_min": "int", "feb_length_max": "int", "oct_length_min": "int",
    "oct_length_max": "int", "submission_rate": "pct", "first_expected": "int",
    "first_not_submitted": "int", "first_not_submitted_share": "pct",
    "first_not_submitted_pass_rate": "pct", "first_not_submitted_withdrawn_rate": "pct",
    "first_submitted_pass_rate": "pct", "tma_on_time_share": "pct", "cma_low_modules": "int",
    "cma_low_submitted": "int", "cma_low_on_time": "int", "cma_other_on_time_share": "pct",
    "week12_active_pass": "pct", "week12_active_fail": "pct", "week12_fail_on_course": "int",
}

SP_COLS = [
    "code_module", "code_presentation", "id_student", "reg_day", "unreg_day", "final_result",
    "outcome_group", "withdrew_before_start", "started", "expected_assessments",
    "submitted_assessments", "tma_submitted", "tma_on_time", "vle_clicks", "vle_active_days",
    "vle_first_day", "vle_active_days_first_2w", "vle_active_weeks",
]
SP_KEYS = ["code_module", "code_presentation", "id_student"]

JSON_EXPORTS = ["presentation_outcome", "assessment_submission", "cohort_week_activity",
                "data_quality", "readme_facts"]
ALL_EXPORTS = JSON_EXPORTS + ["student_presentation"]


# ----------------------------------------------------------------------------------------------
# Общие правила спеки
# ----------------------------------------------------------------------------------------------

def on_course(reg, unreg, d1, d2):
    """R2: числится на курсе в окне [d1, d2]; пропуск даты — NULL (сравнение с NULL ложно)."""
    return (np.isnan(reg) | (reg <= d2)) & (np.isnan(unreg) | (unreg >= d1))


def ratio(num, den):
    """Доля без округления; нулевой знаменатель — null."""
    return None if int(den) == 0 else Fraction(int(num), int(den))


def as_float(fr):
    return None if fr is None else float(fr)


def round_tenths(fr):
    """round(100·value, 1) в целых десятых процента: половина — от нуля; второе значение — ничья."""
    x = Fraction(fr) * 1000
    ax = abs(x)
    whole = ax.numerator // ax.denominator
    rest = ax - whole
    tenths = whole + (1 if rest >= Fraction(1, 2) else 0)
    return (-tenths if x < 0 else tenths), rest == Fraction(1, 2)


def fmt_tenths(fr):
    t, _ = round_tenths(fr)
    sign = "-" if t < 0 else ""
    return f"{sign}{abs(t) // 10},{abs(t) % 10}"


def fmt_pct(fr):
    return fmt_tenths(fr) + "%"


def fmt_pp(fr):
    return fmt_tenths(fr) + PP_SUFFIX


def fmt_int(n):
    n = int(n)
    if n >= 10000:
        return f"{n:,}".replace(",", NBSP)
    return str(n)


def fmt_display(kind, value):
    if value is None:
        return None
    if kind == "int":
        return fmt_int(value)
    if kind == "pct":
        return fmt_pct(value)
    if kind == "pp":
        return fmt_pp(value)
    raise ValueError(kind)


# ----------------------------------------------------------------------------------------------
# Чтение CSV
# ----------------------------------------------------------------------------------------------

def read_text(path, usecols=None):
    """Все значения в кавычках, пропуск — «?»: читаем как текст и разбираем сами."""
    return pd.read_csv(path, dtype=str, keep_default_na=False, usecols=usecols)


def to_float(s):
    """Число с пропуском «?» -> float64 с NaN (NaN играет роль NULL)."""
    return pd.to_numeric(s.where(s != "?", None), errors="raise").astype("float64")


def to_int(s):
    if (s == "?").any():
        raise SystemExit(f"неожиданный пропуск в целой колонке {s.name}")
    return pd.to_numeric(s, errors="raise").astype("int64")


def load_data(data_dir):
    d = Path(data_dir)
    courses = read_text(d / "courses.csv")
    courses["length"] = to_int(courses["module_presentation_length"])
    # Python сравнивает строки по кодовым точкам = по байтам UTF-8 (COLLATE "C")
    courses = courses.sort_values(PKEY).reset_index(drop=True)
    pres_idx = {(m, p): i for i, (m, p) in enumerate(zip(courses.code_module, courses.code_presentation))}

    reg = read_text(d / "studentRegistration.csv")
    info = read_text(d / "studentInfo.csv", usecols=KEY + ["final_result"])
    for t in (reg, info):
        t["id_student"] = to_int(t["id_student"])
    regs = reg.merge(info, on=KEY, how="inner", validate="one_to_one")
    if not (len(regs) == len(reg) == len(info)):
        raise SystemExit("studentRegistration и studentInfo не 1:1 по (модуль, поток, студент)")
    regs["reg"] = to_float(regs["date_registration"])
    regs["unreg"] = to_float(regs["date_unregistration"])
    regs["pres"] = [pres_idx.get(k, -1) for k in zip(regs.code_module, regs.code_presentation)]
    if (regs.pres < 0).any():
        raise SystemExit("регистрация на поток, которого нет в courses.csv")
    regs["length"] = courses.length.to_numpy()[regs.pres.to_numpy()]
    regs["group"] = regs.final_result.map(GROUP_OF)
    if regs.group.isna().any():
        raise SystemExit("неизвестный final_result: " + str(set(regs.final_result) - set(GROUP_OF)))
    regs["wbs"] = regs.unreg.notna() & (regs.unreg <= 0)  # R1
    regs["started"] = ~regs.wbs
    regs = regs.sort_values(KEY).reset_index(drop=True)  # reg_id = номер строки

    asm = read_text(d / "assessments.csv")
    asm["id_assessment"] = to_int(asm["id_assessment"])
    asm["D"] = to_float(asm["date"])
    asm["weight_num"] = to_float(asm["weight"])

    sa = read_text(d / "studentAssessment.csv")
    sa["id_assessment"] = to_int(sa["id_assessment"])
    sa["id_student"] = to_int(sa["id_student"])
    sa["date_submitted"] = to_float(sa["date_submitted"])
    sa["is_banked"] = to_int(sa["is_banked"])
    sa["score_missing"] = sa["score"] == "?"

    # studentVle: 10,6 млн строк — только нужные колонки и явные типы
    vle = pd.read_csv(
        d / "studentVle.csv",
        usecols=["code_module", "code_presentation", "id_student", "id_site", "date", "sum_click"],
        dtype={"code_module": "category", "code_presentation": "category", "id_student": "int64",
               "id_site": "int64", "date": "int64", "sum_click": "int64"},
        keep_default_na=False, na_values=[],
    )
    return {"courses": courses, "pres_idx": pres_idx, "regs": regs, "asm": asm, "sa": sa, "vle": vle}


def n_distinct(columns):
    """Число различных строк по набору колонок: смешанная система счисления на кодах factorize."""
    n = len(columns[0])
    key = np.zeros(n, dtype=np.int64)
    radix = 1
    for c in columns:
        codes, uniq = pd.factorize(c)
        k = max(len(uniq), 1)
        if radix * k >= 2 ** 63:
            raise SystemExit("ключ различения не помещается в int64")
        radix *= k
        key = key * k + codes.astype(np.int64)
    return int(pd.unique(key).size)


# ----------------------------------------------------------------------------------------------
# Пересчёт
# ----------------------------------------------------------------------------------------------

def prepare_vle(data):
    """Привязка строк studentVle к регистрации и агрегаты по (регистрация, день/неделя)."""
    regs, vle, pres_idx = data["regs"], data["vle"], data["pres_idx"]
    R = len(regs)
    mcat = list(vle.code_module.cat.categories)
    pcat = list(vle.code_presentation.cat.categories)
    lut = np.full((len(mcat), len(pcat)), -1, dtype=np.int64)
    for i, m in enumerate(mcat):
        for j, p in enumerate(pcat):
            lut[i, j] = pres_idx.get((m, p), -1)
    vp = lut[vle.code_module.cat.codes.to_numpy(), vle.code_presentation.cat.codes.to_numpy()]
    stud = vle.id_student.to_numpy()
    shift = 1 << 22
    if stud.min() < 0 or stud.max() >= shift or regs.id_student.max() >= shift:
        raise SystemExit("id_student вне ожидаемого диапазона для ключа привязки")
    reg_key = regs.pres.to_numpy().astype(np.int64) * shift + regs.id_student.to_numpy()
    vle_key = np.where(vp >= 0, vp * shift + stud, -1)
    rid = pd.Index(reg_key).get_indexer(vle_key)

    date = vle.date.to_numpy()
    clicks = vle.sum_click.to_numpy()
    out = {"rows_total": len(vle), "unmapped": int((rid < 0).sum()),
           "min_click": int(clicks.min()) if len(clicks) else None}

    # data_quality по журналу целиком
    out["distinct5"] = n_distinct([vle.code_module, vle.code_presentation, vle.id_student,
                                   vle.id_site, vle.date])
    out["distinct6"] = n_distinct([vle.code_module, vle.code_presentation, vle.id_student,
                                   vle.id_site, vle.date, vle.sum_click])
    out["before_start"] = int((date < 0).sum())

    m = rid >= 0
    rid_m, date_m, clk_m = rid[m], date[m], clicks[m]
    unreg = regs.unreg.to_numpy()
    length = regs.length.to_numpy()
    u = unreg[rid_m]
    out["after_unreg"] = int(((~np.isnan(u)) & (date_m > u)).sum())
    out["after_length"] = int((date_m > length[rid_m]).sum())

    out["rows_per_reg"] = np.bincount(rid_m, minlength=R)
    out["clicks_per_reg"] = np.rint(np.bincount(rid_m, weights=clk_m, minlength=R)).astype(np.int64)

    # различные дни по регистрации
    dmin = int(date_m.min()) if len(date_m) else 0
    span = (int(date_m.max()) - dmin + 1) if len(date_m) else 1
    day_key = np.unique(rid_m.astype(np.int64) * span + (date_m - dmin))
    day_rid = day_key // span
    day_val = day_key % span + dmin
    out["active_days"] = np.bincount(day_rid, minlength=R)
    first = np.full(R, np.nan)
    uniq_rid, first_pos = np.unique(day_rid, return_index=True)  # ключи отсортированы: первый = минимум
    first[uniq_rid] = day_val[first_pos]
    out["first_day"] = first
    in2w = (day_val >= 0) & (day_val <= 13)
    out["active_days_2w"] = np.bincount(day_rid[in2w], minlength=R)
    in_len = (day_val >= 0) & (day_val <= length[day_rid])
    wk_key = np.unique(day_rid[in_len] * 1000 + day_val[in_len] // 7)
    out["active_weeks"] = np.bincount(wk_key // 1000, minlength=R)

    # строки и клики по (регистрация, неделя w >= 0): R8 — день в [7w, 7w + 6] = floor(day / 7) == w
    pos = date_m >= 0
    week = date_m[pos] // 7
    nw = int(week.max()) + 1 if len(week) else 1
    key = rid_m[pos].astype(np.int64) * nw + week
    out["nw"] = nw
    out["week_rows"] = np.bincount(key, minlength=R * nw).reshape(R, nw)
    out["week_clicks"] = np.rint(np.bincount(key, weights=clk_m[pos], minlength=R * nw)).astype(np.int64).reshape(R, nw)
    return out


def assessment_pairs(data):
    """Задания TMA/CMA (R4) с seq и пары «задание, регистрация» с флагами R5–R7."""
    asm, regs, sa = data["asm"], data["regs"], data["sa"]
    tc = asm[asm.assessment_type.isin(["TMA", "CMA"])].copy()
    tc = tc.sort_values(PKEY + ["D", "id_assessment"]).reset_index(drop=True)
    tc["seq"] = tc.groupby(PKEY, sort=False).cumcount() + 1

    sa_tc = sa.merge(tc[["id_assessment", "assessment_type", "D"]], on="id_assessment", how="inner")
    banked = sa_tc[sa_tc.is_banked == 1][["id_assessment", "id_student"]].drop_duplicates()
    banked["has_banked"] = True
    nb = sa_tc[sa_tc.is_banked == 0].copy()
    nb["nb_on_time"] = nb.date_submitted <= nb.D  # R7: date_submitted <= D
    nb_flags = nb.groupby(["id_assessment", "id_student"], as_index=False).agg(
        has_nb=("is_banked", "size"), nb_on_time=("nb_on_time", "any"))
    nb_flags["has_nb"] = nb_flags.has_nb > 0

    r = regs.reset_index().rename(columns={"index": "reg_id"})
    pairs = tc[["id_assessment", "code_module", "code_presentation", "assessment_type", "D", "seq"]].merge(
        r[["reg_id", "code_module", "code_presentation", "id_student", "reg", "unreg", "wbs",
           "group", "final_result"]],
        on=PKEY, how="inner")
    pairs = pairs.merge(banked, on=["id_assessment", "id_student"], how="left")
    pairs = pairs.merge(nb_flags, on=["id_assessment", "id_student"], how="left")
    for c in ("has_banked", "has_nb", "nb_on_time"):
        pairs[c] = pairs[c].astype("boolean").fillna(False).astype(bool)
    D = pairs.D.to_numpy()
    pairs["expected"] = on_course(pairs.reg.to_numpy(), pairs.unreg.to_numpy(), D, D) & ~pairs.has_banked  # R5
    pairs["submitted"] = pairs.expected & pairs.has_nb  # R6
    pairs["on_time"] = pairs.submitted & pairs.nb_on_time  # R7

    # строки сдачи (is_banked = 0) от тех, кто не должен был сдавать
    exp_set = pairs.loc[pairs.expected, ["id_assessment", "id_student"]].assign(exp=True)
    nb_rows = nb[["id_assessment", "id_student"]].merge(exp_set, on=["id_assessment", "id_student"], how="left")
    nb_rows["exp"] = nb_rows["exp"].astype("boolean").fillna(False).astype(bool)
    sne = nb_rows[~nb_rows.exp].groupby("id_assessment").size()
    banked_rows = sa_tc[sa_tc.is_banked == 1].groupby("id_assessment").size()
    rows_all = sa_tc.groupby("id_assessment").size()

    agg = pairs.groupby("id_assessment").agg(expected=("expected", "sum"), submitted=("submitted", "sum"),
                                             on_time=("on_time", "sum"))
    tc = tc.merge(agg, left_on="id_assessment", right_index=True, how="left")
    for c in ("expected", "submitted", "on_time"):
        tc[c] = tc[c].fillna(0).astype(np.int64)
    tc["banked"] = tc.id_assessment.map(banked_rows).fillna(0).astype(np.int64)
    tc["submitted_not_expected"] = tc.id_assessment.map(sne).fillna(0).astype(np.int64)
    tc["sa_rows"] = tc.id_assessment.map(rows_all).fillna(0).astype(np.int64)
    dup_pairs = int(sa.duplicated(["id_assessment", "id_student"]).sum())
    return tc, pairs, sa_tc, dup_pairs


def recompute_assessment_submission(tc):
    rows = []
    for t in tc.itertuples(index=False):
        w = float(t.weight_num)
        rows.append({
            "code_module": t.code_module, "code_presentation": t.code_presentation,
            "id_assessment": int(t.id_assessment), "assessment_type": t.assessment_type,
            "seq": int(t.seq), "deadline_day": int(t.D), "weight": w,
            "expected": int(t.expected), "submitted": int(t.submitted), "on_time": int(t.on_time),
            "banked": int(t.banked), "submitted_not_expected": int(t.submitted_not_expected),
            "on_time_measurable": t.assessment_type == "TMA",
            "submission_rate": as_float(ratio(t.submitted, t.expected)),
            "on_time_share": as_float(ratio(t.on_time, t.submitted)),
        })
    return rows


def recompute_presentation_outcome(data, tc):
    courses, regs = data["courses"], data["regs"]
    rows, exact = [], {}
    for c in courses.itertuples(index=False):
        r = regs[(regs.code_module == c.code_module) & (regs.code_presentation == c.code_presentation)]
        st = r[r.started]
        cnt = st.final_result.value_counts()
        dist, pas, fail, wd = (int(cnt.get(k, 0)) for k in ("Distinction", "Pass", "Fail", "Withdrawn"))
        t = tc[(tc.code_module == c.code_module) & (tc.code_presentation == c.code_presentation)]
        tma = t[t.assessment_type == "TMA"]
        registered, wbs, started = len(r), int(r.wbs.sum()), len(st)
        exp_a, sub_a = int(t.expected.sum()), int(t.submitted.sum())
        tma_sub, tma_ot = int(tma.submitted.sum()), int(tma.on_time.sum())
        pr = ratio(dist + pas, started)
        exact[(c.code_module, c.code_presentation)] = {
            "pass_rate": pr, "dist": dist, "pass": pas, "started": started, "length": int(c.length)}
        rows.append({
            "code_module": c.code_module, "code_presentation": c.code_presentation,
            "start_year": int(c.code_presentation[:4]), "start_month_code": c.code_presentation[-1],
            "length_days": int(c.length), "registered": registered, "withdrew_before_start": wbs,
            "started": registered - wbs, "started_distinction": dist, "started_pass": pas,
            "started_fail": fail, "started_withdrawn": wd,
            "pass_rate": as_float(pr), "withdrawn_rate": as_float(ratio(wd, started)),
            "pass_rate_registered": as_float(ratio(int((r.group == "pass").sum()), registered)),
            "expected_assessments": exp_a, "submitted_assessments": sub_a,
            "tma_submitted": tma_sub, "tma_on_time": tma_ot,
            "submission_rate": as_float(ratio(sub_a, exp_a)),
            "tma_on_time_share": as_float(ratio(tma_ot, tma_sub)),
        })
    return rows, exact


def recompute_cohort_week_activity(data, v):
    courses, regs = data["courses"], data["regs"]
    reg_a, unreg_a = regs.reg.to_numpy(), regs.unreg.to_numpy()
    started_a, group_a, pres_a = regs.started.to_numpy(), regs.group.to_numpy(), regs.pres.to_numpy()
    rows = []
    for pi, c in enumerate(courses.itertuples(index=False)):
        sel = np.flatnonzero(pres_a == pi)
        last_week = int(c.length) // 7
        for w in range(last_week + 1):
            cohort = started_a[sel] & on_course(reg_a[sel], unreg_a[sel], 7 * w, 7 * w + 6)  # R9
            if w < v["nw"]:
                act = v["week_rows"][sel, w] > 0  # R8
                clk = v["week_clicks"][sel, w]
            else:
                act = np.zeros(len(sel), dtype=bool)
                clk = np.zeros(len(sel), dtype=np.int64)
            for g in GROUPS:
                e = cohort & (group_a[sel] == g)
                a = e & act
                rows.append({"code_module": c.code_module, "code_presentation": c.code_presentation,
                             "week": w, "outcome_group": g, "enrolled": int(e.sum()),
                             "active": int(a.sum()), "clicks": int(clk[a].sum())})
    return rows


def cma_by_module(tc):
    """Сдачи CMA (R6) и сдачи CMA в срок (R7) по модулю code_module, только модули с CMA."""
    cma = tc[tc.assessment_type == "CMA"]
    by = cma.groupby("code_module").agg(submitted=("submitted", "sum"), on_time=("on_time", "sum"))
    by["low"] = by.on_time * 100 < by.submitted  # в срок меньше 1% сдач CMA модуля
    return by


def recompute_data_quality(data, tc, v):
    regs, sa, asm = data["regs"], data["sa"], data["asm"]
    fr = regs.final_result
    sa_type = sa.merge(asm[["id_assessment", "assessment_type"]], on="id_assessment", how="left").assessment_type
    in_tc = sa_type.isin(["TMA", "CMA"]).to_numpy()
    by = cma_by_module(tc)
    n = {
        "reg_day_missing": int(regs.reg.isna().sum()),
        "late_registration": int((regs.reg > 0).sum()),
        "withdrawn_no_unreg_day": int(((fr == "Withdrawn") & regs.unreg.isna()).sum()),
        "fail_withdrew_before_start": int(((fr != "Withdrawn") & regs.wbs).sum()),
        "unreg_day_not_withdrawn": int(((fr != "Withdrawn") & regs.unreg.notna()).sum()),
        "unreg_after_end": int((regs.unreg > regs.length).sum()),
        "banked": int((in_tc & (sa.is_banked.to_numpy() == 1)).sum()),
        "submitted_not_expected": int(tc.submitted_not_expected.sum()),
        "score_missing": int(sa.score_missing.sum()),
        "exam_out_of_scope": int((sa_type == "Exam").sum()),
        "cma_deadline": int(by[by.low].submitted.sum()),
        "vle_repeated_key": v["rows_total"] - v["distinct5"],
        "vle_exact_duplicate": v["rows_total"] - v["distinct6"],
        "vle_before_start": v["before_start"],
        "vle_after_unreg": v["after_unreg"],
        "no_vle": int((v["rows_per_reg"] == 0).sum()),
    }
    return {code: {"n": n[code], "severity": "warning"} for code in DQ_CODES}


def recompute_readme_facts(data, po_rows, po_exact, tc, pairs, cw_rows):
    f = {}
    keys = [(r["code_module"], r["code_presentation"]) for r in po_rows]
    f["modules"] = len({k[0] for k in keys})
    f["presentations"] = len(keys)
    S = lambda col: sum(r[col] for r in po_rows)
    f["registrations"] = S("registered")
    f["withdrew_before_start"] = S("withdrew_before_start")
    f["started"] = S("started")
    f["started_passed"] = S("started_distinction") + S("started_pass")
    f["pass_rate"] = ratio(f["started_passed"], f["started"])
    f["started_withdrawn"] = S("started_withdrawn")
    f["withdrawn_rate"] = ratio(f["started_withdrawn"], f["started"])
    f["started_failed"] = S("started_fail")

    rated = [(po_exact[k]["pass_rate"], k) for k in keys if po_exact[k]["pass_rate"] is not None]
    lo = min(pr for pr, _ in rated)
    hi = max(pr for pr, _ in rated)
    # при равенстве — первый по модулю и потоку (keys уже в этом порядке)
    lo_k = next(k for pr, k in rated if pr == lo)
    hi_k = next(k for pr, k in rated if pr == hi)
    f["pass_rate_min"], f["pass_rate_max"] = lo, hi
    f["pass_rate_min_presentation"] = f"{lo_k[0]} {lo_k[1]}"
    f["pass_rate_max_presentation"] = f"{hi_k[0]} {hi_k[1]}"

    for code, letter in (("pass_rate_feb", "B"), ("pass_rate_oct", "J")):
        ks = [k for k in keys if k[1][-1] == letter]
        f[code] = ratio(sum(po_exact[k]["dist"] + po_exact[k]["pass"] for k in ks),
                        sum(po_exact[k]["started"] for k in ks))
    by_my = {}
    for k in keys:
        by_my.setdefault((k[0], k[1][:4]), {})[k[1][-1]] = po_exact[k]["pass_rate"]
    gaps = [(d["J"] - d["B"]) for d in by_my.values()
            if "B" in d and "J" in d and d["B"] is not None and d["J"] is not None]
    n_pairs = sum(1 for d in by_my.values() if "B" in d and "J" in d)
    f["feb_oct_pairs"] = n_pairs
    f["feb_lower_pairs"] = sum(1 for g in gaps if g > 0)
    f["feb_gap_min"] = min(gaps) if gaps else None
    f["feb_gap_max"] = max(gaps) if gaps else None
    lb = [po_exact[k]["length"] for k in keys if k[1][-1] == "B"]
    lj = [po_exact[k]["length"] for k in keys if k[1][-1] == "J"]
    f["feb_length_min"], f["feb_length_max"] = min(lb), max(lb)
    f["oct_length_min"], f["oct_length_max"] = min(lj), max(lj)
    f["submission_rate"] = ratio(S("submitted_assessments"), S("expected_assessments"))

    p1 = pairs[(pairs.seq == 1) & pairs.expected]
    not_sub = p1[~p1.submitted]
    sub = p1[p1.submitted]
    f["first_expected"] = len(p1)
    f["first_not_submitted"] = len(not_sub)
    f["first_not_submitted_share"] = ratio(len(not_sub), len(p1))
    f["first_not_submitted_pass_rate"] = ratio(int((not_sub.group == "pass").sum()), len(not_sub))
    f["first_not_submitted_withdrawn_rate"] = ratio(int((not_sub.final_result == "Withdrawn").sum()), len(not_sub))
    f["first_submitted_pass_rate"] = ratio(int((sub.group == "pass").sum()), len(sub))
    f["tma_on_time_share"] = ratio(S("tma_on_time"), S("tma_submitted"))

    by = cma_by_module(tc)
    low, other = by[by.low], by[~by.low]
    f["cma_low_modules"] = len(low)
    f["cma_low_submitted"] = int(low.submitted.sum())
    f["cma_low_on_time"] = int(low.on_time.sum())
    f["cma_other_on_time_share"] = ratio(int(other.on_time.sum()), int(other.submitted.sum()))

    w12 = [r for r in cw_rows if r["week"] == 12]
    for code, g in (("week12_active_pass", "pass"), ("week12_active_fail", "fail")):
        rs = [r for r in w12 if r["outcome_group"] == g]
        f[code] = ratio(sum(r["active"] for r in rs), sum(r["enrolled"] for r in rs))
    f["week12_fail_on_course"] = sum(r["enrolled"] for r in w12 if r["outcome_group"] == "fail")

    out, ties = {}, []
    for code, kind in RF_KINDS.items():
        val = f[code]
        if kind == "text":
            out[code] = {"value": None, "display": val}
        elif kind == "int":
            out[code] = {"value": int(val), "display": fmt_int(val)}
        else:
            if val is not None and round_tenths(val)[1]:
                ties.append(code)
            out[code] = {"value": as_float(val), "display": fmt_display(kind, val)}
    return out, ties


def recompute_student_presentation(data, pairs, v):
    regs = data["regs"]
    R = len(regs)
    p = pairs[pairs.expected]
    rid = p.reg_id.to_numpy()
    tma = (p.assessment_type == "TMA").to_numpy()
    sub = p.submitted.to_numpy()
    ot = p.on_time.to_numpy()
    exp_n = np.bincount(rid, minlength=R)
    sub_n = np.bincount(rid[sub], minlength=R)
    tma_sub = np.bincount(rid[sub & tma], minlength=R)
    tma_ot = np.bincount(rid[ot & tma], minlength=R)

    def int_text(a):
        return ["" if (isinstance(x, float) and math.isnan(x)) else str(int(x)) for x in a]

    def tf(a):
        return np.where(np.asarray(a, dtype=bool), "t", "f")

    df = pd.DataFrame({
        "code_module": regs.code_module.to_numpy(),
        "code_presentation": regs.code_presentation.to_numpy(),
        "id_student": regs.id_student.astype(str).to_numpy(),
        "reg_day": int_text(regs.reg.to_numpy()),
        "unreg_day": int_text(regs.unreg.to_numpy()),
        "final_result": regs.final_result.to_numpy(),
        "outcome_group": regs.group.to_numpy(),
        "withdrew_before_start": tf(regs.wbs.to_numpy()),
        "started": tf(regs.started.to_numpy()),
        "expected_assessments": exp_n.astype(str),
        "submitted_assessments": sub_n.astype(str),
        "tma_submitted": tma_sub.astype(str),
        "tma_on_time": tma_ot.astype(str),
        # сумма и число дней по пустому набору строк — 0; пусто только у vle_first_day (так в спеке)
        "vle_clicks": v["clicks_per_reg"].astype(str),
        "vle_active_days": v["active_days"].astype(str),
        "vle_first_day": int_text(v["first_day"]),
        "vle_active_days_first_2w": v["active_days_2w"].astype(str),
        "vle_active_weeks": v["active_weeks"].astype(str),
    })
    return df.astype(object)


def recompute(data_dir):
    """Пересчёт всех выгрузок из CSV; возвращает ожидаемые выгрузки, контрольные числа спеки и справку."""
    data = load_data(data_dir)
    v = prepare_vle(data)
    tc, pairs, sa_tc, dup_pairs = assessment_pairs(data)
    as_rows = recompute_assessment_submission(tc)
    po_rows, po_exact = recompute_presentation_outcome(data, tc)
    cw_rows = recompute_cohort_week_activity(data, v)
    dq = recompute_data_quality(data, tc, v)
    rf, ties = recompute_readme_facts(data, po_rows, po_exact, tc, pairs, cw_rows)
    sp = recompute_student_presentation(data, pairs, v)

    asm, sa = data["asm"], data["sa"]
    exams = asm[asm.assessment_type == "Exam"]
    exam_rows = sa.merge(exams[["id_assessment", "code_module"]], on="id_assessment", how="inner")
    spec_facts = [
        ("потоков (22)", len(data["courses"]), 22),
        ("регистраций (32 593)", len(data["regs"]), 32593),
        ("заданий TMA/CMA (182)", len(tc), 182),
        ("экзаменов (24)", len(exams), 24),
        ("экзаменов без даты (11 из 24)", int(exams.D.isna().sum()), 11),
        ("модули с результатами экзаменов (CCC, DDD)",
         " ".join(sorted(exam_rows.code_module.unique())), "CCC DDD"),
        ("строк cohort_week_activity (2 451)", len(cw_rows), 2451),
        ("sum_click всегда >= 1", v["min_click"] >= 1, True),
        ("тождество submitted + banked + submitted_not_expected = строк по заданию (нарушений)",
         int((tc.submitted + tc.banked + tc.submitted_not_expected != tc.sa_rows).sum()), 0),
    ]
    diag = [
        f"строк studentVle: {v['rows_total']}, без своей регистрации: {v['unmapped']}",
        f"повторов пары «задание, студент» в studentAssessment: {dup_pairs}",
        f"пар R5 у не приступивших (R1) регистраций: {int((pairs.expected & pairs.wbs).sum())}",
        f"строк studentVle с днём > length своего потока: {v['after_length']}",
        f"ничьих при округлении подписей до 0,1: {len(ties)} {ties if ties else ''}".rstrip(),
    ]
    exp = {"presentation_outcome": po_rows, "assessment_submission": as_rows,
           "cohort_week_activity": cw_rows, "data_quality": dq, "readme_facts": rf,
           "student_presentation": sp}
    return exp, spec_facts, diag


# ----------------------------------------------------------------------------------------------
# Сверка
# ----------------------------------------------------------------------------------------------

class Section:
    def __init__(self, name):
        self.name = name
        self.rows_exp = 0
        self.rows_got = 0
        self.values = 0
        self.mismatches = []
        self.undefined_cols = []  # колонки, значения которых спека не определяет
        self.notes = []

    def add(self, kind, key, col, got, exp):
        self.mismatches.append((self.name, kind, key, col, got, exp))


def same(kind, exp, got):
    if kind == "int":
        return type(got) is int and got == exp
    if kind == "share":
        if exp is None or got is None:
            return exp is None and got is None
        return type(got) in (int, float) and math.isfinite(got) and abs(got - exp) <= TOL
    if kind == "num":
        return type(got) in (int, float) and float(got) == float(exp)
    if kind == "text":
        return type(got) is str and got == exp
    if kind == "bool":
        return type(got) is bool and got == exp
    raise ValueError(kind)


def hkey(v):
    return json.dumps(v, ensure_ascii=False, sort_keys=True) if isinstance(v, (list, dict)) else v


def compare_keys(sec, exp_keys, got_keys):
    """Число строк, недостающие/лишние/повторные ключи и порядок; возвращает общие ключи по порядку пересчёта."""
    sec.rows_exp, sec.rows_got = len(exp_keys), len(got_keys)
    if len(exp_keys) != len(got_keys):
        sec.add("row_count", None, None, len(got_keys), len(exp_keys))
    eset, cnt = set(exp_keys), Counter(got_keys)
    for k, c in cnt.items():
        if c > 1:
            sec.add("duplicate_key", k, None, c, 1)
    for k in exp_keys:
        if k not in cnt:
            sec.add("row_missing", k, None, None, k)
    for k in cnt:
        if k not in eset:
            sec.add("row_extra", k, None, k, None)
    e_common = [k for k in exp_keys if k in cnt]
    g_common = [k for k in dict.fromkeys(got_keys) if k in eset]
    if e_common != g_common:
        for i, (a, b) in enumerate(zip(e_common, g_common)):
            if a != b:
                sec.add("order", a, f"позиция {i}", b, a)
    return e_common


def compare_list(name, exp_rows, got_rows, cols, keys):
    sec = Section(name)
    if not isinstance(got_rows, list) or not all(isinstance(r, dict) for r in got_rows):
        sec.add("format", None, None, type(got_rows).__name__, "массив объектов")
        return sec
    seen = set().union(*[set(r) for r in got_rows]) if got_rows else set()
    for c in sorted(seen - set(cols)):
        sec.add("column_extra", None, c, c, None)
    in_all = set.intersection(*[set(r) for r in got_rows]) if got_rows else set()
    for c in cols:
        if c not in in_all:
            sec.add("column_missing", None, c, None, c)
    if got_rows and list(got_rows[0]) != list(cols):
        sec.notes.append("порядок колонок в объектах отличается от таблицы спеки (справка)")
    ek = [tuple(r[k] for k in keys) for r in exp_rows]
    gk = [tuple(hkey(r.get(k)) for k in keys) for r in got_rows]
    common = compare_keys(sec, ek, gk)
    emap = dict(zip(ek, exp_rows))
    gmap = {}
    for k, r in zip(gk, got_rows):
        gmap.setdefault(k, r)
    for k in common:
        er, gr = emap[k], gmap[k]
        for c, kind in cols.items():
            sec.values += 1
            if c not in gr:
                sec.add("value", k, c, "<нет поля>", er[c])
            elif not same(kind, er[c], gr[c]):
                sec.add("value", k, c, gr[c], er[c])
    return sec


def compare_coded(name, exp, got_rows, all_cols, order_col, undefined, spec_order, checks):
    """Выгрузка «строка на код» (data_quality, readme_facts): порядок только по order_col."""
    sec = Section(name)
    sec.undefined_cols = [f"{order_col} (значения; проверяется только порядок)"] + list(undefined)
    if not isinstance(got_rows, list) or not all(isinstance(r, dict) for r in got_rows):
        sec.add("format", None, None, type(got_rows).__name__, "массив объектов")
        return sec
    seen = set().union(*[set(r) for r in got_rows]) if got_rows else set()
    for c in sorted(seen - set(all_cols)):
        sec.add("column_extra", None, c, c, None)
    in_all = set.intersection(*[set(r) for r in got_rows]) if got_rows else set()
    for c in all_cols:
        if c not in in_all:
            sec.add("column_missing", None, c, None, c)
    # порядок строк: order_col — целые по строгому возрастанию
    prev = None
    for i, r in enumerate(got_rows):
        o = r.get(order_col)
        sec.values += 1
        if type(o) is not int or (prev is not None and o <= prev):
            sec.add("order", r.get("code"), f"{order_col} в позиции {i}", o, f"целое > {prev}")
        if type(o) is int:
            prev = o
    codes = [hkey(r.get("code")) for r in got_rows]
    sec.rows_exp, sec.rows_got = len(exp), len(got_rows)
    if len(exp) != len(got_rows):
        sec.add("row_count", None, None, len(got_rows), len(exp))
    cnt = Counter(codes)
    for c, n in cnt.items():
        if n > 1:
            sec.add("duplicate_key", c, None, n, 1)
    for c in exp:
        if c not in cnt:
            sec.add("row_missing", c, None, None, c)
    for c in cnt:
        if c not in exp:
            sec.add("row_extra", c, None, c, None)
    gmap = {}
    for c, r in zip(codes, got_rows):
        gmap.setdefault(c, r)
    for code in exp:
        if code not in gmap:
            continue
        sec.values += 1  # сам код
        for col, kind, expected in checks(code, exp[code]):
            sec.values += 1
            gr = gmap[code]
            if col not in gr:
                sec.add("value", code, col, "<нет поля>", expected)
            elif not same(kind, expected, gr[col]):
                sec.add("value", code, col, gr[col], expected)
    got_order = [c for c in codes if c in exp]
    want = [c for c in spec_order if c in cnt]
    sec.notes.append("порядок кодов совпадает с порядком таблицы спеки" if got_order == want
                     else "порядок кодов не совпадает с порядком строк таблицы спеки (справка: спека задаёт порядок только через "
                          f"{order_col})")
    return sec


def dq_checks(code, e):
    return [("n", "int", e["n"]), ("severity", "text", e["severity"])]


def rf_checks(code, e):
    kind = RF_KINDS[code]
    if kind == "text":
        return [("value", "share", None), ("display", "text", e["display"])]
    vkind = "int" if kind == "int" else "share"
    return [("value", vkind, e["value"]), ("display", "text", e["display"])]


def compare_students(exp_df, got_df):
    sec = Section("student_presentation")
    got_cols = list(got_df.columns)
    for c in got_cols:
        if c not in SP_COLS:
            sec.add("column_extra", None, c, c, None)
    missing = [c for c in SP_COLS if c not in got_cols]
    for c in missing:
        sec.add("column_missing", None, c, None, c)
    if not missing and got_cols != SP_COLS:
        sec.notes.append("порядок колонок CSV отличается от таблицы спеки (справка)")
    if any(k in missing for k in SP_KEYS):
        sec.rows_exp, sec.rows_got = len(exp_df), len(got_df)
        return sec
    ek = list(zip(*(exp_df[k] for k in SP_KEYS)))
    gk = list(zip(*(got_df[k] for k in SP_KEYS)))
    common = compare_keys(sec, ek, gk)
    idx = pd.MultiIndex.from_tuples(common, names=SP_KEYS) if common else None
    if idx is None:
        return sec
    e = exp_df.set_index(SP_KEYS).reindex(idx)
    g = got_df.drop_duplicates(subset=SP_KEYS, keep="first").set_index(SP_KEYS).reindex(idx)
    sec.values += len(common) * len(SP_KEYS)
    for c in SP_COLS:
        if c in SP_KEYS or c in missing:
            continue
        ev, gv = e[c].to_numpy(), g[c].to_numpy()
        sec.values += len(common)
        for i in np.flatnonzero(ev != gv):
            sec.add("value", common[i], c, gv[i], ev[i])
    return sec


def compare_spec_facts(spec_facts):
    sec = Section("контрольные числа спеки")
    sec.rows_exp = sec.rows_got = len(spec_facts)
    for label, got, want in spec_facts:
        sec.values += 1
        if got != want:
            sec.add("spec_fact", label, None, got, want)
    return sec


def compare_all(exp, ex, spec_facts=None):
    secs = [
        compare_list("presentation_outcome", exp["presentation_outcome"], ex["presentation_outcome"], PO_COLS, PO_KEYS),
        compare_list("assessment_submission", exp["assessment_submission"], ex["assessment_submission"], AS_COLS, AS_KEYS),
        compare_list("cohort_week_activity", exp["cohort_week_activity"], ex["cohort_week_activity"], CW_COLS, CW_KEYS),
        compare_coded("data_quality", exp["data_quality"], ex["data_quality"], DQ_COLS, "seq",
                      DQ_UNDEFINED, DQ_CODES, dq_checks),
        compare_coded("readme_facts", exp["readme_facts"], ex["readme_facts"], RF_COLS, "ord",
                      [], list(RF_KINDS), rf_checks),
        compare_students(exp["student_presentation"], ex["student_presentation"]),
    ]
    if spec_facts is not None:
        secs.append(compare_spec_facts(spec_facts))
    return secs


def load_exports(exports_dir, students_csv):
    ex = {}
    for name in JSON_EXPORTS:
        with open(Path(exports_dir) / f"{name}.json", encoding="utf-8") as fh:
            ex[name] = json.load(fh)
    ex["student_presentation"] = pd.read_csv(students_csv, dtype=str, keep_default_na=False).astype(object)
    return ex


# ----------------------------------------------------------------------------------------------
# Отчёт
# ----------------------------------------------------------------------------------------------

def show(v):
    if isinstance(v, str):
        return repr(v)
    if isinstance(v, tuple):
        return "(" + ", ".join(str(x) for x in v) + ")"
    return str(v)


def print_report(secs, max_examples=5):
    total_v = sum(s.values for s in secs)
    total_m = sum(len(s.mismatches) for s in secs)
    print(f"{'выгрузка':<28}{'строк (пересчёт/выгрузка)':>28}{'значений':>11}{'расхождений':>13}")
    for s in secs:
        print(f"{s.name:<28}{f'{s.rows_exp}/{s.rows_got}':>28}{s.values:>11}{len(s.mismatches):>13}")
    print()
    print("Колонки, значения которых спека не определяет (не сверяются):")
    any_undef = False
    for s in secs:
        if s.undefined_cols:
            any_undef = True
            print(f"  {s.name}: " + ", ".join(s.undefined_cols))
    if not any_undef:
        print("  нет")
    extra = [(s.name, m[3]) for s in secs for m in s.mismatches if m[1] == "column_extra"]
    print("Колонки выгрузок, которых нет в спеке: " + (", ".join(f"{n}.{c}" for n, c in extra) if extra else "нет"))
    notes = [(s.name, n) for s in secs for n in s.notes]
    if notes:
        print("Справка:")
        for n, t in notes:
            print(f"  {n}: {t}")
    if total_m:
        print()
        print(f"РАСХОЖДЕНИЯ (до {max_examples} примеров на выгрузку и вид):")
        for s in secs:
            if not s.mismatches:
                continue
            by_kind = Counter((m[1], m[3]) for m in s.mismatches)
            print(f"  {s.name}:")
            for (kind, col), n in by_kind.items():
                print(f"    [{kind}] {col if col else ''}: {n}")
                for m in [m for m in s.mismatches if m[1] == kind and m[3] == col][:max_examples]:
                    print(f"      ключ {show(m[2])}: выгрузка {show(m[4])}, пересчёт {show(m[5])}")
    print()
    print(f"Всего сверено значений: {total_v}; расхождений: {total_m}")
    return total_m


# ----------------------------------------------------------------------------------------------
# Самопроверка
# ----------------------------------------------------------------------------------------------

def expected_from_exports(ex):
    """Ожидание, собранное из самих выгрузок: сверка с ним обязана дать 0 расхождений."""
    exp = {n: copy.deepcopy(ex[n]) for n in ("presentation_outcome", "assessment_submission", "cohort_week_activity")}
    exp["data_quality"] = {r["code"]: {"n": r["n"], "severity": r["severity"]} for r in ex["data_quality"]}
    exp["readme_facts"] = {r["code"]: {"value": r["value"], "display": r["display"]} for r in ex["readme_facts"]}
    exp["student_presentation"] = ex["student_presentation"].copy()
    return exp


def corruptions():
    """Порчи выгрузок: (описание, функция(копия выгрузок))."""
    def po(ex): return ex["presentation_outcome"]
    def asb(ex): return ex["assessment_submission"]
    def cw(ex): return ex["cohort_week_activity"]
    def dq(ex): return ex["data_quality"]
    def rf(ex): return ex["readme_facts"]
    def sp(ex): return ex["student_presentation"]

    def rf_row(ex, code): return next(r for r in rf(ex) if r["code"] == code)
    def dq_row(ex, code): return next(r for r in dq(ex) if r["code"] == code)

    def swap(lst, i, j): lst[i], lst[j] = lst[j], lst[i]

    def flip_tf(df, row, col):
        df.iat[row, df.columns.get_loc(col)] = "f" if df.iat[row, df.columns.get_loc(col)] == "t" else "t"

    def bump_text_int(df, row, col):
        j = df.columns.get_loc(col)
        df.iat[row, j] = str(int(df.iat[row, j] or 0) + 1)

    def flip_group(ex):
        rows = cw(ex)
        a, b = rows[300], rows[301]
        a["outcome_group"], b["outcome_group"] = b["outcome_group"], a["outcome_group"]

    def fill_missing_unreg(ex):
        df = sp(ex)
        j = df.columns.get_loc("unreg_day")
        i = int(np.flatnonzero(df["unreg_day"].to_numpy() == "")[0])
        df.iat[i, j] = "1"

    def add_row(ex):
        r = dict(po(ex)[-1])
        r["code_presentation"] = "2099J"
        po(ex).append(r)

    return [
        ("presentation_outcome: +1 к целому registered", lambda ex: po(ex)[3].__setitem__("registered", po(ex)[3]["registered"] + 1)),
        ("presentation_outcome: +1e-9 к доле pass_rate", lambda ex: po(ex)[5].__setitem__("pass_rate", po(ex)[5]["pass_rate"] + 1e-9)),
        ("presentation_outcome: лишняя строка", add_row),
        ("presentation_outcome: целое записано дробным (started -> float)", lambda ex: po(ex)[0].__setitem__("started", float(po(ex)[0]["started"]))),
        ("presentation_outcome: лишняя колонка", lambda ex: [r.__setitem__("extra_col", 1) for r in po(ex)]),
        ("assessment_submission: две строки поменяны местами", lambda ex: swap(asb(ex), 10, 11)),
        ("assessment_submission: строка удалена", lambda ex: asb(ex).pop(50)),
        ("assessment_submission: доля on_time_share -> null", lambda ex: asb(ex)[7].__setitem__("on_time_share", None)),
        ("assessment_submission: логическое on_time_measurable перевёрнуто", lambda ex: asb(ex)[0].__setitem__("on_time_measurable", not asb(ex)[0]["on_time_measurable"])),
        ("assessment_submission: weight 10 -> 10.5", lambda ex: asb(ex)[0].__setitem__("weight", asb(ex)[0]["weight"] + 0.5)),
        ("cohort_week_activity: текстовый ключ code_module изменён", lambda ex: cw(ex)[100].__setitem__("code_module", "AAB")),
        ("cohort_week_activity: группы двух соседних ячеек поменяны", flip_group),
        ("cohort_week_activity: +1 к active", lambda ex: cw(ex)[500].__setitem__("active", cw(ex)[500]["active"] + 1)),
        ("cohort_week_activity: колонка clicks удалена", lambda ex: [r.pop("clicks") for r in cw(ex)]),
        ("data_quality: +1 к n у no_vle", lambda ex: dq_row(ex, "no_vle").__setitem__("n", dq_row(ex, "no_vle")["n"] + 1)),
        ("data_quality: severity -> error", lambda ex: dq_row(ex, "banked").__setitem__("severity", "error")),
        ("data_quality: строка удалена", lambda ex: dq(ex).pop(3)),
        ("data_quality: две строки поменяны местами (seq едет со строкой)", lambda ex: swap(dq(ex), 0, 1)),
        ("readme_facts: +1e-9 к value pass_rate", lambda ex: rf_row(ex, "pass_rate").__setitem__("value", rf_row(ex, "pass_rate")["value"] + 1e-9)),
        ("readme_facts: +1 к value first_expected", lambda ex: rf_row(ex, "first_expected").__setitem__("value", rf_row(ex, "first_expected")["value"] + 1)),
        ("readme_facts: текстовый display изменён", lambda ex: rf_row(ex, "pass_rate_min_presentation").__setitem__("display", "AAA 2013J")),
        ("readme_facts: процентная подпись изменена", lambda ex: rf_row(ex, "withdrawn_rate").__setitem__("display", "24,1%")),
        ("readme_facts: подпись целого без неразрывного пробела", lambda ex: rf_row(ex, "registrations").__setitem__("display", "32593")),
        ("readme_facts: value текстового факта не null", lambda ex: rf_row(ex, "pass_rate_max_presentation").__setitem__("value", 0)),
        ("student_presentation: логическое started t<->f", lambda ex: flip_tf(sp(ex), 0, "started")),
        ("student_presentation: +1 к vle_clicks", lambda ex: bump_text_int(sp(ex), 100, "vle_clicks")),
        ("student_presentation: пропуск unreg_day заполнен", fill_missing_unreg),
        ("student_presentation: строка удалена", lambda ex: ex.__setitem__("student_presentation", sp(ex).drop(index=5).reset_index(drop=True))),
        ("student_presentation: две строки поменяны местами", lambda ex: ex.__setitem__("student_presentation", sp(ex).iloc[[1, 0] + list(range(2, len(sp(ex))))].reset_index(drop=True))),
        ("student_presentation: колонка vle_active_weeks удалена", lambda ex: ex.__setitem__("student_presentation", sp(ex).drop(columns=["vle_active_weeks"]))),
    ]


def fmt_selftest():
    """Форматирование подписей на заведомо известных значениях."""
    cases = [
        (fmt_int(32593), "32" + NBSP + "593"), (fmt_int(3097), "3097"), (fmt_int(10000), "10" + NBSP + "000"),
        (fmt_pct(Fraction(1, 8)), "12,5%"), (fmt_pct(Fraction(1, 3)), "33,3%"), (fmt_pct(Fraction(2, 3)), "66,7%"),
        (fmt_pct(Fraction(1, 2000)), "0,1%"), (fmt_pct(Fraction(0)), "0,0%"), (fmt_pct(Fraction(1)), "100,0%"),
        (fmt_pp(Fraction(3, 250)), "1,2 п.п."), (fmt_pp(Fraction(-3, 250)), "-1,2 п.п."),
    ]
    return [(got, want) for got, want in cases if got != want]


def self_test(exp, ex, spec_facts):
    ok = True
    print("САМОПРОВЕРКА")
    # 1. прибор против заведомо правильного случая: выгрузка против самой себя
    ident = compare_all(expected_from_exports(ex), ex)
    n_ident = sum(len(s.mismatches) for s in ident)
    print(f"  контроль: выгрузки против самих себя — расхождений {n_ident} (нужно 0)")
    ok &= n_ident == 0
    bad_fmt = fmt_selftest()
    print(f"  контроль: форматирование подписей на известных значениях — ошибок {len(bad_fmt)} (нужно 0)"
          + (f": {bad_fmt}" if bad_fmt else ""))
    ok &= not bad_fmt

    def ids(secs):
        return {(m[0], m[1], show(m[2]), m[3], show(m[4])) for s in secs for m in s.mismatches}

    base = ids(compare_all(exp, ex, spec_facts))
    print(f"  базовая сверка с пересчётом: расхождений {len(base)}")

    # 2. в пределах допуска: сдвиг доли на 1e-13 ловиться не должен
    tol_copy = copy.deepcopy({n: ex[n] for n in JSON_EXPORTS})
    tol_copy["student_presentation"] = ex["student_presentation"]
    r = tol_copy["presentation_outcome"][2]
    r["pass_rate"] = r["pass_rate"] + 1e-13
    new = ids(compare_all(exp, tol_copy, spec_facts)) - base
    print(f"  контроль допуска: сдвиг доли на 1e-13 — новых расхождений {len(new)} (нужно 0)")
    ok &= not new

    # 3. порчи: каждая обязана дать новое расхождение
    caught = 0
    cases = corruptions()
    for desc, fn in cases:
        c = {n: copy.deepcopy(ex[n]) for n in JSON_EXPORTS}
        c["student_presentation"] = ex["student_presentation"].copy()
        fn(c)
        new = ids(compare_all(exp, c, spec_facts)) - base
        hit = bool(new)
        caught += hit
        ok &= hit
        print(f"  {'поймано' if hit else 'НЕ ПОЙМАНО'}: {desc}" + (f" ({len(new)} новых)" if hit else ""))
    print(f"  порч поймано: {caught} из {len(cases)}")
    print("Самопроверка: " + ("пройдена" if ok else "НЕ ПРОЙДЕНА"))
    return ok


# ----------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Независимый пересчёт выгрузок по docs/spec.md и сверка с ними")
    ap.add_argument("--data", default="data/raw", help="папка с CSV OULAD")
    ap.add_argument("--exports", default="dashboard/data", help="папка с JSON-выгрузками")
    ap.add_argument("--students", default=".tmp/export/student_presentation.csv", help="CSV витрины студентов")
    ap.add_argument("--self-test", action="store_true", help="испортить выгрузки в памяти и проверить, что сверка это ловит")
    args = ap.parse_args()

    t0 = time.time()
    exp, spec_facts, diag = recompute(args.data)
    t1 = time.time()
    ex = load_exports(args.exports, args.students)
    print("Независимый пересчёт выгрузок по docs/spec.md (без доступа к SQL)")
    print(f"Пересчёт из CSV: {t1 - t0:.1f} с")
    print("Справка по данным:")
    for line in diag:
        print("  " + line)
    print()
    secs = compare_all(exp, ex, spec_facts)
    total_m = print_report(secs)
    if args.self_test:
        print()
        ok = self_test(exp, ex, spec_facts)
        print(f"Время: {time.time() - t0:.1f} с")
        print("(в режиме --self-test код возврата отражает только самопроверку; "
              f"расхождений базовой сверки: {total_m})")
        return 0 if ok else 1
    print(f"Время: {time.time() - t0:.1f} с")
    return 1 if total_m else 0


if __name__ == "__main__":
    sys.exit(main())
