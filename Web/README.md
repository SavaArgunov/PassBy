# PassBy Web / Android

React 19 + Vite. Один код для веб-версії (PWA) і Android-застосунку (Capacitor).

## Запуск веб-версії

```bash
cd Web
npm install
npm run dev        # http://localhost:5173
```

Бекенд має працювати на `http://localhost:8080` (`docker compose -f docker-compose.dev.yml up`).
Запити на `/api` проксуються на бекенд, тому CORS не потрібен. Інший бекенд:

```bash
VITE_PROXY_TARGET=http://host:port npm run dev
```

## Що працює з бекендом

| Екран | API |
|---|---|
| Реєстрація | `POST /api/auth/register` (пароль від 12 символів, телефон нормалізується до `+380XXXXXXXXX`) |
| Вхід | `POST /api/auth/login`, сесія відновлюється після перезавантаження сторінки |
| Вибір ролі | `GET /api/roles/my`, `POST /api/roles/acquire` (відправник = `DeliveryRequester`, кур'єр = `Deliverer`) |
| Верифікація | `/api/verification/*` (MockBank): тестовий документ `TEST-ID-001`, код `DEMO-PROOF-001` |

## Що поки лише локально (демо)

- Ім'я та прізвище: на сервері такого поля немає, зберігається в браузері.
- Спосіб оплати: демо-позначка, дані картки не збираються.
- Вихід очищає токен у браузері (на бекенді немає logout).
- Токен у `sessionStorage`: для продакшену потрібен інший підхід.
- Приклади замовлень на головному екрані статичні.

## Android

```bash
cp .env.example .env.local     # VITE_API_URL=http://10.0.2.2:8080 для емулятора
npm run android:sync           # збірка + cap sync
npm run android:open           # відкрити в Android Studio
```

Особливості:

- У застосунку немає проксі, тому потрібна абсолютна адреса бекенду в `VITE_API_URL`.
- Бекенд має дозволяти origin застосунку в CORS (`https://localhost` для Capacitor за замовчуванням).
- Для http-бекенду на емуляторі потрібні `"server": { "androidScheme": "http", "cleartext": true }` у `capacitor.config.json`. Для продакшену використовуйте https.
- Каталог `android/` містить лише вихідні файли; зібрані артефакти ігноруються.

## Скрипти

```bash
npm run build      # збірка у dist/
npm run lint       # eslint
```
