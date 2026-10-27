#!/usr/bin/env bash
# Проверки после сборки: независимый пересчёт из CSV, его самопроверка и числа README.
set -euo pipefail  # pipefail: падение пересчёта не теряется за tee
cd "$(dirname "$0")/.."
mkdir -p .tmp
# Вывод пересчёта сохраняется: числа о проверках в README сверяются с этим логом.
ARGS=(--data data/raw --exports dashboard/data --students .tmp/export/student_presentation.csv)
echo "→ checks/verify_independent.py"
python3 -I checks/verify_independent.py "${ARGS[@]}" | tee .tmp/verify_independent.log
echo "→ checks/verify_independent.py --self-test"
python3 -I checks/verify_independent.py "${ARGS[@]}" --self-test | tee -a .tmp/verify_independent.log
echo "→ checks/check_readme_numbers.py"
python3 -I checks/check_readme_numbers.py
