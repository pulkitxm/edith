import {Easing, interpolate, spring, useVideoConfig} from 'remotion';

export const launchFps = 30;
export const beat = 18;
export const bar = beat * 4;

const dark = {
  night: '#05080f',
  navy: '#0a1730',
  navyDeep: '#050b18',
  navyLight: '#102650',
  gold: '#e9b65a',
  goldLight: '#f7e2a6',
  goldDeep: '#b98a34',
  coral: '#e08a6a',
  canvas: '#18181a',
  panel: '#242426',
  panelHigh: '#2c2c2f',
  line: '#363639',
  text: '#f5f5f7',
  textSoft: '#b0b0b5',
  textFaint: '#98989f',
  green: '#5fd38d',
  blue: '#6aa8ff',
  violet: '#a98bff',
  glass: 'rgba(255,255,255,0.06)',
  glassLine: 'rgba(255,255,255,0.12)',
  grid: 'rgba(255,255,255,0.025)',
  shadow: 'rgba(0,0,0,0.6)',
  scrim: 'rgba(5,8,15,0.94)',
  scrimSoft: 'rgba(5,8,15,0.2)',
  chip: 'rgba(10,23,48,0.94)',
  card: 'linear-gradient(160deg, #23232a, #16161b)',
  tile: 'linear-gradient(160deg, #2e2e32, #1c1c1f)',
  tileText: '#f5f5f7',
};

const light: typeof dark = {
  night: '#f6f3ec',
  navy: '#eef1f8',
  navyDeep: '#f3f1ea',
  navyLight: '#dde5f6',
  gold: '#c08a2c',
  goldLight: '#9a6a17',
  goldDeep: '#7a520f',
  coral: '#d97757',
  canvas: '#f5f5f7',
  panel: '#ffffff',
  panelHigh: '#f0f0f3',
  line: '#dcdfe7',
  text: '#121a2e',
  textSoft: '#4a5268',
  textFaint: '#767d90',
  green: '#2f9a5c',
  blue: '#2f6fd8',
  violet: '#6f55d9',
  glass: 'rgba(19,33,63,0.05)',
  glassLine: 'rgba(19,33,63,0.14)',
  grid: 'rgba(19,33,63,0.045)',
  shadow: 'rgba(19,33,63,0.22)',
  scrim: 'rgba(246,243,236,0.94)',
  scrimSoft: 'rgba(246,243,236,0.2)',
  chip: 'rgba(255,255,255,0.96)',
  card: 'linear-gradient(160deg, #ffffff, #f1f2f6)',
  tile: 'linear-gradient(160deg, #ffffff, #eceef3)',
  tileText: '#121a2e',
};

export const ink = {...dark};

const gradients = {
  dark: 'linear-gradient(135deg, #fff6d2 0%, #f0cd7a 22%, #b98a34 48%, #f7e2a6 66%, #c79a45 84%, #7f5719 100%)',
  light: 'linear-gradient(135deg, #d9a441 0%, #b8852c 30%, #8a5e14 55%, #c4923a 78%, #7a520f 100%)',
};

export type Appearance = 'dark' | 'light';
export let goldGradient = gradients.dark;
export let captureDir = 'launch/captures';
export let appearance: Appearance = 'dark';

export const applyAppearance = (mode: Appearance) => {
  if (mode === appearance) return;
  appearance = mode;
  Object.assign(ink, mode === 'light' ? light : dark);
  goldGradient = gradients[mode];
  captureDir = mode === 'light' ? 'launch/captures-light' : 'launch/captures';
};



export const display =
  '"SF Pro Display", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif';
export const text =
  '"SF Pro Text", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif';
export const mono = '"SF Mono", Menlo, Monaco, monospace';

export const smooth = Easing.bezier(0.16, 1, 0.3, 1);
export const sharp = Easing.bezier(0.7, 0, 0.2, 1);

export const pop = (frame: number, fps: number, delay = 0, bouncy = false) =>
  spring({
    frame: frame - delay,
    fps,
    config: bouncy
      ? {damping: 13, mass: 0.7, stiffness: 170}
      : {damping: 22, mass: 0.7, stiffness: 150},
  });

export const ramp = (
  frame: number,
  from: number,
  to: number,
  out: [number, number] = [0, 1],
  easing = smooth,
) =>
  interpolate(frame, [from, to], out, {
    easing,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

export const exitFade = (frame: number, duration: number, length = 10) =>
  ramp(frame, duration - length, duration, [1, 0], sharp);

export const useLayout = () => {
  const {width, height} = useVideoConfig();
  const square = width / height < 1.3;
  return {width, height, square, u: Math.min(width, height) / 1080};
};
