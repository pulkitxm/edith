import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {MenuBarBadge} from '../components/MenuBarBadge';
import {Caption} from '../components/Caption';
import {springIn} from '../animation';

export const MenuBarBadgeScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const zoomP = springIn(frame, fps, 0);
  const scale = interpolate(zoomP, [0, 1], [2.2, 1]);
  const reveal = interpolate(springIn(frame, fps, 10), [0, 1], [0, 1]);

  return (
    <Background>
      <div style={{transform: `scale(${scale})`}}>
        <MenuBarBadge reveal={reveal} />
      </div>
      <Caption>Limits, right in the menu bar</Caption>
    </Background>
  );
};
