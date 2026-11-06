import {Easing, interpolate, spring} from 'remotion';

export const launchFps = 30;
export const beat = 18;
export const bar = beat * 4;

export const ink = {
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
};

export const goldGradient =
  'linear-gradient(135deg, #fff6d2 0%, #f0cd7a 22%, #b98a34 48%, #f7e2a6 66%, #c79a45 84%, #7f5719 100%)';

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
