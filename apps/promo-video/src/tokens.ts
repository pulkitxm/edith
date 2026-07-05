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

export const durations = {
  coldOpen: 65,
  rings: 145, 
  heatmap: 100,
  stats: 80,
  system: 230, 
  music: 140, 
  calendar: 135, 
  menuBar: 60,
  notification: 75,
  shortcut: 80, 
  settings: 80, 
  trust: 190, 
  outro: 80,
};

export const transitionFrames = 12;
const sceneCount = Object.keys(durations).length;
export const totalDuration =
  Object.values(durations).reduce((a, b) => a + b, 0) -
  (sceneCount - 1) * transitionFrames;
