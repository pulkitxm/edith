import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame, SectionLabel} from '../components/AppFrame';
import {StatRow} from '../components/StatRow';
import {Caption} from '../components/Caption';

const ROWS = [
  {label: 'Today', value: 542.3, suffix: 'M', cost: 698.4},
  {label: 'Yesterday', value: 398.1, suffix: 'M', cost: 512.65},
  {label: 'This week', value: 4.85, suffix: 'B', cost: 3120.5},
  {label: 'This cycle', value: 8.42, suffix: 'B', cost: 5830.75},
];

export const UsageStats: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  return (
    <Background>
      <AppFrame activeIndex={0}>
        <SectionLabel>USAGE</SectionLabel>
        {ROWS.map((row, i) => (
          <StatRow
            key={row.label}
            label={row.label}
            value={row.value}
            suffix={row.suffix}
            cost={row.cost}
            frame={frame}
            fps={fps}
            delay={i * 8}
          />
        ))}
      </AppFrame>
      <Caption>Tokens & cost, at a glance</Caption>
    </Background>
  );
};
