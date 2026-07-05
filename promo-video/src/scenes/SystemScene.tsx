import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate, AbsoluteFill} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame, SectionLabel} from '../components/AppFrame';
import {ToggleSwitch} from '../components/ToggleSwitch';
import {Caption} from '../components/Caption';
import {colors} from '../tokens';
import {springIn} from '../animation';

// Real SystemView.swift stacks POWER above KEYBOARD on one screen - not two
// separate screens. This scene shows both together, Prevent Sleep on top,
// then the Clean Keyboard card demos its own lock/countdown states.
const SCRIM_IN = [100, 118];
const ARMING_START = 118;
const ARMING_END = 166;
const CLEANING_START = 166;

const Card: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div
    style={{
      background: 'rgba(255,255,255,0.04)',
      borderRadius: 16,
      padding: '18px 20px',
      marginBottom: 14,
    }}
  >
    {children}
  </div>
);

export const SystemScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const tabIndex = interpolate(springIn(frame, fps, 0), [0, 1], [0, 2]);
  const togglePos = interpolate(springIn(frame, fps, 24), [0, 1], [0, 1]);

  const scrimOpacity = interpolate(frame, SCRIM_IN, [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const contentOpacity = interpolate(frame, [ARMING_START, ARMING_START + 10], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const panelOpacity = interpolate(frame, SCRIM_IN, [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  const isCleaning = frame >= CLEANING_START;
  const armingNumber = Math.max(
    1,
    3 - Math.floor((frame - ARMING_START) / ((ARMING_END - ARMING_START) / 3)),
  );
  const restoreSeconds = Math.max(40, 60 - Math.floor((frame - CLEANING_START) / 10));

  return (
    <Background>
      <div style={{opacity: panelOpacity}}>
        <AppFrame activeIndex={tabIndex}>
          <Card>
            <SectionLabel>POWER</SectionLabel>
            <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
              <div>
                <div style={{color: colors.text, fontSize: 20, fontWeight: 600}}>
                  Prevent sleep
                </div>
                <div style={{color: colors.textDim, fontSize: 14, marginTop: 4}}>
                  Keeps the display awake; closing the lid still sleeps
                </div>
              </div>
              <ToggleSwitch progress={togglePos} />
            </div>
          </Card>

          <Card>
            <SectionLabel>KEYBOARD</SectionLabel>
            <div style={{color: colors.textDim, fontSize: 14, lineHeight: 1.6, marginBottom: 20}}>
              Blocks every key - letters, shortcuts, volume, brightness - so you
              can wipe the keyboard. The trackpad stays live; exit with the
              Done button or the 60s auto-restore.
            </div>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: 12,
                color: colors.accent,
                fontSize: 17,
                fontWeight: 600,
              }}
            >
              <span>&#9096;</span> Clean keyboard
            </div>
          </Card>
        </AppFrame>
      </div>

      {scrimOpacity > 0.02 && (
        <AbsoluteFill style={{background: 'rgba(0,0,0,0.6)', opacity: scrimOpacity}} />
      )}
      {contentOpacity > 0.02 && (
        <AbsoluteFill
          style={{
            opacity: contentOpacity,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 18,
          }}
        >
          <div style={{fontSize: 52}}>&#9096;</div>
          {isCleaning ? (
            <>
              <div style={{color: colors.text, fontSize: 30, fontWeight: 700}}>
                Keyboard is off - clean away
              </div>
              <div style={{color: 'rgba(255,255,255,0.7)', fontSize: 17}}>
                Auto-restores in {restoreSeconds}s
              </div>
              <div
                style={{
                  marginTop: 8,
                  padding: '12px 30px',
                  borderRadius: 22,
                  background: colors.accent,
                  color: '#1a1208',
                  fontWeight: 700,
                  fontSize: 17,
                }}
              >
                Done cleaning
              </div>
            </>
          ) : (
            <>
              <div style={{color: colors.text, fontSize: 30, fontWeight: 700}}>
                Starting in {armingNumber}&hellip;
              </div>
              <div style={{color: 'rgba(255,255,255,0.7)', fontSize: 17}}>
                Move your hands away from the keyboard.
              </div>
            </>
          )}
        </AbsoluteFill>
      )}
      <Caption delay={40}>Prevent sleep, and lock the keyboard to wipe it</Caption>
    </Background>
  );
};
