export const colors = {
  bg: '#0b0a08',
  bgVignette: 'radial-gradient(120% 100% at 50% 0%, #1c1611 0%, #0b0a08 60%, #050403 100%)',
  panel: 'rgba(20, 17, 14, 0.6)',
  border: 'rgba(255, 255, 255, 0.06)',
  accent: '#f5a623',
  accentSoft: 'rgba(245, 166, 35, 0.18)',
  track: '#2a2521',
  text: '#ffffff',
  textDim: '#9a958d',
  label: '#75706a',
};

export const fontFamily =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Arial, sans-serif';

export const fps = 30;

// scene durations in frames, 30fps - each trimmed to a short buffer past
// where its animation actually settles, so no scene sits frozen mid-cut.
export const durations = {
  coldOpen: 65,
  rings: 145, // rings + 24h chart draw-in
  heatmap: 100,
  stats: 80,
  system: 230, // POWER + KEYBOARD cards together, then the lock demo
  music: 140, // track list + now-playing bar, continuous scrub/visualizer
  calendar: 135, // agenda: 3 day groups, 4 fake events, staggered in
  menuBar: 60,
  notification: 75,
  shortcut: 80, // keys press, then the panel opens
  settings: 80, // 4 tab rows now (calendar added)
  trust: 190, // more hold time to actually read the three points
  outro: 80,
};

// TransitionSeries overlaps each pair of neighboring sequences by the
// transition's own length, shortening the total by (scenes - 1) * that length.
export const transitionFrames = 12;
const sceneCount = Object.keys(durations).length;
export const totalDuration =
  Object.values(durations).reduce((a, b) => a + b, 0) -
  (sceneCount - 1) * transitionFrames;
