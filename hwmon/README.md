# hwmon — Strata Overview как отдельный монитор железа

Код `strata_cli/` и `serve/telemetry.py` взят из github.com/Niko1221/Strata (MIT, см. LICENSE-Strata-MIT).
Запускает немодифицированный монитор Strata поверх локального /metrics, который кормит сэмплер Strata
(NVML через ctypes + psutil). Сервер, движок и модель Strata не нужны.

    pip install -r requirements.txt
    python hwmon.py            # или run.bat
    python hwmon.py --gpu 1 --label "RTX 3090 Ti"

Клавиши: 1-6 вкладки, / фильтр, Space заморозка, r обновить, t тема, ? справка, q выход.
Speed / Context / Experts / Recent requests пустые: их считает сервер инференса, а не железо.
