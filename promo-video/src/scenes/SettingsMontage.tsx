import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame, SectionLabel} from '../components/AppFrame';
import {ToggleSwitch} from '../components/ToggleSwitch';
import {Caption} from '../components/Caption';
import {colors} from '../tokens';
import {springIn} from '../animation';

// Matches App.swift's allTabs registry, in its real default order.
const ROWS = [
  {title: 'Agent Usage', subtitle: 'limit polling, usage stats'},
  {title: 'Music', subtitle: 'player, media keys'},
  {title: 'System', subtitle: 'prevent sleep, keyboard cleaning'},
  {title: 'Calendar', subtitle: "today's schedule"},
];

export const SettingsMontage: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  return (
    <Background>
      <AppFrame activeIndex={0}>
        <SectionLabel>TABS</SectionLabel>
        {ROWS.map((row, i) => {
          const p = interpolate(springIn(frame, fps, i * 10), [0, 1], [0, 1]);
          return (
            <div
              key={row.title}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 14,
                padding: '12px 0',
                opacity: p,
              }}
            >
              <span style={{color: colors.label, fontSize: 16}}>&#9776;</span>
              <div style={{flex: 1}}>
                <div style={{color: colors.text, fontSize: 18}}>{row.title}</div>
                <div style={{color: colors.label, fontSize: 13, marginTop: 2}}>
                  {row.subtitle}
                </div>
              </div>
              <ToggleSwitch progress={p} />
            </div>
          );
        })}
      </AppFrame>
      <Caption>Make it yours</Caption>
    </Background>
  );
};
