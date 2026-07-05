export const fmtUSD = (n) => {
  n = +n || 0;
  if (n >= 1000) return "$" + (n / 1000).toFixed(n >= 100000 ? 0 : 1) + "k";
  if (n >= 100) return "$" + n.toFixed(0);
  return "$" + n.toFixed(2);
};
export const fmtUSDfull = (n) =>
  "$" +
  (+n || 0).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
export const fmtTok = (n) => {
  n = +n || 0;
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "k";
  return String(Math.round(n));
};
export const fmtTokFull = (n) => (+n || 0).toLocaleString("en-US");
export const fmtPct = (n) => (n * 100).toFixed(1) + "%";
export const fmtDur = (ms) => {
  ms = +ms || 0;
  if (ms <= 0) return "-";
  const s = Math.round(ms / 1000);
  if (s < 60) return s + "s";
  const m = Math.round(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60),
    rem = m % 60;
  return rem ? `${h}h ${rem}m` : `${h}h`;
};
export const shortModel = (m) =>
  String(m || "")
    .replace(/^claude-/, "")
    .replace(/-\d{8}$/, "");
export const parseDate = (s) => {
  const [y, mo, d] = String(s).split("-").map(Number);
  return new Date(y, mo - 1, d);
};
export const ymd = (dt) =>
  `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;
export const MON = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];
export const fmtDate = (s) => {
  if (!s) return "-";
  const [, m, d] = String(s).split("-").map(Number);
  return `${MON[m - 1]} ${d}`;
};
export const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
export const MONTH_NAMES = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];
export const hexA = (hex, a) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
};
