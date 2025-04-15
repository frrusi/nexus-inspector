# Nexus Inspector
Контроль загрузок в **Sonatype Nexus Repository** с последующим уведомлением о неавторизованных загрузках

## 📂 Структура проекта
```
nexus-inspector
├── templates
│   └── email.html        # Шаблон email-уведомления
├── .gitignore            # Файлы, игнорируемые Git
├── config.json.example   # Пример конфигурации
├── README.md             # Документация
├── nexus_inspector.sh     # Основной скрипт
├── nexus_inspector_scheduler.sh  # Планировщик скрипта
├── nexus_inspector.service # systemd service
├── nexus_inspector.timer   # systemd таймер
```

## 📌 Установка и настройка
1. **Клонируйте репозиторий**  

```bash
git clone https://github.com/frrusi/nexus-inspector.git
cd nexus_inspector
```

2. **Настройте конфигурацию**  

- Скопируйте пример:
```bash
cp .env.example .env
cp config.json.example config.json
```
- Отредактируйте `.env` и `config.json`, задав логин/пароль от Nexus, email-адреса и репозитории для мониторинга

3. **Установите зависимости**  

Убедитесь, что установлены:  
- `curl`
- `jq`
- `sendmail`  

Если их нет, установите (пример для Debian/Ubuntu):
```bash
sudo apt update && sudo apt install curl jq sendmail -y
```

4. **Настройте отправку почты через `sendmail`:**

По умолчанию используется `sendmail` для отправки email-уведомлений. Убедитесь, что он правильно настроен

5. **Настройка systemd**  

Установите таймер для автоматического запуска:
```bash
sudo cp nexus_inspector.service /etc/systemd/system/
sudo cp nexus_inspector.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nexus_inspector.timer
```

## 🔧 Использование
Запустить сканирование вручную:
```bash
./nexus_inspector.sh --repository <your-repo> --recipients email@example.com
```

Запустить планировщик вручную:
```bash
./nexus_inspector_scheduler.sh --config config.json
```

## 📝 Логирование
- Логи хранятся в `log/debug/YYYY-MM-DD/`
- Отчеты о нарушениях - в `log/reports/<your-repo>/`

## 📧 Уведомления
При обнаружении неавторизованных загрузок отправляется email-уведомление

<img src="docs/images/email-notification.jpg" width="500">