# Запрет планировщиков закрыт для ScheduleWakeup и RemoteTrigger

`block-claude-crons.sh` отказывает теперь семи точкам входа вместо пяти: к
`CronCreate`/`CronList`/`CronDelete` и скиллам `schedule`/`loop` добавились
`ScheduleWakeup` и действия `create`, `update`, `run`, `create_webhook_trigger`
инструмента `RemoteTrigger`; читающие действия `RemoteTrigger` и `Monitor`
разрешены. Тест хука заодно сверяет его ветки с `PreToolUse`-матчером, а
`check-decisions.py` — полноту реестра решений.
