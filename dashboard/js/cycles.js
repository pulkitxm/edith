import { MON, ymd } from "./format.js";

const daysInMonth = (y, m) => new Date(y, m + 1, 0).getDate();
const anchorFor = (y, m, day) =>
  new Date(y, m, Math.min(day, daysInMonth(y, m)));

export function cycleStart(date, day) {
  const y = date.getFullYear(),
    m = date.getMonth();
  const anchor = Math.min(day, daysInMonth(y, m));
  if (date.getDate() >= anchor) return new Date(y, m, anchor);
  return anchorFor(m === 0 ? y - 1 : y, m === 0 ? 11 : m - 1, day);
}

export function cycleEnd(start, day) {
  const y = start.getFullYear(),
    m = start.getMonth();
  const next = anchorFor(m === 11 ? y + 1 : y, m === 11 ? 0 : m + 1, day);
  const end = new Date(next);
  end.setDate(end.getDate() - 1);
  return end;
}

function label(start, end) {
  const s =
    `${start.getDate()} ${MON[start.getMonth()]}` +
    (start.getFullYear() !== end.getFullYear()
      ? ` ${start.getFullYear()}`
      : "");
  return `${s} – ${end.getDate()} ${MON[end.getMonth()]} ${end.getFullYear()}`;
}

export function cyclesFromBounds(earliest, latest, day) {
  const out = [];
  let start = cycleStart(earliest, day);
  while (start <= latest) {
    const end = cycleEnd(start, day);
    out.push({ start: ymd(start), end: ymd(end), label: label(start, end) });
    start = new Date(end);
    start.setDate(start.getDate() + 1);
  }
  return out.reverse();
}
