import {spring, interpolate, Easing} from 'remotion';

export const springIn = (
  frame: number,
  fps: number,
  delay = 0,
  overshoot = false,
) =>
  spring({
    frame: frame - delay,
    fps,
    config: overshoot
      ? {damping: 12, mass: 0.6, stiffness: 180}
      : {damping: 20, mass: 0.6, stiffness: 160},
  });

export const fadeUp = (frame: number, fps: number, delay = 0) => {
  const p = springIn(frame, fps, delay);
  return {
    opacity: interpolate(p, [0, 1], [0, 1]),
    transform: `translateY(${interpolate(p, [0, 1], [16, 0])}px)`,
  };
};

export const easeOut = Easing.bezier(0.16, 1, 0.3, 1);
