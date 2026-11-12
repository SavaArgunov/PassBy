// Ім'я користувача на сервері поки не зберігається (у UserAccount немає такого поля),
// тому тримаємо його локально на пристрої, окремо для кожного email.
const nameKey = (email) => `passby-name:${email.toLowerCase()}`;

export function readName(email) {
  try {
    return localStorage.getItem(nameKey(email)) || '';
  } catch {
    return '';
  }
}

export function saveName(email, name) {
  try {
    localStorage.setItem(nameKey(email), name);
  } catch {
    /* сховище недоступне */
  }
}
