// Saved positions, kept in this browser only.
const KEY = 'chesslens.saved.v1';

export function loadSaved() {
  try {
    const list = JSON.parse(localStorage.getItem(KEY) || '[]');
    return Array.isArray(list) ? list.filter((e) => e && typeof e.fen === 'string') : [];
  } catch {
    return [];
  }
}

/** @returns {boolean} false when storage is unavailable (private mode, quota) */
export function writeSaved(list) {
  try {
    localStorage.setItem(KEY, JSON.stringify(list.slice(0, 200)));
    return true;
  } catch {
    return false;
  }
}
