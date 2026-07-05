import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate, AbsoluteFill} from 'remotion';
import {Background} from '../components/Background';
import {Toast} from '../components/Toast';
import {Caption} from '../components/Caption';
import {easeOut} from '../animation';

export const NotificationScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();

  const x = interpolate(
    frame,
    [0, 18, durationInFrames - 20, durationInFrames - 4],
    [420, 0, 0, 420],
    {easing: easeOut, extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );
  const opacity = interpolate(
    frame,
    [0, 14, durationInFrames - 16, durationInFrames - 2],
    [0, 1, 1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );

  return (
    <Background>
      <AbsoluteFill style={{padding: 80}}>
        <Toast x={x} opacity={opacity} />
      </AbsoluteFill>
      <Caption>Alerts before you hit the wall</Caption>
    </Background>
  );
};
